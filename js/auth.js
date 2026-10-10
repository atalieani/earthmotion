// Shared auth helpers used by the header widget on every page, plus the
// submission flow (which requires a signed-in user) and the admin
// dashboard (which additionally requires profiles.is_moderator).
import { supabase } from './supabaseClient.js';

export async function getSession() {
  const { data } = await supabase.auth.getSession();
  return data.session;
}

export async function getCurrentProfile() {
  const session = await getSession();
  if (!session) return null;
  const { data, error } = await supabase
    .from('profiles')
    .select('id, username, total_points, is_moderator, home_region_id')
    .eq('id', session.user.id)
    .single();
  if (error) {
    console.error('[EarthMotion] failed to load profile', error);
    return null;
  }
  return data;
}

// Magic-link sign-in — no password to manage for a small volunteer-run app.
// Also serves as signup: handle_new_user() (sql/02) creates the profile row
// the first time someone completes the link.
export async function signInWithEmail(email) {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: window.location.href },
  });
  if (error) throw error;
}

export async function signOut() {
  await supabase.auth.signOut();
}

export async function updateUsername(newUsername) {
  const session = await getSession();
  if (!session) throw new Error('Not signed in');
  const { error } = await supabase
    .from('profiles')
    .update({ username: newUsername })
    .eq('id', session.user.id);
  if (error) throw error;
}

// Renders a compact sign-in / account widget into `el` and keeps it in
// sync with auth state changes. Call once per page from a header container.
export function mountAuthWidget(el, { onChange } = {}) {
  async function render() {
    const profile = await getCurrentProfile();
    el.innerHTML = '';

    if (!profile) {
      el.innerHTML = `
        <form class="auth-form" id="em-signin-form">
          <input type="email" name="email" placeholder="you@example.com" required />
          <button type="submit">Sign in</button>
        </form>
      `;
      el.querySelector('#em-signin-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        const email = new FormData(e.target).get('email');
        const btn = e.target.querySelector('button');
        btn.disabled = true;
        btn.textContent = 'Sending link…';
        try {
          await signInWithEmail(email);
          el.innerHTML = '<p class="auth-hint">Check your email for a sign-in link.</p>';
        } catch (err) {
          alert('Could not send sign-in link: ' + err.message);
          btn.disabled = false;
          btn.textContent = 'Sign in';
        }
      });
    } else {
      el.innerHTML = `
        <span class="auth-user">👤 <strong>${escapeHtml(profile.username)}</strong>
          (${profile.total_points} pts)</span>
        <button type="button" id="em-edit-username" title="Change username">✏️</button>
        <button type="button" id="em-signout">Sign out</button>
      `;
      el.querySelector('#em-edit-username').addEventListener('click', async () => {
        const next = prompt('New username', profile.username);
        if (next && next.trim() && next.trim() !== profile.username) {
          try {
            await updateUsername(next.trim());
            render();
          } catch (err) {
            alert('Could not update username: ' + err.message);
          }
        }
      });
      el.querySelector('#em-signout').addEventListener('click', async () => {
        await signOut();
        render();
      });
    }

    if (onChange) onChange(profile);
  }

  supabase.auth.onAuthStateChange(() => render());
  render();
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}
