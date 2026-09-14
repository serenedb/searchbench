/* The grouped column chart — one group per query, one 9px bar per engine.
   ui/index.html:681-717, the first half of `renderCharts`.

   The axis is the whole design of it. On a log scale the benchmark spans five
   decades — a term lookup answers in a millisecond, a full scan takes a minute —
   and a linear axis renders every fast engine as a flat line at the bottom, so
   `log` is the default and `niceLin` exists for the one question a log axis
   cannot answer ("how much of the total is this?").

   Three details that look like bugs and are not:

     - a bar with no measurement still renders, 9px wide and transparent, so a
       group keeps its slots and the engines stay in the same order across
       queries (:700);
     - a value below the log floor is clamped to it rather than dropped, and a
       bar under 0.8% of the height gets a 2px minimum, so "fast" never
       disappears into the axis line (:692, :702);
     - the whole chart is one horizontal scroller sized from the engine and
       query counts, not a squeeze — 92 queries × 9 engines does not fit in a
       column and the original never pretended it did (:694, :707). */

import type { ReactNode } from 'react';
import { engineColor, type EngineRow } from '../../entities/results';
import { fmtSec } from '../../shared/lib/format';
import { metricValue } from '../../shared/lib/metrics';
import { niceLin, niceLog } from '../../shared/lib/scale';
import type { Metric } from '../../shared/model';

export interface QueryLatencyChartProps {
  /** Visible engines, in column order — `orderedVisible(...)`. */
  engines: EngineRow[];
  /** Visible query ids — `visibleQIDS(state.activeQTasks)`. */
  ids: readonly string[];
  metric: Metric;
  /** `state.scale === 'log'`. */
  log: boolean;
}

export function QueryLatencyChart({
  engines,
  ids,
  metric,
  log,
}: QueryLatencyChartProps): ReactNode {
  let min = Infinity;
  let max = -Infinity;
  for (const id of ids) {
    for (const r of engines) {
      const v = metricValue(r, id, metric);
      if (typeof v === 'number' && v > 0) {
        min = Math.min(min, v);
        max = Math.max(max, v);
      }
    }
  }

  if (!isFinite(min)) {
    return (
      <div style={{ fontSize: 12.5, color: 'var(--mut)' }}>
        No timing data for the selected engines.
      </div>
    );
  }

  const sc = log ? niceLog(min, max) : niceLin(max);
  const floor = log ? sc.lo : 0;
  const pos = (v: number) => {
    const vv = Math.max(v, floor);
    return log
      ? (Math.log10(vv) - Math.log10(sc.lo)) / (Math.log10(sc.hi) - Math.log10(sc.lo))
      : vv / sc.hi;
  };
  const ticks = sc.ticks.map((t) => ({ y: (pos(t) * 100).toFixed(2), label: fmtSec(t) }));
  const chartMinW = 60 + ids.length * (engines.length * 11 + 16) + 'px';

  return (
    <div style={{ overflowX: 'auto', paddingBottom: 6 }}>
      <div style={{ minWidth: chartMinW }}>
        <div style={{ display: 'flex' }}>
          <div style={{ width: 52, position: 'relative', height: 240, flexShrink: 0 }}>
            {ticks.map((t, i) => (
              <div
                key={i}
                style={{
                  position: 'absolute',
                  right: 8,
                  bottom: `calc(${t.y}% - 5px)`,
                  fontSize: 10,
                  color: 'var(--mut)',
                }}
              >
                {t.label}
              </div>
            ))}
          </div>
          <div
            style={{
              flex: 1,
              position: 'relative',
              height: 240,
              borderLeft: '.5px solid var(--line)',
              borderBottom: '.5px solid var(--line)',
            }}
          >
            {ticks.map((t, i) => (
              <div
                key={i}
                style={{
                  position: 'absolute',
                  left: 0,
                  right: 0,
                  bottom: `${t.y}%`,
                  borderTop: '1px solid var(--line2)',
                }}
              />
            ))}
            <div style={{ position: 'absolute', inset: 0, display: 'flex' }}>
              {ids.map((id) => (
                <div
                  key={id}
                  style={{
                    flex: 1,
                    display: 'flex',
                    alignItems: 'flex-end',
                    justifyContent: 'center',
                    gap: 2,
                    padding: '0 3px',
                  }}
                >
                  {engines.map((e) => {
                    const v = metricValue(e, id, metric);
                    if (typeof v !== 'number') {
                      return (
                        <div
                          key={e.system}
                          title={`${e.system} · ${id}: —`}
                          style={{ width: 9, height: '0%', background: 'transparent' }}
                        />
                      );
                    }
                    const p = Math.max(0, pos(v));
                    return (
                      <div
                        key={e.system}
                        title={`${e.system} · ${id}: ${fmtSec(v)} s`}
                        style={{
                          width: 9,
                          height: (p * 100).toFixed(2) + '%',
                          minHeight: p < 0.008 ? '2px' : '0',
                          background: engineColor(e.system),
                        }}
                      />
                    );
                  })}
                </div>
              ))}
            </div>
          </div>
        </div>
        <div style={{ display: 'flex', marginLeft: 52 }}>
          {ids.map((id) => (
            <div
              key={id}
              style={{ flex: 1, textAlign: 'center', fontSize: 10, color: 'var(--mut)', paddingTop: 4 }}
            >
              {id}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
