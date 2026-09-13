import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { chromium } from 'playwright';

test('committed HTML renders and responds over file:// without network', async () => {
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({ offline: true, viewport: { width: 1440, height: 1000 } });
    const page = await context.newPage();
    const errors = [];
    const network = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('request', (request) => {
      if (/^https?:/.test(request.url())) network.push(request.url());
    });
    const html = new URL('../index.html', import.meta.url);
    const rows = JSON.parse(await readFile(new URL('../results.json', import.meta.url), 'utf8'));
    await page.goto(html.href);
    const hash = createHash('sha256')
      .update(await readFile(new URL('../results.json', import.meta.url))).digest('hex');
    assert.equal(await page.locator('meta[name="searchbench-results-sha256"]').getAttribute('content'),
      hash, 'Rebuild index.html after changing results.json');
    await page.locator('.sb-app').waitFor();
    await page.getByRole('button', { name: 'Charts', exact: true }).click();
    await page.getByRole('button', { name: 'Linear', exact: true }).waitFor();
    await page.getByRole('button', { name: 'light', exact: true }).click();
    assert.ok(await page.locator('html').evaluate((el) => el.classList.contains('light')));
    await page.getByRole('button', { name: 'Table', exact: true }).click();
    await page.getByRole('button', { name: 'Millis', exact: true }).click();
    await page.locator(`[data-act="dataset"][data-name="${rows[0].dataset}"]`).click();
    assert.ok((await page.locator('body').innerText()).includes('SearchBench'));
    assert.ok((await page.locator('body').innerText()).includes(rows[0].system.split(' ')[0]));
    await page.reload();
    await page.locator('.sb-app').waitFor();
    assert.equal(await page.getByRole('button', { name: 'Millis', exact: true }).getAttribute('class'), 'on');
    assert.deepEqual(errors, []);
    assert.deepEqual(network, []);
    await context.close();
  } finally {
    await browser.close();
  }
});
