'use strict';
const crypto = require('node:crypto');

// ---- Authenticated encryption (AES-256-GCM) for data at rest ----
// Blob layout: v1 | iv(12) | tag(16) | ciphertext. AAD binds ciphertext to its row/context
// so a blob copied to a different record fails authentication.
function encrypt(key, plaintext, aad) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  if (aad) c.setAAD(Buffer.from(aad));
  const ct = Buffer.concat([c.update(plaintext), c.final()]);
  return Buffer.concat([Buffer.from([1]), iv, c.getAuthTag(), ct]);
}
function decrypt(key, blob, aad) {
  if (blob[0] !== 1) throw new Error('unsupported blob version');
  const d = crypto.createDecipheriv('aes-256-gcm', key, blob.subarray(1, 13));
  if (aad) d.setAAD(Buffer.from(aad));
  d.setAuthTag(blob.subarray(13, 29));
  return Buffer.concat([d.update(blob.subarray(29)), d.final()]);
}

// ---- Password hashing (scrypt, per-user salt) ----
const SCRYPT = { N: 1 << 15, r: 8, p: 1, maxmem: 128 * 1024 * 1024 };
function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  const h = crypto.scryptSync(pw, salt, 64, SCRYPT);
  return `scrypt$${salt.toString('base64')}$${h.toString('base64')}`;
}
function verifyPassword(pw, stored) {
  const [alg, s, h] = String(stored).split('$');
  if (alg !== 'scrypt') return false;
  const exp = Buffer.from(h, 'base64');
  const got = crypto.scryptSync(pw, Buffer.from(s, 'base64'), exp.length, SCRYPT);
  return crypto.timingSafeEqual(exp, got);
}
const DUMMY_HASH = hashPassword('dummy-password-for-timing');

function checkPasswordPolicy(pw, email = '') {
  if (typeof pw !== 'string' || pw.length < 14) return 'Password must be at least 14 characters.';
  if (pw.length > 256) return 'Password too long.';
  if (email && pw.toLowerCase().includes(email.split('@')[0].toLowerCase())) return 'Password must not contain your email name.';
  if (new Set(pw).size < 6) return 'Password is too repetitive.';
  if (!/[a-z]/.test(pw) || !/[A-Z0-9]/.test(pw)) return 'Use a mix of letters and numbers/uppercase.';
  return null;
}

// ---- Tokens ----
const randomToken = (n = 32) => crypto.randomBytes(n).toString('base64url');
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const safeEqual = (a, b) => {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};
const hmac = (key, s) => crypto.createHmac('sha256', key).update(s).digest('hex');

// ---- TOTP (RFC 6238, SHA-1, 6 digits, 30s) ----
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function b32encode(buf) {
  let bits = '', out = '';
  for (const b of buf) bits += b.toString(2).padStart(8, '0');
  for (let i = 0; i < bits.length; i += 5) out += B32[parseInt(bits.slice(i, i + 5).padEnd(5, '0'), 2)];
  return out;
}
function b32decode(s) {
  let bits = '';
  for (const ch of s.replace(/=+$/, '')) bits += B32.indexOf(ch).toString(2).padStart(5, '0');
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}
function totpAt(secretB32, t) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(t / 30000)));
  const h = crypto.createHmac('sha1', b32decode(secretB32)).update(counter).digest();
  const o = h[19] & 0xf;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1e6).padStart(6, '0');
}
function verifyTotp(secretB32, code, now = Date.now()) {
  if (!/^\d{6}$/.test(String(code))) return false;
  for (const skew of [-30000, 0, 30000]) if (safeEqual(totpAt(secretB32, now + skew), code)) return true;
  return false;
}
const newTotpSecret = () => b32encode(crypto.randomBytes(20));

module.exports = {
  encrypt, decrypt, hashPassword, verifyPassword, DUMMY_HASH, checkPasswordPolicy,
  randomToken, sha256, safeEqual, hmac, verifyTotp, totpAt, newTotpSecret
};
