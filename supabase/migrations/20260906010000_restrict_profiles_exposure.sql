-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Do not run against production from this
-- session. Written for review only. Kaden applies this himself from his own
-- machine once he's reviewed it (e.g. via `supabase db push` or the Studio
-- SQL editor) — AND, critically, applies it TOGETHER with the matching
-- index.html changes in this same PR. See the "APPLY TOGETHER" warning below.
-- ============================================================================
--
-- CONFIRMED LIVE ISSUE, not a draft/theoretical one: an unauthenticated curl
-- against the real production Supabase REST API confirmed that `profiles` is
-- fully anon-readable today — `select=*` (or an explicit
-- `select=is_admin,verification_requested`) returns those columns for every
-- user row to anyone holding the public anon key, no login required. This is
-- almost certainly because `profiles` currently has a permissive SELECT RLS
-- policy along the lines of `using (true)` with no column-level restriction.
--
-- `is_admin` (who has admin powers) and `verification_requested` (a pending
-- verification flag) should never be readable for any row other than your
-- own. Every OTHER column on profiles (display_name, username, avatar_url,
-- role, role_info) IS meant to be publicly browsable — that's the entire
-- point of the directory, profile pages, gym rosters, and DM contact
-- pickers, all of which are live features today.
--
-- Fix, mirroring the events_bouts_public precedent already reviewed this
-- session (see 20260905000000_add_events_tables.sql for the exact style this
-- follows):
--   1. Lock the base `profiles` table's SELECT policy down to owner-only
--      (auth.uid() = id). No anon/authenticated blanket read policy remains.
--   2. Add a new view, `profiles_public`, exposing only the columns every
--      "look up someone else's profile" call site in index.html actually
--      uses: id, display_name, username, avatar_url, role, role_info. This
--      was verified directly against index.html by grepping every single
--      `.from('profiles')` call site — every one of them already requests
--      only a safe, explicit column list (never `select=*`), and the ONLY
--      call that ever reads `is_admin` is scoped to the logged-in user's own
--      row via `.eq('id', <their own id>)` right after login. No call site
--      requests `verification_requested` at all today.
--   3. Grant SELECT on the view to anon/authenticated so those same features
--      keep working once the base table stops allowing it directly.
--
-- ⚠️ POLICY LOOKUP IS NOW DYNAMIC, NOT GUESSED: earlier drafts of this
-- migration dropped a hand-guessed list of common policy names (e.g.
-- `"Public profiles are viewable by everyone"`). That was found to be
-- unsafe: Supabase's own starter template names this policy
-- `"Public profiles are viewable by everyone."` — WITH a trailing period —
-- which the guess list did not include, so it would have silently no-op'd
-- and left the real leak fully open with no error anywhere. This migration
-- now queries `pg_policies` directly for every permissive SELECT policy on
-- `public.profiles` and drops each by its actual name, whatever it is. See
-- the DO block below.
--
-- ⚠️⚠️ APPLYING EITHER HALF OF THIS FIX ALONE BREAKS REAL FUNCTIONALITY —
-- NOT JUST "DOESN'T HELP" — FOR EVERY REAL USER ⚠️⚠️
-- `profiles` is a real, live table already read by real, shipped features.
-- These two halves must be deployed back-to-back, not one first and the
-- other "later":
--   - Applying this MIGRATION without the matching index.html change: every
--     "someone else's profile" read still queries `profiles` directly, which
--     no longer grants that access — the directory, profile pages, gym
--     rosters, and DM contact pickers all go blank/empty for every user, with
--     no thrown error anywhere (RLS just filters rows out silently).
--   - Deploying the index.html CHANGE (pointed at `profiles_public`) without
--     this migration applied: the view doesn't exist yet, so those same
--     screens break the same way, just for the opposite reason (querying a
--     view that isn't there instead of a table that won't return rows).
-- Both directions fail silently with empty data, not a visible error — so a
-- partial deploy can look "fine" at a glance while every affected screen is
-- actually broken for real users. Apply the migration and merge/deploy the
-- index.html PR together, back-to-back.
--
-- After applying this migration, run `notify pgrst, 'reload schema';` (or
-- simply wait a moment) before spot-checking `profiles_public` — PostgREST
-- caches the schema and needs to pick up the new view before it will resolve
-- requests against it. Checking immediately after applying, before the cache
-- refreshes, can look like the fix failed (404/relation not found) when it
-- actually just hasn't picked up the new view yet.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Lock down the base table: only the row's owner can SELECT it directly.
--    This is what makes is_admin/verification_requested stop being anon-
--    readable — nothing else needs those two columns except the user
--    themselves (and admin-gated security-definer functions elsewhere in
--    this codebase, e.g. admin_set_venue_verification() in
--    20260906000000_roster_follow_review_verify_schema.sql, which bypass RLS
--    entirely as security definer and are unaffected by this change).
-- ----------------------------------------------------------------------------
-- Guard: if profiles currently has no INSERT/UPDATE policy at all, that
-- means writes are working today via RLS being disabled entirely (not via a
-- permissive policy) — in which case flipping RLS on below with only a
-- SELECT policy would leave zero INSERT/UPDATE coverage and silently break
-- the post-login profile upsert, profile edits, and role saving. Abort
-- before enabling RLS if either is missing.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='profiles' and cmd in ('INSERT','ALL')) then
    raise exception 'public.profiles has no INSERT policy; enabling RLS would break the post-login profile upsert.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='profiles' and cmd in ('UPDATE','ALL')) then
    raise exception 'public.profiles has no UPDATE policy; enabling RLS would break profile edits and role saving.';
  end if;
end $$;

alter table public.profiles enable row level security;

-- Dynamically look up and drop every permissive SELECT policy on
-- public.profiles by its real name, whatever that name actually is — see
-- the "POLICY LOOKUP IS NOW DYNAMIC" note above for why a guessed name list
-- is not safe here. Aborts instead of dropping if it finds a permissive
-- FOR ALL policy, since blind-dropping that would also strip whatever
-- INSERT/UPDATE/DELETE coverage rides along with it, which isn't this fix's
-- call to make.
do $$
declare
  names text[];
  nm text;
begin
  select coalesce(array_agg(policyname), '{}')
    into names
  from pg_policies
  where schemaname = 'public' and tablename = 'profiles'
    and permissive = 'PERMISSIVE' and cmd = 'SELECT';

  foreach nm in array names loop
    execute format('drop policy %I on public.profiles', nm);
    raise notice 'Dropped permissive SELECT policy: %', nm;
  end loop;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'profiles'
      and permissive = 'PERMISSIVE' and cmd = 'ALL'
  ) then
    raise exception 'public.profiles has a permissive FOR ALL policy that still grants public SELECT. Split it into explicit INSERT/UPDATE/DELETE policies first, then re-run.';
  end if;
end $$;

create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

-- Post-condition: confirm no other permissive SELECT/ALL policy survived the
-- drop loop above (e.g. one created after this migration was drafted, or
-- named in a way that somehow slipped past the pg_policies query). Postgres
-- RLS policies are OR'd together, so any leftover permissive read policy
-- would completely defeat this fix with no error anywhere else.
do $$
declare leftover text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ') into leftover
  from pg_policies
  where schemaname = 'public' and tablename = 'profiles'
    and permissive = 'PERMISSIVE' and cmd in ('SELECT','ALL')
    and policyname <> 'profiles_select_own';
  if leftover is not null then
    raise exception 'Leftover permissive read policy on public.profiles: %', leftover;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2) profiles_public — the only public-facing read surface for OTHER users'
--    profile data. Allowlists exactly the columns every "look up someone
--    else" call site in index.html actually selects today (verified by
--    grepping every `.from('profiles')` call site in index.html):
--      id, display_name, username, avatar_url, role, role_info
--    Deliberately EXCLUDES is_admin, verification_requested, bio, and any
--    other column not already in that confirmed-safe list. `bio` is left out
--    not because it's necessarily sensitive, but because no current call
--    site reads someone else's bio through this table — add it here later,
--    deliberately, if/when a feature needs it, rather than by default.
--
--    ⚠️ SECURITY DEFINER BY DESIGN — DO NOT ADD security_invoker = true.
--    This view deliberately has NO `WITH (security_invoker = true)` clause,
--    so it runs with the view owner's privileges rather than the querying
--    user's. That's required here: profiles' only SELECT policy is now
--    owner-only ("profiles_select_own"), so an invoker-rights view would
--    inherit that same restriction and any lookup of ANOTHER user's row
--    would silently return zero rows — no error anywhere, the directory,
--    profile pages, gym rosters, and DM pickers would just render empty.
--    Running as the view owner is what lets this view bypass that
--    base-table RLS and actually surface other users' safe public columns.
--    Supabase's built-in database linter (Advisors panel) WILL flag this as
--    a "Security Definer View" ERROR, same as events_bouts_public already
--    does. That warning is expected and, in this specific case, a false
--    positive — do not "fix" it by adding security_invoker = true.
-- ----------------------------------------------------------------------------
drop view if exists public.profiles_public;
create view public.profiles_public as
select
  id,
  display_name,
  username,
  avatar_url,
  role,
  role_info
from public.profiles;

grant select on public.profiles_public to anon, authenticated;

-- ----------------------------------------------------------------------------
-- NOT included in this migration, deliberately:
-- 1. No change to how `role` is assigned or what it means — this migration
--    only touches read access, not the account model.
-- 2. No RLS change to INSERT/UPDATE on profiles — every write call site in
--    index.html already writes only its own row (`.eq('id', user.id)` /
--    `.upsert({id: user.id, ...})`), so those are unaffected by this change
--    and are left exactly as they are.
-- ----------------------------------------------------------------------------
