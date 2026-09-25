/* Results are supplied before ProductApp is imported. The standalone entry
 * embeds frontend/results.json; playground can fetch a public or protected
 * variant without bundling its rows into the shared product code. */
import type { RawEngineRow } from './types';

let rows: RawEngineRow[] | null = null;

/** Called by the shell's loader before this product's modules are imported. */
export function provideResults(next: readonly RawEngineRow[]): void {
  rows = [...next];
}

/**
 * Throws rather than defaulting to empty: a silently blank benchmark looks like
 * a real one with nothing in it, and the cause — a loader that did not run —
 * would be invisible on screen.
 */
export function takeResults(): RawEngineRow[] {
  if (rows === null) {
    throw new Error(
      'searchbench results were never provided: the shell must call provideResults() ' +
        'from @searchbench/frontend/results before importing @searchbench/frontend',
    );
  }
  return rows;
}

/** One entry in the run selector. */
export interface BenchRunOption {
  /** Opaque here: the embedder minted it and only the embedder decodes it. */
  id: string;
  /** `YYYY-MM-DD` the benchmark was measured, or null when the rows say nothing. */
  date: string | null;
  /** Engine rows behind that run — the "N engines" half of the label. */
  engines: number;
}

/** The runs a host offers for this page, and which of them is on screen. */
export interface RunSelection {
  /** Newest measurement first; the header shows them in this order. */
  runs: BenchRunOption[];
  /** Which of `runs` these results are. */
  currentId: string;
  /** The reader picked a run. Reporting it is all the product does with it. */
  onSelect: (id: string) => void;
}

let selection: RunSelection | null = null;

/**
 * Handed in ahead of this product's modules, through the same door as the rows
 * and for the same reason: `dataset.ts` freezes the benchmark in a module-scope
 * `const RAW = takeResults()`, so a document renders exactly one benchmark, and
 * which one it is has to be settled before the first import. A context or a
 * prop would arrive after those modules evaluated, which is one import too late.
 *
 * `onSelect` is a report, not an action, because this package cannot carry out
 * the switch and should not pretend to: with the rows frozen at module scope,
 * changing run is a document load, the shell owns the routes it would load, and
 * the standalone build has no router to load anything with. Leaving the
 * decision on the host's side is also what lets an in-document swap arrive
 * later with no change here.
 */
export function provideRuns(next: RunSelection): void {
  selection = next;
}

/**
 * Null when nobody offered runs, rather than the throw `takeResults` does: the
 * standalone entry embeds one results.json and never calls `provideRuns`, so
 * having no runs is the ordinary case and the selector simply does not render.
 */
export function takeRuns(): RunSelection | null {
  return selection;
}
