/* Reading a number out of a row, and the ratios built on top of it.
   ui/index.html:178-180, 326-347, 380-401.

   Every function that used to read `state.metric` off the module-global takes it
   as an argument instead — that is the whole difference from the original. */

import type { Metric } from '../model/state';
import type { BenchRow } from './rows';

/** 10 ms — ClickBench's ratio-smoothing constant. */
export const SMOOTH = 0.01;

/** Per-try wall-clock cap (lib/benchmark.sh default). */
export const TIMEOUT_CAP = 60;

/** A run that hit the cap is a kill, not a measurement. */
export function isTimeout(v: unknown): boolean {
  return typeof v === 'number' && v >= TIMEOUT_CAP;
}

/**
 * The engine's number for one query under one run mode: `cold` is the first
 * try, `hot` is the fastest of the rest. `null` when the engine did not run it.
 */
export function metricValue(row: BenchRow, id: string, metric: Metric): number | null {
  const qi = row.byId ? row.byId[id] : undefined;
  if (qi == null) return null;
  const arr = row.result[qi];
  if (!Array.isArray(arr)) return null;
  if (metric === 'cold') return typeof arr[0] === 'number' ? arr[0] : null;
  const hots = arr.slice(1).filter((x): x is number => typeof x === 'number');
  return hots.length ? Math.min(...hots) : null;
}

/** Fastest number any engine in `list` posted for `id`. */
export function fastestForQuery(list: BenchRow[], id: string, metric: Metric): number | null {
  const vals = list
    .map((r) => metricValue(r, id, metric))
    .filter((v): v is number => typeof v === 'number');
  return vals.length ? Math.min(...vals) : null;
}

/** Ratio with the smoothing constant applied — used by the geomean, not by cells. */
export function smoothedRatio(t: number | null, best: number | null): number | null {
  if (typeof t !== 'number' || typeof best !== 'number') return null;
  return (SMOOTH + t) / (SMOOTH + best);
}

/** Plain ratio, as shown in a relative cell. `Infinity` when only `t` is > 0. */
export function ratioOf(t: number | null, best: number | null): number | null {
  if (typeof t !== 'number' || typeof best !== 'number') return null;
  if (best === 0) return t === 0 ? 1 : Infinity;
  return t / best;
}

/**
 * Geomean of the smoothed per-query ratios, per engine, over `ids` — one pass
 * with the fastest-per-query memoized.
 *
 * Timeouts are dropped rather than counted as 60 s: at the cap the engine was
 * killed, so the number says "unsupported", and averaging it in would rank an
 * engine that answered nothing above one that answered slowly.
 *
 * @param ids the visible query ids — the mean recomputes when categories filter
 */
export function geomeanMap(
  list: BenchRow[],
  ids: readonly string[],
  metric: Metric,
): Map<string, number | null> {
  const fastest: Record<string, number | null> = {};
  for (const id of ids) {
    let mn = Infinity;
    for (const r of list) {
      const v = metricValue(r, id, metric);
      if (typeof v === 'number') mn = Math.min(mn, v);
    }
    fastest[id] = isFinite(mn) ? mn : null;
  }
  const out = new Map<string, number | null>();
  for (const r of list) {
    let sum = 0;
    let k = 0;
    for (const id of ids) {
      const v = metricValue(r, id, metric);
      if (isTimeout(v) || typeof v !== 'number') continue;
      const best = fastest[id];
      if (best == null) continue;
      const ratio = (SMOOTH + v) / (SMOOTH + best);
      if (ratio > 0) {
        sum += Math.log(ratio);
        k++;
      }
    }
    out.set(r.system, k ? Math.exp(sum / k) : null);
  }
  return out;
}

/** How much of the workload an engine actually answered. `coverageMap`. */
export interface Coverage {
  /** Queries it has a number for. The rest it could not express at all. */
  supported: number;
  /** Of those, the ones that came back under the cap rather than being killed. */
  completed: number;
}

/**
 * Per engine: how many of `ids` it ran, and how many of those finished.
 *
 * The two counts the default column order ranks by, before the geomean breaks
 * the tie. They are deliberately counts over the *visible* ids, like the
 * geomean, so filtering the categories re-ranks on the filtered workload.
 *
 * `supported` and `completed` are nested, not disjoint: a timeout is a query
 * the engine expressed and did not answer, so it counts once in `supported`
 * and not in `completed`.
 */
export function coverageMap(
  list: BenchRow[],
  ids: readonly string[],
  metric: Metric,
): Map<string, Coverage> {
  const out = new Map<string, Coverage>();
  for (const r of list) {
    let supported = 0;
    let completed = 0;
    for (const id of ids) {
      const v = metricValue(r, id, metric);
      if (typeof v !== 'number') continue;
      supported++;
      if (!isTimeout(v)) completed++;
    }
    out.set(r.system, { supported, completed });
  }
  return out;
}
