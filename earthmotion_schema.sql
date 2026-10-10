-- EarthMotion: Community Disaster-Risk Reporting WebGIS
-- Basic schema, designed for PostgreSQL + PostGIS (e.g. via Supabase)

CREATE EXTENSION IF NOT EXISTS postgis;

-- ─────────────────────────────────────────────
-- REGIONS
-- Lookup table for admin areas (kelurahan/kecamatan/etc),
-- used for regional leaderboards and badges.
-- ─────────────────────────────────────────────
CREATE TABLE regions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  region_type TEXT NOT NULL CHECK (region_type IN ('kelurahan','kecamatan','kabupaten_kota','provinsi')),
  parent_region_id UUID REFERENCES regions(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────
-- HAZARD CATEGORIES
-- Admin-managed lookup (flood-prone drainage, landslide slope, etc).
-- ─────────────────────────────────────────────
CREATE TABLE hazard_categories (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  icon_key TEXT
);

-- ─────────────────────────────────────────────
-- PROFILES
-- Extends Supabase's built-in auth.users with app-specific data.
-- total_points is a cached value for fast leaderboard reads;
-- the real source of truth is points_log below.
-- ─────────────────────────────────────────────
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE NOT NULL,
  home_region_id UUID REFERENCES regions(id),
  total_points INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────
-- REPORTS
-- The core table: one row per geotagged submission.
-- ─────────────────────────────────────────────
CREATE TABLE reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  category_id INTEGER NOT NULL REFERENCES hazard_categories(id),
  region_id UUID REFERENCES regions(id),
  location GEOGRAPHY(POINT, 4326) NOT NULL,   -- captured via navigator.geolocation, confirmed by pin-drop
  photo_url TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  rejection_reason TEXT,
  is_first_flag BOOLEAN NOT NULL DEFAULT false,  -- true if no prior approved report of this category exists nearby
  reviewed_by UUID REFERENCES profiles(id),
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Spatial index: powers both map rendering and duplicate/proximity checks
CREATE INDEX reports_location_idx ON reports USING GIST (location);
CREATE INDEX reports_status_idx ON reports (status);
CREATE INDEX reports_category_idx ON reports (category_id);
CREATE INDEX reports_region_idx ON reports (region_id);
CREATE INDEX reports_created_at_idx ON reports (created_at);

-- ─────────────────────────────────────────────
-- POINTS LOG
-- An append-only ledger, not just a running counter —
-- lets you audit, reverse, or explain any point award later.
-- ─────────────────────────────────────────────
CREATE TABLE points_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  report_id UUID REFERENCES reports(id),
  points INTEGER NOT NULL,
  reason TEXT NOT NULL CHECK (reason IN ('approved_report','description_bonus','first_flag_bonus','manual_adjustment')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─────────────────────────────────────────────
-- BADGES
-- Definitions of available badges (tier / regional / consistency / diversity).
-- ─────────────────────────────────────────────
CREATE TABLE badges (
  id SERIAL PRIMARY KEY,
  code TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  badge_type TEXT NOT NULL CHECK (badge_type IN ('tier','regional','consistency','diversity')),
  threshold INTEGER
);

-- Which users have earned which badges.
-- `period` (e.g. '2026-08') allows repeatable monthly regional badges.
CREATE TABLE user_badges (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  badge_id INTEGER NOT NULL REFERENCES badges(id),
  period TEXT,
  awarded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, badge_id, period)
);

-- ─────────────────────────────────────────────
-- RECHECK FLAGS
-- Periodic "is this hazard still there?" prompts for older reports,
-- turning one-off submissions into an ongoing monitoring layer.
-- ─────────────────────────────────────────────
CREATE TABLE recheck_flags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID NOT NULL REFERENCES reports(id),
  flagged_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','still_present','resolved','escalated')),
  confirmed_by UUID REFERENCES profiles(id),
  confirmed_at TIMESTAMPTZ
);

-- ─────────────────────────────────────────────
-- EXAMPLE QUERY: duplicate/proximity check before showing
-- a submission as a "first flag" candidate (within 50 meters)
-- ─────────────────────────────────────────────
-- SELECT id FROM reports
-- WHERE ST_DWithin(location, ST_SetSRID(ST_MakePoint(:lng, :lat), 4326)::geography, 50)
--   AND category_id = :category_id
--   AND status = 'approved';
