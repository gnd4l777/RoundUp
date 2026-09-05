-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Do not run against production.
-- Written for review only. Kaden applies this himself from his own machine
-- once he's reviewed it (e.g. via `supabase db push` or the Studio SQL editor).
-- ============================================================================
--
-- Purpose: introduce a real `events` schema. Today, all events live only in
-- browser localStorage (`state.events` in index.html) and `hostGym` is just a
-- demo-user id, not a real foreign key. This migration does NOT wire index.html
-- up to these tables — that is a separate, larger follow-up task. This is the
-- schema draft only.
--
-- Design decision (per Kaden, "Option B"): bout-shaped (combat sports) events
-- and generic (non-combat) events live in two SEPARATE tables, not one shared
-- table with a category discriminator column. This keeps the combat-sports
-- core untouched and separate as the app expands into general event hosting.
--
-- Conventions matched from existing `gyms`/`profiles`/`gym_members` tables as
-- queried in index.html: snake_case columns, `created_at timestamptz default
-- now()`, ownership checks of the form `.eq('owner_id', user.id)`, and gym
-- rows/profile rows being readable by anyone (no `.eq` filter on SELECT calls
-- like `db.from('gyms').select('name').limit(200)` or the directory query at
-- `db.from('profiles').select(...).not('role','is',null).limit(500)`).
-- NOTE: I could not find the original CREATE TABLE for `gyms`/`profiles` in
-- this repo (no prior migrations directory existed), so the exact existing
-- RLS policies are inferred from query behavior in index.html, not confirmed
-- against the live policy definitions. Kaden should double check the policies
-- below against what's actually configured on `gyms` before applying.
--
-- ⚠️ VERIFY BEFORE APPLYING — gyms.id column type: every FK to public.gyms(id)
-- below is typed `uuid`, inferred from the `gen_random_uuid()` convention used
-- elsewhere in this file. This has NOT been confirmed against the live
-- `gyms` table definition (no prior migration file exists to check against).
-- If `gyms.id` is actually `text` (or anything else) in production, the
-- `gym_id uuid references public.gyms(id)` columns and the
-- `public.user_can_manage_gym(uuid)` function signature below will fail to
-- apply and need their type changed to match before this migration can run.
--
-- ============================================================================
-- REVISION (this version): addressed reviewer findings on the first draft:
--   1. Financial/officials columns on events_bouts were publicly SELECTable
--      via the old "published" policy — moved public read to a restricted
--      view (events_bouts_public) that excludes total_pay, sponsor_pool,
--      officials, and sponsor_tiers. The base table now has no anon-readable
--      policy at all; only the owner can SELECT the base table directly.
--   2. Insert policies only checked owner_id, not that the inserting user
--      actually controls the gym being attached — added
--      public.user_can_manage_gym(gym_id), checked in both insert and update
--      WITH CHECK clauses on both tables.
--   3. The public-read filter excluded status='completed', hiding past events
--      — changed to status in ('published','completed') everywhere public
--      read happens (events_general's policy, and events_bouts_public's
--      WHERE clause).
--   4. CREATE POLICY has no IF NOT EXISTS in Postgres — added
--      DROP POLICY IF EXISTS before every CREATE POLICY so a partial-failure
--      re-run doesn't die on "policy already exists".
--   5. Added columns for fields the current localStorage event shape actually
--      carries but this draft was missing: venue_listing,
--      venue_rental_fee_per_fighter, created_by_fighter, fighter_draft_card_id.
--   6. Added a check that `fights` can only ever hold a JSON array.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) Shared helper: does the current user control the given gym?
--    "Control" = owns it outright, OR is an approved member of it
--    (gym_members.status = 'approved') — gym_members already models
--    membership with an approval workflow (see index.html gym_members insert/
--    update calls), so team members of a gym can attach events to it too, not
--    just the single owner.
--    A null gym_id is allowed through (an event with no gym attached at all
--    isn't a gym-claiming concern).
-- ----------------------------------------------------------------------------
create or replace function public.user_can_manage_gym(check_gym_id uuid)
returns boolean
language sql
stable
as $$
  select check_gym_id is null
    or exists (
      select 1 from public.gyms g
      where g.id = check_gym_id and g.owner_id = auth.uid()
    )
    or exists (
      select 1 from public.gym_members gm
      where gm.gym_id = check_gym_id
        and gm.user_id = auth.uid()
        and gm.status = 'approved'
    );
$$;

-- ----------------------------------------------------------------------------
-- 1) events_general — non-combat events (weddings, reunions, tournaments, etc.)
--    No combat-specific fields. Kept intentionally generic.
-- ----------------------------------------------------------------------------
create table if not exists public.events_general (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid references public.gyms(id) on delete set null, -- see uuid-type warning above
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  description text,
  category text not null default 'other'
    check (category in ('wedding','reunion','tournament','other')),
  start_time timestamptz not null,
  end_time timestamptz,
  venue_name text,
  venue_address text,
  status text not null default 'draft'
    check (status in ('draft','published','cancelled','completed')),
  created_at timestamptz not null default now()
);

create index if not exists events_general_gym_id_idx on public.events_general(gym_id);
create index if not exists events_general_owner_id_idx on public.events_general(owner_id);
create index if not exists events_general_status_idx on public.events_general(status);

alter table public.events_general enable row level security;

-- Published AND completed events are publicly browsable (past events should
-- stay visible, not just upcoming ones). No sensitive columns exist on this
-- table, so a straight table-level policy is fine here (unlike events_bouts).
drop policy if exists "events_general_select_published_public" on public.events_general;
create policy "events_general_select_published_public"
  on public.events_general for select
  using (status in ('published','completed'));

-- Owners can always see their own events, including drafts.
drop policy if exists "events_general_select_own" on public.events_general;
create policy "events_general_select_own"
  on public.events_general for select
  using (auth.uid() = owner_id);

drop policy if exists "events_general_insert_own" on public.events_general;
create policy "events_general_insert_own"
  on public.events_general for insert
  with check (auth.uid() = owner_id and public.user_can_manage_gym(gym_id));

drop policy if exists "events_general_update_own" on public.events_general;
create policy "events_general_update_own"
  on public.events_general for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id and public.user_can_manage_gym(gym_id));

drop policy if exists "events_general_delete_own" on public.events_general;
create policy "events_general_delete_own"
  on public.events_general for delete
  using (auth.uid() = owner_id);

-- ----------------------------------------------------------------------------
-- 2) events_bouts — combat-sports events (mirrors current localStorage shape).
--    fights[] and officials{} are stored as JSONB rather than fully normalized
--    — see PR description / report for why.
--
--    IMPORTANT: this table holds financial fields (total_pay, sponsor_pool),
--    the officials assignment map, and sponsor_tiers (which embeds a
--    claimedBy field). None of these should be anon-readable — index.html
--    itself only shows the commission pool to the card owner (isOwner check
--    around the event-list rendering) and hides officials from fans. So this
--    table has NO public-read policy at all; public browsing goes through the
--    `events_bouts_public` view below instead, which allowlists only the
--    safe columns.
-- ----------------------------------------------------------------------------
create table if not exists public.events_bouts (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid references public.gyms(id) on delete set null, -- see uuid-type warning above
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  event_date date,
  event_time text,
  doors_time text,
  venue text,
  address text,
  -- Venue-rental fields for the "fighter books a gym's open venue slot, and
  -- the fighter-initiated card is created from that listing" flow (see
  -- createFighterInitiatedCard() / acceptVenueOffer() in index.html). Neither
  -- venue_listing nor fighter_draft_card_id are real FKs yet — venue listings
  -- currently live inside a gym's JSON blob (gym.venueListings) and fighter
  -- draft cards aren't a table at all, so both are stored as plain text ids
  -- here. Revisit as real FKs once those get their own tables.
  venue_listing text,
  venue_rental_fee_per_fighter numeric,
  -- The fighter who initiated this card from a venue listing (see
  -- createFighterInitiatedCard()/acceptVenueOffer() in index.html, where this
  -- is stored as a user id — not a boolean — because the initiating fighter
  -- is meant to keep some co-organizer access to the card they started. This
  -- column only records who that is; no access-control logic is being added
  -- here — that's a separate follow-up once the app is wired to this table.
  created_by_fighter uuid references auth.users(id) on delete set null,
  fighter_draft_card_id text,
  card_type text not null default 'amateur'
    check (card_type in ('amateur','women_amateur','pro_am')),
  sanctioning text,
  sanctioning_status text default 'not_submitted',
  -- Per-fight data (id, f1, f2, weight, weightClass, rounds, roundLen, tag) —
  -- weight class / rounds / round length are FIGHT-level, not event-level, in
  -- the existing localStorage shape (see e.g. index.html fight objects like
  -- {weightClass:'Welterweight', rounds:6, roundLen:3, ...}), so they live
  -- inside this array rather than as top-level columns on the event.
  fights jsonb not null default '[]'::jsonb
    check (jsonb_typeof(fights) = 'array'),
  -- Map of official role -> assigned user id, e.g.
  -- {"Referee":null,"Judge1":null,"Judge2":null,"Judge3":null,"Physician":null,
  --  "Timekeeper":null,"Announcer":null,"Inspector":null}
  -- NOT publicly readable — see events_bouts_public view below.
  officials jsonb not null default '{}'::jsonb,
  sponsors jsonb not null default '[]'::jsonb,
  -- sponsor_tiers embeds a claimedBy field per tier — NOT publicly readable
  -- (whole column excluded from events_bouts_public; JSONB makes redacting
  -- just claimedBy impractical at the column-grant level).
  sponsor_tiers jsonb not null default '[]'::jsonb,
  total_pay numeric not null default 0,
  sponsor_pool numeric not null default 0,
  status text not null default 'draft'
    check (status in ('draft','published','cancelled','completed')),
  created_at timestamptz not null default now()
);

create index if not exists events_bouts_gym_id_idx on public.events_bouts(gym_id);
create index if not exists events_bouts_owner_id_idx on public.events_bouts(owner_id);
create index if not exists events_bouts_status_idx on public.events_bouts(status);
-- Nice-to-have, cheap and correct given the jsonb-array check above: supports
-- future containment queries against the fight card (e.g. "any fight where
-- f1 = this user"). Not required for anything in this migration today.
create index if not exists events_bouts_fights_gin_idx on public.events_bouts using gin (fights);

alter table public.events_bouts enable row level security;

-- Owners can always see their own cards in full, including drafts and all
-- financial/officials fields. This is the ONLY select policy on the base
-- table — there is deliberately no anon/public-read policy here (see the
-- comment above the table). Public browsing uses events_bouts_public.
drop policy if exists "events_bouts_select_own" on public.events_bouts;
create policy "events_bouts_select_own"
  on public.events_bouts for select
  using (auth.uid() = owner_id);

drop policy if exists "events_bouts_insert_own" on public.events_bouts;
create policy "events_bouts_insert_own"
  on public.events_bouts for insert
  with check (auth.uid() = owner_id and public.user_can_manage_gym(gym_id));

drop policy if exists "events_bouts_update_own" on public.events_bouts;
create policy "events_bouts_update_own"
  on public.events_bouts for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id and public.user_can_manage_gym(gym_id));

drop policy if exists "events_bouts_delete_own" on public.events_bouts;
create policy "events_bouts_delete_own"
  on public.events_bouts for delete
  using (auth.uid() = owner_id);

-- ----------------------------------------------------------------------------
-- 2a) events_bouts_public — the only public-facing read surface for bouts.
--     Explicitly allowlists safe/browsable columns only. Deliberately
--     EXCLUDES: total_pay, sponsor_pool, officials, sponsor_tiers (financial
--     data and the officials role->user-id map — none of this is shown to
--     fans/anon in index.html today; see renderEventListItem()'s isOwner
--     check around the commission-pool display, and renderEventPublishedDetail
--     which hides the whole "Officials" section for role==='fan').
--
--     The status filter is applied directly in this view's own query (not
--     inherited from a base-table RLS policy), so it holds regardless of how
--     Postgres resolves RLS-vs-view-owner semantics — completed events stay
--     browsable alongside published ones, drafts/cancelled never appear.
-- ----------------------------------------------------------------------------
drop view if exists public.events_bouts_public;
create view public.events_bouts_public as
select
  id,
  gym_id,
  owner_id,
  name,
  event_date,
  event_time,
  doors_time,
  venue,
  address,
  venue_listing,
  venue_rental_fee_per_fighter,
  created_by_fighter,
  fighter_draft_card_id,
  card_type,
  sanctioning,
  sanctioning_status,
  fights,
  sponsors,
  status,
  created_at
from public.events_bouts
where status in ('published','completed');

-- New views aren't covered by whatever default-privilege grants already exist
-- for anon/authenticated on pre-existing tables — grant explicitly.
grant select on public.events_bouts_public to anon, authenticated;

-- ----------------------------------------------------------------------------
-- NOT included in this draft, deliberately, as open questions for Kaden:
--
-- 1. Officials assigned inside the `officials` JSONB (Referee/Judge1-3/
--    Physician/Timekeeper/Announcer/Inspector) currently see their own
--    assigned draft cards in index.html (state.events.filter(e=>
--    Object.values(e.officials).includes(myId) || e.status==='draft')).
--    Replicating that as an RLS SELECT policy is possible (a jsonb containment
--    check against auth.uid()::text) but adds real complexity for a
--    draft-only migration, so it's intentionally left out here — today an
--    assigned official would only see a draft card via the app's own
--    additional server-side query logic once that gets built, not via this
--    migration's RLS alone. Flagging this so it isn't forgotten in the
--    follow-up task that wires index.html to these tables. Same goes for
--    fighters/coaches who need to see officials once authenticated — the
--    events_bouts_public view intentionally does NOT solve this (it's
--    anon-safe only); an authenticated, row-scoped policy or view is a
--    separate follow-up.
-- 2. Whether gym members should get write access to events tied to gym_id is
--    now partially answered (see public.user_can_manage_gym — approved
--    members can insert/update, matching gym_members.status='approved'
--    already existing in this codebase). Whether they should also see a
--    gym's own drafts (not just the owner) is still open — left as
--    owner_id-only for SELECT on both tables for now.
-- ----------------------------------------------------------------------------
