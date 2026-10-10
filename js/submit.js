// Submission flow: photo capture → pin-drop location → category → optional
// description → submit. Requires sign-in (see js/auth.js for the magic-link
// flow). Photo upload + the geography insert are split so we can show a
// friendly error if either step fails without losing the user's work.
import { supabase } from './supabaseClient.js';
import { mountAuthWidget, getSession } from './auth.js';
import { styleFor } from './hazards.js';
import { PHOTO_BUCKET, DEFAULT_MAP_CENTER } from './config.js';

const state = {
  photoFile: null,
  lat: null,
  lng: null,
  categoryId: null,
  categoryIconKey: null,
  regionId: null,
};

const form = document.getElementById('submit-form');
const signinRequired = document.getElementById('signin-required');

mountAuthWidget(document.getElementById('auth-widget'), {
  onChange: (profile) => {
    form.style.display = profile ? '' : 'none';
    signinRequired.style.display = profile ? 'none' : '';
  },
});

// ---- Step navigation ----
document.querySelectorAll('.em-next').forEach((btn) =>
  btn.addEventListener('click', () => goToStep(btn.dataset.next)));
document.querySelectorAll('.em-back').forEach((btn) =>
  btn.addEventListener('click', () => goToStep(btn.dataset.back)));

function goToStep(step) {
  document.querySelectorAll('.em-step').forEach((el) => {
    el.classList.toggle('active', el.dataset.step === String(step));
  });
  if (step === '2') initPinMap();
  if (step === '4') checkNearby();
}

// ---- Step 1: photo ----
const photoInput = document.getElementById('photo-input');
const photoPreview = document.getElementById('photo-preview');
photoInput.addEventListener('change', () => {
  const file = photoInput.files[0];
  if (!file) return;
  state.photoFile = file;
  photoPreview.src = URL.createObjectURL(file);
  photoPreview.style.display = 'block';
});

// ---- Step 2: location ----
let pinMap, pinMarker, pinMapInitialized = false;

function initPinMap() {
  if (pinMapInitialized) { setTimeout(() => pinMap.invalidateSize(), 50); return; }
  pinMapInitialized = true;
  const start = [state.lat ?? DEFAULT_MAP_CENTER[0], state.lng ?? DEFAULT_MAP_CENTER[1]];
  pinMap = L.map('pin-map').setView(start, state.lat ? 16 : 5);
  L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=cb1_45o8_1_153595582f622e88eb0f067b', {
    attribution: '&copy; OpenStreetMap contributors &copy; CARTO', subdomains: 'abcd', maxZoom: 19,
  }).addTo(pinMap);
  pinMarker = L.marker(start, { draggable: true }).addTo(pinMap);
  pinMarker.on('dragend', () => setLocation(pinMarker.getLatLng()));
  if (state.lat) setLocation({ lat: state.lat, lng: state.lng });
}

function setLocation(latlng) {
  state.lat = latlng.lat;
  state.lng = latlng.lng;
}

document.getElementById('locate-btn').addEventListener('click', () => {
  if (!navigator.geolocation) return alert('Geolocation is not available in this browser.');
  navigator.geolocation.getCurrentPosition(
    (pos) => {
      const latlng = { lat: pos.coords.latitude, lng: pos.coords.longitude };
      setLocation(latlng);
      if (pinMapInitialized) {
        pinMap.setView(latlng, 16);
        pinMarker.setLatLng(latlng);
      }
    },
    (err) => alert('Could not get your location: ' + err.message),
    { enableHighAccuracy: true, timeout: 10000 }
  );
});

// ---- Step 3: category + region ----
async function loadCategoriesAndRegions() {
  const { data: categories } = await supabase.from('hazard_categories').select('id, name, icon_key').order('name');
  const list = document.getElementById('category-list');
  list.innerHTML = (categories || []).map((c) => {
    const { color, emoji } = styleFor(c.icon_key);
    return `
      <label>
        <input type="radio" name="category" value="${c.id}" data-icon="${c.icon_key}" />
        <span style="color:${color}">${emoji}</span> ${escapeHtml(c.name)}
      </label>`;
  }).join('');
  list.querySelectorAll('input[name="category"]').forEach((input) => {
    input.addEventListener('change', () => {
      state.categoryId = Number(input.value);
      state.categoryIconKey = input.dataset.icon;
    });
  });

  const { data: regions } = await supabase.from('regions').select('id, name').order('name');
  const regionSelect = document.getElementById('region-select');
  (regions || []).forEach((r) => {
    const opt = document.createElement('option');
    opt.value = r.id;
    opt.textContent = r.name;
    regionSelect.appendChild(opt);
  });
  regionSelect.addEventListener('change', () => { state.regionId = regionSelect.value || null; });
}

// ---- Step 4: non-blocking duplicate hint ----
async function checkNearby() {
  const box = document.getElementById('nearby-warning');
  box.innerHTML = '';
  if (state.lat == null || !state.categoryId) return;
  const { data, error } = await supabase.rpc('check_nearby_reports', {
    p_lng: state.lng, p_lat: state.lat, p_category_id: state.categoryId,
  });
  if (error || !data || data.length === 0) return;
  box.innerHTML = `<div class="em-warning">There ${data.length === 1 ? 'is' : 'are'} already ${data.length}
    approved report${data.length === 1 ? '' : 's'} of this hazard type within 50m. You can still submit —
    just note it may be reviewed as a possible duplicate.</div>`;
}

// ---- Submit ----
form.addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('submit-error');
  errorEl.textContent = '';

  if (!state.photoFile) return (errorEl.textContent = 'A photo is required.');
  if (state.lat == null) return (errorEl.textContent = 'A location is required.');
  if (!state.categoryId) return (errorEl.textContent = 'A hazard type is required.');

  const session = await getSession();
  if (!session) return (errorEl.textContent = 'You must be signed in.');

  const submitBtn = document.getElementById('submit-btn');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Submitting…';

  try {
    const ext = (state.photoFile.name.split('.').pop() || 'jpg').toLowerCase();
    const path = `${session.user.id}/${crypto.randomUUID()}.${ext}`;
    const { error: uploadError } = await supabase.storage
      .from(PHOTO_BUCKET)
      .upload(path, state.photoFile, { contentType: state.photoFile.type });
    if (uploadError) throw uploadError;

    const { data: urlData } = supabase.storage.from(PHOTO_BUCKET).getPublicUrl(path);

    const description = document.getElementById('description-input').value.trim();
    const { error: rpcError } = await supabase.rpc('submit_report', {
      p_category_id: state.categoryId,
      p_lng: state.lng,
      p_lat: state.lat,
      p_photo_url: urlData.publicUrl,
      p_description: description || null,
      p_region_id: state.regionId,
    });
    if (rpcError) throw rpcError;

    form.style.display = 'none';
    document.getElementById('submit-success').style.display = '';
  } catch (err) {
    console.error(err);
    errorEl.textContent = 'Something went wrong: ' + err.message;
  } finally {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Submit report';
  }
});

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

await loadCategoriesAndRegions();
