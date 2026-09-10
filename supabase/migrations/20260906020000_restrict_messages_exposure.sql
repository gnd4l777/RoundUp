-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Do not run against production from this
-- session. Written for review only. Kaden applies this himself from his own
-- machine once he's reviewed it (e.g. via `supabase db push` or the Studio
-- SQL editor).
-- ============================================================================
--
-- CONFIRMED LIVE ISSUE, found while checking whether the just-fixed
-- `profiles` exposure pattern (see 20260906010000_restrict_profiles_exposure.sql
-- on the agent/fix-profiles-exposure branch) also applied elsewhere: an
-- unauthenticated curl against the real production Supabase REST API
-- confirmed that the real `messages` table (private DMs between users) is
-- fully anon-readable today. It currently returns `200 []` (empty, not a
-- 401/403) because no real DMs have been sent yet — column-fuzzing against
-- that same endpoint confirmed the real schema: id, sender_id, recipient_id,
-- body, created_at. The moment any real user sends a DM, its `body` becomes
-- publicly readable by anyone holding the public anon key, no login
-- required. This is almost certainly because `messages` currently has a
-- permissive SELECT RLS policy along the lines of `using (true)`, or RLS is
-- not enabled on the table at all.
--
-- UNLIKE THE PROFILES FIX, THIS ONE NEEDS NO index.html CHANGE AND NO NEW
-- VIEW. Every `.from('messages')` call site in index.html was re-grepped
-- directly (not just trusted from a prior description) to confirm this:
--   - SELECT (inbox list),      ~line 2572: .or('sender_id.eq.'+myId+',recipient_id.eq.'+myId)
--   - SELECT (one DM thread),   ~line 4971: .or('and(sender_id.eq.'+myId+',recipient_id.eq.'+otherId+'),and(sender_id.eq.'+otherId+',recipient_id.eq.'+myId+')')
--   - INSERT (send a DM),       ~line 5024: .insert({sender_id:user.id, recipient_id:otherId, body:text})
--   - INSERT (send a reel as DM), ~line 7836: .insert({sender_id:user.id, recipient_id:otherId, body:'[reel:'+reelId+']'})
-- Every read already filters to rows where the current user is sender or
-- recipient, and every write already sets sender_id to the caller's own
-- auth id. There is no legitimate case anywhere in the app for reading a
-- message you didn't send or receive, and no legitimate case for inserting
-- a message as anyone other than yourself. So the fix here is purely
-- tightening RLS on the base table to match what the client already
-- voluntarily does — no public view, no index.html changes, and therefore
-- no "apply both halves together" deploy hazard like the profiles fix had.
--
-- Policy lookup below is dynamic, not guessed, for the same reason as the
-- profiles migration: hand-guessing a policy name to drop is unsafe (e.g.
-- Supabase's own starter templates sometimes include punctuation or wording
-- that a guess list won't match), so this queries pg_policies directly for
-- whatever the real policy names are and drops each by its actual name.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) No pre-flight "an INSERT policy must already exist" guard here, and
--    deliberately so. Earlier drafts of this migration aborted if
--    public.messages had zero existing INSERT policies, on the reasoning
--    that "DM-sending works today, so some permissive INSERT policy must
--    exist." That reasoning doesn't hold: DM-sending working today is
--    equally (arguably more) consistent with RLS being fully *disabled* on
--    messages — zero policies of any kind, with Supabase's default
--    table-level grant letting inserts through regardless of RLS. That is
--    in fact the single most likely real explanation for the anon-SELECT
--    leak this migration exists to fix in the first place, since the exact
--    same "no RLS at all" state also explains unrestricted reads.
--
--    Unlike the profiles migration (20260906010000), which does NOT create
--    its own INSERT policy and so genuinely needs a guard against enabling
--    RLS with none present, this migration creates its own correct INSERT
--    policy unconditionally below (`messages_insert_own`, scoped to
--    auth.uid() = sender_id) regardless of what existed before. So there is
--    nothing to guard: zero pre-existing policies is a legitimate, expected
--    starting state — most likely the actual current state in production —
--    and this migration handles it correctly by simply creating the new
--    SELECT and INSERT policies below rather than treating it as a failure.
--
--    Enabling RLS here is also safe in that "currently disabled, zero
--    policies" scenario specifically: the messages table is confirmed empty
--    in production today (see note atop this file — anon SELECT currently
--    returns `200 []`), so there's no existing row-visibility question to
--    reason about, and this migration installs both a correct SELECT policy
--    (participant-only, below) and a correct INSERT policy (own sender_id,
--    below) in the same transaction as enabling RLS, so nothing is stranded
--    without coverage at any point after this migration finishes.
-- ----------------------------------------------------------------------------

alter table public.messages enable row level security;

-- ----------------------------------------------------------------------------
-- 1) SELECT: dynamically look up and drop every permissive SELECT policy on
--    public.messages by its real name, whatever that name actually is (same
--    approach as the profiles migration — see the note above on why a
--    guessed name list is unsafe). Aborts instead of dropping if it finds a
--    permissive FOR ALL policy, since blind-dropping that would also strip
--    whatever INSERT coverage rides along with it, which isn't this fix's
--    call to make — that needs a human to split it into explicit policies
--    first.
-- ----------------------------------------------------------------------------
do $$
declare
  names text[];
  nm text;
begin
  select coalesce(array_agg(policyname), '{}')
    into names
  from pg_policies
  where schemaname = 'public' and tablename = 'messages'
    and permissive = 'PERMISSIVE' and cmd = 'SELECT';

  foreach nm in array names loop
    execute format('drop policy %I on public.messages', nm);
    raise notice 'Dropped permissive SELECT policy: %', nm;
  end loop;

  if exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'messages'
      and permissive = 'PERMISSIVE' and cmd = 'ALL'
  ) then
    raise exception 'public.messages has a permissive FOR ALL policy that still grants public SELECT. Split it into explicit INSERT/SELECT policies first, then re-run.';
  end if;
end $$;

-- A message is visible only to its two participants — no "read other
-- people's DMs" use case exists anywhere in this app, so no public view is
-- needed here (unlike profiles/gyms, which have a legitimate public-read
-- surface).
create policy "messages_select_participant"
  on public.messages for select
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- Post-condition: confirm no other permissive SELECT/ALL policy survived the
-- drop loop above. Postgres RLS policies are OR'd together, so any leftover
-- permissive read policy would completely defeat this fix with no error
-- anywhere else.
do $$
declare leftover text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ') into leftover
  from pg_policies
  where schemaname = 'public' and tablename = 'messages'
    and permissive = 'PERMISSIVE' and cmd in ('SELECT','ALL')
    and policyname <> 'messages_select_participant';
  if leftover is not null then
    raise exception 'Leftover permissive read policy on public.messages: %', leftover;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2) INSERT: the read fix above doesn't address a second, related risk —
--    with only an anon key and no scoped INSERT check, anyone could also
--    INSERT a message claiming to be any sender_id, not just read other
--    people's DMs. Every insert call site in index.html already sets
--    sender_id to the caller's own auth id (`sender_id:user.id`), so a
--    `with check (auth.uid() = sender_id)` policy matches real usage exactly
--    and breaks nothing legitimate.
--
--    We can't safely guess what any pre-existing INSERT policy checks (or
--    doesn't) without querying it, so this looks it up the same dynamic way
--    as SELECT above rather than assuming. Three possible shapes, all
--    handled: zero permissive INSERT policies (RLS was off, or on with no
--    INSERT policy at all — the expected case, most likely the real current
--    state — nothing to drop, just create the scoped policy below), exactly
--    one (replace it with the scoped version), or more than one (an
--    unexpected shape for this table — abort for manual review rather than
--    guessing which one is "the" policy to replace).
-- ----------------------------------------------------------------------------
do $$
declare
  names text[];
  nm text;
begin
  select coalesce(array_agg(policyname), '{}')
    into names
  from pg_policies
  where schemaname = 'public' and tablename = 'messages'
    and permissive = 'PERMISSIVE' and cmd = 'INSERT';

  if array_length(names, 1) > 1 then
    raise exception 'public.messages has more than one permissive INSERT policy (%); resolve manually before scoping INSERT to sender_id.', array_to_string(names, ', ');
  end if;

  foreach nm in array names loop
    execute format('drop policy %I on public.messages', nm);
    raise notice 'Dropped permissive INSERT policy: %', nm;
  end loop;
end $$;

create policy "messages_insert_own"
  on public.messages for insert
  with check (auth.uid() = sender_id);

-- Post-condition: confirm no other permissive INSERT/ALL policy survived.
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

-- ----------------------------------------------------------------------------
-- NOT included in this migration, deliberately:
-- 1. No change to UPDATE/DELETE on messages. No current feature edits or
--    deletes a DM, so no policy for either exists to reason about here. If
--    RLS was previously disabled and some other undocumented path relied on
--    UPDATE/DELETE working via an anon/authenticated key, enabling RLS above
--    with no UPDATE/DELETE policy will now default-deny both, which is the
--    safe direction for a table storing private message content. Worth a
--    quick manual check after applying that nothing unexpected relied on
--    editing/deleting messages.
-- 2. No public view — unlike profiles/gyms there is no legitimate "browse
--    other people's DMs" feature, so nothing needs a public read surface for
--    this table.
-- 3. No index.html changes — every existing read/write call site already
--    scopes itself to the current user, so nothing in the app needs to
--    change to work correctly under these tightened policies.
-- ----------------------------------------------------------------------------
