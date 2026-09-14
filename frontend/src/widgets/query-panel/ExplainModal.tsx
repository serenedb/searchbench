/* The explain overlay — ui/index.html:818-834, `renderExplain(qp)`.
 *
 * The full-screen plan viewer the ▚ Explain button opens. It renders the same
 * `qp` the query panel does — the page computes it once and hands it to both
 * (:863, :870) — and it is deliberately *not* nested inside the query panel:
 * `render()` appended it as a sibling of the layout grid, and `state.max` hides
 * the query panel without closing an open plan. It sits in the query panel's
 * slice rather than in one of its own because it renders that panel's
 * view-model, and a widget may not import from another widget.
 *
 * The panel here is hand-built rather than run through `panel()`: it has its own
 * padding (`0 10px 10px 0` against the helper's 8.5px) and its `bd` carries no
 * `fill` class. Copied as-is, dithered-shadow mismatch included.
 *
 * The plan pane is dark in both themes. That is the original's choice, not an
 * oversight — the colours are literals (`#0d0d0d`, `#161616`, `#f2f2f2`,
 * `#dcdcdc`, `rgba(255,255,255,…)`) with only `--accent` coming from the
 * palette, and `--accent` is `#895af8` in both. So the platform theme toggle
 * leaves this overlay alone, exactly as the page's own toggle did.
 *
 * Dismissal, three ways, all as the original wired them:
 *   - the backdrop (`data-act="explain-close"` on `.modal`);
 *   - the × button (its own `data-act`, found first by `closest()`);
 *   - Escape, from the window-level binding in `useBenchShortcuts`.
 * A click anywhere inside the panel is swallowed by `data-act="stop"`, which was
 * `e.stopPropagation()` in the delegated listener (:948) and is the same call
 * here. The × sits inside that panel, so its click closes and *then* gets its
 * propagation stopped — one close, as before.
 */

import type { Dispatch } from 'react';
import type { BenchAction } from '../../shared/model';
import type { QueryPanelData } from './queryPanelData';

interface ExplainModalProps {
  /** `queryPanelData(ds, state)` — the same object the query panel renders. */
  qp: QueryPanelData | null;
  /** `state.explainOpen`. Never encoded in `?s=`: a link cannot open the modal. */
  open: boolean;
  dispatch: Dispatch<BenchAction>;
}

export function ExplainModal({ qp, open, dispatch }: ExplainModalProps) {
  if (!(open && qp && qp.hasPlan)) return null;
  const close = () => dispatch({ type: 'explain-close' });
  return (
    <div className="modal" data-act="explain-close" onClick={close}>
      <div
        data-act="stop"
        className="panel"
        onClick={(e) => e.stopPropagation()}
        style={{
          padding: '0 10px 10px 0',
          width: 'min(960px,92vw)',
          maxHeight: '86vh',
          display: 'flex',
        }}
      >
        <div className="sh" />
        <div
          className="bd"
          style={{
            background: '#0d0d0d',
            flex: 1,
            minWidth: 0,
            display: 'flex',
            flexDirection: 'column',
          }}
        >
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '9px 14px',
              borderBottom: '.5px solid rgba(255,255,255,.14)',
              background: '#161616',
              flexShrink: 0,
            }}
          >
            <span style={{ color: 'var(--accent)', fontWeight: 700, fontSize: 12 }}>&gt;</span>
            <span
              style={{
                fontSize: 10,
                fontWeight: 700,
                letterSpacing: '.09em',
                textTransform: 'uppercase',
                color: 'var(--accent)',
              }}
            >
              {qp.planLabel}
            </span>
            <span
              style={{
                fontSize: 12.5,
                fontWeight: 700,
                color: '#f2f2f2',
                marginLeft: 4,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {qp.title}
            </span>
            <button
              data-act="explain-close"
              title="close (Esc)"
              onClick={close}
              style={{
                marginLeft: 'auto',
                border: '.5px solid rgba(255,255,255,.2)',
                background: '#232323',
                color: '#f2f2f2',
                width: 24,
                height: 24,
                fontSize: 14,
                lineHeight: 1,
                cursor: 'pointer',
                flexShrink: 0,
              }}
            >
              ×
            </button>
          </div>
          <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '16px 18px' }}>
            <pre
              style={{
                margin: 0,
                fontFamily: 'var(--mono)',
                fontSize: 12,
                lineHeight: 1.45,
                color: '#dcdcdc',
                whiteSpace: 'pre',
              }}
            >
              {qp.plan}
            </pre>
          </div>
        </div>
      </div>
    </div>
  );
}
