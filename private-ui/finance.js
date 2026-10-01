/* Proprietary underwriting engine. Served ONLY to authenticated sessions (never from /public). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(); else root.Finance = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const DEFAULTS = {
    units: 100, avgRent: 1200, otherIncome: 60, vacancyPct: 7, purchasePrice: 10000000, closingPct: 2, capex: 500000,
    taxes: 140000, insurance: 70000, utilities: 90000, repairs: 100000, payroll: 130000, admin: 40000, mgmtPct: 4, reservesPerUnit: 300,
    ltvPct: 70, ratePct: 6.25, amortYears: 30, ioYears: 0, loanFeePct: 1,
    rentGrowthPct: 3, expGrowthPct: 3, holdYears: 5, exitCapPct: 6, saleCostPct: 2
  };
  const n = (v, d = 0) => (Number.isFinite(+v) ? +v : d);

  function monthlyPayment(principal, annualRatePct, years) {
    const r = annualRatePct / 1200, k = years * 12;
    if (!principal || !k) return 0;
    return r === 0 ? principal / k : (principal * r) / (1 - Math.pow(1 + r, -k));
  }
  // Loan balance after m months given IO period and amortisation.
  function schedule(loan, ratePct, amortYears, ioYears, months) {
    const r = ratePct / 1200, pmt = monthlyPayment(loan, ratePct, amortYears);
    let bal = loan; const yearly = [];
    let paid = 0;
    for (let m = 1; m <= months; m++) {
      const interest = bal * r;
      const pay = m <= ioYears * 12 ? interest : pmt;
      bal -= pay - interest; paid += pay;
      if (m % 12 === 0) { yearly.push(paid); paid = 0; }
    }
    return { balance: bal, yearlyDebtService: yearly };
  }
  function irr(flows) {
    let lo = -0.99, hi = 10;
    const npv = (r) => flows.reduce((s, f, i) => s + f / Math.pow(1 + r, i), 0);
    if (npv(lo) * npv(hi) > 0) return null;
    for (let i = 0; i < 200; i++) { const mid = (lo + hi) / 2; (npv(lo) * npv(mid) <= 0) ? (hi = mid) : (lo = mid); }
    return (lo + hi) / 2;
  }

  function analyze(input) {
    const i = Object.assign({}, DEFAULTS, Object.fromEntries(Object.entries(input || {}).map(([k, v]) => [k, n(v, DEFAULTS[k])])));
    const hold = Math.max(1, Math.min(30, Math.round(i.holdYears)));
    const loan = i.purchasePrice * i.ltvPct / 100;
    const loanFee = loan * i.loanFeePct / 100;
    const closing = i.purchasePrice * i.closingPct / 100;
    const equity = i.purchasePrice + closing + i.capex + loanFee - loan;
    const debt = schedule(loan, i.ratePct, i.amortYears, i.ioYears, hold * 12);
    const years = [];
    for (let y = 1; y <= hold + 1; y++) {
      const rg = Math.pow(1 + i.rentGrowthPct / 100, y - 1), eg = Math.pow(1 + i.expGrowthPct / 100, y - 1);
      const gpr = i.units * i.avgRent * 12 * rg;
      const other = i.units * i.otherIncome * 12 * rg;
      const vacancy = (gpr + other) * i.vacancyPct / 100;
      const egi = gpr + other - vacancy;
      const fixed = (i.taxes + i.insurance + i.utilities + i.repairs + i.payroll + i.admin + i.reservesPerUnit * i.units) * eg;
      const opex = fixed + egi * i.mgmtPct / 100;
      const noi = egi - opex;
      const ds = y <= hold ? debt.yearlyDebtService[y - 1] : 0;
      years.push({ year: y, gpr, other, vacancy, egi, opex, noi, debtService: ds, cashFlow: noi - ds, dscr: ds ? noi / ds : null });
    }
    const hy = years.slice(0, hold), y1 = years[0];
    const exitValue = years[hold].noi / (i.exitCapPct / 100);
    const saleCosts = exitValue * i.saleCostPct / 100;
    const netSale = exitValue - saleCosts - debt.balance;
    const flows = [-equity, ...hy.map((y) => y.cashFlow)];
    flows[hold] += netSale;
    const totalDist = hy.reduce((s, y) => s + y.cashFlow, 0) + netSale;
    return {
      inputs: i, loan, equity, closing, loanFee, years: hy,
      metrics: {
        noi: y1.noi, capRate: y1.noi / i.purchasePrice, pricePerUnit: i.purchasePrice / i.units,
        allInBasis: (i.purchasePrice + closing + i.capex) / i.units,
        dscr: y1.dscr, debtYield: loan ? y1.noi / loan : null, cashOnCash: y1.cashFlow / equity,
        avgCashOnCash: hy.reduce((s, y) => s + y.cashFlow, 0) / hold / equity,
        exitValue, netSale, irr: irr(flows), equityMultiple: totalDist / equity,
        breakevenOccupancy: (y1.opex + y1.debtService) / (y1.gpr + y1.other),
        expenseRatio: y1.opex / y1.egi, loanBalanceAtExit: debt.balance
      },
      flows
    };
  }

  // Highest purchase price that still meets a target (bisection; other inputs held constant).
  function maxPrice(input, metric, target) {
    const get = { cap: (m) => m.capRate, dscr: (m) => m.dscr, coc: (m) => m.cashOnCash, irr: (m) => m.irr }[metric];
    const ok = (p) => { const v = get(analyze({ ...input, purchasePrice: p }).metrics); return v !== null && v >= target; };
    let lo = 1, hi = (input.purchasePrice || DEFAULTS.purchasePrice) * 5;
    if (!ok(lo)) return null;
    for (let k = 0; k < 80; k++) { const mid = (lo + hi) / 2; ok(mid) ? (lo = mid) : (hi = mid); }
    return lo;
  }

  // Sum year-by-year cash flows and equity across several deals (portfolio view).
  function portfolio(results) {
    const H = Math.max(0, ...results.map((r) => r.years.length));
    const rows = [];
    for (let y = 0; y < H; y++) rows.push({
      year: y + 1,
      noi: results.reduce((s, r) => s + (r.years[y]?.noi || 0), 0),
      debtService: results.reduce((s, r) => s + (r.years[y]?.debtService || 0), 0),
      cashFlow: results.reduce((s, r) => s + (r.years[y]?.cashFlow || 0), 0)
    });
    const flows = Array.from({ length: H + 1 }, (_, t) => results.reduce((s, r) => s + (r.flows[t] || 0), 0));
    const equity = results.reduce((s, r) => s + r.equity, 0);
    return { rows, equity, loan: results.reduce((s, r) => s + r.loan, 0), price: results.reduce((s, r) => s + r.inputs.purchasePrice, 0), irr: irr(flows), flows,
      multiple: equity ? flows.slice(1).reduce((a, b) => a + b, 0) / equity : null };
  }
  // Deal scorecard: transparent rules (no outside services). Percent criteria are in percent units.
  const DEFAULT_CRITERIA = { minCap: 6.5, minDscr: 1.25, minCoc: 6, minIrr: 14 };
  function evaluate(m, criteria) {
    const c = Object.assign({}, DEFAULT_CRITERIA, criteria || {});
    const checks = [
      { name: 'Cap rate', value: m.capRate * 100, target: c.minCap, unit: '%', ok: m.capRate * 100 >= c.minCap },
      { name: 'Debt coverage (DSCR)', value: m.dscr, target: c.minDscr, unit: 'x', ok: m.dscr !== null && m.dscr >= c.minDscr },
      { name: 'Cash-on-cash (Yr 1)', value: m.cashOnCash * 100, target: c.minCoc, unit: '%', ok: m.cashOnCash * 100 >= c.minCoc },
      { name: 'IRR', value: m.irr === null ? null : m.irr * 100, target: c.minIrr, unit: '%', ok: m.irr !== null && m.irr * 100 >= c.minIrr }
    ];
    const passed = checks.filter((x) => x.ok).length;
    let verdict = 'Good deal';
    if (passed < checks.length) verdict = (m.dscr !== null && m.dscr < 1) || passed <= 1 ? 'Not a good deal' : 'Borderline';
    return { verdict, passed, total: checks.length, checks };
  }
  // What would it take to pass? Highest price meeting each target, the price meeting ALL, and the rent needed at the current price.
  function whatWouldWork(input, criteria) {
    const c = Object.assign({}, DEFAULT_CRITERIA, criteria || {});
    const per = {
      cap: maxPrice(input, 'cap', c.minCap / 100), dscr: maxPrice(input, 'dscr', c.minDscr),
      coc: maxPrice(input, 'coc', c.minCoc / 100), irr: maxPrice(input, 'irr', c.minIrr / 100)
    };
    const vals = Object.values(per);
    const allPrice = vals.every((v) => v !== null) ? Math.min(...vals) : null;
    const passes = (rent) => evaluate(analyze({ ...input, avgRent: rent }).metrics, c).passed === 4;
    let rentForAll = null;
    if (passes(20000)) { let lo = 50, hi = 20000; for (let i = 0; i < 60; i++) { const mid = (lo + hi) / 2; passes(mid) ? (hi = mid) : (lo = mid); } rentForAll = Math.ceil(hi); }
    const price = Number(input.purchasePrice) || DEFAULTS.purchasePrice;
    return { per, allPrice, discount: allPrice === null ? null : 1 - allPrice / price, rentForAll, currentRent: Number(input.avgRent) || DEFAULTS.avgRent, alreadyPasses: evaluate(analyze(input).metrics, c).passed === 4 };
  }
  // Ranks deals against the owner's targets: verdict first, then targets met, then IRR, DSCR, cap rate.
  function rankDeals(items, criteria) {
    const rank = { 'Good deal': 2, Borderline: 1, 'Not a good deal': 0 };
    const rows = items.map((it, index) => {
      const ev = evaluate(it.metrics, criteria), m = it.metrics;
      return { index, name: it.name, equity: it.equity, m, ev, key: [rank[ev.verdict], ev.passed, m.irr === null ? -9 : m.irr, m.dscr === null ? -9 : m.dscr, m.capRate] };
    });
    const cmp = (a, b) => { for (let i = 0; i < a.key.length; i++) if (a.key[i] !== b.key[i]) return b.key[i] - a.key[i]; return 0; };
    const ranked = rows.slice().sort(cmp);
    const w = ranked[0], r = ranked[1];
    const closeCall = !!r && w.key[0] === r.key[0] && w.key[1] === r.key[1] && Math.abs((w.m.irr ?? -9) - (r.m.irr ?? -9)) < 0.01 && Math.abs((w.m.dscr ?? 0) - (r.m.dscr ?? 0)) < 0.1;
    const reasons = [];
    if (r) {
      if (w.ev.passed !== r.ev.passed) reasons.push(`meets ${w.ev.passed} of ${w.ev.total} of your targets (${r.name}: ${r.ev.passed})`);
      const d = (label, a, b, fmt, higher = true) => { if (a !== null && b !== null && (higher ? a > b : a < b)) reasons.push(`${label} ${fmt(a)} vs ${fmt(b)}`); };
      d('IRR', w.m.irr, r.m.irr, (v) => (v * 100).toFixed(1) + '%');
      d('cap rate', w.m.capRate, r.m.capRate, (v) => (v * 100).toFixed(2) + '%');
      d('debt coverage', w.m.dscr, r.m.dscr, (v) => v.toFixed(2) + 'x');
      d('cash needed', w.equity, r.equity, (v) => '$' + Math.round(v).toLocaleString(), false);
    }
    return { ranked, winner: w, closeCall, reasons: reasons.slice(0, 4) };
  }
  // Reads pasted listing-page text (no network). Returns recognised fields + estimated underwriting boxes.
  function parseListing(text, url) {
    const t = String(text || '').replace(/\r/g, '');
    const num = (m) => (m ? Number(String(m[1]).replace(/,/g, '')) : null);
    const out = { found: [], estimated: [] };
    const RE_CITY = "([A-Za-z][A-Za-z .'-]{1,40}),[ \\t]*([A-Z]{2})[ \\t]+(\\d{5})";
    const addr = t.match(new RegExp("^[ \\t]*(\\d{1,6}[ \\t]+[^\\n,]{3,60}),[ \\t]*" + RE_CITY, 'm'))            // "123 Main St, City, ST 12345" on one line
      || t.match(new RegExp("^[ \\t]*(\\d{1,6}[ \\t]+[^\\n,]{3,60})[ \\t]*\\n[ \\t]*" + RE_CITY, 'm'))           // street and "City, ST 12345" on two lines
      || t.match(new RegExp("(\\d{1,6}[ \\t]+[A-Za-z0-9 .'#-]{3,50}),[ \\t]*" + RE_CITY));                       // address in the middle of a line
    if (addr) {
      out.address = `${addr[1].trim()}, ${addr[2].trim()}, ${addr[3]} ${addr[4]}`; out.found.push('address');
      const before = t.slice(0, addr.index).split('\n').map((l) => l.trim()).filter(Boolean).reverse();
      const LABEL = /^(back to.*|multi-?family( home)?|apartments?|listing.*|price( cut)?|(asking|list|listing) price|beds?|baths?|sq\.? ?ft\.?|square feet|status|for sale|new|open house|duplex|triplex|fourplex|residential income|overview|description|about|home|property|details|photos?|save|share|tour|contact|request a tour|est\. ?payment.*)$/i;
      const prev = before.find((l) => !LABEL.test(l) && !/\$/.test(l) && /[A-Za-z]/.test(l) && l.length <= 60);
      out.name = prev && prev.toLowerCase() !== addr[1].trim().toLowerCase() && !/^\d/.test(prev) ? prev : addr[1].trim();
    }
    const price = num(t.match(/(?:Listing|Asking|List)\s*Price\s*:?\s*\$\s*([\d,]{4,})/i)) || num(t.match(/\$\s*([\d,]{6,})/));
    if (price) { out.askingPrice = price; out.found.push('price'); }
    const units = num(t.match(/(?:Number|No\.?|#|Total)\s*(?:of\s*)?Units\s*:?\s*(\d{1,4})\b/i)) || num(t.match(/\bUnits\s*:\s*(\d{1,4})\b/i)) || num(t.match(/\b(\d{1,4})[-\s]units?\b/i))
      || (/\bduplex\b/i.test(t) ? 2 : /\btriplex\b/i.test(t) ? 3 : /\b(?:fourplex|quadplex|4-plex)\b/i.test(t) ? 4 : null);
    if (units) { out.units = units; out.found.push('units'); }
    const cap = num(t.match(/Cap Rate\s*:?\s*([\d.]+)\s*%/i)); if (cap) { out.capRate = cap; out.found.push('cap rate'); }
    const grm = num(t.match(/\bGRM\s*:?\s*([\d.]+)/i)); if (grm) { out.grm = grm; out.found.push('GRM'); }
    const occ = num(t.match(/Occupancy\s*:?\s*([\d.]+)\s*%/i)); if (occ) { out.occupancy = occ; out.found.push('occupancy'); }
    const sf = num(t.match(/Gross SF\s*:?\s*([\d,]+)/i)) || num(t.match(/([\d,]{3,6})\s*(?:sq\.?\s*ft\.?|sqft|square feet)/i)); if (sf) out.grossSf = sf;
    const yr = num(t.match(/(?:Year Built|Built in)\s*:?\s*(\d{4})/i)); if (yr) out.yearBuilt = yr;
    const tax = num(t.match(/(?:Annual\s*Tax(?:\s*Amount)?|Property\s*Tax(?:es)?|Taxes)\s*(?:\(annual\))?\s*:?\s*\$\s*([\d,]+)/i));
    const noi = num(t.match(/(?:Net Operating Income|NOI)\s*:?\s*\$\s*([\d,]+)/i));
    const grossInc = num(t.match(/(?:Gross (?:Scheduled |Annual )?(?:Rent|Income)|Total (?:Gross )?(?:Annual )?(?:Rent|Income))\s*:?\s*\$\s*([\d,]+)/i));
    const monthlyInc = num(t.match(/(?:Gross Monthly (?:Rent|Income)|Total Monthly (?:Rent|Income))\s*:?\s*\$\s*([\d,]+)/i));
    if (/marcus\s*&\s*millichap/i.test(t)) out.source = 'Marcus & Millichap';
    else if (/loopnet/i.test(t)) out.source = 'LoopNet'; else if (/crexi/i.test(t)) out.source = 'Crexi';
    else if (url) { try { out.source = new URL(url).hostname.replace(/^www\./, ''); } catch (e) { /* ignore */ } }
    if (/^https?:\/\//i.test(url || '')) out.listingUrl = url.trim();

    // Estimates: derive rent from GRM and spread costs so the model's NOI matches the listing's cap rate.
    let capUse = cap; if (!capUse && noi && price) { capUse = Math.round(noi / price * 10000) / 100; out.capRate = capUse; out.found.push('NOI'); }
    const uw = {};
    if (price && units) {
      uw.units = units; uw.purchasePrice = price; uw.otherIncome = 0; uw.mgmtPct = 5; uw.reservesPerUnit = 300; uw.payroll = 0;
      uw.vacancyPct = occ ? Math.max(0, Math.round((100 - occ) * 10) / 10) : 5; if (uw.vacancyPct < 3) uw.vacancyPct = 3;
      uw.capex = Math.round(price * 0.03 / 1000) * 1000;
      if (capUse) uw.exitCapPct = Math.round((capUse + 0.5) * 100) / 100;
      const gross = grm ? price / grm : grossInc || (monthlyInc ? monthlyInc * 12 : null);
      if (gross) {
        uw.avgRent = Math.round(gross / 12 / units);
        const egi = gross * (1 - uw.vacancyPct / 100);
        if (capUse) {
          const rest = egi - price * capUse / 100 - egi * 0.05 - 300 * units;
          if (rest > 0) Object.assign(uw, { taxes: Math.round(rest * 0.40), insurance: Math.round(rest * 0.15), utilities: Math.round(rest * 0.20), repairs: Math.round(rest * 0.18), admin: Math.round(rest * 0.07) });
          out.estimated.push('expenses (spread to match the listing cap rate)');
        }
        out.estimated.push(grm ? 'average rent (price ÷ GRM)' : 'average rent (listed gross income ÷ units)');
      }
      if (tax && tax >= 300 && tax < price * 0.06) { uw.taxes = tax; out.found.push('property taxes'); }
      out.estimated.push('capex (3% of price)', 'exit cap (listing cap + 0.5)');
    }
    out.uw = uw;
    return out;
  }
  return { DEFAULTS, DEFAULT_CRITERIA, analyze, maxPrice, portfolio, irr, monthlyPayment, evaluate, rankDeals, whatWouldWork, parseListing };
});
