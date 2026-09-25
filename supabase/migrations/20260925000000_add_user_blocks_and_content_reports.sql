-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself. Do not run this
-- against any database from this session or any automated tool.
-- ============================================================================
--
-- Purpose: Phase 1 of LAUNCH-CHECKLIST.md — before any public launch, a
-- messaging + UGC app needs a real Block and Report path, not just the
-- existing conduct-word filter (checkConduct, index.html ~1917), which only
-- catches known bad words at send time and does nothing once a user decides
-- they don't want to hear from someone again, or wants to flag a reel/user
-- to an admin. Neither `user_blocks` nor `content_reports` exist today —
-- confirmed by grepping every migration file for both names.
--
-- Two tables:
--   1. user_blocks — one row per (blocker, blocked) pair. Enforced at the
--      RLS layer on `messages` below, not just hidden in the UI — a blocked
--      user (in either direction) cannot INSERT a new message to the other
--      party, matching the project's standing rule that RLS is the real
--      security boundary and client-side checks are UX only.
--   2. content_reports — one row per report. Reporters can see their own
--      reports (so the UI can show "reported" state); only an admin
--      (profiles.is_admin, the same real admin gate used everywhere else in
--      this schema) can see/update the full queue. No admin review UI is
--      built yet — this migration only lays the data layer down.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) user_blocks
-- ----------------------------------------------------------------------------
create table if not exists public.user_blocks (
  id uuid primary key default gen_random_uuid(),
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint user_blocks_not_self check (blocker_id <> blocked_id),
  constraint user_blocks_unique unique (blocker_id, blocked_id)
);

create index if not exists user_blocks_blocker_id_idx on public.user_blocks(blocker_id);
create index if not exists user_blocks_blocked_id_idx on public.user_blocks(blocked_id);

alter table public.user_blocks enable row level security;

-- A user's block list is private — visible only to the person who made it.
-- No case anywhere needs "can I see who blocked me" (that would let a
-- blocked user route around the block by re-approaching some other way).
drop policy if exists "user_blocks_select_own" on public.user_blocks;
create policy "user_blocks_select_own"
  on public.user_blocks for select
  using (auth.uid() = blocker_id);

drop policy if exists "user_blocks_insert_own" on public.user_blocks;
create policy "user_blocks_insert_own"
  on public.user_blocks for insert
  with check (auth.uid() = blocker_id);

-- Unblocking is a delete of your own row — no update path needed, a block
-- either exists or it doesn't.
drop policy if exists "user_blocks_delete_own" on public.user_blocks;
create policy "user_blocks_delete_own"
  on public.user_blocks for delete
  using (auth.uid() = blocker_id);

-- No column-level lockdown needed here (unlike rental_requests/venue_spaces):
-- every column on this table is exactly as sensitive as the row itself, and
-- the row-level policies above already fully gate it — there's no column a
-- blocker shouldn't be able to set on their own block row.

-- ----------------------------------------------------------------------------
-- 2) content_reports
-- ----------------------------------------------------------------------------
create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_user_id uuid references public.profiles(id) on delete set null,
  content_type text not null check (content_type in ('profile','message','reel','event','comment','other')),
  content_id text,
  reason text not null,
  details text,
  status text not null default 'open' check (status in ('open','reviewed','dismissed','actioned')),
  created_at timestamptz not null default now()
);

create index if not exists content_reports_reporter_id_idx on public.content_reports(reporter_id);
create index if not exists content_reports_status_idx on public.content_reports(status);

alter table public.content_reports enable row level security;

-- A reporter can see their own reports (so the UI can reflect "reported").
-- An admin can see everything, via the same profiles.is_admin flag used for
-- venue-space verification and gym certification. This subquery only ever
-- reads the caller's OWN profiles row (id = auth.uid()), which the existing
-- profiles RLS already allows for any authenticated user regardless of
-- admin status — this is the same shape used at
-- 20260911000000_add_venue_rental_schema.sql:293-304 and
-- 20260906000000_roster_follow_review_verify_schema.sql:372-382, just
-- inlined into a policy instead of a SECURITY DEFINER function since no
-- privileged write is happening on the read side.
drop policy if exists "content_reports_select_own_or_admin" on public.content_reports;
create policy "content_reports_select_own_or_admin"
  on public.content_reports for select
  using (
    auth.uid() = reporter_id
    or exists (select 1 from public.profiles where id = auth.uid() and is_admin = true)
  );

drop policy if exists "content_reports_insert_own" on public.content_reports;
create policy "content_reports_insert_own"
  on public.content_reports for insert
  with check (auth.uid() = reporter_id);

-- Only an admin can change a report's status (review/dismiss/action it).
-- The reporter cannot edit their own report after filing — prevents a
-- reporter from tampering with the queue once it's admin-visible.
drop policy if exists "content_reports_update_admin" on public.content_reports;
create policy "content_reports_update_admin"
  on public.content_reports for update
  using (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true))
  with check (exists (select 1 from public.profiles where id = auth.uid() and is_admin = true));

-- Column-level lockdown: a reporter must not be able to set `status` to
-- anything but the 'open' default at insert, and must never be able to
-- update a report at all (the UPDATE policy above already blocks non-admins
-- at the row level, but per the project's standing "RLS is row-level, not
-- column-level" lesson, an admin's UPDATE grant is scoped to `status` only
-- so an admin action can't accidentally rewrite the original report content).
revoke insert, update on public.content_reports from authenticated, anon;

grant insert (
  reporter_id, reported_user_id, content_type, content_id, reason, details
) on public.content_reports to authenticated;

grant update (status) on public.content_reports to authenticated;

-- ----------------------------------------------------------------------------
-- 3) Enforce blocks at the messages layer — the actual security boundary.
--    Without this, "Block" would only be a UI-side filter that a blocked
--    user could trivially route around by hitting the anon-key REST API
--    directly, same class of gap this project has fixed before (see
--    20260906020000_restrict_messages_exposure.sql). Blocking in EITHER
--    direction stops new messages between the pair — once either party
--    blocks, the conversation is closed for new sends both ways, matching
--    common product convention and avoiding a one-sided "I blocked them but
--    they can still message me" gap.
-- ----------------------------------------------------------------------------
drop policy if exists "messages_insert_own" on public.messages;
create policy "messages_insert_own"
  on public.messages for insert
  with check (
    auth.uid() = sender_id
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = recipient_id and b.blocked_id = sender_id)
         or (b.blocker_id = sender_id and b.blocked_id = recipient_id)
    )
  );

-- Post-condition: confirm exactly the expected INSERT policy is present and
-- nothing else permissive survived (same style of check this project's
-- migrations already use for messages).
do $$
declare leftover text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ') into leftover
  from pg_policies
  where schemaname = 'public' and tablename = 'messages'
    and permissive = 'PERMISSIVE' and cmd in ('INSERT','ALL')
    and policyname <> 'messages_insert_own';
  if leftover is not null then
    raise exception 'Leftover permissive insert policy on public.messages: %', leftover;
  end if;
end $$;

notify pgrst, 'reload schema';
