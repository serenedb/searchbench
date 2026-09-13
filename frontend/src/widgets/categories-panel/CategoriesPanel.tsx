/* The query-category chips — ui/index.html:526-534.
 *
 * Each chip is one `query_tags[].task`, and switching one on narrows the query
 * set everything downstream is computed over: the table's rows, the charts, and
 * — the part worth saying out loud, which is why the chip carries a title —
 * the geomean, which is a mean over the *visible* queries and therefore a
 * different number under a filter.
 *
 * "clear" only appears once something is on, so the head does not carry a dead
 * control in the default view.
 *
 * One line of the original is deliberately not here: `:528` pruned
 * `state.activeQTasks` of tasks the data no longer has, in the middle of
 * rendering. Nothing can put such a task in the set any more — `restoreUrlState`
 * filters `?q=` through `qTasksFor()` and the only other writer is a chip
 * below, which by construction is one of them — and a render that mutates state
 * is exactly what React re-runs itself over.
 */

import type { Dispatch } from 'react';
import { qTasksFor } from '../../entities/results';
import type { BenchAction, BenchState } from '../../shared/model';
import { Panel } from '../../shared/ui/Panel';

export function CategoriesPanel({
  state,
  dispatch,
}: {
  state: BenchState;
  dispatch: Dispatch<BenchAction>;
}) {
  const allTasks = qTasksFor();

  return (
    <Panel>
      <div className="ph">
        <span className="pr">&gt;</span>
        <span className="pt">categories</span>
        <span className="note">filter queries by task</span>
        {state.activeQTasks.size > 0 && (
          <button
            className="link"
            style={{ marginLeft: 'auto' }}
            data-act="clear-qtasks"
            onClick={() => dispatch({ type: 'clear-qtasks' })}
          >
            clear
          </button>
        )}
      </div>
      <div style={{ padding: 8, display: 'flex', flexWrap: 'wrap', gap: 5 }}>
        {allTasks.length ? (
          allTasks.map((t) => (
            <button
              key={t}
              className={state.activeQTasks.has(t) ? 'chip on' : 'chip'}
              data-act="qtask"
              data-task={t}
              title="show only queries in this category — table + geomean recompute"
              onClick={() => dispatch({ type: 'qtask', task: t })}
            >
              {t}
            </button>
          ))
        ) : (
          <span className="note">no categories</span>
        )}
      </div>
    </Panel>
  );
}
