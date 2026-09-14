/* The strip under the grid — ui/index.html:656-664.

   Four swatches off the same `ratioBg` ramp the cells are painted with (1×, 2×,
   5×, 10×+), the black timeout swatch, and one sentence of footnote naming the
   run mode, the unit the cells are in, and every gesture the table answers to.

   The swatch colours are computed, not written down: `ratioBg(2)` here is the
   same call the cell makes, so the legend cannot drift from the scale. The
   timeout swatch is the literal `#000` the cell uses, and the cap in its label
   is `TIMEOUT_CAP`, the same constant `isTimeout` compares against.

   The repeated `display:inline-flex;align-items:center;gap:4px` was written out
   five times in the template literal; here it is one object used five times,
   which serialises to the identical `style` attribute. */

import type { CSSProperties, ReactNode } from 'react';
import { ratioBg } from '../../shared/lib/format';
import { TIMEOUT_CAP } from '../../shared/lib/metrics';
import { DEFAULT_SORT_ROW, type Metric, type ValueMode } from '../../shared/model';

export interface TableLegendProps {
  metric: Metric;
  valueMode: ValueMode;
  /** `state.sortRow` — the default order is the one that needs explaining. */
  sortRow: string;
}

/** ui/index.html:658 — repeated verbatim on each of the five swatch items. */
const item: CSSProperties = { display: 'inline-flex', alignItems: 'center', gap: 4 };

export function TableLegend({ metric, valueMode, sortRow }: TableLegendProps): ReactNode {
  /* Named only under the default order: every other order names itself, with
     the ▲ on the row label or the engine header it was clicked from, and this
     one has no row to put a mark on. Trailing separator, so it drops out of
     the sentence cleanly when a row sort is active. */
  const order =
    sortRow === DEFAULT_SORT_ROW
      ? 'engines by queries supported, then finished, then geomean · '
      : '';
  const unit =
    valueMode === 'relative'
      ? 'ratio to fastest'
      : valueMode === 'ms'
        ? 'absolute milliseconds'
        : 'absolute seconds';

  return (
    <div className="legend">
      <span style={item}>
        <span className="sw" style={{ background: ratioBg(1) }} />
        fastest
      </span>
      <span style={item}>
        <span className="sw" style={{ background: ratioBg(2) }} />
        2×
      </span>
      <span style={item}>
        <span className="sw" style={{ background: ratioBg(5) }} />
        5×
      </span>
      <span style={item}>
        <span className="sw" style={{ background: ratioBg(10) }} />
        10×+
      </span>
      <span style={item}>
        <span className="sw" style={{ background: '#000' }} />💀 timed out ({TIMEOUT_CAP}s cap)
      </span>
      <span>
        {metric} run · {unit} · {order}click a cell for its query · click a row label or engine
        header to sort · drag a column to reorder
      </span>
    </div>
  );
}
