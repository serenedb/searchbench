/* The one state object the page renders from — ui/index.html:182-190, minus
   `theme`.

   The standalone owned its own dark/light segmented control and kept the choice
   in `state.theme` (+ the `sb-theme` localStorage key). In the playground the
   theme is the platform's: `useTheme()` from @serenedb/ui, one toggle in the
   header for every service. Nothing else about the field survives — but the URL
   codec still reads and writes its `th` slot, because links minted by the
   standalone carry it. See url-codec.ts.

   Everything here is readonly-by-convention: the reducer replaces Sets rather
   than mutating them, so React sees a new reference. */

export type Tab = 'table' | 'charts';
export type Metric = 'cold' | 'hot';
export type ValueMode = 'relative' | 'sec' | 'ms';
export type Scale = 'log' | 'linear';
/** 1 = ascending (fastest first), -1 = descending. */
export type SortDir = 1 | -1;

/** Panels `?hide=` / `?s=…p` can switch off. ui/index.html:190. */
export type PanelId =
  | 'header'
  | 'dataset'
  | 'config'
  | 'categories'
  | 'participants'
  | 'query'
  | 'expand';

export const HIDEABLE_PANELS: ReadonlySet<PanelId> = new Set<PanelId>([
  'header',
  'dataset',
  'config',
  'categories',
  'participants',
  'query',
  'expand',
]);

/** The cell the query panel is showing: engine × query id. */
export interface CellSelection {
  sys: string;
  id: string;
}

export interface BenchState {
  /** null = "whatever `datasets[0]` is"; resolve with `curDataset()`. */
  dataset: string | null;
  metric: Metric;
  valueMode: ValueMode;
  tab: Tab;
  scale: Scale;
  /** Row the engines are sorted by: 'geomean' | 'load' | 'size' | `q:${id}` | ''. */
  sortRow: string;
  sortDir: SortDir;
  /** Engines the user switched off, by `system`. */
  hidden: ReadonlySet<string>;
  /** Engine tag filter. Never encoded in the URL — the standalone had no UI for it. */
  activeTags: ReadonlySet<string>;
  /** Query-category filter, by `query_tags[].task`. */
  activeQTasks: ReadonlySet<string>;
  /** Set by dragging a column; overrides every sort while it is non-null. */
  manualOrder: string[] | null;
  /** Engine whose column sorts the query rows. */
  sortByEngine: string | null;
  sortByEngineDir: SortDir;
  sel: CellSelection | null;
  /** Maximised: filters and query panel hidden. */
  max: boolean;
  explainOpen: boolean;
  hiddenPanels: ReadonlySet<PanelId>;
}

export const INITIAL_STATE: BenchState = {
  dataset: null,
  metric: 'hot',
  valueMode: 'relative',
  tab: 'table',
  scale: 'log',
  sortRow: 'geomean',
  sortDir: 1,
  hidden: new Set(),
  activeTags: new Set(),
  activeQTasks: new Set(),
  manualOrder: null,
  sortByEngine: null,
  sortByEngineDir: 1,
  sel: null,
  max: false,
  explainOpen: false,
  hiddenPanels: new Set(),
};

/** `state.dataset` resolved against the dataset list. ui/index.html:292-295. */
export function curDataset(dataset: string | null, datasets: readonly string[]): string | null {
  if (dataset) return dataset;
  return datasets[0] ?? null;
}

export function isPanelHidden(state: BenchState, id: PanelId): boolean {
  return state.hiddenPanels.has(id);
}
