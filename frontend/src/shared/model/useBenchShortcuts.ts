/* The page's keyboard bindings — ui/index.html:984-986.
 *
 * The standalone bound one `keydown` listener on `window` in `wire()`, once,
 * for the life of the page, and it did exactly one thing: Escape closes the
 * explain overlay. That is the whole shortcut surface, so this hook is the
 * whole of it too.
 *
 * `window`, not the modal: the plan pane is a `<div>` with nothing focusable in
 * it except the close button, so a listener on the overlay would only fire
 * after a click had put focus inside. The original's choice is the working one.
 *
 * The effect re-subscribes when `explainOpen` flips instead of reading it
 * through a ref. Same behaviour — the handler's only branch is `explainOpen`,
 * so a binding made while the modal is closed was already inert — and it keeps
 * the dependency honest. Nothing is preventDefault'ed; Escape stays available
 * to the browser exactly as before.
 */

import { useEffect } from 'react';
import type { Dispatch } from 'react';
import type { BenchAction } from './reducer';
import type { BenchState } from './state';

export function useBenchShortcuts(state: BenchState, dispatch: Dispatch<BenchAction>): void {
  const explainOpen = state.explainOpen;
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && explainOpen) dispatch({ type: 'explain-close' });
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [explainOpen, dispatch]);
}
