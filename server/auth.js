'use strict';
const db = require('./private-db');
const config = require('./config');
const C = require('./crypto');
const { audit } = require('./audit');

const COOKIE = config.isProd ? '__Host-sid' : 'sid';
const ROLE_RANK = { viewer: 1, analyst: 2, owner: 3 };

function parseCookies(h = '') {
  const o = {};
  for (const p of h.split(';')) { const i = p.indexOf('='); if (i > 0) o[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim()); }
  return o;
}
function setCookie(res, value, maxAgeMs) {
  res.append('Set-Cookie', `${COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${Math.floor(maxAgeMs / 1000)}${config.isProd ? '; Secure' : ''}`);
}

function createSession(req, res, user, twofaOk) {
  const token = C.randomToken(32), csrf = C.randomToken(24), now = Date.now();
  db.prepare('INSERT INTO sessions(id_hash,user_id,csrf,created_at,last_seen,ip,ua,twofa_ok) VALUES(?,?,?,?,?,?,?,?)')
    .run(C.sha256(token), user.id, csrf, now, now, req.ip, String(req.get('user-agent') || '').slice(0, 200), twofaOk ? 1 : 0);
  setCookie(res, token, config.session.absoluteMs);
}
function destroySession(req, res) {
  const t = parseCookies(req.headers.cookie)[COOKIE];
  if (t) db.prepare('DELETE FROM sessions WHERE id_hash=?').run(C.sha256(t));
  setCookie(res, '', 0);
}

// Attaches req.session/req.user when a valid, unexpired, non-idle session exists.
function loadSession(req, res, next) {
  const t = parseCookies(req.headers.cookie)[COOKIE];
  if (t) {
    const row = db.prepare(`SELECT s.*, u.email, u.name, u.role, u.active, u.totp_enabled, u.must_change_pw
      FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id_hash=?`).get(C.sha256(t));
    const now = Date.now();
    if (row && row.active && now - row.last_seen < config.session.idleMs && now - row.created_at < config.session.absoluteMs) {
      db.prepare('UPDATE sessions SET last_seen=? WHERE id_hash=?').run(now, row.id_hash);
      req.session = row;
      req.user = { id: row.user_id, email: row.email, name: row.name, role: row.role, totpEnabled: !!row.totp_enabled };
      req.limited = !!row.must_change_pw || (config.require2fa && !row.twofa_ok);
    } else if (row) {
      db.prepare('DELETE FROM sessions WHERE id_hash=?').run(row.id_hash);
    }
  }
  next();
}

// Server-side authorization gates. Every private API route passes through these.
const requireAuth = (req, res, next) => {
  if (!req.user) return res.status(401).json({ error: 'Authentication required' });
  next();
};
const requireFull = (req, res, next) => {   // fully-authenticated: 2FA satisfied, password not flagged
  if (!req.user) return res.status(401).json({ error: 'Authentication required' });
  if (req.limited) return res.status(403).json({ error: 'Complete account security setup first', limited: true });
  next();
};
const requireRole = (min) => (req, res, next) => {
  if (!req.user) return res.status(401).json({ error: 'Authentication required' });
  if (req.limited) return res.status(403).json({ error: 'Complete account security setup first', limited: true });
  if (ROLE_RANK[req.user.role] < ROLE_RANK[min]) {
    audit(req, req.user.id, 'authz.denied', `${req.method} ${req.path}`, `needs ${min}`);
    return res.status(403).json({ error: 'Forbidden' });
  }
  next();
};
// CSRF layer 2: per-session synchroniser token required on every state-changing request.
function csrf(req, res, next) {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method) || !req.session) return next();
  if (!C.safeEqual(req.get('x-csrf-token') || '', req.session.csrf)) return res.status(403).json({ error: 'Bad CSRF token' });
  next();
}

// ---- Login with lockout ----
const MAX_FAILS = 5, WINDOW = 15 * 60 * 1000;
function failures(key) {
  return db.prepare('SELECT COUNT(*) c FROM login_attempts WHERE key=? AND ts>?').get(key, Date.now() - WINDOW).c;
}
function attemptLogin(req, email, password, code) {
  const keyAcct = `a:${String(email).toLowerCase()}`, keyIp = `i:${req.ip}`;
  if (failures(keyAcct) >= MAX_FAILS || failures(keyIp) >= MAX_FAILS * 4) return { error: 'locked' };
  const fail = () => {
    const ins = db.prepare('INSERT INTO login_attempts(key,ts) VALUES(?,?)');
    ins.run(keyAcct, Date.now()); ins.run(keyIp, Date.now());
    audit(req, null, 'login.failed', String(email).slice(0, 120));
    return { error: 'invalid' };
  };
  const user = db.prepare('SELECT * FROM users WHERE email=?').get(String(email));
  const ok = C.verifyPassword(String(password), user ? user.pw_hash : C.DUMMY_HASH); // constant work either way
  if (!user || !ok || !user.active) return fail();
  let twofaOk = false;
  if (user.totp_enabled) {
    if (!code) return { needCode: true };
    if (!C.verifyTotp(C.decrypt(config.dataKey, user.totp_secret, `totp:${user.id}`).toString(), code)) return fail();
    twofaOk = true;
  }
  db.prepare('DELETE FROM login_attempts WHERE key=?').run(keyAcct);
  return { user, twofaOk };
}

module.exports = { loadSession, requireAuth, requireFull, requireRole, csrf, createSession, destroySession, attemptLogin, ROLE_RANK };
