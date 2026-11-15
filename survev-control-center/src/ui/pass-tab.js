// PASS tab: Survevr Pass level / XP tracking, daily quests, auto-claim of already-granted unlocks, history.

import { h } from '../core/util.js';
import { buttonControl } from './controls.js';

const T = (path, label, hint, x = {}) => ({ type: 'toggle', path, label, hint, ...x });
const G = (path, label, options, x = {}) => ({ type: 'seg', path, label, options, ...x });
const X = (render) => ({ type: 'custom', render });
const N = (text) => ({ type: 'note', text });

const fmt = (n) => (n == null ? '—' : Number(n).toLocaleString());
const when = (t) => {
  const d = new Date(t);
  const today = new Date().toDateString() === d.toDateString();
  return today ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : d.toLocaleDateString([], { month: 'short', day: 'numeric' });
};

function needPass(ctx, build) {
  if (!ctx.pass) {
    return h('p', { class: 'scc-note', text: 'Shown on survev.io, read from the game’s own pass panel.' });
  }
  return build(ctx.pass);
}

function onChange(ctx, el, fn) {
  const run = () => ctx.isShown(el) && fn();
  ctx.disposers.push(ctx.pass.bus.on('change', run));
  ctx.disposers.push(ctx.state.watch('loc.pass', run));
  return run;
}

function progress(ctx) {
  return needPass(ctx, (pass) => {
    const lvl = h('span', { class: 'ps-level', text: '—' });
    const xp = h('div', { class: 'ps-xp' });
    const fill = h('span');
    const bar = h('div', { class: 'ps-bar' }, fill);
    const sub = h('div', { class: 'scc-hint' });
    const state = h('div', { class: 'pf-detect' });
    const stats = h('div', { class: 'pf-chips' });
    const root = h('div', {}, state, h('div', { class: 'ps-hero' }, h('div', { class: 'ps-lvwrap' }, h('small', { text: 'LEVEL' }), lvl), h('div', { class: 'ps-right' }, xp, bar, sub)), stats);
    const update = () => {
      const r = pass.read();
      state.textContent = '';
      const tone = !r.present ? 'muted' : r.locked ? 'amber' : 'green';
      const label = !r.present ? pass.status : r.locked ? 'Log in on survev.io to load your pass progress (showing placeholders)' : 'Reading the game’s pass panel';
      state.append(h('span', { class: `scc-dot ${tone}` }), h('span', { text: label }));
      lvl.textContent = r.level != null ? String(r.level) : '—';
      xp.textContent = r.xp != null ? `${fmt(r.xp)} / ${fmt(r.target)} XP` : '—';
      fill.style.width = `${Math.round((r.pct || 0) * 100)}%`;
      sub.textContent = r.toNext != null ? `${fmt(r.toNext)} XP to level ${r.level != null ? r.level + 1 : '?'} · ${Math.round((r.pct || 0) * 100)}%` : '';
      const hist = ctx.state.get('loc.pass.history') || [];
      const today = new Date().toDateString();
      const todayXp = hist.filter((e) => new Date(e.at).toDateString() === today && e.gained > 0).reduce((s, e) => s + e.gained, 0);
      const ups = hist.filter((e) => e.kind === 'level' && new Date(e.at).toDateString() === today).length;
      stats.textContent = '';
      for (const [v, l] of [[fmt(pass.session.gained), 'Session XP'], [fmt(todayXp), 'Today XP'], [String(ups), 'Levels today'], [String(pass.session.claims), 'Claims']]) {
        stats.append(h('div', { class: 'pf-chip' }, h('b', { text: v }), h('span', { text: l })));
      }
    };
    onChange(ctx, root, update);
    requestAnimationFrame(update);
    return root;
  });
}

function quests(ctx) {
  return needPass(ctx, (pass) => {
    const list = h('div', { class: 'ps-quests' });
    const update = () => {
      const r = pass.read();
      list.textContent = '';
      const qs = r.quests.filter((q) => q.present);
      if (!qs.length) {
        list.append(h('p', { class: 'scc-note', text: 'Quest panels (#pass-quest-0 / #pass-quest-1) not found on this page.' }));
        return;
      }
      for (const q of qs) {
        const pct = q.target ? Math.min(1, (q.cur || 0) / q.target) : 0;
        list.append(
          h('div', { class: 'ps-quest' + (q.complete ? ' done' : '') },
            h('div', { class: 'ps-q-top' }, h('b', { text: q.desc || `Quest ${q.idx + 1} — not loaded${r.locked ? ' (log in on survev.io)' : ''}` }), q.complete ? h('span', { class: 'pf-badge ok', text: 'COMPLETE' }) : null),
            h('div', { class: 'ps-bar sm' }, h('span', { style: { width: `${Math.round(pct * 100)}%` } })),
            h('div', { class: 'ps-q-meta' },
              h('span', { text: q.cur != null && q.target != null ? `${fmt(q.cur)} / ${fmt(q.target)}` : '—' }),
              h('span', { text: q.xp != null ? `+${fmt(q.xp)} XP` : '' }),
              h('span', { text: q.timer ? `refresh ${q.timer}` : '' })))
        );
      }
    };
    onChange(ctx, list, update);
    requestAnimationFrame(update);
    return list;
  });
}

function claimStatus(ctx) {
  return needPass(ctx, (pass) => {
    const st = h('div', { class: 'pf-auto' });
    const btn = buttonControl({
      text: 'Confirm now', icon: 'check', variant: 'ghost',
      onClick: () => {
        const r = pass.confirm('manual');
        ctx.toast({ confirmed: 'Confirmed', 'confirmed-all': 'Confirmed all', 'no-window': 'No unlock window is open', 'no-button': 'No Confirm button found', 'rate-limited': 'One moment…' }[r] || r);
      },
    });
    const root = h('div', {}, st, btn);
    const update = () => {
      const m = pass.read().modal;
      const auto = ctx.state.get('cfg.pass.autoClaim');
      st.className = 'pf-auto ' + (m.open ? 'applied' : auto ? 'ok' : '');
      st.textContent = !m.present
        ? 'The unlock window (#modal-item-confirm) is not on this page.'
        : m.open
          ? `Unlock window open: ${m.item || 'new item'}${auto ? ' — confirming…' : ' — press Confirm now or enable Auto Claim.'}`
          : auto
            ? 'Auto Claim is on. Waiting for the game to show an unlock window.'
            : 'Auto Claim is off. Unlock windows will wait for you.';
      btn.disabled = !m.open;
    };
    onChange(ctx, root, update);
    ctx.watch('cfg.pass', update);
    requestAnimationFrame(update);
    return root;
  });
}

function claimHistory(ctx) {
  const list = h('div', { class: 'pf-log' });
  const render = () => {
    const claims = (ctx.state.get('loc.pass.claims') || []).slice().reverse();
    list.textContent = '';
    if (!claims.length) return list.append(h('div', { class: 'scc-hint', text: 'No confirmations yet.' }));
    for (const c of claims.slice(0, 15)) {
      list.append(h('div', { class: 'ps-row' }, h('span', { text: when(c.at) }), h('b', { text: c.all ? `${c.item} + all pending` : c.item }), h('span', { class: 'pf-badge ' + (c.source === 'auto' ? 'info' : 'muted'), text: c.source === 'auto' ? 'AUTO' : 'MANUAL' })));
    }
  };
  ctx.watch('loc.pass.claims', render);
  render();
  return h('div', {}, list, buttonControl({ text: 'Clear claim history', icon: 'trash', variant: 'ghost', onClick: () => ctx.state.set('loc.pass.claims', []) }));
}

function xpHistory(ctx) {
  const list = h('div', { class: 'pf-log' });
  const render = () => {
    const hist = (ctx.state.get('loc.pass.history') || []).slice().reverse();
    list.textContent = '';
    if (!hist.length) return list.append(h('div', { class: 'scc-hint', text: 'XP changes are recorded when the game updates your pass (after matches).' }));
    for (const e of hist.slice(0, 15)) {
      const text =
        e.kind === 'quest' ? `Quest complete: ${e.desc}${e.xp ? ` (+${fmt(e.xp)} XP)` : ''}`
        : e.kind === 'level' ? `Level ${e.prevLevel} → ${e.level}${e.gained ? ` · +${fmt(e.gained)} XP` : ''}`
        : `Level ${e.level} · ${fmt(e.xp)} / ${fmt(e.target)} XP${e.gained ? ` · +${fmt(e.gained)}` : ''}`;
      list.append(h('div', { class: 'ps-row' }, h('span', { text: when(e.at) }), h('b', { text }), h('span', {})));
    }
  };
  ctx.watch('loc.pass.history', render);
  render();
  return h('div', {}, list, buttonControl({ text: 'Clear XP history', icon: 'trash', variant: 'ghost', onClick: () => { ctx.state.set('loc.pass.history', []); ctx.state.set('loc.pass.last', null); } }));
}

export const PASS_TAB = {
  id: 'pass',
  label: 'Pass',
  icon: 'shield',
  title: 'Survevr Pass',
  sub: 'Level, XP and daily quests read from the game’s own pass panel. Nothing is edited or unlocked by the extension.',
  cards: [
    { title: 'Pass progress', rows: [X(progress)] },
    { title: 'Daily quests', rows: [X(quests)] },
    {
      title: 'Auto claim',
      enable: 'cfg.pass.autoClaim',
      sub: 'When the game shows its “new item unlocked” window, press its own Confirm button for you.',
      rows: [
        G('cfg.pass.claimMode', 'Confirm', [{ v: 'next', l: 'One at a time' }, { v: 'all', l: 'Confirm all' }]),
        X(claimStatus),
        N('That window only appears for items the server has already added to your account. Confirming just acknowledges them — the same as clicking the button yourself. Locked or unearned items cannot be claimed.'),
      ],
    },
    { title: 'Claim history', rows: [X(claimHistory)] },
    { title: 'XP history', rows: [T('cfg.pass.track', 'Record XP / level changes', 'Stored on this device only.'), X(xpHistory)] },
  ],
};
