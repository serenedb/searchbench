import { useMemo } from 'react';
import { DATASETS, SYSTEMS, qTasksFor, rowsFor, visibleQIDS } from '../../entities/results';
import { orderedVisible } from '../../shared/lib/ranking';
import {
  curDataset,
  isPanelHidden,
  useBenchShortcuts,
  useBenchState,
  type BenchEnv,
} from '../../shared/model';
import { ExplainModal } from '../../widgets/query-panel/ExplainModal';
import { QueryPanel } from '../../widgets/query-panel/QueryPanel';
import { queryPanelData } from '../../widgets/query-panel/queryPanelData';
import { CategoriesPanel } from '../../widgets/categories-panel/CategoriesPanel';
import { ChartsPanel } from '../../widgets/charts';
import { ConfigPanel } from '../../widgets/config-panel/ConfigPanel';
import { DatasetPanel } from '../../widgets/dataset-panel/DatasetPanel';
import { BenchHeader } from '../../widgets/header/BenchHeader';
import { ParticipantsPanel } from '../../widgets/participants-panel/ParticipantsPanel';
import { ResultsTable } from '../../widgets/results-table';

/**
 * The page frame — ui/index.html's `render()` (:839-879), with the panels left
 * as slots.
 *
 * This is the whole of the layout and none of the content: the grid, the two
 * columns, the gaps and the one element that used to be `#app`. Each slot names
 * the widget that replaces it and the lines of the standalone it is ported
 * from. The state, the selectors and the ordering are already live, so a widget
 * is a pure function of `state` + `engines` + `ids` and nothing here has to
 * change to accept one.
 *
 * Not yet ported, and deliberately: the scroll-position preservation around the
 * innerHTML swap (:844-878), which React makes unnecessary for everything
 * except `#tscroll`'s horizontal offset when the column order changes.
 */
export function BenchPage() {
  // Stable for the lifetime of the page: results.json is a build input.
  const env = useMemo<BenchEnv>(
    () => ({
      datasets: DATASETS,
      systems: SYSTEMS,
      qTasks: qTasksFor(),
    }),
    [],
  );

  const [state, dispatch] = useBenchState(env);
  // The page's whole keyboard surface: Escape closes the explain overlay
  // (:984-986). Bound on window, above the `!ds` return, as `wire()` was.
  useBenchShortcuts(state, dispatch);

  const ds = curDataset(state.dataset, DATASETS);
  const ids = useMemo(() => visibleQIDS(state.activeQTasks), [state.activeQTasks]);
  const engines = useMemo(() => orderedVisible(rowsFor(ds), ids, state), [ds, ids, state]);

  if (!ds) {
    return (
      <div className="sb-app">
        {!isPanelHidden(state, 'header') && <BenchHeader />}
        <div
          style={{
            flex: 1,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            color: 'var(--mut)',
            fontSize: 13,
          }}
        >
          No results found. Run an engine benchmark, then
          <code style={{ margin: '0 5px' }}>./frontend/build_results</code>.
        </div>
      </div>
    );
  }

  const showSidebar =
    !state.max &&
    (['dataset', 'config', 'categories', 'participants'] as const).some(
      (id) => !isPanelHidden(state, id),
    );
  const showQueryPanel = !state.max && !isPanelHidden(state, 'query');
  // Computed once and handed to both consumers, as `render()` did (:863, :870).
  // Unconditionally: `max` and `?hide=query` drop the panel, not the overlay.
  const qp = queryPanelData(ds, state);

  return (
    <div className="sb-app">
      {/* `let html = isPanelHidden("header") ? "" : renderHeader()` (:854) —
          before the `!ds` return there as here, and droppable by `?hide=` like
          every other panel. */}
      {!isPanelHidden(state, 'header') && <BenchHeader />}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: showSidebar ? '300px 1fr' : '1fr',
          columnGap: 14,
          flex: 1,
          minHeight: 0,
        }}
      >
        {showSidebar && (
          <aside
            style={{
              display: 'flex',
              flexDirection: 'column',
              gap: 11,
              minHeight: 0,
              minWidth: 0,
            }}
          >
            {/* `renderSidebar`'s panel list (:555-560): rendered in this order
                whatever order they were built in, each one droppable by
                `?hide=`. The `<aside>` above is the same function's wrapper. */}
            {!isPanelHidden(state, 'dataset') && <DatasetPanel ds={ds} dispatch={dispatch} />}
            {!isPanelHidden(state, 'config') && (
              <ConfigPanel state={state} dispatch={dispatch} />
            )}
            {!isPanelHidden(state, 'categories') && (
              <CategoriesPanel state={state} dispatch={dispatch} />
            )}
            {!isPanelHidden(state, 'participants') && (
              <ParticipantsPanel ds={ds} ids={ids} state={state} dispatch={dispatch} />
            )}
          </aside>
        )}

        <main
          style={{
            display: 'flex',
            flexDirection: 'column',
            gap: 11,
            minWidth: 0,
            minHeight: 0,
          }}
        >
          {state.tab === 'table' ? (
            <ResultsTable ds={ds} engines={engines} ids={ids} state={state} dispatch={dispatch} />
          ) : (
            <ChartsPanel ds={ds} engines={engines} ids={ids} state={state} dispatch={dispatch} />
          )}
          {showQueryPanel && <QueryPanel qp={qp} dispatch={dispatch} />}
        </main>
      </div>

      {/* `html += renderExplain(qp)` (:871) — a sibling of the grid, not a
          child of the query panel: it is `position:fixed`, and it stays open
          when `max` hides the panel that opened it. */}
      <ExplainModal qp={qp} open={state.explainOpen} dispatch={dispatch} />
    </div>
  );
}
