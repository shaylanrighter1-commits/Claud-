'use strict';
/* Private dashboard. Delivered only to fully authenticated sessions; every call is re-authorised server-side. */
const F = window.Finance;
let ME, CSRF;
const RANK = { viewer: 1, analyst: 2, owner: 3 };
const can = (r) => RANK[ME.user.role] >= RANK[r];

// ---------- helpers (DOM built with textContent only: no HTML injection) ----------
const h = (tag, attrs, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === 'class') e.className = v; else if (k.startsWith('on')) e[k] = v; else if (v === true) e.setAttribute(k, ''); else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const c of kids.flat()) if (c != null && c !== false) e.append(c.nodeType ? c : document.createTextNode(String(c)));
  return e;
};
const api = async (path, method = 'GET', body) => {
  const r = await fetch('/portal/api' + path, { method, headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': CSRF }, body: body ? JSON.stringify(body) : undefined });
  if (r.status === 401 || (r.status === 403 && (await r.clone().json().catch(() => ({}))).limited)) { location.href = '/portal/'; throw new Error('Session ended'); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || 'Request failed');
  return j;
};
const $ = (n) => (n == null ? '—' : n.toLocaleString(undefined, { maximumFractionDigits: 0 }));
const usd = (n) => (n == null ? '—' : (n < 0 ? '-$' : '$') + Math.abs(Math.round(n)).toLocaleString());
const pct = (n, d = 1) => (n == null || !isFinite(n) ? '—' : (n * 100).toFixed(d) + '%');
const x2 = (n) => (n == null ? '—' : n.toFixed(2) + 'x');
const fdate = (t) => new Date(t).toLocaleString();
const kpi = (label, value) => h('div', { class: 'kpi' }, h('b', {}, value), h('span', {}, label));
const toast = (m, bad) => { const t = h('p', { class: bad ? 'err' : 'ok', role: 'status' }, m); main.prepend(t); setTimeout(() => t.remove(), 4000); };
const guard = (fn) => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message, true); } };
function input(label, name, val, type = 'text', extra = {}) { return h('label', {}, label, h('input', { name, type, value: val ?? '', step: 'any', ...extra })); }
function select(label, name, opts, val) { return h('label', {}, label, h('select', { name }, opts.map((o) => h('option', { value: o, selected: o === val }, o)))); }
const formData = (f) => Object.fromEntries(new FormData(f));
function table(cols, rows, onRow) {
  return h('table', {}, h('thead', {}, h('tr', {}, cols.map((c) => h('th', { class: c.num ? 'num' : '' }, c.label)))),
    h('tbody', {}, rows.map((r) => h('tr', {}, cols.map((c) => h('td', { class: c.num ? 'num' : '' }, c.render ? c.render(r) : r[c.key]))))));
}
function download(name, text, type = 'text/csv') {
  const a = h('a', { href: URL.createObjectURL(new Blob([text], { type })), download: name }); document.body.append(a); a.click(); a.remove();
}
const csvCell = (v) => { v = String(v ?? ''); return /^[=+\-@\t\r]/.test(v) ? `"'${v.replace(/"/g, '""')}"` : /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v; }; // neutralise spreadsheet formulas

async function getCriteria() {
  const r = (await api('/records/assumption')).find((x) => x.type === 'criteria');
  return { ...F.DEFAULT_CRITERIA, ...(r ? { minCap: r.minCap, minDscr: r.minDscr, minCoc: r.minCoc, minIrr: r.minIrr } : {}), _id: r ? r.id : null };
}
const fmtCheck = (c) => (c.value === null ? '—' : c.unit === 'x' ? c.value.toFixed(2) + 'x' : c.value.toFixed(1) + '%');
const verdictClass = (v) => (v === 'Good deal' ? 'v-good' : v === 'Borderline' ? 'v-mid' : 'v-bad');
const verdictIcon = (v) => (v === 'Good deal' ? '✓ ' : v === 'Borderline' ? '~ ' : '✗ ');
function verdictBanner(ev) {
  return h('div', { class: 'panel verdict ' + verdictClass(ev.verdict) },
    h('b', {}, verdictIcon(ev.verdict) + ev.verdict), h('span', { class: 'muted' }, ` — meets ${ev.passed} of ${ev.total} of your targets`),
    table([{ label: 'Test' }, { label: 'This deal', num: 1 }, { label: 'Your target', num: 1 }, { label: '' }].map((c, i) => ({ ...c, render: (r) => r[i] })),
      ev.checks.map((c) => [c.name, fmtCheck(c), '≥ ' + (c.unit === 'x' ? c.target.toFixed(2) + 'x' : c.target + '%'), c.ok ? '✓ pass' : '✗ short'])));
}
const STAGES = ['Sourcing', 'Screening', 'Underwriting', 'Offer', 'Under contract', 'Closed', 'Passed'];
const main = document.getElementById('main');

// ---------- views ----------
const views = {};
const NAV = [
  ['overview', 'Overview'], ['plan', 'Business plan'], ['properties', 'Properties'], ['calc', 'Calculator'], ['compare', 'Compare'],
  ['capital', 'Capital & financing'], ['projections', 'Projections'], ['docs', 'Documents'], ['inquiries', 'Inquiries', 'analyst'],
  ['publish', 'Publishing', 'owner'], ['users', 'Users & access', 'owner'], ['audit', 'Audit log', 'owner']
];

views.overview = async () => {
  const [props, fin, plan, docs] = await Promise.all([api('/records/property'), api('/records/financing'), api('/records/plan'), api('/documents')]);
  const active = props.filter((p) => !['Passed'].includes(p.stage));
  const results = active.filter((p) => p.uw).map((p) => F.analyze(p.uw));
  const pf = results.length ? F.portfolio(results) : null;
  main.append(h('h2', {}, 'Overview'), h('p', { class: 'conf' }, 'Confidential — not for distribution'),
    h('div', { class: 'cards' }, kpi('Active pipeline', active.length), kpi('Plan sections', plan.length), kpi('Documents', docs.length), kpi('Financing records', fin.length),
      pf && kpi('Pipeline purchase volume', usd(pf.price)), pf && kpi('Pipeline equity required', usd(pf.equity)), pf && kpi('Blended IRR', pct(pf.irr))),
    h('h3', {}, 'Pipeline by stage'),
    table([{ label: 'Stage', key: 'stage' }, { label: 'Deals', key: 'n', num: 1 }], STAGES.map((s) => ({ stage: s, n: props.filter((p) => p.stage === s).length }))));
  if (!props.length && !plan.length) main.append(h('p', { class: 'warn' }, 'The vault is empty. Import your business plan under “Business plan” and upload source documents under “Documents”. Everything is encrypted at rest.'));
};

views.plan = async () => {
  const secs = (await api('/records/plan')).sort((a, b) => (a.order ?? a.id) - (b.order ?? b.id));
  main.append(h('h2', {}, 'Business plan'), h('p', { class: 'conf' }, 'Confidential — encrypted at rest'));
  if (can('analyst')) {
    const importText = async (text) => {
      const parts = text.split(/^(?=#{1,3}\s)/m).filter((t) => t.trim());
      if (!parts.length) throw new Error('Nothing to import');
      let i = secs.length;
      for (const p of parts) { const m = p.match(/^#{1,3}\s+(.*)\n?/); await api('/records/plan', 'POST', { title: m ? m[1].trim() : 'Untitled', body: m ? p.slice(m[0].length).trim() : p.trim(), order: i++ }); }
      await router(); toast(`Imported ${parts.length} sections`);
    };
    const file = h('input', { type: 'file' });
    const paste = h('textarea', { placeholder: 'Paste your plan here. Lines starting with # become section titles.' });
    main.append(h('div', { class: 'panel' }, h('b', {}, 'Import plan text'), h('p', { class: 'muted' }, 'Paste text below (easiest), or choose a .md/.txt file. Text is split into sections at headings. For PDF/Word originals, use Documents (stored encrypted).'),
      paste, h('div', { class: 'row' }, h('button', { onclick: guard(() => importText(paste.value)) }, 'Import pasted text'), h('button', { class: 'sec', onclick: () => editPlan() }, 'New section')),
      h('div', { class: 'row' }, file, h('button', { class: 'sec', onclick: guard(async () => { const f = file.files[0]; if (!f) throw new Error('Choose a file first'); await importText(await f.text()); }) }, 'Import file'))));
  }
  for (const s of secs) main.append(h('div', { class: 'panel' }, h('h3', {}, s.title), h('div', { class: 'pre' }, s.body), can('analyst') && h('div', { class: 'row noprint' }, h('button', { class: 'sec', onclick: () => editPlan(s) }, 'Edit'), can('owner') && h('button', { class: 'danger', onclick: guard(async () => { if (confirm('Delete this section?')) { await api('/records/plan/' + s.id, 'DELETE'); router(); } }) }, 'Delete'))));
  if (!secs.length) main.append(h('p', { class: 'muted' }, 'No sections yet.'));
};
function editPlan(s = {}) {
  const f = h('form', { class: 'panel' }, h('h3', {}, s.id ? 'Edit section' : 'New section'), input('Title', 'title', s.title), h('label', {}, 'Body', h('textarea', { name: 'body' }, s.body || '')),
    h('div', { class: 'row' }, h('button', {}, 'Save'), h('button', { type: 'button', class: 'sec', onclick: () => router() }, 'Cancel')));
  f.onsubmit = guard(async (e) => { e.preventDefault(); const d = formData(f); const body = { title: d.title, body: d.body, order: s.order }; s.id ? await api('/records/plan/' + s.id, 'PUT', body) : await api('/records/plan', 'POST', body); router(); });
  main.replaceChildren(f);
}

const UW_GROUPS = [
  ['Property & income', { units: 'Units', avgRent: 'Avg rent / unit / mo ($)', otherIncome: 'Other income / unit / mo ($)', vacancyPct: 'Vacancy (%)' }],
  ['Acquisition', { purchasePrice: 'Purchase price ($)', closingPct: 'Closing costs (%)', capex: 'Upfront capex ($)' }],
  ['Operating expenses (annual)', { taxes: 'Property taxes', insurance: 'Insurance', utilities: 'Utilities', repairs: 'Repairs & maintenance', payroll: 'Payroll', admin: 'Admin & other', mgmtPct: 'Management (% of EGI)', reservesPerUnit: 'Reserves / unit / yr' }],
  ['Financing', { ltvPct: 'LTV (%)', ratePct: 'Interest rate (%)', amortYears: 'Amortisation (yrs)', ioYears: 'Interest-only (yrs)', loanFeePct: 'Loan fee (%)' }],
  ['Growth & exit', { rentGrowthPct: 'Rent growth (%)', expGrowthPct: 'Expense growth (%)', holdYears: 'Hold (yrs)', exitCapPct: 'Exit cap (%)', saleCostPct: 'Sale costs (%)' }]
];
const uwInputs = (f) => Object.fromEntries(Object.keys(F.DEFAULTS).map((k) => [k, +f.elements[k].value]));

views.properties = async () => {
  const [props, crit] = [await api('/records/property'), await getCriteria()];
  main.append(h('h2', {}, 'Properties & opportunities'), h('p', { class: 'conf' }, 'Confidential — proprietary pipeline'), can('analyst') && h('div', { class: 'row' }, h('button', { onclick: () => editProperty() }, 'Add property')));
  main.append(table([
    { label: 'Name', render: (p) => h('a', { href: '#', onclick: (e) => { e.preventDefault(); editProperty(p); } }, p.name) }, { label: 'Stage', key: 'stage' }, { label: 'Address', key: 'address' },
    { label: 'Listing', render: (p) => (p.listingUrl && /^https?:\/\//i.test(p.listingUrl) ? h('a', { href: p.listingUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Open ↗') : '') },
    { label: 'Asking', num: 1, render: (p) => usd(p.askingPrice) }, { label: 'Target price', num: 1, render: (p) => usd(p.targetPrice) },
    { label: 'Cap @ target', num: 1, render: (p) => (p.uw ? pct(F.analyze({ ...p.uw, purchasePrice: p.targetPrice || p.uw.purchasePrice }).metrics.capRate, 2) : '—') },
    { label: 'IRR', num: 1, render: (p) => (p.uw ? pct(F.analyze(p.uw).metrics.irr) : '—') },
    { label: 'Verdict', render: (p) => (p.uw ? h('span', { class: 'tag ' + verdictClass(F.evaluate(F.analyze(p.uw).metrics, crit).verdict) }, verdictIcon(F.evaluate(F.analyze(p.uw).metrics, crit).verdict) + F.evaluate(F.analyze(p.uw).metrics, crit).verdict) : '—') }], props));
  if (!props.length) main.append(h('p', { class: 'muted' }, 'No properties yet.'));
};
function editProperty(p = {}) {
  const uw = { ...F.DEFAULTS, ...(p.uw || {}) };
  const qfText = h('textarea', { placeholder: 'Backup: if the link does not work, open the listing (signed in), press Cmd+A then Cmd+C, and paste the page text here, then click Auto-fill.' });
  const qfUrl = h('input', { type: 'url', placeholder: 'Paste a listing link (Marcus & Millichap, LoopNet, Crexi) and press Enter', value: p.listingUrl || '', name: 'listingUrl' });
  const qfMsg = h('p', { class: 'muted' });
  const applyListing = (r) => {
    const set = (n, v) => { if (v !== undefined && v !== null && f.elements[n]) f.elements[n].value = v; };
    set('name', r.name); set('address', r.address); set('askingPrice', r.askingPrice); set('source', r.source);
    for (const [k, v] of Object.entries(r.uw)) set(k, v);
    const extra = [r.capRate && `listing cap rate ${r.capRate}%`, r.grm && `GRM ${r.grm}`, r.occupancy && `occupancy ${r.occupancy}%`, r.grossSf && `${r.grossSf.toLocaleString()} sq ft`, r.yearBuilt && `built ${r.yearBuilt}`].filter(Boolean).join(', ');
    set('notes', `${r.listingUrl ? 'Listing: ' + r.listingUrl + '\n' : ''}Auto-filled from a listing${extra ? ' (' + extra + ')' : ''}.\nESTIMATED, not from the offering memorandum: ${r.estimated.join('; ') || 'none'}.\nVerify rents and expenses before relying on the verdict.`);
    qfMsg.className = 'ok'; qfMsg.textContent = `Filled: ${r.found.join(', ')}. Estimated: ${r.estimated.join(', ') || 'nothing'}. Review the boxes below, then Save.`;
  };
  const autoFill = async () => {
    const link = qfUrl.value.trim(); let text = qfText.value;
    qfMsg.className = 'muted'; qfMsg.textContent = 'Working…';
    try {
      if (!text.trim()) {
        if (!/^https?:\/\//i.test(link)) throw new Error('Paste a listing link first (or paste the page text in the big box).');
        text = (await api('/listing/fetch', 'POST', { url: link })).text;
      }
      const r = F.parseListing(text, link);
      if (!r.found.length) throw new Error('The site did not give me the numbers (it may need you to be signed in). Open the listing, press Cmd+A then Cmd+C, paste the page text in the big box, and click Auto-fill.');
      applyListing(r);
    } catch (e) { qfMsg.className = 'err'; qfMsg.textContent = e.message; }
  };
  qfUrl.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); autoFill(); } });
  const quickFill = h('div', { class: 'panel' }, h('b', {}, 'Quick fill from a listing'), h('p', { class: 'muted' }, 'Paste the link and press Enter. If the site blocks it, use the backup box.'), qfUrl, qfText,
    h('div', { class: 'row' }, h('button', { type: 'button', onclick: autoFill }, 'Auto-fill'), qfMsg));
  const f = h('form', {}, h('h2', {}, p.id ? 'Edit property' : 'Add property'), quickFill,
    p.listingUrl && /^https?:\/\//i.test(p.listingUrl) && h('p', {}, h('a', { href: p.listingUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Open original listing')),
    h('div', { class: 'panel' }, h('div', { class: 'fields' }, input('Name', 'name', p.name, 'text', { required: true }), input('Address', 'address', p.address), select('Stage', 'stage', STAGES, p.stage || 'Sourcing'),
      input('Asking price ($)', 'askingPrice', p.askingPrice, 'number'), input('Target acquisition price ($)', 'targetPrice', p.targetPrice, 'number'), input('Seller / broker', 'source', p.source)),
      h('label', {}, 'Notes & strategy', h('textarea', { name: 'notes' }, p.notes || ''))),
    UW_GROUPS.map(([t, fields]) => h('div', { class: 'panel' }, h('b', {}, t), h('div', { class: 'fields' }, Object.entries(fields).map(([k, l]) => input(l, k, uw[k], 'number'))))),
    h('div', { class: 'row' }, h('button', {}, 'Save'), h('button', { type: 'button', class: 'sec', onclick: () => { sessionStorage.setItem('calc', JSON.stringify(uwInputs(f))); location.hash = 'calc'; } }, 'Open in calculator'),
      h('button', { type: 'button', class: 'sec', onclick: () => router() }, 'Cancel')));
  if (!can('analyst')) for (const el of f.elements) el.disabled = true;
  f.onsubmit = guard(async (e) => {
    e.preventDefault(); const d = formData(f);
    const body = { listingUrl: /^https?:\/\//i.test(d.listingUrl || '') ? d.listingUrl.trim() : undefined, name: d.name, address: d.address, stage: d.stage, askingPrice: +d.askingPrice || null, targetPrice: +d.targetPrice || null, source: d.source, notes: d.notes, uw: uwInputs(f) };
    p.id ? await api('/records/property/' + p.id, 'PUT', body) : await api('/records/property', 'POST', body); router();
  });
  if (p.id && can('owner')) f.append(h('div', { class: 'row' }, h('button', { type: 'button', class: 'danger', onclick: guard(async () => { if (confirm('Delete property?')) { await api('/records/property/' + p.id, 'DELETE'); router(); } }) }, 'Delete property')));
  main.replaceChildren(f);
}

views.calc = async () => {
  let start = {}; try { start = JSON.parse(sessionStorage.getItem('calc') || '{}'); } catch { /* ignore */ }
  const uw = { ...F.DEFAULTS, ...start };
  let crit = await getCriteria();
  const vbox = h('div', {});
  const out = h('div', {});
  const f = h('form', { class: 'noprint' }, UW_GROUPS.map(([t, fields]) => h('div', { class: 'panel' }, h('b', {}, t), h('div', { class: 'fields' }, Object.entries(fields).map(([k, l]) => input(l, k, uw[k], 'number'))))));
  const draw = () => {
    const inputs = uwInputs(f), r = F.analyze(inputs), m = r.metrics;
    sessionStorage.setItem('calc', JSON.stringify(inputs));
    const solve = (metric, target) => F.maxPrice(inputs, metric, target);
    vbox.replaceChildren(verdictBanner(F.evaluate(m, crit)));
    out.replaceChildren(
      h('div', { class: 'cards' }, kpi('NOI (Yr 1)', usd(m.noi)), kpi('Cap rate', pct(m.capRate, 2)), kpi('DSCR', x2(m.dscr)), kpi('Debt yield', pct(m.debtYield)), kpi('Cash-on-cash (Yr 1)', pct(m.cashOnCash)),
        kpi('Equity required', usd(r.equity)), kpi('Loan', usd(r.loan)), kpi('Price / unit', usd(m.pricePerUnit)), kpi('All-in / unit', usd(m.allInBasis)), kpi('Break-even occ.', pct(m.breakevenOccupancy)),
        kpi('Expense ratio', pct(m.expenseRatio)), kpi('Exit value', usd(m.exitValue)), kpi('IRR', pct(m.irr)), kpi('Equity multiple', x2(m.equityMultiple))),
      h('div', { class: 'panel' }, h('b', {}, 'Maximum purchase price (other inputs held constant)'), table([{ label: 'To achieve' }, { label: 'Max price', num: 1 }].map((c, i) => ({ ...c, render: (r) => r[i] })), [
        ['Cap rate ≥ 7.0%', usd(solve('cap', 0.07))], ['DSCR ≥ 1.25x', usd(solve('dscr', 1.25))], ['Cash-on-cash ≥ 8%', usd(solve('coc', 0.08))], ['IRR ≥ 15%', usd(solve('irr', 0.15))]])),
      h('div', { class: 'panel' }, h('b', {}, 'Pro forma'), table([{ label: 'Year', key: 'year' }, ...[['gpr', 'Gross potential rent'], ['vacancy', 'Vacancy'], ['egi', 'EGI'], ['opex', 'Operating expenses'], ['noi', 'NOI'], ['debtService', 'Debt service'], ['cashFlow', 'Cash flow']].map(([k, l]) => ({ label: l, num: 1, render: (y) => usd(y[k]) })), { label: 'DSCR', num: 1, render: (y) => x2(y.dscr) }], r.years)));
  };
  f.addEventListener('input', draw);
  const save = can('analyst') && h('div', { class: 'row noprint' }, h('button', { onclick: guard(async () => { const name = prompt('Property name to save this underwriting as:'); if (!name) return; await api('/records/property', 'POST', { name, stage: 'Underwriting', uw: uwInputs(f) }); toast('Saved to Properties'); }) }, 'Save as property'),
    h('button', { class: 'sec', onclick: () => { sessionStorage.removeItem('calc'); router(); } }, 'Reset'));
  const cf = h('form', { class: 'panel noprint' }, h('b', {}, 'Your deal targets (used for the Good / Borderline / Not good verdict)'),
    h('div', { class: 'fields' }, input('Min cap rate (%)', 'minCap', crit.minCap, 'number'), input('Min DSCR (x)', 'minDscr', crit.minDscr, 'number'), input('Min cash-on-cash (%)', 'minCoc', crit.minCoc, 'number'), input('Min IRR (%)', 'minIrr', crit.minIrr, 'number')),
    can('analyst') && h('button', {}, 'Save my targets'));
  cf.addEventListener('input', () => { for (const k of ['minCap', 'minDscr', 'minCoc', 'minIrr']) if (cf.elements[k].value !== '') crit[k] = +cf.elements[k].value; draw(); });
  cf.onsubmit = guard(async (e) => { e.preventDefault(); const b = { type: 'criteria', minCap: crit.minCap, minDscr: crit.minDscr, minCoc: crit.minCoc, minIrr: crit.minIrr };
    crit._id ? await api('/records/assumption/' + crit._id, 'PUT', b) : (crit._id = (await api('/records/assumption', 'POST', b)).id); toast('Targets saved'); });
  main.append(h('h2', {}, 'Advanced calculator'), h('p', { class: 'conf' }, 'Proprietary underwriting model'), save, f, out, vbox, cf); draw();
};

views.compare = async () => {
  const props = (await api('/records/property')).filter((p) => p.uw);
  const crit = await getCriteria();
  const box = h('div', {});
  const picks = props.map((p) => h('label', { class: 'row' }, h('input', { type: 'checkbox', value: p.id, onchange: draw }), p.name));
  function draw() {
    const sel = props.filter((p) => picks.some((c) => c.firstChild.checked && +c.firstChild.value === p.id));
    if (sel.length < 2) return box.replaceChildren(h('p', { class: 'muted' }, 'Select two or more properties.'));
    const res = sel.map((p) => ({ p, r: F.analyze(p.uw) }));
    const rows = [['Verdict', (x) => F.evaluate(x.r.metrics, crit).verdict], ['Stage', (x) => x.p.stage], ['Purchase price', (x) => usd(x.r.inputs.purchasePrice)], ['Units', (x) => $(x.r.inputs.units)], ['Price / unit', (x) => usd(x.r.metrics.pricePerUnit)], ['NOI (Yr 1)', (x) => usd(x.r.metrics.noi)],
      ['Cap rate', (x) => pct(x.r.metrics.capRate, 2)], ['DSCR', (x) => x2(x.r.metrics.dscr)], ['Cash-on-cash', (x) => pct(x.r.metrics.cashOnCash)], ['Equity required', (x) => usd(x.r.equity)],
      ['IRR', (x) => pct(x.r.metrics.irr)], ['Equity multiple', (x) => x2(x.r.metrics.equityMultiple)], ['Break-even occupancy', (x) => pct(x.r.metrics.breakevenOccupancy)], ['Expense ratio', (x) => pct(x.r.metrics.expenseRatio)]];
    box.replaceChildren(table([{ label: 'Metric', key: 0 }, ...res.map((x, i) => ({ label: x.p.name, num: 1, render: (r) => r[i + 1] }))], rows.map(([l, fn]) => [l, ...res.map(fn)])));
  }
  main.append(h('h2', {}, 'Property comparison'), h('p', { class: 'conf' }, 'Confidential'), h('div', { class: 'panel' }, picks.length ? picks : h('p', { class: 'muted' }, 'Add properties with underwriting first.')), box);
  draw();
};

views.capital = async () => {
  const [fin, props] = await Promise.all([api('/records/financing'), api('/records/property')]);
  const sum = (t) => fin.filter((x) => x.type === t && x.status !== 'Declined').reduce((s, x) => s + (+x.amount || 0), 0);
  const need = props.filter((p) => p.uw && !['Passed', 'Closed'].includes(p.stage)).map((p) => F.analyze(p.uw)).reduce((s, r) => s + r.equity, 0);
  main.append(h('h2', {}, 'Investment capital & financing'), h('p', { class: 'conf' }, 'Confidential'),
    h('div', { class: 'cards' }, kpi('Equity committed', usd(sum('Equity'))), kpi('Equity needed (open pipeline)', usd(need)), kpi('Surplus / (gap)', usd(sum('Equity') - need)), kpi('Debt sources', usd(sum('Debt')))),
    can('analyst') && h('div', { class: 'row' }, h('button', { onclick: () => editFin() }, 'Add capital / financing source')),
    table([{ label: 'Type', key: 'type' }, { label: 'Party', render: (x) => h('a', { href: '#', onclick: (e) => { e.preventDefault(); editFin(x); } }, x.party) }, { label: 'Amount', num: 1, render: (x) => usd(x.amount) }, { label: 'Rate / pref', key: 'rate' }, { label: 'Status', key: 'status' }, { label: 'Terms', key: 'terms' }], fin));
};
function editFin(x = {}) {
  const f = h('form', { class: 'panel' }, h('h3', {}, x.id ? 'Edit source' : 'New source'), h('div', { class: 'fields' }, select('Type', 'type', ['Equity', 'Debt', 'Other'], x.type), input('Party (investor / lender)', 'party', x.party, 'text', { required: true }), input('Amount ($)', 'amount', x.amount, 'number'), input('Rate / preferred return', 'rate', x.rate), select('Status', 'status', ['Prospect', 'Soft-circled', 'Committed', 'Funded', 'Declined'], x.status)),
    h('label', {}, 'Terms & notes', h('textarea', { name: 'terms' }, x.terms || '')), h('div', { class: 'row' }, h('button', {}, 'Save'), h('button', { type: 'button', class: 'sec', onclick: () => router() }, 'Cancel'),
      x.id && can('owner') && h('button', { type: 'button', class: 'danger', onclick: guard(async () => { if (confirm('Delete?')) { await api('/records/financing/' + x.id, 'DELETE'); router(); } }) }, 'Delete')));
  f.onsubmit = guard(async (e) => { e.preventDefault(); const d = formData(f); const b = { ...d, amount: +d.amount || 0 }; x.id ? await api('/records/financing/' + x.id, 'PUT', b) : await api('/records/financing', 'POST', b); router(); });
  main.replaceChildren(f);
}

views.projections = async () => {
  const props = (await api('/records/property')).filter((p) => p.uw && p.stage !== 'Passed');
  const box = h('div', {});
  const picks = props.map((p) => h('label', { class: 'row' }, h('input', { type: 'checkbox', value: p.id, checked: true, onchange: draw }), p.name, h('span', { class: 'tag' }, p.stage)));
  let last = null;
  function draw() {
    const sel = props.filter((p) => picks.some((c) => c.firstChild.checked && +c.firstChild.value === p.id));
    if (!sel.length) return box.replaceChildren(h('p', { class: 'muted' }, 'Select properties.'));
    const pf = F.portfolio(sel.map((p) => F.analyze(p.uw))); last = pf;
    const max = Math.max(...pf.rows.map((r) => Math.abs(r.cashFlow)), 1), w = 600 / pf.rows.length;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'); svg.setAttribute('viewBox', '0 0 600 200'); svg.setAttribute('class', 'chart'); svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', 'Annual portfolio cash flow');
    pf.rows.forEach((r, i) => {
      const hgt = Math.abs(r.cashFlow) / max * 150, rect = document.createElementNS(svg.namespaceURI, 'rect');
      rect.setAttribute('x', i * w + 8); rect.setAttribute('width', w - 16); rect.setAttribute('y', 170 - hgt); rect.setAttribute('height', hgt); svg.append(rect);
      const t = document.createElementNS(svg.namespaceURI, 'text'); t.setAttribute('x', i * w + w / 2); t.setAttribute('y', 188); t.setAttribute('text-anchor', 'middle'); t.textContent = 'Y' + r.year; svg.append(t);
    });
    box.replaceChildren(h('div', { class: 'cards' }, kpi('Purchase volume', usd(pf.price)), kpi('Total debt', usd(pf.loan)), kpi('Total equity', usd(pf.equity)), kpi('Portfolio IRR', pct(pf.irr)), kpi('Equity multiple', x2(pf.multiple))), svg,
      table([{ label: 'Year', key: 'year' }, { label: 'NOI', num: 1, render: (r) => usd(r.noi) }, { label: 'Debt service', num: 1, render: (r) => usd(r.debtService) }, { label: 'Cash flow', num: 1, render: (r) => usd(r.cashFlow) }], pf.rows));
  }
  const exp = can('analyst') && h('div', { class: 'row noprint' }, h('button', { class: 'sec', onclick: () => { if (last) download('projection.csv', ['Year,NOI,Debt service,Cash flow', ...last.rows.map((r) => [r.year, r.noi, r.debtService, r.cashFlow].map(Math.round).map(csvCell).join(','))].join('\n')); } }, 'Export CSV'), h('button', { class: 'sec', onclick: () => print() }, 'Print report'));
  main.append(h('h2', {}, 'Portfolio projections'), h('p', { class: 'conf' }, 'Confidential — assumes all selected deals close on day 1'), h('div', { class: 'panel noprint' }, picks.length ? picks : h('p', { class: 'muted' }, 'Add underwritten properties first.')), exp, box);
  draw();
};

views.docs = async () => {
  const docs = await api('/documents');
  main.append(h('h2', {}, 'Confidential documents'), h('p', { class: 'muted' }, 'Stored AES-256-GCM encrypted under random file names. Downloads are logged.'));
  if (can('analyst')) {
    const file = h('input', { type: 'file' });
    main.append(h('div', { class: 'panel row' }, file, h('button', { onclick: guard(async () => {
      const f = file.files[0]; if (!f) throw new Error('Choose a file');
      const r = await fetch('/portal/api/documents', { method: 'POST', headers: { 'Content-Type': 'application/octet-stream', 'X-CSRF-Token': CSRF, 'X-Filename': encodeURIComponent(f.name) }, body: f });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'Upload failed'); router();
    }) }, 'Upload encrypted')));
  }
  main.append(table([{ label: 'Name', render: (d) => h('a', { href: `/portal/api/documents/${d.id}/download` }, d.name) }, { label: 'Size', num: 1, render: (d) => Math.ceil(d.size / 1024) + ' KB' }, { label: 'Added', render: (d) => fdate(d.createdAt) },
    { label: '', render: (d) => can('owner') && h('button', { class: 'danger', onclick: guard(async () => { if (confirm('Delete document permanently?')) { await api('/documents/' + d.id, 'DELETE'); router(); } }) }, 'Delete') }], docs));
};

views.inquiries = async () => {
  const rows = await api('/inquiries');
  main.append(h('h2', {}, 'Website inquiries'), table([{ label: 'When', render: (r) => fdate(r.ts) }, { label: 'From', render: (r) => `${r.name} <${r.email}>${r.phone ? ' · ' + r.phone : ''}` }, { label: 'Interest', key: 'interest' }, { label: 'Message', render: (r) => h('span', { class: 'pre' }, r.message) },
    { label: 'Handled', render: (r) => h('input', { type: 'checkbox', checked: !!r.handled, onchange: guard((e) => api('/inquiries/' + r.id, 'PATCH', { handled: e.target.checked })) }) }], rows));
};

views.publish = async () => {
  const pubd = await api('/publish');
  const f = h('form', { class: 'panel' }, h('h3', {}, 'Publish to the public website'),
    h('p', { class: 'warn' }, 'Publishing makes text visible to everyone on the internet and to search engines. Never paste plan content, pricing, targets, or financing. You are the only user who can do this.'),
    input('Slug (a-z, 0-9, -)', 'slug', '', 'text', { pattern: '[a-z0-9-]{1,60}', required: true }), input('Title', 'title', '', 'text', { required: true, maxlength: 120 }), h('label', {}, 'Body (plain text)', h('textarea', { name: 'body', required: true, maxlength: 10000 })),
    input('Re-enter your password', 'password', '', 'password', { autocomplete: 'current-password', required: true }),
    h('label', { class: 'row' }, h('input', { type: 'checkbox', name: 'confirm', required: true }), 'I confirm this content is approved for public release.'), h('button', {}, 'Publish'));
  f.onsubmit = guard(async (e) => { e.preventDefault(); const d = formData(f); await api('/publish', 'POST', { ...d, confirm: !!d.confirm }); router(); });
  main.append(h('h2', {}, 'Publishing'), f, h('h3', {}, 'Currently public'), table([{ label: 'Slug', key: 'slug' }, { label: 'Title', key: 'title' }, { label: 'Published', render: (r) => fdate(r.publishedAt) }, { label: 'Approved by', key: 'approvedBy' },
    { label: '', render: (r) => h('button', { class: 'danger', onclick: guard(async () => { await api('/publish/' + r.slug, 'DELETE'); router(); }) }, 'Unpublish') }], pubd));
};

views.users = async () => {
  const users = await api('/users');
  const f = h('form', { class: 'panel' }, h('h3', {}, 'Authorize a new user'), h('p', { class: 'muted' }, 'Viewer: read-only. Analyst: read/write, upload, export. Owner: full control. The user must change the temporary password and enrol 2FA at first sign-in.'),
    h('div', { class: 'fields' }, input('Name', 'name', '', 'text', { required: true }), input('Email', 'email', '', 'email', { required: true }), select('Role', 'role', ['viewer', 'analyst', 'owner'], 'viewer')), h('button', {}, 'Create user'));
  const pwBox = h('div', {});
  f.onsubmit = guard(async (e) => { e.preventDefault(); const r = await api('/users', 'POST', formData(f)); pwBox.replaceChildren(h('p', { class: 'warn' }, 'Temporary password (shown once): ', h('code', {}, r.temporaryPassword))); f.reset(); });
  const act = (u, body, label, cls = 'sec') => h('button', { class: cls, onclick: guard(async () => { const r = await api('/users/' + u.id, 'PATCH', body); if (r.temporaryPassword) { pwBox.replaceChildren(h('p', { class: 'warn' }, `New temporary password for ${u.email}: `, h('code', {}, r.temporaryPassword))); } else router(); }) }, label);
  main.append(h('h2', {}, 'Users & access'), f, pwBox, table([{ label: 'Name', key: 'name' }, { label: 'Email', key: 'email' }, { label: 'Role', key: 'role' }, { label: '2FA', render: (u) => (u.totpEnabled ? 'on' : 'off') }, { label: 'Status', render: (u) => (u.active ? 'active' : 'disabled') },
    { label: '', render: (u) => h('div', { class: 'row' }, u.role !== 'viewer' && act(u, { role: 'viewer' }, '→ viewer'), u.role !== 'analyst' && act(u, { role: 'analyst' }, '→ analyst'), u.role !== 'owner' && act(u, { role: 'owner' }, '→ owner'), act(u, { resetPassword: true }, 'Reset password'), act(u, { resetTwoFactor: true }, 'Reset 2FA'), act(u, { active: !u.active }, u.active ? 'Disable' : 'Enable', u.active ? 'danger' : 'sec')) }], users));
};

views.audit = async () => {
  const { chain, rows } = await api('/audit');
  main.append(h('h2', {}, 'Audit log'), h('p', { class: chain.ok ? 'ok' : 'err' }, chain.ok ? '✓ Hash chain intact (tamper-evident).' : `✗ Chain broken at entry ${chain.brokenAt}`),
    table([{ label: 'Time', render: (r) => fdate(r.ts) }, { label: 'User', key: 'email' }, { label: 'Action', key: 'action' }, { label: 'Target', key: 'target' }, { label: 'IP', key: 'ip' }, { label: 'Detail', key: 'detail' }], rows));
};

// ---------- shell ----------
async function router() {
  const name = (location.hash.slice(1) || 'overview'); const v = views[name] ? name : 'overview';
  document.querySelectorAll('#nav a').forEach((a) => a.classList.toggle('on', a.dataset.v === v));
  main.replaceChildren();
  try { await views[v](); } catch (e) { main.append(h('p', { class: 'err' }, e.message)); }
}
async function boot() {
  const r = await fetch('/portal/api/auth/me'); if (!r.ok) return (location.href = '/portal/login');
  ME = await r.json(); CSRF = ME.csrf; if (ME.limited) return (location.href = '/portal/');
  const nav = document.getElementById('nav');
  for (const [k, label, min] of NAV) if (!min || can(min)) nav.append(h('a', { href: '#' + k, 'data-v': k }, label));
  nav.append(h('a', { href: '/portal/?setup=1' }, 'Account security'));
  document.getElementById('who').replaceChildren(ME.user.name, h('br'), `${ME.user.role} · `, h('a', { href: '#', onclick: async (e) => { e.preventDefault(); await api('/auth/logout', 'POST'); location.href = '/portal/login'; } }, 'Sign out'));
  window.addEventListener('hashchange', router); router();
  // Idle auto-logout mirrors the server's 30-minute idle limit.
  let t; const reset = () => { clearTimeout(t); t = setTimeout(() => (location.href = '/portal/login'), 29 * 60 * 1000); };
  ['click', 'keydown', 'mousemove'].forEach((ev) => addEventListener(ev, reset, { passive: true })); reset();
}
boot();
