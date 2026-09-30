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
  return { DEFAULTS, DEFAULT_CRITERIA, analyze, maxPrice, portfolio, irr, monthlyPayment, evaluate };
});
