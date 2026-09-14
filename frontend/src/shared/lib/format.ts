/* Every string the page prints, and the one colour it computes.
   ui/index.html:291, 349-376.

   The precision ladders are load-bearing: a cell that reads "0.003" where the
   original read "0.00" is a different screenshot, so the thresholds are copied
   rather than replaced with a formatter that "does the same thing". */

/** "1,000,000,000". Non-finite → em dash. */
export function fmtItems(n: number | null | undefined): string {
  return Number.isFinite(n) ? new Intl.NumberFormat('en-US').format(n as number) : '—';
}

/** Seconds, 3 significant-ish digits: 123 / 12.3 / 1.23 / 0.123. */
export function fmtSec(s: number | null | undefined): string {
  if (typeof s !== 'number') return '—';
  if (s >= 100) return s.toFixed(0);
  if (s >= 10) return s.toFixed(1);
  if (s >= 1) return s.toFixed(2);
  return s.toFixed(3);
}

/** Binary units, 1024-based, one decimal below 100. */
export function fmtBytes(b: number | null | undefined): string {
  if (typeof b !== 'number' || b <= 0) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = b;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + ' ' + u[i];
}

/** Seconds in, milliseconds out. */
export function fmtMs(s: number | null | undefined): string {
  if (typeof s !== 'number') return '—';
  const ms = s * 1000;
  if (ms >= 100) return ms.toFixed(0);
  if (ms >= 1) return ms.toFixed(1);
  return ms.toFixed(2);
}

/** "1.00×", "12.3×", "∞×". */
export function fmtRatio(r: number | null | undefined): string {
  return typeof r !== 'number'
    ? '—'
    : !isFinite(r)
      ? '∞×'
      : (r >= 100 ? r.toFixed(0) : r.toFixed(2)) + '×';
}

/**
 * Cell background: green at parity, red at 8× and beyond, on a log2 ramp.
 * Returns `var(--card)` for a non-positive ratio so an empty cell blends in.
 */
export function ratioBg(ratio: number | null | undefined): string {
  if (!(typeof ratio === 'number' && ratio > 0)) return 'var(--card)';
  const t = Math.min(1, Math.log2(ratio) / Math.log2(8));
  return `hsl(${(120 * (1 - t)).toFixed(0)}, 62%, ${(78 - 16 * t).toFixed(0)}%)`;
}

/**
 * HTML entity escape.
 *
 * React escapes text and attributes on its own, so this is *not* needed for
 * ordinary JSX. It is here because the original built every string by
 * concatenation and a widget that still renders one through
 * `dangerouslySetInnerHTML` (a query plan, an SVG payload) needs the identical
 * escaping — the four replacements, in this order, and no others.
 */
export function esc(s: unknown): string {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
