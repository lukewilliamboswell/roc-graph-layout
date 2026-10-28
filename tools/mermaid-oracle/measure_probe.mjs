import { openBrowserSession } from './browser.mjs';
// Text-measurement probes against the pinned browser and font. Authoring only.
//
//   node measure_probe.mjs <file.mmd>      print the rendered SVG of one case
//   node measure_probe.mjs --eval <js>     evaluate an async function body in the page
//
// The page is set up exactly like the oracle's (same font, same configuration).
import fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { CONFIG, FONT_FAMILY, FONT_FILE } from './oracle.mjs';

const require = createRequire(import.meta.url);

export async function openPage() {
	const browser = await openBrowserSession();
	const font = (await fs.readFile(FONT_FILE)).toString('base64');
	const page = await browser.newPage();
	await page.setRequestInterception(true);
	page.on('request', request => (request.url().startsWith('data:') ? request.continue() : request.abort()));
	await page.setContent(
		`<!doctype html><html><head><style>@font-face{font-family:"${FONT_FAMILY}";src:url(data:font/ttf;base64,${font}) format("truetype");}` +
			`body{margin:0;font-family:"${FONT_FAMILY}"}</style></head><body><div id="host"></div></body></html>`,
	);
	await page.addScriptTag({ path: require.resolve('mermaid/dist/mermaid.min.js') });
	await page.evaluate(
		async (config, family) => {
			await document.fonts.load(`16px "${family}"`);
			globalThis.mermaid.initialize(config);
		},
		CONFIG,
		FONT_FAMILY,
	);
	return { browser, page };
}

async function main() {
	const args = process.argv.slice(2);
	const { browser, page } = await openPage();
	try {
		if (args[0] === '--eval') {
			const out = await page.evaluate(`(async () => { ${args[1]} })()`);
			console.log(typeof out === 'string' ? out : JSON.stringify(out, null, 1));
		} else {
			const source = await fs.readFile(args[0], 'utf8');
			const svg = await page.evaluate(async src => (await globalThis.mermaid.render('oracle', src)).svg, source);
			console.log(svg);
		}
	} finally {
		await browser.close();
	}
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) await main();
