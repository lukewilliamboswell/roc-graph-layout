// Groups disagreements between the Roc flowchart reader and Mermaid.
// Authoring only.
//
//   node triage.mjs <inspect-binary> <records-dir> [<sources-dir>]
//
// Runs the native inspector (built from inspect.roc) over each record's
// source and compares its verdict and diagram with what Mermaid did. Records
// from a corpus cache name their source file in `corpus_file`, resolved in
// <sources-dir>; named case records sit beside their `.mmd` file.
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { expectedOutcome, firstDifference } from './model.mjs';

const [inspector, recordsDir, sourcesDir] = process.argv.slice(2);

const records = [];
for (const file of (await fs.readdir(recordsDir)).filter(f => f.endsWith('.json')).sort()) {
	const record = JSON.parse(await fs.readFile(path.join(recordsDir, file), 'utf8'));
	if (!record.utf8) continue;
	const source = record.corpus_file ? path.join(sourcesDir, record.corpus_file) : path.join(recordsDir, file.replace(/\.oracle\.json$/, '.mmd'));
	records.push({ name: record.corpus_file ?? file, record, source });
}

const verdicts = new Map();
for (let i = 0; i < records.length; i += 200) {
	const batch = records.slice(i, i + 200).map(r => r.source);
	const out = execFileSync(inspector, batch, { encoding: 'utf8', maxBuffer: 1 << 28 });
	for (const line of out.split('\n').filter(Boolean)) {
		const parsed = JSON.parse(line);
		verdicts.set(parsed.file, parsed);
	}
}

const groups = new Map();
const add = (kind, name, detail) => {
	if (!groups.has(kind)) groups.set(kind, []);
	groups.get(kind).push({ name, detail });
};
let agree = 0;
let skipped = 0;
for (const { name, record, source } of records) {
	const ours = verdicts.get(source)?.result;
	const wanted = expectedOutcome(record, path.basename(name));
	const unsupported = ours && !ours.accepted && ours.problems.some(p => p.startsWith('Unsupported'));
	if (unsupported) {
		skipped += 1;
		add(`skip: ${ours.problems[0]}`, name, null);
		continue;
	}
	if (wanted.outcome === 'Rejected') {
		if (ours.accepted) add('roc accepts, mermaid rejects', name, (record.error ?? '').split('\n')[0]);
		else agree += 1;
	} else if (wanted.outcome === 'Unsupported') {
		add(`roc reads, model cannot express (${wanted.reason})`, name, ours.accepted ? 'accepted' : ours.problems[0]);
	} else if (!ours.accepted) {
		add(`mermaid accepts, roc rejects: ${ours.problems[0].replace(/near: ".*"/, 'near: …')}`, name, ours.problems[0]);
	} else {
		const diff = firstDifference(wanted.diagram, ours.diagram);
		if (diff) add(`model differs at ${diff.at.replace(/\[\d+\]/g, '[]')}`, name, diff);
		else agree += 1;
	}
}

console.log(`${records.length} inputs: ${agree} agree, ${skipped} skipped as unsupported`);
for (const [kind, items] of [...groups].sort((a, b) => b[1].length - a[1].length)) {
	console.log(`\n${items.length}  ${kind}`);
	for (const item of items.slice(0, 3)) console.log(`     ${item.name}  ${item.detail ? JSON.stringify(item.detail).slice(0, 160) : ''}`);
}
