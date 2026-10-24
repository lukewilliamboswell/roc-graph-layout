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
import { CONFIG, FONT_FAMILY, openBrowser } from './oracle.mjs';
import { compare, openRaster, writePng } from './raster.mjs';

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
	const raster = await openRaster();
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
			const result = await compare(raster.page, rendered.svg, c.record.layout.view_box, rocSvg);
			await writePng(path.join(outDir, `${c.name}.png`), result.png);
			results.push({ name: c.name, score: result.score, strict: result.strict, ink: result.ink });
		}
	} finally {
		await raster.close();
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
