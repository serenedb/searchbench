/* `seg()` and `segRow()` — ui/index.html:461-471.
 *
 * The one control the config panel is built from: a bordered inset strip of
 * buttons, exactly one of them `.on`. `act` used to be the only thing a click
 * carried — the delegated listener read `data-act` / `data-v` off the button
 * and switched on it (ui/index.html:894-950). React calls `onPick` instead, but
 * the two attributes stay on the element: they are the DOM the original
 * produced, and `tools/visual/src/scenarios.mjs` drives the screenshots through
 * selectors like `[data-act="tab"][data-v="charts"]`.
 *
 * `pad` and `fs` are strings rather than numbers because the original passed
 * CSS values ("4px 2px", "10.5px") and the "cells" row depends on the tighter
 * pair to fit three labels in 300px.
 */

import type { CSSProperties } from 'react';

export interface SegOption<V extends string> {
  label: string;
  v: V;
  /** Rendered `disabled aria-disabled="true"`; the click never fires. */
  disabled?: boolean;
  /** Empty string means no `title` attribute at all, as in the original. */
  title?: string;
}

export interface SegProps<V extends string> {
  /** The `data-act` name — one per case of the original's switch. */
  act: string;
  opts: readonly SegOption<V>[];
  cur: V;
  /** `flex:1` on each button, so the strip divides evenly. */
  flex?: boolean;
  pad?: string;
  fs?: string;
  onPick: (v: V) => void;
}

export function Seg<V extends string>({
  act,
  opts,
  cur,
  flex = false,
  pad = '4px 8px',
  fs = '11px',
  onPick,
}: SegProps<V>) {
  return (
    <div className="seg" style={{ flex: 1 }}>
      {opts.map((o) => (
        <button
          key={o.v}
          className={o.v === cur ? 'on' : ''}
          data-act={act}
          data-v={o.v}
          disabled={o.disabled}
          aria-disabled={o.disabled ? 'true' : undefined}
          title={o.title || undefined}
          style={{ ...(flex ? { flex: 1 } : {}), padding: pad, fontSize: fs }}
          onClick={() => onPick(o.v)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

const LABEL: CSSProperties = {
  width: 48,
  flexShrink: 0,
  fontSize: '9.5px',
  fontWeight: 700,
  letterSpacing: '.07em',
  textTransform: 'uppercase',
  color: 'var(--mut)',
};

/** A `Seg` behind a fixed-width caption — one row of the config panel. */
export function SegRow<V extends string>({ label, ...seg }: { label: string } & SegProps<V>) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={LABEL}>{label}</span>
      <Seg {...seg} />
    </div>
  );
}
