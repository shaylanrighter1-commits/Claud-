// Renders ONLY content the owner explicitly published. Uses textContent (no HTML injection).
fetch('/api/public/content').then((r) => r.json()).then((rows) => {
  if (!rows.length) return;
  const box = document.getElementById('posts'); box.textContent = '';
  for (const p of rows) {
    const a = document.createElement('article'); a.className = 'post';
    const h = document.createElement('h3'); h.textContent = p.title;
    const d = document.createElement('div'); d.className = 'note'; d.textContent = new Date(p.publishedAt).toLocaleDateString();
    const b = document.createElement('p'); b.textContent = p.body;
    a.append(h, d, b); box.append(a);
  }
}).catch(() => {});
