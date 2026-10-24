import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

// The package compiler floats: build with the latest Roc nightly on PATH, or
// the executable named by ROC.
const example = resolve(import.meta.dirname, '..');
const compiler = process.env.ROC || 'roc';

const built = spawnSync(compiler, ['build', 'main.roc', '--output=node-editor'], {
  cwd: example,
  stdio: 'inherit',
});
if (built.error) console.error(`Could not run the Roc compiler at ${compiler}: ${built.error.message}`);
process.exit(built.status ?? 1);
