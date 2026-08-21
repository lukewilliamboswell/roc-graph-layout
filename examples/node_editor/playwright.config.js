const { defineConfig } = require('@playwright/test');

const testPort = 18080;

module.exports = defineConfig({
  testDir: './tests',
  fullyParallel: false,
  workers: 1,
  timeout: 30_000,
  expect: { timeout: 8_000 },
  use: {
    baseURL: `http://127.0.0.1:${testPort}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  webServer: {
    command: 'node ./tests/server.mjs',
    url: `http://127.0.0.1:${testPort}`,
    reuseExistingServer: false,
    timeout: 15_000,
  },
});
