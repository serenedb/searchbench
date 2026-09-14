/* The shape of frontend/results.json, as ./frontend/build_results writes it.

   One object per (engine, dataset) pair. `result`, `query_tags` and `queries`
   are positionally aligned within a row and only within a row — engines omit
   queries they cannot express, so two rows' index 40 are different queries.
   That is what `byId` exists for; never align two engines by position. */

export interface QueryTag {
  /** "Q01" … — the stable identity of a query across engines. */
  id?: string;
  /** Category: "count", "join", "topk", … Drives the categories filter. */
  task?: string;
  /** Predicate shape: "term", "phrase", "range", … */
  filter?: string;
  /** Selectivity bucket: "hi" / "lo". */
  freq?: string;
}

/** A row exactly as it appears in results.json. */
export interface RawEngineRow {
  system: string;
  version: string;
  os: string;
  date: string;
  dataset: string;
  /** Engine labels; includes the engine's own name, which `tagsOf` strips. */
  tags: string[];
  /** Seconds to ingest + index. */
  load_time: number;
  /** Bytes on disk, data + index. */
  data_size: number;
  /** `result[qi] = [cold, hot, hot]`, seconds. */
  result: (number | null)[][];
  query_tags?: QueryTag[];
  /** The executed statement per query; "UNSUPPORTED: …" when the engine cannot. */
  queries?: string[];
  explains?: (string | null)[];
  explain_analyzes?: (string | null)[];
  /** Provenance: the per-engine results file this row was built from. */
  _source?: string;
}

/**
 * A raw row plus its query index. Built once at module load; this is the type
 * every selector and every widget works with.
 */
export interface EngineRow extends RawEngineRow {
  /** Query id → index into `result` / `queries` / `explains` for THIS row. */
  byId: Record<string, number>;
}
