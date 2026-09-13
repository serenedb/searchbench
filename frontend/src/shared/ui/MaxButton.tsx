/* The maximise toggle — ui/index.html:763-767, `maxBtn()`.
 *
 * Hides the sidebar and the query panel so the results table gets the whole
 * window, and switches its own label and colours when it is on. It renders in
 * the panel head of *both* main panels — the results table (:671) and the
 * charts (:758) — which is why it is in shared/ui: two widgets need it, and a
 * widget may not import from another widget.
 *
 * `?hide=expand` removes the control without removing the state, so an embed
 * can pin `?s=…x=1` and give the reader no way out of it. That is the
 * standalone's behaviour and the reason for the early return.
 *
 * Styles copied verbatim from the template literal, including `title` flipping
 * with the state.
 */

import type { Dispatch } from 'react';
import type { BenchAction, BenchState } from '../model';
import { isPanelHidden } from '../model';

export interface MaxButtonProps {
  state: BenchState;
  dispatch: Dispatch<BenchAction>;
}

export function MaxButton({ state, dispatch }: MaxButtonProps) {
  if (isPanelHidden(state, 'expand')) return null;
  const on = state.max;
  return (
    <button
      data-act="max"
      title={on ? 'restore filters & query panel' : 'maximize — hide filters & query panel'}
      onClick={() => dispatch({ type: 'max' })}
      style={{
        border: '.5px solid var(--line)',
        background: on ? 'var(--accent)' : 'var(--inset)',
        color: on ? '#fff' : 'var(--mut)',
        padding: '2px 8px',
        fontSize: 10,
        fontWeight: 700,
        cursor: 'pointer',
        marginLeft: 10,
      }}
    >
      {on ? '⛶ restore' : '⛶ max'}
    </button>
  );
}
