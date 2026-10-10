-- EarthMotion Phase 1 — Storage policies for report photos
-- Run this AFTER creating a Storage bucket named 'report-photos' in the
-- Supabase dashboard (Storage → New bucket → Public bucket: ON).
--
-- Public/ON on the bucket lets anyone load photo URLs directly (needed for
-- the map popups and moderation queue). These RLS policies add the write
-- side, which the bucket toggle alone doesn't cover: only signed-in users
-- may upload, and only into a folder named after their own user id
-- (report photos are stored as `${user_id}/${uuid}.jpg`, see js/submit.js).
--
-- Open consideration from the brief: photos may show identifiable private
-- property. Revisit whether the bucket should stay public before any wider
-- launch — see "Privacy" in section 7 of the build brief.

CREATE POLICY report_photos_public_read ON storage.objects FOR SELECT
  USING (bucket_id = 'report-photos');

CREATE POLICY report_photos_owner_upload ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'report-photos'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- No UPDATE/DELETE policy: uploaded photos are immutable from the client,
-- matching "genuine, unedited photo" in the submission flow requirements.
