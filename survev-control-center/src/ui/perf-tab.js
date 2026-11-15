// PERFORMANCE BOOST tab: live FPS + frame-time graph, presets, game-settings integration, auto optimization,
// before/after benchmark, network diagnostics and environment checks.
// Live widgets only update while the tab is actually visible (no work when hidden or minimized).

import { h } from '../core/util.js';
import { buttonControl } from './controls.js';
import { PRESETS, PRESET_ORDER } from '../perf/presets.js';
import { GAME_SETTINGS, APPLIES_TEXT } from '../perf/game-settings.js';
import { describeChange } from '../perf/perf-controller.js';

const T = (path, label, hint, x = {}) => ({ type: 'toggle', path, label, hint, ...x });
const S = (path, label, min, max, step, unit, x = {}) => ({ type: 'slider', path, label, min, max, step, unit, ...x });
const G = (path, label, options, x = {}) => ({ type: 'seg', path, label, options, ...x });
const X = (render) => ({ type: 'custom', render });
const N = (text) => ({ type: 'note', text });

const f0 = (v) => (v == null || !Number.isFinite(v) ? '—' : v.toFixed(0));
const f1 = (v) => (v == null || !Number.isFinite(v) ? '—' : v.toFixed(1));
const badge = (text, tone = '') => h('span', { class: `pf-badge ${tone}`, text });
const ago = (t) => new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });

function needPerf(ctx, build) {
  if (!ctx.perf) return h('p', { class: 'scc-note', text: 'Live performance data is measured on the page you are playing. Open the game page (localhost) or the Demo Arena and use the in-page dashboard.' });
  return build(ctx.perf);
}

/** Subscribe to the 4 Hz perf tick, but only do work while `el` is visible. */
function onTick(ctx, el, fn) {
  const run = () => ctx.isShown(el) && fn();
  ctx.disposers.push(ctx.perf.bus.on('tick', run));
  return run;
}

function cell(label) {
  const v = h('div', { class: 'scc-stat-v', text: '—' });
  const s = h('div', { class: 'scc-stat-s', text: label });
  return { v, s, node: h('div', { class: 'scc-stat' }, v, s), label };
}

// ------------------------------------------------------------------ hero: big FPS + frame-time graph
function drawGraph(cv, ft, L) {
  const dpr = Math.min(devicePixelRatio || 1, 2);
  const w = Math.max(80, cv.clientWidth);
  const hh = 96;
  if (cv.width !== Math.round(w * dpr)) {
    cv.width = Math.round(w * dpr);
    cv.height = Math.round(hh * dpr);
  }
  const c = cv.getContext('2d');
  c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.clearRect(0, 0, w, hh);
  const accent = getComputedStyle(cv).getPropertyValue('--accent').trim() || '#2f7bff';
  const budget = 1000 / L.target.fps;
  const top = Math.max(40, Math.min(120, Math.ceil(((L.s ? L.s.p99 : 33) * 1.25) / 10) * 10));
  const y = (ms) => hh - 4 - (Math.min(ms, top) / top) * (hh - 10);
  // guides
  c.lineWidth = 1;
  c.setLineDash([3, 4]);
  c.strokeStyle = 'rgba(255,255,255,0.12)';
  for (const g of [16.7, 33.3]) {
    if (g > top) continue;
    c.beginPath();
    c.moveTo(0, y(g));
    c.lineTo(w, y(g));
    c.stroke();
  }
  c.strokeStyle = accent;
  c.globalAlpha = 0.6;
  c.beginPath();
  c.moveTo(0, y(budget));
  c.lineTo(w, y(budget));
  c.stroke();
  c.globalAlpha = 1;
  c.setLineDash([]);
  if (ft.length < 2) return top;
  let total = 0;
  for (let i = 0; i < ft.length; i++) total += ft[i];
  const sx = w / total;
  // area + line
  const thresh = L.s ? L.s.stutterThresh : 1e9;
  c.beginPath();
  let x = 0;
  c.moveTo(0, hh);
  for (let i = 0; i < ft.length; i++) {
    x += ft[i] * sx;
    c.lineTo(x, y(ft[i]));
  }
  c.lineTo(w, hh);
  c.closePath();
  const g = c.createLinearGradient(0, 0, 0, hh);
  g.addColorStop(0, accent + '55');
  g.addColorStop(1, accent + '05');
  c.fillStyle = g;
  c.fill();
  c.beginPath();
  x = 0;
  for (let i = 0; i < ft.length; i++) {
    x += ft[i] * sx;
    if (i === 0) c.moveTo(x, y(ft[i]));
    else c.lineTo(x, y(ft[i]));
  }
  c.strokeStyle = accent;
  c.lineWidth = 1.4;
  c.lineJoin = 'round';
  c.stroke();
  // stutters
  x = 0;
  c.fillStyle = '#ff4d5e';
  for (let i = 0; i < ft.length; i++) {
    x += ft[i] * sx;
    if (ft[i] > thresh) c.fillRect(x - 1, y(ft[i]) - 1, 2.5, hh - y(ft[i]));
  }
  return top;
}

function sourceBanner(ctx) {
  if (!ctx.perf) return h('span');
  const m = ctx.perf.mode;
  const text =
    m === 'live' ? 'Measuring this survev.io tab: real frames delivered by your browser while the game runs.'
    : m === 'demo' ? 'Demo Arena: these numbers measure the simulator page, NOT survev.io. Open survev.io for real game performance.'
    : 'Measuring this local development page.';
  return h('div', { class: 'pf-source ' + m }, text);
}

function hero(ctx) {
  return needPerf(ctx, (perf) => {
    const fps = h('span', { class: 'pf-fps', text: '—' });
    const pill = h('span', { class: 'pf-pill' });
    const sub1 = h('div', { class: 'pf-sub' });
    const sub2 = h('div', { class: 'pf-sub' });
    const chips = ['Average', '1% low', 'Stutters/min', 'Display'].map((l) => {
      const b = h('b', { text: '—' });
      return { b, node: h('div', { class: 'pf-chip' }, b, h('span', { text: l })) };
    });
    const cv = h('canvas', { class: 'pf-graph', height: 96 });
    const legend = h('div', { class: 'pf-legend' });
    const root = h('div', {},
      h('div', { class: 'pf-hero' }, h('div', { class: 'pf-big' }, fps, h('span', { class: 'pf-unit', text: 'FPS' })), h('div', { class: 'pf-side' }, pill, sub1, sub2)),
      h('div', { class: 'pf-chips' }, chips.map((c) => c.node)),
      cv, legend);
    let lastDraw = 0;
    let L = null;
    const update = () => {
      L = perf.live();
      fps.textContent = L.cur ? L.cur.toFixed(0) : '—';
      fps.className = 'pf-fps ' + (L.status.tone || '');
      pill.className = `pf-pill ${L.status.tone}`;
      pill.textContent = L.status.label;
      sub1.textContent = L.s ? `Frame time ${L.s.p50.toFixed(1)} ms median · ${L.s.p99.toFixed(1)} ms p99` : 'Waiting for frames…';
      sub2.textContent = `Target ${L.target.fps} FPS${L.target.capped ? ` (capped to ~${L.target.display} Hz display)` : ''}`;
      chips[0].b.textContent = L.s ? f1(L.s.avgFps) : '—';
      chips[1].b.textContent = L.s ? f1(L.s.low1Fps) : '—';
      chips[2].b.textContent = L.s ? f1(L.s.stuttersPerMin) : '—';
      chips[3].b.textContent = L.refresh ? `~${L.refresh} Hz` : '—';
      const top = drawGraph(cv, L.ft, L);
      legend.textContent = `Frame time, last ${L.win} s · scale 0–${top} ms · dashed = ${(1000 / L.target.fps).toFixed(1)} ms budget · red = stutter`;
    };
    onTick(ctx, root, update);
    // smoother graph: redraw from the frame stream at ≤ 12 Hz while visible
    ctx.disposers.push(
      perf.monitor.onFrame((d, ts) => {
        if (ts - lastDraw < 83 || !L || !ctx.isShown(root)) return;
        lastDraw = ts;
        drawGraph(cv, perf.monitor.window(perf.cfg.window), L);
      })
    );
    return root;
  });
}

// ------------------------------------------------------------------ analytics grid
function analytics(ctx) {
  return needPerf(ctx, (perf) => {
    const cells = ['Avg FPS', '1% low', 'p99 frame', 'Frame σ', 'Jitter', 'Stutters', 'Long frames', 'On-time', 'Render est.', 'Overlay cost', 'Resolution', 'DPR'].map(cell);
    const drops = h('div', { class: 'pf-drops' });
    const root = h('div', {}, h('div', { class: 'scc-stats' }, cells.map((c) => c.node)), drops);
    const set = (i, v, s) => {
      cells[i].v.textContent = v;
      cells[i].s.textContent = s || cells[i].label;
    };
    onTick(ctx, root, () => {
      const L = perf.live();
      const s = L.s;
      set(0, s ? f1(s.avgFps) : '—', `avg · ${L.win} s`);
      set(1, s ? f1(s.low1Fps) : '—', '1% low fps');
      set(2, s ? `${f1(s.p99)}ms` : '—', 'p99 frame');
      set(3, s ? `${f1(s.stdev)}ms` : '—', 'frame σ');
      set(4, s ? `${f1(s.jitter)}ms` : '—', 'jitter');
      set(5, s ? String(s.stutters) : '—', `stutters · ${L.sessionStutters} total`);
      set(6, String(L.long.count), L.loaf ? `long frames${L.long.extension ? ` · ${L.long.extension} ext` : ''}` : 'long tasks');
      set(7, s ? `${Math.round(s.onTimePct * 100)}%` : '—', 'on-time frames');
      set(8, L.rating.label, L.rating.score != null ? `est. score ${L.rating.score}` : 'render est.');
      set(9, L.overlayCost != null ? `${L.overlayCost.toFixed(2)}ms` : '—', 'overlay / frame');
      set(10, `${L.res.backingW}×${L.res.backingH}`, L.res.source === '#cvs' ? 'game canvas px' : 'viewport px');
      set(11, `${(L.res.dpr || 1).toFixed(2)}×`, 'device px ratio');
      drops.textContent = '';
      if (L.drops.length) {
        drops.append(h('div', { class: 'scc-hint', text: 'Recent FPS drops (1 s below 60% of the 10 s average):' }));
        for (const d of L.drops.slice().reverse()) drops.append(h('div', { class: 'pf-drop' }, h('span', { text: ago(d.at) }), h('b', { text: `${f0(d.from)} → ${f0(d.to)} FPS` })));
      }
    });
    return root;
  });
}

// ------------------------------------------------------------------ presets
function presetCards(ctx) {
  const wrap = h('div', { class: 'pf-presets' });
  const result = h('div', { class: 'pf-result scc-hidden' });
  const perf = ctx.perf;

  const render = () => {
    wrap.textContent = '';
    const read = perf ? perf.settings.read() : null;
    const active = ctx.state.get('cfg.perf.preset');
    for (const id of PRESET_ORDER) {
      const p = PRESETS[id];
      const items = h('ul', { class: 'pf-items' });
      for (const [sid, v] of Object.entries(p.game)) {
        const meta = GAME_SETTINGS.find((s) => s.id === sid);
        const r = read && read[sid];
        let b;
        if (!read) b = badge('GAME SETTING', 'info');
        else if (!r.present) b = badge('NOT ON THIS PAGE', 'muted');
        else if (r.checked === v) b = badge('ALREADY SET', 'muted');
        else if (meta.applies === 'reload') b = badge('RELOADS PAGE', 'warn');
        else b = badge('NEXT MATCH', 'info');
        items.append(h('li', {}, h('span', { text: `${meta.label}: ${v ? 'on' : 'off'}` }), b));
      }
      const ov = p.overlay;
      items.append(h('li', {}, h('span', { text: ov.liteUi ? 'Lightweight dashboard' : 'Full dashboard effects' }), badge('VERIFIED', 'ok')));
      if (!perf || perf.mode !== 'live') {
        items.append(h('li', {}, h('span', { text: ov.glow === 0 && !ov.cone ? 'Dev overlay effects: minimal' : ov.rays ? 'Dev overlay effects: full' : 'Dev overlay effects: reduced' }), badge('VERIFIED', 'ok')));
      }
      const btn = perf
        ? buttonControl({
            text: active === id ? 'Re-apply' : 'Apply',
            icon: 'bolt',
            variant: active === id ? 'ghost' : 'primary',
            onClick: () => showResult(perf.applyPreset(id)),
          })
        : null;
      wrap.append(
        h('div', { class: 'pf-preset' + (active === id ? ' on' : '') },
          h('div', { class: 'pf-preset-h' }, h('b', { text: p.label }), active === id ? badge('ACTIVE', 'accent') : null),
          h('p', { text: p.blurb }),
          items,
          btn)
      );
    }
  };

  const showResult = (res) => {
    result.textContent = '';
    result.classList.remove('scc-hidden');
    const changed = res.changes.filter((c) => c.status !== 'missing');
    const title = res.kind === 'restore' ? 'Restored original settings' : `${PRESETS[res.preset].label} applied`;
    result.append(h('b', { text: title }));
    if (!changed.length && !res.pending.length) result.append(h('div', { class: 'scc-hint', text: 'Nothing needed to change — everything already matched.' }));
    for (const c of changed) result.append(h('div', { class: 'pf-change', text: describeChange(c) }));
    const missing = res.changes.filter((c) => c.status === 'missing');
    if (missing.length) result.append(h('div', { class: 'scc-hint', text: `Not available on this page: ${missing.map((m) => m.label).join(', ')}.` }));
    if (res.pending.length) {
      result.append(h('div', { class: 'pf-warn', text: 'High-resolution textures can only change when the game reloads the page (that is how the game itself applies it). Do this between matches — reloading leaves a match in progress.' }));
      result.append(buttonControl({ text: 'Apply & reload now', icon: 'refresh', variant: 'danger', onClick: () => perf.applyPending() }));
    }
  };

  if (perf) {
    ctx.disposers.push(perf.bus.on('settings', render));
  }
  ctx.watch('cfg.perf.preset', render);
  render();
  return h('div', {}, perf ? null : h('p', { class: 'scc-note', text: 'Presets are applied on the game page (in-page dashboard). Shown here for reference.' }), wrap, result, perf ? h('div', {}, restoreRow(ctx, showResult)) : null);
}

function restoreRow(ctx, showResult) {
  const perf = ctx.perf;
  const btn = buttonControl({
    text: 'Restore original settings', icon: 'refresh', variant: 'ghost',
    onClick: () => {
      if (!ctx.state.get('loc.perf.original')) return ctx.toast('Nothing to restore — no preset has changed anything yet');
      const r = perf.restoreOriginal();
      showResult({ kind: 'restore', changes: [], pending: r.pending });
      ctx.toast(`Restored ${r.restored} setting${r.restored === 1 ? '' : 's'}`);
    },
  });
  return btn;
}

// ------------------------------------------------------------------ game settings
function gameSettings(ctx) {
  return needPerf(ctx, (perf) => {
    const head = h('div', {});
    const list = h('div', { class: 'pf-gs' });
    const tier = h('div', { class: 'scc-hint' });
    const armed = {};
    const render = () => {
      const read = perf.settings.read();
      const tests = ctx.state.get('loc.perf.settingTests') || {};
      const any = Object.values(read).some((r) => r.present);
      head.textContent = '';
      head.append(
        h('div', { class: 'pf-detect ' + (any ? 'ok' : '') },
          h('span', { class: 'scc-dot ' + (any ? 'green' : 'muted') }),
          h('span', { text: any ? 'Game settings controls detected on this page' : 'No game settings controls on this page' }))
      );
      if (!any) head.append(h('div', { class: 'scc-hint', text: 'Looking for #highResTex, #interpolation, #localRotation, #screenShake. Presets only adjust Control Center effects here.' }));
      list.textContent = '';
      for (const meta of GAME_SETTINGS) {
        const r = read[meta.id];
        const t = tests[meta.id];
        let measured;
        if (t) {
          const txt = t.verdict === 'improved' ? `Measured on this device: +${t.pct.toFixed(0)}% avg FPS with it ${t.to ? 'on' : 'off'}` : t.verdict === 'worse' ? `Measured: ${t.pct.toFixed(0)}% avg FPS with it ${t.to ? 'on' : 'off'}` : `Measured: no significant FPS change`;
          measured = h('div', { class: 'pf-measured ' + (t.verdict === 'improved' ? 'ok' : t.verdict === 'worse' ? 'bad' : '') }, txt, t.combined ? ' (changed together with other settings)' : '', ` · p=${t.p.toFixed(3)}`);
        } else measured = h('div', { class: 'pf-measured', text: meta.impact === 'gpu' ? 'Requires testing: run a before/after benchmark around this change.' : 'Not expected to change FPS (code analysis). Untested on this device.' });
        const state = r.present ? badge(r.checked ? 'ON' : 'OFF', r.checked ? 'accent' : 'muted') : badge('NOT DETECTED', 'muted');
        let btn = null;
        if (r.present) {
          btn = h('button', { class: 'scc-btn ghost pf-tgl', type: 'button', text: r.checked ? 'Turn off' : 'Turn on', disabled: r.disabled });
          btn.addEventListener('click', () => {
            if (meta.applies === 'reload' && !armed[meta.id]) {
              armed[meta.id] = setTimeout(() => {
                armed[meta.id] = 0;
                render();
              }, 4000);
              btn.textContent = 'Reloads page — confirm';
              btn.classList.add('danger');
              return;
            }
            clearTimeout(armed[meta.id]);
            armed[meta.id] = 0;
            const res = perf.setGameSetting(meta.id, !r.checked);
            if (res === 'changed' && meta.applies === 'next-match') ctx.toast(`${meta.label} ${!r.checked ? 'on' : 'off'} — takes effect next match`);
            render();
          });
        }
        list.append(
          h('div', { class: 'pf-gs-row' },
            h('div', { class: 'pf-gs-top' }, h('b', { text: meta.label }), state, badge(APPLIES_TEXT[meta.applies], meta.applies === 'reload' ? 'warn' : 'info')),
            h('div', { class: 'scc-hint', text: meta.note }),
            measured,
            btn)
        );
      }
    };
    perf.environment().then(({ tier: t }) => {
      tier.textContent = t.canUseHigh
        ? 'High-res textures can take effect on this device (screen, WebGL and GPU texture size qualify).'
        : `High-res textures have NO effect on this device — the game forces low-res because ${t.reasons.join('; ')}.`;
    });
    ctx.disposers.push(perf.bus.on('settings', render));
    ctx.watch('loc.perf.settingTests', render);
    render();
    return h('div', {}, head, tier, list, h('p', { class: 'scc-note', text: 'Changes go through the game’s own checkboxes (same as clicking them in its settings menu). Nothing else in the game is modified.' }));
  });
}

// ------------------------------------------------------------------ auto optimize
function autoStatus(ctx) {
  const capNote = h('div', { class: 'scc-hint' });
  const status = h('div', { class: 'pf-auto' });
  const log = h('div', { class: 'pf-log' });
  const renderLog = () => {
    const entries = (ctx.state.get('loc.perf.autoLog') || []).slice().reverse();
    log.textContent = '';
    if (!entries.length) {
      log.append(h('div', { class: 'scc-hint', text: 'No automatic changes yet.' }));
      return;
    }
    for (const e of entries.slice(0, 6)) {
      log.append(
        h('div', { class: 'pf-log-e' },
          h('div', { class: 'pf-log-h' }, h('b', { text: `${(PRESETS[e.from] || { label: 'Custom' }).label} → ${PRESETS[e.to].label}` }), h('span', { text: ago(e.at) })),
          h('div', { class: 'pf-log-r', text: `Why: ${e.reason}` }),
          e.changes.length ? h('div', { class: 'pf-log-c', text: `Changed: ${e.changes.join(' · ')}` }) : h('div', { class: 'pf-log-c', text: 'Changed: nothing (already at this level)' }),
          e.recommended && e.recommended.length ? h('div', { class: 'pf-log-c warn', text: `Recommended: ${e.recommended.join(' · ')}` }) : null,
          h('div', { class: 'pf-log-x' }, `Before ${f0(e.before.avg)} FPS`, e.after ? ` · after ${f0(e.after.avg)} FPS` : '', ` — ${e.effect}`))
      );
    }
  };
  ctx.watch('loc.perf.autoLog', renderLog);
  renderLog();
  const root = h('div', {}, capNote, status, log);
  if (ctx.perf) {
    const perf = ctx.perf;
    const upd = () => {
      const t = perf.effectiveTarget();
      capNote.textContent = t.capped
        ? `Your display/browser delivers ~${t.display} frames per second, so the effective target is ${t.fps} FPS. No setting can exceed the refresh rate.`
        : t.display
          ? `Display delivers ~${t.display} Hz. Target ${t.fps} FPS.`
          : 'Measuring display refresh rate…';
      status.className = `pf-auto ${perf.auto.state}`;
      status.textContent = perf.auto.note;
    };
    onTick(ctx, root, upd);
    ctx.disposers.push(perf.bus.on('config', upd));
    upd();
    root.append(
      buttonControl({
        text: 'Restore original settings', icon: 'refresh', variant: 'ghost',
        onClick: () => {
          if (!ctx.state.get('loc.perf.original')) return ctx.toast('Nothing to restore yet');
          const r = perf.restoreOriginal();
          ctx.toast(r.pending.length ? 'Restored — high-res textures need a page reload (see Presets)' : `Restored ${r.restored} setting(s)`);
        },
      }),
      buttonControl({ text: 'Clear log', icon: 'trash', variant: 'ghost', onClick: () => ctx.state.set('loc.perf.autoLog', []) })
    );
  } else capNote.textContent = 'Auto optimization runs on the game page. Your choice here is saved and used there.';
  return root;
}

// ------------------------------------------------------------------ benchmark
function benchmark(ctx) {
  const table = h('div', { class: 'pf-bench' });
  const verdict = h('div', { class: 'pf-verdict' });
  const notes = h('div', { class: 'pf-notes' });
  const prog = h('div', { class: 'pf-progress scc-hidden' }, h('span'));
  const perf = ctx.perf;
  const run = (phase) => async () => {
    try {
      ctx.toast(`Measuring ${phase.toUpperCase()} — keep playing normally…`);
      await perf.runBenchmark(phase);
      ctx.toast(`${phase === 'before' ? 'Before' : 'After'} measurement saved`);
    } catch (e) {
      ctx.toast(e.message);
    }
    render();
  };
  const btns = perf
    ? [
        buttonControl({ text: 'Measure BEFORE', icon: 'gauge', variant: 'primary', onClick: run('before') }),
        buttonControl({ text: 'Measure AFTER', icon: 'gauge', variant: 'primary', onClick: run('after') }),
      ]
    : [];
  const render = () => {
    const b = ctx.state.get('loc.perf.bench') || {};
    table.textContent = '';
    verdict.textContent = '';
    notes.textContent = '';
    const head = h('div', { class: 'pf-brow head' }, h('span', { text: 'Metric' }), h('span', { text: 'Before' }), h('span', { text: 'After' }), h('span', { text: 'Change' }));
    table.append(head);
    const cmp = perf ? perf.comparison() : null;
    const rows = cmp
      ? cmp.rows
      : [
          { label: 'Average FPS', before: b.before?.avgFps, after: b.after?.avgFps },
          { label: '1% low FPS', before: b.before?.low1Fps, after: b.after?.low1Fps },
          { label: 'Frame-time σ (ms)', before: b.before?.stdev, after: b.after?.stdev },
          { label: 'Frame-to-frame jitter (ms)', before: b.before?.jitter, after: b.after?.jitter },
          { label: 'Stutters / min', before: b.before?.stuttersPerMin, after: b.after?.stuttersPerMin },
        ];
    for (const r of rows) {
      let chg = '—';
      let tone = '';
      if (cmp) {
        const good = r.higherBetter ? r.pct > 0 : r.pct < 0;
        chg = `${r.pct >= 0 ? '+' : ''}${r.pct.toFixed(0)}%`;
        tone = Math.abs(r.pct) < 3 ? '' : good ? 'ok' : 'bad';
      }
      table.append(h('div', { class: 'pf-brow' }, h('span', { text: r.label }), h('span', { text: f1(r.before) }), h('span', { text: f1(r.after) }), h('span', { class: tone, text: chg })));
    }
    const when = (r) => (r ? `${r.seconds}s at ${ago(r.at)} · ${PRESETS[r.context?.preset]?.label || 'custom'}` : 'not measured');
    notes.append(h('div', { class: 'scc-hint', text: `Before: ${when(b.before)} · After: ${when(b.after)}` }));
    if (cmp) {
      const text = {
        improved: `Improvement measured: average FPS ${cmp.rows[0].pct.toFixed(0)}% higher (p = ${cmp.p.toFixed(3)}).`,
        worse: `Performance got worse: average FPS ${cmp.rows[0].pct.toFixed(0)}% (p = ${cmp.p.toFixed(3)}).`,
        'no-change': `No significant difference (p = ${cmp.p.toFixed(2)}${Math.abs(cmp.rows[0].pct) < 3 ? ', change under 3%' : ''}). No improvement is claimed.`,
        insufficient: 'Not enough data to compare — use at least 10-second windows.',
      }[cmp.verdict];
      verdict.className = `pf-verdict ${cmp.verdict}`;
      verdict.textContent = text;
      if (cmp.diffs.length) notes.append(h('div', { class: 'pf-diff', text: `Changed between runs: ${cmp.diffs.join(' · ')}` }));
      for (const n of cmp.notes) notes.append(h('div', { class: 'scc-hint', text: n }));
    }
  };
  if (perf) {
    const tick = () => {
      const on = !!perf.bench.running;
      prog.classList.toggle('scc-hidden', !on);
      prog.firstChild.style.width = `${Math.round(perf.bench.progress * 100)}%`;
      for (const b of btns) b.disabled = on;
    };
    ctx.disposers.push(perf.bus.on('bench', tick));
    ctx.disposers.push(perf.bus.on('tick', () => perf.bench.running && tick()));
  }
  ctx.watch('loc.perf.bench', render);
  render();
  return h('div', {},
    perf ? h('div', { class: 'scc-inline pf-bbtns' }, btns) : h('p', { class: 'scc-note', text: 'Run measurements on the game page.' }),
    prog, verdict, table, notes,
    buttonControl({ text: 'Clear results', icon: 'trash', variant: 'ghost', onClick: () => ctx.state.set('loc.perf.bench', { before: null, after: null }) }));
}

// ------------------------------------------------------------------ network
function network(ctx) {
  return needPerf(ctx, (perf) => {
    const cells = ['Connection', 'Game ping', 'WebSocket', 'Interruptions', 'Probe RTT', 'Stability'].map(cell);
    const probeInfo = h('div', { class: 'scc-hint' });
    const warn = h('div', { class: 'pf-warnings' });
    const root = h('div', {}, h('div', { class: 'scc-stats' }, cells.map((c) => c.node)), probeInfo, warn);
    const set = (i, v, s) => {
      cells[i].v.textContent = v;
      cells[i].s.textContent = s || cells[i].label;
    };
    onTick(ctx, root, () => {
      const n = perf.net.stats();
      set(0, n.online ? 'Online' : 'Offline', n.conn ? `${n.conn.type || '?'} · browser est.${n.conn.rtt != null ? ` ${n.conn.rtt} ms` : ''}` : 'connection');
      set(1, n.game && n.game.rttMs != null ? `${Math.round(n.game.rttMs)}ms` : '—', n.game ? 'reported by game' : 'not exposed by page');
      set(2, n.game && n.game.wsState ? n.game.wsState : '—', n.game ? `${n.gameDisconnects} disconnects` : 'not exposed by page');
      set(3, String(n.interruptions), `${n.recentInterruptions} in last 10 min`);
      set(4, n.probe && n.probe.avg != null ? `${Math.round(n.probe.avg)}ms` : '—', n.probe ? `avg · jitter ${n.probe.jitter != null ? Math.round(n.probe.jitter) : '—'} ms` : 'probe off');
      set(5, n.stability, 'stability');
      probeInfo.textContent = n.probe
        ? `HTTP HEAD → ${n.probe.url} · ${n.probe.n} samples · min ${f0(n.probe.min)} / max ${f0(n.probe.max)} ms · ${n.probe.attempts - n.probe.n} failed. Includes server processing; it is not the game's WebSocket ping.`
        : perf.net.allowProbe
          ? 'Latency probe off. Enable it below to measure round-trip time to an endpoint on this same origin.'
          : 'Latency probe unavailable on this page (only on http(s) game pages).';
      warn.textContent = '';
      for (const w of n.warnings) warn.append(h('div', { class: 'pf-warn', text: w }));
      if (!n.warnings.length) warn.append(h('div', { class: 'scc-hint', text: 'No network warnings.' }));
    });
    return root;
  });
}

function endpointInput(ctx) {
  const inp = h('input', { class: 'scc-input mono', type: 'text', placeholder: '/api/health', spellcheck: false, 'aria-label': 'Latency endpoint path' });
  inp.value = ctx.state.get('cfg.perf.net.endpoint');
  const msg = h('div', { class: 'scc-hint' });
  const commit = () => {
    const v = inp.value.trim();
    if (ctx.perf && v && !ctx.perf.net.resolveEndpoint(v) && ctx.perf.net.allowProbe) {
      msg.textContent = 'Must be a path on this same origin (e.g. /api/health).';
      return;
    }
    msg.textContent = '';
    ctx.state.set('cfg.perf.net.endpoint', v);
  };
  inp.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') commit();
  });
  inp.addEventListener('change', commit);
  return h('div', { class: 'scc-row stacked' }, h('div', { class: 'scc-label', text: 'Authorized endpoint (same origin)' }), h('div', { class: 'scc-hint', text: 'A lightweight route on your own dev server. One HEAD request per interval; the game’s traffic is never touched.' }), inp, msg);
}

// ------------------------------------------------------------------ environment
function environment(ctx) {
  return needPerf(ctx, (perf) => {
    const list = h('div', { class: 'pf-env' });
    const details = h('div', { class: 'scc-meta' });
    const load = async (force) => {
      const { env, findings } = await perf.environment(force);
      list.textContent = '';
      for (const f of findings) list.append(h('div', { class: `pf-find ${f.level}` }, h('span', { class: `scc-dot ${f.level === 'ok' ? 'green' : f.level === 'warn' ? 'amber' : 'red'}` }), h('span', { text: f.text })));
      details.textContent = '';
      for (const [k, v] of [
        ['GPU', env.renderer || '—'],
        ['Max texture', env.maxTexture ? String(env.maxTexture) : '—'],
        ['CPU threads', env.cores ? String(env.cores) : '—'],
        ['Memory', env.memoryGb ? `${env.memoryGb} GB+` : '—'],
        ['Screen', `${env.screen.w}×${env.screen.h} @ ${env.screen.dpr}×`],
        ['Battery', env.battery ? `${Math.round(env.battery.level * 100)}% · ${env.battery.charging ? 'charging' : 'on battery'}` : '—'],
      ]) details.append(h('div', {}, h('span', { text: k }), h('b', { text: v })));
    };
    load(false);
    return h('div', {}, list, details, buttonControl({ text: 'Re-run checks', icon: 'refresh', variant: 'ghost', onClick: () => load(true) }));
  });
}

function restoreDefaults(ctx) {
  let armed = 0;
  return buttonControl({
    text: 'Restore defaults', icon: 'refresh', variant: 'danger',
    onClick: (e, b) => {
      if (!armed) {
        armed = setTimeout(() => {
          armed = 0;
          b.lastChild.textContent = 'Restore defaults';
        }, 3000);
        b.lastChild.textContent = 'Click again to confirm';
        return;
      }
      clearTimeout(armed);
      armed = 0;
      b.lastChild.textContent = 'Restore defaults';
      if (ctx.perf) {
        const r = ctx.perf.restoreDefaults();
        ctx.toast(r.pending.length ? 'Defaults restored — high-res textures need a reload (Presets card)' : 'Performance settings restored to defaults');
      } else {
        ctx.state.set('cfg.perf.autoOptimize', false);
        ctx.state.set('cfg.perf.targetFps', 60);
        ctx.state.set('cfg.perf.liteUi', false);
        ctx.toast('Performance settings restored to defaults');
      }
    },
  });
}

// ------------------------------------------------------------------ tab definition
export const PERF_TAB = {
  id: 'perf',
  label: 'Boost',
  icon: 'bolt',
  title: 'Performance Boost',
  sub: 'Measure real frame pacing, apply supported settings, and verify the result with before/after benchmarks.',
  cards: [
    { title: 'Live performance', enable: 'cfg.perf.monitor', rows: [X(sourceBanner), X(hero)] },
    {
      title: 'Frame-time analytics',
      sub: 'Measured from the browser’s actual frame cadence on this page (requestAnimationFrame timestamps + Long Animation Frames API).',
      rows: [G('cfg.perf.window', 'Measurement window', [{ v: 5, l: '5 s' }, { v: 10, l: '10 s' }, { v: 30, l: '30 s' }]), X(analytics)],
    },
    { title: 'Graphics presets', sub: 'Only settings the game actually exposes are changed. Unsupported items are labelled.', rows: [X(presetCards)] },
    { title: 'Game settings', sub: 'The game’s own controls, with what each one really does (from the client code).', rows: [X(gameSettings)] },
    {
      title: 'Auto optimize',
      enable: 'cfg.perf.autoOptimize',
      sub: 'Steps down one preset only after sustained low FPS (7 of 10 s below 90% of target), waits 30 s between changes, never steps back up by itself, and never reloads the page.',
      rows: [G('cfg.perf.targetFps', 'Target FPS', [{ v: 30, l: '30' }, { v: 60, l: '60' }, { v: 120, l: '120' }, { v: 144, l: '144' }]), X(autoStatus)],
    },
    {
      title: 'Before / after benchmark',
      sub: 'Same-length windows of real frames. A change is only reported when Welch’s t-test on per-second FPS is significant and ≥ 3%.',
      rows: [G('cfg.perf.benchSeconds', 'Window', [{ v: 10, l: '10 s' }, { v: 15, l: '15 s' }, { v: 30, l: '30 s' }]), X(benchmark)],
    },
    {
      title: 'Network diagnostics',
      sub: 'Observation only. Values are never estimated or invented — missing data is shown as “—”.',
      rows: [
        X(network),
        T('cfg.perf.net.probe', 'Latency probe', 'Off by default. Requires an endpoint on the game page’s own origin.'),
        X(endpointInput),
        S('cfg.perf.net.intervalSec', 'Probe interval', 2, 30, 1, ' s'),
      ],
    },
    { title: 'Environment checks', sub: 'Common system causes of low FPS in browser games.', rows: [X(environment)] },
    {
      title: 'Dashboard & defaults',
      rows: [
        T('cfg.perf.liteUi', 'Lightweight dashboard', 'Removes blur, shadows and animations from this panel. Background blur over a moving game canvas costs GPU time every frame.'),
        T('cfg.perf.autoAttach', 'Open on local game pages', 'Show the dashboard automatically on localhost pages that contain the game canvas (#cvs). On survev.io it always loads; minimize or hide it with ⌥D.'),
        N('While the dashboard is minimized or on another tab, live widgets stop updating. The overlay canvas is hidden whenever it has nothing to draw.'),
        X(restoreDefaults),
      ],
    },
  ],
};

