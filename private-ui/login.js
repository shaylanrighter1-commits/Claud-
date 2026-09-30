const f = document.getElementById('f'), msg = document.getElementById('msg');
f.addEventListener('submit', async (e) => {
  e.preventDefault(); msg.textContent = '';
  const body = Object.fromEntries(new FormData(f));
  if (!body.code) delete body.code;
  try {
    const r = await fetch('/portal/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const j = await r.json();
    if (j.needCode) { document.getElementById('codeRow').hidden = false; f.code.focus(); msg.textContent = 'Enter your authenticator code.'; return; }
    if (!r.ok) throw new Error(j.error || 'Sign-in failed');
    location.href = '/portal/';
  } catch (err) { msg.textContent = err.message; }
});
