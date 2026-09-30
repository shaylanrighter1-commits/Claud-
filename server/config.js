'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

// Minimal .env loader (no dependency). Real environment variables win.
try {
  const envFile = path.join(__dirname, '..', '.env');
  if (fs.existsSync(envFile)) {
    for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
      if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
    }
  }
} catch { /* ignore */ }

const isProd = process.env.NODE_ENV === 'production';
const dataDir = path.resolve(process.env.DATA_DIR || path.join(__dirname, '..', 'data'));
fs.mkdirSync(path.join(dataDir, 'vault'), { recursive: true, mode: 0o700 });

function loadKey(envName, fileName) {
  const v = process.env[envName];
  if (v) {
    const buf = Buffer.from(v, 'base64');
    if (buf.length !== 32) throw new Error(`${envName} must be 32 bytes, base64-encoded (run: npm run gen-keys)`);
    return buf;
  }
  if (isProd) throw new Error(`${envName} is required in production. Run: npm run gen-keys`);
  // Development only: persist a local key outside git-tracked paths.
  const f = path.join(dataDir, fileName);
  if (!fs.existsSync(f)) fs.writeFileSync(f, crypto.randomBytes(32).toString('base64'), { mode: 0o600 });
  console.warn(`[dev] using generated ${envName} from ${f}; set ${envName} in production.`);
  return Buffer.from(fs.readFileSync(f, 'utf8'), 'base64');
}

const mode = process.env.SERVE_MODE || 'all';
if (!['public', 'portal', 'all'].includes(mode)) throw new Error('SERVE_MODE must be public|portal|all');

module.exports = {
  isProd,
  mode,
  port: Number(process.env.PORT || 3000),
  dataDir,
  trustProxy: process.env.TRUST_PROXY === '1',
  require2fa: process.env.REQUIRE_2FA === '1',
  publicOrigin: process.env.PUBLIC_ORIGIN || '',
  portalOrigin: process.env.PORTAL_ORIGIN || '',
  // The public process never loads the data-encryption key.
  dataKey: mode === 'public' ? null : loadKey('DATA_KEY', 'dev-data.key'),
  publishKey: loadKey('PUBLISH_KEY', 'dev-publish.key'),
  session: { idleMs: 30 * 60 * 1000, absoluteMs: 8 * 60 * 60 * 1000 },
  maxUploadBytes: 25 * 1024 * 1024,
  company: {
    name: process.env.COMPANY_NAME || 'Keystone Residential Partners',
    email: process.env.CONTACT_EMAIL || 'hello@example.com'
  }
};
