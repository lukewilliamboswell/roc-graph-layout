import { spawn } from 'node:child_process';
import { rmSync as remove } from 'node:fs';
import { resolve } from 'node:path';

const directory = resolve(import.meta.dirname, '..');
const database = resolve(directory, 'node_editor.playwright.db');
for (const suffix of ['', '-shm', '-wal']) remove(`${database}${suffix}`, { force: true });

const server = spawn(resolve(directory, 'node-editor'), [], {
  cwd: directory,
  env: { ...process.env, ROC_GRAPH_LAYOUT_NODE_EDITOR_DB: database, ROC_GRAPH_LAYOUT_NODE_EDITOR_PORT: '18080' },
  stdio: ['inherit', 'pipe', 'pipe'],
});

const expectedDisconnect = 'Client disconnected before finishing an HTTP request.';
const forwardServerOutput = (stream, destination) => {
  let buffered = '';
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    buffered += chunk;
    const lines = buffered.split('\n');
    buffered = lines.pop() ?? '';
    for (const line of lines) {
      if (!line.includes(expectedDisconnect)) destination.write(`${line}\n`);
    }
  });
  stream.on('end', () => {
    if (buffered && !buffered.includes(expectedDisconnect)) destination.write(buffered);
  });
};

forwardServerOutput(server.stdout, process.stdout);
forwardServerOutput(server.stderr, process.stderr);

const stop = signal => {
  if (!server.killed) server.kill(signal);
};
process.on('SIGINT', () => stop('SIGINT'));
process.on('SIGTERM', () => stop('SIGTERM'));
server.on('exit', code => process.exit(code ?? 0));
