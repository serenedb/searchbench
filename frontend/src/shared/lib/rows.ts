/* The shape shared/lib needs from a result row, and the two tag predicates.

   Deliberately structural and deliberately *smaller* than entities/results'
   `EngineRow`: shared may not import entities, so the helpers below describe
   the fields they actually touch and `EngineRow` satisfies them by shape. Pass
   a real row anywhere a `BenchRow` is asked for. */

export interface BenchRow {
  system: string;
  /** Per-query runs, `result[qi] = [cold, hot1, hot2]`. */
  result: (number | null)[][];
  /** Query id → index into `result`; built by entities/results, never by hand. */
  byId: Record<string, number>;
  /** Engine labels ("Java", "Lucene", …). */
  tags?: string[];
  load_time?: number;
  data_size?: number;
}

/**
 * An engine's tags minus its own name — `["Java","Lucene","OpenSearch"]` on
 * OpenSearch is two labels and a repetition. ui/index.html:302-305.
 */
export function tagsOf(row: BenchRow): string[] {
  const name = (row.system || '').toLowerCase();
  return (row.tags || []).filter((t) => String(t).toLowerCase() !== name);
}

/** Empty filter passes everything. ui/index.html:311-313. */
export function passesTagFilter(row: BenchRow, activeTags: ReadonlySet<string>): boolean {
  return activeTags.size === 0 || tagsOf(row).some((t) => activeTags.has(t));
}
