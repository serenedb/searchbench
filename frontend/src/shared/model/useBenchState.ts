/* The store: reducer + the URL round-trip, in one hook.

   This is `init()` and the `syncUrlState()` line at the top of `render()`
   (ui/index.html:842, 989-995), moved into React's lifecycle:

     - the URL is read once, before the first paint, so a shared link never
       flashes the default view;
     - it is written back after every committed state change, with
       `replaceState`, so the address bar always holds a link to what is on
       screen and the back button still leaves the product;
     - a link that pins a theme applies it through the platform toggle.

   `env` must be referentially stable — memoise it at the page. */

import { useEffect, useReducer, useRef } from 'react';
import { useTheme } from '@serenedb/ui';
import { benchReducer, type BenchAction } from './reducer';
import { INITIAL_STATE, type BenchState } from './state';
import { restoreUrlState, syncUrlState, type CodecEnv, type ThemeName } from './url-codec';

/** Everything the store needs from the data. The codec's environment is all of
    it — a name kept because the page passes this around as `env`. */
export type BenchEnv = CodecEnv;

interface Boot {
  state: BenchState;
  /** Theme the link pinned, or null. */
  theme: ThemeName | null;
}

function boot(env: BenchEnv): Boot {
  const { patch, theme } = restoreUrlState(window.location.search, env, INITIAL_STATE);
  const state: BenchState = { ...INITIAL_STATE, ...patch };
  return { state, theme };
}

export function useBenchState(env: BenchEnv): [BenchState, React.Dispatch<BenchAction>] {
  const booted = useRef<Boot | null>(null);
  if (booted.current === null) booted.current = boot(env);

  const [state, dispatch] = useReducer(benchReducer, booted.current.state);
  const { theme, setTheme } = useTheme();

  // A link minted while the sender was in light mode opens in light mode: the
  // page they are quoting is the one the reader should see. Mount only — after
  // that the header toggle is the sole owner of the theme.
  const pinned = booted.current.theme;
  useEffect(() => {
    if (pinned) setTheme(pinned);
  }, [pinned, setTheme]);

  useEffect(() => {
    syncUrlState(state, env, theme as ThemeName);
  }, [state, env, theme]);

  return [state, dispatch];
}
