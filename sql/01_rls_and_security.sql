-- EarthMotion Phase 1 — Row Level Security
-- Run this AFTER earthmotion_schema.sql, in the Supabase SQL editor.
--
-- Why this file exists: the frontend is a static site using Supabase's
-- public "anon" key, which anyone can read out of the page source. That key
-- is meant to be public — it only grants what these policies allow. Every
-- table PostgREST exposes must have RLS enabled or the anon key can read/
-- write it directly, so we lock everything down here, even Phase 2/3 tables
-- that the frontend doesn't touch yet.

-- ──────────────────────────────────────────────
-- profiles: add a moderator flag (not in the base schema)
-- ──────────────────────────────────────────────
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_moderator BOOLEAN NOT NULL DEFAULT false;

-- Small helper so policies below don't repeat this subquery everywhere.
CREATE OR REPLACE FUNCTION is_current_user_moderator()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((SELECT is_moderator FROM profiles WHERE id = auth.uid()), false);
$$;

-- ──────────────────────────────────────────────
-- regions / hazard_categories — admin-managed lookups.
-- Public read, no client writes (edited via SQL editor / dashboard for now,
-- per the brief: "no institutional partnerships yet, small internal team").
-- ──────────────────────────────────────────────
ALTER TABLE regions ENABLE ROW LEVEL SECURITY;
CREATE POLICY regions_select_all ON regions FOR SELECT USING (true);

ALTER TABLE hazard_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY hazard_categories_select_all ON hazard_categories FOR SELECT USING (true);

-- ──────────────────────────────────────────────
-- profiles
-- Public read (needed for leaderboards/usernames next to reports).
-- Users may update their own row, but NOT total_points or is_moderator —
-- those are only ever touched by the SECURITY DEFINER trigger below, which
-- runs as the function owner and bypasses these grants entirely.
-- ──────────────────────────────────────────────
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_select_all ON profiles FOR SELECT USING (true);

CREATE POLICY profiles_update_own ON profiles FOR UPDATE
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

REVOKE UPDATE ON profiles FROM authenticated;
GRANT UPDATE (username, home_region_id) ON profiles TO authenticated;

-- profiles are created by the handle_new_user trigger (sql/02), not inserted
-- by the client, so no INSERT policy is granted to authenticated/anon.

-- ──────────────────────────────────────────────
-- reports
-- Public can see approved reports. Authenticated users can also see their
-- own reports regardless of status. Moderators can see everything.
-- ──────────────────────────────────────────────
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY reports_select ON reports FOR SELECT
  USING (
    status = 'approved'
    OR user_id = auth.uid()
    OR is_current_user_moderator()
  );

-- Users can only submit as themselves, only as 'pending', and can't
-- pre-set is_first_flag or reviewed_* fields — those are decided at
-- moderation time, not by the submitter.
CREATE POLICY reports_insert_own ON reports FOR INSERT
  WITH CHECK (
    user_id = auth.uid()
    AND status = 'pending'
    AND is_first_flag = false
    AND reviewed_by IS NULL
    AND reviewed_at IS NULL
  );

-- Only moderators can update reports (approve/reject). Submitters cannot
-- edit after submitting in Phase 1.
CREATE POLICY reports_update_moderator ON reports FOR UPDATE
  USING (is_current_user_moderator())
  WITH CHECK (is_current_user_moderator());

-- No DELETE policy for anyone — reports are kept for audit history.

-- ──────────────────────────────────────────────
-- points_log — append-only ledger.
-- Users can read their own entries; moderators can read all (for audits).
-- No direct INSERT/UPDATE/DELETE — only the SECURITY DEFINER trigger in
-- sql/02 writes here, so a moderator's own client access can't forge points.
-- ──────────────────────────────────────────────
ALTER TABLE points_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY points_log_select_own_or_moderator ON points_log FOR SELECT
  USING (user_id = auth.uid() OR is_current_user_moderator());

-- ──────────────────────────────────────────────
-- badges / user_badges / recheck_flags — Phase 2 features, but the tables
-- already exist in the schema, so lock them down now rather than leave
-- them open. Public read (they're social/transparency data); no client
-- writes yet — those land with the Phase 2 build.
-- ──────────────────────────────────────────────
ALTER TABLE badges ENABLE ROW LEVEL SECURITY;
CREATE POLICY badges_select_all ON badges FOR SELECT USING (true);

ALTER TABLE user_badges ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_badges_select_all ON user_badges FOR SELECT USING (true);

ALTER TABLE recheck_flags ENABLE ROW LEVEL SECURITY;
CREATE POLICY recheck_flags_select_all ON recheck_flags FOR SELECT USING (true);
