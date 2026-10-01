'use strict';
// Consistent snapshot of everything: private.db + public.db (SQLite VACUUM INTO), the encrypted vault, and the
// encryption keys in a SEPARATE folder (a backup is useless without them; keep them apart from the data).
// Database contents and vault files are already encrypted at rest, so the data folders stay unreadable without the keys.
const fs = require('node:fs');
const path = require('node:path');
const config = require('./config');

const backupsDir = () => path.join(config.dataDir, 'backups');

function createBackup(privateDb, publicDb) {
  let stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19), n = 1;
  while (fs.existsSync(path.join(backupsDir(), stamp))) stamp = `${stamp.slice(0, 19)}-${++n}`;   // never overwrite or collide
  const root = path.join(backupsDir(), stamp);
  const dataDir = path.join(root, 'data'), keyDir = path.join(root, 'KEYS-store-separately');
  fs.mkdirSync(path.join(dataDir, 'vault'), { recursive: true, mode: 0o700 });
  fs.mkdirSync(keyDir, { recursive: true, mode: 0o700 });
  const q = (p) => p.replace(/'/g, "''");
  privateDb.exec(`VACUUM INTO '${q(path.join(dataDir, 'private.db'))}'`);
  if (publicDb) publicDb.exec(`VACUUM INTO '${q(path.join(dataDir, 'public.db'))}'`);
  const vault = path.join(config.dataDir, 'vault');
  let files = 0;
  for (const f of fs.existsSync(vault) ? fs.readdirSync(vault) : []) { fs.copyFileSync(path.join(vault, f), path.join(dataDir, 'vault', f)); files++; }
  // Development keys live in the data folder; in production they come from environment variables and must be backed up by you.
  const keys = [];
  for (const k of ['dev-data.key', 'dev-publish.key']) {
    const src = path.join(config.dataDir, k);
    if (fs.existsSync(src)) { fs.copyFileSync(src, path.join(keyDir, k)); fs.chmodSync(path.join(keyDir, k), 0o600); keys.push(k); }
  }
  fs.writeFileSync(path.join(root, 'README.txt'), [
    'BACKUP of the private dashboard', `Created: ${new Date().toISOString()}`, '',
    'data/   -> the databases and encrypted documents (unreadable without the keys)',
    'KEYS-store-separately/ -> the encryption keys. Without them the data CANNOT be recovered.',
    '          Move this folder somewhere safe and different from the data (USB drive, password manager).',
    '', 'To restore: stop the site, copy data/* into the project data folder, put the key files back beside them, start the site.'
  ].join('\n'), { mode: 0o600 });
  return { name: stamp, path: root, vaultFiles: files, keysIncluded: keys.length > 0 };
}
function listBackups() {
  const dir = backupsDir();
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).filter((n) => /^\d{4}-/.test(n)).sort().reverse().map((n) => {
    let size = 0;
    const walk = (p) => { for (const e of fs.readdirSync(p, { withFileTypes: true })) { const fp = path.join(p, e.name); e.isDirectory() ? walk(fp) : (size += fs.statSync(fp).size); } };
    try { walk(path.join(dir, n)); } catch { /* ignore */ }
    return { name: n, size };
  });
}
module.exports = { createBackup, listBackups, backupsDir };
