/* The charts view behind the Charts tab. ui/index.html:678-761 (`renderCharts`).

   Same panel as the results table, same head, same ⛶ button — what changes is
   the body: the engine legend, the per-query column chart, and the two
   horizontal bar lists for the scalars a benchmark row also carries (load time,
   on-disk size). Everything is a function of the engines the sidebar left
   visible and the queries the category filter left visible, so the charts and
   the table always describe the same selection.

   Two things this component does NOT own, and did not own in the standalone:

     - the Log/Linear switch. It is a `segRow` in the sidebar's config panel
       (ui/index.html:502), rendered only while the Charts tab is up, and it
       dispatches `{type:'scale'}`. This widget is the consumer of `state.scale`
       — both branches of it are here, and nothing else on the page reads the
       field.
     - the Table/Charts switch itself (ui/index.html:499), which is why there is
       no tab bar in this file: `BenchPage` picks the widget.

   Colours come from `engineColor`, never from the palette directly, so an
   engine is the same colour in the legend, the columns, the bars, the
   participants list and the table.  */

import type { Dispatch, ReactNode } from 'react';
import { NQ, engineColor, rowsFor, type EngineRow } from '../../entities/results';
import { fmtBytes, fmtSec } from '../../shared/lib/format';
import type { BenchAction, BenchState } from '../../shared/model';
import { MaxButton, Panel } from '../../shared/ui';
import { HBars } from './HBars';
import { QueryLatencyChart } from './QueryLatencyChart';

export interface ChartsPanelProps {
  /** The resolved dataset — `curDataset(state.dataset, DATASETS)`. */
  ds: string;
  /** Visible engines, in column order — `orderedVisible(...)`. */
  engines: EngineRow[];
  /** Visible query ids — `visibleQIDS(state.activeQTasks)`. */
  ids: readonly string[];
  state: BenchState;
  dispatch: Dispatch<BenchAction>;
}

export function ChartsPanel({ ds, engines, ids, state, dispatch }: ChartsPanelProps): ReactNode {
  const log = state.scale === 'log';

  /* ui/index.html:734-737. The same three lines open `renderTable` (:666-668);
     they are duplicated there in the standalone too, and copying them is the
     smaller sin — the string is a caption, not a model. */
  const shown = engines.length;
  const total = rowsFor(ds).length;
  const vqN = ids.length;
  const metaText = `${ds} · ${shown === total ? total + ' engines' : shown + ' of ' + total + ' engines'} · ${vqN === NQ ? NQ + ' queries' : vqN + ' of ' + NQ + ' queries'} × 3 runs`;
  const caption = `${metaText} · ${state.metric} run · ${state.scale} scale`;

  return (
    <Panel grow style={{ flex: 1, minHeight: 0, display: 'flex' }}>
      <div className="ph" style={{ padding: '6px 12px' }}>
        <span className="pr">&gt;</span>
        <span className="pt">charts</span>
        <span className="note" style={{ marginLeft: 'auto', fontSize: 11 }}>
          {caption}
        </span>
        <MaxButton state={state} dispatch={dispatch} />
      </div>

      <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '12px 14px' }}>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 12 }}>
          {engines.map((e) => (
            <span
              key={e.system}
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                gap: 5,
                fontSize: 11,
                color: 'var(--mut)',
              }}
            >
              <span className="swatch" style={{ background: engineColor(e.system) }} />
              {e.system}
            </span>
          ))}
        </div>

        <div style={{ fontSize: 12.5, fontWeight: 700, marginBottom: 2 }}>per-query latency</div>
        <div style={{ fontSize: 11, color: 'var(--mut)', marginBottom: 8 }}>
          seconds · lower is better · 0.000 = sub-ms
        </div>
        <QueryLatencyChart engines={engines} ids={ids} metric={state.metric} log={log} />

        <div
          style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24, marginTop: 18 }}
        >
          <div>
            <div style={{ fontSize: 12.5, fontWeight: 700, marginBottom: 2 }}>load time</div>
            <div style={{ fontSize: 11, color: 'var(--mut)', marginBottom: 8 }}>
              seconds to ingest + index · lower is better
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
              <HBars
                engines={engines}
                log={log}
                valueOf={(r) => r.load_time}
                fmt={(v) => fmtSec(v) + ' s'}
              />
            </div>
          </div>
          <div>
            <div style={{ fontSize: 12.5, fontWeight: 700, marginBottom: 2 }}>on-disk size</div>
            <div style={{ fontSize: 11, color: 'var(--mut)', marginBottom: 8 }}>
              data + index footprint · lower is better
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
              <HBars
                engines={engines}
                log={log}
                valueOf={(r) => r.data_size}
                fmt={(v) => fmtBytes(v)}
              />
            </div>
          </div>
        </div>
      </div>
    </Panel>
  );
}
