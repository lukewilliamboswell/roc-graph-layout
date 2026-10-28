// Authoring-only browser ownership and canonical rendering environment.
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);

export const BROWSER_PLATFORM = 'linux';
export const BROWSER_ARCHITECTURE = 'x64';

// A remote Linux browser lets a native macOS executable be compared with the
// same oracle as CI. Each caller owns an isolated browser context; closing a
// session never shuts down a shared remote browser.
export async function openBrowserSession() {
 const puppeteer = require('puppeteer');
 const endpoint = process.env.MERMAID_ORACLE_BROWSER_URL;
 if (!endpoint && (process.platform !== BROWSER_PLATFORM || process.arch !== BROWSER_ARCHITECTURE)) {
  throw new Error('The canonical Mermaid oracle requires Linux x64. Set MERMAID_ORACLE_BROWSER_URL to a pinned Linux Chrome debugging URL.');
 }
 const browser = endpoint
  ? await puppeteer.connect({ browserURL: endpoint })
  : await puppeteer.launch({ headless: true, args: ['--no-sandbox', '--font-render-hinting=none'] });
 const dispose = async () => endpoint ? browser.disconnect() : browser.close();
 try {
  if (!(await browser.version()).endsWith(`/${await puppeteer.default.browserVersion()}`)) {
   throw new Error('oracle browser does not match Puppeteer\'s pinned revision');
  }
  const agent = await browser.userAgent();
  if (!agent.includes('Linux x86_64')) throw new Error('oracle browser must run on Linux x64');
  const context = await browser.createBrowserContext();
  return {
   version: () => browser.version(),
   newPage: () => context.newPage(),
   close: async () => { try { await context.close(); } finally { await dispose(); } },
  };
 } catch (error) { await dispose(); throw error; }
}
