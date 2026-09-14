/* The two horizontal bar lists under the query chart — load time and on-disk
   size. ui/index.html:719-732, the `hBars` closure of `renderCharts`.

   One list per scalar column of the results row, fastest/smallest first, so the
   ranking is the order and not something the reader has to compute. It shares
   the query chart's log/linear switch but not its axis: each list is scaled to
   its own range, because seconds and bytes have nothing to say to each other.

   Rendered without the wrapping column so the caller keeps the original's
   `display:flex;flex-direction:column;gap:5px` container (:748, :753). */

import type { ReactNode } from 'react';
import { engineColor, type EngineRow } from '../../entities/results';
import { niceLin, niceLog } from '../../shared/lib/scale';

export interface HBarsProps {
  /** Visible engines — the same list the query chart draws. */
  engines: EngineRow[];
  /** The scalar to rank by. Non-numbers and non-positives drop out. */
  valueOf: (row: EngineRow) => number | null | undefined;
  /** How the number reads at the end of the bar. */
  fmt: (v: number) => string;
  /** `state.scale === 'log'`. */
  log: boolean;
}

export function HBars({ engines, valueOf, fmt, log }: HBarsProps): ReactNode {
  const items = engines
    .map((r) => ({ name: r.system, v: valueOf(r) }))
    .filter((x): x is { name: string; v: number } => typeof x.v === 'number' && x.v > 0)
    .sort((a, b) => a.v - b.v);

  if (!items.length) return <div style={{ fontSize: 11, color: 'var(--mut)' }}>No data.</div>;

  const mn = items[0].v;
  const mx = items[items.length - 1].v;
  const sc = log ? niceLog(mn, mx) : niceLin(mx);
  // No clamp to the floor here, unlike the query chart: these values are always
  // inside the range they were scaled from.
  const pos = (v: number) =>
    log
      ? (Math.log10(v) - Math.log10(sc.lo)) / (Math.log10(sc.hi) - Math.log10(sc.lo))
      : v / sc.hi;

  return (
    <>
      {items.map((it) => (
        <div key={it.name} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span className="barlab">{it.name}</span>
          <div style={{ flex: 1, position: 'relative', height: 13, background: 'var(--inset)' }}>
            <div
              style={{
                position: 'absolute',
                left: 0,
                top: 0,
                bottom: 0,
                // 0.6% keeps the smallest bar visible rather than a hairline.
                width: Math.max(0.6, pos(it.v) * 100).toFixed(2) + '%',
                background: engineColor(it.name),
              }}
            />
          </div>
          <span className="bartxt">{fmt(it.v)}</span>
        </div>
      ))}
    </>
  );
}
