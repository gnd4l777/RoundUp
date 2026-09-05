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
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) events_general — non-combat events (weddings, reunions, tournaments, etc.)
--    No combat-specific fields. Kept intentionally generic.
-- ----------------------------------------------------------------------------
create table if not exists public.events_general (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid references public.gyms(id) on delete set null,
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

-- Published events are publicly browsable (mirrors state.events.filter(status==='published')
-- being the public-facing set in index.html today).
create policy "events_general_select_published_public"
  on public.events_general for select
  using (status = 'published');

-- Owners can always see their own events, including drafts.
create policy "events_general_select_own"
  on public.events_general for select
  using (auth.uid() = owner_id);

create policy "events_general_insert_own"
  on public.events_general for insert
  with check (auth.uid() = owner_id);

create policy "events_general_update_own"
  on public.events_general for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

create policy "events_general_delete_own"
  on public.events_general for delete
  using (auth.uid() = owner_id);

-- ----------------------------------------------------------------------------
-- 2) events_bouts — combat-sports events (mirrors current localStorage shape).
--    fights[] and officials{} are stored as JSONB rather than fully normalized
--    — see PR description / report for why.
-- ----------------------------------------------------------------------------
create table if not exists public.events_bouts (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid references public.gyms(id) on delete set null,
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  event_date date,
  event_time text,
  doors_time text,
  venue text,
  address text,
  card_type text not null default 'amateur'
    check (card_type in ('amateur','women_amateur','pro_am')),
  sanctioning text,
  sanctioning_status text default 'not_submitted',
  -- Per-fight data (id, f1, f2, weight, weightClass, rounds, roundLen, tag) —
  -- weight class / rounds / round length are FIGHT-level, not event-level, in
  -- the existing localStorage shape (see e.g. index.html fight objects like
  -- {weightClass:'Welterweight', rounds:6, roundLen:3, ...}), so they live
  -- inside this array rather than as top-level columns on the event.
  fights jsonb not null default '[]'::jsonb,
  -- Map of official role -> assigned user id, e.g.
  -- {"Referee":null,"Judge1":null,"Judge2":null,"Judge3":null,"Physician":null,
  --  "Timekeeper":null,"Announcer":null,"Inspector":null}
  officials jsonb not null default '{}'::jsonb,
  sponsors jsonb not null default '[]'::jsonb,
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

alter table public.events_bouts enable row level security;

-- Published cards are publicly browsable (mirrors state.events.filter(status==='published')
-- being the public-facing fight card list in index.html today).
create policy "events_bouts_select_published_public"
  on public.events_bouts for select
  using (status = 'published');

-- Owners can always see their own cards, including drafts.
create policy "events_bouts_select_own"
  on public.events_bouts for select
  using (auth.uid() = owner_id);

create policy "events_bouts_insert_own"
  on public.events_bouts for insert
  with check (auth.uid() = owner_id);

create policy "events_bouts_update_own"
  on public.events_bouts for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

create policy "events_bouts_delete_own"
  on public.events_bouts for delete
  using (auth.uid() = owner_id);

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
--    follow-up task that wires index.html to these tables.
-- 2. Whether gym members (gym_members.status='approved'), not just the single
--    owner_id, should get write access to events tied to gym_id. Today in
--    index.html, hostGym is always set to the current demo user's own id, so
--    owner_id and "the gym" are the same actor — there's no existing pattern
--    of one person managing another's gym's events to copy. Left as
--    owner_id-only for now; easy to extend with an EXISTS-against-gyms policy
--    later if Kaden wants gym-team members to co-manage a gym's event slate.
-- ----------------------------------------------------------------------------
