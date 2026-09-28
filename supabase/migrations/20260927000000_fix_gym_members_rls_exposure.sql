-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself. Do not run this
-- against any database from this session or any automated tool.
--
-- URGENT — same severity class as the 2026-09-10 profiles/messages exposure
-- fixes. Apply this before anything else in this batch.
-- ============================================================================
--
-- CONFIRMED LIVE, 2026-09-27, via unauthenticated curl against the real
-- production REST API using the public anon key already shipped in
-- index.html: `public.gym_members` has NEVER had row-level security enabled.
-- The 2026-09-06 migration (20260906000000_roster_follow_review_verify_schema.sql)
-- added column-level INSERT/UPDATE grants for this table but never ran
-- `alter table ... enable row level security` and never created a single
-- policy on it — so Supabase's default table-level grants apply with zero
-- row-level restriction. Live proof (anon key, no login):
--   GET /gym_members?select=* returned every row, including one with
--   status='pending' — a real user's UUID and the fact that they'd
--   requested to join a specific gym, visible to anyone on the internet.
--
-- This is worse than a read-only leak. Because RLS is fully off (not just
-- under-scoped), and DELETE was never touched by any migration at all:
--   - Any authenticated user can UPDATE any gym_members row's `status` to
--     'approved' for ANY gym (the column-level grant restricts WHICH
--     COLUMN, not WHICH ROW) — self-approve a pending request, or falsely
--     approve someone else's.
--   - Any authenticated user can DELETE any gym_members row for ANY gym
--     (DELETE was never column-or-row restricted by anything) — kick any
--     member out of any gym's roster at will.
-- Both are real integrity risks on top of the read-side privacy leak.
--
-- Fix, matching this project's established pattern (profiles/messages 2026-
-- 09-10, gyms.verified_venue PR #17): enable RLS, and scope every operation
-- to exactly what the real call sites in index.html need — verified by
-- grepping every `.from('gym_members')` site (lines ~1690, 1715, 1732,
-- 1742, 1753, 1772):
--   - SELECT: the app's own comment says it plainly — "approved (public) +
--     pending (owner sees these)". Public sees approved rows; a member sees
--     their own row regardless of status; the gym's owner sees every row
--     for gyms they own (needed for the approve/decline queue).
--   - INSERT: a user requesting to join sets their own row (gym_id, own
--     user_id, status='pending') — already column-scoped by the 2026-09-06
--     migration; this adds the missing row check (auth.uid() = user_id).
--   - UPDATE: only the gym owner may approve (already column-scoped to
--     `status` only by 2026-09-06; this adds the missing owner-only row
--     check).
--   - DELETE: the member themselves (withdraw) or the gym's owner (decline/
--     remove) — never touched by any prior migration, so this is a new row
--     AND new coverage, not just tightening an existing gap.
-- ============================================================================

alter table public.gym_members enable row level security;

drop policy if exists "gym_members_select_approved_own_or_owner" on public.gym_members;
create policy "gym_members_select_approved_own_or_owner"
  on public.gym_members for select
  using (
    status = 'approved'
    or user_id = auth.uid()
    or exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid())
  );

drop policy if exists "gym_members_insert_own_pending" on public.gym_members;
create policy "gym_members_insert_own_pending"
  on public.gym_members for insert
  with check (
    auth.uid() = user_id
    and status = 'pending'
  );

drop policy if exists "gym_members_update_owner_only" on public.gym_members;
create policy "gym_members_update_owner_only"
  on public.gym_members for update
  using (exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid()))
  with check (exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid()));

drop policy if exists "gym_members_delete_own_or_owner" on public.gym_members;
create policy "gym_members_delete_own_or_owner"
  on public.gym_members for delete
  using (
    user_id = auth.uid()
    or exists (select 1 from public.gyms g where g.id = gym_id and g.owner_id = auth.uid())
  );

-- Post-condition: confirm no permissive policy slipped through with a
-- different name/shape than intended (same style of check this project's
-- other RLS migrations use).
do $$
declare leftover text;
begin
  select string_agg(policyname || ' (' || cmd || ')', ', ') into leftover
  from pg_policies
  where schemaname = 'public' and tablename = 'gym_members'
    and permissive = 'PERMISSIVE'
    and policyname not in (
      'gym_members_select_approved_own_or_owner',
      'gym_members_insert_own_pending',
      'gym_members_update_owner_only',
      'gym_members_delete_own_or_owner'
    );
  if leftover is not null then
    raise exception 'Leftover/unexpected permissive policy on public.gym_members: %', leftover;
  end if;
end $$;

notify pgrst, 'reload schema';
