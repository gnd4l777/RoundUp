-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself. Do not run this
-- against any database from this session or any automated tool.
--
-- ORDERING: must be applied AFTER
-- 20260925000000_add_user_blocks_and_content_reports.sql — this migration
-- alters the content_reports policy that file creates, and will fail with
-- "relation does not exist" if run first.
-- ============================================================================
--
-- Purpose: Kaden asked how to grant admin access to other people as he
-- brings on a small team ahead of a public launch, and specifically wants a
-- lighter tier for people who should be able to moderate (resolve reports,
-- delete abusive content) without full admin power (venue verification, gym
-- certification). Today there is only one gate anywhere in this schema —
-- profiles.is_admin — checked in four places (admin_set_venue_space_verification,
-- the gym-certification function, content_reports' admin policies, and the
-- client's window.ruIsAdmin). This migration adds a second, narrower flag
-- and a safe in-app way to grant/revoke both, replacing "ask Kaden to run
-- SQL by hand every time."
--
-- IMPORTANT FINDING, fixed here: profiles.is_admin has NEVER had a
-- column-level write lockdown in any tracked migration. 20260906010000
-- (the profiles exposure fix) explicitly left INSERT/UPDATE untouched
-- ("every write call site already writes only its own row"), which is true
-- for the columns real code writes — but it means nothing has ever stopped
-- a client from calling `.update({is_admin: true}).eq('id', auth.uid())`
-- directly against the anon-key REST API, if the live UPDATE policy is
-- row-scoped only (`auth.uid() = id`) without a column restriction — the
-- exact "RLS is row-level, not column-level" gap this project already hit
-- once for gyms.verified_venue (PR #17). This migration closes that gap the
-- same way: revoke table-level INSERT/UPDATE from authenticated, re-grant
-- only the columns every real call site actually writes (confirmed by
-- grepping every `.from('profiles')` call site in index.html: display_name,
-- avatar_url, role, role_info, username, plus id at insert time).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) The new column
-- ----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists is_moderator boolean not null default false;

-- ----------------------------------------------------------------------------
-- 2) Column-level lockdown on profiles INSERT/UPDATE (see finding above).
--    Deliberately excludes: id (insert-only, and even then must equal
--    auth.uid() per the existing insert policy), is_admin, is_moderator,
--    verification_requested (referenced in prior migration comments as a
--    future admin-only field, not currently written by any client call
--    site — left out on the same "add it deliberately when a feature needs
--    it" principle as profiles_public's column list), created_at.
-- ----------------------------------------------------------------------------
revoke insert, update on public.profiles from authenticated, anon;

grant insert (
  id, username, display_name
) on public.profiles to authenticated;

grant update (
  username, display_name, avatar_url, role, role_info
) on public.profiles to authenticated;

-- ----------------------------------------------------------------------------
-- 3) admin_set_user_role() — the ONLY path that may ever change is_admin or
--    is_moderator. Same SECURITY DEFINER pattern as
--    admin_set_venue_space_verification() (20260911000000). Caller must
--    already be a real admin — a moderator cannot promote anyone, including
--    themselves, to admin or moderator.
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_user_role(target_user_id uuid, make_admin boolean, make_moderator boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_count int;
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'Only an admin can change another user''s role.';
  end if;

  -- Guard against locking everyone out: if this call would remove admin from
  -- the last remaining admin account (including an admin demoting
  -- themselves), block it rather than leaving the platform with zero admins
  -- and no remaining way to grant it back in-app.
  if make_admin = false then
    select count(*) into admin_count from public.profiles where is_admin = true;
    if admin_count <= 1 and exists (
      select 1 from public.profiles where id = target_user_id and is_admin = true
    ) then
      raise exception 'Cannot remove admin from the last remaining admin account.';
    end if;
  end if;

  update public.profiles
    set is_admin = make_admin,
        is_moderator = make_moderator
    where id = target_user_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4) Extend content_reports so a moderator (not just an admin) can see and
--    resolve the queue. Replaces the two policies from
--    20260925000000_add_user_blocks_and_content_reports.sql with versions
--    that also check is_moderator. Venue verification and gym certification
--    are deliberately NOT touched anywhere in this file — those stay
--    admin-only, per Kaden's explicit split between full admin and
--    moderator.
-- ----------------------------------------------------------------------------
drop policy if exists "content_reports_select_own_or_admin" on public.content_reports;
create policy "content_reports_select_own_or_admin"
  on public.content_reports for select
  using (
    auth.uid() = reporter_id
    or exists (select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_moderator = true))
  );

drop policy if exists "content_reports_update_admin" on public.content_reports;
create policy "content_reports_update_admin"
  on public.content_reports for update
  using (exists (select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_moderator = true)))
  with check (exists (select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_moderator = true)));

-- ----------------------------------------------------------------------------
-- 5) Let a moderator (or admin) delete a reel/comment that isn't their own,
--    for acting on an actioned report. Neither public.reels nor
--    public.reel_comments has ever appeared in a tracked migration in this
--    repo — both were created directly in the Supabase dashboard, so their
--    current policies are unverified from here. Guard hard instead of
--    guessing: abort if RLS isn't already enabled on either table (this
--    migration only adds a DELETE policy; it does not stand up a full
--    SELECT/INSERT policy set, so RLS being off would mean enabling it here
--    defaults-denies reads/inserts too and breaks the live reels feed — the
--    same class of mistake flagged in this project's own migration-review
--    lessons). If this aborts, the live schema needs a human to look at it
--    before this section can be written safely.
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_tables where schemaname='public' and tablename='reels') then
    raise exception 'public.reels does not exist in this database — check the live schema before applying this migration.';
  end if;
  if not exists (select 1 from pg_tables where schemaname='public' and tablename='reel_comments') then
    raise exception 'public.reel_comments does not exist in this database — check the live schema before applying this migration.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.reels'::regclass) then
    raise exception 'public.reels does not have RLS enabled. This migration only adds a DELETE policy and assumes correct existing SELECT/INSERT policies — investigate the live table manually before proceeding.';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.reel_comments'::regclass) then
    raise exception 'public.reel_comments does not have RLS enabled. This migration only adds a DELETE policy and assumes correct existing SELECT/INSERT policies — investigate the live table manually before proceeding.';
  end if;
end $$;

-- reels: dynamically drop whatever permissive DELETE policy already exists
-- (same safe pattern as 20260906020000's messages fix) rather than guessing
-- its name, then install the intended one.
do $$
declare
  names text[];
  nm text;
begin
  select coalesce(array_agg(policyname), '{}') into names
  from pg_policies
  where schemaname = 'public' and tablename = 'reels'
    and permissive = 'PERMISSIVE' and cmd = 'DELETE';

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'reels'
      and permissive = 'PERMISSIVE' and cmd = 'ALL'
  ) then
    raise exception 'public.reels has a permissive FOR ALL policy that also grants DELETE. Split it into explicit policies first, then re-run.';
  end if;

  foreach nm in array names loop
    execute format('drop policy %I on public.reels', nm);
    raise notice 'Dropped permissive DELETE policy on reels: %', nm;
  end loop;
end $$;

create policy "reels_delete_own_or_moderator"
  on public.reels for delete
  using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_moderator = true))
  );

-- reel_comments: identical treatment.
do $$
declare
  names text[];
  nm text;
begin
  select coalesce(array_agg(policyname), '{}') into names
  from pg_policies
  where schemaname = 'public' and tablename = 'reel_comments'
    and permissive = 'PERMISSIVE' and cmd = 'DELETE';

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'reel_comments'
      and permissive = 'PERMISSIVE' and cmd = 'ALL'
  ) then
    raise exception 'public.reel_comments has a permissive FOR ALL policy that also grants DELETE. Split it into explicit policies first, then re-run.';
  end if;

  foreach nm in array names loop
    execute format('drop policy %I on public.reel_comments', nm);
    raise notice 'Dropped permissive DELETE policy on reel_comments: %', nm;
  end loop;
end $$;

create policy "reel_comments_delete_own_or_moderator"
  on public.reel_comments for delete
  using (
    auth.uid() = author_id
    or exists (select 1 from public.profiles where id = auth.uid() and (is_admin = true or is_moderator = true))
  );

notify pgrst, 'reload schema';
