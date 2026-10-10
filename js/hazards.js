// Maps hazard_categories.icon_key (admin-managed in the DB, see
// sql/04_seed_data.sql) to a marker color + emoji glyph for the map and
// forms. Any icon_key not listed here falls back to a generic marker, so a
// newly-added admin category never breaks rendering — it just looks generic
// until someone adds a matching entry below.
export const HAZARD_STYLES = {
  flood_drainage: { color: '#2b7fff', emoji: '🌊' },
  landslide_slope: { color: '#a0522d', emoji: '⛰️' },
  cracked_seawall: { color: '#0891b2', emoji: '🧱' },
  riverbank_construction: { color: '#f59e0b', emoji: '🏗️' },
  fire_hazard: { color: '#dc2626', emoji: '🔥' },
  coastal_erosion: { color: '#f97316', emoji: '🏖️' },
  other: { color: '#6b7280', emoji: '❗' },
};

export function styleFor(iconKey) {
  return HAZARD_STYLES[iconKey] || HAZARD_STYLES.other;
}

// A small colored/emoji div-icon, used instead of Leaflet's default pin so
// each hazard category is visually distinct on the map at a glance.
export function hazardDivIcon(iconKey) {
  const { color, emoji } = styleFor(iconKey);
  return L.divIcon({
    className: 'em-marker',
    html: `<span class="em-marker-dot" style="background:${color}">${emoji}</span>`,
    iconSize: [28, 28],
    iconAnchor: [14, 14],
    popupAnchor: [0, -14],
  });
}
