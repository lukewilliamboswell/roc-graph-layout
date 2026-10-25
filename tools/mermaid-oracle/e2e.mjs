// End-to-end comparison: Mermaid text to our final SVG, through the public
// `Mermaid.svg` (parse, sizes, layout and drawing together), against
// Mermaid's own rendering of the same text. Authoring only; never part of a
// Roc package.
//
//   roc build --opt=speed package-mermaid/mermaid_svg.roc --output=mermaid_svg
//   node tools/mermaid-oracle/e2e.mjs ./mermaid_svg <out dir> [cases dir ...] [--only name,name]
//
// The cases default to tests/mermaid/flowchart and tests/mermaid/layout.
// Cases Mermaid rejects or does not render, and cases we report as
// `Unsupported`, are skipped and counted; any other failure of ours is
// listed as such.
//
// Both SVGs are rendered in the pinned browser with the pinned font at one
// CSS pixel per unit, their view boxes' top left corners aligned. The view
// boxes can differ in size; the comparison covers the larger of the two, and
// `size` reports ours relative to Mermaid's (width x height).
//
// Writes `<case>.png` (Mermaid | Roc | difference: red marks pixels only Roc
// draws, blue pixels only Mermaid draws; plus the difference after the best
// shift when that shift is not zero), `<case>.mermaid.svg`,
// `<case>.roc.svg` and `scores.json`, and prints a table sorted by score
// (the share of inked pixels with no match within one CSS pixel, as in
// `visual.mjs`), the same score after the translation of our drawing (up to
// 4 CSS pixels) that best overlays Mermaid's, which separates a drawing
// displaced as a whole from one that differs, and the time our native CLI took for each case (one
// process per case, so it includes process start-up) and for all cases in
// one process.
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { CONFIG, openBrowser } from './oracle.mjs';
import { compare, openRaster, viewBoxOf, writePng } from './raster.mjs';

// How far (CSS pixels) to look for a translation that best overlays our
// drawing on Mermaid's.
const MAX_SHIFT = 4;

const DEFAULT_DIRS = ['tests/mermaid/flowchart', 'tests/mermaid/layout'];

function run(tool, args) {
	const started = process.hrtime.bigint();
	const out = spawnSync(tool, args, { encoding: 'utf8', maxBuffer: 64 << 20 });
	const ms = Number(process.hrtime.bigint() - started) / 1e6;
	if (out.error) throw out.error;
	return { status: out.status, stderr: out.stderr, ms };
}

async function main() {
	const args = process.argv.slice(2);
	let only = null;
	const rest = [];
	for (let i = 0; i < args.length; i++) {
		if (args[i] === '--only') only = new Set(args[++i].split(','));
		else rest.push(args[i]);
	}
	const [tool, outDir, ...dirArgs] = rest;
	if (!tool || !outDir) {
		console.error('usage: e2e.mjs <mermaid_svg binary> <out dir> [cases dir ...] [--only a,b]');
		process.exit(2);
	}
	const dirs = dirArgs.length ? dirArgs : DEFAULT_DIRS;
	await fs.mkdir(outDir, { recursive: true });

	const cases = [];
	const skipped = [];
	const seen = new Set();
	for (const dir of dirs) {
		const names = (await fs.readdir(dir))
			.filter(f => f.endsWith('.mmd'))
			.map(f => f.slice(0, -4))
			.filter(n => !only || only.has(n))
			.sort();
		for (const name of names) {
			// Output files are named by case; a name repeated across
			// directories is prefixed with its directory.
			const id = seen.has(name) ? `${path.basename(dir)}-${name}` : name;
			seen.add(name);
			let record;
			try {
				record = JSON.parse(await fs.readFile(path.join(dir, `${name}.oracle.json`), 'utf8'));
			} catch {
				skipped.push({ name: id, why: 'no record' });
				continue;
			}
			if (!record.accepted || !record.layout) {
				skipped.push({ name: id, why: record.accepted ? 'not rendered by Mermaid' : 'rejected by Mermaid' });
				continue;
			}
			cases.push({ name: id, dir, record, source: path.join(dir, `${name}.mmd`), roc: path.join(outDir, `${id}.roc.svg`) });
		}
	}

	// The whole run in one process, then each case on its own for its time.
	for (const c of cases) await fs.rm(c.roc, { force: true });
	const whole = run(
		tool,
		cases.flatMap(c => [c.source, c.roc]),
	);
	const failures = [];
	const drawn = [];
	for (const c of cases) {
		const one = run(tool, [c.source, c.roc]);
		if (one.status === 0) {
			drawn.push({ ...c, ms: one.ms });
		} else if (/not drawn: \[Unsupported\(/.test(one.stderr)) {
			skipped.push({ name: c.name, why: `unsupported here: ${one.stderr.trim().split(': not drawn: ')[1]}` });
		} else {
			failures.push({ name: c.name, why: one.stderr.trim() || `exit ${one.status}` });
		}
	}

	const mermaid = await openBrowser();
	const raster = await openRaster();
	const results = [];
	try {
		for (const c of drawn) {
			const rocSvg = await fs.readFile(c.roc, 'utf8');
			const rendered = await mermaid.extract(c.record.source);
			if (!rendered.svg || !rendered.layout) {
				skipped.push({ name: c.name, why: 'Mermaid did not render' });
				continue;
			}
			await fs.writeFile(path.join(outDir, `${c.name}.mermaid.svg`), rendered.svg);
			const theirs = rendered.layout.view_box;
			const ours = viewBoxOf(rocSvg);
			if (!ours) {
				failures.push({ name: c.name, why: 'our SVG has no view box' });
				continue;
			}
			const result = await compare(raster.page, rendered.svg, theirs, rocSvg, ours, { maxShift: MAX_SHIFT });
			await writePng(path.join(outDir, `${c.name}.png`), result.png);
			const ratio = (a, b) => (b > 0 ? a / b : a > 0 ? Infinity : 1);
			results.push({
				name: c.name,
				dir: c.dir,
				score: result.score,
				strict: result.strict,
				shifted_score: result.shifted_score,
				shift: result.shift,
				ink: result.ink,
				width_ratio: ratio(ours.width, theirs.width),
				height_ratio: ratio(ours.height, theirs.height),
				mermaid_view_box: theirs,
				roc_view_box: ours,
				ms: c.ms,
			});
		}
	} finally {
		await raster.close();
		await mermaid.close();
	}

	results.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
	const mean = f => results.reduce((s, r) => s + f(r), 0) / Math.max(1, results.length);
	const median = f => {
		const v = results.map(f).sort((a, b) => a - b);
		return v.length ? v[Math.floor((v.length - 1) / 2)] : 0;
	};
	const areaRatio = r => r.width_ratio * r.height_ratio;
	const aggregate = {
		cases: results.length,
		skipped: skipped.length,
		failed: failures.length,
		mean_score: mean(r => r.score),
		median_score: median(r => r.score),
		mean_strict: mean(r => r.strict),
		mean_shifted_score: mean(r => r.shifted_score),
		// Typical size error, symmetric in over- and undersize.
		mean_abs_log_area_ratio: mean(r => Math.abs(Math.log(areaRatio(r)))),
		within_5_percent_size: results.filter(r => Math.abs(r.width_ratio - 1) <= 0.05 && Math.abs(r.height_ratio - 1) <= 0.05).length,
		cli_ms_per_case_total: results.reduce((s, r) => s + r.ms, 0),
		cli_ms_whole_run: whole.ms,
	};
	await fs.writeFile(
		path.join(outDir, 'scores.json'),
		JSON.stringify({ config: CONFIG, aggregate, results, skipped, failures }, null, '\t') + '\n',
	);

	const pct = v => `${(v * 100).toFixed(2)}%`.padStart(8);
	const size = r => `${r.width_ratio.toFixed(3)}x${r.height_ratio.toFixed(3)}`.padStart(12);
	const shift = r => `${r.shift.dx},${r.shift.dy}`.padStart(10);
	const ms = v => `${v.toFixed(1)}ms`.padStart(9);
	console.log(`${'case'.padEnd(40)}    score   strict  shifted      shift         size       cli`);
	for (const r of results) console.log(`${r.name.padEnd(40)} ${pct(r.score)} ${pct(r.strict)} ${pct(r.shifted_score)} ${shift(r)} ${size(r)} ${ms(r.ms)}`);
	console.log('');
	console.log(`cases scored:            ${aggregate.cases} (skipped ${aggregate.skipped}, failed ${aggregate.failed})`);
	console.log(`mean score:              ${pct(aggregate.mean_score).trim()} (median ${pct(aggregate.median_score).trim()}, strict ${pct(aggregate.mean_strict).trim()}, best-shifted ${pct(aggregate.mean_shifted_score).trim()})`);
	console.log(`view box size:           ${aggregate.within_5_percent_size} of ${aggregate.cases} within 5% in both directions; mean |log area ratio| ${aggregate.mean_abs_log_area_ratio.toFixed(4)}`);
	console.log(`native CLI time:         ${aggregate.cli_ms_whole_run.toFixed(1)}ms for all ${cases.length} cases in one process; ${aggregate.cli_ms_per_case_total.toFixed(1)}ms summed over one process per case`);
	for (const s of skipped) console.log(`skipped ${s.name}: ${s.why}`);
	for (const f of failures) console.log(`FAILED ${f.name}: ${f.why}`);
	if (failures.length) process.exitCode = 1;
}

await main();
