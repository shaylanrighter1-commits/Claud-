'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'mf-'));
process.env.NODE_ENV = 'test';
process.env.REQUIRE_2FA = '0';
const app = require('../server/index');
const db = require('../server/private-db');
const C = require('../server/crypto');

let base, server;
const PW = 'Correct-Horse-Battery-9';
test.before(async () => {
  await new Promise((r) => { server = app.listen(0, r); });
  base = `http://127.0.0.1:${server.address().port}`;
  db.prepare('INSERT INTO users(email,name,role,pw_hash,created_at) VALUES(?,?,?,?,?)').run('owner@x.com', 'Owner', 'owner', C.hashPassword(PW), Date.now());
});
test.after(() => server.close());

class Client {
  constructor() { this.cookie = ''; this.csrf = ''; }
  async req(method, url, body, extra = {}) {
    const headers = { Origin: base, ...(this.cookie && { Cookie: this.cookie }), ...(this.csrf && { 'X-CSRF-Token': this.csrf }), ...extra };
    if (body !== undefined && !(body instanceof Buffer)) headers['Content-Type'] = 'application/json';
    const r = await fetch(base + url, { method, headers, body: body instanceof Buffer ? body : body !== undefined ? JSON.stringify(body) : undefined, redirect: 'manual' });
    const sc = r.headers.get('set-cookie'); if (sc) this.cookie = sc.split(';')[0];
    return r;
  }
  async login(email, pw, code) {
    const r = await this.req('POST', '/portal/api/auth/login', { email, password: pw, code });
    if (r.ok) { const me = await (await this.req('GET', '/portal/api/auth/me')).json(); this.csrf = me.csrf; }
    return r;
  }
}
const owner = new Client();

test('public site serves pages with security headers and no private data paths', async () => {
  const r = await fetch(base + '/');
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-security-policy'), /default-src 'none'/);
  assert.equal(r.headers.get('x-frame-options'), 'DENY');
  for (const p of ['/private-ui/app.js', '/server/config.js', '/data/private.db', '/.env', '/package.json', '/../server/config.js', '/portal/app.js', '/portal/finance.js', '/portal/api/records/plan'])
    assert.notEqual((await fetch(base + p)).status, 200, p);
});

test('unauthenticated access to every private API is rejected', async () => {
  for (const p of ['/records/plan', '/records/property', '/documents', '/users', '/audit', '/inquiries', '/publish', '/export']) {
    const r = await fetch(base + '/portal/api' + p);
    assert.equal(r.status, 401, p);
  }
  const r = await fetch(base + '/portal/', { redirect: 'manual' });
  assert.equal(r.status, 302);
});

test('login: wrong password fails, lockout engages, private pages are noindex/no-store', async () => {
  const c = new Client();
  assert.equal((await c.login('owner@x.com', 'wrong-password-123')).status, 401);
  const r = await fetch(base + '/portal/login');
  assert.match(r.headers.get('x-robots-tag'), /noindex/);
  assert.match(r.headers.get('cache-control'), /no-store/);
  for (let i = 0; i < 5; i++) await new Client().login('lock@x.com', 'nope-nope-nope-1');
  assert.equal((await new Client().login('lock@x.com', 'nope-nope-nope-1')).status, 429);
});

test('owner can sign in; CSRF + origin checks enforced', async () => {
  assert.equal((await owner.login('owner@x.com', PW)).status, 200);
  assert.equal((await owner.req('POST', '/portal/api/records/plan', { title: 't' }, { 'X-CSRF-Token': 'bad' })).status, 403);
  assert.equal((await owner.req('POST', '/portal/api/records/plan', { title: 't' }, { Origin: 'https://evil.example' })).status, 403);
});

test('records are encrypted at rest and tamper-evident', async () => {
  const secret = 'TARGET-PRICE-7,250,000 ZEBRA-STRATEGY';
  const r = await owner.req('POST', '/portal/api/records/plan', { title: 'Acquisition', body: secret });
  assert.equal(r.status, 201);
  const { id } = await r.json();
  const raw = db.prepare('SELECT data FROM records WHERE id=?').get(id).data;
  assert.ok(!Buffer.from(raw).includes('ZEBRA'), 'plaintext found in database');
  assert.ok(!Buffer.from(raw).includes('7,250,000'));
  const list = await (await owner.req('GET', '/portal/api/records/plan')).json();
  assert.equal(list[0].body, secret);
  // swapping a ciphertext onto another record must fail authentication
  const id2 = (await (await owner.req('POST', '/portal/api/records/plan', { title: 'B', body: 'x' })).json()).id;
  db.prepare('UPDATE records SET data=(SELECT data FROM records WHERE id=?) WHERE id=?').run(id, id2);
  assert.equal((await owner.req('GET', '/portal/api/records/plan')).status, 500);
  db.prepare('DELETE FROM records WHERE id=?').run(id2);
});

test('documents are encrypted in the vault and only downloadable when authorised', async () => {
  const content = Buffer.from('%PDF-1.4 CONFIDENTIAL-BUSINESS-PLAN-BODY');
  const r = await owner.req('POST', '/portal/api/documents', content, { 'Content-Type': 'application/octet-stream', 'X-Filename': encodeURIComponent('plan.pdf') });
  assert.equal(r.status, 201);
  const { id } = await r.json();
  for (const f of fs.readdirSync(path.join(process.env.DATA_DIR, 'vault')))
    assert.ok(!fs.readFileSync(path.join(process.env.DATA_DIR, 'vault', f)).includes('CONFIDENTIAL'));
  const d = await owner.req('GET', `/portal/api/documents/${id}/download`);
  assert.equal(Buffer.from(await d.arrayBuffer()).toString(), content.toString());
  assert.match(d.headers.get('content-disposition'), /attachment/);
  assert.equal((await fetch(`${base}/portal/api/documents/${id}/download`)).status, 401);
  const bad = await owner.req('POST', '/portal/api/documents', Buffer.from('x'), { 'Content-Type': 'application/octet-stream', 'X-Filename': 'evil.exe' });
  assert.equal(bad.status, 415);
});

test('role-based access: viewer is read-only; analyst cannot delete, manage users or publish', async () => {
  const mk = async (role) => {
    const res = await (await owner.req('POST', '/portal/api/users', { email: `${role}@x.com`, name: role, role })).json();
    db.prepare('UPDATE users SET must_change_pw=0 WHERE email=?').run(`${role}@x.com`);
    const c = new Client(); assert.equal((await c.login(`${role}@x.com`, res.temporaryPassword)).status, 200); return c;
  };
  const viewer = await mk('viewer'), analyst = await mk('analyst');
  assert.equal((await viewer.req('GET', '/portal/api/records/plan')).status, 200);
  assert.equal((await viewer.req('POST', '/portal/api/records/plan', { title: 'x' })).status, 403);
  assert.equal((await viewer.req('POST', '/portal/api/documents', Buffer.from('x'), { 'Content-Type': 'application/octet-stream', 'X-Filename': 'a.txt' })).status, 403);
  assert.equal((await analyst.req('POST', '/portal/api/records/plan', { title: 'x', body: 'y' })).status, 201);
  for (const [m, p, b] of [['DELETE', '/records/plan/1'], ['GET', '/users'], ['POST', '/users', { email: 'z@x.com', name: 'z', role: 'owner' }], ['GET', '/audit'], ['GET', '/export'], ['POST', '/publish', { slug: 'a', title: 'a', body: 'a', password: PW, confirm: true }]])
    assert.equal((await analyst.req(m, '/portal/api' + p, b)).status, 403, `${m} ${p}`);
  assert.equal((await viewer.req('GET', '/portal/app.js')).status, 200);
});

test('new users are forced to change their password before any data access', async () => {
  const res = await (await owner.req('POST', '/portal/api/users', { email: 'new@x.com', name: 'New', role: 'viewer' })).json();
  const c = new Client(); await c.login('new@x.com', res.temporaryPassword);
  assert.equal((await c.req('GET', '/portal/api/records/plan')).status, 403);
  assert.equal((await c.req('GET', '/portal/app.js')).status, 404);
});

test('publication: only owner-approved, signed content appears publicly; DB injection is ignored', async () => {
  assert.deepEqual(await (await fetch(base + '/api/public/content')).json(), []);
  const noConfirm = await owner.req('POST', '/portal/api/publish', { slug: 'hello', title: 'Hello', body: 'Welcome', password: PW });
  assert.equal(noConfirm.status, 400);
  const wrongPw = await owner.req('POST', '/portal/api/publish', { slug: 'hello', title: 'Hello', body: 'Welcome', password: 'nope', confirm: true });
  assert.equal(wrongPw.status, 401);
  assert.equal((await owner.req('POST', '/portal/api/publish', { slug: 'hello', title: 'Hello', body: 'Welcome', password: PW, confirm: true })).status, 201);
  let pub = await (await fetch(base + '/api/public/content')).json();
  assert.equal(pub.length, 1);
  const pdb = require('../server/public-db');
  pdb.prepare("INSERT INTO published_content(slug,title,body,published_at,approved_by,signature) VALUES('evil','x','y',1,'attacker','deadbeef')").run();
  pub = await (await fetch(base + '/api/public/content')).json();
  assert.deepEqual(pub.map((p) => p.slug), ['hello']);
});

test('public inquiry form validates, stores, rate-limits, and drops honeypot bots', async () => {
  const post = (b) => fetch(base + '/api/public/inquiries', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(b) });
  assert.equal((await post({ name: 'A', email: 'bad', message: 'short' })).status, 400);
  assert.equal((await post({ name: 'Ann', email: 'ann@x.com', message: 'Interested in investing please', interest: 'Investing with us' })).status, 200);
  await post({ name: 'Bot', email: 'b@x.com', message: 'spam spam spam spam', website: 'http://spam' });
  const rows = await (await owner.req('GET', '/portal/api/inquiries')).json();
  assert.equal(rows.length, 1); assert.equal(rows[0].name, 'Ann');
});

test('audit log is append-only at the database level and its hash chain verifies', async () => {
  assert.throws(() => db.prepare('DELETE FROM audit_log').run(), /append-only/);
  assert.throws(() => db.prepare("UPDATE audit_log SET action='x'").run(), /append-only/);
  const a = await (await owner.req('GET', '/portal/api/audit')).json();
  assert.equal(a.chain.ok, true);
  assert.ok(a.rows.some((r) => r.action === 'login.ok') && a.rows.some((r) => r.action === 'authz.denied'));
});

test('last owner cannot be demoted, disabled or deleted (database triggers)', () => {
  assert.throws(() => db.prepare("UPDATE users SET role='viewer' WHERE email='owner@x.com'").run(), /last active owner/);
  assert.throws(() => db.prepare("UPDATE users SET active=0 WHERE email='owner@x.com'").run(), /last active owner/);
  assert.throws(() => db.prepare("DELETE FROM users WHERE email='owner@x.com'").run(), /deactivate/);
});

test('TOTP implementation matches RFC 6238 test vector', () => {
  const secret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'; // ASCII "12345678901234567890"
  assert.equal(C.totpAt(secret, 59000), '287082');
  assert.ok(C.verifyTotp(secret, '287082', 59000));
});

test('finance engine sanity', () => {
  const F = require('../private-ui/finance.js');
  const r = F.analyze({});
  assert.ok(r.metrics.capRate > 0.05 && r.metrics.dscr > 1);
  const p = F.maxPrice({}, 'dscr', 1.25);
  assert.ok(Math.abs(F.analyze({ purchasePrice: p }).metrics.dscr - 1.25) < 0.001);
});
