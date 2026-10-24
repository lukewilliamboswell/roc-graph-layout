// Scores the Roc flowchart layout against Mermaid's own layout.
//
//   node tools/mermaid-oracle/score.mjs [--bin <layout_dump>] [--json <out.json>] [--cases] <dir-or-record>...
//
// For every recorded case Mermaid accepted, the Roc layout is run on the same
// source with the sizes Mermaid measured (node shape boxes, edge label boxes,
// subgraph title boxes), so the comparison isolates layout from text
// measurement. `layout_dump` is the native build of
// `package-mermaid/layout_dump.roc`; with no `--bin` it is built into a
// temporary directory first.
//
// Metrics, per case, after translating the Roc drawing onto Mermaid's by the
// mean node-centre offset:
//   disp      mean node-centre displacement / Mermaid diagram diagonal
//   dmax      largest node-centre displacement / diagonal
//   layer     fraction of node pairs whose order along the flow agrees
//             (before, same layer, after), layers found by flow coordinate
//   rank      fraction of nodes with the same layer number
//   order     Kendall tau of the across-flow order of node pairs that share
//             a layer in both drawings (1 = same order, -1 = reversed)
//   cross     edge crossings, Roc / Mermaid, counted on route polylines
//   w, h      Roc bounds width and height / Mermaid view box
//   iou       mean subgraph box intersection-over-union
//   origin    distance between the bounds origins before alignment
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');

function parseArgs(argv) {
	const opts = { bin: null, json: null, cases: false, inputs: [] };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === '--bin') opts.bin = argv[++i];
		else if (a === '--json') opts.json = argv[++i];
		else if (a === '--cases') opts.cases = true;
		else opts.inputs.push(a);
	}
	if (opts.inputs.length === 0) opts.inputs = [path.join(repo, 'tests/mermaid/layout'), path.join(repo, 'tests/mermaid/flowchart')];
	return opts;
}

function recordsIn(inputs) {
	const files = [];
	for (const input of inputs) {
		const stat = fs.statSync(input);
		if (stat.isDirectory()) {
			for (const name of fs.readdirSync(input).sort()) if (name.endsWith('.oracle.json')) files.push(path.join(input, name));
		} else files.push(input);
	}
	return files;
}

const milli = v => String(Math.max(0, Math.round((Number.isFinite(v) ? v : 0) * 1000)));

// The case file `layout_dump` reads: source, NUL, then sizes. Label and
// title sizes are the text boxes Mermaid measured at unit scale (what it
// hands its layout engine), not their boxes in the scaled drawing.
const textSize = item => (item.text && item.text.box ? item.text.box : item.label);
export function caseText(record) {
	const lines = [];
	for (const n of record.layout.nodes) if (!n.missing && n.box) lines.push(['node', n.id, milli(n.box.width), milli(n.box.height)].join('\t'));
	record.layout.edges.forEach((e, i) => {
		if (!e.missing && e.label) lines.push(['edge', String(i), milli(textSize(e).width), milli(textSize(e).height)].join('\t'));
	});
	for (const c of record.layout.clusters) if (!c.missing && c.label) lines.push(['group', c.id, milli(textSize(c).width), milli(textSize(c).height)].join('\t'));
	return record.source + '\0' + lines.join('\n') + '\n';
}

export function buildDump(outDir) {
	const roc = process.env.ROC || 'roc';
	const out = path.join(outDir, 'layout_dump');
	execFileSync(roc, ['build', path.join(repo, 'package-mermaid/layout_dump.roc'), `--output=${out}`], { stdio: 'inherit' });
	return out;
}

export function runDump(bin, caseFiles) {
	const results = new Map();
	// Batches keep the argument list short.
	for (let i = 0; i < caseFiles.length; i += 40) {
		const batch = caseFiles.slice(i, i + 40);
		let text;
		try {
			text = execFileSync(bin, batch, { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] });
		} catch {
			// One case crashed: run them one at a time to find it.
			text = batch
				.map(file => {
					try {
						return execFileSync(bin, [file], { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] });
					} catch (error) {
						return JSON.stringify({ file, crashed: String(error.stderr || error.message).trim().slice(0, 200) }) + '\n';
					}
				})
				.join('');
		}
		for (const line of text.split('\n')) {
			if (!line.trim()) continue;
			const row = JSON.parse(line);
			results.set(row.file, row);
		}
	}
	return results;
}

const center = r => ({ x: r.x + r.width / 2, y: r.y + r.height / 2 });

// Dense layer numbers from node extents along the flow: walking nodes in
// order of their centres, a node starts a new layer when it does not overlap
// every node of the current one. Layered layouts align a layer's nodes but
// not always on one line, so centres alone would split layers.
function layersOf(spans) {
	const order = spans.map((s, i) => i).sort((a, b) => spans[a].mid - spans[b].mid || a - b);
	const layer = new Array(spans.length).fill(0);
	let current = -1, end = -Infinity;
	for (const i of order) {
		const s = spans[i];
		if (current < 0 || s.start >= end) {
			current++;
			end = s.end;
		} else end = Math.min(end, s.end);
		layer[i] = current;
	}
	return layer;
}

function segmentsCross(a, b, c, d) {
	const orient = (p, q, r) => (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x);
	const o1 = orient(a, b, c), o2 = orient(a, b, d), o3 = orient(c, d, a), o4 = orient(c, d, b);
	const eps = 1e-6;
	return ((o1 > eps && o2 < -eps) || (o1 < -eps && o2 > eps)) && ((o3 > eps && o4 < -eps) || (o3 < -eps && o4 > eps));
}

export function crossings(polylines) {
	let count = 0;
	for (let i = 0; i < polylines.length; i++) {
		for (let j = i + 1; j < polylines.length; j++) {
			const p = polylines[i], q = polylines[j];
			for (let a = 0; a + 1 < p.length; a++) for (let b = 0; b + 1 < q.length; b++) if (segmentsCross(p[a], p[a + 1], q[b], q[b + 1])) count++;
		}
	}
	return count;
}

function iou(a, b) {
	const x1 = Math.max(a.x, b.x), y1 = Math.max(a.y, b.y);
	const x2 = Math.min(a.x + a.width, b.x + b.width), y2 = Math.min(a.y + a.height, b.y + b.height);
	const inter = Math.max(0, x2 - x1) * Math.max(0, y2 - y1);
	const union = a.width * a.height + b.width * b.height - inter;
	return union > 0 ? inter / union : 1;
}

export function scoreCase(record, ours) {
	const m = record.layout;
	const dir = (record.flowchart && record.flowchart.direction) || 'TB';
	const horizontal = /LR|RL|Right|Left/.test(String(dir));
	const across = p => (horizontal ? p.y : p.x);
	const ourNodes = new Map(ours.nodes.map(n => [n.id, n.box]));
	const pairs = m.nodes
		.filter(n => !n.missing && ourNodes.has(n.id))
		.map(n => ({ id: n.id, theirs: n.center, ours: center(ourNodes.get(n.id)), theirBox: n.box, ourBox: ourNodes.get(n.id) }));
	const span = (box, c) => (horizontal ? { start: box.x, end: box.x + box.width, mid: c.x } : { start: box.y, end: box.y + box.height, mid: c.y });
	const diag = Math.hypot(m.view_box.width, m.view_box.height) || 1;
	const shift = pairs.length
		? { x: pairs.reduce((s, p) => s + p.theirs.x - p.ours.x, 0) / pairs.length, y: pairs.reduce((s, p) => s + p.theirs.y - p.ours.y, 0) / pairs.length }
		: { x: 0, y: 0 };
	const moved = p => ({ x: p.x + shift.x, y: p.y + shift.y });
	const dists = pairs.map(p => Math.hypot(moved(p.ours).x - p.theirs.x, moved(p.ours).y - p.theirs.y));
	const theirLayers = layersOf(pairs.map(p => span(p.theirBox, p.theirs)));
	const ourLayers = layersOf(pairs.map(p => span(p.ourBox, p.ours)));
	let layerAgree = 0, layerPairs = 0, concordant = 0, discordant = 0;
	for (let i = 0; i < pairs.length; i++) {
		for (let j = i + 1; j < pairs.length; j++) {
			layerPairs++;
			if (Math.sign(theirLayers[i] - theirLayers[j]) === Math.sign(ourLayers[i] - ourLayers[j])) layerAgree++;
			if (theirLayers[i] === theirLayers[j] && ourLayers[i] === ourLayers[j]) {
				const s = Math.sign(across(pairs[i].theirs) - across(pairs[j].theirs)) * Math.sign(across(pairs[i].ours) - across(pairs[j].ours));
				if (s > 0) concordant++;
				else if (s < 0) discordant++;
			}
		}
	}
	const rankSame = pairs.filter((_, i) => theirLayers[i] === ourLayers[i]).length;
	const theirRoutes = m.edges.filter(e => !e.missing && Array.isArray(e.points)).map(e => e.points);
	const ourRoutes = ours.edges.map(e => e.points);
	const ourGroups = new Map(ours.groups.map(g => [g.id, g.box]));
	const groupScores = m.clusters
		.filter(c => !c.missing && ourGroups.has(c.id))
		.map(c => {
			const b = ourGroups.get(c.id);
			return iou(c.box, { x: b.x + shift.x, y: b.y + shift.y, width: b.width, height: b.height });
		});
	return {
		nodes: pairs.length,
		disp: dists.length ? dists.reduce((a, b) => a + b, 0) / dists.length / diag : 0,
		dmax: dists.length ? Math.max(...dists) / diag : 0,
		layer: layerPairs ? layerAgree / layerPairs : 1,
		rank: pairs.length ? rankSame / pairs.length : 1,
		order: concordant + discordant ? (concordant - discordant) / (concordant + discordant) : 1,
		cross_ours: crossings(ourRoutes),
		cross_theirs: crossings(theirRoutes),
		w: ours.bounds.width / (m.view_box.width || 1),
		h: ours.bounds.height / (m.view_box.height || 1),
		iou: groupScores.length ? groupScores.reduce((a, b) => a + b, 0) / groupScores.length : null,
		origin: Math.hypot(ours.bounds.x - m.view_box.x, ours.bounds.y - m.view_box.y),
	};
}

const fmt = (v, d = 3) => (v === null || v === undefined ? '  -  ' : typeof v === 'number' ? v.toFixed(d) : String(v));

function main() {
	const opts = parseArgs(process.argv.slice(2));
	const work = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), 'mermaid-score-'));
	const bin = opts.bin || buildDump(work);
	const records = recordsIn(opts.inputs)
		.map(file => ({ file, record: JSON.parse(fs.readFileSync(file, 'utf8')) }))
		.filter(({ record }) => record.accepted && record.layout && !record.render_error);
	const caseFiles = records.map(({ file, record }, i) => {
		const out = path.join(work, `${i}.case`);
		fs.writeFileSync(out, caseText(record));
		return out;
	});
	const results = runDump(bin, caseFiles);
	const rows = [];
	records.forEach(({ file, record }, i) => {
		const row = results.get(caseFiles[i]);
		const name = path.basename(file, '.oracle.json');
		if (row && row.crashed) {
			rows.push({ name, error: `crashed: ${row.crashed}` });
			return;
		}
		if (!row || !row.accepted) {
			rows.push({ name, error: 'not accepted by the Roc reader' });
			return;
		}
		rows.push({ name, ...scoreCase(record, row.geometry) });
	});
	const ok = rows.filter(r => !r.error);
	const mean = key => {
		const vals = ok.map(r => r[key]).filter(v => typeof v === 'number');
		return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
	};
	if (opts.cases) {
		console.log(['case'.padEnd(36), 'n', 'disp', 'dmax', 'layer', 'rank', 'order', 'cross', 'w', 'h', 'iou'].join('\t'));
		for (const r of rows) {
			if (r.error) console.log(`${r.name.padEnd(36)}\t${r.error}`);
			else console.log([r.name.padEnd(36), r.nodes, fmt(r.disp), fmt(r.dmax), fmt(r.layer), fmt(r.rank), fmt(r.order, 2), `${r.cross_ours}/${r.cross_theirs}`, fmt(r.w, 2), fmt(r.h, 2), fmt(r.iou, 2)].join('\t'));
		}
	}
	const crossOurs = ok.reduce((s, r) => s + r.cross_ours, 0);
	const crossTheirs = ok.reduce((s, r) => s + r.cross_theirs, 0);
	const summary = {
		cases: ok.length,
		failed: rows.length - ok.length,
		disp: mean('disp'),
		dmax: mean('dmax'),
		layer: mean('layer'),
		rank: mean('rank'),
		order: mean('order'),
		crossings: { ours: crossOurs, theirs: crossTheirs },
		w: mean('w'),
		h: mean('h'),
		iou: mean('iou'),
		origin: mean('origin'),
	};
	console.log(
		`cases ${summary.cases} (failed ${summary.failed})  disp ${fmt(summary.disp)}  dmax ${fmt(summary.dmax)}  layer ${fmt(summary.layer)}  rank ${fmt(summary.rank)}  order ${fmt(summary.order)}  crossings ${crossOurs}/${crossTheirs}  w ${fmt(summary.w)}  h ${fmt(summary.h)}  iou ${fmt(summary.iou)}  origin ${fmt(summary.origin, 1)}`,
	);
	if (opts.json) fs.writeFileSync(opts.json, JSON.stringify({ summary, rows }, null, 1));
	fs.rmSync(work, { recursive: true, force: true });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
