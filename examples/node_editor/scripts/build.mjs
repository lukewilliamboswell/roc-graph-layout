import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

const example = resolve(import.meta.dirname, '..');
const required = readFileSync(resolve(example, '..', '..', '.roc-version'), 'utf8').trim();
const compiler = process.env.ROC || 'roc';
const version = spawnSync(compiler, ['version'], { encoding: 'utf8' });

if (version.error) {
  console.error(`Could not run the Roc compiler at ${compiler}: ${version.error.message}`);
  console.error('Set ROC to the executable for the compiler named in ../../.roc-version.');
  process.exit(1);
}

const reported = `${version.stdout}${version.stderr}`.trim();
if (!reported.includes(required)) {
  console.error(`This example requires Roc ${required}, but ${compiler} reports: ${reported}`);
  console.error('Run `ROC=/path/to/the/pinned/roc npm run build`.');
  process.exit(1);
}

const built = spawnSync(compiler, ['build', 'main.roc', '--output=node-editor'], {
  cwd: example,
  stdio: 'inherit',
});
if (built.error) console.error(`Could not run ${compiler}: ${built.error.message}`);
process.exit(built.status ?? 1);
