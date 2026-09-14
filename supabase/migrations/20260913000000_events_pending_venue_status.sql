-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself. Do not run this
-- against any database from this session or any automated tool.
-- ============================================================================
--
-- Purpose: Slice 2 of VENUE-RENTALS-AND-TAXONOMY-DESIGN.md (§3.1, §4.3) — the
-- venue-space picker added to the "Post an Event" form in index.html
-- (openGeneralEventForm/saveGeneralEvent) needs a status value to hold an
-- event in while it waits on the venue to confirm the linked rental_requests
-- row. `20260911000000_add_venue_rental_schema.sql` (lines 54-58) flagged this
-- exact gap: "an event created with a venue_space attached must land in a new
-- events_general status ('pending_venue') until its linked rental_agreements
-- row exists... That is an index.html + a small events_general
-- status-constraint change for Slice 2 — not part of this migration."
--
-- REQUIRED BEFORE THE ACCOMPANYING index.html CHANGE WORKS. The Slice 2 PR's
-- saveGeneralEvent() inserts events_general rows with status:'pending_venue'
-- whenever a renter picks a verified venue space. events_general.status's
-- CHECK constraint today (20260905000000) only allows
-- ('draft','published','cancelled','completed') — 'pending_venue' is NOT in
-- that list yet. Until this migration is applied, any venue-attached event
-- creation will fail outright with a CHECK-constraint violation (Postgres
-- error 23514). THIS MIGRATION MUST BE APPLIED BEFORE THAT PR IS MERGED, not
-- just before it's used — merging without applying this first means the
-- picker is reachable in the UI but every submission through it errors.
--
-- What this file does:
--   1. Widens events_general.status's CHECK constraint to add 'pending_venue',
--      via the same drop-then-add pattern as
--      20260910010000_events_category_drop_wedding_reunion.sql. That pattern
--      (drop constraint if exists, then add) is itself what makes this file
--      safe to re-run — `alter table ... add constraint` has no
--      `add constraint if not exists` in Postgres, but preceding it with
--      `drop constraint if exists` on the same constraint name means a second
--      run drops what the first run added and re-adds the identical
--      definition, instead of failing on "constraint already exists".
--   2. Re-creates public.confirm_rental() with exactly one behavioral
--      addition on top of the version in 20260911000000_add_venue_rental_schema.sql:
--      once both parties have confirmed and the agreement + booking rows are
--      successfully inserted, if the request's purpose is 'event' and it has
--      a linked event_id, flip that events_general row from 'pending_venue' to
--      'published' in the SAME transaction. Every other line of the function
--      is unchanged from the original — diff this against
--      20260911000000_add_venue_rental_schema.sql's confirm_rental() to
--      confirm the only delta is the new UPDATE statement and its guard.
--      Stays SECURITY DEFINER — same reason as the original: it needs to
--      update an events_general row it does not own (the promoter owns the
--      event; the function runs as whichever party called confirm_rental(),
--      which may be the venue owner).
--   3. No policy change: events_general's existing public SELECT policy
--      ("events_general_select_published_public", 20260905000000) is
--      `using (status in ('published','completed'))` — 'pending_venue' was
--      never in that list and still isn't, so a pending_venue event is
--      automatically non-public with zero policy changes needed. The
--      separate "events_general_select_own" policy (`auth.uid() = owner_id`)
--      already lets the event's owner see it regardless of status, which is
--      what index.html's Slice 2 change relies on to show the owner their own
--      pending event with a "pending venue confirmation" badge instead of it
--      silently vanishing.
--
-- Safe to run once; re-running no-ops via the drop-then-add pattern above and
-- `create or replace function`.
-- ============================================================================

alter table public.events_general
  drop constraint if exists events_general_status_check;

alter table public.events_general
  add constraint events_general_status_check
  check (status in ('draft','published','pending_venue','cancelled','completed'));

-- ----------------------------------------------------------------------------
-- confirm_rental() — identical to 20260911000000_add_venue_rental_schema.sql's
-- version, with one addition: after the rental_agreements + venue_bookings
-- inserts succeed, flip a linked event from 'pending_venue' to 'published'.
-- Guarded to only touch events created through the event-booking path
-- (purpose = 'event' and event_id is not null) — a casual (purpose='casual')
-- request never has an event_id, so this update is a no-op for that path.
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

  -- NEW (Slice 2, this migration): an event created through the event-booking
  -- path (saveGeneralEvent in index.html) is inserted as 'pending_venue' and
  -- excluded from public listing (see the no-policy-change note at the top of
  -- this file) until this exact moment. Flip it to 'published' in the same
  -- transaction as the agreement/booking above, so an event never sits
  -- confirmed-but-still-hidden or public-but-unconfirmed. Guarded to
  -- purpose='event' with a non-null event_id — a casual (purpose='casual')
  -- request has no event_id and this is a no-op for it. The `and status =
  -- 'pending_venue'` guard means this never touches an event a promoter
  -- separately cancelled/republished through some other path in the interim.
  if req.purpose = 'event' and req.event_id is not null then
    update public.events_general set status = 'published'
      where id = req.event_id and status = 'pending_venue';
  end if;

  update public.rental_requests set status = 'confirmed', updated_at = now() where id = target_request_id;

  return new_agreement_id;
end;
$$;

notify pgrst, 'reload schema';
