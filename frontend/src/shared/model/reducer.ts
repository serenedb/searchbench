/* Every transition the page has — ui/index.html:894-982's `data-act` switch,
   one action per case.

   The original mutated the global `state` in place and called `render()`. Here
   the reducer is pure, so two rules follow: Sets and arrays are replaced rather
   than mutated (React compares references), and any guard the original computed
   at click time from the data travels in the action payload. That keeps
   shared/model free of an upward import into entities/results while the guards
   stay exactly where they were — `part` still refuses to hide the last engine.

   Two cases are deliberately absent:
     - `theme`, which the platform owns now (see state.ts);
     - the drag bookkeeping, which is transient DOM state: the column header
       widget keeps `dragSys` in a ref, swallows the click that ends a drag as
       the original did, and dispatches the finished order as `reorder`. */

import type { BenchState, Metric, PanelId, Scale, SortDir, Tab, ValueMode } from './state';

export type BenchAction =
  | { type: 'tab'; value: Tab }
  | { type: 'metric'; value: Metric }
  | { type: 'cells'; value: ValueMode }
  | { type: 'scale'; value: Scale }
  | { type: 'dataset'; name: string }
  | { type: 'qtask'; task: string }
  | { type: 'clear-qtasks' }
  /** `visibleCount`: engines visible *before* this click; hiding the last is refused. */
  | { type: 'part'; sys: string; visibleCount: number }
  /** `present`: every system in the current dataset, `universeOrder(...)`. */
  | { type: 'toggle-all'; present: readonly string[] }
  | { type: 'max' }
  | { type: 'sortrow'; key: string }
  | { type: 'engsort'; sys: string }
  | { type: 'cell'; sys: string; id: string }
  | { type: 'qp-close' }
  | { type: 'explain-open' }
  | { type: 'explain-close' }
  /** The finished column order from a drop. Clears the row sort, as the original did. */
  | { type: 'reorder'; order: string[] }
  | { type: 'panels'; hidden: ReadonlySet<PanelId> };

function toggled(set: ReadonlySet<string>, value: string): Set<string> {
  const next = new Set(set);
  if (next.has(value)) next.delete(value);
  else next.add(value);
  return next;
}

export function benchReducer(state: BenchState, action: BenchAction): BenchState {
  switch (action.type) {
    case 'tab':
      return { ...state, tab: action.value };

    case 'metric':
      return { ...state, metric: action.value };

    case 'cells':
      return { ...state, valueMode: action.value };

    case 'scale':
      return { ...state, scale: action.value };

    case 'dataset':
      return {
        ...state,
        dataset: action.name,
        // The selection names an engine × query in the old dataset; keeping it
        // would show another engine's query text under the same title.
        sel: null,
        explainOpen: false,
      };

    case 'qtask':
      return { ...state, activeQTasks: toggled(state.activeQTasks, action.task) };

    case 'clear-qtasks':
      return { ...state, activeQTasks: new Set() };

    case 'part': {
      if (state.hidden.has(action.sys)) {
        const next = new Set(state.hidden);
        next.delete(action.sys);
        return { ...state, hidden: next };
      }
      // Keep at least one engine shown: an empty table is not a view of a
      // benchmark, and every ratio in it is against nothing.
      if (action.visibleCount <= 1) return state;
      const next = new Set(state.hidden);
      next.add(action.sys);
      return { ...state, hidden: next };
    }

    case 'toggle-all': {
      const present = action.present;
      const allSelected = present.length > 0 && !present.some((s) => state.hidden.has(s));
      const next = new Set(state.hidden);
      // Systems hidden in another dataset stay hidden — `next` is not rebuilt.
      if (allSelected) present.forEach((s) => next.add(s));
      else present.forEach((s) => next.delete(s));
      return { ...state, hidden: next };
    }

    case 'max':
      return { ...state, max: !state.max };

    case 'sortrow': {
      const same = state.sortRow === action.key;
      return {
        ...state,
        sortRow: action.key,
        sortDir: same ? ((state.sortDir * -1) as SortDir) : 1,
        // An explicit sort abandons a hand-dragged column order.
        manualOrder: null,
      };
    }

    case 'engsort':
      // Third click on the same header clears the sort rather than cycling
      // back to ascending — asc, desc, off.
      if (state.sortByEngine === action.sys) {
        return state.sortByEngineDir === 1
          ? { ...state, sortByEngineDir: -1 }
          : { ...state, sortByEngine: null, sortByEngineDir: 1 };
      }
      return { ...state, sortByEngine: action.sys, sortByEngineDir: 1 };

    case 'cell':
      return { ...state, sel: { sys: action.sys, id: action.id } };

    case 'qp-close':
      return { ...state, sel: null, explainOpen: false };

    case 'explain-open':
      return { ...state, explainOpen: true };

    case 'explain-close':
      return { ...state, explainOpen: false };

    case 'reorder':
      return { ...state, manualOrder: action.order, sortRow: '' };

    case 'panels':
      return { ...state, hiddenPanels: action.hidden };
  }
}
