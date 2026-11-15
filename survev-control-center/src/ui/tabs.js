// Tab + card definitions for the dashboard (declarative), plus the live/custom widgets.

import { h, clone, deepMerge, downloadJson, pickJsonFile, stamp } from '../core/util.js';
import { DEFAULT_CFG, PRESETS, THEMES, WEAPONS, VERSION } from '../core/defaults.js';
import { mergeDefaults } from '../core/state.js';
import { icon } from './icons.js';
import { buttonControl } from './controls.js';
import { PERF_TAB } from './perf-tab.js';
import { PASS_TAB } from './pass-tab.js';

const T = (path, label, hint, x = {}) => ({ type: 'toggle', path, label, hint, ...x });
const S = (path, label, min, max, step, unit, x = {}) => ({ type: 'slider', path, label, min, max, step, unit, ...x });
const G = (path, label, options, x = {}) => ({ type: 'seg', path, label, options, ...x });
const C = (path, label, x = {}) => ({ type: 'color', path, label, ...x });
const K = (path, label, x = {}) => ({ type: 'key', path, label, ...x });
const N = (text, tone) => ({ type: 'note', text, tone });
const X = (render) => ({ type: 'custom', render });

const SHORTCUT_PATHS = ['cfg.shortcuts.master', 'cfg.shortcuts.dashboard', 'cfg.shortcuts.pause', 'cfg.shortcuts.record'];

// ------------------------------------------------------------------ live widgets
function liveOnly(ctx, build) {
  if (!ctx.app) return h('p', { class: 'scc-note', text: 'Live data appears in the Demo Arena or on a connected dev page. Open one from the buttons above.' });
  return build();
}

const pct = (v) => (v == null ? '—' : `${Math.round(v * 100)}%`);
const fix = (v, n = 1, u = '') => (v == null ? '—' : `${v.toFixed(n)}${u}`);

function statGrid(ctx, items) {
  const cells = items.map((it) => {
    const v = h('div', { class: 'scc-stat-v', text: '—' });
    const s = h('div', { class: 'scc-stat-s', text: it.label });
    return { it, v, s, node: h('div', { class: 'scc-stat' }, v, s) };
  });
  const off = ctx.bus.on('diag', (d) => {
    for (const c of cells) {
      const r = c.it.get(d);
      c.v.textContent = r[0];
      c.s.textContent = r[1] || c.it.label;
    }
  });
  ctx.disposers.push(off);
  return h('div', { class: 'scc-stats' }, cells.map((c) => c.node));
}

function sparkline(ctx) {
  const cv = h('canvas', { class: 'scc-spark', height: 64 });
  const cap = h('div', { class: 'scc-spark-cap' }, h('span', { text: 'Aim error while locked (last ~4 s)' }), h('span', { class: 'scc-spark-max', text: '' }));
  const draw = (d) => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = Math.max(60, cv.clientWidth);
    const hh = 64;
    if (cv.width !== Math.round(w * dpr)) {
      cv.width = Math.round(w * dpr);
      cv.height = Math.round(hh * dpr);
    }
    const c = cv.getContext('2d');
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, w, hh);
    const s = d.series;
    let max = 5;
    for (let i = 0; i < s.length; i++) if (s[i] > max) max = s[i];
    max = Math.ceil(max / 5) * 5;
    const accent = getComputedStyle(cv).getPropertyValue('--accent').trim() || '#2f7bff';
    c.strokeStyle = 'rgba(255,255,255,0.06)';
    c.lineWidth = 1;
    for (let i = 0; i <= 2; i++) {
      const y = 6 + (i / 2) * (hh - 12);
      c.beginPath();
      c.moveTo(0, y);
      c.lineTo(w, y);
      c.stroke();
    }
    c.strokeStyle = accent;
    c.lineWidth = 1.8;
    c.lineJoin = 'round';
    c.beginPath();
    let pen = false;
    const area = [];
    for (let i = 0; i < s.length; i++) {
      const v = s[i];
      if (Number.isNaN(v)) {
        pen = false;
        continue;
      }
      const x = (i / (s.length - 1)) * w;
      const y = hh - 6 - (Math.min(v, max) / max) * (hh - 12);
      if (!pen) {
        c.moveTo(x, y);
        pen = true;
      } else c.lineTo(x, y);
      area.push([x, y]);
    }
    c.stroke();
    cap.lastChild.textContent = `scale 0–${max}°`;
  };
  ctx.disposers.push(ctx.bus.on('diag', draw));
  return h('div', { class: 'scc-spark-wrap' }, cv, cap);
}

function visTable(ctx) {
  const body = h('div', { class: 'scc-table-body' });
  const head = h('div', { class: 'scc-trow head' }, h('span', { text: 'Player' }), h('span', { text: 'Dist' }), h('span', { text: 'Visible' }), h('span', { text: 'Blocker' }));
  const rows = [];
  for (let i = 0; i < 8; i++) {
    const r = { name: h('span'), dist: h('span'), vis: h('span'), blk: h('span') };
    r.node = h('div', { class: 'scc-trow scc-hidden' }, r.name, r.dist, r.vis, r.blk);
    rows.push(r);
    body.append(r.node);
  }
  const empty = h('div', { class: 'scc-trow empty', text: 'No players in snapshot' });
  body.append(empty);
  ctx.disposers.push(
    ctx.bus.on('diag', (d) => {
      empty.classList.toggle('scc-hidden', d.vis.length > 0);
      rows.forEach((r, i) => {
        const v = d.vis[i];
        r.node.classList.toggle('scc-hidden', !v);
        if (!v) return;
        r.name.textContent = v.name;
        r.dist.textContent = `${v.dist.toFixed(0)} m`;
        r.vis.textContent = v.visible ? `${Math.round(v.fraction * 100)}%` : 'hidden';
        r.vis.className = v.visible ? (v.fraction >= 1 ? 'ok' : 'part') : 'bad';
        r.blk.textContent = v.visible ? (v.occluder != null ? `#${v.occluder}` : '—') : `#${v.occluder} · ${v.thickness.toFixed(1)} m`;
      });
    })
  );
  return h('div', { class: 'scc-table' }, head, body);
}

// ------------------------------------------------------------------ tab definitions
export const TABS = [
  {
    id: 'aiming',
    label: 'Aiming',
    icon: 'crosshair',
    title: 'Aiming Lab',
    sub: 'Test targeting, smoothing and projectile prediction against synthetic or dev-session entities.',
    cards: [
      {
        title: 'Aiming module',
        enable: 'cfg.aiming.enabled',
        rows: [
          N('Hold the lock key (default Left Shift) in the Demo Arena to engage the aim-lock test. Dev sessions and replays are analysed read-only — nothing is sent to your game.'),
        ],
      },
      {
        title: 'FOV circle',
        sub: 'Candidates must fall inside this circle (screen pixels around the cursor).',
        rows: [
          T('cfg.aiming.showFov', 'Show FOV circle'),
          S('cfg.aiming.fovRadius', 'Radius', 40, 600, 5, ' px'),
          S('cfg.aiming.fovOpacity', 'Fill opacity', 0, 50, 1, '%'),
          T('cfg.aiming.fovPulse', 'Animated pulse'),
          C('cfg.aiming.fovColor', 'Circle colour'),
        ],
      },
      {
        title: 'Smoothing & lock test',
        rows: [
          S('cfg.aiming.smoothing', 'Aim smoothing', 0, 100, 1, '', { hint: '0 = instant snap · 100 = very gradual', format: (v) => (v === 0 ? 'Instant' : v >= 100 ? 'Max' : `${v}`) }),
          S('cfg.aiming.maxTurnRate', 'Max turn rate', 90, 1440, 30, '°/s'),
          G('cfg.aiming.weapon', 'Test weapon', Object.values(WEAPONS).map((w) => ({ v: w.id, l: w.name.split(' ')[0] })), { hint: 'Sets projectile speed, range and spread for the simulated shooter.' }),
          K('cfg.aiming.lockKey', 'Aim-lock key', { single: true, hint: 'Click, then press any key. Backspace clears.' }),
          G('cfg.aiming.lockMode', 'Activation', [{ v: 'hold', l: 'Hold' }, { v: 'toggle', l: 'Toggle' }]),
          T('cfg.aiming.autoFire', 'Auto test-fire when locked', 'Fires the simulated weapon whenever hit chance is above 25%.'),
        ],
      },
      {
        title: 'Target selection', advanced: true,
        rows: [
          G('cfg.aiming.targetMode', 'Priority', [{ v: 'crosshair', l: 'Crosshair' }, { v: 'distance', l: 'Distance' }, { v: 'health', l: 'Health' }, { v: 'threat', l: 'Threat' }]),
          T('cfg.aiming.enemiesOnly', 'Enemies only', 'Allies and neutrals are shown as rejected candidates.'),
          G('cfg.aiming.visibilityCheck', 'Visibility check', [{ v: 'off', l: 'Off' }, { v: 'sight', l: 'Sight' }, { v: 'shot', l: 'Shot' }, { v: 'both', l: 'Both' }], { hint: 'Sight = not hidden by view blockers. Shot = bullet path not blocked.' }),
          S('cfg.aiming.stickyMs', 'Target stickiness', 0, 1500, 25, ' ms'),
          T('cfg.aiming.showCandidates', 'Show candidate scores'),
        ],
      },
      {
        title: 'Projectile prediction', advanced: true,
        enable: 'cfg.aiming.prediction.enabled',
        sub: 'Solves the interception point for a moving target and the weapon’s bullet speed.',
        rows: [
          S('cfg.aiming.prediction.strength', 'Lead strength', 0, 150, 5, '%', { hint: '100% = full constant-velocity lead' }),
          S('cfg.aiming.prediction.maxLeadMs', 'Max lead time', 100, 2000, 50, ' ms'),
          S('cfg.aiming.prediction.latencyMs', 'Latency compensation', 0, 250, 5, ' ms'),
          T('cfg.aiming.prediction.showMarker', 'Lead marker'),
          T('cfg.aiming.prediction.showPath', 'Predicted target path'),
          T('cfg.aiming.prediction.showGhost', 'Ghost projectile animation'),
        ],
      },
      {
        title: 'Trajectory', advanced: true,
        rows: [
          T('cfg.aiming.showTrajectory', 'Aim trajectory line'),
          T('cfg.aiming.showSpread', 'Weapon spread cone'),
          T('cfg.aiming.showImpact', 'Impact label (what the shot hits)'),
        ],
      },
      {
        title: 'Accuracy diagnostics',
        rows: [
          X((ctx) =>
            liveOnly(ctx, () =>
              h('div', {},
                statGrid(ctx, [
                  { label: 'Accuracy', get: (d) => [pct(d.accuracy), `${d.hits}/${d.hits + d.misses} hits`] },
                  { label: 'Shots', get: (d) => [String(d.shots), 'fired'] },
                  { label: 'Aim error', get: (d) => [fix(d.meanErr, 1, '°'), 'mean error'] },
                  { label: 'Lead error', get: (d) => [fix(d.leadErr, 1, ' m'), 'lead miss'] },
                  { label: 'Hit chance', get: (d) => [pct(d.hitProb), d.target ? `vs ${d.target}` : 'no target'] },
                  { label: 'Acquire', get: (d) => [fix(d.acquire, 0, ' ms'), `${d.locks} locks`] },
                ]),
                sparkline(ctx),
                buttonControl({ type: 'button', text: 'Reset statistics', icon: 'refresh', variant: 'ghost', onClick: () => ctx.app.resetDiagnostics() })
              )
            )
          ),
        ],
      },
    ],
  },

  {
    id: 'entities',
    label: 'Entities',
    icon: 'entities',
    title: 'Entity Visualization',
    sub: 'Bounding boxes, labels, team colours, loot markers and off-screen indicators.',
    cards: [
      {
        title: 'Entity module',
        enable: 'cfg.entities.enabled',
        rows: [S('cfg.entities.maxDistance', 'Max distance', 20, 400, 5, ' m'), X((ctx) => liveOnly(ctx, () => statGrid(ctx, [
          { label: 'Players', get: (d) => [String(d.counts.players)] },
          { label: 'Visible', get: (d) => [String(d.counts.visible)] },
          { label: 'Occluded', get: (d) => [String(d.counts.occluded)] },
          { label: 'Loot', get: (d) => [String(d.counts.loot)] },
        ])))],
      },
      {
        title: 'Bounding boxes',
        enable: 'cfg.entities.boxes.show',
        rows: [
          G('cfg.entities.boxes.style', 'Style', [{ v: 'corners', l: 'Corners' }, { v: 'full', l: 'Full' }, { v: 'filled', l: 'Filled' }]),
          S('cfg.entities.boxes.thickness', 'Line thickness', 1, 5, 0.5, ' px'),
          S('cfg.entities.boxes.scale', 'Box size', 80, 180, 5, '%'),
          T('cfg.entities.boxes.dashedOccluded', 'Dashed when occluded', 'Uses the visibility engine to mark hidden entities.'),
        ],
      },
      {
        title: 'Labels & health',
        rows: [
          T('cfg.entities.labels.names', 'Names'),
          T('cfg.entities.labels.health', 'Health bars'),
          G('cfg.entities.labels.healthStyle', 'Health style', [{ v: 'bar', l: 'Smooth bar' }, { v: 'segments', l: 'Segments' }], { showIf: (s) => s.get('cfg.entities.labels.health') }),
          T('cfg.entities.labels.hpText', 'Health numbers', null, { showIf: (s) => s.get('cfg.entities.labels.health') }),
          T('cfg.entities.labels.distance', 'Distance labels'),
          G('cfg.entities.labels.unit', 'Distance unit', [{ v: 'm', l: 'Metres' }, { v: 'u', l: 'World units' }], { showIf: (s) => s.get('cfg.entities.labels.distance') }),
          T('cfg.entities.labels.weapon', 'Weapon names'),
          S('cfg.entities.labels.scale', 'Label size', 70, 150, 5, '%'),
        ],
      },
      {
        title: 'Team colours', advanced: true,
        enable: 'cfg.entities.teams.enabled',
        rows: [
          G('cfg.entities.teams.mode', 'Colour by', [{ v: 'relation', l: 'Relation' }, { v: 'team', l: 'Per team' }]),
          C('cfg.entities.teams.colors.self', 'You', { showIf: (s) => s.get('cfg.entities.teams.mode') === 'relation' }),
          C('cfg.entities.teams.colors.ally', 'Allies', { showIf: (s) => s.get('cfg.entities.teams.mode') === 'relation' }),
          C('cfg.entities.teams.colors.enemy', 'Enemies', { showIf: (s) => s.get('cfg.entities.teams.mode') === 'relation' }),
          C('cfg.entities.teams.colors.neutral', 'Neutral', { showIf: (s) => s.get('cfg.entities.teams.mode') === 'relation' }),
          S('cfg.entities.teams.opacity', 'Overlay opacity', 30, 100, 1, '%'),
        ],
      },
      {
        title: 'Loot markers', advanced: true,
        enable: 'cfg.entities.loot.show',
        rows: [
          G('cfg.entities.loot.minRarity', 'Minimum rarity', [{ v: 0, l: 'All' }, { v: 1, l: 'Uncommon+' }, { v: 2, l: 'Rare+' }, { v: 3, l: 'Epic+' }]),
          T('cfg.entities.loot.labels', 'Item labels'),
          S('cfg.entities.loot.size', 'Marker size', 5, 18, 1, ' px'),
        ],
      },
      {
        title: 'Off-screen indicators', advanced: true,
        enable: 'cfg.entities.offscreen.show',
        rows: [
          S('cfg.entities.offscreen.size', 'Arrow size', 8, 28, 1, ' px'),
          S('cfg.entities.offscreen.margin', 'Edge margin', 16, 140, 2, ' px'),
          S('cfg.entities.offscreen.maxCount', 'Max indicators', 1, 24, 1, ''),
          T('cfg.entities.offscreen.labels', 'Distance chips'),
        ],
      },
      { title: 'Connector lines', advanced: true, rows: [T('cfg.entities.lines.show', 'Lines from you to each entity', 'Fade with distance.')] },
    ],
  },

  {
    id: 'visibility',
    label: 'Visibility',
    icon: 'eye',
    title: 'Visibility Debug',
    sub: 'Line of sight, occlusion, silhouettes and collision diagnostics for your level geometry.',
    cards: [
      { title: 'Visibility module', enable: 'cfg.visibility.enabled', rows: [N('Obstacles carry three flags — blocks sight, blocks bullets, blocks movement — so glass, bushes and walls behave differently.')] },
      {
        title: 'Line of sight',
        rows: [
          T('cfg.visibility.los.showCone', 'Visibility polygon'),
          T('cfg.visibility.los.showRays', 'Rays to each player', 'Green = clear · red = blocked at the marked point.'),
          S('cfg.visibility.los.range', 'Range', 10, 200, 5, ' m'),
          S('cfg.visibility.los.fov', 'View cone', 30, 360, 5, '°', { hint: 'Cone is centred on your facing direction.' }),
          S('cfg.visibility.los.fillOpacity', 'Fill opacity', 0, 40, 1, '%'),
        ],
      },
      {
        title: 'Wall occlusion diagnostics', advanced: true,
        enable: 'cfg.visibility.occlusion.show',
        rows: [
          T('cfg.visibility.occlusion.highlight', 'Highlight occluding obstacles'),
          T('cfg.visibility.occlusion.blockerPoints', 'Blocker hit points'),
          T('cfg.visibility.occlusion.labels', 'Wall thickness labels'),
          X((ctx) => liveOnly(ctx, () => visTable(ctx))),
        ],
      },
      {
        title: 'Character silhouettes',
        enable: 'cfg.visibility.silhouettes.show',
        rows: [
          G('cfg.visibility.silhouettes.colorMode', 'Colour', [{ v: 'team', l: 'By team' }, { v: 'custom', l: 'Custom' }]),
          C('cfg.visibility.silhouettes.color', 'Custom colour', { showIf: (s) => s.get('cfg.visibility.silhouettes.colorMode') === 'custom' }),
          S('cfg.visibility.silhouettes.alpha', 'Fill transparency', 5, 100, 1, '%'),
          S('cfg.visibility.silhouettes.outline', 'Outline width', 0, 6, 0.5, ' px'),
          S('cfg.visibility.silhouettes.glow', 'Glow', 0, 30, 1, ' px'),
          T('cfg.visibility.silhouettes.outlineVisible', 'Also outline visible players'),
        ],
      },
      {
        title: 'Obstacle rendering', advanced: true,
        rows: [
          S('cfg.visibility.wallAlpha', 'Obstacle opacity', 10, 100, 1, '%', { hint: 'Lower to see entities through level geometry in the demo view.' }),
          T('cfg.visibility.obstacleGhost', 'Obstacle ghosts on dev pages', 'Draws the obstacles your dev API reports as translucent shapes.'),
          T('cfg.visibility.obstacleOutline', 'Outline obstacles (demo)'),
        ],
      },
      {
        title: 'Collision debugging', advanced: true,
        rows: [
          T('cfg.visibility.collisions.hitboxes', 'Obstacle hitboxes', 'Blue = blocks movement · orange = blocks bullets · green = blocks sight · dashed = does not block sight.'),
          T('cfg.visibility.collisions.players', 'Player hit circles'),
          T('cfg.visibility.collisions.contacts', 'Contact points & normals', 'Amber = touching · red = penetrating.'),
          T('cfg.visibility.collisions.impacts', 'Bullet impact markers'),
          X((ctx) => liveOnly(ctx, () => statGrid(ctx, [
            { label: 'Obstacles', get: (d) => [String(d.counts.obstacles)] },
            { label: 'Contacts', get: (d) => [String(d.counts.contacts)] },
            { label: 'Bullets', get: (d) => [String(d.counts.bullets)] },
          ]))),
        ],
      },
    ],
  },
];

// ------------------------------------------------------------------ settings tab
const NAME_BAD = new Set(['__proto__', 'constructor', 'prototype']);

function setAccent(state, preset, accent) {
  const old = state.get('cfg.theme.accent');
  state.set('cfg.theme.preset', preset);
  state.set('cfg.theme.accent', accent);
  if (state.get('cfg.aiming.fovColor') === old) state.set('cfg.aiming.fovColor', accent);
}

function themeSwatches(ctx) {
  const wrap = h('div', { class: 'scc-themes' });
  const btns = Object.entries(THEMES).map(([id, t]) => {
    const b = h('button', { class: 'scc-theme', type: 'button', title: t.label, 'aria-label': t.label, style: { '--c': t.accent } });
    b.addEventListener('click', () => setAccent(ctx.state, id, t.accent));
    wrap.append(b);
    return [id, b];
  });
  const custom = h('label', { class: 'scc-theme custom', title: 'Custom colour' }, h('input', { type: 'color' }));
  custom.firstChild.addEventListener('input', (e) => setAccent(ctx.state, 'custom', e.target.value));
  wrap.append(custom);
  const upd = () => {
    const cur = ctx.state.get('cfg.theme.preset');
    for (const [id, b] of btns) b.classList.toggle('on', id === cur);
    custom.classList.toggle('on', cur === 'custom');
    custom.firstChild.value = ctx.state.get('cfg.theme.accent');
    custom.style.setProperty('--c', ctx.state.get('cfg.theme.accent'));
  };
  ctx.watch('cfg.theme', upd);
  upd();
  return h('div', { class: 'scc-row stacked' }, h('div', { class: 'scc-label', text: 'Accent colour' }), wrap);
}

function presetChips(ctx) {
  const wrap = h('div', { class: 'scc-chips' });
  for (const [id, p] of Object.entries(PRESETS)) {
    const b = h('button', { class: 'scc-chipbtn', type: 'button', text: p.label });
    b.addEventListener('click', () => {
      const cfg = ctx.state.data.cfg;
      const next = deepMerge(clone(DEFAULT_CFG), p.patch);
      next.theme = clone(cfg.theme);
      next.shortcuts = clone(cfg.shortcuts);
      next.aiming.lockKey = cfg.aiming.lockKey;
      next.aiming.fovColor = cfg.theme.accent;
      ctx.state.replaceCfg(next);
      ctx.state.set('loc.activeProfile', '');
      ctx.toast(`Preset applied: ${p.label}`);
    });
    wrap.append(b);
  }
  return h('div', { class: 'scc-row stacked' }, h('div', { class: 'scc-label', text: 'Quick presets' }), h('div', { class: 'scc-hint', text: 'Layout presets keep your theme and shortcuts.' }), wrap);
}

function masterRow(ctx) {
  const sw = h('button', { class: 'scc-switch big', type: 'button', role: 'switch', 'aria-label': 'Master ON/OFF' }, h('span', { class: 'scc-knob' }));
  const title = h('div', { class: 'scc-label big' });
  const hint = h('div', { class: 'scc-hint' });
  const upd = () => {
    const on = ctx.state.get('loc.master');
    sw.classList.toggle('on', on);
    sw.setAttribute('aria-checked', String(on));
    title.textContent = on ? 'Master ON' : 'Master OFF';
    hint.textContent = on ? 'All visualization modules are running.' : 'Overlays are hidden. Settings are kept.';
  };
  sw.addEventListener('click', () => ctx.state.toggle('loc.master'));
  ctx.watch('loc.master', upd);
  upd();
  return h('div', { class: 'scc-row master' }, h('div', { class: 'scc-row-text' }, title, hint), sw);
}

function profilesCard(ctx) {
  const input = h('input', { class: 'scc-input', type: 'text', maxLength: 32, placeholder: 'Configuration name', 'aria-label': 'Configuration name' });
  const list = h('div', { class: 'scc-plist' });
  const valid = (n) => n && n.length <= 32 && !NAME_BAD.has(n);
  const render = () => {
    const profiles = ctx.state.get('loc.profiles') || {};
    const active = ctx.state.get('loc.activeProfile');
    list.textContent = '';
    const names = Object.keys(profiles);
    if (!names.length) list.append(h('p', { class: 'scc-note', text: 'No saved configurations yet. Name the current setup above and press Save.' }));
    for (const name of names) {
      const p = profiles[name];
      const when = p.savedAt ? new Date(p.savedAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '';
      list.append(
        h('div', { class: 'scc-pitem' + (name === active ? ' active' : '') },
          h('div', { class: 'scc-pname' }, h('span', { text: name }), h('small', { text: name === active ? 'ACTIVE' : when })),
          h('div', { class: 'scc-pact' },
            iconBtn('check', 'Load', () => {
              ctx.state.replaceCfg(p.cfg);
              ctx.state.set('loc.activeProfile', name);
              ctx.toast(`Loaded “${name}”`);
            }),
            iconBtn('download', 'Export', () => downloadJson(`scc-config-${name.replace(/[^\w-]+/g, '_')}.json`, { format: 'scc-config', version: 1, profiles: { [name]: p } })),
            iconBtn('trash', 'Delete', () => {
              const next = { ...ctx.state.get('loc.profiles') };
              delete next[name];
              ctx.state.set('loc.profiles', next);
              if (ctx.state.get('loc.activeProfile') === name) ctx.state.set('loc.activeProfile', '');
            })
          )
        )
      );
    }
  };
  const iconBtn = (ic, title, fn) => {
    const b = h('button', { class: 'scc-iconbtn sm', type: 'button', title, 'aria-label': title, html: icon(ic, 15) });
    b.addEventListener('click', fn);
    return b;
  };
  const save = () => {
    const name = input.value.trim();
    if (!valid(name)) return ctx.toast('Enter a name (1–32 characters)');
    const profiles = { ...ctx.state.get('loc.profiles') };
    if (!profiles[name] && Object.keys(profiles).length >= 30) return ctx.toast('Limit of 30 saved configurations reached');
    profiles[name] = { savedAt: Date.now(), cfg: clone(ctx.state.data.cfg) };
    ctx.state.set('loc.profiles', profiles);
    ctx.state.set('loc.activeProfile', name);
    input.value = '';
    ctx.toast(`Saved “${name}”`);
  };
  input.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') save();
  });
  ctx.watch('loc.profiles', render);
  ctx.watch('loc.activeProfile', render);
  render();
  const importBtn = buttonControl({
    text: 'Import', icon: 'upload', variant: 'ghost',
    onClick: async () => {
      try {
        const data = await pickJsonFile();
        if (!data) return;
        const incoming = data.profiles && typeof data.profiles === 'object' ? data.profiles : data.cfg ? { [data.name || 'Imported']: { cfg: data.cfg } } : null;
        if (data.format !== 'scc-config' && !incoming) throw new Error('Not a Control Center configuration file');
        const next = { ...ctx.state.get('loc.profiles') };
        let n = 0;
        for (const [name, p] of Object.entries(incoming || {})) {
          if (!valid(name) || !p || typeof p !== 'object' || Object.keys(next).length >= 30) continue;
          next[name] = { savedAt: Date.now(), cfg: mergeDefaults(DEFAULT_CFG, p.cfg) };
          n++;
        }
        ctx.state.set('loc.profiles', next);
        ctx.toast(n ? `Imported ${n} configuration${n > 1 ? 's' : ''}` : 'Nothing to import');
      } catch (e) {
        ctx.toast(e.message);
      }
    },
  });
  const exportAll = buttonControl({
    text: 'Export all', icon: 'download', variant: 'ghost',
    onClick: () => downloadJson(`scc-configs-${stamp()}.json`, { format: 'scc-config', version: 1, profiles: ctx.state.get('loc.profiles') }),
  });
  const saveBtn = buttonControl({ text: 'Save', icon: 'save', variant: 'primary', onClick: save });
  return h('div', {}, h('div', { class: 'scc-inline' }, input, saveBtn), list, h('div', { class: 'scc-inline end' }, importBtn, exportAll));
}

const PHASES = {
  demo: ['accent', 'Demo mode'],
  live: ['accent', 'Live site · developer modules off'],
  idle: ['muted', 'Not attached'],
  probing: ['amber', 'Waiting for dev API'],
  authorized: ['green', 'Authorized session'],
  stale: ['amber', 'Authorized · no data'],
  rejected: ['red', 'Rejected'],
  blocked: ['red', 'Host not permitted'],
  none: ['muted', 'No dev page'],
};

function devCard(ctx) {
  const dot = h('span', { class: 'scc-dot' });
  const label = h('span', { class: 'scc-dev-label' });
  const reason = h('div', { class: 'scc-hint' });
  const meta = h('div', { class: 'scc-meta' });
  const apply = (st) => {
    const [tone, text] = PHASES[st.phase] || PHASES.none;
    dot.className = 'scc-dot ' + tone;
    label.textContent = text;
    reason.textContent = st.reason || '';
    meta.textContent = '';
    for (const [k, v] of [['Host', st.host], ['Environment', st.env], ['Session', st.sessionId], ['App', st.app], ['Frames', st.frames != null && st.phase !== 'demo' ? String(st.frames) : '']]) {
      if (v) meta.append(h('div', {}, h('span', { text: k }), h('b', { text: v })));
    }
  };
  let alive = true;
  const poll = async () => {
    if (!alive) return;
    try {
      apply(await ctx.getDevStatus());
    } catch (_) {
      apply({ phase: 'none' });
    }
  };
  poll();
  const iv = setInterval(poll, 1000);
  ctx.disposers.push(() => {
    alive = false;
    clearInterval(iv);
  });

  const tok = h('input', { class: 'scc-input mono', type: 'password', placeholder: 'Session token', autocomplete: 'off', spellcheck: false, 'aria-label': 'Session token' });
  tok.value = ctx.state.get('loc.dev.token');
  const commit = () => {
    ctx.state.set('loc.dev.token', tok.value.trim());
    if (ctx.actions.reconnect) ctx.actions.reconnect();
    ctx.toast('Token saved');
  };
  tok.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Enter') commit();
  });
  tok.addEventListener('change', commit);
  const reveal = h('button', { class: 'scc-iconbtn sm', type: 'button', title: 'Show / hide token', 'aria-label': 'Show or hide token', html: icon('eye', 15) });
  reveal.addEventListener('click', () => (tok.type = tok.type === 'password' ? 'text' : 'password'));
  ctx.watch('loc.dev.token', () => {
    if (document.activeElement !== tok && tok.value !== ctx.state.get('loc.dev.token')) tok.value = ctx.state.get('loc.dev.token');
  });

  return h('div', {},
    h('div', { class: 'scc-status' }, dot, label),
    reason,
    meta,
    h('div', { class: 'scc-row stacked' }, h('div', { class: 'scc-label', text: 'Session token' }), h('div', { class: 'scc-hint', text: 'Must match the token your private test server hands to the page. Stored on this device only.' }), h('div', { class: 'scc-inline' }, tok, reveal)),
    ctx.actions.reconnect ? buttonControl({ text: 'Reconnect', icon: 'refresh', variant: 'ghost', onClick: () => { ctx.actions.reconnect(); ctx.toast('Handshake restarted'); } }) : null,
    h('p', { class: 'scc-note', text: 'The adapter only runs on localhost / private-network hosts, only for sessions that declare themselves "development" or "private-test", and never on public multiplayer sites.' })
  );
}

function versionNote() {
  return h('p', { class: 'scc-note', text: `Version ${VERSION}` });
}

function resetCard(ctx) {
  let armed = 0;
  const btn = buttonControl({
    text: 'Reset to defaults', icon: 'refresh', variant: 'danger',
    onClick: (e, b) => {
      if (!armed) {
        armed = setTimeout(() => {
          armed = 0;
          b.lastChild.textContent = 'Reset to defaults';
        }, 3000);
        b.lastChild.textContent = 'Click again to confirm';
        return;
      }
      clearTimeout(armed);
      armed = 0;
      ctx.state.resetCfg();
      ctx.state.set('loc.activeProfile', '');
      b.lastChild.textContent = 'Reset to defaults';
      ctx.toast('All settings restored to defaults');
    },
  });
  ctx.disposers.push(() => clearTimeout(armed));
  return h('div', {}, btn, h('p', { class: 'scc-note', text: `Resets configuration only. Saved configurations and your session token are kept. · v${VERSION}` }));
}

export const SETTINGS_TAB = {
  id: 'settings',
  label: 'Settings',
  icon: 'settings',
  title: 'Settings',
  sub: 'Master switch, shortcuts, theme, saved configurations and the developer session.',
  cards: [
    {
      title: 'General',
      rows: [
        X(masterRow),
        T('loc.ui.startMinimized', 'Start minimized', 'Each visit shows only the small status icon. Press ⌥D or click it to open.'),
        T('loc.ui.advanced', 'Show advanced settings', 'Analytics, benchmarks, auto optimize, histories, shortcuts, theme, saved configurations.'),
        { type: 'custom', advanced: true, render: presetChips },
        T('cfg.hud.show', 'Status HUD on canvas', 'Small FPS / mode chip in the bottom-left of the dev overlay.', { advanced: true }),
        { type: 'custom', render: versionNote },
      ],
    },
    {
      title: 'Keyboard shortcuts', advanced: true,
      sub: 'Work inside the Demo Arena and on connected dev pages. Click a shortcut, then press the new keys.',
      rows: [
        K('cfg.shortcuts.master', 'Master ON / OFF', { conflicts: SHORTCUT_PATHS }),
        K('cfg.shortcuts.dashboard', 'Open / minimize dashboard', { conflicts: SHORTCUT_PATHS }),
        K('cfg.shortcuts.pause', 'Pause demo / replay', { conflicts: SHORTCUT_PATHS }),
        K('cfg.shortcuts.record', 'Start / stop recording', { conflicts: SHORTCUT_PATHS }),
        N('Browser-level shortcuts (Alt+Shift+S, Alt+Shift+D) can be changed at chrome://extensions/shortcuts.'),
      ],
    },
    {
      title: 'Theme', advanced: true,
      rows: [
        X(themeSwatches),
        S('cfg.theme.radius', 'Corner radius', 6, 22, 1, ' px'),
        S('cfg.theme.panelOpacity', 'Panel opacity', 70, 100, 1, '%'),
        T('cfg.theme.compact', 'Compact density'),
        T('cfg.theme.motion', 'Animations'),
      ],
    },
    { title: 'Saved configurations', advanced: true, rows: [X(profilesCard)] },
    { title: 'Developer authorization', advanced: true, sub: 'Server-authorized development sessions only.', rows: [X(devCard)] },
    { title: 'Reset', advanced: true, rows: [X(resetCard)] },
  ],
};

export const ALL_TABS = [...TABS, PERF_TAB, PASS_TAB, SETTINGS_TAB];

/** Tab sets per context. Developer modules are never offered on the live site. */
export const TAB_SETS = {
  dev: ['aiming', 'entities', 'visibility', 'perf', 'settings'],
  live: ['perf', 'pass', 'settings'],
  popup: ['aiming', 'entities', 'visibility', 'perf', 'pass', 'settings'],
};
const SHORT = { aiming: 'Aim', entities: 'Entities', visibility: 'Vision', perf: 'Boost', pass: 'Pass', settings: 'Settings' };
for (const t of ALL_TABS) t.short = SHORT[t.id] || t.label;
