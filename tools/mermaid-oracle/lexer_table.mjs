// Prints the flowchart lexer exactly as the pinned Mermaid bundle compiled it:
// each state's rules, in the order jison tries them, with their regexes.
// The Roc port in package-mermaid/FlowLexer.roc must agree with this table.
// Authoring only.
//
//   node lexer_table.mjs [state...]
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const chunks = path.join(path.dirname(require.resolve('mermaid/package.json')), 'dist/chunks/mermaid.esm');
const file = fs
	.readdirSync(chunks)
	.map(f => path.join(chunks, f))
	.find(f => /DOUBLECIRCLESTART/.test(fs.readFileSync(f, 'utf8')) && /conditions: \{ "shapeDataEndBracket"/.test(fs.readFileSync(f, 'utf8')));
const source = fs.readFileSync(file, 'utf8');
// The compiled lexer is plain object literal syntax; evaluate just its two
// tables (the bundle is the pinned, locally installed Mermaid).
const rules = new Function(`return ${source.match(/rules: (\[\/\^.*\]),\n/)[1]}`)();
const conditions = new Function(`return ${source.match(/conditions: (\{ "shapeDataEndBracket".*\})\n/)[1]}`)();

const wanted = process.argv.slice(2);
for (const [state, { rules: indices }] of Object.entries(conditions)) {
	if (wanted.length > 0 && !wanted.includes(state)) continue;
	console.log(`\n${state}`);
	for (const i of indices) {
		const text = rules[i].source.replace(/^\^\(\?:/, '').replace(/\)$/, '');
		console.log(`  ${String(i).padStart(3)}  ${text.length > 110 ? text.slice(0, 107) + '...' : text}`);
	}
}
