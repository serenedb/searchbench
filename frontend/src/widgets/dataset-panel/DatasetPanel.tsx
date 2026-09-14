/* The dataset picker — ui/index.html:508-524.
 *
 * "Dataset has a dedicated, high-contrast panel so size is readable at a
 * glance": which corpus the numbers below are about is the first thing a reader
 * needs, and it is the one control that changes every value on the page. Hence
 * the size on its own line in the mono face, the engine count on the right, and
 * the violet chevron + 10%-tinted background on the active row instead of a
 * plain highlight.
 */

import type { Dispatch } from 'react';
import { DATASETS, datasetItems, rowsFor } from '../../entities/results';
import { fmtItems } from '../../shared/lib/format';
import type { BenchAction } from '../../shared/model';
import { Panel } from '../../shared/ui/Panel';

export function DatasetPanel({
  ds,
  dispatch,
}: {
  /** The resolved current dataset — `curDataset(state.dataset, DATASETS)`. */
  ds: string | null;
  dispatch: Dispatch<BenchAction>;
}) {
  return (
    <Panel className="dataset-panel">
      <div className="ph">
        <span className="pr">&gt;</span>
        <span className="pt">dataset</span>
        <span className="note" style={{ marginLeft: 'auto' }}>
          items
        </span>
      </div>
      <div style={{ padding: 7, display: 'flex', flexDirection: 'column', gap: 2 }}>
        {DATASETS.map((name) => {
          const on = name === ds;
          const items = datasetItems(name);
          return (
            <button
              key={name}
              className="dsrow"
              data-act="dataset"
              data-name={name}
              style={{
                borderColor: on ? 'var(--accent)' : 'transparent',
                background: on
                  ? 'color-mix(in srgb, var(--accent) 10%, transparent)'
                  : 'transparent',
              }}
              onClick={() => dispatch({ type: 'dataset', name })}
            >
              {/* Kept in the layout at opacity 0 rather than removed, so the
                  names below it do not shift by 13px as the selection moves. */}
              <span
                style={{
                  color: 'var(--accent)',
                  fontWeight: 700,
                  fontSize: 10,
                  width: 7,
                  opacity: on ? 1 : 0,
                }}
              >
                &gt;
              </span>
              <span
                style={{
                  flex: 1,
                  minWidth: 0,
                  display: 'flex',
                  flexDirection: 'column',
                  alignItems: 'flex-start',
                  gap: 1,
                  overflow: 'hidden',
                }}
              >
                <span
                  style={{
                    fontSize: 12,
                    fontWeight: 600,
                    color: 'var(--fg)',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                  }}
                >
                  {name}
                </span>
                <span
                  style={{ font: '700 10px var(--mono)', color: 'var(--mut)', letterSpacing: '.03em' }}
                >
                  {items ? fmtItems(items) + ' items' : 'dataset'}
                </span>
              </span>
              <span style={{ fontSize: 10, color: 'var(--mut)' }}>{rowsFor(name).length} eng</span>
            </button>
          );
        })}
      </div>
    </Panel>
  );
}
