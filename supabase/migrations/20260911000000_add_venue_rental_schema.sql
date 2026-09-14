-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Do not run against production.
-- Written for review only. Kaden applies this himself from his own machine
-- once he's reviewed it (e.g. via `supabase db push` or the Studio SQL editor).
-- This is Slice 1 from VENUE-RENTALS-AND-TAXONOMY-DESIGN.md §3.1 — schema
-- draft only, ships as a review artifact. Nothing in index.html calls any of
-- this yet; that's Slice 2, a separate follow-up once this is signed off.
-- ============================================================================
--
-- Purpose: task 4c. Implements Part 1 of VENUE-RENTALS-AND-TAXONOMY-DESIGN.md
-- (sports venue rentals — the Soccer City Tulsa model: an indoor facility
-- with N rentable spaces; a group books one space for a time block), plus
-- the amendments from Part 4/Part 5 that Kaden decided 2026-09-10/11.
--
-- All additive. Zero ALTER on gyms/profiles/messages/events_general. 7 new
-- tables (venues, venue_spaces, venue_availability_rules, venue_blackouts,
-- rental_requests, rental_agreements, venue_bookings), the btree_gist
-- extension, one exclusion constraint, RLS on every table, and three
-- SECURITY DEFINER functions (confirm_rental, set_booking_outcome,
-- admin_set_venue_space_verification).
--
-- Decisions this migration encodes (VENUE-RENTALS-AND-TAXONOMY-DESIGN.md
-- §3.2 + Part 4 + Part 5, all closed 2026-09-10/11 — see ACTION-NEEDED.md
-- for the decision log):
--   1. New venues/venue_spaces tables, not extending gyms (gyms stays
--      combat-scoped; see design doc §0.2/§1.1).
--   2. Venue identity: any authenticated user can list a venue by owning a
--      venues row. No new profiles.role. No admin gate on LISTING a venue.
--   3. Verification (Part 4.1, overrides the original "no verified flag in
--      v1" line): venue_spaces.verified_sports is an admin-set jsonb array
--      of taxonomy sport-item strings (matching RU_TAXONOMY item labels in
--      index.html, e.g. "Basketball", "Boxing"). Granted per sport, not per
--      space_type, per Kaden's 2026-09-11 answer — a court can be verified
--      for Basketball without being verified for Volleyball. Admin-set only,
--      via admin_set_venue_space_verification() below, same column-privilege
--      pattern as gyms.verified_venue in 20260906000000.
--   4. Payments line: rental_agreements records amount + payer/payee +
--      payment_terms_text as RECORDED TERMS ONLY. RoundUp processes, holds,
--      or transmits no money. No checkout, no card entry anywhere in this
--      schema.
--   5. Cancellation / no-show: recorded text terms only, same treatment as
--      payments — cancellation_terms_text / no_show_terms_text are plain
--      text, nothing is enforced or charged by the database.
--   6. Geographic gating (Tulsa metro only at launch) is a UI-layer decision,
--      not a DB constraint — no CHECK on venues.city/region here. See
--      design doc Part 5 item 5.
--   7. Legacy combat venue-marketplace code removal is a separate, already-
--      shipped change (PR #27) — unrelated to this schema, noted here only
--      so nobody goes looking for a migration tied to that PR.
--   8. Casual-renter messaging whitelist against canMessageUser() is an
--      index.html-side change for whenever that function reaches real DMs
--      (see design doc §1.5) — nothing to encode in this migration.
--
-- Event visibility gating (Part 4.3): when Slice 2 wires this up, an event
-- created with a venue_space attached must land in a new events_general
-- status ('pending_venue') until its linked rental_agreements row exists,
-- at which point it flips to 'published'. That is an index.html + a small
-- events_general status-constraint change for Slice 2 — not part of this
-- migration, which only adds the rental tables themselves.
-- ============================================================================

create extension if not exists btree_gist;

-- ----------------------------------------------------------------------------
-- 1) venues — the business. Any authenticated user may own one (decision 2
--    above) — same non-gated pattern as gym creation today.
-- ----------------------------------------------------------------------------
create table if not exists public.venues (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  city text,
  region text,
  address text,
  lat numeric,
  lng numeric,
  gym_id uuid references public.gyms(id) on delete set null, -- optional link if this venue is also a listed gym
  description text,
  contact text,
  photo_url text,
  -- Kaden approved 2026-09-13 (round-3 review, new item): a venue with any
  -- rental agreement history used to hit a hard `raise exception` on delete
  -- with literally no way to remove it from public browse ever (see the old
  -- venues_block_delete_with_history comment below, now superseded). Adding
  -- is_active mirrors venue_spaces' existing soft-delete column exactly.
  is_active boolean not null default true,
  created_at timestamptz not null default now()
  -- Deliberately no reputation/score column and no top-level verified flag —
  -- verification lives per-space, per-sport (venue_spaces.verified_sports
  -- below), not at the venue level. See design doc §1.1 / Part 4.1.
);

create index if not exists venues_owner_id_idx on public.venues(owner_id);

alter table public.venues enable row level security;

-- Self-listed and unverified at launch, same disclaimer pattern as gyms
-- (index.html:1149) — so browsing is public, same as the gym directory.
-- Public browsing only sees active venues (mirrors venue_spaces_select_public
-- below); the owner can still see their own inactive venues so they can
-- manage/reactivate them.
drop policy if exists "venues_select_public" on public.venues;
create policy "venues_select_public"
  on public.venues for select
  using (is_active or auth.uid() = owner_id);

drop policy if exists "venues_insert_own" on public.venues;
create policy "venues_insert_own"
  on public.venues for insert
  with check (auth.uid() = owner_id);

drop policy if exists "venues_update_own" on public.venues;
create policy "venues_update_own"
  on public.venues for update
  using (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

drop policy if exists "venues_delete_own" on public.venues;
create policy "venues_delete_own"
  on public.venues for delete
  using (auth.uid() = owner_id);

-- ----------------------------------------------------------------------------
-- 1b) Shared helper: does the current user control the given venue?
--    "Control" = owns it outright. No venue-staff/team concept in v1 (unlike
--    gyms' approved-member model) — keeping this simple until there's a real
--    need for venue team accounts.
--    NOTE ON PLACEMENT: this must live AFTER `create table ... venues` above.
--    `language sql` function bodies are parse-validated against the schema at
--    CREATE time (check_function_bodies is on by default), so defining this
--    before public.venues existed made the whole migration abort with
--    "relation public.venues does not exist". plpgsql functions elsewhere in
--    this file defer body validation and don't have this constraint — this
--    is the only `language sql` function in the file, so it's the only one
--    that needed moving.
-- ----------------------------------------------------------------------------
create or replace function public.user_can_manage_venue(check_venue_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.venues v
    where v.id = check_venue_id and v.owner_id = auth.uid()
  );
$$;

-- ----------------------------------------------------------------------------
-- Item 8, venues half (superseded 2026-09-13 by the new is_active column
-- above): this trigger used to `raise exception` outright on any delete of a
-- venue with agreement history, since venues previously had no soft-delete
-- column to fall back on — that left a venue with any rental history with
-- literally no way to be removed from public browse. Now that venues has its
-- own is_active column, this converts the delete into is_active = false
-- instead, the exact same pattern as venue_spaces_soft_delete below.
-- confirm_rental() always keeps rental_agreements.venue_id consistent with
-- the confirmed space's parent venue, so checking venue_id here directly is
-- equivalent to (and simpler than) checking through every child space.
create or replace function public.venues_block_delete_with_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.rental_agreements where venue_id = old.id) then
    update public.venues set is_active = false where id = old.id;
    return null; -- cancel the actual DELETE
  end if;
  return old; -- no history — hard delete proceeds
end;
$$;

drop trigger if exists venues_block_delete_with_history_trg on public.venues;
create trigger venues_block_delete_with_history_trg
  before delete on public.venues
  for each row execute function public.venues_block_delete_with_history();

-- ----------------------------------------------------------------------------
-- Round-3 review non-blocking 4: nothing previously stopped a venue owner
-- from setting gym_id to ANY gym's id, including one they don't own. Nothing
-- reads this column yet so it's harmless today, but leaving it unchecked
-- would let it silently misrepresent an affiliation the moment something
-- does read it (e.g. showing "affiliated with [gym]" on a venue page). Gym
-- ownership is public.gyms.owner_id (see index.html's gym queries, e.g.
-- `.from('gyms').select('*').eq('owner_id', user.id)`) — gyms has no
-- separate staff/team table to consult, so this is a direct ownership match,
-- same shape as user_can_manage_venue above.
-- ----------------------------------------------------------------------------
create or replace function public.venues_validate_gym_affiliation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.gym_id is not null and not exists (
    select 1 from public.gyms g where g.id = new.gym_id and g.owner_id = new.owner_id
  ) then
    raise exception 'gym_id must reference a gym you own.';
  end if;
  return new;
end;
$$;

drop trigger if exists venues_validate_gym_affiliation_trg on public.venues;
create trigger venues_validate_gym_affiliation_trg
  before insert or update of gym_id, owner_id on public.venues
  for each row execute function public.venues_validate_gym_affiliation();

-- ----------------------------------------------------------------------------
-- 2) venue_spaces — one rentable unit under a venue ("Field 3", "Ring 1").
--    Bookings always target a space_id, never a venue_id (design doc §1.1).
-- ----------------------------------------------------------------------------
create table if not exists public.venue_spaces (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null,
  space_type text not null
    check (space_type in ('field','court','turf','mat','ring','cage','lane','rink','studio','room','other')),
  surface text,
  dimensions text,
  capacity int,
  default_price numeric,
  price_unit text check (price_unit in ('hour','block','half_day','day')),
  min_block_minutes int,
  turnaround_before_min int not null default 0,
  turnaround_after_min int not null default 0,
  inclusions jsonb not null default '[]'::jsonb, -- e.g. ["lights","goals","locker rooms"]
  -- Part 4.1: admin-set, per-sport verification gate. Holds RU_TAXONOMY item
  -- strings (e.g. ["Basketball","Volleyball"]) this space is verified for.
  -- A space with an empty array still browses fine everywhere else — it just
  -- won't appear in the event-creation picker for any sport. Column-level
  -- privileges below make this admin-write-only, same pattern as
  -- gyms.verified_venue in 20260906000000.
  verified_sports jsonb not null default '[]'::jsonb,
  is_active bool not null default true,
  created_at timestamptz not null default now()
);

create index if not exists venue_spaces_venue_id_idx on public.venue_spaces(venue_id);

alter table public.venue_spaces enable row level security;

-- Public browsing only sees active spaces (item 8: a soft-deleted space must
-- disappear from browse-facing reads); the owner can still see their own
-- inactive spaces so they can manage/reactivate them.
drop policy if exists "venue_spaces_select_public" on public.venue_spaces;
create policy "venue_spaces_select_public"
  on public.venue_spaces for select
  using (is_active or public.user_can_manage_venue(venue_id));

drop policy if exists "venue_spaces_insert_own" on public.venue_spaces;
create policy "venue_spaces_insert_own"
  on public.venue_spaces for insert
  with check (public.user_can_manage_venue(venue_id));

drop policy if exists "venue_spaces_update_own" on public.venue_spaces;
create policy "venue_spaces_update_own"
  on public.venue_spaces for update
  using (public.user_can_manage_venue(venue_id))
  with check (public.user_can_manage_venue(venue_id));

drop policy if exists "venue_spaces_delete_own" on public.venue_spaces;
create policy "venue_spaces_delete_own"
  on public.venue_spaces for delete
  using (public.user_can_manage_venue(venue_id));

-- verified_sports is admin-write-only: revoke the table-level UPDATE grant
-- and re-grant only on the columns a venue owner is actually allowed to
-- touch, exactly the column-privilege-lockdown pattern already used for
-- gyms.verified_venue (20260906000000). The "venue_spaces_update_own" RLS
-- policy above still gates WHICH ROWS an owner can update; this grant gates
-- WHICH COLUMNS, so an owner cannot self-verify by including
-- verified_sports in an otherwise-legitimate update to their own space.
revoke update on public.venue_spaces from authenticated, anon;
grant update (
  name, space_type, surface, dimensions, capacity, default_price, price_unit,
  min_block_minutes, turnaround_before_min, turnaround_after_min, inclusions,
  is_active
) on public.venue_spaces to authenticated;

revoke insert on public.venue_spaces from authenticated, anon;
grant insert (
  venue_id, name, space_type, surface, dimensions, capacity, default_price,
  price_unit, min_block_minutes, turnaround_before_min, turnaround_after_min,
  inclusions, is_active
) on public.venue_spaces to authenticated;
-- verified_sports is omitted from both lists — it already has a
-- `default '[]'::jsonb` (above), so omitting it from the insert list doesn't
-- break space creation.

-- Only an admin (profiles.is_admin = true) may set a space's verified sports.
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
end;
$$;

-- ----------------------------------------------------------------------------
-- Item 8: soft delete for venue_spaces. Once a space has agreement history
-- (public.rental_agreements.space_id references it), a hard DELETE would
-- raise a raw FK error (23503) instead of the delete button doing anything
-- sensible. Reuses the space's EXISTING is_active column rather than adding
-- a new one: a `before delete` trigger converts the delete into
-- `is_active = false` and cancels the actual row delete (returns null) when
-- agreement history exists; otherwise it lets the hard delete proceed
-- (returns old). This matches the file's existing convention of doing
-- integrity work in a trigger (see rental_requests_set_venue_owner below)
-- rather than requiring every caller to know to call a special function —
-- the venue owner's existing "delete a space" button keeps working as-is.
-- Combined with the tightened "venue_spaces_select_public" policy above and
-- the is_active guards in rental_requests/confirm_rental below, a
-- soft-deleted space drops out of browse and can't be newly booked.
create or replace function public.venue_spaces_soft_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.rental_agreements where space_id = old.id) then
    update public.venue_spaces set is_active = false where id = old.id;
    return null; -- cancel the actual DELETE
  end if;
  return old; -- no history — hard delete proceeds
end;
$$;

drop trigger if exists venue_spaces_soft_delete_trg on public.venue_spaces;
create trigger venue_spaces_soft_delete_trg
  before delete on public.venue_spaces
  for each row execute function public.venue_spaces_soft_delete();

-- ----------------------------------------------------------------------------
-- 3) venue_availability_rules — recurring weekly open hours per space.
-- ----------------------------------------------------------------------------
create table if not exists public.venue_availability_rules (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.venue_spaces(id) on delete cascade,
  weekday int not null check (weekday between 0 and 6), -- 0 = Sunday
  opens time not null,
  closes time not null,
  effective_from date,
  effective_until date,
  created_at timestamptz not null default now(),
  check (closes > opens)
);

create index if not exists venue_availability_rules_space_id_idx on public.venue_availability_rules(space_id);

alter table public.venue_availability_rules enable row level security;

drop policy if exists "venue_availability_rules_select_public" on public.venue_availability_rules;
create policy "venue_availability_rules_select_public"
  on public.venue_availability_rules for select
  using (true);

drop policy if exists "venue_availability_rules_write_own" on public.venue_availability_rules;
create policy "venue_availability_rules_write_own"
  on public.venue_availability_rules for all
  using (exists (
    select 1 from public.venue_spaces s
    where s.id = space_id and public.user_can_manage_venue(s.venue_id)
  ))
  with check (exists (
    select 1 from public.venue_spaces s
    where s.id = space_id and public.user_can_manage_venue(s.venue_id)
  ));

-- ----------------------------------------------------------------------------
-- 4) venue_blackouts — one-off closures / holds. space_id null = whole venue.
-- ----------------------------------------------------------------------------
create table if not exists public.venue_blackouts (
  id uuid primary key default gen_random_uuid(),
  space_id uuid references public.venue_spaces(id) on delete cascade,
  venue_id uuid references public.venues(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_at timestamptz not null default now(),
  check (space_id is not null or venue_id is not null),
  check (ends_at > starts_at)
);

create index if not exists venue_blackouts_space_id_idx on public.venue_blackouts(space_id);
create index if not exists venue_blackouts_venue_id_idx on public.venue_blackouts(venue_id);

alter table public.venue_blackouts enable row level security;

drop policy if exists "venue_blackouts_select_public" on public.venue_blackouts;
create policy "venue_blackouts_select_public"
  on public.venue_blackouts for select
  using (true);

-- Item 6 fix: the old version OR'd two independent ownership checks
-- (venue_id = mine OR space_id = mine), which let a caller name THEIR OWN
-- venue_id alongside a COMPETITOR's space_id — the venue_id branch alone
-- satisfied the OR, so the mismatched space_id was never actually checked.
-- That let an attacker plant a blackout row that blocks a rival's space
-- while passing ownership checks on their own unrelated venue.
-- Fixed version: validate whichever key actually identifies the target row,
-- and if both are present, require them to be consistent (the named space
-- must really belong to the named venue) — no bare OR of two ownership
-- checks against two different rows.
drop policy if exists "venue_blackouts_write_own" on public.venue_blackouts;
create policy "venue_blackouts_write_own"
  on public.venue_blackouts for all
  using (
    case
      when space_id is not null then exists (
        select 1 from public.venue_spaces s
        where s.id = space_id
          and public.user_can_manage_venue(s.venue_id)
          and (venue_id is null or venue_id = s.venue_id)
      )
      when venue_id is not null then public.user_can_manage_venue(venue_id)
      else false
    end
  )
  with check (
    case
      when space_id is not null then exists (
        select 1 from public.venue_spaces s
        where s.id = space_id
          and public.user_can_manage_venue(s.venue_id)
          and (venue_id is null or venue_id = s.venue_id)
      )
      when venue_id is not null then public.user_can_manage_venue(venue_id)
      else false
    end
  );

-- ----------------------------------------------------------------------------
-- 5) rental_requests — the mutable negotiation between renter and venue.
--    venue_owner_id is denormalized for RLS but NEVER trusted from the
--    client — the trigger below always overwrites it from the space's real
--    owner, so a renter cannot forge it to see/claim someone else's request.
-- ----------------------------------------------------------------------------
create table if not exists public.rental_requests (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.venue_spaces(id) on delete cascade,
  renter_id uuid not null references auth.users(id) on delete cascade,
  venue_owner_id uuid not null references auth.users(id) on delete cascade,
  purpose text not null check (purpose in ('casual','event')),
  event_id uuid references public.events_general(id) on delete set null, -- only ever set when purpose='event'
  proposed_starts_at timestamptz not null,
  proposed_ends_at timestamptz not null,
  headcount int,
  activity_note text,
  proposed_price numeric,
  price_notes text,
  inclusions_requested jsonb,
  setup_teardown_note text,
  -- Item 7 (Kaden approved 2026-09-12): negotiated cancellation/no-show terms
  -- and explicit payer/payee, recorded on the request so confirm_rental() can
  -- freeze them into rental_agreements instead of hardcoding null/literals.
  -- Descriptive/record-keeping only — no amounts move, no processor, no
  -- payment-status machine. Same treatment as proposed_price/price_notes.
  proposed_cancellation_terms text,
  proposed_cancellation_deadline timestamptz,
  proposed_no_show_terms text,
  proposed_payer text not null default 'renter' check (proposed_payer in ('renter','venue')),
  proposed_payee text not null default 'venue' check (proposed_payee in ('renter','venue')),
  status text not null default 'requested'
    check (status in ('requested','countered','confirmed','declined','cancelled','expired','completed','no_show')),
  last_actor text not null default 'renter' check (last_actor in ('renter','venue')),
  renter_confirmed_at timestamptz,
  venue_confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (proposed_ends_at > proposed_starts_at),
  -- Round-3 review non-blocking 3: nothing previously stopped payer and
  -- payee from both being 'renter' or both 'venue' — a nonsensical term that
  -- would then get frozen verbatim into rental_agreements below.
  check (proposed_payer <> proposed_payee)
);

create index if not exists rental_requests_space_id_idx on public.rental_requests(space_id);
create index if not exists rental_requests_renter_id_idx on public.rental_requests(renter_id);
create index if not exists rental_requests_venue_owner_id_idx on public.rental_requests(venue_owner_id);
create index if not exists rental_requests_event_id_idx on public.rental_requests(event_id);

-- Force venue_owner_id to the space's real owner on every insert/update,
-- regardless of what the client sends. This is what makes venue_owner_id
-- safe to use in RLS below.
--
-- Round-3 review non-blocking 2: is_active was already checked at insert
-- time (rental_requests_insert_renter policy below) and again inside
-- confirm_rental(), but a renter could still repoint an existing request's
-- space_id at a space that's since been soft-deleted via UPDATE, since
-- nothing re-checked is_active on that path. This trigger already fires on
-- `before insert or update of space_id, venue_owner_id` (item 4), and
-- venue_owner_id is withheld from the client's update-column grant below, so
-- in practice a client-driven fire of this trigger only ever happens when
-- space_id is being set (insert) or actually changed (update) — exactly the
-- moment a fresh is_active check is needed. Folding the check in here means
-- an update that leaves space_id untouched (e.g. declining or cancelling a
-- request against a space that went inactive after the request was made)
-- is unaffected — only an attempt to point at a *different*, inactive space
-- is blocked.
create or replace function public.rental_requests_set_venue_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  space_active boolean;
begin
  select v.owner_id, s.is_active into new.venue_owner_id, space_active
    from public.venue_spaces s
    join public.venues v on v.id = s.venue_id
    where s.id = new.space_id;

  if new.venue_owner_id is null then
    raise exception 'venue space % has no resolvable owner', new.space_id;
  end if;

  if not space_active then
    raise exception 'This space is no longer available and cannot be assigned to a rental request.';
  end if;

  return new;
end;
$$;

-- Item 4 fix: this trigger must also fire when venue_owner_id ITSELF is the
-- column being updated, not only space_id. A `before update of <cols>`
-- trigger only fires when one of the listed columns appears in the UPDATE's
-- SET list — with only `of space_id`, an UPDATE that touched just
-- venue_owner_id skipped this guard entirely, letting a renter repoint a
-- request's venue_owner_id at themselves (and since the read policy below
-- keys off venue_owner_id, that also locked the real owner out of seeing
-- their own request). Listing venue_owner_id here too means any attempt to
-- set it directly gets recomputed from the space's real owner instead.
drop trigger if exists rental_requests_set_venue_owner_trg on public.rental_requests;
create trigger rental_requests_set_venue_owner_trg
  before insert or update of space_id, venue_owner_id on public.rental_requests
  for each row execute function public.rental_requests_set_venue_owner();

-- Item 5 fix: "both confirmation timestamps are non-null" is not the same
-- guarantee as "both parties agreed to the same terms." Without this, a
-- sequence like: venue confirms -> renter edits the price -> renter
-- confirms -> confirm_rental() would write the agreement at the NEW price
-- against the venue's consent to the OLD price. Whenever any material term
-- changes, reset BOTH parties' confirmations so the handshake has to happen
-- again on the new terms. Keep this list explicit — extend it whenever a
-- new negotiable term column is added (e.g. the item 7 columns are already
-- included below).
--
-- Round-3 review finding A: this list previously missed price_notes,
-- inclusions_requested, and setup_teardown_note — all three ARE frozen into
-- rental_agreements by confirm_rental() below (as payment_terms_text,
-- inclusions, and setup_teardown_terms respectively), so leaving them out of
-- this watch list let one party silently change them after the other had
-- already confirmed: venue confirms -> renter edits price_notes to terms the
-- venue never saw -> renter confirms -> confirm_rental() freezes the
-- renter's version into the write-once rental_agreements row with no
-- invalidation and no way to correct it afterward (rental_agreements has no
-- UPDATE policy). Every column that confirm_rental() reads off `req` to
-- populate rental_agreements must be listed here — there is no other
-- enforcement mechanism, so re-verify this list any time confirm_rental()'s
-- insert changes.
create or replace function public.rental_requests_invalidate_stale_confirmation()
returns trigger
language plpgsql
as $$
begin
  if new.space_id is distinct from old.space_id
     or new.proposed_starts_at is distinct from old.proposed_starts_at
     or new.proposed_ends_at is distinct from old.proposed_ends_at
     or new.proposed_price is distinct from old.proposed_price
     or new.price_notes is distinct from old.price_notes
     or new.inclusions_requested is distinct from old.inclusions_requested
     or new.setup_teardown_note is distinct from old.setup_teardown_note
     or new.proposed_cancellation_terms is distinct from old.proposed_cancellation_terms
     or new.proposed_cancellation_deadline is distinct from old.proposed_cancellation_deadline
     or new.proposed_no_show_terms is distinct from old.proposed_no_show_terms
     or new.proposed_payer is distinct from old.proposed_payer
     or new.proposed_payee is distinct from old.proposed_payee
  then
    new.renter_confirmed_at := null;
    new.venue_confirmed_at := null;
  end if;

  return new;
end;
$$;

drop trigger if exists rental_requests_invalidate_stale_confirmation_trg on public.rental_requests;
create trigger rental_requests_invalidate_stale_confirmation_trg
  before update on public.rental_requests
  for each row execute function public.rental_requests_invalidate_stale_confirmation();

alter table public.rental_requests enable row level security;

-- Parties only — a rental negotiation is private between renter and venue.
drop policy if exists "rental_requests_select_parties" on public.rental_requests;
create policy "rental_requests_select_parties"
  on public.rental_requests for select
  using (auth.uid() in (renter_id, venue_owner_id));

-- Item 8: a soft-deleted (is_active = false) space can't be newly booked —
-- block the request at creation time.
--
-- Round-3 review finding B: this policy previously had no constraint on
-- `status` at all, so a renter could INSERT a brand-new row with
-- status='confirmed', 'completed', or 'no_show' directly — bypassing the
-- two-party confirm_rental() handshake entirely. A row inserted as
-- 'confirmed' then permanently fails the UPDATE policy below (whose USING
-- clause only allows 'requested'/'countered') and there's no DELETE policy
-- either, so it would sit frozen forever in the venue owner's queue; a
-- 'completed'/'no_show' insert would fabricate rental history against a
-- venue that never rented to this person. Every new request must start in
-- 'requested' — the only legitimate way forward from there is through the
-- update policy below and confirm_rental()/set_booking_outcome().
drop policy if exists "rental_requests_insert_renter" on public.rental_requests;
create policy "rental_requests_insert_renter"
  on public.rental_requests for insert
  with check (
    auth.uid() = renter_id
    and status = 'requested'
    and exists (select 1 from public.venue_spaces s where s.id = space_id and s.is_active)
  );

-- Either party can edit/counter/decline/cancel while the request is still
-- negotiable. Confirmation is deliberately NOT reachable through this
-- policy — 'confirmed' can only be set by confirm_rental() below, which
-- runs as SECURITY DEFINER and bypasses RLS, after verifying BOTH parties
-- signed off. This stops a client from just UPDATE-ing status='confirmed'
-- to fake a two-party handshake.
drop policy if exists "rental_requests_update_parties" on public.rental_requests;
create policy "rental_requests_update_parties"
  on public.rental_requests for update
  using (
    auth.uid() in (renter_id, venue_owner_id)
    and status in ('requested','countered')
  )
  with check (
    auth.uid() in (renter_id, venue_owner_id)
    and status in ('requested','countered','declined','cancelled')
  );

-- Item 3 fix: column-privilege lockdown, same pattern as venue_spaces above.
-- Today (before this fix) `authenticated` retains full table-level INSERT and
-- UPDATE on every column via Supabase's default grant. The RLS policies above
-- gate WHICH ROWS can be touched, but not WHICH COLUMNS within an otherwise
-- legitimate row-level update — so a renter could insert/update their own
-- request row but set venue_confirmed_at (or forge venue_owner_id, bypassing
-- the recompute trigger's authority) and price, then call confirm_rental()
-- to obtain a binding agreement the venue never actually agreed to. It works
-- symmetrically the other way for a malicious venue owner. Column-level
-- REVOKE alone would NOT carve an exception out of Supabase's default
-- table-level GRANT — it must be a table-level revoke followed by an
-- explicit safe-column re-grant, covering both INSERT and UPDATE.
--
-- Columns deliberately withheld from BOTH lists (client never legitimately
-- authors these):
--   id                 — surrogate key, not client-authored.
--   venue_owner_id     — denormalized/derived; only the recompute trigger
--                        (rental_requests_set_venue_owner) may set it, and
--                        excluding it from the grant is defense-in-depth on
--                        top of that trigger (item 4).
--   renter_confirmed_at, venue_confirmed_at — may ONLY be set by
--                        confirm_rental() (SECURITY DEFINER, bypasses RLS
--                        and these grants entirely). This is the crux of the
--                        item 3 finding — these two must never be
--                        client-writable under any circumstance.
--   created_at         — server-assigned at insert (default now()).
-- Additionally withheld from the UPDATE list only:
--   renter_id          — the renter identity is set once at insert (RLS
--                        requires it match auth.uid() there) and must not
--                        change afterward; there's no legitimate reason for
--                        an existing request to switch renters.
revoke insert, update on public.rental_requests from authenticated, anon;

grant insert (
  space_id, renter_id, purpose, event_id, proposed_starts_at, proposed_ends_at,
  headcount, activity_note, proposed_price, price_notes, inclusions_requested,
  setup_teardown_note, proposed_cancellation_terms, proposed_cancellation_deadline,
  proposed_no_show_terms, proposed_payer, proposed_payee, status, last_actor
) on public.rental_requests to authenticated;

grant update (
  space_id, purpose, event_id, proposed_starts_at, proposed_ends_at,
  headcount, activity_note, proposed_price, price_notes, inclusions_requested,
  setup_teardown_note, proposed_cancellation_terms, proposed_cancellation_deadline,
  proposed_no_show_terms, proposed_payer, proposed_payee, status, last_actor,
  updated_at
) on public.rental_requests to authenticated;

-- ----------------------------------------------------------------------------
-- 6) rental_agreements — IMMUTABLE snapshot, written once on confirm.
--    No UPDATE policy, no DELETE policy anywhere below — default-deny under
--    RLS makes the row physically write-once. Only confirm_rental() (a
--    SECURITY DEFINER function, bypasses RLS) may insert here. A post-
--    confirmation change is a NEW row with supersedes_id pointing at the
--    prior one (design doc §1.3) — not implemented by any function yet,
--    since amendment flows are explicitly out of scope for this slice
--    (design doc §3.3).
-- ----------------------------------------------------------------------------
create table if not exists public.rental_agreements (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.rental_requests(id) on delete restrict,
  supersedes_id uuid references public.rental_agreements(id),
  space_id uuid not null references public.venue_spaces(id),
  venue_id uuid not null references public.venues(id),
  renter_id uuid not null references auth.users(id),
  venue_owner_id uuid not null references auth.users(id),
  renter_name_snapshot text,
  venue_name_snapshot text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  amount numeric, -- recorded term only — see decision 4 above; RoundUp moves no money
  payer text not null default 'renter' check (payer in ('renter','venue')),
  payee text not null default 'venue' check (payee in ('renter','venue')),
  payment_terms_text text,
  inclusions jsonb,
  setup_teardown_terms text,
  cancellation_terms_text text,
  cancellation_deadline timestamptz,
  no_show_terms_text text,
  agreement_hash text,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  -- Round-3 review non-blocking 3: same payer/payee distinctness guarantee
  -- as rental_requests above, applied to the frozen copy too — confirm_rental()
  -- only ever copies req.proposed_payer/proposed_payee straight across, so
  -- this is redundant with the source-table check today, but rental_agreements
  -- is the immutable record of truth and shouldn't rely solely on a
  -- constraint on a different, mutable table to stay valid.
  check (payer <> payee)
);

create index if not exists rental_agreements_request_id_idx on public.rental_agreements(request_id);
create index if not exists rental_agreements_space_id_idx on public.rental_agreements(space_id);

alter table public.rental_agreements enable row level security;

drop policy if exists "rental_agreements_select_parties" on public.rental_agreements;
create policy "rental_agreements_select_parties"
  on public.rental_agreements for select
  using (auth.uid() in (renter_id, venue_owner_id));

-- Deliberately no insert/update/delete policy for authenticated/anon — see
-- comment above the table. With RLS enabled and no permissive INSERT/UPDATE
-- policy, PostgREST/RLS already denies these outright regardless of table
-- grants. The explicit revoke below is defense-in-depth documentation only
-- (item 3 audit) — this table was never actually exploitable, but the
-- column-privilege gap has now been found twice in this project (venue_spaces
-- originally, rental_requests in item 3), so every table in this file gets an
-- explicit statement of intent rather than relying solely on "no policy
-- exists yet."
revoke insert, update on public.rental_agreements from authenticated, anon;

-- ----------------------------------------------------------------------------
-- 7) venue_bookings — the calendar fact. Created only by confirm_rental().
--    Double-booking is prevented at the DB level by the exclusion constraint
--    below, not by application logic — a Postgres exclusion constraint is
--    the only thing that can express "no overlapping booking for this
--    space" across concurrent requests, since RLS is row-local and can't
--    see other rows (design doc §1.2).
-- ----------------------------------------------------------------------------
create table if not exists public.venue_bookings (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.venue_spaces(id) on delete cascade,
  agreement_id uuid not null references public.rental_agreements(id) on delete cascade,
  renter_id uuid not null references auth.users(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'confirmed' check (status in ('confirmed','cancelled','completed','no_show')),
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);

create index if not exists venue_bookings_space_id_idx on public.venue_bookings(space_id);
create index if not exists venue_bookings_agreement_id_idx on public.venue_bookings(agreement_id);

-- The double-booking guarantee. Only 'confirmed' rows lock a slot —
-- overlapping *requests* are fine and expected; first to actually confirm
-- wins, the rest fail here with Postgres error 23P01 (client should catch
-- this and show "that slot was just booked — pick another").
--
-- Round-3 review non-blocking 1: unlike every other statement in this file,
-- this `alter table ... add constraint` had no re-run guard. Since this has
-- never executed against real Postgres, a first manual run failing partway
-- through (for any reason) followed by Kaden re-running the whole file would
-- die here with 42710 (duplicate object) even though nothing is actually
-- wrong. Wrapped in the same "skip if it already exists" idempotency as the
-- rest of the file (drop-policy-if-exists, create-or-replace, etc.).
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'venue_bookings_no_overlap'
  ) then
    alter table public.venue_bookings
      add constraint venue_bookings_no_overlap
      exclude using gist (
        space_id with =,
        tstzrange(starts_at, ends_at, '[)') with &&
      ) where (status = 'confirmed');
  end if;
end;
$$;

alter table public.venue_bookings enable row level security;

drop policy if exists "venue_bookings_select_parties" on public.venue_bookings;
create policy "venue_bookings_select_parties"
  on public.venue_bookings for select
  using (
    auth.uid() = renter_id
    or exists (
      select 1 from public.venue_spaces s
      where s.id = space_id and public.user_can_manage_venue(s.venue_id)
    )
  );

-- Deliberately no insert/update/delete policy — confirm_rental() and
-- set_booking_outcome() below (both SECURITY DEFINER) are the only writers.
-- Same defense-in-depth note as rental_agreements above (item 3 audit): RLS
-- already denies this with no policy present, this revoke just states intent
-- explicitly rather than relying on that alone.
revoke insert, update on public.venue_bookings from authenticated, anon;

-- Anyone (not just the parties) needs to know a space is taken, to grey out
-- unavailable slots when browsing — but not who booked it or why. Same
-- security-definer-view pattern already used for events_bouts_public
-- (20260905000000): the view bypasses venue_bookings' parties-only RLS on
-- purpose, surfacing only the columns needed to compute availability.
-- ⚠️ SECURITY DEFINER BY DESIGN — DO NOT ADD security_invoker = true. This
-- view deliberately has no WITH (security_invoker = true) clause, so it runs
-- with the view owner's privileges rather than the querying user's — that's
-- required here since venue_bookings' only SELECT policy is parties-only.
-- Supabase's linter will flag this as a "Security Definer View"; that is
-- intentional, same as events_bouts_public (20260905000000). "Fixing" the
-- lint warning by adding security_invoker = true will not error — it will
-- just make availability-checking silently return zero rows to anon.
drop view if exists public.venue_bookings_public;
create view public.venue_bookings_public as
  select id, space_id, starts_at, ends_at, status
  from public.venue_bookings
  where status = 'confirmed';

grant select on public.venue_bookings_public to authenticated, anon;

-- ----------------------------------------------------------------------------
-- 8) confirm_rental() — the only path from a two-sided handshake to an
--    immutable agreement + a locked calendar slot.
-- ----------------------------------------------------------------------------
create or replace function public.confirm_rental(target_request_id uuid)
returns uuid -- returns the new rental_agreements.id
language plpgsql
security definer
set search_path = public
as $$
declare
  req public.rental_requests%rowtype;
  space public.venue_spaces%rowtype;
  venue public.venues%rowtype;
  renter_name text;
  new_agreement_id uuid;
  blackout_conflict boolean;
begin
  select * into req from public.rental_requests where id = target_request_id for update;
  if req.id is null then
    raise exception 'Rental request % not found', target_request_id;
  end if;
  if auth.uid() not in (req.renter_id, req.venue_owner_id) then
    raise exception 'Only a party to this request may confirm it.';
  end if;
  if req.status not in ('requested','countered') then
    raise exception 'Request is in status %, not confirmable.', req.status;
  end if;

  -- Record this caller's confirmation.
  if auth.uid() = req.renter_id then
    req.renter_confirmed_at := now();
  end if;
  if auth.uid() = req.venue_owner_id then
    req.venue_confirmed_at := now();
  end if;

  update public.rental_requests
    set renter_confirmed_at = req.renter_confirmed_at,
        venue_confirmed_at = req.venue_confirmed_at,
        updated_at = now()
    where id = target_request_id;

  -- Only proceed to a full confirmation once BOTH parties have signed off
  -- on the same terms (design doc §1.3 — "confirmed requires both
  -- renter_confirmed_at and venue_confirmed_at on the same terms").
  if req.renter_confirmed_at is null or req.venue_confirmed_at is null then
    return null;
  end if;

  select * into space from public.venue_spaces where id = req.space_id;
  select * into venue from public.venues where id = space.venue_id;

  -- Item 8: a space soft-deleted (is_active = false) since the request was
  -- made cannot be newly booked either — close the gap between "request
  -- created while active" and "confirmed after the owner deactivated it."
  if not space.is_active then
    raise exception 'This space is no longer available and cannot be booked.';
  end if;

  -- Re-check blackouts server-side — venue_blackouts is a separate table
  -- and is NOT covered by the exclusion constraint on venue_bookings, so
  -- the confirm path must check it explicitly (design doc §1.2).
  select exists (
    select 1 from public.venue_blackouts b
    where (b.space_id = space.id or (b.venue_id = venue.id and b.space_id is null))
      and tstzrange(b.starts_at, b.ends_at, '[)') && tstzrange(req.proposed_starts_at, req.proposed_ends_at, '[)')
  ) into blackout_conflict;

  if blackout_conflict then
    raise exception 'Requested time conflicts with a venue blackout — cannot confirm.';
  end if;

  select display_name into renter_name from public.profiles where id = req.renter_id;

  -- Item 7: copy the negotiated terms from the request instead of hardcoding
  -- payer/payee to literals and cancellation/no-show terms to null.
  -- rental_agreements is write-once (no update policy), so these had to be
  -- added while the schema is still a draft — there's no later chance to
  -- backfill them.
  insert into public.rental_agreements (
    request_id, space_id, venue_id, renter_id, venue_owner_id,
    renter_name_snapshot, venue_name_snapshot,
    starts_at, ends_at, amount, payer, payee, payment_terms_text,
    inclusions, setup_teardown_terms, cancellation_terms_text,
    cancellation_deadline, no_show_terms_text, agreement_hash
  ) values (
    req.id, space.id, venue.id, req.renter_id, req.venue_owner_id,
    coalesce(renter_name, 'Renter'), coalesce(venue.name, 'Venue'),
    req.proposed_starts_at, req.proposed_ends_at, req.proposed_price,
    req.proposed_payer, req.proposed_payee,
    req.price_notes, coalesce(req.inclusions_requested, space.inclusions), req.setup_teardown_note,
    req.proposed_cancellation_terms, req.proposed_cancellation_deadline, req.proposed_no_show_terms,
    -- Item 2 fix: Postgres has no text -> bytea cast; sha256() takes bytea,
    -- so the text must go through convert_to(text, 'UTF8') first, not ::bytea.
    encode(sha256(
      convert_to(
        req.id::text || req.space_id::text || req.renter_id::text || req.venue_owner_id::text ||
        req.proposed_starts_at::text || req.proposed_ends_at::text || coalesce(req.proposed_price::text,''),
        'UTF8'
      )
    ), 'hex')
  ) returning id into new_agreement_id;

  -- This is the guarantee: only a 'confirmed' venue_bookings row locks a
  -- slot, enforced by the exclusion constraint above. If a concurrent
  -- confirm_rental() already took this slot, this insert raises 23P01 and
  -- the whole function aborts — no agreement is left dangling without a
  -- booking, because both inserts are in the same transaction.
  insert into public.venue_bookings (space_id, agreement_id, renter_id, starts_at, ends_at, status)
  values (space.id, new_agreement_id, req.renter_id, req.proposed_starts_at, req.proposed_ends_at, 'confirmed');

  update public.rental_requests set status = 'confirmed', updated_at = now() where id = target_request_id;

  return new_agreement_id;
end;
$$;

-- ----------------------------------------------------------------------------
-- 9) set_booking_outcome() — manual venue-owner buttons after end time.
--    No automation in v1 (design doc §1.3) — a human marks completed/no_show.
-- ----------------------------------------------------------------------------
create or replace function public.set_booking_outcome(target_booking_id uuid, outcome text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  booking public.venue_bookings%rowtype;
begin
  if outcome not in ('completed','no_show','cancelled') then
    raise exception 'Invalid booking outcome: %', outcome;
  end if;

  select * into booking from public.venue_bookings where id = target_booking_id;
  if booking.id is null then
    raise exception 'Booking % not found', target_booking_id;
  end if;

  if not exists (
    select 1 from public.venue_spaces s
    where s.id = booking.space_id and public.user_can_manage_venue(s.venue_id)
  ) then
    raise exception 'Only the venue owner can set a booking outcome.';
  end if;

  if booking.status != 'confirmed' then
    raise exception 'Only a confirmed booking can have its outcome set.';
  end if;

  update public.venue_bookings set status = outcome where id = target_booking_id;

  update public.rental_requests
    set status = outcome, updated_at = now()
    where id = (select request_id from public.rental_agreements where id = booking.agreement_id);
end;
$$;
