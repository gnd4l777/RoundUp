-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Do not run against production.
-- Written for review only. Kaden applies this himself from his own machine
-- once he's reviewed it (e.g. via `supabase db push` or the Studio SQL editor).
-- ============================================================================
--
-- Purpose: schema foundation for wiring real (Supabase-backed) accounts to
-- features that today only work against the legacy demo-data layer in
-- index.html. This migration does NOT touch index.html or any application
-- code — that is separate, later follow-up work. This is the schema draft
-- only, covering four related pieces:
--   1) gym_members.member_role — distinguish a coach's membership from a
--      fighter's, so "this coach's fighters" becomes a real derivable query.
--   2) follows.followee_type + follows.tier — extend the existing follows
--      table to cover gyms (venues/promoters) as well as profiles, and leave
--      room for a future paid-follow tier (schema only, no payment logic).
--   3) public.venue_reviews — a new, real reviews table for gyms.
--   4) gyms.verified_venue — an admin-set certification badge, no reputation
--      score column (that formula isn't decided yet — see note at the bottom
--      of section 3).
--
-- Conventions matched from the existing events migration
-- (20260905000000_add_events_tables.sql): snake_case columns, `created_at
-- timestamptz default now()`, `drop policy if exists` before every
-- `create policy` so a partial re-run doesn't die on "policy already
-- exists", `alter table ... add column if not exists` for idempotent column
-- additions, and ownership checks of the form `auth.uid() = <owner column>`.
--
-- ⚠️ VERIFY BEFORE APPLYING — gyms.id / profiles.id / gym_members.id column
-- types: as in the events migration, every FK below to public.gyms(id) and
-- auth.users(id) is typed `uuid`, inferred from the `gen_random_uuid()`
-- convention used elsewhere and from index.html always handling these ids as
-- opaque strings (never doing numeric arithmetic on them). This has NOT been
-- confirmed against the live table definitions (no prior migration file
-- exists for gyms/profiles/gym_members/follows to check against). If any of
-- these are actually a different type in production, the FK columns below
-- will fail to apply and need their type changed to match first.
--
-- ⚠️ VERIFY BEFORE APPLYING — follows.followee_id FK target: this repo has
-- no CREATE TABLE for `follows` (it predates any migrations directory), and
-- every call site in index.html (search `db.from('follows')`) only ever
-- passes a profile id as followee_id — there is no existing call that passes
-- a gym id. It is plausible (maybe even likely, given the naming and the
-- app's history as a fighter-only follow feature) that followee_id currently
-- carries a live foreign-key constraint straight to `profiles(id)`, which
-- would reject any row where followee_id is a gym id. Do NOT assume this
-- migration's ALTER TABLE additions below are sufficient on their own —
-- before relying on gym-follows working, Kaden should check the live
-- constraint (Studio → Database → Tables → follows → foreign keys, or
-- `select conname, pg_get_constraintdef(oid) from pg_constraint where
-- conrelid = 'public.follows'::regclass`) and, if a profiles(id)-only FK
-- exists, drop and replace it with something that allows either
-- profiles(id) or gyms(id) (e.g. drop the FK entirely and enforce
-- referential integrity at the application layer, or add a trigger) as a
-- follow-up to this migration, not assumed to already be handled here.
--
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) gym_members.member_role — coach-fighter roster relationship.
--
--    Today gym_members (id, gym_id, user_id, status) has no way to tell a
--    coach's membership row apart from a fighter's or a plain member's, so
--    "this coach's fighters" cannot be derived from real data at all — it's
--    demo data only. Adding member_role lets that become a real, derivable
--    relationship: "user A's fighters" = "profiles with an approved
--    gym_members row where member_role='fighter', in any gym where user A
--    also has an approved gym_members row with member_role='coach'".
--
--    Nullable with a default of 'member' rather than a hard NOT NULL, so
--    existing rows (all of which predate this column) don't need a backfill
--    decision made here — 'member' is a safe, neutral default that doesn't
--    silently promote anyone to 'coach' or 'fighter' status they never
--    actually had.
--
--    No application code reads or writes this column yet — that's separate,
--    later follow-up work once "coach's fighters" actually gets built.
-- ----------------------------------------------------------------------------
alter table public.gym_members
  add column if not exists member_role text default 'member';

-- Postgres has no `add constraint if not exists`, so guard the constraint
-- add with a catalog check instead, matching the idempotency intent of the
-- events migration's `drop policy if exists` pattern (constraints don't
-- support drop-if-exists-then-create as cleanly as policies do, so this is
-- the equivalent safe-guard for a re-run).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'gym_members_member_role_check'
      and conrelid = 'public.gym_members'::regclass
  ) then
    alter table public.gym_members
      add constraint gym_members_member_role_check
      check (member_role in ('coach', 'fighter', 'member'));
  end if;
end $$;

create index if not exists gym_members_role_idx
  on public.gym_members(gym_id, member_role)
  where status = 'approved';

-- ----------------------------------------------------------------------------
-- 2) follows — extend to venues/promoters (gyms), plus a future paid-tier
--    column.
--
--    followee_type: today every call site in index.html
--    (db.from('follows').insert({follower_id, followee_id})) only ever
--    passes a profile id — following a gym isn't wired up anywhere yet. This
--    column lets the SAME table represent both, rather than adding a second
--    parallel gym_follows table: 'profile' for following a fighter/creator,
--    'gym' for following a venue or promoter (both venues and promoters are
--    rows in the `gyms` table in this schema — there is no separate
--    promoters table).
--
--    not null default 'profile' so every existing row (all of which are
--    profile-follows today, per the call-site check above) is correctly
--    classified with no backfill step needed, and so new inserts that don't
--    yet know about this column (until application code catches up) keep
--    working exactly as before.
--
--    tier: forward-compatibility for a future paid-follow tier. Nothing sets
--    this to 'paid' anywhere — there is no checkout/payment logic in this
--    migration or anywhere else yet, and none is being added here. This
--    purely reserves a column so that when a real payment feature exists
--    later (a deliberate, separate decision — see project guardrails), "paid
--    follow = subscription" can slot into this existing column instead of
--    requiring a new table and a data migration at that point.
-- ----------------------------------------------------------------------------
alter table public.follows
  add column if not exists followee_type text not null default 'profile';

alter table public.follows
  add column if not exists tier text not null default 'free';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'follows_followee_type_check'
      and conrelid = 'public.follows'::regclass
  ) then
    alter table public.follows
      add constraint follows_followee_type_check
      check (followee_type in ('profile', 'gym'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'follows_tier_check'
      and conrelid = 'public.follows'::regclass
  ) then
    alter table public.follows
      add constraint follows_tier_check
      check (tier in ('free', 'paid'));
  end if;
end $$;

create index if not exists follows_followee_idx
  on public.follows(followee_id, followee_type);

-- ----------------------------------------------------------------------------
-- 3) public.venue_reviews — a real reviews table for gyms (venues/promoters).
--
--    One review per (gym_id, reviewer_id) via a unique constraint, so a
--    reviewer can't spam multiple reviews for the same venue. Editing an
--    existing review instead of inserting a new one is an application-layer
--    concern for later (an upsert against this unique pair, or a dedicated
--    "edit my review" call) — this migration only makes the schema enforce
--    the one-per-pair rule, it doesn't build that UI/flow.
--
--    body is nullable — rating-only reviews (a star rating with no written
--    text) are explicitly allowed per the task, so no NOT NULL here.
--
--    Gym-owner self-review: the task asks for "no review from the gym's own
--    owner_id", ideally as a DB-level check. A CHECK constraint can't
--    reference another table (Postgres CHECK constraints must be row-local,
--    no subqueries), so this is enforced via a BEFORE INSERT/UPDATE trigger
--    below instead of a plain check constraint — this keeps the guarantee at
--    the database level (not just app-layer, matching the spirit of the
--    ask) while working within what Postgres check constraints can actually
--    express.
-- ----------------------------------------------------------------------------
create table if not exists public.venue_reviews (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete cascade,
  reviewer_id uuid not null references auth.users(id) on delete cascade,
  rating integer not null check (rating between 1 and 5),
  body text,
  created_at timestamptz not null default now(),
  unique (gym_id, reviewer_id)
);

create index if not exists venue_reviews_gym_id_idx on public.venue_reviews(gym_id);
create index if not exists venue_reviews_reviewer_id_idx on public.venue_reviews(reviewer_id);

-- Enforce "no review from the gym's own owner_id" at the database level,
-- since a plain CHECK constraint can't look up gyms.owner_id for the row
-- being inserted.
create or replace function public.venue_reviews_block_owner_self_review()
returns trigger
language plpgsql
as $$
begin
  if exists (
    select 1 from public.gyms g
    where g.id = new.gym_id and g.owner_id = new.reviewer_id
  ) then
    raise exception 'A gym owner cannot review their own venue.';
  end if;
  return new;
end;
$$;

drop trigger if exists venue_reviews_block_owner_self_review_trg on public.venue_reviews;
create trigger venue_reviews_block_owner_self_review_trg
  before insert or update on public.venue_reviews
  for each row execute function public.venue_reviews_block_owner_self_review();

alter table public.venue_reviews enable row level security;

-- Public trust signal: anyone (including anon) can read all reviews.
drop policy if exists "venue_reviews_select_all" on public.venue_reviews;
create policy "venue_reviews_select_all"
  on public.venue_reviews for select
  using (true);

-- Only the reviewer can write their own review row. The self-review trigger
-- above is the actual enforcement for "not the gym's own owner" — this
-- policy just scopes insert/update/delete to the review's own author.
drop policy if exists "venue_reviews_insert_own" on public.venue_reviews;
create policy "venue_reviews_insert_own"
  on public.venue_reviews for insert
  with check (auth.uid() = reviewer_id);

drop policy if exists "venue_reviews_update_own" on public.venue_reviews;
create policy "venue_reviews_update_own"
  on public.venue_reviews for update
  using (auth.uid() = reviewer_id)
  with check (auth.uid() = reviewer_id);

drop policy if exists "venue_reviews_delete_own" on public.venue_reviews;
create policy "venue_reviews_delete_own"
  on public.venue_reviews for delete
  using (auth.uid() = reviewer_id);

-- NOTE ON REPUTATION SCORING (intentionally NOT built here): this migration
-- does not add any stored "reputation score" column to gyms. The actual
-- scoring formula (how venue_reviews ratings, the extended follows table,
-- and — eventually — real booking/rental volume combine into a single
-- reputation number) has not been decided yet, and inventing one now would
-- be building ahead of a real design decision that isn't this migration's
-- call to make. When that formula is decided, it should most likely be
-- computed on read (a view or a function) from public.venue_reviews +
-- public.follows (where followee_type='gym') + future booking data, not
-- stored as a column that would then need to be kept in sync by triggers or
-- batch jobs. Revisit this note when that design decision actually happens.

-- ----------------------------------------------------------------------------
-- 4) gyms.verified_venue — admin-set certification badge.
--
--    Mirrors the existing fighter-verification pattern (a plain pass/fail
--    boolean, not a score). Defaults to false; nothing in this migration or
--    elsewhere sets it to true anywhere — that's an admin action wired up in
--    a later, separate application-code task.
-- ----------------------------------------------------------------------------
alter table public.gyms
  add column if not exists verified_venue boolean not null default false;

-- ----------------------------------------------------------------------------
-- NOT included in this draft, deliberately, as open questions for Kaden:
--
-- 1. The follows.followee_id FK-target question flagged at the top of this
--    file (verify whether it's currently profiles(id)-only before relying on
--    gym-follows actually working) is the single biggest risk in this
--    migration — everything else here applies cleanly regardless, but a
--    gym-follow insert will fail at the database level until that's checked.
-- 2. gym_members.member_role is nullable/default-'member' with no backfill
--    of existing rows to 'coach' or 'fighter' — every existing membership
--    row will read as 'member' until something (an admin action, or an
--    inference from gyms.owner_id / some other future signal) actually
--    populates 'coach' rows. No such backfill is attempted here.
-- 3. Whether a gym owner should also be implicitly treated as that gym's
--    'coach' (so they don't need a separate gym_members row of their own) is
--    left open — this migration only adds the column and constraint, not
--    any inference logic connecting gyms.owner_id to gym_members.member_role.
-- ----------------------------------------------------------------------------
