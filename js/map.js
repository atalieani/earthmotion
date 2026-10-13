// Public map: viewport-based loading (via the get_reports_in_view RPC,
// sql/02) so we never fetch the whole reports table, clustering for dense
// areas, category/region/date filters, and an optional heatmap toggle.
import { supabase } from './supabaseClient.js';
import { mountAuthWidget, getSession } from './auth.js';
import { hazardDivIcon, styleFor, iconHTML } from './hazards.js';
import { DEFAULT_MAP_CENTER, DEFAULT_MAP_ZOOM } from './config.js';

mountAuthWidget(document.getElementById('auth-widget'));

const map = L.map('map', { zoomControl: true }).setView(DEFAULT_MAP_CENTER, DEFAULT_MAP_ZOOM);

L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=cb1_45o8_1_153595582f622e88eb0f067b', {
  attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
  subdomains: 'abcd',
  maxZoom: 19,
}).addTo(map);

const clusterLayer = L.markerClusterGroup();
map.addLayer(clusterLayer);
let heatLayer = null;
let showHeat = false;

let allCategories = []; // {id, name, icon_key}
let selectedCategoryIds = new Set();

async function loadFilterOptions() {
  const { data: categories, error: catErr } = await supabase
    .from('hazard_categories')
    .select('id, name, icon_key')
    .order('name');
  if (catErr) return console.error(catErr);

  allCategories = categories;
  const container = document.getElementById('category-filters');
  container.innerHTML = categories.map((c) => {
    const { color, emoji } = styleFor(c.icon_key);
    return `
      <label>
        <input type="checkbox" value="${c.id}" checked />
        ${iconHTML(c.icon_key)} ${escapeHtml(c.name)}
      </label>`;
  }).join('');
  selectedCategoryIds = new Set(categories.map((c) => c.id));
  container.querySelectorAll('input[type="checkbox"]').forEach((cb) => {
    cb.addEventListener('change', () => {
      const id = Number(cb.value);
      if (cb.checked) selectedCategoryIds.add(id);
      else selectedCategoryIds.delete(id);
      refresh();
    });
  });

  const { data: regions, error: regErr } = await supabase
    .from('regions')
    .select('id, name')
    .order('name');
  if (regErr) return console.error(regErr);
  const regionSelect = document.getElementById('region-filter');
  regions.forEach((r) => {
    const opt = document.createElement('option');
    opt.value = r.id;
    opt.textContent = r.name;
    regionSelect.appendChild(opt);
  });
}

function currentFilters() {
  const bounds = map.getBounds();
  const regionId = document.getElementById('region-filter').value || null;
  const dateFrom = document.getElementById('date-from').value || null;
  const dateTo = document.getElementById('date-to').value || null;
  return {
    min_lng: bounds.getWest(),
    min_lat: bounds.getSouth(),
    max_lng: bounds.getEast(),
    max_lat: bounds.getNorth(),
    p_category_ids: allCategories.length ? [...selectedCategoryIds] : null,
    p_region_id: regionId,
    p_date_from: dateFrom,
    p_date_to: dateTo ? `${dateTo}T23:59:59Z` : null,
  };
}

async function refresh() {
  const { data, error } = await supabase.rpc('get_reports_in_view', currentFilters());
  if (error) {
    console.error('[EarthMotion] failed to load reports', error);
    return;
  }
  renderMarkers(data || []);
}

function renderMarkers(reports) {
  clusterLayer.clearLayers();
  const markers = reports.map((r) => {
    const marker = L.marker([r.lat, r.lng], { icon: hazardDivIcon(r.icon_key) });
    // Bound to a live DOM element (not an HTML string) so the recheck
    // confirm/resolve buttons below can carry real event listeners.
    marker.bindPopup(buildPopupContent(r));
    return marker;
  });
  clusterLayer.addLayers(markers);

  if (heatLayer) { map.removeLayer(heatLayer); heatLayer = null; }
  if (showHeat) {
    heatLayer = L.heatLayer(reports.map((r) => [r.lat, r.lng, 0.6]), { radius: 25 });
    map.addLayer(heatLayer);
  }

  document.getElementById('result-count').textContent =
    `${reports.length} report${reports.length === 1 ? '' : 's'} in view`;
}

document.getElementById('heatmap-toggle').addEventListener('change', (e) => {
  showHeat = e.target.checked;
  if (showHeat) { map.removeLayer(clusterLayer); } else { map.addLayer(clusterLayer); }
  refresh();
});
document.getElementById('region-filter').addEventListener('change', refresh);
document.getElementById('date-from').addEventListener('change', refresh);
document.getElementById('date-to').addEventListener('change', refresh);

let debounceTimer;
map.on('moveend zoomend', () => {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(refresh, 300);
});

function buildPopupContent(r) {
  const date = new Date(r.created_at).toLocaleDateString();
  const el = document.createElement('div');
  el.className = 'em-popup';
  el.innerHTML = `
    <img src="${r.photo_url}" alt="${escapeHtml(r.category_name)} photo" loading="lazy" />
    <strong>${escapeHtml(r.category_name)}</strong><br/>
    ${r.description ? `<p>${escapeHtml(r.description)}</p>` : ''}
    ${r.region_name ? `<div>${escapeHtml(r.region_name)}</div>` : ''}
    <div class="em-status">Reported ${date}</div>
  `;

  if (r.recheck_flag_id) {
    const box = document.createElement('div');
    box.className = 'em-warning';
    box.innerHTML = `
      <div>🔁 Flagged for a recheck — is this hazard still here?</div>
      <div class="em-row-actions" style="margin-top:0.4rem;">
        <button type="button" class="em-recheck-still">Still there</button>
        <button type="button" class="em-btn-secondary em-recheck-resolved">Resolved</button>
      </div>
      <div class="em-recheck-msg" style="margin-top:0.3rem;"></div>
    `;
    const msg = box.querySelector('.em-recheck-msg');
    box.querySelector('.em-recheck-still').addEventListener('click', () =>
      confirmRecheck(r.recheck_flag_id, 'still_present', msg));
    box.querySelector('.em-recheck-resolved').addEventListener('click', () =>
      confirmRecheck(r.recheck_flag_id, 'resolved', msg));
    el.appendChild(box);
  }

  return el;
}

async function confirmRecheck(flagId, status, msgEl) {
  const session = await getSession();
  if (!session) {
    msgEl.textContent = 'Sign in (top right) to confirm a recheck.';
    return;
  }
  const { error } = await supabase
    .from('recheck_flags')
    .update({ status, confirmed_by: session.user.id, confirmed_at: new Date().toISOString() })
    .eq('id', flagId);
  msgEl.textContent = error ? 'Could not save: ' + error.message : 'Thanks — recorded.';
  if (!error) refresh();
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

await loadFilterOptions();
await refresh();
