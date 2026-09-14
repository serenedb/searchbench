/* Engine colours. ui/index.html:170-176.

   SereneDB (canonical) always paints in the brand blue so it stands out; every
   other engine — including SereneDB variants, which are separate `system`
   values — takes a stable palette slot keyed off its position in the sorted
   list of non-SereneDB systems. Stable is the point: an engine keeps its colour
   between the table legend, the participants list and every chart, and adding a
   dataset must not repaint the ones already published.

   The `others` list is data, so entities/results binds it — call
   `engineColor(sys)` from there rather than passing the array by hand. */

export const PALETTE = [
  '#895af8',
  '#5ed29a',
  '#ffb454',
  '#e06c9f',
  '#7fd7e0',
  '#d0c05a',
  '#ff7b6b',
  '#9aa7ff',
  '#f29e7b',
  '#b48ead',
] as const;

/** The one engine that is not on the palette. */
export const SERENEDB_SYSTEM = 'SereneDB';
export const SERENEDB_COLOR = '#3386ff';

/**
 * @param others every `system` except SereneDB, sorted — the slot index
 */
export function colorOf(sys: string, others: readonly string[]): string {
  if (sys === SERENEDB_SYSTEM) return SERENEDB_COLOR;
  const i = others.indexOf(sys);
  return PALETTE[(i < 0 ? 0 : i) % PALETTE.length];
}
