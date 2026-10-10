-- EarthMotion Phase 2 — data export
-- Run after sql/01–06.
--
-- Backs the admin dashboard's CSV/GeoJSON export buttons. Moderator-only
-- for now: the brief frames this as "internal analysis," and long-term
-- data-sharing/licensing is explicitly an open, undecided question (§7) —
-- so this stays behind the same moderator gate as the rest of the admin
-- dashboard rather than becoming an open public bulk-download endpoint
-- (a full-dataset CSV grab is a bigger exposure than one map popup at a
-- time, especially with reports possibly near people's homes). Revisit
-- once data-sharing terms are actually decided.
--
-- Deliberately excludes user_id/username even from moderators' export:
-- moderation only needs to know *what* and *where*, not attribute a bulk
-- coordinate list to a specific person. Approved reports only — pending/
-- rejected submissions were never public.
CREATE OR REPLACE FUNCTION get_export_data()
RETURNS TABLE (
  id UUID,
  category TEXT,
  region TEXT,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  description TEXT,
  photo_url TEXT,
  is_first_flag BOOLEAN,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    r.id, hc.name, reg.name,
    ST_Y(r.location::geometry), ST_X(r.location::geometry),
    r.description, r.photo_url, r.is_first_flag, r.created_at
  FROM reports r
  JOIN hazard_categories hc ON hc.id = r.category_id
  LEFT JOIN regions reg ON reg.id = r.region_id
  WHERE r.status = 'approved'
    AND is_current_user_moderator()
    -- Matches the map's visibility rule (sql/06): a report the community
    -- confirmed resolved via a recheck is no longer a "current" hazard.
    -- (Scalar subquery returns NULL when there's no flag at all, and
    -- NULL IS DISTINCT FROM 'resolved' is true, so unflagged reports pass.)
    AND (
      SELECT rf.status FROM recheck_flags rf
      WHERE rf.report_id = r.id
      ORDER BY rf.flagged_at DESC LIMIT 1
    ) IS DISTINCT FROM 'resolved';
$$;

GRANT EXECUTE ON FUNCTION get_export_data TO authenticated;
