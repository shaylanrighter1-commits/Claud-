// Account-security screen: available to any signed-in user, including "limited" sessions
// (forced password change / 2FA enrolment). Contains no business data or logic.
let csrf = '';
const api = async (path, method = 'GET', body) => {
  const r = await fetch('/portal/api' + path, { method, headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || 'Request failed');
  return j;
};
const el = (t, a = {}, ...k) => { const e = document.createElement(t); for (const [x, v] of Object.entries(a)) x === 'class' ? (e.className = v) : e.setAttribute(x, v); e.append(...k); return e; };
const field = (label, name, type = 'text', ac) => el('label', {}, label, el('input', { name, type, autocomplete: ac || 'off', required: '' }));
const root = document.getElementById('root');
const msg = el('p', { class: 'err', role: 'alert' });

async function render() {
  const me = await fetch('/portal/api/auth/me').then((r) => (r.ok ? r.json() : null));
  if (!me) return (location.href = '/portal/login');
  csrf = me.csrf;
  root.replaceChildren(el('h1', {}, 'Account security'), el('p', { class: 'muted' }, me.user.email));
  if (me.limited) root.append(el('p', { class: 'warn' }, 'Complete the steps below to unlock the dashboard.'));

  const pw = el('form', {}, el('h3', {}, 'Change password'), field('Current password', 'current', 'password', 'current-password'), field('New password (14+ characters)', 'next', 'password', 'new-password'), el('button', {}, 'Update password'));
  pw.onsubmit = async (e) => { e.preventDefault(); msg.className = 'err'; try { await api('/auth/password', 'POST', Object.fromEntries(new FormData(pw))); render(); } catch (x) { msg.textContent = x.message; } };
  root.append(pw);

  if (!me.user.totpEnabled) {
    const box = el('div', {}, el('h3', {}, 'Two-factor authentication'), el('p', { class: 'muted' }, 'Use an authenticator app (1Password, Authy, Google Authenticator).'));
    const start = el('button', { type: 'button' }, 'Set up 2FA');
    start.onclick = async () => {
      const s = await api('/auth/2fa/setup', 'POST');
      const f = el('form', {}, el('p', {}, 'Add this key to your authenticator app:'), el('code', {}, s.secret), el('p', { class: 'muted' }, s.uri), field('6-digit code', 'code'), el('button', {}, 'Enable 2FA'));
      f.onsubmit = async (e) => { e.preventDefault(); try { await api('/auth/2fa/enable', 'POST', Object.fromEntries(new FormData(f))); render(); } catch (x) { msg.textContent = x.message; } };
      box.replaceChildren(f);
    };
    box.append(start); root.append(box);
  } else root.append(el('p', { class: 'ok' }, '✓ Two-factor authentication is enabled.'));

  root.append(msg);
  if (!me.limited) root.append(el('p', {}, el('a', { href: '/portal/' }, '← Back to dashboard')));
}
render();
