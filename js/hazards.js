// Maps hazard_categories.icon_key (admin-managed in the DB, see
// sql/04_seed_data.sql) to a marker color, an SVG icon file, and an emoji
// fallback. Any icon_key not listed here falls back to the generic "other"
// style, so a newly-added admin category never breaks rendering. An entry
// with icon: null shows its emoji instead of an SVG.
export const HAZARD_STYLES = {
  flood_drainage: { color: '#2b7fff', emoji: '🌊', icon: 'assets/icons/flood_drainage.svg' },
  landslide_slope: { color: '#a0522d', emoji: '⛰️', icon: 'assets/icons/landslide_slope.svg' },
  cracked_seawall: { color: '#0891b2', emoji: '🧱', icon: 'assets/icons/cracked_seawall.svg' },
  riverbank_construction: { color: '#f59e0b', emoji: '🏗️', icon: 'assets/icons/riverbank_construction.svg' },
  fire_hazard: { color: '#dc2626', emoji: '🔥', icon: 'assets/icons/fire_hazard.svg' },
  coastal_erosion: { color: '#7c3aed', emoji: '🏖️', icon: 'assets/icons/coastal_erosion.svg' },
  other: { color: '#6b7280', emoji: '❗', icon: null },
};

export function styleFor(iconKey) {
  return HAZARD_STYLES[iconKey] || HAZARD_STYLES.other;
}

// The icon as HTML. The SVG is used as a mask, so it takes on the text color
// of whatever it sits in (dark on a white chip, white on a selected chip).
export function iconHTML(iconKey) {
  const { emoji, icon } = styleFor(iconKey);
  if (!icon) return emoji;
  return `<span class="hz-icon" style="-webkit-mask-image:url('${icon}');mask-image:url('${icon}')"></span>`;
}

// A small colored div-icon, used instead of Leaflet's default pin so
// each hazard category is visually distinct on the map at a glance.
export function hazardDivIcon(iconKey) {
  const { color } = styleFor(iconKey);
  return L.divIcon({
    className: 'em-marker',
    html: `<span class="em-marker-dot" style="background:${color}">${iconHTML(iconKey)}</span>`,
    iconSize: [28, 28],
    iconAnchor: [14, 14],
    popupAnchor: [0, -14],
  });
}
