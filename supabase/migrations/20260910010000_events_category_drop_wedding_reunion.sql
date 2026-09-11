-- ============================================================================
-- DRAFT MIGRATION — NOT APPLIED YET. Kaden applies this himself.
-- ============================================================================
--
-- Purpose: ACTION-NEEDED.md item 4, Option A. events_general already exists in
-- production (20260905000000 was applied before this decision landed), so
-- dropping wedding/reunion now needs an ALTER instead of a pre-apply file
-- edit. Table is empty in production as of 2026-09-10 (verified via anon
-- probe) — no rows use the old 'wedding'/'reunion' values, so this is a
-- zero-data-loss constraint swap. Also adds 'pickup' and 'league' so a casual
-- pickup game or a recurring league has a real category instead of being
-- filed as "Tournament" or "Other".
--
-- Safe to run once; re-running no-ops via IF EXISTS.
-- ============================================================================

alter table public.events_general
  drop constraint if exists events_general_category_check;

alter table public.events_general
  add constraint events_general_category_check
  check (category in ('tournament','fundraiser','showcase','pickup','league','other'));

notify pgrst, 'reload schema';
