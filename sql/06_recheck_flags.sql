-- EarthMotion Phase 2 — recheck flags
-- Run after sql/01–05.
--
-- Turns "is this hazard still there?" into a crowdsourced check: any
-- signed-in user (not just the original submitter) can confirm or resolve
-- a pending flag — moderators can additionally escalate. Flags themselves
-- are created by a moderator-triggered sweep (flag_stale_reports), not by
-- individual users, so this stays a deliberate review action rather than
-- something spammable.

-- ──────────────────────────────────────────────
-- Who can update a recheck flag, and how
-- ──────────────────────────────────────────────
REVOKE UPDATE ON recheck_flags FROM authenticated;
GRANT UPDATE (status, confirmed_by, confirmed_at) ON recheck_flags TO authenticated;

-- Any signed-in user may resolve a currently-pending flag as
-- still-present/resolved, attributing the confirmation to themselves.
CREATE POLICY recheck_flags_confirm ON recheck_flags FOR UPDATE
  USING (status = 'pending')
  WITH CHECK (status IN ('still_present', 'resolved') AND confirmed_by = auth.uid());

-- Moderators can additionally move a flag to any status (e.g. escalate).
CREATE POLICY recheck_flags_moderator_update ON recheck_flags FOR UPDATE
  USING (is_current_user_moderator())
  WITH CHECK (is_current_user_moderator());

-- ──────────────────────────────────────────────
-- flag_stale_reports — moderator sweep that opens a recheck flag for
-- approved reports older than N days that don't already have one pending.
-- Wire this to a button in the admin dashboard, or automate via pg_cron:
--   select cron.schedule('em-flag-stale', '0 3 1 * *', $$select flag_stale_reports(180)$$);
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION flag_stale_reports(p_days_old INTEGER DEFAULT 180)
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

  INSERT INTO recheck_flags (report_id)
  SELECT r.id FROM reports r
  WHERE r.status = 'approved'
    AND r.created_at < now() - (p_days_old || ' days')::interval
    AND NOT EXISTS (
      SELECT 1 FROM recheck_flags rf WHERE rf.report_id = r.id AND rf.status = 'pending'
    );

  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END;
$$;

GRANT EXECUTE ON FUNCTION flag_stale_reports TO authenticated;

-- ──────────────────────────────────────────────
-- Extend get_reports_in_view (sql/02) with the report's current pending
-- recheck flag, if any, so the map popup can offer the confirm/resolve
-- prompt without a second round-trip per marker. Return type is changing,
-- so the old function must be dropped first (CREATE OR REPLACE can't do it).
-- ──────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_reports_in_view(
  double precision, double precision, double precision, double precision,
  integer[], uuid, timestamptz, timestamptz
);

CREATE OR REPLACE FUNCTION get_reports_in_view(
  min_lng DOUBLE PRECISION,
  min_lat DOUBLE PRECISION,
  max_lng DOUBLE PRECISION,
  max_lat DOUBLE PRECISION,
  p_category_ids INTEGER[] DEFAULT NULL,
  p_region_id UUID DEFAULT NULL,
  p_date_from TIMESTAMPTZ DEFAULT NULL,
  p_date_to TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  category_id INTEGER,
  category_name TEXT,
  icon_key TEXT,
  region_name TEXT,
  photo_url TEXT,
  description TEXT,
  created_at TIMESTAMPTZ,
  lng DOUBLE PRECISION,
  lat DOUBLE PRECISION,
  recheck_flag_id UUID,
  recheck_status TEXT
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    r.id, r.category_id, hc.name, hc.icon_key, reg.name,
    r.photo_url, r.description, r.created_at,
    ST_X(r.location::geometry), ST_Y(r.location::geometry),
    CASE WHEN rf.status = 'pending' THEN rf.id END,
    CASE WHEN rf.status = 'pending' THEN rf.status END
  FROM reports r
  JOIN hazard_categories hc ON hc.id = r.category_id
  LEFT JOIN regions reg ON reg.id = r.region_id
  -- Most recent recheck flag of any status, so a report the community
  -- marked 'resolved' drops off the map instead of showing forever; a
  -- later stale-sweep can still re-flag it and bring it back as 'pending'.
  LEFT JOIN LATERAL (
    SELECT id, status FROM recheck_flags
    WHERE report_id = r.id
    ORDER BY flagged_at DESC LIMIT 1
  ) rf ON true
  WHERE r.status = 'approved'
    AND (rf.status IS NULL OR rf.status <> 'resolved')
    AND r.location && ST_MakeEnvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
    AND (p_category_ids IS NULL OR r.category_id = ANY(p_category_ids))
    AND (p_region_id IS NULL OR r.region_id = p_region_id)
    AND (p_date_from IS NULL OR r.created_at >= p_date_from)
    AND (p_date_to IS NULL OR r.created_at <= p_date_to);
$$;

GRANT EXECUTE ON FUNCTION get_reports_in_view TO anon, authenticated;
