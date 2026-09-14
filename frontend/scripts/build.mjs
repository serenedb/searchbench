import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { build } from 'vite';

const frontend = new URL('../', import.meta.url);
const result = await build({
  configFile: fileURLToPath(new URL('vite.config.ts', frontend)),
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  build: { write: false },
});
const outputs = (Array.isArray(result) ? result : [result]).flatMap((r) => r.output);
const script = outputs.filter((o) => o.type === 'chunk').map((o) => o.code).join('\n');
const styles = outputs.filter((o) => o.type === 'asset' && o.fileName.endsWith('.css'));
const unexpected = outputs.filter((o) => o.type === 'asset' && !o.fileName.endsWith('.css'));
if (unexpected.length) throw new Error(`Unbundled assets: ${unexpected.map((o) => o.fileName)}`);

// Library mode embeds fonts/images as data URLs. Classic inline JS also works
// over file://, where module scripts and fetch('./results.json') are restricted.
const css = styles.map((o) => o.source.toString()).join('\n');
const template = await readFile(new URL('dev.html', frontend), 'utf8');
const resultsHash = createHash('sha256')
  .update(await readFile(new URL('results.json', frontend))).digest('hex');
const html = template
  .replace('</head>', () =>
    `<meta name="searchbench-results-sha256" content="${resultsHash}">\n` +
    `<style>${css.replace(/<\/style/gi, '<\\/style')}</style>\n  </head>`)
  .replace(/<script type="module"[^>]*><\/script>/, () =>
    `<script>${script.replace(/<\/script/gi, '<\\/script')}</script>`);
await writeFile(new URL('index.html', frontend), html);
console.log(`Wrote frontend/index.html (${Buffer.byteLength(html)} bytes, self-contained)`);
