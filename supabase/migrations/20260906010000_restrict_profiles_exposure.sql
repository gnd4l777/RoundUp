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
-- ⚠️ VERIFY BEFORE APPLYING — POLICY NAME UNKNOWN: I cannot see the live
-- policy definitions currently on `public.profiles` from this session (same
-- limitation flagged in 20260905000000_add_events_tables.sql for `gyms`; no
-- prior migration file exists in this repo for the original CREATE TABLE /
-- CREATE POLICY of `profiles`, so its current policy name is a guess, not a
-- confirmed fact). `drop policy if exists` is a no-op if the name doesn't
-- match, which means the OLD permissive policy could silently remain active
-- side-by-side with the new owner-only one — and Postgres RLS policies are
-- OR'd together, so a leftover permissive policy would completely defeat this
-- fix with no error anywhere. Below, this migration drops every commonly-
-- guessed name for the existing policy, but Kaden MUST open Studio ->
-- Authentication -> Policies -> profiles (or run
-- `select policyname from pg_policies where tablename = 'profiles';`) BEFORE
-- applying this, confirm the real current SELECT policy name(s), and add an
-- explicit `drop policy if exists "<real name>" on public.profiles;` line for
-- any name not already guessed below if needed.
--
-- ⚠️⚠️ APPLY TOGETHER WITH THE index.html CHANGES IN THIS SAME PR ⚠️⚠️
-- This is NOT a schema-only, safe-to-apply-early migration like the earlier
-- ones this session (events, roster/follow/review). `profiles` is a real,
-- live table already read by real, shipped features. If this migration is
-- applied WITHOUT also deploying the matching index.html change (repointing
-- every "someone else's profile" read from `profiles` to `profiles_public`),
-- the directory, profile-viewing, gym rosters, and DM contact pickers will
-- ALL break immediately for every real user the moment this migration is
-- applied — they'd suddenly be querying a table they no longer have
-- permission to read other users' rows from, with those UI sections going
-- blank/erroring. Apply the migration and merge/deploy the index.html PR
-- back-to-back, not the migration alone first.
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
alter table public.profiles enable row level security;

-- Guessed/likely names for whatever permissive policy currently allows
-- anon/authenticated to read every column of every row. Each is a no-op if
-- the name doesn't match — see the VERIFY BEFORE APPLYING warning above.
-- Kaden: confirm the real name in Studio and add it explicitly if it isn't
-- one of these.
drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "Public profiles are viewable by everyone" on public.profiles;
drop policy if exists "Enable read access for all users" on public.profiles;
drop policy if exists "profiles_select_all" on public.profiles;
drop policy if exists "profiles_select_public" on public.profiles;
drop policy if exists "Allow public read access" on public.profiles;
drop policy if exists "select_profiles" on public.profiles;

create policy "profiles_select_own"
  on public.profiles for select
  using (auth.uid() = id);

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
