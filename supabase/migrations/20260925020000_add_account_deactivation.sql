-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED. Kaden applies this himself. Do not run this
-- against any database from this session or any automated tool.
--
-- ORDERING: no dependency on the other 2026-09-25 migrations — can be applied
-- independently of them, in any order relative to those two.
-- ============================================================================
--
-- Purpose: Launch checklist Phase 1 gap — there is no self-service way for a
-- user to delete/deactivate their own account today (grepped confirmed: no
-- "delete account" call site anywhere in index.html). CCPA/GDPR-style
-- deletion rights don't strictly require instant irreversible hard-delete —
-- a defined deactivation is an accepted pattern — but doing nothing isn't.
--
-- Scope decision: SOFT deactivation, not a hard cascading delete. This app's
-- schema is deeply interlinked (rental_requests/rental_agreements/
-- venue_bookings, events_general, messages, reels/reel_comments, follows,
-- gym_members, user_blocks, content_reports all reference profiles.id).
-- A hard delete attempted quickly risks FK violations or orphaned rows in
-- exactly the kind of multi-table migration this project's own review
-- history (see LEARNINGS.md) has repeatedly found subtle bugs in. Soft
-- deactivation is real (the account disappears from the directory, they're
-- signed out immediately and can't log back in) and reversible if Kaden
-- needs to undo it for someone, without the cascading-delete risk. A true
-- hard-delete pipeline (e.g. for an explicit legal deletion request) is a
-- separate, deliberate future task, not this one.
-- ============================================================================

alter table public.profiles
  add column if not exists is_active boolean not null default true;

-- Add is_active to the client-writable column list alongside the others —
-- symmetric and low-risk: RLS already scopes profiles UPDATE to the row
-- owner (auth.uid() = id), so a user can only ever flip their OWN
-- visibility, never anyone else's. No new function needed, unlike
-- is_admin/is_moderator which required SECURITY DEFINER because those
-- DO let one account affect another's privileges.
grant update (is_active) on public.profiles to authenticated;

-- profiles_public (20260906010000) is the only public-facing read surface
-- for OTHER users' profile data — directory, gym rosters, DM pickers, the
-- venue-rental party lookups, everything. Excluding deactivated accounts
-- here is what makes "delete my account" actually mean something: they stop
-- being findable/messageable app-wide in one place, without touching every
-- individual query site.
--
-- Re-creating this view WITHOUT `security_invoker = true` is deliberate —
-- see the original migration's warning: profiles' only SELECT policy is
-- owner-only, so an invoker-rights view would make every lookup of another
-- user's row return zero rows. Do not add security_invoker = true here.
drop view if exists public.profiles_public;
create view public.profiles_public as
select
  id,
  display_name,
  username,
  avatar_url,
  role,
  role_info
from public.profiles
where is_active;

grant select on public.profiles_public to anon, authenticated;

notify pgrst, 'reload schema';
