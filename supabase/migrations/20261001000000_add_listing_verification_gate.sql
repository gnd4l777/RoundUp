-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself from his own
-- machine once he's reviewed it (e.g. via `supabase db push` or the Studio
-- SQL editor). Do not run this against any database from this session or
-- any automated tool.
--
-- ORDERING: must be applied AFTER 20260911000000_add_venue_rental_schema.sql
-- (this migration alters the `venues` table that file creates), AFTER
-- 20260925010000_add_moderator_role_and_admin_management.sql (this migration
-- relies on profiles.is_admin, which predates that file, but also assumes the
-- moderator/admin split it establishes is already live), and AFTER
-- 20260925020000_add_account_deactivation.sql (this migration's
-- profiles_public redefinition in section 4 must preserve that migration's
-- `where is_active` filter — see the note on section 4 below; profiles.is_active
-- must already exist or that filter breaks). If venues doesn't exist yet,
-- section 1 below fails with "relation does not exist".
--
-- ⚠️⚠️ APPLYING THIS MIGRATION WITHOUT THE MATCHING index.html CHANGE BREAKS
-- REAL FUNCTIONALITY FOR EVERY USER — same severity class as the 2026-09-10
-- profiles/messages exposure fixes. See that migration's header for the full
-- shape of this risk. Specifically:
--   - Every venue, gym, and self-listed role that exists in the live database
--     TODAY becomes invisible to everyone except its own owner the instant
--     this migration is applied (decision #2 below, intentional) — until an
--     admin re-approves it via the rewired Admin Verification Dashboard in
--     the matching index.html PR. If that PR isn't deployed yet, nobody has
--     a working Approve button and every existing listing stays hidden.
--   - loadDirectory()/renderDirectory() in the OLD index.html doesn't request
--     `role_verified` from profiles_public, so an old client won't crash, but
--     it also won't suppress unverified-role badges — deploy the migration
--     and the index.html PR together, back-to-back, same as every prior
--     exposure fix in this project.
-- ============================================================================
--
-- FOLLOW-UP — 2026-10-02 (PR review on #45 flagged 3 functional gaps + 1
-- undecided design question; this file was edited in place, not re-created,
-- since it was never applied — see the follow-up PR description for the full
-- review). Changes made in this pass, each tagged inline where it lands:
--   Fix 1 (Issue A): existing role holders had no row and no path back to
--     visibility. Added admin_approve_unsubmitted_role() (section 3) so an
--     admin can approve a profile/role pair directly even with zero prior
--     role_verification_requests rows — index.html's dashboard now also
--     queries for this "never submitted" case.
--   Fix 2 (Issue B): saveRole() inserted a brand-new pending row on every
--     save, flooding the queue with duplicates. Added `updated_at` column
--     plus a scoped UPDATE policy/grant (section 3, right before
--     role_verification_requests_insert_own's grant) so the client can
--     update an existing pending row's role_info in place instead of
--     inserting a new one. See that policy's comment for the one narrow
--     write-path this opens and why it's still safe.
--   Fix 3 (Issue C): nothing here changed — the three admin_set_*_status()
--     functions already accepted any status value with no "this must
--     currently be pending" guard, so index.html's new Approved/Rejected
--     tabs (letting an admin undo a mis-tap) needed no backend change.
--     Documented here only so a future reader isn't left searching for it.
--   Fix 4 (Issue D) — Kaden's decision, confirmed 2026-10-01/02, not a
--     guess: role_verified changes from "is the MOST RECENT matching
--     request approved" to "does ANY approved request exist for this
--     (profile_id, requested_role) pair" — an old approved listing now
--     keeps showing publicly while a newer resubmission for the SAME role
--     sits pending, rather than blanking out immediately. See section 4.
-- ============================================================================
--
-- Purpose: VERIFICATION-GATE-DESIGN.md, approved 2026-10-01. Kaden's three
-- binding decisions this migration encodes:
--   1. Hard gate — a new venue, gym, or self-listed role (Fighter/Coach/
--      Official/Sponsor) is invisible to the public until an admin approves
--      it. Not a "pending" label shown publicly — actually hidden via RLS.
--   2. Existing listings drop to pending too, intentionally — the new
--      `status` column on venues/gyms defaults to 'pending' with NOT NULL,
--      so adding the column correctly backfills every existing row to
--      'pending' with no separate UPDATE statement needed. Existing
--      self-listed roles have no analogous "existing row" to retrofit (there
--      is no pre-existing role_verification_requests table), so an existing
--      self-listed role simply shows role_verified = false (see profiles_public
--      below) until its owner is prompted to (re)submit — no retroactive
--      request rows are synthesized here, since doing so would mean guessing
--      at approval on Kaden's behalf, which isn't this migration's call.
--   3. Admin-only approval — moderators do NOT get this capability, same
--      restriction already in place for venue-space verification / gym
--      certification / team-role management (PR #37,
--      20260925010000_add_moderator_role_and_admin_management.sql). Every
--      function and policy below checks profiles.is_admin only, never
--      is_moderator.
--
-- Guardrail check (explicitly confirmed, not just asserted): this migration
-- does NOT change what profiles.role means or how it's written. saveRole()/
-- clearRole() keep writing profiles.role/role_info exactly as before. The
-- gate controls VISIBILITY only, via a new computed `role_verified` column on
-- profiles_public — it never touches profiles.role itself and grants no new
-- capability (profiles.role already conferred zero capability before this;
-- that remains true after).
--
-- DEVIATIONS FROM THE LITERAL TASK SPEC — flagged here, not silently applied:
--   (a) venues already has a live, shipped soft-delete gate
--       (`is_active`, from 20260911000000) that the original task's literal
--       predicate (`status='approved' or auth.uid()=owner_id`) would have
--       silently dropped — making a soft-deleted-but-previously-approved
--       venue publicly visible again. The venues SELECT policy below ANDs
--       status with is_active instead of replacing it, to avoid
--       reintroducing that already-fixed gap. gyms has no such column, so its
--       policy matches the literal spec as written.
--   (b) both the venues and gyms SELECT policies, and the
--       role_verification_requests SELECT policy, add a third branch — "or
--       the caller is an admin" — beyond what the task literally specified
--       (status='approved' or owner). Without this, an admin could not
--       actually see OTHER people's pending/rejected listings through an
--       ordinary `.select()` (the admin-rewired dashboard in index.html
--       queries these tables directly, not through a bypassing function), so
--       the approval queue would always render empty for real admins. This
--       mirrors the existing pattern on content_reports
--       (20260925010000: `... or exists (... is_admin = true or
--       is_moderator = true)`) — scoped to is_admin only here per decision 3.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) VENUES — add status, lock it down, replace the public SELECT policy.
-- ----------------------------------------------------------------------------
alter table public.venues
  add column if not exists status text not null default 'pending'
    check (status in ('pending','approved','rejected'));

-- Column-level lockdown so an owner can't self-approve via an otherwise
-- legitimate UPDATE/INSERT of their own row. venues has never had this
-- lockdown applied before (unlike gyms, see section 2) — Supabase's default
-- table-level grant to `authenticated` is still fully in place, so a bare
-- column-level REVOKE here would be a no-op per the project's own documented
-- lesson (20260906000000 section 5): REVOKE the table-level privilege
-- entirely first, THEN GRANT back only the real, in-use safe column list.
-- Column lists below were built by reading saveVenue() (index.html ~1465-1502)
-- — the only real insert/update call sites for this table: `fields = {name,
-- city, region, address, contact, description}`. `is_active` and `gym_id` are
-- deliberately excluded — neither is ever set directly by the client today
-- (is_active is trigger-managed by venues_block_delete_with_history();
-- gym_id has no form field) — add either deliberately later if a feature
-- needs it, same principle profiles_public's column list already follows.
revoke update on public.venues from authenticated, anon;
grant update (name, city, region, address, contact, description)
  on public.venues to authenticated;

revoke insert on public.venues from authenticated, anon;
grant insert (owner_id, name, city, region, address, contact, description)
  on public.venues to authenticated;

-- Dynamically look up and drop whatever permissive SELECT policy currently
-- exists on public.venues by its real name, rather than assuming the
-- "venues_select_public" name from 20260911000000 is still live verbatim —
-- same dynamic-lookup pattern this project already uses for profiles,
-- gym_members, and reels/reel_comments, per the documented lesson that a
-- live policy name can drift from what a tracked migration assumes.
do $$
declare
  names text[];
  nm text;
begin
  if not exists (select 1 from pg_tables where schemaname='public' and tablename='venues') then
    raise exception 'public.venues does not exist — apply 20260911000000_add_venue_rental_schema.sql first.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.venues'::regclass) then
    raise exception 'public.venues does not have RLS enabled — investigate before proceeding (20260911000000 should have enabled it; if it was never applied, apply that first).';
  end if;

  select coalesce(array_agg(policyname), '{}') into names
  from pg_policies
  where schemaname = 'public' and tablename = 'venues'
    and permissive = 'PERMISSIVE' and cmd = 'SELECT';

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'venues'
      and permissive = 'PERMISSIVE' and cmd = 'ALL'
  ) then
    raise exception 'public.venues has a permissive FOR ALL policy that also grants SELECT. Split it into explicit policies first, then re-run.';
  end if;

  foreach nm in array names loop
    execute format('drop policy %I on public.venues', nm);
    raise notice 'Dropped permissive SELECT policy on venues: %', nm;
  end loop;
end $$;

-- Deviation (a): ANDs status with the existing is_active soft-delete gate
-- instead of replacing it outright — see the header note above.
-- Deviation (b): adds an admin-visibility branch so the Admin Verification
-- Dashboard can list pending/rejected venues belonging to other users.
create policy "venues_select_approved_own_or_admin"
  on public.venues for select
  using (
    (status = 'approved' and is_active)
    or auth.uid() = owner_id
    or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin = true)
  );

-- Post-condition: confirm no other permissive SELECT/ALL policy survived.
do $$
declare leftover text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ') into leftover
  from pg_policies
  where schemaname = 'public' and tablename = 'venues'
    and permissive = 'PERMISSIVE' and cmd in ('SELECT','ALL')
    and policyname <> 'venues_select_approved_own_or_admin';
  if leftover is not null then
    raise exception 'Leftover permissive read policy on public.venues: %', leftover;
  end if;
end $$;

-- Only an admin (profiles.is_admin = true) may move a venue's status.
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
end;
$$;

-- ----------------------------------------------------------------------------
-- 2) GYMS — add status, confirm it's locked down, replace the public SELECT
--    policy.
-- ----------------------------------------------------------------------------
alter table public.gyms
  add column if not exists status text not null default 'pending'
    check (status in ('pending','approved','rejected'));

-- Unlike venues, gyms already had its table-level INSERT/UPDATE privilege
-- fully revoked and re-granted on an explicit safe-column list in
-- 20260906000000 (section 5, for verified_venue). Per Postgres's own
-- privilege model (and this project's own documented lesson on it), a
-- column-level grant list never automatically extends to a column added
-- later by ALTER TABLE — `status` therefore already has ZERO write privilege
-- for `authenticated`/`anon` the moment it's added, with no further action
-- needed. Restated explicitly below anyway (same column lists, so this is a
-- no-op re-run) so this migration is self-contained and a future reviewer
-- doesn't have to cross-reference 20260906000000 to confirm gyms.status is
-- write-protected.
revoke update on public.gyms from authenticated, anon;
grant update (name, location, sports, team, address, contact, bio, avatar_url)
  on public.gyms to authenticated;

revoke insert on public.gyms from authenticated, anon;
grant insert (owner_id, name, location, sports, team, address, contact, bio)
  on public.gyms to authenticated;

-- Dynamically look up and drop whatever permissive SELECT policy currently
-- exists on public.gyms. gyms predates every tracked migration in this repo
-- (no CREATE TABLE has ever been checked in for it — see LEARNINGS.md "open
-- questions"), so its real policy name is unknown and must not be guessed.
do $$
declare
  names text[];
  nm text;
begin
  if not exists (select 1 from pg_tables where schemaname='public' and tablename='gyms') then
    raise exception 'public.gyms does not exist — unexpected, investigate before proceeding.';
  end if;
  -- Same class of trap as gym_members (20260927000000): a table that "works"
  -- publicly today is equally consistent with "RLS disabled" as with "a
  -- permissive policy exists" — don't assume. If RLS turns out to be off,
  -- STOP: flipping it on here with only a SELECT policy, and no confirmed
  -- live INSERT/UPDATE/DELETE policies, would default-deny gym creation and
  -- editing entirely.
  if not (select relrowsecurity from pg_class where oid = 'public.gyms'::regclass) then
    raise exception 'public.gyms does not have RLS enabled. This migration only replaces the SELECT policy and assumes correct existing INSERT/UPDATE/DELETE policies already exist — investigate the live table manually (Studio -> gyms -> RLS) before proceeding. Enabling RLS here blind could break gym creation/editing for every user.';
  end if;

  select coalesce(array_agg(policyname), '{}') into names
  from pg_policies
  where schemaname = 'public' and tablename = 'gyms'
    and permissive = 'PERMISSIVE' and cmd = 'SELECT';

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'gyms'
      and permissive = 'PERMISSIVE' and cmd = 'ALL'
  ) then
    raise exception 'public.gyms has a permissive FOR ALL policy that also grants SELECT. Split it into explicit policies first, then re-run.';
  end if;

  foreach nm in array names loop
    execute format('drop policy %I on public.gyms', nm);
    raise notice 'Dropped permissive SELECT policy on gyms: %', nm;
  end loop;
end $$;

-- Deviation (b): same admin-visibility branch as venues, for the same reason.
create policy "gyms_select_approved_own_or_admin"
  on public.gyms for select
  using (
    status = 'approved'
    or auth.uid() = owner_id
    or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin = true)
  );

do $$
declare leftover text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ') into leftover
  from pg_policies
  where schemaname = 'public' and tablename = 'gyms'
    and permissive = 'PERMISSIVE' and cmd in ('SELECT','ALL')
    and policyname <> 'gyms_select_approved_own_or_admin';
  if leftover is not null then
    raise exception 'Leftover permissive read policy on public.gyms: %', leftover;
  end if;
end $$;

-- Only an admin (profiles.is_admin = true) may move a gym's status.
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
end;
$$;

-- ----------------------------------------------------------------------------
-- 3) role_verification_requests — a new table, not a column on profiles.
--    Self-listed roles (Fighter/Coach/Official/Sponsor only — profiles.role
--    can theoretically hold other values like 'gym' from legacy code, but
--    saveRole() in index.html only ever writes these four) go through a
--    request row instead of a bare status column, since there's one profile
--    row per user regardless of role history and no natural place on
--    profiles itself to keep a reviewer note / audit trail per submission.
-- ----------------------------------------------------------------------------
create table if not exists public.role_verification_requests (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  requested_role text not null check (requested_role in ('fighter','coach','official','sponsor')),
  role_info jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  note text,
  created_at timestamptz not null default now(),
  -- Fix 2 (2026-10-02): separate "first submitted" from "last edited" so the
  -- admin queue can show a real freshness signal when an existing pending
  -- row gets updated in place instead of duplicated (see the UPDATE policy
  -- below). Defaults to created_at's value on insert; bumped explicitly by
  -- the client on every in-place edit.
  updated_at timestamptz not null default now()
);

create index if not exists role_verification_requests_profile_role_idx
  on public.role_verification_requests(profile_id, requested_role, created_at desc);

alter table public.role_verification_requests enable row level security;

-- A user can see their own requests (any status — they need to know if
-- they're pending/approved/rejected); an admin can see everyone's.
drop policy if exists "role_verification_requests_select_own_or_admin" on public.role_verification_requests;
create policy "role_verification_requests_select_own_or_admin"
  on public.role_verification_requests for select
  using (
    profile_id = auth.uid()
    or exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.is_admin = true)
  );

-- A user can submit a request for themselves, always starting 'pending' with
-- no reviewer fields pre-set — mirrors content_reports' "reporter can only
-- ever insert status='open'" pattern (20260925000000).
drop policy if exists "role_verification_requests_insert_own" on public.role_verification_requests;
create policy "role_verification_requests_insert_own"
  on public.role_verification_requests for insert
  with check (
    profile_id = auth.uid()
    and status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
  );

-- Column-level lockdown: status/reviewed_by/reviewed_at/note may ONLY ever
-- change via admin_set_role_request_status() or
-- admin_approve_unsubmitted_role() below (both SECURITY DEFINER, bypass RLS
-- and table grants). The REVOKE below still fully blocks a user from ever
-- touching those four columns.
--
-- Fix 2 (2026-10-02) changes what follows this line from the original
-- design: the original plan was "no UPDATE policy at all — a user who wants
-- to change their submission inserts a NEW row every time," relying on
-- profiles_public always reading the MOST RECENT matching request. In
-- practice that let three trivial edits produce three pending rows in the
-- admin queue with no way to tell them apart (PR #45 review, Issue B). Fix:
-- a narrow UPDATE policy that lets a user update ONLY (role_info,
-- updated_at) on ONLY their own ALREADY-PENDING row for ONE (profile_id,
-- requested_role) pair — status/reviewed_by/reviewed_at/note are excluded
-- from both the policy's WITH CHECK and the column grant below, so this
-- cannot be used to self-approve or tamper with review fields. index.html's
-- saveRole() checks for an existing pending row first and UPDATEs it instead
-- of inserting a new one when found; see that function for the small,
-- accepted race-window note (two near-simultaneous saves from the same user
-- could each insert, in the rare case both reads land before either write
-- commits — low-risk for a single-user profile-edit flow, not worth a
-- partial unique index for this fix).
revoke update on public.role_verification_requests from authenticated, anon;

drop policy if exists "role_verification_requests_update_own_pending" on public.role_verification_requests;
create policy "role_verification_requests_update_own_pending"
  on public.role_verification_requests for update
  using (profile_id = auth.uid() and status = 'pending')
  with check (profile_id = auth.uid() and status = 'pending' and reviewed_by is null and reviewed_at is null);

grant update (role_info, updated_at)
  on public.role_verification_requests to authenticated;

revoke insert on public.role_verification_requests from authenticated, anon;
grant insert (profile_id, requested_role, role_info, status)
  on public.role_verification_requests to authenticated;

-- Only an admin (profiles.is_admin = true) may approve/reject a role request.
-- Parameter is named `note` to match the signature index.html calls via
-- db.rpc('admin_set_role_request_status', {request_id, new_status, note}) —
-- PostgREST/RPC matches named parameters by their declared name. Internally
-- it's immediately assigned to a differently-named local variable (v_note)
-- purely to avoid an ambiguous reference against the identically-named
-- role_verification_requests.note column inside the UPDATE below; this has
-- no effect on the external call signature.
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
end;
$$;

-- Fix 1 (2026-10-02, Issue A): decision #2 drops every PRE-EXISTING
-- self-listed role to unverified with no role_verification_requests row ever
-- created for it (see the header note on decision #2 above) — there was no
-- queue entry for an admin to act on and no path back to a verified badge
-- for that user at all. This function is that path: it lets an admin approve
-- a (profile_id, requested_role) pair directly, synthesizing the first-ever
-- request row for it as already-approved, for the specific case where ZERO
-- role_verification_requests rows exist yet for that pair. index.html's
-- admin dashboard surfaces these as "Never submitted for review" (distinct
-- from a genuine pending row) and calls this function on approve/reject.
-- Deliberately also accepts 'rejected' (not approve-only) for symmetry with
-- admin_set_venue_status/admin_set_gym_status, which both accept either —
-- an admin may reasonably want to explicitly reject a never-submitted role
-- rather than leave it in limbo.
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

  -- Guard against a race (e.g. the user submits their own request, or
  -- another admin tab already acted, between this screen loading and this
  -- call) — if a row already exists for this exact pair, this is no longer
  -- the "never submitted" case and admin_set_role_request_status should be
  -- used on that real row instead, so the audit trail stays on one row.
  if exists (
    select 1 from public.role_verification_requests
    where profile_id = target_profile_id and requested_role = target_role
  ) then
    raise exception 'A verification request already exists for this profile and role — refresh the queue and use the normal approve/reject action on it instead.';
  end if;

  select role_info into v_role_info
  from public.profiles
  where id = target_profile_id and role = target_role;

  insert into public.role_verification_requests
    (profile_id, requested_role, role_info, status, reviewed_by, reviewed_at, note)
  values
    (target_profile_id, target_role, coalesce(v_role_info, '{}'::jsonb), new_status, auth.uid(), now(), note);
end;
$$;

-- ----------------------------------------------------------------------------
-- 4) profiles_public — add a computed role_verified column.
--    Must come AFTER role_verification_requests exists (section 3 above):
--    this is a plain SQL view, parse-validated against the schema at CREATE
--    time, so defining it before the table it references would abort with
--    "relation does not exist" (the same ordering trap documented for
--    `language sql` FUNCTION bodies in 20260911000000 — a plain VIEW
--    definition has the identical constraint).
--
--    Preserves every column the existing view already has (id, display_name,
--    username, avatar_url, role, role_info — see 20260906010000) and adds
--    exactly one new one.
--
--    Fix 4 (2026-10-02, Issue D) — Kaden's decision, confirmed directly and
--    final, not a guess: role_verified is true whenever ANY
--    role_verification_requests row exists for (profile_id, requested_role =
--    profiles.role) with status = 'approved' — regardless of whether a
--    newer PENDING request also exists for that same role. This replaces the
--    original "is the MOST RECENT matching request approved" computation,
--    which blanked a user's public badge the instant they resubmitted an
--    edit, even before an admin had looked at it. Concretely: an old
--    approved listing keeps showing publicly while a resubmitted edit for
--    the SAME role sits pending — only a REJECTED outcome on that review (or
--    switching to a genuinely different role, which naturally has no
--    approved row yet) changes visibility. Do not revert this to a
--    "latest row wins" computation without re-confirming with Kaden first.
--
--    ⚠️ MUST ALSO PRESERVE `where is_active` — this view's definition was
--    already updated once since 20260906010000, by 20260925020000 (account
--    deactivation), which added a `where is_active` filter so a deactivated
--    account disappears from the directory/gym rosters/DM pickers. A plain
--    `drop view ... create view ...` that copies the ORIGINAL 20260906010000
--    body without also carrying that filter forward would silently undo the
--    deactivation fix the moment this migration applies — the account
--    reappears everywhere, with no error anywhere. The select below includes
--    `where p.is_active` for exactly this reason; do not drop it.
--
--    ⚠️ SECURITY DEFINER BY DESIGN — DO NOT ADD security_invoker = true, for
--    the exact reason documented in 20260906010000: profiles' only SELECT
--    policy is owner-only, so an invoker-rights view would silently return
--    zero rows for every "look up someone else" query. Dropping and
--    recreating the view also resets its grants, which is why the explicit
--    GRANT SELECT is restated below (same as the original migration did).
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'is_active'
  ) then
    raise exception 'public.profiles.is_active does not exist — apply 20260925020000_add_account_deactivation.sql first, or this view redefinition will silently drop the deactivation filter.';
  end if;
end $$;

drop view if exists public.profiles_public;
create view public.profiles_public as
select
  p.id,
  p.display_name,
  p.username,
  p.avatar_url,
  p.role,
  p.role_info,
  -- Fix 4 (2026-10-02, Issue D, confirmed with Kaden, final — see the note
  -- above): true if ANY approved request exists for this role, not just the
  -- most recent request.
  exists (
    select 1
    from public.role_verification_requests rvr
    where rvr.profile_id = p.id and rvr.requested_role = p.role and rvr.status = 'approved'
  ) as role_verified
from public.profiles p
where p.is_active;

grant select on public.profiles_public to anon, authenticated;

notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- NOT included in this migration, deliberately:
-- 1. No change to profiles.role's meaning or how it's assigned — confirmed
--    against the hard guardrail; saveRole()/clearRole() are untouched here.
-- 2. No bulk-approval of any existing venue/gym/role — decision #2 is
--    "everyone drops to pending," enforced purely by the column default, with
--    zero rows pre-approved by this file. Re-approving the real pre-launch
--    backlog is a one-time admin task through the rewired dashboard, not a
--    migration concern.
-- 3. No participation-gating (e.g. blocking an unverified fighter from
--    claiming a bout slot) — this is visibility-only, per
--    VERIFICATION-GATE-DESIGN.md §3.3 / decision 9. That enforcement point
--    doesn't exist in real, non-demo code yet.
-- 4. No retroactive role_verification_requests rows synthesized for existing
--    self-listed roles BY THIS MIGRATION FILE — still true, this file
--    creates zero rows on apply. The 2026-10-02 follow-up (Fix 1 above) adds
--    admin_approve_unsubmitted_role() as the explicit, admin-triggered path
--    for creating that first row per profile/role — one deliberate action
--    per case, not a blanket automatic backfill run by this migration.
-- ----------------------------------------------------------------------------
