/* The query panel — ui/index.html:798-815, `renderQueryPanel(qp)`.
 *
 * The strip under the results table that shows the statement behind whichever
 * cell is selected. It is always the same 186px tall box: with a selection it
 * carries the title, the run line, the ▚ Explain button and a close button;
 * without one, the "select a query cell" prompt and a blinking block cursor.
 *
 * The markup is `panel(head + body, { fillBody: true, style: … })`, and the
 * call survives as `<Panel fillBody style={…}>` — same three nested divs
 * (`panel` / `sh` / `bd fill`), same inline style on the outer one (:456-459).
 * Every style below is copied character-for-character from the template
 * literal; the only edits are the ones the language forces (`class` →
 * `className`, `style="a:b"` → an object) and the `data-act` strings becoming
 * real handlers. The attributes themselves are kept so the rendered DOM still
 * matches the original's.
 *
 * The whitespace the template literal had between the head's spans, and between
 * the three in the empty state, is gone: JSX strips indentation between
 * elements where HTML would have collapsed it to a space. Both containers are
 * flex (`.ph` from the stylesheet, the empty state inline), and a flex
 * container drops whitespace-only children — so nothing moves.
 *
 * `esc()` is gone from this file and nowhere else: React escapes text children
 * and attribute values itself, and the original's four replacements produce the
 * same rendered characters.
 */

import type { Dispatch } from 'react';
import type { BenchAction } from '../../shared/model';
import { Panel } from '../../shared/ui';
import type { QueryPanelData } from './queryPanelData';

interface QueryPanelProps {
  /** `queryPanelData(ds, state)`; null when no cell is selected. */
  qp: QueryPanelData | null;
  dispatch: Dispatch<BenchAction>;
}

export function QueryPanel({ qp, dispatch }: QueryPanelProps) {
  return (
    <Panel fillBody style={{ height: 186, flexShrink: 0, display: 'flex' }}>
      <div className="ph" style={{ padding: '6px 12px' }}>
        <span className="pr">&gt;</span>
        <span className="pt">query</span>
        {qp && (
          <>
            <span
              style={{
                fontSize: 12,
                fontWeight: 700,
                color: 'var(--fg)',
                marginLeft: 6,
              }}
            >
              {qp.title}
            </span>
            <span
              style={{
                marginLeft: 'auto',
                fontSize: 11,
                color: 'var(--mut)',
                fontVariantNumeric: 'tabular-nums',
              }}
            >
              {qp.meta}
            </span>
            {qp.hasPlan && (
              <button
                data-act="explain-open"
                title="show the query plan (EXPLAIN)"
                onClick={() => dispatch({ type: 'explain-open' })}
                style={{
                  border: '.5px solid var(--accent)',
                  background: 'color-mix(in srgb, var(--accent) 15%, transparent)',
                  color: 'var(--accent)',
                  padding: '3px 11px',
                  fontSize: 10.5,
                  fontWeight: 700,
                  cursor: 'pointer',
                  marginLeft: 10,
                }}
              >
                ▚ Explain
              </button>
            )}
            <button
              data-act="qp-close"
              title="close"
              onClick={() => dispatch({ type: 'qp-close' })}
              style={{
                border: '.5px solid var(--line)',
                background: 'var(--inset)',
                color: 'var(--fg)',
                width: 20,
                height: 20,
                fontSize: 12,
                lineHeight: 1,
                cursor: 'pointer',
                marginLeft: 10,
              }}
            >
              ×
            </button>
          </>
        )}
      </div>
      {qp ? (
        <div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: '10px 12px' }}>
          <div
            style={{
              border: '.5px solid var(--line)',
              background: 'var(--inset)',
              padding: '9px 12px',
              fontSize: 12,
              lineHeight: 1.55,
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
              color: 'var(--fg)',
              fontFamily: 'var(--mono)',
            }}
          >
            {qp.sql}
          </div>
        </div>
      ) : (
        <div
          style={{
            flex: 1,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 8,
            color: 'var(--mut)',
            fontSize: 12.5,
          }}
        >
          <span style={{ color: 'var(--accent)', fontWeight: 700 }}>~$</span>
          <span>select a query cell to view the executed query</span>
          <span
            style={{
              display: 'inline-block',
              width: 7,
              height: 13,
              background: 'var(--mut)',
              animation: 'sb-blink 1.1s steps(1) infinite',
            }}
          />
        </div>
      )}
    </Panel>
  );
}
