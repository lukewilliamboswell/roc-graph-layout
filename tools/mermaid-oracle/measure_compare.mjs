// Compares the sizes `FlowSize.roc` computes with Mermaid's, case by case.
//
//   roc build package-mermaid/measure_sizes.roc --output=measure_sizes
//   node tools/mermaid-oracle/measure_compare.mjs ./measure_sizes tests/mermaid/flowchart tests/mermaid/measure
//
// For every accepted case with an oracle record it compares
//   - label text: rows, and the text box Mermaid measured (record `text`,
//     read at unit scale) for node labels, edge labels and group titles;
//   - node sizes: the outline's box (record `box`), per shape.
// and prints max and mean absolute error in px, then the worst mismatches.
// Exits non-zero when any text row differs or an error exceeds --tolerance
// (default 0.01 px).
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
const tolArg = args.find(a => a.startsWith('--tolerance='));
const tolerance = tolArg ? Number(tolArg.split('=')[1]) : 0.01;
const [binary, ...dirs] = args.filter(a => !a.startsWith('--'));
if (!binary || dirs.length === 0) {
	console.error('usage: measure_compare.mjs <measure_sizes binary> <case dir>... [--tolerance=px]');
	process.exit(2);
}

const files = dirs.flatMap(d => fs.readdirSync(d).filter(f => f.endsWith('.mmd')).sort().map(f => path.join(d, f)));
const ours = new Map(
	execFileSync(binary, files, { encoding: 'utf8', maxBuffer: 1 << 28 })
		.trim()
		.split('\n')
		.map(line => JSON.parse(line))
		.map(r => [r.file, r]),
);

const stats = new Map();
const worst = [];
const rowMismatches = [];
function add(kind, err, detail) {
	const s = stats.get(kind) ?? { n: 0, sum: 0, max: 0 };
	s.n += 1;
	s.sum += Math.abs(err);
	s.max = Math.max(s.max, Math.abs(err));
	stats.set(kind, s);
	worst.push({ kind, err: Math.abs(err), detail });
}

function compareText(kind, file, id, mine, theirs) {
	if (!theirs) {
		if (mine && mine.width > 0) rowMismatches.push(`${file} ${kind} ${id}: Mermaid drew no text, we have ${JSON.stringify(mine.lines)}`);
		return;
	}
	if (!mine) {
		rowMismatches.push(`${file} ${kind} ${id}: no label computed, Mermaid has ${JSON.stringify(theirs.rows)}`);
		return;
	}
	if (JSON.stringify(mine.lines) !== JSON.stringify(theirs.rows)) {
		rowMismatches.push(`${file} ${kind} ${id}: rows ${JSON.stringify(mine.lines)} vs ${JSON.stringify(theirs.rows)}`);
	}
	add(`${kind} text width`, mine.width - theirs.box.width, `${file} ${id} ${JSON.stringify(mine.lines)} ${mine.width} vs ${theirs.box.width}`);
	add(`${kind} text height`, mine.height - theirs.box.height, `${file} ${id} ${mine.height} vs ${theirs.box.height}`);
}

// Cases where Mermaid's SVG labels show different text from the label it
// reads: character references stay undecoded (`&quot;` drawn as written) and
// NUL becomes U+FFFD. The Roc reader reports the decoded text, so these
// differ by design and are listed rather than counted.
const knownTextDivergence = new Set([
	'entity-codes',
	'fuzz-legacy-entity-prefix',
	'fuzz-legacy-entity-title',
	'fuzz-numeric-references',
	'fuzz-nul-in-label',
	'quirk-entity-in-edge',
]);

let cases = 0;
const skipped = [];
for (const file of files) {
	if (knownTextDivergence.has(path.basename(file, '.mmd'))) {
		skipped.push(path.basename(file, '.mmd'));
		continue;
	}
	const recordFile = file.replace(/\.mmd$/, '.oracle.json');
	if (!fs.existsSync(recordFile)) continue;
	const record = JSON.parse(fs.readFileSync(recordFile, 'utf8'));
	const mine = ours.get(file);
	if (!record.accepted || !record.layout || !mine?.accepted) continue;
	cases += 1;
	const nodes = new Map(record.layout.nodes.map(n => [n.id, n]));
	for (const node of mine.nodes) {
		const theirs = nodes.get(node.id);
		if (!theirs || theirs.missing) continue;
		compareText('node label', file, node.id, node.label, theirs.text);
		add(`${node.shape} width`, node.width - theirs.box.width, `${file} ${node.id} ${node.width} vs ${theirs.box.width}`);
		add(`${node.shape} height`, node.height - theirs.box.height, `${file} ${node.id} ${node.height} vs ${theirs.box.height}`);
	}
	mine.edges.forEach((edge, i) => {
		const theirs = record.layout.edges[i];
		if (!theirs || theirs.missing) return;
		compareText('edge label', file, edge.id, edge.label, theirs.text);
	});
	const clusters = new Map(record.layout.clusters.map(c => [c.id, c]));
	for (const group of mine.groups) {
		const theirs = clusters.get(group.id);
		if (!theirs || theirs.missing) continue;
		compareText('group title', file, group.id, group.title, theirs.text && theirs.text.box.width > 0 ? theirs.text : null);
	}
}

console.log(`${cases} cases compared; text differs by design in ${skipped.join(', ')}`);
console.log('kind'.padEnd(28), 'count'.padStart(6), 'max px'.padStart(12), 'mean px'.padStart(12));
for (const [kind, s] of [...stats].sort()) {
	console.log(kind.padEnd(28), String(s.n).padStart(6), s.max.toFixed(6).padStart(12), (s.sum / s.n).toFixed(6).padStart(12));
}
const over = worst.filter(w => w.err > tolerance).sort((a, b) => b.err - a.err);
for (const w of over.slice(0, 25)) console.log(`  ${w.err.toFixed(4)} ${w.kind}: ${w.detail}`);
for (const m of rowMismatches.slice(0, 25)) console.log(`  rows: ${m}`);
console.log(`${over.length} value(s) over ${tolerance} px, ${rowMismatches.length} row mismatch(es)`);
process.exit(over.length > 0 || rowMismatches.length > 0 ? 1 : 0);
