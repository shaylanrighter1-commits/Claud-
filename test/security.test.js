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

test('deal scorecard: verdict follows the owner criteria', () => {
  const F = require('../private-ui/finance.js');
  const weak = F.evaluate(F.analyze({ units: 12, avgRent: 950, otherIncome: 25, purchasePrice: 1350000, capex: 60000, taxes: 16800, insurance: 8400, utilities: 10800, repairs: 12000, payroll: 0, admin: 4800, mgmtPct: 6, ltvPct: 65, ratePct: 6.75, exitCapPct: 6.5 }).metrics);
  assert.equal(weak.verdict, 'Not a good deal');
  const strong = F.evaluate(F.analyze({ units: 12, avgRent: 1500, otherIncome: 25, purchasePrice: 1350000, capex: 60000, taxes: 16800, insurance: 8400, utilities: 10800, repairs: 12000, payroll: 0, admin: 4800, mgmtPct: 6, ltvPct: 65, ratePct: 6.75, exitCapPct: 6.5 }).metrics);
  assert.equal(strong.verdict, 'Good deal');
  const lax = F.evaluate(F.analyze({}).metrics, { minCap: 1, minDscr: 0.5, minCoc: -50, minIrr: -50 });
  assert.equal(lax.verdict, 'Good deal');
});

test('login still works when the browser holds an existing session cookie (no CSRF token on login form)', async () => {
  const c = new Client();
  assert.equal((await c.login('owner@x.com', PW)).status, 200);
  c.csrf = '';                                       // login form never sends a CSRF token
  assert.equal((await c.req('POST', '/portal/api/auth/login', { email: 'owner@x.com', password: PW })).status, 200);
  assert.equal((await c.req('POST', '/portal/api/records/plan', { title: 'x' })).status, 403); // other writes still need the token
});

test('listing paste parser fills address, price, units and derives estimates that match the listing cap rate', () => {
  const F = require('../private-ui/finance.js');
  const win = F.parseListing('Back to the Properties Search Page\nMULTIFAMILY\n12601 S Winchester Ave\n12601 S Winchester Ave, Calumet Park, IL 60827\nListing Price: $840,000\nOFFERING MEMORANDUM & DEAL ROOM\nCap Rate\n8.03%\nNumber of Units\n12\nGRM\n6.16\nOccupancy\n95.0%\nPrice/Unit\n$70,000\nGross SF\n9,900\nMarcus & Millichap have been selected', 'https://www.marcusmillichap.com/properties/304851/12601-s-winchester-ave');
  assert.equal(win.address, '12601 S Winchester Ave, Calumet Park, IL 60827');
  assert.equal(win.name, '12601 S Winchester Ave');
  assert.equal(win.askingPrice, 840000); assert.equal(win.units, 12); assert.equal(win.capRate, 8.03);
  assert.equal(win.source, 'Marcus & Millichap');
  assert.ok(Math.abs(win.uw.avgRent - 947) <= 1);
  const m = F.analyze(win.uw).metrics;
  assert.ok(Math.abs(m.capRate * 100 - 8.03) < 0.3, 'model cap rate should match listing, got ' + m.capRate);
  const ld = F.parseListing('MULTIFAMILY\n4484 La Deney St\n4484 La Deney St, Montclair, CA 91763\nListing Price: $1,435,000\nCap Rate 5.40%\nNumber of Units 4\nGRM 13.29\nOccupancy 100.0%');
  assert.equal(ld.units, 4); assert.equal(ld.askingPrice, 1435000);
  assert.ok(Math.abs(F.analyze(ld.uw).metrics.capRate * 100 - 5.4) < 0.3);
  const mar = F.parseListing('Marion 12\n2394 Marion Ave, North Bend, OR 97459\nListing Price: $1,350,000\nThis complex includes a total of 12 units');
  assert.equal(mar.name, 'Marion 12'); assert.equal(mar.units, 12);
  assert.equal(F.parseListing('hello world').found.length, 0);
  assert.equal(F.parseListing('x', 'javascript:alert(1)').listingUrl, undefined);   // only http(s) links are kept
});

test('listing fetch: SSRF protections and happy path (against a local mock page)', async () => {
  const http = require('node:http');
  const { fetchListing, htmlToText, isPrivateIp } = require('../server/listing-fetch');
  for (const ip of ['127.0.0.1', '10.0.0.5', '192.168.1.9', '172.16.4.4', '169.254.169.254', '::1', 'fd00::1', '::ffff:127.0.0.1', '0.0.0.0'])
    assert.equal(isPrivateIp(ip), true, ip);
  assert.equal(isPrivateIp('8.8.8.8'), false);
  const blocked = async (u, opts) => { try { await fetchListing(u, opts); return false; } catch (e) { return !!e.publicMessage; } };
  assert.ok(await blocked('http://www.marcusmillichap.com/x'));                       // not https
  assert.ok(await blocked('https://evil.example.com/x'));                             // not allow-listed
  assert.ok(await blocked('https://marcusmillichap.com.evil.com/x'));                 // suffix trick
  assert.ok(await blocked('https://user:pw@www.marcusmillichap.com/x'));              // credentials
  assert.ok(await blocked('http://127.0.0.1:1/x', { hosts: ['127.0.0.1'], allowHttp: true })); // private IP without allowPrivate
  assert.ok(await blocked('http://169.254.169.254/latest/meta-data', { hosts: ['169.254.169.254'], allowHttp: true }));
  // happy path + redirect to a disallowed host is refused
  const srv = http.createServer((req, res) => {
    if (req.url === '/redir') { res.writeHead(302, { Location: 'http://localhost:1/' }); return res.end(); }
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end('<html><script>var x=1</script><body><h1>4484 La Deney St</h1><p>4484 La Deney St, Montclair, CA 91763</p><div>Listing Price: $1,435,000</div><span>Cap Rate</span><span>5.40%</span><span>Number of Units</span><span>4</span><span>GRM</span><span>13.29</span></body></html>');
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const port = srv.address().port, opts = { hosts: ['127.0.0.1'], allowHttp: true, allowPrivate: true };
  const F = require('../private-ui/finance.js');
  const parsed = F.parseListing(htmlToText(await fetchListing(`http://127.0.0.1:${port}/p`, opts)), 'x');
  assert.equal(parsed.units, 4); assert.equal(parsed.askingPrice, 1435000); assert.equal(parsed.capRate, 5.4);
  assert.ok(await blocked(`http://127.0.0.1:${port}/redir`, opts));                    // redirect target not allow-listed
  srv.close();
});

test('listing fetch route: auth required, viewers blocked, bad links rejected', async () => {
  assert.equal((await fetch(base + '/portal/api/listing/fetch', { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: base }, body: '{}' })).status, 401);
  assert.equal((await owner.req('POST', '/portal/api/listing/fetch', { url: 'https://evil.example.com/x' })).status, 502);
  assert.equal((await owner.req('POST', '/portal/api/listing/fetch', {})).status, 400);
});

test('listing fetch works with a real hostname (DNS pinning must support the all-addresses lookup shape)', async () => {
  const http = require('node:http');
  const { fetchListing } = require('../server/listing-fetch');
  const srv = http.createServer((q, r) => r.end('<html>Cap Rate 5.4%</html>'));
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const body = await fetchListing(`http://localhost:${srv.address().port}/`, { hosts: ['localhost'], allowHttp: true, allowPrivate: true });
  assert.match(body, /Cap Rate/);
  srv.close();
});

test('listing parser handles residential-portal style text (synthetic samples), without inventing numbers', () => {
  const F = require('../private-ui/finance.js');
  // Redfin/Zillow-style: street and "City, ST ZIP" on separate lines, duplex wording, annual tax label
  const a = F.parseListing('$1,250,000\nPrice\n12320 Texas Ave\nLos Angeles, CA 90025\nDuplex\n3,400 sq ft\nBuilt in 1962\nAnnual Tax Amount: $14,800\nGross Scheduled Income: $78,000\nNet Operating Income $41,000', 'https://www.redfin.com/CA/Los-Angeles/12320-Texas-Ave-90025/home/6764141');
  assert.equal(a.address, '12320 Texas Ave, Los Angeles, CA 90025');
  assert.equal(a.name, '12320 Texas Ave');               // not the label "Price"
  assert.equal(a.units, 2); assert.equal(a.askingPrice, 1250000);
  assert.equal(a.grossSf, 3400); assert.equal(a.yearBuilt, 1962);
  assert.equal(a.uw.taxes, 14800);
  assert.equal(a.uw.avgRent, 3250);                       // 78,000 / 12 / 2
  assert.ok(Math.abs(a.capRate - 3.28) < 0.01);           // derived from NOI / price
  assert.equal(a.source, 'redfin.com');
  // Single-family style page: price + address found, but no units or rent -> nothing invented
  const b = F.parseListing('$899,000\n1234 Main St, Los Angeles, CA 90025\n3 beds 2 baths 1,800 sq ft', '');
  assert.equal(b.askingPrice, 899000); assert.equal(b.units, undefined); assert.equal(b.uw.avgRent, undefined);
  // "Units: 4" label and mid-line address
  const c = F.parseListing('Great fourplex at 55 Oak Lane, Fresno, CA 93721 listed at Asking Price: $640,000. Units: 4');
  assert.equal(c.units, 4); assert.equal(c.address, '55 Oak Lane, Fresno, CA 93721');
});
