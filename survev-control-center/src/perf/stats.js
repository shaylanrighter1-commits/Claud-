// Pure statistics for frame-time analysis and benchmark comparison. No DOM access (unit-tested in node).

const COMMON_RATES = [24, 30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 180, 240, 360];

/** Snap a measured refresh rate to a common display rate when within 6%. */
export function snapRefresh(hz) {
  if (!Number.isFinite(hz) || hz <= 0) return null;
  let best = null;
  for (const r of COMMON_RATES) if (Math.abs(hz - r) / r <= 0.06 && (best == null || Math.abs(hz - r) < Math.abs(hz - best))) best = r;
  return best || Math.round(hz);
}

function percentile(sorted, p) {
  if (!sorted.length) return NaN;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * p)));
  return sorted[i];
}

export function stutterThreshold(medianMs) {
  return Math.max(2.5 * medianMs, medianMs + 12);
}

/**
 * Summarize an array of frame times (ms).
 * 1% low = FPS computed from the mean of the slowest 1% of frames (at least one frame).
 */
export function summarize(ft, refreshHz = null) {
  const n = ft.length;
  if (n < 2) return null;
  let total = 0;
  for (let i = 0; i < n; i++) total += ft[i];
  const sorted = Float64Array.from(ft).sort();
  const p50 = percentile(sorted, 0.5);
  const worstN = Math.max(1, Math.round(n * 0.01));
  let worst = 0;
  for (let i = n - worstN; i < n; i++) worst += sorted[i];
  const mean = total / n;
  let varSum = 0;
  let jit = 0;
  for (let i = 0; i < n; i++) {
    varSum += (ft[i] - mean) ** 2;
    if (i) jit += Math.abs(ft[i] - ft[i - 1]);
  }
  const thresh = stutterThreshold(p50);
  let stutters = 0;
  for (let i = 0; i < n; i++) if (ft[i] > thresh) stutters++;
  const budget = refreshHz ? 1000 / refreshHz : p50;
  let onTime = 0;
  for (let i = 0; i < n; i++) if (ft[i] <= budget * 1.5) onTime++;
  return {
    frames: n,
    durationMs: total,
    avgFps: (n * 1000) / total,
    low1Fps: 1000 / (worst / worstN),
    p50,
    p95: percentile(sorted, 0.95),
    p99: percentile(sorted, 0.99),
    maxFt: sorted[n - 1],
    stdev: Math.sqrt(varSum / (n - 1)),
    jitter: jit / (n - 1),
    stutters,
    stutterThresh: thresh,
    stuttersPerMin: (stutters / total) * 60000,
    onTimePct: onTime / n,
  };
}

/** Qualitative rendering-performance estimate from a summary + target. */
export function rateRendering(s, targetFps) {
  if (!s) return { label: 'Measuring', score: null };
  const avgRatio = s.avgFps / targetFps;
  const lowRatio = s.low1Fps / targetFps;
  const score = Math.max(0, Math.min(100, Math.round(55 * Math.min(1, avgRatio) + 30 * Math.min(1, lowRatio) + 15 * s.onTimePct - Math.min(15, s.stuttersPerMin))));
  const label = score >= 88 ? 'Excellent' : score >= 72 ? 'Good' : score >= 50 ? 'Fair' : 'Poor';
  return { label, score };
}

// ---------------------------------------------------------------- Welch's t-test
function lgamma(x) {
  const c = [76.18009172947146, -86.50532032941677, 24.01409824083091, -1.231739572450155, 0.1208650973866179e-2, -0.5395239384953e-5];
  let y = x;
  let tmp = x + 5.5;
  tmp -= (x + 0.5) * Math.log(tmp);
  let ser = 1.000000000190015;
  for (let j = 0; j < 6; j++) ser += c[j] / ++y;
  return -tmp + Math.log((2.5066282746310005 * ser) / x);
}

function betacf(a, b, x) {
  const MAXIT = 200;
  const EPS = 3e-12;
  const FPMIN = 1e-300;
  const qab = a + b;
  const qap = a + 1;
  const qam = a - 1;
  let c = 1;
  let d = 1 - (qab * x) / qap;
  if (Math.abs(d) < FPMIN) d = FPMIN;
  d = 1 / d;
  let h = d;
  for (let m = 1; m <= MAXIT; m++) {
    const m2 = 2 * m;
    let aa = (m * (b - m) * x) / ((qam + m2) * (a + m2));
    d = 1 + aa * d;
    if (Math.abs(d) < FPMIN) d = FPMIN;
    c = 1 + aa / c;
    if (Math.abs(c) < FPMIN) c = FPMIN;
    d = 1 / d;
    h *= d * c;
    aa = (-(a + m) * (qab + m) * x) / ((a + m2) * (qap + m2));
    d = 1 + aa * d;
    if (Math.abs(d) < FPMIN) d = FPMIN;
    c = 1 + aa / c;
    if (Math.abs(c) < FPMIN) c = FPMIN;
    d = 1 / d;
    const del = d * c;
    h *= del;
    if (Math.abs(del - 1) < EPS) break;
  }
  return h;
}

/** Regularized incomplete beta I_x(a,b). */
export function ibeta(x, a, b) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const bt = Math.exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * Math.log(x) + b * Math.log(1 - x));
  return x < (a + 1) / (a + b + 2) ? (bt * betacf(a, b, x)) / a : 1 - (bt * betacf(b, a, 1 - x)) / b;
}

/** Two-sided p-value for Student's t with df degrees of freedom. */
export function tTwoSidedP(t, df) {
  if (!Number.isFinite(t)) return 0;
  return ibeta(df / (df + t * t), df / 2, 0.5);
}

const meanOf = (a) => a.reduce((s, v) => s + v, 0) / a.length;
const varOf = (a, m) => a.reduce((s, v) => s + (v - m) ** 2, 0) / (a.length - 1);

/** Welch's unequal-variance t-test between two samples. */
export function welch(a, b) {
  if (a.length < 3 || b.length < 3) return { t: NaN, df: NaN, p: 1, ok: false };
  const ma = meanOf(a);
  const mb = meanOf(b);
  const va = varOf(a, ma) / a.length;
  const vb = varOf(b, mb) / b.length;
  const se = Math.sqrt(va + vb);
  if (se < 1e-9) return { t: ma === mb ? 0 : Infinity, df: a.length + b.length - 2, p: ma === mb ? 1 : 0, ok: true };
  const t = (mb - ma) / se;
  const df = (va + vb) ** 2 / (va ** 2 / (a.length - 1) + vb ** 2 / (b.length - 1));
  return { t, df, p: tTwoSidedP(Math.abs(t), df), ok: true };
}

/**
 * Compare two benchmark results. Claims a change only when Welch's test on per-second FPS is significant
 * (p < 0.05) AND the average moved by at least 3%.
 */
export function compareRuns(before, after) {
  if (!before || !after) return null;
  const pct = (b, a) => (b ? ((a - b) / b) * 100 : 0);
  const test = welch(before.perSecond || [], after.perSecond || []);
  const avgPct = pct(before.avgFps, after.avgFps);
  const significant = test.ok && test.p < 0.05 && Math.abs(avgPct) >= 3;
  let verdict = 'no-change';
  if (!test.ok) verdict = 'insufficient';
  else if (significant) verdict = avgPct > 0 ? 'improved' : 'worse';
  return {
    verdict,
    p: test.p,
    rows: [
      { key: 'avgFps', label: 'Average FPS', before: before.avgFps, after: after.avgFps, pct: avgPct, higherBetter: true },
      { key: 'low1Fps', label: '1% low FPS', before: before.low1Fps, after: after.low1Fps, pct: pct(before.low1Fps, after.low1Fps), higherBetter: true },
      { key: 'stdev', label: 'Frame-time σ (ms)', before: before.stdev, after: after.stdev, pct: pct(before.stdev, after.stdev), higherBetter: false },
      { key: 'jitter', label: 'Frame-to-frame jitter (ms)', before: before.jitter, after: after.jitter, pct: pct(before.jitter, after.jitter), higherBetter: false },
      { key: 'stuttersPerMin', label: 'Stutters / min', before: before.stuttersPerMin, after: after.stuttersPerMin, pct: pct(before.stuttersPerMin, after.stuttersPerMin), higherBetter: false },
    ],
  };
}
