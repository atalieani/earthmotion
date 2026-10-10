-- EarthMotion Phase 2 — badges & leaderboards
-- Run after sql/01–04.
--
-- Badge strategy, split by how each one can be computed:
--  - tier (bronze/silver/gold) and diversity depend only on the approving
--    user's own history, so they're awarded synchronously in the same
--    trigger transaction as the approval — no cross-user data needed.
--  - regional "most active" and consistency need to compare across users
--    or across time, so they're periodic recomputations exposed as
--    moderator-only RPCs (wire a button to them in the admin dashboard, or
--    schedule with pg_cron — see README).
--
-- user_badges.period is nullable per the base schema, but NULL is treated
-- as distinct-from-NULL in the UNIQUE(user_id, badge_id, period) constraint,
-- which would defeat ON CONFLICT DO NOTHING for non-periodic badges. We use
-- '' (empty string) as the "not period-scoped" sentinel instead, and real
-- 'YYYY-MM' strings only for the regional badge.

INSERT INTO badges (code, name, description, badge_type, threshold) VALUES
  ('bronze_contributor', 'Bronze Contributor', 'Awarded for 5 approved reports.', 'tier', 5),
  ('silver_contributor', 'Silver Contributor', 'Awarded for 20 approved reports.', 'tier', 20),
  ('gold_contributor', 'Gold Contributor', 'Awarded for 50 approved reports.', 'tier', 50),
  ('diversity_explorer', 'Hazard Explorer', 'Awarded for documenting 4+ distinct hazard types.', 'diversity', 4),
  ('consistency_streak', 'Steady Reporter', 'Awarded for contributing approved reports in 3+ different months.', 'consistency', 3),
  ('regional_most_active', 'Most Active This Month', 'Top contributor in your region for the month.', 'regional', NULL)
ON CONFLICT (code) DO NOTHING;

-- ──────────────────────────────────────────────
-- Tier + diversity: awarded at approval time
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION award_badges_on_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  approved_count INTEGER;
  distinct_categories INTEGER;
BEGIN
  IF NEW.status = 'approved' AND OLD.status IS DISTINCT FROM 'approved' THEN
    SELECT count(*) INTO approved_count FROM reports WHERE user_id = NEW.user_id AND status = 'approved';
    SELECT count(DISTINCT category_id) INTO distinct_categories FROM reports WHERE user_id = NEW.user_id AND status = 'approved';

    INSERT INTO user_badges (user_id, badge_id, period)
    SELECT NEW.user_id, id, ''
    FROM badges
    WHERE badge_type = 'tier' AND threshold <= approved_count
    ON CONFLICT (user_id, badge_id, period) DO NOTHING;

    INSERT INTO user_badges (user_id, badge_id, period)
    SELECT NEW.user_id, id, ''
    FROM badges
    WHERE badge_type = 'diversity' AND threshold <= distinct_categories
    ON CONFLICT (user_id, badge_id, period) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS after_report_approval_badges ON reports;
CREATE TRIGGER after_report_approval_badges
  AFTER UPDATE ON reports
  FOR EACH ROW EXECUTE FUNCTION award_badges_on_approval();

-- ──────────────────────────────────────────────
-- Regional "most active": top contributor(s) per region for a given month.
-- Ties all get the badge (RANK, not ROW_NUMBER). Moderator-only — call from
-- the admin dashboard's "Recompute badges" button, ideally once a month.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION compute_regional_badges(p_period TEXT DEFAULT to_char(now(), 'YYYY-MM'))
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected INTEGER;
BEGIN
  IF NOT is_current_user_moderator() THEN
    RAISE EXCEPTION 'Moderator access required';
  END IF;

  WITH counts AS (
    SELECT region_id, user_id, count(*) AS cnt,
           RANK() OVER (PARTITION BY region_id ORDER BY count(*) DESC) AS rnk
    FROM reports
    WHERE status = 'approved' AND region_id IS NOT NULL AND to_char(created_at, 'YYYY-MM') = p_period
    GROUP BY region_id, user_id
  ), top AS (
    SELECT user_id FROM counts WHERE rnk = 1
  )
  INSERT INTO user_badges (user_id, badge_id, period)
  SELECT top.user_id, badges.id, p_period
  FROM top, badges
  WHERE badges.code = 'regional_most_active'
  ON CONFLICT (user_id, badge_id, period) DO NOTHING;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

-- ──────────────────────────────────────────────
-- Consistency: contributed approved reports in 3+ distinct calendar months
-- (not required to be consecutive — a simplification worth revisiting if
-- "multi-month" is meant more strictly). Moderator-only, same reason as above.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION compute_consistency_badges()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  affected INTEGER;
BEGIN
  IF NOT is_current_user_moderator() THEN
    RAISE EXCEPTION 'Moderator access required';
  END IF;

  WITH months AS (
    SELECT user_id, count(DISTINCT to_char(created_at, 'YYYY-MM')) AS months_active
    FROM reports
    WHERE status = 'approved'
    GROUP BY user_id
  ), qualifying AS (
    SELECT months.user_id
    FROM months, badges
    WHERE badges.code = 'consistency_streak' AND months.months_active >= badges.threshold
  )
  INSERT INTO user_badges (user_id, badge_id, period)
  SELECT qualifying.user_id, badges.id, ''
  FROM qualifying, badges
  WHERE badges.code = 'consistency_streak'
  ON CONFLICT (user_id, badge_id, period) DO NOTHING;

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

GRANT EXECUTE ON FUNCTION compute_regional_badges TO authenticated;
GRANT EXECUTE ON FUNCTION compute_consistency_badges TO authenticated;

-- ──────────────────────────────────────────────
-- Leaderboard: national (p_region_id NULL) or regional, for a given month,
-- capped at each user's top N reports by points (brief §3: cap submissions
-- counted toward the prize so raw volume can't dominate over variety).
--
-- SECURITY DEFINER is required here: points_log's RLS (sql/01) only lets a
-- user read their own rows, but a public leaderboard needs to sum points
-- across everyone. This function only ever returns an aggregate
-- (username + total + count), never raw ledger rows, so it doesn't leak
-- anything points_log's own policy is protecting against.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_leaderboard(
  p_period TEXT DEFAULT to_char(now(), 'YYYY-MM'),
  p_region_id UUID DEFAULT NULL,
  p_cap_per_user INTEGER DEFAULT 30,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (user_id UUID, username TEXT, monthly_points BIGINT, report_count BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH report_points AS (
    SELECT r.user_id, r.id AS report_id, sum(pl.points) AS points
    FROM reports r
    JOIN points_log pl ON pl.report_id = r.id
    WHERE r.status = 'approved'
      AND to_char(r.created_at, 'YYYY-MM') = p_period
      AND (p_region_id IS NULL OR r.region_id = p_region_id)
    GROUP BY r.user_id, r.id
  ), ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY points DESC) AS rn
    FROM report_points
  )
  SELECT p.id, p.username, sum(ranked.points), count(*)
  FROM ranked
  JOIN profiles p ON p.id = ranked.user_id
  WHERE ranked.rn <= p_cap_per_user
  GROUP BY p.id, p.username
  ORDER BY sum(ranked.points) DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION get_leaderboard TO anon, authenticated;
