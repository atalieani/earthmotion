// Moderation dashboard. Gated on profiles.is_moderator (set manually in the
// DB for now — small internal team per the brief, no self-serve signup for
// moderator status). The RLS policies in sql/01 are the real enforcement:
// this client-side check only controls what's *shown*, since a non-
// moderator's queries would come back empty/denied regardless.
import { supabase } from './supabaseClient.js';
import { mountAuthWidget } from './auth.js';

const notAuthorized = document.getElementById('not-authorized');
const queueWrap = document.getElementById('queue-wrap');

mountAuthWidget(document.getElementById('auth-widget'), {
  onChange: (profile) => {
    const isModerator = !!profile?.is_moderator;
    notAuthorized.style.display = isModerator ? 'none' : '';
    queueWrap.style.display = isModerator ? '' : 'none';
    if (isModerator) loadQueue();
  },
});

// ---- Maintenance actions (Phase 2) ----
const maintenanceMsg = document.getElementById('maintenance-msg');

document.getElementById('flag-stale-btn').addEventListener('click', async () => {
  const days = Number(prompt('Flag approved reports older than how many days?', '180'));
  if (!days || days <= 0) return;
  const { data, error } = await supabase.rpc('flag_stale_reports', { p_days_old: days });
  maintenanceMsg.textContent = error
    ? 'Could not flag reports: ' + error.message
    : `Flagged ${data} report(s) for recheck.`;
});

document.getElementById('recompute-badges-btn').addEventListener('click', async () => {
  const [regional, consistency] = await Promise.all([
    supabase.rpc('compute_regional_badges'),
    supabase.rpc('compute_consistency_badges'),
  ]);
  if (regional.error || consistency.error) {
    maintenanceMsg.textContent = 'Could not recompute badges: ' +
      (regional.error?.message || consistency.error?.message);
    return;
  }
  maintenanceMsg.textContent =
    `Awarded ${regional.data} regional badge(s) and ${consistency.data} consistency badge(s).`;
});

document.getElementById('export-csv-btn').addEventListener('click', async () => {
  const rows = await fetchExportData();
  if (!rows) return;
  const header = Object.keys(rows[0] ?? { id: '', category: '', region: '', lat: '', lng: '', description: '', photo_url: '', is_first_flag: '', created_at: '' });
  const csv = [header.join(',')]
    .concat(rows.map((r) => header.map((k) => csvEscape(r[k])).join(',')))
    .join('\n');
  downloadFile(csv, 'earthmotion-reports.csv', 'text/csv');
});

document.getElementById('export-geojson-btn').addEventListener('click', async () => {
  const rows = await fetchExportData();
  if (!rows) return;
  const geojson = {
    type: 'FeatureCollection',
    features: rows.map((r) => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [r.lng, r.lat] },
      properties: {
        id: r.id, category: r.category, region: r.region, description: r.description,
        photo_url: r.photo_url, is_first_flag: r.is_first_flag, created_at: r.created_at,
      },
    })),
  };
  downloadFile(JSON.stringify(geojson, null, 2), 'earthmotion-reports.geojson', 'application/geo+json');
});

async function fetchExportData() {
  const { data, error } = await supabase.rpc('get_export_data');
  if (error) {
    maintenanceMsg.textContent = 'Could not export: ' + error.message;
    return null;
  }
  if (!data || data.length === 0) {
    maintenanceMsg.textContent = 'Nothing to export yet.';
    return null;
  }
  maintenanceMsg.textContent = `Exporting ${data.length} approved report(s)…`;
  return data;
}

function csvEscape(value) {
  const str = value === null || value === undefined ? '' : String(value);
  return /[",\n]/.test(str) ? `"${str.replace(/"/g, '""')}"` : str;
}

function downloadFile(content, filename, mimeType) {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

async function loadQueue() {
  const { data, error } = await supabase
    .from('reports')
    .select(`
      id, description, photo_url, created_at,
      hazard_categories ( name ),
      profiles!reports_user_id_fkey ( username )
    `)
    .eq('status', 'pending')
    .order('created_at', { ascending: true });

  if (error) {
    console.error('[EarthMotion] failed to load moderation queue', error);
    return;
  }

  document.getElementById('queue-count').textContent = `(${data.length})`;
  const body = document.getElementById('queue-body');
  body.innerHTML = data.map(rowHtml).join('') ||
    '<tr><td colspan="6">Nothing pending — queue is clear 🎉</td></tr>';

  body.querySelectorAll('.em-approve').forEach((btn) =>
    btn.addEventListener('click', () => approve(btn.dataset.id)));
  body.querySelectorAll('.em-reject').forEach((btn) =>
    btn.addEventListener('click', () => reject(btn.dataset.id)));
}

function rowHtml(r) {
  const date = new Date(r.created_at).toLocaleString();
  return `
    <tr>
      <td><a href="${r.photo_url}" target="_blank" rel="noopener"><img src="${r.photo_url}" alt="" /></a></td>
      <td>${escapeHtml(r.hazard_categories?.name ?? '—')}</td>
      <td>${escapeHtml(r.description ?? '')}</td>
      <td>${escapeHtml(r.profiles?.username ?? '—')}</td>
      <td>${date}</td>
      <td class="em-row-actions">
        <button class="em-approve" data-id="${r.id}">Approve</button>
        <button class="em-btn-danger em-reject" data-id="${r.id}">Reject</button>
      </td>
    </tr>`;
}

async function approve(reportId) {
  const session = (await supabase.auth.getSession()).data.session;
  const { error } = await supabase
    .from('reports')
    .update({ status: 'approved', reviewed_by: session.user.id, reviewed_at: new Date().toISOString() })
    .eq('id', reportId);
  if (error) return alert('Could not approve: ' + error.message);
  loadQueue();
}

async function reject(reportId) {
  const reason = prompt('Rejection reason (shown to the submitter):');
  if (reason === null) return; // cancelled
  const session = (await supabase.auth.getSession()).data.session;
  const { error } = await supabase
    .from('reports')
    .update({
      status: 'rejected',
      rejection_reason: reason || 'No reason given',
      reviewed_by: session.user.id,
      reviewed_at: new Date().toISOString(),
    })
    .eq('id', reportId);
  if (error) return alert('Could not reject: ' + error.message);
  loadQueue();
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}
