'use strict';
// Tamper-evident audit trail: each row's hash chains to the previous row.
const crypto = require('node:crypto');
const db = require('./private-db');

const insert = db.prepare('INSERT INTO audit_log(ts,user_id,action,target,ip,detail,prev_hash,hash) VALUES(?,?,?,?,?,?,?,?)');
const last = db.prepare('SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1');
const h = (...p) => crypto.createHash('sha256').update(p.join('\u001f')).digest('hex');

function audit(req, userId, action, target = '', detail = '') {
  const prev = last.get()?.hash || 'GENESIS';
  const ts = Date.now(), ip = req?.ip || '', t = String(target), d = String(detail).slice(0, 500);
  insert.run(ts, userId ?? null, action, t, ip, d, prev, h(prev, ts, userId ?? '', action, t, ip, d));
}
function verifyChain() {
  let prev = 'GENESIS';
  for (const r of db.prepare('SELECT * FROM audit_log ORDER BY id').all()) {
    if (r.prev_hash !== prev || r.hash !== h(prev, r.ts, r.user_id ?? '', r.action, r.target, r.ip, r.detail)) return { ok: false, brokenAt: r.id };
    prev = r.hash;
  }
  return { ok: true };
}
module.exports = { audit, verifyChain };
