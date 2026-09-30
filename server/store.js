'use strict';
// Encrypted record + document vault. Only ciphertext ever touches disk or SQLite.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const db = require('./private-db');
const config = require('./config');
const C = require('./crypto');

const aad = (kind, id) => `rec:${kind}:${id}`;
const vaultDir = path.join(config.dataDir, 'vault');

function unwrap(row) {
  const payload = JSON.parse(C.decrypt(config.dataKey, row.data, aad(row.kind, row.id)).toString('utf8'));
  return { id: row.id, kind: row.kind, version: row.version, createdAt: row.created_at, updatedAt: row.updated_at, ...payload };
}
const records = {
  list(kind) {
    return db.prepare('SELECT * FROM records WHERE kind=? ORDER BY id').all(kind).map(unwrap);
  },
  get(kind, id) {
    const r = db.prepare('SELECT * FROM records WHERE kind=? AND id=?').get(kind, id);
    return r ? unwrap(r) : null;
  },
  create(kind, payload, userId) {
    const now = Date.now();
    db.exec('BEGIN');
    try {
      const { lastInsertRowid: id } = db.prepare('INSERT INTO records(kind,data,created_by,updated_by,created_at,updated_at) VALUES(?,?,?,?,?,?)')
        .run(kind, Buffer.alloc(0), userId, userId, now, now);
      db.prepare('UPDATE records SET data=? WHERE id=?').run(C.encrypt(config.dataKey, Buffer.from(JSON.stringify(payload)), aad(kind, id)), id);
      db.exec('COMMIT');
      return Number(id);
    } catch (e) { db.exec('ROLLBACK'); throw e; }
  },
  update(kind, id, payload, userId) {
    const r = db.prepare('SELECT id FROM records WHERE kind=? AND id=?').get(kind, id);
    if (!r) return false;
    db.prepare('UPDATE records SET data=?, version=version+1, updated_by=?, updated_at=? WHERE id=?')
      .run(C.encrypt(config.dataKey, Buffer.from(JSON.stringify(payload)), aad(kind, id)), userId, Date.now(), id);
    return true;
  },
  remove(kind, id) { return db.prepare('DELETE FROM records WHERE kind=? AND id=?').run(kind, id).changes > 0; }
};

const ALLOWED_EXT = new Set(['.pdf', '.docx', '.xlsx', '.pptx', '.csv', '.txt', '.md', '.png', '.jpg', '.jpeg']);
const docs = {
  add(buf, originalName, mime, userId) {
    const ext = path.extname(originalName).toLowerCase();
    if (!ALLOWED_EXT.has(ext)) throw Object.assign(new Error('File type not allowed'), { status: 415 });
    const vault = crypto.randomBytes(24).toString('hex');            // random name: no info leaked via filesystem
    const { lastInsertRowid: id } = db.prepare('INSERT INTO documents(meta,vault_name,size,uploaded_by,created_at) VALUES(?,?,?,?,?)')
      .run(Buffer.alloc(0), vault, buf.length, userId, Date.now());
    const meta = { name: path.basename(originalName).replace(/[^\w.\- ()]/g, '_').slice(0, 120), mime: String(mime).slice(0, 100) };
    db.prepare('UPDATE documents SET meta=? WHERE id=?').run(C.encrypt(config.dataKey, Buffer.from(JSON.stringify(meta)), `docmeta:${id}`), id);
    fs.writeFileSync(path.join(vaultDir, vault), C.encrypt(config.dataKey, buf, `doc:${id}`), { mode: 0o600 });
    return Number(id);
  },
  list() {
    return db.prepare('SELECT * FROM documents ORDER BY id DESC').all().map((r) => ({
      id: r.id, size: r.size, createdAt: r.created_at,
      ...JSON.parse(C.decrypt(config.dataKey, r.meta, `docmeta:${r.id}`).toString())
    }));
  },
  read(id) {
    const r = db.prepare('SELECT * FROM documents WHERE id=?').get(id);
    if (!r) return null;
    const meta = JSON.parse(C.decrypt(config.dataKey, r.meta, `docmeta:${r.id}`).toString());
    const data = C.decrypt(config.dataKey, fs.readFileSync(path.join(vaultDir, r.vault_name)), `doc:${r.id}`);
    return { meta, data };
  },
  remove(id) {
    const r = db.prepare('SELECT vault_name FROM documents WHERE id=?').get(id);
    if (!r) return false;
    db.prepare('DELETE FROM documents WHERE id=?').run(id);
    fs.rmSync(path.join(vaultDir, r.vault_name), { force: true });
    return true;
  }
};
module.exports = { records, docs };
