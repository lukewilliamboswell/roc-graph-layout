import { expect, test } from '@playwright/test';

const documentState = page => page.locator('#workspace').evaluate(element => JSON.parse(element.dataset.document));

const clickEdge = async (page, id) => {
  const points = await page.locator(`#edge-${id} .route-hit`).evaluate(path => JSON.parse(path.dataset.points));
  const segments = points.slice(1).map((point, index) => ({
    a: points[index],
    b: point,
    length: Math.abs(point.x - points[index].x) + Math.abs(point.y - points[index].y),
  }));
  const segment = segments.sort((a, b) => b.length - a.length)[0];
  const canvas = await page.locator('#editor-canvas').boundingBox();
  await page.mouse.click(canvas.x + (segment.a.x + segment.b.x) / 2, canvas.y + (segment.a.y + segment.b.y) / 2);
};

test.beforeEach(async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.node')).toHaveCount(3);
  const revision = await page.locator('#workspace').getAttribute('data-revision');
  await expect(page.locator('#status')).toHaveText(`Revision ${revision} synchronized.`);
});

test('ports use their configured names and distinct rounded roles', async ({ page }) => {
  const request = page.locator('.node[data-node-id="1"]');
  await expect(request.locator('.port-mark')).toHaveText(['A', 'B']);
  await expect(page.locator('.node[data-node-id="3"] .port-mark')).toHaveText(['A', 'B', 'C']);
  const shapes = await request.locator('.port').evaluateAll(ports => ports.map(port => ({
    role: port.dataset.role,
    radius: getComputedStyle(port).borderRadius,
    color: getComputedStyle(port).borderColor,
  })));
  expect(shapes.every(shape => shape.radius !== '0px')).toBe(true);
  expect(shapes.find(shape => shape.role === 'input').color).not.toBe(shapes.find(shape => shape.role === 'output').color);
  const route = page.locator('.edge').first();
  await expect(route.locator('.route')).toHaveAttribute('marker-end', 'url(#route-arrow)');
  expect(await route.locator('.route').getAttribute('d')).not.toBe(await route.locator('.route-hit').getAttribute('d'));
});

test('light and dark themes preserve accessible semantic contrast', async ({ page }) => {
  const ratios = async theme => {
    await page.locator('#theme').selectOption(theme);
    return page.evaluate(() => {
      const rgb = value => {
        let hex=value.trim().slice(1);if(hex.length===3)hex=[...hex].map(character=>character+character).join('');
        return [0,2,4].map(index=>parseInt(hex.slice(index,index+2),16));
      };
      const luminance = value => rgb(value).map(channel => channel / 255).map(channel => channel <= .04045 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4).reduce((sum,channel,index) => sum + channel * [.2126,.7152,.0722][index], 0);
      const ratio = (a,b) => (Math.max(luminance(a),luminance(b)) + .05) / (Math.min(luminance(a),luminance(b)) + .05);
      const root = getComputedStyle(document.documentElement);
      return {
        text:ratio(root.getPropertyValue('--text'),root.getPropertyValue('--surface-container')),
        muted:ratio(root.getPropertyValue('--text-muted'),root.getPropertyValue('--surface-container')),
        input:ratio(root.getPropertyValue('--input'),root.getPropertyValue('--surface-container')),
        output:ratio(root.getPropertyValue('--output'),root.getPropertyValue('--surface-container')),
      };
    });
  };
  for (const theme of ['light','dark']) {
    const result = await ratios(theme);
    expect(result.text).toBeGreaterThanOrEqual(4.5);
    expect(result.muted).toBeGreaterThanOrEqual(4.5);
    expect(result.input).toBeGreaterThanOrEqual(3);
    expect(result.output).toBeGreaterThanOrEqual(3);
  }
  await page.reload();
  await expect(page.locator('#theme')).toHaveValue('dark');
});

test('a dropped node remains at its exact browser position after the server response', async ({ page }) => {
  const node = page.locator('.node[data-node-id="2"]');
  const before = await documentState(page);
  const revision = Number(await page.locator('#workspace').getAttribute('data-revision'));
  const box = await node.boundingBox();
  expect(box).not.toBeNull();

  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width / 2 + 73, box.y + box.height / 2 + 41, { steps: 6 });
  await page.mouse.up();

  await expect.poll(async () => Number(await page.locator('#workspace').getAttribute('data-revision'))).toBeGreaterThan(revision);
  const after = await documentState(page);
  const oldNode = before.nodes.find(item => item.id === 2);
  const movedNode = after.nodes.find(item => item.id === 2);
  expect(movedNode.x).toBeCloseTo(oldNode.x + 73, 4);
  expect(movedNode.y).toBeCloseTo(oldNode.y + 41, 4);

  await page.reload();
  await expect.poll(async () => (await documentState(page)).nodes.find(item => item.id === 2).x).toBeCloseTo(movedNode.x, 4);
});

test('a server disconnect preserves the canvas and pauses mutations', async ({ page }) => {
  const canvas = page.locator('node-editor-canvas');
  const nodesBefore = await page.locator('.node').count();
  await page.route('**/health', route => route.abort());
  await canvas.evaluate(element => element.checkServer());
  await expect(page.locator('body')).toHaveAttribute('data-server-state', 'offline');
  await expect(page.locator('#offline-status')).toBeVisible();
  await expect(page.locator('#offline-status')).toContainText('changes are paused');
  expect(await canvas.evaluate(element => element.requestCommand('add-node'))).toBe(false);
  await expect(page.locator('.node')).toHaveCount(nodesBefore);

  await page.unroute('**/health');
  await canvas.evaluate(element => element.checkServer());
  await expect(page.locator('body')).toHaveAttribute('data-server-state', 'online');
});

test('port and connection properties persist through the server and reload', async ({ page }) => {
  await page.locator('.node[data-node-id="1"] .node-title').click();
  await expect(page.locator('.port-editor')).toHaveCount(2);
  await page.getByRole('button', { name: 'Add output' }).click();
  await expect(page.locator('.port-editor')).toHaveCount(3);

  const added = page.locator('.port-editor').last();
  await added.locator('[data-port-label]').fill('Failure');
  await added.locator('[data-port-side]').selectOption('left');
  await added.locator('[data-port-label]').blur();
  await expect.poll(async () => (await documentState(page)).nodes.find(item => item.id === 1).ports.length).toBe(3);
  await expect.poll(async () => (await documentState(page)).nodes.find(item => item.id === 1).ports.at(-1).label).toBe('Failure');
  await added.getByRole('button', { name: 'Move port up' }).click();
  await expect.poll(async () => (await documentState(page)).nodes.find(item => item.id === 1).ports[1].label).toBe('Failure');
  await page.locator('.port-editor').nth(1).getByRole('button', { name: 'Move port down' }).click();
  await expect.poll(async () => (await documentState(page)).nodes.find(item => item.id === 1).ports.at(-1).label).toBe('Failure');
  await page.locator('.port-editor').last().getByRole('button', { name: 'Move port up' }).click();
  await expect.poll(async () => (await documentState(page)).nodes.find(item => item.id === 1).ports[1].label).toBe('Failure');

  await clickEdge(page, 1);
  await expect(page.locator('.edge-editor')).toBeVisible();
  await page.locator('[data-edge-label]').fill('approved');
  await page.locator('[data-edge-label]').blur();
  await expect.poll(async () => (await documentState(page)).edges.find(item => item.id === 1).label).toBe('approved');
  await page.locator('[data-edge-color]').evaluate(input => {
    input.value = '#22aa88';
    input.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await expect.poll(async () => (await documentState(page)).edges.find(item => item.id === 1).color).toBe('#22aa88');

  await page.reload();
  const persisted = await documentState(page);
  const port = persisted.nodes.find(item => item.id === 1).ports.find(item => item.label === 'Failure');
  expect(port.side).toBe('left');
  expect(persisted.nodes.find(item => item.id === 1).ports[1].id).toBe(port.id);
  expect(persisted.edges.find(item => item.id === 1)).toMatchObject({ label: 'approved', color: '#22aa88' });
});

test('serialized final routes are orthogonal and avoid unrelated node bodies', async ({ page }) => {
  const violations = await page.locator('#editor-canvas').evaluate(canvas => {
    const nodes = [...canvas.querySelectorAll('.node')].map(node => ({
      id: Number(node.dataset.nodeId),
      left: Number(node.dataset.x),
      top: Number(node.dataset.y),
      right: Number(node.dataset.x) + Number(node.dataset.width),
      bottom: Number(node.dataset.y) + Number(node.dataset.height),
    }));
    const crosses = (a, b, box) => {
      if (a.x === b.x) return a.x > box.left && a.x < box.right && Math.max(a.y, b.y) > box.top && Math.min(a.y, b.y) < box.bottom;
      if (a.y === b.y) return a.y > box.top && a.y < box.bottom && Math.max(a.x, b.x) > box.left && Math.min(a.x, b.x) < box.right;
      return true;
    };
    return [...canvas.querySelectorAll('.route')].flatMap(path => {
      const points = JSON.parse(path.dataset.points);
      const excluded = new Set([Number(path.dataset.from), Number(path.dataset.to)]);
      return points.slice(1).flatMap((point, index) => nodes
        .filter(node => !excluded.has(node.id) && crosses(points[index], point, node))
        .map(node => ({ edge: path.dataset.edgeId, segment: index, node: node.id })));
    });
  });
  expect(violations).toEqual([]);
});

test('routing diagnostics render deterministic orthogonal fixtures', async ({ page }) => {
  await page.goto('/routing-gallery');
  await expect(page.locator('article')).toHaveCount(3);
  const invalid = await page.locator('.gallery-route').evaluateAll(routes => routes.flatMap((route, routeIndex) => {
    const points = route.getAttribute('points').trim().split(/\s+/).map(pair => {
      const [x, y] = pair.split(',').map(Number);
      return { x, y };
    });
    return points.slice(1).flatMap((point, index) => {
      const previous = points[index];
      return Number.isFinite(point.x) && Number.isFinite(point.y) && (point.x === previous.x || point.y === previous.y)
        ? []
        : [{ route: routeIndex, segment: index }];
    });
  }));
  expect(invalid).toEqual([]);
});
