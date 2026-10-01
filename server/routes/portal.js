'use strict';
// PRIVATE surface, mounted at /portal. Everything except /login* requires a valid session;
// every data route additionally enforces role + CSRF on the server.
const express = require('express');
const path = require('node:path');
const fs = require('node:fs');
const config = require('../config');
const db = require('../private-db');
const pub = require('../public-db');
const C = require('../crypto');
const A = require('../auth');
const { audit, verifyChain } = require('../audit');
const { records, docs } = require('../store');
const { sig } = require('./public');
const { rateLimit, sameOrigin } = require('../security');
const { fetchListing, htmlToText } = require('../listing-fetch');

const UI = path.join(__dirname, '..', '..', 'private-ui');
const router = express.Router();
const api = express.Router();
const KINDS = new Set(['plan', 'property', 'financing', 'assumption', 'report']);
const bad = (res, m, s = 400) => res.status(s).json({ error: m });
const int = (v) => (/^\d+$/.test(String(v)) ? Number(v) : null);

router.use(A.loadSession);

// ---- Login shell (contains no business data) ----
const openFiles = { '/login': 'login.html', '/login.js': 'login.js', '/portal.css': 'portal.css' };
router.get(Object.keys(openFiles), (req, res) => res.sendFile(path.join(UI, openFiles[req.path])));

// ---- Gated application shell + assets: invisible (404) without a full session ----
const gated = { '/app.js': 'app.js', '/finance.js': 'finance.js' };
router.get('/', (req, res) => {
  if (!req.user) return res.redirect('/portal/login');
  const file = req.limited || req.query.setup ? 'setup.html' : 'app.html';
  res.sendFile(path.join(UI, file));
});
router.get('/setup.js', (req, res) => (req.user ? res.sendFile(path.join(UI, 'setup.js')) : res.status(404).end()));
router.get(Object.keys(gated), (req, res) => {
  if (!req.user || req.limited) return res.status(404).end();
  res.sendFile(path.join(UI, gated[req.path]));
});

// ---- API ----
router.use('/api', sameOrigin, express.json({ limit: '300kb' }), A.csrf, api);

// Auth
api.post('/auth/login', rateLimit('login', 20, 60 * 1000), (req, res) => {
  const { email, password, code } = req.body || {};
  if (typeof email !== 'string' || typeof password !== 'string') return bad(res, 'Invalid request');
  const r = A.attemptLogin(req, email, password, code);
  if (r.error === 'locked') return bad(res, 'Too many failed attempts. Try again in 15 minutes.', 429);
  if (r.error) return bad(res, 'Invalid credentials', 401);
  if (r.needCode) return res.json({ needCode: true });
  A.createSession(req, res, r.user, r.twofaOk);
  audit(req, r.user.id, 'login.ok');
  res.json({ ok: true });
});
api.post('/auth/logout', (req, res) => { if (req.user) audit(req, req.user.id, 'logout'); A.destroySession(req, res); res.json({ ok: true }); });
api.get('/auth/me', (req, res) => {
  if (!req.user) return bad(res, 'Authentication required', 401);
  res.json({ user: req.user, csrf: req.session.csrf, limited: req.limited, must_change_pw: !!req.session.must_change_pw, require2fa: config.require2fa });
});
api.post('/auth/password', A.requireAuth, rateLimit('pw', 10, 60 * 1000), (req, res) => {
  const { current, next } = req.body || {};
  const u = db.prepare('SELECT * FROM users WHERE id=?').get(req.user.id);
  if (typeof current !== 'string' || !C.verifyPassword(current, u.pw_hash)) return bad(res, 'Current password incorrect', 401);
  const err = C.checkPasswordPolicy(next, u.email);
  if (err) return bad(res, err);
  db.prepare('UPDATE users SET pw_hash=?, must_change_pw=0 WHERE id=?').run(C.hashPassword(next), u.id);
  db.prepare('DELETE FROM sessions WHERE user_id=? AND id_hash<>?').run(u.id, req.session.id_hash); // kill other sessions
  audit(req, u.id, 'password.changed');
  res.json({ ok: true });
});
api.post('/auth/2fa/setup', A.requireAuth, (req, res) => {
  const secret = C.newTotpSecret();
  db.prepare('UPDATE users SET totp_secret=?, totp_enabled=0 WHERE id=?').run(C.encrypt(config.dataKey, Buffer.from(secret), `totp:${req.user.id}`), req.user.id);
  const label = encodeURIComponent(`${config.company.name}:${req.user.email}`);
  res.json({ secret, uri: `otpauth://totp/${label}?secret=${secret}&issuer=${encodeURIComponent(config.company.name)}` });
});
api.post('/auth/2fa/enable', A.requireAuth, rateLimit('2fa', 10, 60 * 1000), (req, res) => {
  const u = db.prepare('SELECT * FROM users WHERE id=?').get(req.user.id);
  if (!u.totp_secret) return bad(res, 'Run setup first');
  if (!C.verifyTotp(C.decrypt(config.dataKey, u.totp_secret, `totp:${u.id}`).toString(), (req.body || {}).code)) return bad(res, 'Invalid code', 401);
  db.prepare('UPDATE users SET totp_enabled=1 WHERE id=?').run(u.id);
  db.prepare('UPDATE sessions SET twofa_ok=1 WHERE id_hash=?').run(req.session.id_hash);
  audit(req, u.id, '2fa.enabled');
  res.json({ ok: true });
});

// Records (plan sections, properties, financing, assumptions, reports)
api.use('/records/:kind', (req, res, next) => (KINDS.has(req.params.kind) ? next() : bad(res, 'Unknown kind', 404)));
const payload = (req, res) => {
  const b = req.body;
  if (!b || typeof b !== 'object' || Array.isArray(b)) { bad(res, 'Object body required'); return null; }
  const { id, kind, version, createdAt, updatedAt, ...clean } = b;      // never trust client-supplied meta
  return clean;
};
api.get('/records/:kind', A.requireRole('viewer'), (req, res) => res.json(records.list(req.params.kind)));
api.post('/records/:kind', A.requireRole('analyst'), (req, res) => {
  const p = payload(req, res); if (!p) return;
  const id = records.create(req.params.kind, p, req.user.id);
  audit(req, req.user.id, 'record.create', `${req.params.kind}:${id}`);
  res.status(201).json({ id });
});
api.put('/records/:kind/:id', A.requireRole('analyst'), (req, res) => {
  const id = int(req.params.id), p = payload(req, res); if (!p) return;
  if (id === null || !records.update(req.params.kind, id, p, req.user.id)) return bad(res, 'Not found', 404);
  audit(req, req.user.id, 'record.update', `${req.params.kind}:${id}`);
  res.json({ ok: true });
});
api.delete('/records/:kind/:id', A.requireRole('owner'), (req, res) => {
  const id = int(req.params.id);
  if (id === null || !records.remove(req.params.kind, id)) return bad(res, 'Not found', 404);
  audit(req, req.user.id, 'record.delete', `${req.params.kind}:${id}`);
  res.json({ ok: true });
});

// Documents (encrypted vault)
api.get('/documents', A.requireRole('viewer'), (req, res) => res.json(docs.list()));
api.post('/documents', A.requireRole('analyst'), express.raw({ type: '*/*', limit: config.maxUploadBytes }), (req, res) => {
  if (!Buffer.isBuffer(req.body) || !req.body.length) return bad(res, 'Empty upload');
  try {
    const name = decodeURIComponent(req.get('x-filename') || 'upload');
    const id = docs.add(req.body, name, req.get('content-type') || 'application/octet-stream', req.user.id);
    audit(req, req.user.id, 'document.upload', `doc:${id}`, name);
    res.status(201).json({ id });
  } catch (e) { bad(res, e.message, e.status || 400); }
});
api.get('/documents/:id/download', A.requireRole('viewer'), (req, res) => {
  const id = int(req.params.id), d = id === null ? null : docs.read(id);
  if (!d) return bad(res, 'Not found', 404);
  audit(req, req.user.id, 'document.download', `doc:${id}`, d.meta.name);
  res.set({ 'Content-Type': 'application/octet-stream', 'Content-Disposition': `attachment; filename="${d.meta.name}"` }).send(d.data);
});
api.delete('/documents/:id', A.requireRole('owner'), (req, res) => {
  const id = int(req.params.id);
  if (id === null || !docs.remove(id)) return bad(res, 'Not found', 404);
  audit(req, req.user.id, 'document.delete', `doc:${id}`);
  res.json({ ok: true });
});

// Listing helper: fetch one public listing page (allow-listed sites only) and return its text for in-browser parsing.
api.post('/listing/fetch', A.requireRole('analyst'), rateLimit('listing', 10, 60 * 1000), async (req, res) => {
  const url = (req.body || {}).url;
  if (typeof url !== 'string' || url.length > 500) return bad(res, 'A listing link is required');
  try {
    const text = htmlToText(await fetchListing(url, req.app.locals.listingFetchOpts));
    audit(req, req.user.id, 'listing.fetch', (() => { try { return new URL(url).hostname; } catch { return 'invalid'; } })());
    res.json({ text: text.slice(0, 200000) });
  } catch (e) { bad(res, e.publicMessage || 'Could not fetch that page', 502); }
});

// Users (owner only; there is no public sign-up anywhere)
api.get('/users', A.requireRole('owner'), (req, res) =>
  res.json(db.prepare('SELECT id,email,name,role,active,totp_enabled totpEnabled,created_at createdAt FROM users ORDER BY id').all()));
api.post('/users', A.requireRole('owner'), (req, res) => {
  const { email, name, role } = req.body || {};
  if (typeof email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || typeof name !== 'string' || !name.trim() || !['owner', 'analyst', 'viewer'].includes(role)) return bad(res, 'email, name, role required');
  if (db.prepare('SELECT 1 FROM users WHERE email=?').get(email)) return bad(res, 'Email already exists', 409);
  const temp = C.randomToken(12) + 'Aa1';
  db.prepare('INSERT INTO users(email,name,role,pw_hash,must_change_pw,created_by,created_at) VALUES(?,?,?,?,1,?,?)')
    .run(email.trim(), name.trim().slice(0, 100), role, C.hashPassword(temp), req.user.id, Date.now());
  audit(req, req.user.id, 'user.create', email, role);
  res.status(201).json({ temporaryPassword: temp });   // shown once; user must change at first login
});
api.patch('/users/:id', A.requireRole('owner'), (req, res) => {
  const id = int(req.params.id), u = id === null ? null : db.prepare('SELECT * FROM users WHERE id=?').get(id);
  if (!u) return bad(res, 'Not found', 404);
  const { role, active, resetPassword, resetTwoFactor } = req.body || {};
  try {
    if (role !== undefined) { if (!['owner', 'analyst', 'viewer'].includes(role)) return bad(res, 'bad role'); db.prepare('UPDATE users SET role=? WHERE id=?').run(role, id); }
    if (active !== undefined) db.prepare('UPDATE users SET active=? WHERE id=?').run(active ? 1 : 0, id);
    if (active === false) db.prepare('DELETE FROM sessions WHERE user_id=?').run(id);
    if (resetTwoFactor) db.prepare('UPDATE users SET totp_secret=NULL, totp_enabled=0 WHERE id=?').run(id);
    let temporaryPassword;
    if (resetPassword) {
      temporaryPassword = C.randomToken(12) + 'Aa1';
      db.prepare('UPDATE users SET pw_hash=?, must_change_pw=1 WHERE id=?').run(C.hashPassword(temporaryPassword), id);
      db.prepare('DELETE FROM sessions WHERE user_id=?').run(id);
    }
    audit(req, req.user.id, 'user.update', u.email, JSON.stringify({ role, active, resetPassword: !!resetPassword, resetTwoFactor: !!resetTwoFactor }));
    res.json({ ok: true, temporaryPassword });
  } catch (e) { bad(res, e.message, 409); }
});

// Audit log + inquiries (owner only)
api.get('/audit', A.requireRole('owner'), (req, res) => res.json({
  chain: verifyChain(),
  rows: db.prepare('SELECT a.id,a.ts,a.action,a.target,a.ip,a.detail,u.email FROM audit_log a LEFT JOIN users u ON u.id=a.user_id ORDER BY a.id DESC LIMIT 300').all()
}));
api.get('/inquiries', A.requireRole('analyst'), (req, res) => res.json(pub.prepare('SELECT id,ts,name,email,phone,interest,message,handled FROM inquiries ORDER BY id DESC LIMIT 500').all()));
api.patch('/inquiries/:id', A.requireRole('analyst'), (req, res) => {
  pub.prepare('UPDATE inquiries SET handled=? WHERE id=?').run((req.body || {}).handled ? 1 : 0, int(req.params.id)); res.json({ ok: true });
});

// Publication: the ONLY path by which anything becomes public. Owner-only, password re-entry, explicit acknowledgement.
api.get('/publish', A.requireRole('owner'), (req, res) => res.json(pub.prepare('SELECT slug,title,body,published_at publishedAt,approved_by approvedBy FROM published_content ORDER BY published_at DESC').all()));
api.post('/publish', A.requireRole('owner'), rateLimit('publish', 10, 60 * 1000), (req, res) => {
  const { slug, title, body, password, confirm } = req.body || {};
  const u = db.prepare('SELECT * FROM users WHERE id=?').get(req.user.id);
  if (confirm !== true) return bad(res, 'You must explicitly confirm that this content is approved for public release.');
  if (typeof password !== 'string' || !C.verifyPassword(password, u.pw_hash)) return bad(res, 'Password confirmation failed', 401);
  if (typeof slug !== 'string' || !/^[a-z0-9-]{1,60}$/.test(slug) || typeof title !== 'string' || !title.trim() || title.length > 120 || typeof body !== 'string' || !body.trim() || body.length > 10000) return bad(res, 'Invalid slug/title/body');
  const row = { slug, title: title.trim(), body: body.trim(), published_at: Date.now() };
  pub.prepare('INSERT INTO published_content(slug,title,body,published_at,approved_by,signature) VALUES(?,?,?,?,?,?) ON CONFLICT(slug) DO UPDATE SET title=excluded.title, body=excluded.body, published_at=excluded.published_at, approved_by=excluded.approved_by, signature=excluded.signature')
    .run(row.slug, row.title, row.body, row.published_at, u.email, sig(row));
  audit(req, u.id, 'publish', slug, row.title);
  res.status(201).json({ ok: true });
});
api.delete('/publish/:slug', A.requireRole('owner'), (req, res) => {
  pub.prepare('DELETE FROM published_content WHERE slug=?').run(String(req.params.slug));
  audit(req, req.user.id, 'unpublish', req.params.slug); res.json({ ok: true });
});

// Full encrypted-at-rest export for backup/migration (owner only, audited).
api.get('/export', A.requireRole('owner'), (req, res) => {
  audit(req, req.user.id, 'export.full');
  res.set('Content-Disposition', 'attachment; filename="export.json"')
    .json(Object.fromEntries([...KINDS].map((k) => [k, records.list(k)])));
});

api.use((req, res) => bad(res, 'Not found', 404));
router.use((req, res) => res.status(404).end());
module.exports = router;
