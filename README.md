# EarthMotion — Phase 1 + 2

A static frontend (no build step) + Supabase backend, per `earthmotion_webgis_build_brief.md`.
Phase 1: public map, submission flow, basic points, simple moderation queue.
Phase 2: badges, national/regional leaderboards, recheck-flag prompts, data export.

## What's here

```
earthmotion_schema.sql        original core schema (tables)
sql/
  01_rls_and_security.sql     Row Level Security — the real access control,
                               since the anon key is public in the page source
  02_functions_and_triggers.sql  new-user profile creation, points-on-approval
                               trigger, is_first_flag calc, viewport/duplicate RPCs
  03_storage_policies.sql     who can upload/read report photos
  04_seed_data.sql            the 6 hazard categories + example regions
  05_badges_and_leaderboards.sql  badge defs, tier/diversity auto-award,
                               regional/consistency compute RPCs, get_leaderboard
  06_recheck_flags.sql        who can confirm a recheck, flag_stale_reports sweep,
                               extends get_reports_in_view with recheck status
  07_export.sql                moderator-only CSV/GeoJSON export RPC

index.html, js/map.js          public map (clustering + heatmap toggle + filters + recheck prompts)
submit.html, js/submit.js      4-step submission flow
admin/index.html, js/admin.js  moderation queue + maintenance tools + export
leaderboard.html, js/leaderboard.js  national/regional leaderboard + badge showcase
js/auth.js                     shared magic-link sign-in widget (used on every page)
js/hazards.js                  icon_key → marker color/emoji mapping
js/config.js                   Supabase URL/anon key — fill in below
css/styles.css                 shared styling
```

## Setup

1. **Create a Supabase project** at supabase.com.
2. **Run the SQL, in order**, in the Supabase SQL editor:
   `earthmotion_schema.sql` → `sql/01` → `sql/02` → `sql/04` → `sql/05` → `sql/06` → `sql/07`.
   (`sql/03` needs the storage bucket to exist first — see next step.)
3. **Storage:** create a bucket named `report-photos`, mark it **Public**, then run `sql/03_storage_policies.sql`.
4. **Auth:** in Authentication → Providers, make sure Email is enabled. The app uses magic-link sign-in (`signInWithOtp`), not passwords — no extra config needed beyond the default.
5. **Fill in `js/config.js`** with your project's URL and anon (public) key from Project Settings → API. The anon key is *meant* to be public — everything it can do is governed by the RLS policies in `sql/01`.
6. **Make yourself a moderator** (until there's an admin UI for this): sign in once via the app so your profile row exists, then in the SQL editor:
   ```sql
   update profiles set is_moderator = true where username = 'your_generated_username';
   ```
7. **Run it locally.** ES modules need to be served over http(s), not opened as a `file://` path:
   ```
   npm run dev
   ```
   then open the printed localhost URL. (Any static server works — this just saves an install step.)
8. **Deploy:** it's a static site, so GitHub Pages or Azure Static Web Apps both work with zero config — just publish this folder.

## Phase 2 maintenance tasks

Two things aren't reactive to a single event (unlike points/tier/diversity badges,
which award themselves at approval time) — they compare across users or across
time, so they're moderator-triggered RPCs instead:

- **Recompute regional/consistency badges** — button in the admin dashboard, calls
  `compute_regional_badges()` and `compute_consistency_badges()`. Run monthly.
- **Flag stale reports for recheck** — button in the admin dashboard, calls
  `flag_stale_reports(days_old)`. Run periodically (e.g. monthly).

Both are plain SQL functions, so if you want them to run themselves instead of
being a dashboard button, enable the `pg_cron` extension (Database → Extensions)
and schedule them, e.g.:
```sql
select cron.schedule('em-flag-stale', '0 3 1 * *', $$select flag_stale_reports(180)$$);
select cron.schedule('em-regional-badges', '0 3 1 * *', $$select compute_regional_badges()$$);
select cron.schedule('em-consistency-badges', '0 3 1 * *', $$select compute_consistency_badges()$$);
```

## How the pieces fit together

- **Points are never awarded by the client.** `award_points_on_approval()` (sql/02) runs as a Postgres trigger the instant a moderator's UPDATE sets `reports.status = 'approved'`, in the same transaction. This is also where `is_first_flag` gets computed — at approval time, not submission time, since that's when "is there already an approved report nearby" is actually true.
- **The map never fetches the whole `reports` table.** `js/map.js` calls the `get_reports_in_view` RPC with the current viewport bounds on every pan/zoom (debounced), which filters with `&&` against the GIST spatial index.
- **Submission goes through the `submit_report` RPC**, not a raw insert, so the geography point is constructed server-side from lat/lng and the row is always inserted as the calling user — the RLS insert policy backs this up, but the RPC avoids fiddly PostGIS type-casting in the JS client.
- **Moderators still can't forge points or write `points_log` directly** — only the SECURITY DEFINER trigger function can, even though moderators can update `reports.status`.
- **The leaderboard is the one place a client function bypasses another table's RLS on purpose.** `get_leaderboard()` (sql/05) is `SECURITY DEFINER` because it has to sum `points_log` across every user, which that table's own RLS (read-your-own-rows-only) would otherwise block — it only ever returns an aggregate (username, total, count), never raw ledger rows.
- **A "resolved" recheck retires the marker.** `get_reports_in_view` and the export RPC both hide a report once its *most recent* recheck flag has `status = 'resolved'` — a later stale-sweep can still re-flag and re-surface it. Any signed-in user can confirm/resolve a pending flag, not just the original submitter or a moderator; only *creating* flags (`flag_stale_reports`) and force-escalating are moderator-only.
- **Data export is moderator-only**, not a public endpoint — the brief treats it as "internal analysis" and leaves external data-sharing/licensing as an open, undecided question (§7), so `get_export_data()` deliberately isn't exposed to the anon key the way the map/leaderboard RPCs are.

## Known limitations (by design — see build brief §6–7)

- `capture="environment"` on the photo input is a *hint* that mobile browsers mostly honor to open the camera directly; desktop browsers will still show a normal file picker. There's no way to fully block gallery uploads from a web page — worth knowing since the brief calls out wanting a "live, unedited photo."
- No per-user rate limiting on submissions yet (brief §7 flags this as an open consideration) — would be a good addition to `submit_report()` before wider rollout (e.g. reject if the user has >N reports in the last 24h).
- Report photos are stored in a fully public bucket for MVP simplicity. Revisit before a public launch given photos may show identifiable private property (brief §7).
- The consistency badge counts *distinct* months with an approved report, not strictly *consecutive* ones — simpler to compute, but worth revisiting if "multi-month contributor" is meant to reward an unbroken streak specifically.
- Regional "most active" ties: everyone tied for the top report count in a region/month gets the badge (no tiebreaker) — a deliberate simplification, not a bug.
- Phase 3 (institutional data-sharing with agencies like BPBD) is intentionally not started — brief §6 gates it behind EarthMotion's institutional-partnership phase, which hasn't begun.
