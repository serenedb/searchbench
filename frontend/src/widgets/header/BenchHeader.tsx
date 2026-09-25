/* SearchBench identity, run selector, source link, service switcher and shared
 * theme toggle.
 * Router context selects SPA links in the playground; standalone uses anchors. */

import { Link, useInRouterContext } from 'react-router-dom';
import { findService, GithubIcon, ServiceSwitcher, SereneLogo, useTheme } from '@serenedb/ui';
import type { LinkRenderer, Theme } from '@serenedb/ui';
import { takeRuns, type BenchRunOption } from '../../entities/results/model/source';
import { SERVICE_ID } from '../../shared/config';
import { Panel } from '../../shared/ui';

const THEMES: readonly Theme[] = ['dark', 'light'];

/* The benchmark harness and the UI live in this repository. */
const SOURCE = 'https://github.com/serenedb/searchbench';

/* How a run reads: `2026-09-21 · 38 engines`, and just `38 engines` when the
   rows carry no date.

   The host that supplies the runs formats the same string a second time, so
   that an operator adding one sees the label a reader will get. Copied and not
   shared, because sharing it would mean a dependency on the host's package and
   this one deliberately has none: nothing here needs a backend, which is what
   keeps `npm run build` producing a file that opens over file:// with no
   network at all (tests/offline.test.mjs asserts exactly that). */
function runLabel(run: BenchRunOption): string {
  const engines = `${run.engines} engine${run.engines === 1 ? '' : 's'}`;
  return run.date === null ? engines : `${run.date} · ${engines}`;
}

/* `owner/repo` out of a GitHub URL. The standalone wrote the string out next to
   the href; deriving it means the label cannot drift from where the button
   actually goes. */
function repoLabel(href: string): string {
  const m = /^https:\/\/github\.com\/([^/]+)\/([^/?#]+)/.exec(href);
  return m ? `${m[1]}/${m[2]}` : 'GitHub';
}

export function BenchHeader() {
  const internal = useInRouterContext();
  const routerLink: LinkRenderer = ({ href, children, ...rest }) =>
    internal && href.startsWith('/') ? (
      <Link to={href} {...rest}>{children}</Link>
    ) : (
      <a href={href} {...rest}>{children}</a>
    );
  const { theme, setTheme } = useTheme();
  const service = findService(SERVICE_ID);
  const name = service?.name ?? 'SearchBench';
  /* One run is the page saying what it is, not a choice, and the standalone
     offers none at all — in both cases the control would be a dead widget. */
  const runs = takeRuns();

  return (
    <Panel className="sb-head">
      <div style={{ padding: '8px 14px', display: 'flex', alignItems: 'center', gap: 10 }}>
        {routerLink({
          href: internal ? (service?.path ?? '/') : window.location.pathname,
          className: 'sb-brand',
          children: (
            <>
              <SereneLogo size={20} />
              <span
                style={{
                  fontSize: 15,
                  fontWeight: 700,
                  letterSpacing: '-.01em',
                  whiteSpace: 'nowrap',
                }}
              >
                SereneDB <span style={{ fontWeight: 400, color: 'var(--mut)' }}>/</span>{' '}
                <span style={{ color: 'var(--accent)' }}>{name}</span>
                {/* ui/index.html:457 (`CURSOR`) — it followed the wordmark
                    there and it follows the service name here. */}
                <span
                  style={{
                    display: 'inline-block',
                    width: 8,
                    height: 15,
                    background: 'var(--accent)',
                    marginLeft: 3,
                    verticalAlign: -2,
                    animation: 'sb-blink 1.1s steps(1) infinite',
                  }}
                />
              </span>
            </>
          ),
        })}

        <ServiceSwitcher currentId={SERVICE_ID} internal={internal} renderLink={routerLink} />

        {/* Beside the identity rather than out with the source link and the
            theme toggle: it names which benchmark is on screen, which is part
            of what this page is, not a preference about how to view it. It
            costs ~157px on a strip that is never narrower than the 1280 this
            layout is pinned to (searchbench.css, `.sb-app { min-width }`), so
            the row stays one line and a window below that scrolls sideways
            with the rest of the page rather than squeezing this control alone.

            A native select, with the UA's own caret and popup. `.sb-app`
            declares `color-scheme`, so both are already drawn in the theme the
            page is in, and a hand-built popover would be more code, worse with
            a keyboard and worse on a phone for the same result. Borders,
            padding and weight are the GitHub button's beside it; `borderRadius`
            is spelled out because a select is the one control a UA rounds on
            its own, and nothing on this page has a corner.

            `value` tracks the host and never local state: a pick loads another
            document, and a control that moved on its own would be claiming a
            switch that has not happened yet. */}
        {runs !== null && runs.runs.length > 1 && (
          <select
            aria-label="Benchmark run"
            title="Which measurement of this benchmark to show"
            value={runs.currentId}
            onChange={(e) => runs.onSelect(e.currentTarget.value)}
            style={{
              border: '.5px solid var(--line)',
              borderRadius: 0,
              background: 'var(--inset)',
              color: 'var(--fg)',
              fontFamily: 'inherit',
              fontSize: 11,
              fontWeight: 700,
              padding: '4px 6px',
            }}
          >
            {runs.runs.map((run) => (
              <option key={run.id} value={run.id}>
                {runLabel(run)}
              </option>
            ))}
          </select>
        )}

        <a
          href={SOURCE}
          target="_blank"
          rel="noopener"
          title="View source on GitHub"
          style={{
            marginLeft: 'auto',
            display: 'inline-flex',
            alignItems: 'center',
            gap: 6,
            border: '.5px solid var(--line)',
            background: 'var(--inset)',
            color: 'var(--fg)',
            padding: '4px 10px',
            fontSize: 11,
            fontWeight: 700,
          }}
        >
          <GithubIcon size={14} className="shrink-0" />
          {repoLabel(SOURCE)}
        </a>

        <div className="seg">
          {THEMES.map((t) => (
            <button
              key={t}
              type="button"
              className={theme === t ? 'on' : ''}
              data-act="theme"
              data-v={t}
              style={{ padding: '3px 8px', fontSize: '10.5px' }}
              onClick={() => setTheme(t)}
            >
              {t}
            </button>
          ))}
        </div>
      </div>
    </Panel>
  );
}
