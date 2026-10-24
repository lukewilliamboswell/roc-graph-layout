// Visual comparison of the Roc flowchart drawing with Mermaid's own rendering.
// Authoring only; never part of a Roc package.
//
// For each recorded case, Mermaid's geometry (node boxes, label boxes, edge
// routes, cluster boxes and the view box) is handed to the Roc drawing stage
// through `package-mermaid/draw_svg.roc`, so the drawing is judged on its own:
// same geometry, compare pixels. Both SVGs are rendered in the pinned browser
// at the same view box and scale with the pinned font, and compared pixel by
// pixel.
//
//   roc build package-mermaid/draw_svg.roc --output=draw_svg
//   node tools/mermaid-oracle/visual.mjs ./draw_svg tests/mermaid/flowchart out/ [case ...]
//
// Writes, into the output directory, `<case>.png` (Mermaid | Roc | difference,
// where red marks pixels only Roc draws and blue pixels only Mermaid draws)
// and `scores.json`, and prints a table sorted by score. A case's score is the
// share of inked pixels (in either image) that the other image does not match
// within one CSS pixel; `strict` is the share that differs in place.
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { CONFIG, FONT_FAMILY, FONT_FILE, openBrowser } from './oracle.mjs';

const require = createRequire(import.meta.url);
const SCALE = 2;

const thousandths = v => String(Math.round((Number.isFinite(v) ? v : 0) * 1000));
const hex = id => Buffer.from(String(id), 'utf8').toString('hex');
// The label rows Mermaid drew (after its own wrapping), or `-` to use the
// diagram's label split at line breaks.
const rows = item => (item.text && Array.isArray(item.text.rows) ? hex(item.text.rows.join('\n')) || '-' : '-');

// The geometry file `draw_svg.roc` reads.
function geometryText(layout) {
	const lines = [];
	const vb = layout.view_box;
	lines.push(['bounds', vb.x, vb.y, vb.width, vb.height].map((v, i) => (i === 0 ? v : thousandths(v))).join(' '));
	for (const n of layout.nodes) {
		if (n.missing || !n.box) continue;
		const t = n.label ?? { width: 0, height: 0 };
		lines.push(['node', hex(n.id), ...[n.box.x, n.box.y, n.box.width, n.box.height, t.width, t.height].map(thousandths), rows(n)].join(' '));
	}
	for (const c of layout.clusters) {
		if (c.missing || !c.box) continue;
		const t = c.label ?? { width: 0, height: 0 };
		lines.push(['group', hex(c.id), ...[c.box.x, c.box.y, c.box.width, c.box.height, t.width, t.height].map(thousandths), rows(c)].join(' '));
	}
	for (const e of layout.edges) {
		if (e.missing || !e.points) continue;
		const label = e.label
			? [e.label.x + e.label.width / 2, e.label.y + e.label.height / 2, e.label.width, e.label.height].map(thousandths)
			: ['-', '-', '-', '-'];
		const pts = e.points.flatMap(p => [thousandths(p.x), thousandths(p.y)]);
		lines.push(['edge', hex(e.id), ...label, rows(e), String(e.points.length), ...pts].join(' '));
	}
	return lines.join('\n') + '\n';
}

async function rasterPage(browser) {
	const page = await browser.newPage();
	await page.setRequestInterception(true);
	page.on('request', request => (request.url().startsWith('data:') ? request.continue() : request.abort()));
	await page.setViewport({ width: 1200, height: 800, deviceScaleFactor: SCALE });
	const font = (await fs.readFile(FONT_FILE)).toString('base64');
	await page.setContent(
		`<!doctype html><html><head><style>@font-face{font-family:"${FONT_FAMILY}";src:url(data:font/ttf;base64,${font}) format("truetype");}` +
			`body{margin:0;background:#fff}.cell{display:inline-block;background:#fff;line-height:0;vertical-align:top}</style></head>` +
			`<body><div id="a" class="cell"></div><div id="b" class="cell"></div></body></html>`,
	);
	await page.evaluate(async family => {
		await document.fonts.load(`16px "${family}"`);
		if (!document.fonts.check(`16px "${family}"`)) throw new Error('font failed to load');
	}, FONT_FAMILY);
	return page;
}

// Renders both SVGs at the view box size, screenshots each, and compares them
// in the page. Returns the scores and a PNG (data URL) of the comparison.
async function compare(page, mermaidSvg, rocSvg, viewBox) {
	const width = Math.max(1, Math.ceil(viewBox.width));
	const height = Math.max(1, Math.ceil(viewBox.height));
	await page.setViewport({ width: Math.min(8000, width * 2 + 40), height: Math.min(8000, height + 20), deviceScaleFactor: SCALE });
	await page.evaluate(
		(a, b, w, h) => {
			const place = (id, text) => {
				const host = document.getElementById(id);
				host.innerHTML = text;
				const svg = host.querySelector('svg');
				svg.setAttribute('width', w);
				svg.setAttribute('height', h);
				svg.style.maxWidth = 'none';
				svg.style.display = 'block';
				host.style.width = `${w}px`;
				host.style.height = `${h}px`;
			};
			place('a', a);
			place('b', b);
		},
		mermaidSvg,
		rocSvg,
		width,
		height,
	);
	const shotA = await (await page.$('#a')).screenshot({ encoding: 'base64' });
	const shotB = await (await page.$('#b')).screenshot({ encoding: 'base64' });
	return page.evaluate(
		async (a, b, scale) => {
			const load = src =>
				new Promise((resolve, reject) => {
					const img = new Image();
					img.onload = () => resolve(img);
					img.onerror = reject;
					img.src = `data:image/png;base64,${src}`;
				});
			const [ia, ib] = await Promise.all([load(a), load(b)]);
			const w = Math.min(ia.width, ib.width);
			const h = Math.min(ia.height, ib.height);
			const pixels = img => {
				const c = document.createElement('canvas');
				c.width = w;
				c.height = h;
				const ctx = c.getContext('2d');
				ctx.drawImage(img, 0, 0);
				return ctx.getImageData(0, 0, w, h).data;
			};
			const pa = pixels(ia);
			const pb = pixels(ib);
			const close = (p, i, q, j) => Math.max(Math.abs(p[i] - q[j]), Math.abs(p[i + 1] - q[j + 1]), Math.abs(p[i + 2] - q[j + 2])) <= 40;
			const inked = (p, i) => p[i] + p[i + 1] + p[i + 2] < 3 * 250;
			const radius = scale; // one CSS pixel
			const matchedNear = (p, q, x, y) => {
				const i = (y * w + x) * 4;
				for (let dy = -radius; dy <= radius; dy++) {
					const yy = y + dy;
					if (yy < 0 || yy >= h) continue;
					for (let dx = -radius; dx <= radius; dx++) {
						const xx = x + dx;
						if (xx < 0 || xx >= w) continue;
						if (close(p, i, q, (yy * w + xx) * 4)) return true;
					}
				}
				return false;
			};
			const out = document.createElement('canvas');
			out.width = w * 3;
			out.height = h;
			const octx = out.getContext('2d');
			octx.fillStyle = '#fff';
			octx.fillRect(0, 0, w * 3, h);
			octx.drawImage(ia, 0, 0);
			octx.drawImage(ib, w, 0);
			const diff = octx.createImageData(w, h);
			let ink = 0;
			let strict = 0;
			let loose = 0;
			for (let y = 0; y < h; y++) {
				for (let x = 0; x < w; x++) {
					const i = (y * w + x) * 4;
					const shade = 255 - Math.round((255 - (pa[i] + pa[i + 1] + pa[i + 2]) / 3) * 0.25);
					diff.data[i] = shade;
					diff.data[i + 1] = shade;
					diff.data[i + 2] = shade;
					diff.data[i + 3] = 255;
					if (!inked(pa, i) && !inked(pb, i)) continue;
					ink += 1;
					if (!close(pa, i, pb, i)) strict += 1;
					const aMissing = !matchedNear(pa, pb, x, y);
					const bMissing = !matchedNear(pb, pa, x, y);
					if (aMissing || bMissing) {
						loose += 1;
						// red: Roc's pixel has no match in Mermaid; blue: Mermaid's has none in Roc.
						if (bMissing && inked(pb, i)) {
							diff.data[i] = 230;
							diff.data[i + 1] = 30;
							diff.data[i + 2] = 30;
						} else {
							diff.data[i] = 30;
							diff.data[i + 1] = 80;
							diff.data[i + 2] = 230;
						}
					}
				}
			}
			octx.putImageData(diff, w * 2, 0);
			return { ink, strict: ink ? strict / ink : 0, score: ink ? loose / ink : 0, png: out.toDataURL('image/png') };
		},
		shotA,
		shotB,
		SCALE,
	);
}

async function main() {
	const [tool, casesDir, outDir, ...only] = process.argv.slice(2);
	if (!tool || !casesDir || !outDir) {
		console.error('usage: visual.mjs <draw_svg binary> <cases dir> <out dir> [case ...]');
		process.exit(2);
	}
	await fs.mkdir(outDir, { recursive: true });
	const names = (await fs.readdir(casesDir))
		.filter(f => f.endsWith('.mmd'))
		.map(f => f.slice(0, -4))
		.filter(n => only.length === 0 || only.includes(n))
		.sort();
	const cases = [];
	const skipped = [];
	for (const name of names) {
		let record;
		try {
			record = JSON.parse(await fs.readFile(path.join(casesDir, `${name}.oracle.json`), 'utf8'));
		} catch {
			skipped.push({ name, why: 'no record' });
			continue;
		}
		if (!record.accepted || !record.layout) {
			skipped.push({ name, why: record.accepted ? 'not rendered' : 'rejected by Mermaid' });
			continue;
		}
		const geometry = path.join(outDir, `${name}.geometry`);
		await fs.writeFile(geometry, geometryText(record.layout));
		cases.push({ name, record, source: path.join(casesDir, `${name}.mmd`), geometry, roc: path.join(outDir, `${name}.roc.svg`) });
	}
	for (const c of cases) await fs.rm(c.roc, { force: true });
	const triples = cases.flatMap(c => [c.source, c.geometry, c.roc]);
	execFileSync(tool, [FONT_FAMILY, ...triples], { stdio: ['ignore', 'inherit', 'inherit'] });

	const mermaid = await openBrowser();
	const puppeteer = require('puppeteer');
	const browser = await puppeteer.launch({ headless: true, args: ['--no-sandbox', '--font-render-hinting=none'] });
	const page = await rasterPage(browser);
	const results = [];
	try {
		for (const c of cases) {
			let rocSvg;
			try {
				rocSvg = await fs.readFile(c.roc, 'utf8');
			} catch {
				skipped.push({ name: c.name, why: 'not drawn by Roc' });
				continue;
			}
			const rendered = await mermaid.extract(c.record.source);
			if (!rendered.svg) {
				skipped.push({ name: c.name, why: 'Mermaid did not render' });
				continue;
			}
			await fs.writeFile(path.join(outDir, `${c.name}.mermaid.svg`), rendered.svg);
			const result = await compare(page, rendered.svg, rocSvg, c.record.layout.view_box);
			await fs.writeFile(path.join(outDir, `${c.name}.png`), Buffer.from(result.png.split(',')[1], 'base64'));
			results.push({ name: c.name, score: result.score, strict: result.strict, ink: result.ink });
		}
	} finally {
		await browser.close();
		await mermaid.close();
	}
	results.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
	await fs.writeFile(path.join(outDir, 'scores.json'), JSON.stringify({ config: CONFIG, results, skipped }, null, '\t') + '\n');
	const pct = v => `${(v * 100).toFixed(2)}%`.padStart(8);
	console.log(`${'case'.padEnd(40)}   score   strict`);
	for (const r of results) console.log(`${r.name.padEnd(40)} ${pct(r.score)} ${pct(r.strict)}`);
	const mean = results.reduce((s, r) => s + r.score, 0) / Math.max(1, results.length);
	const meanStrict = results.reduce((s, r) => s + r.strict, 0) / Math.max(1, results.length);
	console.log(`${'mean of ' + results.length + ' cases'.padEnd(40)} ${pct(mean)} ${pct(meanStrict)}`);
	for (const s of skipped) console.log(`skipped ${s.name}: ${s.why}`);
}

await main();
