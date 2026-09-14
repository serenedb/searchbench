/* The four view switches — ui/index.html:497-506.
 *
 * Two rows are always there (view, run) and the third depends on the first:
 * "cells" only means something for a table of numbers, "scale" only for a
 * chart's axis. The original branched on `isTable` / `isCharts` and so does
 * this; the row count changing with the tab is why the panel has no fixed
 * height.
 *
 * "Cold" is offered on every dataset: the harness now records an honest cold run
 * at 1B too, so there is nothing left to disable.
 */

import type { Dispatch } from 'react';
import type { BenchAction, BenchState, Metric, Scale, Tab, ValueMode } from '../../shared/model';
import { Panel } from '../../shared/ui/Panel';
import { SegRow, type SegOption } from '../../shared/ui/Segmented';

const VIEW: readonly SegOption<Tab>[] = [
  { label: 'Table', v: 'table' },
  { label: 'Charts', v: 'charts' },
];
const RUN: readonly SegOption<Metric>[] = [
  { label: 'Cold', v: 'cold' },
  { label: 'Hot', v: 'hot' },
];
const CELLS: readonly SegOption<ValueMode>[] = [
  { label: 'Relative', v: 'relative' },
  { label: 'Seconds', v: 'sec' },
  { label: 'Millis', v: 'ms' },
];
const SCALE: readonly SegOption<Scale>[] = [
  { label: 'Log', v: 'log' },
  { label: 'Linear', v: 'linear' },
];

export function ConfigPanel({
  state,
  dispatch,
}: {
  state: BenchState;
  dispatch: Dispatch<BenchAction>;
}) {
  const isTable = state.tab === 'table';
  const isCharts = state.tab === 'charts';

  return (
    <Panel>
      <div className="ph">
        <span className="pr">&gt;</span>
        <span className="pt">config</span>
        <span className="note" style={{ marginLeft: 'auto' }}>
          cold = after cache drop
        </span>
      </div>
      <div style={{ padding: 9, display: 'flex', flexDirection: 'column', gap: 9 }}>
        <SegRow
          label="view"
          act="tab"
          opts={VIEW}
          cur={state.tab}
          flex
          onPick={(value) => dispatch({ type: 'tab', value })}
        />
        <SegRow
          label="run"
          act="metric"
          opts={RUN}
          cur={state.metric}
          flex
          onPick={(value) => dispatch({ type: 'metric', value })}
        />
        {/* Three labels in a 300px column, hence the tighter padding and the
            half-pixel-smaller face — the original's own numbers. */}
        {isTable && (
          <SegRow
            label="cells"
            act="cells"
            opts={CELLS}
            cur={state.valueMode}
            flex
            pad="4px 2px"
            fs="10.5px"
            onPick={(value) => dispatch({ type: 'cells', value })}
          />
        )}
        {isCharts && (
          <SegRow
            label="scale"
            act="scale"
            opts={SCALE}
            cur={state.scale}
            flex
            onPick={(value) => dispatch({ type: 'scale', value })}
          />
        )}
      </div>
    </Panel>
  );
}
