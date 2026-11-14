// Canvas drawing helpers.

export const FONT = "Inter, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif";
export const MONO = "'SF Mono', ui-monospace, Menlo, Consolas, monospace";

const colorCache = new Map();

/** '#rrggbb' + alpha -> 'rgba(r,g,b,a)' (cached). */
export function hexA(hex, a = 1) {
  const key = hex + '|' + Math.round(a * 100);
  let v = colorCache.get(key);
  if (v) return v;
  let s = hex.startsWith('#') ? hex.slice(1) : hex;
  if (s.length === 3) s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2];
  const n = parseInt(s, 16);
  v = `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${Math.max(0, Math.min(1, a))})`;
  if (colorCache.size > 600) colorCache.clear();
  colorCache.set(key, v);
  return v;
}

export function roundRectPath(ctx, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** Text with a dark halo for legibility on any background. */
export function haloText(ctx, text, x, y, color, size = 11, weight = 600, align = 'center', baseline = 'alphabetic') {
  ctx.font = `${weight} ${size}px ${FONT}`;
  ctx.textAlign = align;
  ctx.textBaseline = baseline;
  ctx.lineJoin = 'round';
  ctx.lineWidth = 3;
  ctx.strokeStyle = 'rgba(6,7,9,0.85)';
  ctx.strokeText(text, x, y);
  ctx.fillStyle = color;
  ctx.fillText(text, x, y);
}

/** Rounded label chip. (x,y) is the anchor; align picks which edge it anchors. */
export function chip(ctx, text, x, y, o = {}) {
  const size = o.size || 10;
  ctx.font = `${o.weight || 600} ${size}px ${o.mono ? MONO : FONT}`;
  const padX = o.padX ?? 5;
  const w = ctx.measureText(text).width + padX * 2;
  const hgt = size + 6;
  const left = o.align === 'left' ? x : o.align === 'right' ? x - w : x - w / 2;
  roundRectPath(ctx, left, y - hgt / 2, w, hgt, 5);
  ctx.fillStyle = o.bg || 'rgba(10,11,14,0.78)';
  ctx.fill();
  if (o.border) {
    ctx.lineWidth = 1;
    ctx.strokeStyle = o.border;
    ctx.stroke();
  }
  ctx.fillStyle = o.fg || '#e9ecf2';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, left + padX, y + 0.5);
  return w;
}

export function healthColor(frac) {
  const hue = Math.round(Math.max(0, Math.min(1, frac)) * 125);
  return `hsl(${hue} 82% 52%)`;
}

export function crosshair(ctx, x, y, r, gap = 3) {
  ctx.beginPath();
  ctx.moveTo(x - r, y);
  ctx.lineTo(x - gap, y);
  ctx.moveTo(x + gap, y);
  ctx.lineTo(x + r, y);
  ctx.moveTo(x, y - r);
  ctx.lineTo(x, y - gap);
  ctx.moveTo(x, y + gap);
  ctx.lineTo(x, y + r);
}

export function bracket(ctx, x, y, half, len) {
  ctx.beginPath();
  for (const [sx, sy] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
    const cx = x + sx * half;
    const cy = y + sy * half;
    ctx.moveTo(cx - sx * len, cy);
    ctx.lineTo(cx, cy);
    ctx.lineTo(cx, cy - sy * len);
  }
}

/** Top-down character: body, two hands and a weapon barrel along `angle`. */
export function bodyPath(ctx, x, y, r, angle) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arc(x, y, r, 0, Math.PI * 2);
  for (const side of [-0.75, 0.75]) {
    const hx = x + Math.cos(angle + side) * r * 0.98;
    const hy = y + Math.sin(angle + side) * r * 0.98;
    ctx.moveTo(hx + r * 0.32, hy);
    ctx.arc(hx, hy, r * 0.32, 0, Math.PI * 2);
  }
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  const bl = r * 1.7;
  const bw = r * 0.16;
  ctx.moveTo(x + c * r * 0.8 - s * bw, y + s * r * 0.8 + c * bw);
  ctx.lineTo(x + c * bl - s * bw, y + s * bl + c * bw);
  ctx.lineTo(x + c * bl + s * bw, y + s * bl - c * bw);
  ctx.lineTo(x + c * r * 0.8 + s * bw, y + s * r * 0.8 - c * bw);
  ctx.closePath();
}

export function arrowHead(ctx, size) {
  ctx.beginPath();
  ctx.moveTo(size, 0);
  ctx.lineTo(-size * 0.7, size * 0.75);
  ctx.lineTo(-size * 0.35, 0);
  ctx.lineTo(-size * 0.7, -size * 0.75);
  ctx.closePath();
}
