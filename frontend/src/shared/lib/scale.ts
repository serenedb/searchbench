/* Chart axis ranges. ui/index.html:436-448. */

export interface AxisScale {
  /** Bottom of the axis — the floor bars are clamped to on a log scale. */
  lo: number;
  /** Top of the axis. */
  hi: number;
  /** Tick values, in ascending order, `lo` and `hi` included. */
  ticks: number[];
}

/** Decade-aligned log axis covering [min, max], one tick per power of ten. */
export function niceLog(min: number, max: number): AxisScale {
  const lo = Math.pow(10, Math.floor(Math.log10(min)));
  const hi = Math.pow(10, Math.ceil(Math.log10(max)));
  const ticks: number[] = [];
  for (let p = Math.log10(lo); p <= Math.log10(hi) + 1e-9; p++) ticks.push(Math.pow(10, Math.round(p)));
  return { lo, hi, ticks };
}

/** Zero-based linear axis rounded up to a leading digit, in four steps. */
export function niceLin(max: number): AxisScale {
  const pow = Math.pow(10, Math.floor(Math.log10(max || 1)));
  const top = Math.ceil((max || 1) / pow) * pow;
  const ticks: number[] = [];
  for (let i = 0; i <= 4; i++) ticks.push((top * i) / 4);
  return { lo: 0, hi: top || 1, ticks };
}
