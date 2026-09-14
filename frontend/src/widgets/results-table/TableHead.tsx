/* The sticky header row of the results grid — ui/index.html:602-613, plus the
   drag-to-reorder handlers from the delegated listeners at :952-982.

   One `.corner` and one `.engcol` per engine, in column order. Each column is
   three things at once and all three are the original's:

     click  → sort the query rows by this engine (asc → desc → off)
     drag   → move the column, which pins a manual order and drops the row sort
     title  → the engine's tags, version, OS and run date

   Two pieces of drag bookkeeping stay outside React state on purpose, exactly
   as the standalone had them:

     `dragSys`   the column being dragged. A ref, not state, because it is also
                 the guard that swallows the click a drag ends with
                 (ui/index.html:936) — by the time that click arrives a state
                 update would have re-rendered and the guard would read stale.
     `lastOver`  the column under the cursor, highlighted by toggling
                 `.dragover` on the node. `dragover` fires every few
                 milliseconds; the original noted it wanted the highlight
                 "without a full re-render" and this keeps that property. The
                 class is always removed on drop/dragend, before the reorder
                 re-renders, so React never paints over a stale one. */

import { useRef, type DragEvent, type ReactNode } from 'react';
import type { EngineRow } from '../../entities/results';
import { tagsOf } from '../../shared/lib/rows';
import type { SortDir } from '../../shared/model';

export interface TableHeadProps {
  /** Visible engines, in column order. */
  engines: EngineRow[];
  /** `grid-template-columns` — shared with every row so the columns line up. */
  gridCols: string;
  sortByEngine: string | null;
  sortByEngineDir: SortDir;
  onSort: (sys: string) => void;
  /** A finished drop: `dragged` lands at `target`'s position. */
  onReorder: (dragged: string, target: string) => void;
}

export function TableHead({
  engines,
  gridCols,
  sortByEngine,
  sortByEngineDir,
  onSort,
  onReorder,
}: TableHeadProps): ReactNode {
  const dragSys = useRef<string | null>(null);
  const lastOver = useRef<HTMLElement | null>(null);

  const clearDrag = () => {
    if (lastOver.current) lastOver.current.classList.remove('dragover');
    dragSys.current = null;
    lastOver.current = null;
  };

  const handleDragStart = (e: DragEvent<HTMLDivElement>, sys: string) => {
    dragSys.current = sys;
    e.dataTransfer.effectAllowed = 'move';
    try {
      e.dataTransfer.setData('text/plain', sys);
    } catch {
      /* Safari refuses setData outside a user gesture; the drag still works. */
    }
  };

  const handleDragOver = (e: DragEvent<HTMLDivElement>) => {
    if (dragSys.current == null) return;
    e.preventDefault(); // without this the drop is never delivered
    const th = e.currentTarget;
    if (lastOver.current && lastOver.current !== th) lastOver.current.classList.remove('dragover');
    th.classList.add('dragover');
    lastOver.current = th;
  };

  const handleDrop = (e: DragEvent<HTMLDivElement>, target: string) => {
    const dragged = dragSys.current;
    if (dragged == null) return;
    e.preventDefault();
    if (target && target !== dragged) onReorder(dragged, target);
    clearDrag();
  };

  return (
    <div className="thead" style={{ gridTemplateColumns: gridCols }}>
      <div className="corner">metric \ engine</div>
      {engines.map((e) => {
        const ver = [
          e.version && e.version !== 'unknown' ? 'v' + e.version : null,
          e.os,
          e.date,
        ]
          .filter(Boolean)
          .join(' · ');
        const tags = tagsOf(e).join(' · ');
        const tip =
          [tags, ver].filter(Boolean).join('  —  ') +
          '  —  click: sort queries by this engine · drag: reorder';
        const sortedHere = sortByEngine === e.system;
        const smark = sortedHere ? (sortByEngineDir === 1 ? '▲' : '▼') : '';
        const bg = sortedHere ? 'color-mix(in srgb, var(--accent) 14%, var(--head))' : 'var(--head)';
        return (
          <div
            key={e.system}
            className="engcol"
            draggable
            data-act="engsort"
            data-drag="1"
            data-sys={e.system}
            title={tip}
            style={{ background: bg }}
            onClick={() => {
              if (dragSys.current != null) return; // the click that ends a drag
              onSort(e.system);
            }}
            onDragStart={(ev) => handleDragStart(ev, e.system)}
            onDragOver={handleDragOver}
            onDrop={(ev) => handleDrop(ev, e.system)}
            onDragEnd={clearDrag}
          >
            <span className="grip">⠿</span>
            {e.system}
            <span className="sm">{smark}</span>
          </div>
        );
      })}
    </div>
  );
}
