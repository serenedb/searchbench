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
