-- EarthMotion Phase 1 — seed data
-- Optional but recommended so the app has something to show immediately.
-- icon_key values here must match js/hazards.js — if you add a category,
-- add a matching entry there too (it falls back to a generic marker
-- otherwise, so nothing breaks, it just won't have a distinct icon/color).

INSERT INTO hazard_categories (name, description, icon_key) VALUES
  ('Flood-prone drainage', 'Clogged, undersized, or damaged drainage likely to cause flooding.', 'flood_drainage'),
  ('Landslide-prone slope', 'Steep or eroding slope near homes/roads with landslide risk.', 'landslide_slope'),
  ('Cracked seawall', 'Coastal/riverside wall showing cracks, gaps, or structural damage.', 'cracked_seawall'),
  ('Illegal riverbank construction', 'Unauthorized building that narrows or blocks a waterway.', 'riverbank_construction'),
  ('Fire hazard', 'Conditions with elevated fire risk (e.g. dense illegal wiring, dry brush).', 'fire_hazard'),
  ('Other', 'Any other standing disaster risk not covered above.', 'other')
ON CONFLICT DO NOTHING;

-- A couple of example regions to populate the submission form's region
-- picker. Replace with real kelurahan/kecamatan data for your pilot area.
INSERT INTO regions (name, region_type) VALUES
  ('DKI Jakarta', 'provinsi'),
  ('Kota Jakarta Selatan', 'kabupaten_kota')
ON CONFLICT DO NOTHING;
