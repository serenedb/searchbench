/* One row of the grid: the sticky label button and one cell per engine.
   ui/index.html:618-654 — the body of the `for (const row of metricRows(...))`
   loop, minus the section divider, which the parent draws above the row that
   carries it.

   The two things worth reading twice, because both are easy to "clean up" into
   something that renders differently:

   1. `best` is the row's own minimum, and what counts as a candidate depends on
      the row. A query row takes any number (a 0.000 s answer is a real answer);
      a summary row takes only positives, because a missing load time is
      recorded as 0 and would otherwise become the engine everything is measured
      against. ui/index.html:621-626.

   2. The colour is `ratioBg(ratio)` with a *hardcoded* `#06223f` on top of it —
      not `var(--fg)`. The scale is the same green→red ramp in both themes, so
      the text on it is the same near-black in both themes. A timeout replaces
      both with #000 on #fff and prefixes the value with 💀. */

import type { ReactNode } from 'react';
import type { EngineRow } from '../../entities/results';
import { fmtMs, fmtRatio, fmtSec, ratioBg } from '../../shared/lib/format';
import { TIMEOUT_CAP, isTimeout, metricValue, ratioOf } from '../../shared/lib/metrics';
import type { CellSelection, Metric, SortDir, ValueMode } from '../../shared/model';
import type { MetricRow } from './model/metricRows';

export interface TableRowProps {
  row: MetricRow;
  /** Visible engines, in column order. */
  engines: EngineRow[];
  gridCols: string;
  /** `geomeanMap(engines, ids, metric)` — computed once for the whole table. */
  geo: Map<string, number | null>;
  metric: Metric;
  valueMode: ValueMode;
  sortRow: string;
  sortDir: SortDir;
  sel: CellSelection | null;
  onSortRow: (key: string) => void;
  onSelect: (sys: string, id: string) => void;
}

/** The number this row shows for this engine, before any formatting. */
function valueOf(
  row: MetricRow,
  e: EngineRow,
  geo: Map<string, number | null>,
  metric: Metric,
): number | null | undefined {
  if (row.kind === 'geomean') return geo.get(e.system);
  if (row.kind === 'query') return metricValue(e, row.id, metric);
  return row.get(e);
}

export function TableRow({
  row,
  engines,
  gridCols,
  geo,
  metric,
  valueMode,
  sortRow,
  sortDir,
  sel,
  onSortRow,
  onSelect,
}: TableRowProps): ReactNode {
  const isQuery = row.kind === 'query';

  let bestRaw = Infinity;
  for (const e of engines) {
    const v = valueOf(row, e, geo, metric);
    if (typeof v === 'number' && (isQuery || v > 0)) bestRaw = Math.min(bestRaw, v);
  }
  const best: number | null = isFinite(bestRaw) ? bestRaw : null;

  const mark = sortRow === row.key ? (sortDir === 1 ? '▲' : '▼') : '';
  const labColor = sortRow === row.key ? 'var(--accent)' : 'var(--fg)';
  const tagText =
    row.kind === 'query' && row.tag
      ? [row.tag.task, row.tag.filter, row.tag.freq].filter(Boolean).join(' · ')
      : '';

  return (
    <div className="trow" style={{ gridTemplateColumns: gridCols }}>
      <button
        className="rowlab"
        data-act="sortrow"
        data-key={row.key}
        title="sort engines by this row"
        style={{ color: labColor }}
        onClick={() => onSortRow(row.key)}
      >
        {row.label}
        <span className="mk">{mark}</span>
        {tagText ? <span className="tg">{tagText}</span> : null}
      </button>

      {engines.map((e) => {
        const raw = valueOf(row, e, geo, metric);
        const missing = isQuery ? typeof raw !== 'number' : !(typeof raw === 'number' && raw > 0);
        if (missing) {
          return (
            <div
              key={e.system}
              className="cell"
              style={{ background: 'var(--na)', color: 'var(--mut)' }}
              title="no result recorded"
            >
              —
            </div>
          );
        }
        const v = raw as number;
        const ratio = isQuery ? ratioOf(v, best) : best ? v / best : 1;
        const timedOut = isQuery && isTimeout(v);
        const text =
          row.kind === 'geomean'
            ? fmtRatio(v)
            : row.kind === 'query'
              ? valueMode === 'relative'
                ? fmtRatio(ratio)
                : valueMode === 'ms'
                  ? fmtMs(v)
                  : fmtSec(v)
              : row.fmt(v);
        const isSel =
          row.kind === 'query' && sel !== null && sel.sys === e.system && sel.id === row.id;
        const tip = timedOut
          ? `timed out — killed at the ${TIMEOUT_CAP}s cap — click for query`
          : isQuery
            ? `${fmtSec(v)} s · ${fmtRatio(ratio)} — click for query`
            : best
              ? fmtRatio(v / best)
              : '';
        return (
          <div
            key={e.system}
            className={isQuery ? 'cell q' : 'cell'}
            {...(row.kind === 'query'
              ? {
                  'data-act': 'cell',
                  'data-sys': e.system,
                  'data-id': row.id,
                  onClick: () => onSelect(e.system, row.id),
                }
              : null)}
            title={tip}
            style={{
              background: timedOut ? '#000000' : ratioBg(ratio),
              color: timedOut ? '#ffffff' : '#06223f',
              ...(isSel ? { boxShadow: 'inset 0 0 0 2px var(--accent)' } : null),
            }}
          >
            {timedOut ? '💀 ' + text : text}
          </div>
        );
      })}
    </div>
  );
}
