// Inline SVG icon set (24x24, stroke = currentColor). Static strings only.

const P = {
  crosshair: '<circle cx="12" cy="12" r="8.5"/><path d="M22 12h-4M6 12H2M12 6V2M12 22v-4"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/>',
  entities: '<path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"/><circle cx="12" cy="10" r="2.6"/><path d="M7.5 17c.8-2.2 2.5-3.2 4.5-3.2s3.7 1 4.5 3.2"/>',
  eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  settings: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  power: '<path d="M12 2.5v9"/><path d="M17.7 6.3a8.5 8.5 0 1 1-11.4 0"/>',
  minus: '<path d="M6 12h12"/>',
  plus: '<path d="M12 6v12M6 12h12"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  rec: '<circle cx="12" cy="12" r="6" fill="currentColor" stroke="none"/>',
  play: '<path d="M8 5.5v13l11-6.5z" fill="currentColor"/>',
  pause: '<path d="M9 6v12M15 6v12" stroke-width="2.6"/>',
  stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor" stroke="none"/>',
  download: '<path d="M12 4v11m0 0-4-4m4 4 4-4M5 20h14"/>',
  upload: '<path d="M12 16V5m0 0L8 9m4-4 4 4M5 20h14"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/>',
  flask: '<path d="M9 3h6M10 3v6l-5.5 9.5A2 2 0 0 0 6.2 21h11.6a2 2 0 0 0 1.7-2.5L14 9V3"/><path d="M7.5 15h9"/>',
  link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  shield: '<path d="M12 3 5 6v5.5c0 4.4 2.9 8 7 9.5 4.1-1.5 7-5.1 7-9.5V6z"/><path d="m9 12 2.2 2.2L15.5 10"/>',
  key: '<rect x="3" y="7" width="18" height="11" rx="2.5"/><path d="M7 11h.01M11 11h.01M15 11h.01M8 15h8"/>',
  save: '<path d="M5 4h11l3 3v13H5z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
  eyeoff: '<path d="M3 3l18 18M10.6 5.2A9.7 9.7 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-3.2 4M6.5 6.7C3.9 8.4 2 12 2 12s3.6 7 10 7a9.6 9.6 0 0 0 4.2-1M9.9 9.9a3 3 0 0 0 4.2 4.2"/>',
};

export function icon(name, size = 18) {
  return `<svg class="scc-i" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[name] || ''}</svg>`;
}

export const LOGO = `<svg viewBox="0 0 32 32" width="30" height="30" aria-hidden="true">
  <defs><linearGradient id="sccg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b9bff"/><stop offset="1" stop-color="#2f7bff"/></linearGradient></defs>
  <rect x="1.5" y="1.5" width="29" height="29" rx="8.5" fill="#0b0c0f" stroke="#23262e"/>
  <circle cx="16" cy="16" r="7.6" fill="none" stroke="url(#sccg)" stroke-width="2"/>
  <path d="M16 4.5v5M16 22.5v5M4.5 16h5M22.5 16h5" stroke="url(#sccg)" stroke-width="2" stroke-linecap="round"/>
  <circle cx="16" cy="16" r="2" fill="#fff"/>
</svg>`;
