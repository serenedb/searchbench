/* The dithered offset card. ui/index.html:456-459 (`panel`).

   Every box on the page is one of these: a shadow layer masked with the 4×5px
   dither SVG, and a bordered body on top of it. The original built the markup
   by string concatenation and took the same three options, so they are the
   props here, spelled the same way:

     panel(inner, { grow, style, fillBody })
       → <Panel grow style={…} fillBody>{inner}</Panel>

   `className` is the one addition: the dataset panel got its extra class by
   `.replace('class="panel"', 'class="panel dataset-panel"')` (ui/index.html:524),
   which is not a thing you can do to JSX. Nothing else about the element
   changed — same tag, same order, same class names. */

import type { CSSProperties, ReactNode } from 'react';

export interface PanelProps {
  /** `flex:1` card that fills the column, and a flex body inside it. */
  grow?: boolean;
  /** Body gets `.fill` without the card growing — a fixed-height panel. */
  fillBody?: boolean;
  /** Inline style on the outer `.panel`, exactly as the original passed it. */
  style?: CSSProperties;
  /** Extra classes after `panel`/`panel grow`. */
  className?: string;
  children?: ReactNode;
}

export function Panel({
  grow = false,
  fillBody = false,
  style,
  className,
  children,
}: PanelProps): ReactNode {
  return (
    <div
      className={'panel' + (grow ? ' grow' : '') + (className ? ' ' + className : '')}
      style={style}
    >
      <div className="sh" />
      <div className={grow || fillBody ? 'bd fill' : 'bd'}>{children}</div>
    </div>
  );
}
