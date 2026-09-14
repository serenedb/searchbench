/* The results grid behind the Table tab — ui/index.html:597-675 (`renderTable`),
   assembled from the pieces around it.

   `renderTable` was one function that produced one string: the column template,
   the header, every row, the section dividers between them and the legend. Here
   it is the container: it owns the numbers the whole grid shares and hands each
   piece the slice it draws.

     gridCols  one `grid-template-columns` for the header and every row, so the
               columns line up — they are separate grids, not one table
               (ui/index.html:598-599). The 196px label column and the 6.6px
               per-character estimate are the original's, and they decide where
               the horizontal scrollbar starts, so they are copied, not tuned.
     geo       `geomeanMap` once for the table (ui/index.html:616) rather than
               once per row: it is O(engines × queries), and the Geomean row
               would otherwise recompute it for every cell.
     rows      `metricRows` — three summary rows and the per-query block, the
               latter already re-sorted if an engine column is the sort key.

   The section divider is drawn here rather than inside `TableRow` because it is
   a sibling of the row, not part of it: the original emitted it just before the
   `.trow` (ui/index.html:619) and `.section` is a full-width band across the
   scroll area. A row carries the caption; the row that carries one gets a band
   above it.

   Two clicks and a drop leave this component, all three straight to the reducer:

     row label   → `sortrow`  sort the engine columns by this row (asc/desc)
     cell        → `cell`     select engine × query; the query panel reads it
     column drop → `reorder`  the finished order, computed here

   `reorder` is the only one that is not a plain forward. `TableHead` reports
   which column was dropped on which, and the order is built the way the drop
   handler built it (ui/index.html:968-973): over `universeOrder`, the order of
   every engine in the dataset including the hidden ones, so dragging a column
   while an engine is switched off does not move that engine when it comes back. */

import { Fragment, useMemo, type Dispatch, type ReactNode } from 'react';
import { NQ, rowsFor, type EngineRow } from '../../entities/results';
import { geomeanMap } from '../../shared/lib/metrics';
import { universeOrder } from '../../shared/lib/ranking';
import type { BenchAction, BenchState } from '../../shared/model';
import { MaxButton, Panel } from '../../shared/ui';
import { TableHead } from './TableHead';
import { TableLegend } from './TableLegend';
import { TableRow } from './TableRow';
import { metricRows } from './model/metricRows';

export interface ResultsTableProps {
  /** The resolved dataset — `curDataset(state.dataset, DATASETS)`. */
  ds: string;
  /** Visible engines, in column order — `orderedVisible(...)`. */
  engines: EngineRow[];
  /** Visible query ids — `visibleQIDS(state.activeQTasks)`. */
  ids: readonly string[];
  state: BenchState;
  dispatch: Dispatch<BenchAction>;
}

/** ui/index.html:598 — name length in characters, clamped to 62…184px. */
function colW(e: EngineRow): number {
  return Math.min(184, Math.max(62, Math.round((e.system || '').length * 6.6) + 46));
}

export function ResultsTable({ ds, engines, ids, state, dispatch }: ResultsTableProps): ReactNode {
  const gridCols = '196px ' + engines.map((e) => colW(e) + 'px').join(' ');

  const geo = useMemo(() => geomeanMap(engines, ids, state.metric), [engines, ids, state.metric]);
  const rows = useMemo(() => metricRows(ds, engines, ids, state), [ds, engines, ids, state]);

  /* ui/index.html:666-668. `renderCharts` prints the same caption from the same
     three lines (:734-737); both copy it, as the standalone did. */
  const shown = engines.length;
  const total = rowsFor(ds).length;
  const vqN = ids.length;
  const metaText = `${ds} · ${shown === total ? total + ' engines' : shown + ' of ' + total + ' engines'} · ${vqN === NQ ? NQ + ' queries' : vqN + ' of ' + NQ + ' queries'} × 3 runs`;

  const handleReorder = (dragged: string, target: string) => {
    const order = universeOrder(rowsFor(ds), ids, state).filter((s) => s !== dragged);
    const ti = order.indexOf(target);
    order.splice(ti < 0 ? order.length : ti, 0, dragged);
    dispatch({ type: 'reorder', order });
  };

  return (
    <Panel grow style={{ flex: 1, minHeight: 0, display: 'flex' }}>
      <div className="ph" style={{ padding: '6px 12px' }}>
        <span className="pr">&gt;</span>
        <span className="pt">results</span>
        <span className="note" style={{ marginLeft: 'auto', fontSize: 11 }}>
          {metaText}
        </span>
        <MaxButton state={state} dispatch={dispatch} />
      </div>

      <div className="tscroll" id="tscroll">
        <TableHead
          engines={engines}
          gridCols={gridCols}
          sortByEngine={state.sortByEngine}
          sortByEngineDir={state.sortByEngineDir}
          onSort={(sys) => dispatch({ type: 'engsort', sys })}
          onReorder={handleReorder}
        />
        {rows.map((row) => (
          <Fragment key={row.key}>
            {row.section && (
              <div className="section">
                <span>{row.section}</span>
              </div>
            )}
            <TableRow
              row={row}
              engines={engines}
              gridCols={gridCols}
              geo={geo}
              metric={state.metric}
              valueMode={state.valueMode}
              sortRow={state.sortRow}
              sortDir={state.sortDir}
              sel={state.sel}
              onSortRow={(key) => dispatch({ type: 'sortrow', key })}
              onSelect={(sys, id) => dispatch({ type: 'cell', sys, id })}
            />
          </Fragment>
        ))}
      </div>

      <TableLegend metric={state.metric} valueMode={state.valueMode} sortRow={state.sortRow} />
    </Panel>
  );
}
