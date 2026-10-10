// National/regional leaderboard + badge showcase. Points come from the
// get_leaderboard RPC (sql/05), which caps each contributor's top 30
// reports for the month before summing — see brief §3.
import { supabase } from './supabaseClient.js';
import { mountAuthWidget, getSession } from './auth.js';

mountAuthWidget(document.getElementById('auth-widget'), { onChange: () => loadBadges() });

const periodInput = document.getElementById('lb-period');
const scopeSelect = document.getElementById('lb-scope');
periodInput.value = new Date().toISOString().slice(0, 7); // "YYYY-MM"

async function loadRegions() {
  const { data: regions } = await supabase.from('regions').select('id, name').order('name');
  (regions || []).forEach((r) => {
    const opt = document.createElement('option');
    opt.value = r.id;
    opt.textContent = r.name;
    scopeSelect.appendChild(opt);
  });
}

async function loadLeaderboard() {
  const period = periodInput.value; // "YYYY-MM"
  const regionId = scopeSelect.value || null;
  const { data, error } = await supabase.rpc('get_leaderboard', {
    p_period: period,
    p_region_id: regionId,
  });
  const body = document.getElementById('lb-body');
  if (error) {
    console.error('[EarthMotion] failed to load leaderboard', error);
    body.innerHTML = '<tr><td colspan="4">Could not load the leaderboard.</td></tr>';
    return;
  }
  body.innerHTML = (data || []).map((row, i) => `
    <tr>
      <td>${i + 1}</td>
      <td>${escapeHtml(row.username)}</td>
      <td>${row.monthly_points}</td>
      <td>${row.report_count}</td>
    </tr>`).join('') || '<tr><td colspan="4">No approved reports yet for this month.</td></tr>';
}

periodInput.addEventListener('change', loadLeaderboard);
scopeSelect.addEventListener('change', loadLeaderboard);

// ---- Badges ----
const BADGE_TYPE_EMOJI = { tier: '🏅', regional: '📍', consistency: '📆', diversity: '🧭' };

async function loadBadges() {
  const { data: badges } = await supabase.from('badges').select('*').order('badge_type').order('threshold');
  let earnedIds = new Set();
  const session = await getSession();
  if (session) {
    const { data: earned } = await supabase.from('user_badges').select('badge_id').eq('user_id', session.user.id);
    earnedIds = new Set((earned || []).map((e) => e.badge_id));
  }

  document.getElementById('badge-list').innerHTML = (badges || []).map((b) => {
    const earned = earnedIds.has(b.id);
    return `
      <div style="display:flex; gap:0.6rem; align-items:flex-start; padding:0.5rem 0; ${earned ? '' : 'opacity:0.5;'}">
        <span style="font-size:1.4rem;">${BADGE_TYPE_EMOJI[b.badge_type] || '🎖️'}</span>
        <div>
          <strong>${escapeHtml(b.name)}</strong> ${earned ? '<span class="em-status" style="color:var(--em-green);">EARNED</span>' : ''}
          <div style="color:var(--em-muted); font-size:0.85rem;">${escapeHtml(b.description || '')}</div>
        </div>
      </div>`;
  }).join('');
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

await loadRegions();
await loadLeaderboard();
await loadBadges();
