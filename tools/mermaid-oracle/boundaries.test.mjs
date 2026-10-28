import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

async function exportedModules(directory) {
 const source = await fs.readFile(path.join(directory, 'main.roc'), 'utf8');
 return [...source.slice(source.indexOf('[') + 1, source.indexOf(']')).matchAll(/\b[A-Z]\w*\b/g)].map(match => match[0]);
}

async function visit(directory, roots, checkImport) {
 const seen = new Set();
 const pending = [...roots];
 while (pending.length) {
  const name = pending.pop();
  if (seen.has(name)) continue;
  seen.add(name);
  const source = await fs.readFile(path.join(directory, `${name}.roc`), 'utf8');
  for (const match of source.matchAll(/^import\s+([\w./]+)/gm)) {
   const dependency = match[1];
   checkImport(name, dependency);
   if (!dependency.includes('.')) pending.push(dependency);
  }
 }
 return seen;
}

test('the public geometry package has only local, pure geometry dependencies', async () => {
 const closure = await visit('package', await exportedModules('package'), (name, dependency) => {
  assert.match(dependency, /^[A-Z]\w*$/, `${name} imports an external dependency: ${dependency}`);
  assert.doesNotMatch(dependency, /^(Mermaid|Drawing|Svg|TextMeasure|Flowchart|Font)$/, `${name} crosses the geometric boundary`);
 });
 for (const phase of ['LayeredFlowLayers', 'LayeredFlowOrder', 'LayeredFlowPlace', 'LayeredFlowRoute', 'LayeredFlowLabels']) {
  assert.ok(closure.has(phase), `${phase} must be owned by the core production dependency graph`);
 }
});

test('Mermaid uses exported core interfaces and owns no duplicate solver phases', async () => {
 const exported = new Set(await exportedModules('package'));
 await visit('package-mermaid', await exportedModules('package-mermaid'), (name, dependency) => {
  if (dependency.startsWith('layout.')) {
   assert.ok(exported.has(dependency.slice('layout.'.length)), `${name} reaches into private core module ${dependency}`);
  }
  assert.doesNotMatch(dependency, /^FlowLayout(?:Elk|Graph|Import|Layers|Order|Place|Route|Random|Simplex|Loops)$/, `${name} retains a solver dependency in Mermaid`);
 });
 const files = await fs.readdir('package-mermaid');
 for (const phase of ['Elk', 'Graph', 'Import', 'Layers', 'Order', 'Place', 'Route', 'Random', 'Simplex', 'Loops']) {
  assert.ok(!files.includes(`FlowLayout${phase}.roc`), `duplicate Mermaid phase FlowLayout${phase}`);
 }
});
