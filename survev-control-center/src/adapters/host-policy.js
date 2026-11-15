// Host policy.
//   private  -> loopback / private-network dev hosts: every module, incl. the developer API adapter.
//   live     -> the public survev.io site: ONLY Performance Boost, Pass and Settings. No dev adapter, no overlay
//               renderer, no aiming / entity / visibility modules.
// The developer API adapter (evaluateLocation) never activates on a public host.

const BLOCKED = [/(^|\.)survev\.io$/i, /(^|\.)surviv\.io$/i, /(^|\.)zurviv\.io$/i, /(^|\.)resurviv\.biz$/i];

export function isPrivateHost(hostname) {
  let h = String(hostname || '').toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.slice(1, -1);
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.local')) return true;
  if (h === '::1') return true;
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (m) {
    const [a, b] = [Number(m[1]), Number(m[2])];
    if ([m[1], m[2], m[3], m[4]].some((x) => Number(x) > 255)) return false;
    return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31);
  }
  return false;
}

const LIVE_HOSTS = new Set(['survev.io']);

/** @returns {'private'|'live'|'none'} */
export function classifyLocation(loc) {
  const host = String((loc && loc.hostname) || '').toLowerCase();
  const proto = (loc && loc.protocol) || '';
  if (proto === 'https:' && LIVE_HOSTS.has(host)) return 'live';
  return evaluateLocation(loc).ok ? 'private' : 'none';
}

/** Developer-adapter policy. @returns {{ok:boolean, reason:string}} */
export function evaluateLocation(loc) {
  const host = (loc && loc.hostname) || '';
  const proto = (loc && loc.protocol) || '';
  if (proto !== 'http:' && proto !== 'https:') return { ok: false, reason: `Protocol ${proto || '?'} is not supported` };
  if (BLOCKED.some((re) => re.test(host))) return { ok: false, reason: `${host} is a public multiplayer site — developer modules are disabled there.` };
  if (!isPrivateHost(host)) return { ok: false, reason: `${host} is not a loopback/private development host` };
  return { ok: true, reason: '' };
}
