'use strict';
// Best-effort fetch of ONE public listing page so its text can be parsed in the browser.
// Hardened against SSRF: https only, allow-listed hosts, DNS pinned to a validated public IP,
// redirects re-validated, size/time limits, no cookies or credentials sent.
const dns = require('node:dns').promises;
const net = require('node:net');
const https = require('node:https');
const http = require('node:http');

const DEFAULT_HOSTS = ['marcusmillichap.com', 'loopnet.com', 'crexi.com'];
const MAX_BYTES = 2 * 1024 * 1024, TIMEOUT_MS = 10000, MAX_HOPS = 3;
const fail = (msg) => Object.assign(new Error(msg), { publicMessage: msg });

function isPrivateIp(ip) {
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  const v = ip.toLowerCase();
  if (v.startsWith('::ffff:')) return isPrivateIp(v.slice(7));
  return v === '::1' || v === '::' || v.startsWith('fc') || v.startsWith('fd') || v.startsWith('fe8') || v.startsWith('fe9') || v.startsWith('fea') || v.startsWith('feb');
}
const hostAllowed = (h, hosts) => hosts.some((x) => h === x || h.endsWith('.' + x));

async function fetchOnce(urlStr, o) {
  let u; try { u = new URL(urlStr); } catch { throw fail('That does not look like a valid link.'); }
  if (u.protocol !== 'https:' && !(o.allowHttp && u.protocol === 'http:')) throw fail('Only https links are supported.');
  if (u.username || u.password) throw fail('Links with credentials are not allowed.');
  const host = u.hostname.toLowerCase();
  if (!hostAllowed(host, o.hosts)) throw fail(`Auto-fetch only works for: ${o.hosts.join(', ')}. For other sites, paste the page text instead.`);
  let addrs;
  try { addrs = await dns.lookup(host, { all: true }); } catch { throw fail('Could not find that website.'); }
  if (!addrs.length || (!o.allowPrivate && addrs.some((a) => isPrivateIp(a.address)))) throw fail('That address is not allowed.');
  const pinned = addrs[0];
  const mod = u.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const req = mod.request({
      host, port: u.port || (u.protocol === 'https:' ? 443 : 80), path: u.pathname + u.search, method: 'GET', servername: host,
      // Node may ask for all addresses (Happy Eyeballs); answer in whichever shape it asks for.
      lookup: (_h, opts, cb) => (opts && opts.all ? cb(null, [{ address: pinned.address, family: pinned.family }]) : cb(null, pinned.address, pinned.family)),
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; DealDashboard/1.0)', Accept: 'text/html', 'Accept-Encoding': 'identity', Host: u.host },
      timeout: TIMEOUT_MS
    }, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location) { res.resume(); return resolve({ redirect: new URL(res.headers.location, u).toString() }); }
      if (res.statusCode !== 200) { res.resume(); return reject(fail(`The site returned an error (${res.statusCode}). It may block automatic access or require sign-in.`)); }
      const chunks = []; let n = 0;
      res.on('data', (c) => { n += c.length; if (n > MAX_BYTES) { req.destroy(); reject(fail('The page was too large.')); } else chunks.push(c); });
      res.on('end', () => resolve({ body: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', () => reject(fail('The download failed.')));
    });
    req.on('timeout', () => { req.destroy(); reject(fail('The site took too long to respond.')); });
    req.on('error', (e) => { console.error('[listing-fetch]', host, e.code || e.message); reject(fail(`Could not reach the site (${e.code || 'connection error'}).`)); });
    req.end();
  });
}
async function fetchListing(url, opts = {}) {
  const o = { hosts: DEFAULT_HOSTS, allowPrivate: false, allowHttp: false, ...opts };
  let cur = url;
  for (let hop = 0; hop <= MAX_HOPS; hop++) {
    const r = await fetchOnce(cur, o);
    if (r.body !== undefined) return r.body;
    cur = r.redirect;
  }
  throw fail('Too many redirects.');
}

const ENT = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&apos;': "'", '&nbsp;': ' ' };
function htmlToText(html) {
  return String(html)
    .replace(/<(script|style|noscript|svg)[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<\/(p|div|li|tr|h[1-6]|section|article|ul|ol|table)>|<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&(?:amp|lt|gt|quot|#39|apos|nbsp);/g, (m) => ENT[m])
    .replace(/&#(\d+);/g, (_m, d) => String.fromCharCode(+d))
    .replace(/[ \t\f\v]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
module.exports = { fetchListing, htmlToText, isPrivateIp, DEFAULT_HOSTS };
