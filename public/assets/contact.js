document.getElementById('f').addEventListener('submit', async (e) => {
  e.preventDefault();
  const s = document.getElementById('status'), f = e.target;
  s.className = ''; s.textContent = 'Sending…';
  try {
    const r = await fetch('/api/public/inquiries', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Object.fromEntries(new FormData(f))) });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || 'Something went wrong');
    f.reset(); s.className = 'ok'; s.textContent = 'Thank you. We will be in touch shortly.';
  } catch (err) { s.className = 'err'; s.textContent = err.message; }
});
