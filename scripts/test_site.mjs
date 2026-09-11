import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve, sep } from 'node:path';

// Set PLAYWRIGHT_MODULE to an installed playwright-core module when running
// without a repository-local node_modules directory.
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright-core');
const root = resolve(process.argv[2] ?? 'dist/site');
const build = JSON.parse(await readFile(resolve(root, 'build-info.json'), 'utf8'));
const prefix = `${build.base_path}/`;
const origin = 'https://pages.test';
const browser = await chromium.launch({
  headless: true,
  ...(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {}),
});
const missing = [];
const errors = [];
async function serve(context) {
  await context.route(`${origin}/**`, async route => {
    const url = new URL(route.request().url());
    assert.ok(url.pathname.startsWith(prefix), `asset escaped project prefix: ${url.pathname}`);
    let relative = decodeURIComponent(url.pathname.slice(prefix.length));
    if (!relative || relative.endsWith('/')) relative += 'index.html';
    const file = resolve(root, relative);
    assert.ok(file.startsWith(root + sep), `asset escaped site output: ${file}`);
    const mime = file.endsWith('.wasm') ? 'application/wasm'
      : file.endsWith('.mjs') || file.endsWith('.js') ? 'text/javascript'
      : file.endsWith('.css') ? 'text/css'
      : file.endsWith('.svg') ? 'image/svg+xml' : 'text/html';
    try {
      await route.fulfill({ contentType: mime, body: await readFile(file) });
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      missing.push(url.pathname);
      await route.fulfill({ status: 404, body: 'Missing site asset' });
    }
  });
}
try {
  const staticContext = await browser.newContext({ javaScriptEnabled: false });
  await serve(staticContext);
  const guide = await staticContext.newPage();
  await guide.goto(origin + prefix);
  await guide.getByRole('heading', { name: 'Graph geometry, ready for your renderer', exact: true }).waitFor();
  await guide.getByRole('navigation').getByRole('link', { name: 'Choosing a layout', exact: true }).click();
  await guide.getByRole('heading', { name: 'Choosing a layout', exact: true }).waitFor();
  assert.equal(await guide.locator('script').count(), 0, 'guides should not load an application runtime');
  await staticContext.close();

  const context = await browser.newContext();
  await serve(context);
  const page = await context.newPage();
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(origin + prefix + 'playground/');
  await page.getByRole('button', { name: 'Run layout', exact: true }).waitFor();
  await page.waitForFunction(() => document.querySelectorAll('svg .node').length === 7);
  assert.equal(await page.locator('[role="alert"]').isVisible(), false, 'empty errors must not leave a visible banner');
  assert.match(await page.locator('.layout-control').innerText(), /Layout algorithm/);
  assert.match(await page.locator('.example-picker').innerText(), /Choose an example/);
  assert.ok(await page.locator('.preview').evaluate(el => el.getBoundingClientRect().height < 750), 'preview must remain bounded on desktop');
  assert.equal(await page.locator('details.inspect').getAttribute('open'), null, 'geometry starts collapsed');
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'mobile layout must not scroll sideways');
  await page.setViewportSize({ width: 1440, height: 1000 });
  assert.equal(await page.locator('svg').evaluate(el => el.namespaceURI), 'http://www.w3.org/2000/svg');
  const editor = page.getByRole('textbox', { name: 'Graph data in RVN', exact: true });
  const editorHandle = await editor.elementHandle();
  await editor.fill('{ labels: ["A"], graph: { nodes: [{ width: 90, height: 40 }], edges: [] } }');
  await page.waitForFunction(() => document.querySelectorAll('svg .node').length === 1);
  assert.ok(await editorHandle.evaluate(el => el.isConnected), 'editing must preserve the editor element');
  await page.getByRole('combobox', { name: 'Example', exact: true }).selectOption('ring');
  await page.waitForFunction(() => document.querySelectorAll('svg .node').length === 8);
  await page.getByRole('combobox', { name: 'Example', exact: true }).selectOption('pipeline');
  await page.waitForFunction(() => document.querySelectorAll('svg .node').length === 1);
  await editor.fill('invalid');
  await page.getByRole('alert').filter({ hasText: 'not valid RVN' }).waitFor();
  assert.equal(await page.locator('svg').count(), 0);
  await page.getByRole('button', { name: 'Reset', exact: true }).click();
  await page.waitForFunction(() => document.querySelectorAll('svg .node').length === 7);
  for (const [preset, count] of [['org', 9], ['mind', 11], ['collaboration', 10], ['incident', 12], ['cloud', 8], ['release', 9], ['transit', 10]]) {
    await page.getByRole('combobox', { name: 'Example', exact: true }).selectOption(preset);
    await page.waitForFunction(expected => document.querySelectorAll('svg .node').length === expected, count);
    assert.equal(await page.locator('[role="alert"]').textContent(), '', `${preset} errors`);
    assert.doesNotMatch(await page.locator('svg').getAttribute('viewBox'), /NaN|Infinity/);
  }
  await page.getByRole('navigation', { name: 'Site', exact: true }).getByRole('link', { name: 'API reference', exact: true }).click();
  await page.waitForURL(`**/docs/${build.version}/`);
  assert.ok((await page.locator('body').innerText()).includes('Layered'));
  assert.deepEqual(errors, []);
  assert.deepEqual(missing, []);
  console.log('PASS: no-JavaScript guides, all nine presets, interactive edits, and API navigation under a Pages project prefix.');
} finally {
  await browser.close();
}
