-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself. Do not run this
-- against any database from this session or any automated tool.
--
-- ORDERING:
--   - Must be applied AFTER 20260925010000_add_moderator_role_and_admin_management.sql
--     (this migration replaces admin_set_user_role(), which that file creates,
--     and relies on profiles.is_admin/is_moderator already existing).
--   - Independent of 20261001000000_add_listing_verification_gate.sql (the
--     still-unapplied verification-gate migration) in the sense that neither
--     depends on the other to apply its own core work — but this migration's
--     final section (6) adds logging wrappers around four functions THAT FILE
--     defines (admin_set_venue_status, admin_set_gym_status,
--     admin_set_role_request_status, admin_approve_unsubmitted_role). Because
--     both files do `create or replace function` on the same signatures,
--     WHICHEVER FILE IS APPLIED LAST WINS for those four functions. If
--     20261001000000 is ever applied AFTER this migration, it will silently
--     overwrite this file's logging wrapper for those four functions (its own
--     bodies have no log_admin_action call) — AND, specifically for
--     admin_approve_unsubmitted_role, it will also silently reintroduce a
--     real bug: that file's version still uses a plain `select ... into`
--     with no `strict`/`exception when no_data_found` guard, where this
--     file's version (section 6 below) fixed that. So applying
--     20261001000000 last doesn't just drop logging for that one function —
--     it un-fixes a correctness bug too. If that happens, just re-run
--     section 6 of this file afterward to restore both the logging and the
--     no_data_found fix. To avoid needing that manual follow-up at all,
--     apply THIS migration (20261002000000) LAST, after 20261001000000. The
--     two files are still kept fully separate per the explicit instruction
--     not to combine them — this is a documented ordering caveat, not a hard
--     dependency.
--   - Section 6 also relies on plpgsql deferring body validation until
--     runtime (confirmed project pattern, see LEARNINGS.md), so it is safe to
--     create these four logging wrappers even if 20261001000000 has never
--     been applied at all — the functions will simply sit dormant,
--     referencing columns/tables (venues.status, gyms.status,
--     role_verification_requests) that don't exist yet, until that migration
--     creates them. No client code calls these four functions until
--     20261001000000's matching index.html changes ship, so this is not a
--     live gap in the meantime.
--
-- Purpose: Kaden's two requests after first getting real admin panel access:
--   1. A log of every admin/moderator action taken by anyone on the team, not
--      just himself — who did what, when.
--   2. Protection so nobody he grants admin/moderator access to can ever
--      outrank him or take over the site — demote him, strip his own access,
--      or grant themselves/others admin behind his back.
--
-- Research confirmed the real gap: profiles.is_admin is a flat,
-- undifferentiated boolean with zero hierarchy. admin_set_user_role()
-- (20260925010000) only guards against the total admin COUNT hitting zero —
-- it does nothing to protect any SPECIFIC account. The moment a second
-- is_admin=true account exists, it has identical power to Kaden's, including
-- the ability to demote him. Nothing anywhere logs who performed a
-- privileged action.
--
-- Guardrail check (explicitly confirmed, not just asserted): this migration
-- does not touch profiles.role (the self-listed Fighter/Coach/etc. label) —
-- completely separate column/system from is_admin/is_moderator/is_owner, per
-- the standing hard guardrail. It also does not implement any payment,
-- checkout, or fighter-ranking logic.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) profiles.is_owner — a third, strictly-above-admin tier. Exactly one row
--    is expected to ever hold this (Kaden's account), but the column itself
--    doesn't enforce "exactly one" — that's a convention enforced by this
--    migration only ever setting it for one UUID, and by no function
--    anywhere (including this file) ever exposing a client-callable path to
--    set it for anyone else. See section 2 for the lockdown.
-- ----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists is_owner boolean not null default false;

-- One-time bootstrap: Kaden's own confirmed real account UUID. Confirmed
-- directly by Kaden earlier the same day, running the following in the
-- Supabase SQL editor against the live database:
--   update profiles set is_admin=true
--   where id=(select id from auth.users where email='kadenf0108@gmail.com')
--   returning id, is_admin;
-- The result returned exactly this UUID with is_admin: true. Baked into the
-- migration itself so applying it is a single step with no separate manual
-- SQL required afterward.
update public.profiles
  set is_owner = true, is_admin = true
  where id = 'b596390f-ec61-4bfb-9d34-4e6acf0b3dfc';

do $$
begin
  if not exists (
    select 1 from public.profiles where id = 'b596390f-ec61-4bfb-9d34-4e6acf0b3dfc' and is_owner = true
  ) then
    raise exception 'Owner bootstrap matched zero rows — the UUID b596390f-ec61-4bfb-9d34-4e6acf0b3dfc does not exist in public.profiles on this database. Confirm the real account id before re-running (Supabase Studio "Success. No rows returned" does not confirm a row was matched — this check exists because that exact silent-failure mode has bitten this project before, see LEARNINGS.md).';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2) Lock down is_owner the same way is_admin/is_moderator already are.
--    profiles already had its table-level INSERT/UPDATE fully revoked and
--    re-granted on an explicit safe-column list (20260925010000). Per this
--    project's own documented lesson (a column-level grant list never
--    automatically extends to a column added later by ALTER TABLE), is_owner
--    already has ZERO write privilege for authenticated/anon the instant it's
--    added above, with no further action needed — restated explicitly below
--    anyway so this migration is self-contained and a future reviewer
--    doesn't have to cross-reference that file to confirm is_owner is
--    write-protected. The re-grant below includes every column previously
--    granted across BOTH 20260925010000 (username, display_name,
--    avatar_url, role, role_info) and 20260925020000 (is_active) — the
--    table-level REVOKE above clears prior grants from both of those
--    migrations, not just the first one, so both lists have to be
--    reproduced here or a working grant silently disappears.
--    There is deliberately NO function anywhere (in this file or any other)
--    that can set is_owner for any client-authenticated caller — it is only
--    ever settable by a human running SQL directly against the database,
--    exactly as decided.
-- ----------------------------------------------------------------------------
revoke insert, update on public.profiles from authenticated, anon;

grant insert (
  id, username, display_name
) on public.profiles to authenticated;

grant update (
  username, display_name, avatar_url, role, role_info, is_active
) on public.profiles to authenticated;

-- ----------------------------------------------------------------------------
-- 3) admin_audit_log — generic audit trail for every privileged action.
--    Writes only ever happen from inside SECURITY DEFINER functions (which
--    bypass RLS and table grants entirely as the function/table owner) — no
--    INSERT/UPDATE/DELETE grant is given to authenticated/anon at all, so
--    there is no client path to write or tamper with this table directly.
-- ----------------------------------------------------------------------------
create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles(id),
  action text not null,
  target_type text not null,
  target_id uuid,
  details jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_log_created_at_idx on public.admin_audit_log(created_at desc);
create index if not exists admin_audit_log_actor_id_idx on public.admin_audit_log(actor_id);

alter table public.admin_audit_log enable row level security;

-- Only an admin or the owner may read the log. Moderators explicitly do NOT
-- get this — same restriction already in place for venue verification/gym
-- certification/team-role management (admin-only, not moderator).
drop policy if exists "admin_audit_log_select_admin_or_owner" on public.admin_audit_log;
create policy "admin_audit_log_select_admin_or_owner"
  on public.admin_audit_log for select
  using (
    exists (select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_owner = true))
  );

-- SELECT grant only — explicitly no insert/update/delete grant to
-- authenticated or anon. The table's only writer is log_admin_action()
-- (section 4), called from inside already-gated SECURITY DEFINER functions,
-- which run with the privileges of the function owner (who owns/can bypass
-- this table) regardless of any client-facing grant.
grant select on public.admin_audit_log to authenticated;

-- ----------------------------------------------------------------------------
-- 4) log_admin_action() — small internal helper. Not itself security-
--    sensitive: it always stamps actor_id as auth.uid() (the real caller,
--    unaffected by any SECURITY DEFINER role-switching happening in the
--    function that calls it), and it is only ever called from within
--    already-gated SECURITY DEFINER functions below. Deliberately NOT marked
--    SECURITY DEFINER itself — when called from inside a SECURITY DEFINER
--    function, it runs with that function's already-elevated effective
--    privileges, so the INSERT below succeeds without needing its own grant;
--    if a client calls it directly via RPC, it runs as the caller
--    (authenticated), who has no INSERT grant on admin_audit_log at all, so
--    the INSERT fails with a permission error instead of letting anyone
--    write an arbitrary log row. EXECUTE is also explicitly revoked from
--    PUBLIC below as a second, belt-and-suspenders layer on top of that.
-- ----------------------------------------------------------------------------
create or replace function public.log_admin_action(p_action text, p_target_type text, p_target_id uuid, p_details jsonb default null)
returns void
language plpgsql
as $$
begin
  insert into public.admin_audit_log (actor_id, action, target_type, target_id, details)
  values (auth.uid(), p_action, p_target_type, p_target_id, p_details);
end;
$$;

revoke execute on function public.log_admin_action(text, text, uuid, jsonb) from public;

-- ----------------------------------------------------------------------------
-- 5) admin_set_user_role() — rewritten with owner protection, keeping
--    everything 20260925010000's version already does correctly (admin-only
--    caller, last-admin guard), plus two new rules:
--
--    Rule A — a profile with is_owner = true can NEVER have is_admin or
--    is_moderator changed by this function, by anyone, including itself.
--    Checked before anything else touches the row.
--
--    Rule B — only the owner may GRANT is_admin = true to a target who isn't
--    already an admin. A regular (non-owner) admin may still: grant/revoke
--    moderator freely, and REVOKE admin from a non-owner admin (demotions
--    stay admin-accessible; only NEW promotions to admin are owner-gated).
--    The existing "can't drop the last admin to zero" guard is kept as-is —
--    the owner account is now permanently exempt from ever being removed via
--    this path anyway (Rule A), so that guard's practical role narrows to
--    protecting against an all-non-owner-admin team accidentally zeroing
--    itself out, which is still worth keeping.
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_user_role(target_user_id uuid, make_admin boolean, make_moderator boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_count int;
  v_target_is_owner boolean;
  v_target_is_admin boolean;
  v_target_is_moderator boolean;
  v_caller_is_owner boolean;
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can change another user''s role.';
  end if;

  select is_owner, is_admin, is_moderator
    into v_target_is_owner, v_target_is_admin, v_target_is_moderator
    from public.profiles where id = target_user_id;

  if v_target_is_owner is null then
    raise exception 'Target user not found.';
  end if;

  -- Rule A: the owner's own is_admin/is_moderator can never be changed by
  -- this function, full stop — no partial update, abort before anything else.
  if v_target_is_owner then
    raise exception 'Cannot modify the owner account''s permissions.';
  end if;

  select is_owner into v_caller_is_owner from public.profiles where id = auth.uid();

  -- Rule B: only the owner can grant NEW admin access. A non-owner admin
  -- calling with make_admin = true for a target who isn't currently an admin
  -- is rejected. Re-affirming make_admin = true on someone ALREADY admin
  -- (e.g. only changing their moderator flag) is not a new grant and stays
  -- open to any admin.
  if make_admin = true and coalesce(v_target_is_admin, false) = false and coalesce(v_caller_is_owner, false) = false then
    raise exception 'Only the owner can grant admin access.';
  end if;

  -- Guard against locking everyone out: if this call would remove admin from
  -- the last remaining admin account, block it rather than leaving the
  -- platform with zero admins and no remaining way to grant it back in-app.
  -- (The owner account can never reach this branch per Rule A above, since
  -- it's always excluded before this point.)
  if make_admin = false then
    select count(*) into admin_count from public.profiles where is_admin = true;
    if admin_count <= 1 and coalesce(v_target_is_admin, false) then
      raise exception 'Cannot remove admin from the last remaining admin account.';
    end if;
  end if;

  update public.profiles
    set is_admin = make_admin,
        is_moderator = make_moderator
    where id = target_user_id;

  perform public.log_admin_action(
    'set_user_role',
    'profile',
    target_user_id,
    jsonb_build_object(
      'old_is_admin', v_target_is_admin, 'new_is_admin', make_admin,
      'old_is_moderator', v_target_is_moderator, 'new_is_moderator', make_moderator
    )
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- 6) Logging wrappers for every other existing admin-privileged function.
--    Each is a verbatim re-creation of the original function's logic (no
--    behavior change) with one log_admin_action() call added right before
--    the normal success return — never on an aborted/exception path.
-- ----------------------------------------------------------------------------

-- admin_set_venue_verification (gym certification) —
-- 20260906000000_roster_follow_review_verify_schema.sql:373-391. Applied and
-- live in production.
create or replace function public.admin_set_venue_verification(gym_id uuid, verified boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can set venue verification.';
  end if;

  update public.gyms
    set verified_venue = verified
    where id = gym_id;

  perform public.log_admin_action('set_venue_verification', 'gym', gym_id, jsonb_build_object('verified', verified));
end;
$$;

-- admin_set_venue_space_verification —
-- 20260911000000_add_venue_rental_schema.sql:294-312. Applied and live in
-- production.
create or replace function public.admin_set_venue_space_verification(target_space_id uuid, sports jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles
    where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can set venue space verification.';
  end if;

  update public.venue_spaces
    set verified_sports = sports
    where id = target_space_id;

  perform public.log_admin_action('set_venue_space_verification', 'venue_space', target_space_id, jsonb_build_object('sports', sports));
end;
$$;

-- admin_set_venue_status — 20261001000000_add_listing_verification_gate.sql
-- (still unapplied). See the ORDERING note at the top of this file.
create or replace function public.admin_set_venue_status(target_id uuid, new_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can set venue status.';
  end if;

  if new_status not in ('approved','rejected') then
    raise exception 'Invalid venue status: %. Must be approved or rejected.', new_status;
  end if;

  update public.venues set status = new_status where id = target_id;

  perform public.log_admin_action('set_venue_status', 'venue', target_id, jsonb_build_object('new_status', new_status));
end;
$$;

-- admin_set_gym_status — 20261001000000_add_listing_verification_gate.sql
-- (still unapplied). See the ORDERING note at the top of this file.
create or replace function public.admin_set_gym_status(target_id uuid, new_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can set gym status.';
  end if;

  if new_status not in ('approved','rejected') then
    raise exception 'Invalid gym status: %. Must be approved or rejected.', new_status;
  end if;

  update public.gyms set status = new_status where id = target_id;

  perform public.log_admin_action('set_gym_status', 'gym', target_id, jsonb_build_object('new_status', new_status));
end;
$$;

-- admin_set_role_request_status — 20261001000000_add_listing_verification_gate.sql
-- (still unapplied). See the ORDERING note at the top of this file.
create or replace function public.admin_set_role_request_status(request_id uuid, new_status text, note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := note;
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can set role verification status.';
  end if;

  if new_status not in ('approved','rejected') then
    raise exception 'Invalid role verification status: %. Must be approved or rejected.', new_status;
  end if;

  update public.role_verification_requests
    set status = new_status,
        reviewed_by = auth.uid(),
        reviewed_at = now(),
        note = v_note
    where id = request_id;

  perform public.log_admin_action('set_role_request_status', 'role_verification_request', request_id, jsonb_build_object('new_status', new_status));
end;
$$;

-- admin_approve_unsubmitted_role — 20261001000000_add_listing_verification_gate.sql
-- (still unapplied). See the ORDERING note at the top of this file.
create or replace function public.admin_approve_unsubmitted_role(target_profile_id uuid, target_role text, new_status text, note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role_info jsonb;
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can approve or reject a role.';
  end if;

  if target_role not in ('fighter','coach','official','sponsor') then
    raise exception 'Invalid role: %. Must be fighter, coach, official, or sponsor.', target_role;
  end if;

  if new_status not in ('approved','rejected') then
    raise exception 'Invalid role verification status: %. Must be approved or rejected.', new_status;
  end if;

  if exists (
    select 1 from public.role_verification_requests
    where profile_id = target_profile_id and requested_role = target_role
  ) then
    raise exception 'A verification request already exists for this profile and role — refresh the queue and use the normal approve/reject action on it instead.';
  end if;

  begin
    select role_info into strict v_role_info
    from public.profiles
    where id = target_profile_id and role = target_role;
  exception when no_data_found then
    raise exception 'This profile no longer holds the % role — refresh the queue and try again.', target_role;
  end;

  insert into public.role_verification_requests
    (profile_id, requested_role, role_info, status, reviewed_by, reviewed_at, note)
  values
    (target_profile_id, target_role, coalesce(v_role_info, '{}'::jsonb), new_status, auth.uid(), now(), note);

  perform public.log_admin_action('approve_unsubmitted_role', 'profile', target_profile_id, jsonb_build_object('role', target_role, 'new_status', new_status));
end;
$$;

-- ----------------------------------------------------------------------------
-- 7) content_reports resolution — today a raw RLS-gated client UPDATE
--    (index.html updateReportStatus(), calling
--    db.from('content_reports').update({status}).eq('id', reportId)) with no
--    function to hook logging into. Replaced with a real SECURITY DEFINER
--    chokepoint, admin_resolve_report(), and the direct column-level UPDATE
--    grant on content_reports.status is revoked so this RPC becomes the only
--    write path left.
-- ----------------------------------------------------------------------------
revoke update (status) on public.content_reports from authenticated, anon;

create or replace function public.admin_resolve_report(report_id uuid, new_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_status text;
begin
  -- Same caller gate as the existing content_reports_update_admin RLS policy
  -- (20260925010000): admin OR moderator, since moderators already resolve
  -- reports today and this function must not narrow that.
  if not exists (
    select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_moderator = true)
  ) then
    raise exception 'Only an admin or moderator can resolve a report.';
  end if;

  if new_status not in ('reviewed','dismissed','actioned') then
    raise exception 'Invalid report status: %. Must be reviewed, dismissed, or actioned.', new_status;
  end if;

  select status into v_old_status from public.content_reports where id = report_id;
  if v_old_status is null then
    raise exception 'Report not found.';
  end if;

  update public.content_reports set status = new_status where id = report_id;

  perform public.log_admin_action('resolve_report', 'content_report', report_id, jsonb_build_object('old_status', v_old_status, 'new_status', new_status));
end;
$$;

-- ----------------------------------------------------------------------------
-- 8) admin_list_team_roster() — read-only helper backing the new "Team &
--    Roles" roster list in the Admin Panel. profiles_public deliberately
--    does NOT expose is_admin/is_moderator/is_owner (that was a real,
--    previously-fixed public-exposure bug, PR #21) — so the client has no
--    way to query "everyone with elevated access" directly. This function
--    bypasses RLS as a SECURITY DEFINER, gated to admin-or-owner callers
--    only, and returns only the columns the roster UI needs. Not itself a
--    privileged WRITE action, so it does not call log_admin_action() — only
--    state-changing admin actions are logged, per the task scope.
-- ----------------------------------------------------------------------------
create or replace function public.admin_list_team_roster()
returns table (
  id uuid,
  display_name text,
  username text,
  avatar_url text,
  is_admin boolean,
  is_moderator boolean,
  is_owner boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_owner = true)
  ) then
    raise exception 'Only an admin or the owner can view the team roster.';
  end if;

  return query
    select p.id, p.display_name, p.username, p.avatar_url, p.is_admin, p.is_moderator, p.is_owner
    from public.profiles p
    where p.is_admin = true or p.is_moderator = true or p.is_owner = true
    order by p.is_owner desc, p.is_admin desc, p.display_name asc;
end;
$$;

notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- NOT included in this migration, deliberately:
-- 1. No change to profiles.role's meaning or how it's assigned.
-- 2. No real payment/checkout logic, no fighter-ranking math.
-- 3. No way, anywhere, for any client-facing RPC to set is_owner for any
--    account — the bootstrap UPDATE in section 1 is the only place it's ever
--    written by this migration, and no function defined here or elsewhere
--    accepts is_owner as a settable parameter.
-- ----------------------------------------------------------------------------
