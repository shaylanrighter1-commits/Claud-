'use strict';
const crypto = require('node:crypto');
const config = require('./config');

const CSP = [
  "default-src 'none'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:",
  "font-src 'self'", "connect-src 'self'", "form-action 'self'", "base-uri 'none'",
  "frame-ancestors 'none'", "object-src 'none'"
].join('; ');

function headers(isPrivate) {
  return (req, res, next) => {
    res.removeHeader('X-Powered-By');
    res.set({
      'Content-Security-Policy': CSP,
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
      'Permissions-Policy': 'geolocation=(), camera=(), microphone=(), payment=(), usb=()',
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Resource-Policy': 'same-origin'
    });
    if (config.isProd) res.set('Strict-Transport-Security', 'max-age=63072000; includeSubDomains; preload');
    if (isPrivate) {
      // Private surface: never cached, never indexed, never archived.
      res.set({
        'Cache-Control': 'no-store, no-cache, must-revalidate, private',
        Pragma: 'no-cache', Expires: '0',
        'X-Robots-Tag': 'noindex, nofollow, noarchive, nosnippet, noimageindex'
      });
    }
    next();
  };
}

// Redirect http -> https in production (requires TRUST_PROXY=1 behind a TLS terminator).
function forceHttps(req, res, next) {
  if (config.isProd && !req.secure) {
    if (req.method === 'GET' || req.method === 'HEAD') return res.redirect(308, `https://${req.headers.host}${req.originalUrl}`);
    return res.status(400).json({ error: 'HTTPS required' });
  }
  next();
}

// Reject requests whose Host header is not one of the configured origins (Host-header attacks).
function hostGuard(req, res, next) {
  const allowed = [config.publicOrigin, config.portalOrigin].filter(Boolean).map((o) => new URL(o).host);
  if (allowed.length && !allowed.includes(req.headers.host)) return res.status(421).end();
  next();
}

// CSRF defence layer 1: state-changing requests must come from our own origin.
function sameOrigin(req, res, next) {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  const src = req.get('origin') || req.get('referer');
  try {
    if (src && new URL(src).host === req.headers.host) return next();
  } catch { /* fallthrough */ }
  res.status(403).json({ error: 'Cross-origin request blocked' });
}

// Small in-memory sliding-window limiter (per IP + bucket).
function rateLimit(bucket, max, windowMs) {
  const hits = new Map();
  setInterval(() => { const c = Date.now() - windowMs; for (const [k, v] of hits) if (!v.some((t) => t > c)) hits.delete(k); }, windowMs).unref();
  return (req, res, next) => {
    const k = `${bucket}:${req.ip}`, now = Date.now();
    const arr = (hits.get(k) || []).filter((t) => t > now - windowMs);
    if (arr.length >= max) { res.set('Retry-After', Math.ceil(windowMs / 1000)); return res.status(429).json({ error: 'Too many requests. Try again later.' }); }
    arr.push(now); hits.set(k, arr); next();
  };
}

const ipHash = (ip) => crypto.createHash('sha256').update(`${ip}|${config.publishKey.toString('base64')}`).digest('hex').slice(0, 32);

module.exports = { headers, forceHttps, hostGuard, sameOrigin, rateLimit, ipHash };
