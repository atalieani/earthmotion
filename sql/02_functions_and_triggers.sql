-- EarthMotion Phase 1 — functions & triggers
-- Run this AFTER sql/01_rls_and_security.sql.
--
-- Covers three things the schema comments describe but don't implement yet:
--  1. Auto-create a profile row when someone signs up (profiles.username is
--     NOT NULL, so signup can't insert straight into auth.users alone).
--  2. Compute is_first_flag and award points atomically when a moderator
--     approves a report — this must happen in one transaction in Postgres,
--     not as two separate calls from the admin dashboard's browser client.
--  3. RPCs the frontend calls for things plain PostgREST filters can't do:
--     geography construction on submit, a viewport bounding-box query for
--     the map (using the GIST index instead of fetching every report), and
--     the "is there already a similar report near here?" duplicate check.

-- ──────────────────────────────────────────────
-- 1. New user → profile row
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO profiles (id, username)
  VALUES (
    NEW.id,
    -- Placeholder username derived from the email; users can rename via
    -- the "edit username" control in the app header (see js/auth.js).
    split_part(NEW.email, '@', 1) || '_' || substr(NEW.id::text, 1, 4)
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ──────────────────────────────────────────────
-- 2a. BEFORE UPDATE: compute is_first_flag at the moment of approval.
-- Doing this here (not at submission time) matches the schema comment —
-- "true if no prior APPROVED report of this category exists nearby" — and
-- reflects the map's true state at approval time, not submission time.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION handle_report_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'approved' AND OLD.status IS DISTINCT FROM 'approved' THEN
    NEW.is_first_flag := NOT EXISTS (
      SELECT 1 FROM reports r
      WHERE r.id <> NEW.id
        AND r.category_id = NEW.category_id
        AND r.status = 'approved'
        AND ST_DWithin(r.location, NEW.location, 50)
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS before_report_approval ON reports;
CREATE TRIGGER before_report_approval
  BEFORE UPDATE ON reports
  FOR EACH ROW EXECUTE FUNCTION handle_report_approval();

-- ──────────────────────────────────────────────
-- 2b. AFTER UPDATE: award points once a report transitions to 'approved'.
-- SECURITY DEFINER because the moderator's own role has no grant to write
-- points_log or profiles.total_points directly (see sql/01) — this
-- function is the only path to those writes, and it runs in the same
-- transaction as the approval so counts can't drift.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION award_points_on_approval()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  total INTEGER := 10; -- approved_report base
BEGIN
  IF NEW.status = 'approved' AND OLD.status IS DISTINCT FROM 'approved' THEN
    INSERT INTO points_log (user_id, report_id, points, reason)
    VALUES (NEW.user_id, NEW.id, 10, 'approved_report');

    IF NEW.description IS NOT NULL AND length(trim(NEW.description)) > 0 THEN
      INSERT INTO points_log (user_id, report_id, points, reason)
      VALUES (NEW.user_id, NEW.id, 2, 'description_bonus');
      total := total + 2;
    END IF;

    IF NEW.is_first_flag THEN
      INSERT INTO points_log (user_id, report_id, points, reason)
      VALUES (NEW.user_id, NEW.id, 5, 'first_flag_bonus');
      total := total + 5;
    END IF;

    UPDATE profiles SET total_points = total_points + total WHERE id = NEW.user_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS after_report_approval ON reports;
CREATE TRIGGER after_report_approval
  AFTER UPDATE ON reports
  FOR EACH ROW EXECUTE FUNCTION award_points_on_approval();

-- ──────────────────────────────────────────────
-- 3a. submit_report — builds the geography point server-side and inserts
-- as the calling user, so a report can never be submitted on someone
-- else's behalf even though the RLS insert policy also checks user_id.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION submit_report(
  p_category_id INTEGER,
  p_lng DOUBLE PRECISION,
  p_lat DOUBLE PRECISION,
  p_photo_url TEXT,
  p_description TEXT DEFAULT NULL,
  p_region_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
AS $$
DECLARE
  new_id UUID;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Must be signed in to submit a report';
  END IF;

  INSERT INTO reports (user_id, category_id, region_id, location, photo_url, description)
  VALUES (
    auth.uid(),
    p_category_id,
    p_region_id,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
    p_photo_url,
    NULLIF(trim(p_description), '')
  )
  RETURNING id INTO new_id;

  RETURN new_id;
END;
$$;

-- ──────────────────────────────────────────────
-- 3b. get_reports_in_view — viewport-based marker loading for the public
-- map. Uses && against the GIST index (reports_location_idx) so it stays
-- fast as the dataset grows, per the brief's "load by viewport" requirement.
-- ──────────────────────────────────────────────
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
  lat DOUBLE PRECISION
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    r.id, r.category_id, hc.name, hc.icon_key, reg.name,
    r.photo_url, r.description, r.created_at,
    ST_X(r.location::geometry), ST_Y(r.location::geometry)
  FROM reports r
  JOIN hazard_categories hc ON hc.id = r.category_id
  LEFT JOIN regions reg ON reg.id = r.region_id
  WHERE r.status = 'approved'
    AND r.location && ST_MakeEnvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
    AND (p_category_ids IS NULL OR r.category_id = ANY(p_category_ids))
    AND (p_region_id IS NULL OR r.region_id = p_region_id)
    AND (p_date_from IS NULL OR r.created_at >= p_date_from)
    AND (p_date_to IS NULL OR r.created_at <= p_date_to);
$$;

-- ──────────────────────────────────────────────
-- 3c. check_nearby_reports — non-blocking duplicate hint shown to the user
-- before they submit (mirrors the example query at the bottom of the
-- schema file). Only surfaces already-public (approved) reports.
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_nearby_reports(
  p_lng DOUBLE PRECISION,
  p_lat DOUBLE PRECISION,
  p_category_id INTEGER,
  p_radius_m DOUBLE PRECISION DEFAULT 50
)
RETURNS TABLE (id UUID, description TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql
STABLE
AS $$
  SELECT r.id, r.description, r.created_at
  FROM reports r
  WHERE r.status = 'approved'
    AND r.category_id = p_category_id
    AND ST_DWithin(r.location, ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, p_radius_m);
$$;

GRANT EXECUTE ON FUNCTION submit_report TO authenticated;
GRANT EXECUTE ON FUNCTION get_reports_in_view TO anon, authenticated;
GRANT EXECUTE ON FUNCTION check_nearby_reports TO anon, authenticated;
