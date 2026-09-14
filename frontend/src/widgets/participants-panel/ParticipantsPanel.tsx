/* The engine list and its visibility toggles — ui/index.html:536-553.
 *
 * The one panel that grows: it takes whatever height the three above it leave
 * and scrolls, because the engine count is data and the other three panels have
 * a fixed number of rows.
 *
 * Rows are in `universeOrder`, not `orderedVisible` — the same sort as the
 * table's columns but over *every* engine in the dataset, hidden ones included.
 * That is the point: an engine you switch off has to stay where it was, or the
 * list reshuffles under the pointer and the next click lands on a neighbour.
 * Hidden rows dim to 0.4, strike the name through and say so on the right.
 *
 * Two guards travel with the clicks, both computed here because the reducer
 * cannot see the data:
 *
 *   - `visibleCount` is how many engines are shown *before* the click, and the
 *     reducer refuses to hide the last one (ui/index.html:915-917). Every ratio
 *     on the page is against the fastest visible engine, so an empty table is
 *     not a sparser view of the benchmark, it is a table of nothing.
 *   - `present` for "select all" is the list the original's handler built at
 *     :923 — `universeOrder` filtered by presence in the dataset and *not* by
 *     the engine-tag filter, unlike the `present` that renders the rows below.
 *     The two coincide today (`activeTags` is always empty: the standalone
 *     never shipped the UI for it, and the codec never encoded it), and they
 *     are kept apart anyway so that the day a tag filter exists, "select all"
 *     still means what it meant — every engine, not every visible engine.
 */

import type { Dispatch } from 'react';
import { engineColor, rowsFor } from '../../entities/results';
import { universeOrder } from '../../shared/lib/ranking';
import { passesTagFilter } from '../../shared/lib/rows';
import type { BenchAction, BenchState } from '../../shared/model';
import { Panel } from '../../shared/ui/Panel';

export function ParticipantsPanel({
  ds,
  ids,
  state,
  dispatch,
}: {
  ds: string | null;
  /** The visible query ids — `visibleQIDS(state.activeQTasks)`. Both the
      default order and a geomean sort are computed over exactly these, so the
      list re-ranks with the query filter. */
  ids: readonly string[];
  state: BenchState;
  dispatch: Dispatch<BenchAction>;
}) {
  const rows = rowsFor(ds);
  const order = universeOrder(rows, ids, state);
  // A Map, not `Object.fromEntries`: a system named "constructor" would be
  // truthy on a plain object without ever being in the dataset.
  const bySys = new Map(rows.map((r) => [r.system, r]));

  const present = order.filter((s) => {
    const row = bySys.get(s);
    return !!row && passesTagFilter(row, state.activeTags);
  });
  const allSelected = present.length > 0 && !present.some((s) => state.hidden.has(s));

  /** ui/index.html:923 — the handler's own list, without the tag filter. */
  const togglePresent = order.filter((s) => bySys.has(s));
  /** ui/index.html:915 — engines on screen right now. */
  const visibleCount = rows.filter(
    (r) => !state.hidden.has(r.system) && passesTagFilter(r, state.activeTags),
  ).length;

  return (
    <Panel grow style={{ flex: 1, minHeight: 0, display: 'flex' }}>
      <div className="ph">
        <span className="pr">&gt;</span>
        <span className="pt">participants</span>
        {present.length > 0 && (
          <button
            className="link"
            style={{ marginLeft: 'auto' }}
            data-act="toggle-all"
            onClick={() => dispatch({ type: 'toggle-all', present: togglePresent })}
          >
            {allSelected ? 'unselect all' : 'select all'}
          </button>
        )}
      </div>
      {/* The id is the original's. It was there for scroll restoration across
          the innerHTML swap (:877-878), which React makes unnecessary — the
          node survives a re-render — but it is part of the DOM the page
          published, and nothing costs less than leaving it. */}
      <div
        id="partscroll"
        style={{
          flex: 1,
          minHeight: 0,
          overflowY: 'auto',
          padding: 6,
          display: 'flex',
          flexDirection: 'column',
          gap: 1,
        }}
      >
        {present.map((s) => {
          const off = state.hidden.has(s);
          return (
            <button
              key={s}
              className="prow"
              data-act="part"
              data-sys={s}
              title="click to show / hide"
              style={{ opacity: off ? 0.4 : 1 }}
              onClick={() => dispatch({ type: 'part', sys: s, visibleCount })}
            >
              <span className="swatch" style={{ background: engineColor(s) }} />
              <span
                style={{
                  flex: 1,
                  fontSize: '12.5px',
                  fontWeight: 600,
                  color: 'var(--fg)',
                  textDecoration: off ? 'line-through' : 'none',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                }}
              >
                {s}
              </span>
              {/* Empty when shown, and still rendered: `.prow` is a flex row
                  with `gap: 8px`, so dropping it would pull the name 8px right
                  on every visible engine. */}
              <span style={{ fontSize: 10, color: 'var(--mut)' }}>{off ? 'hidden' : ''}</span>
            </button>
          );
        })}
      </div>
    </Panel>
  );
}
