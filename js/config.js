// Fill these in after creating your Supabase project
// (Project Settings → API → Project URL / anon public key).
//
// The anon key is meant to be public — it ships in the page source and
// only grants what the RLS policies in sql/01_rls_and_security.sql allow.
export const SUPABASE_URL = 'https://egoousaxkuhinyrchkiy.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_GkOXBFcc1ZnBLTqVK77YWg_7xWl2N3m';

// Must match the Storage bucket created per sql/03_storage_policies.sql.
export const PHOTO_BUCKET = 'report-photos';

// Default map view (Indonesia-wide) before geolocation/filters narrow it.
export const DEFAULT_MAP_CENTER = [-2.5, 118.0];
export const DEFAULT_MAP_ZOOM = 5;
