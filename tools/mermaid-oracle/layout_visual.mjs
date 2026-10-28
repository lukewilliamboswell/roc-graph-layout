import { openBrowserSession } from './browser.mjs';
// Mermaid's flowchart rendering beside the Roc pipeline's (sizing, layout and
// drawing), for judging layout by eye. Authoring only.
//
//   roc build package-mermaid/layout_draw.roc --output=layout_draw
//   node tools/mermaid-oracle/layout_visual.mjs ./layout_draw <out-dir> <dir-or-case.mmd>... [--only name,name]
//
// Writes `<case>.png` (Mermaid left, Roc right, each at its own size and the
// same scale) and `<case>.mermaid.svg`/`<case>.roc.svg` into the output
// directory. Mermaid's SVG is reused from the output directory when present
// and newer than its source, since rendering it is the slow part.
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { FONT_FAMILY, FONT_FILE, openBrowser } from './oracle.mjs';

const require = createRequire(import.meta.url);

async function casesIn(inputs) {
	const out = [];
	for (const input of inputs) {
		const stat = await fs.stat(input);
		if (stat.isDirectory()) {
			for (const f of (await fs.readdir(input)).sort()) if (f.endsWith('.mmd')) out.push(path.join(input, f));
		} else out.push(input);
	}
	return out;
}

const mtime = async file => {
	try {
		return (await fs.stat(file)).mtimeMs;
	} catch {
		return -1;
	}
};

async function main() {
	const args = process.argv.slice(2);
	let only = null;
	const rest = [];
	for (let i = 0; i < args.length; i++) {
		if (args[i] === '--only') only = new Set(args[++i].split(','));
		else rest.push(args[i]);
	}
	const [tool, outDir, ...inputs] = rest;
	if (!tool || !outDir || inputs.length === 0) {
		console.error('usage: layout_visual.mjs <layout_draw binary> <out dir> <dir-or-case.mmd>... [--only a,b]');
		process.exit(2);
	}
	await fs.mkdir(outDir, { recursive: true });
	const cases = (await casesIn(inputs))
		.map(source => ({ source, name: path.basename(source, '.mmd') }))
		.filter(c => !only || only.has(c.name))
		.map(c => ({ ...c, roc: path.join(outDir, `${c.name}.roc.svg`), mermaid: path.join(outDir, `${c.name}.mermaid.svg`), png: path.join(outDir, `${c.name}.png`) }));
	for (const c of cases) await fs.rm(c.roc, { force: true });
	execFileSync(tool, [FONT_FAMILY, ...cases.flatMap(c => [c.source, c.roc])], { stdio: ['ignore', 'inherit', 'inherit'] });

	let mermaid = null;
	const browser = await openBrowserSession();
	const page = await browser.newPage();
	await page.setRequestInterception(true);
	page.on('request', r => (r.url().startsWith('data:') ? r.continue() : r.abort()));
	const font = (await fs.readFile(FONT_FILE)).toString('base64');
	await page.setContent(
		`<!doctype html><html><head><style>@font-face{font-family:"${FONT_FAMILY}";src:url(data:font/ttf;base64,${font}) format("truetype");}` +
			`body{margin:0;background:#fff;font:12px sans-serif}#row{display:flex;gap:24px;align-items:flex-start;padding:8px;width:max-content}` +
			`.cell{border:1px solid #ddd}.cap{color:#888;padding:2px 4px}</style></head>` +
			`<body><div id="row"><div><div class="cap">Mermaid (ELK)</div><div id="a" class="cell"></div></div><div><div class="cap">Roc</div><div id="b" class="cell"></div></div></div></body></html>`,
	);
	await page.evaluate(async family => {
		await document.fonts.load(`16px "${family}"`);
	}, FONT_FAMILY);
	try {
		for (const c of cases) {
			let rocSvg;
			try {
				rocSvg = await fs.readFile(c.roc, 'utf8');
			} catch {
				console.log(`${c.name}: not drawn by Roc`);
				continue;
			}
			let mermaidSvg = null;
			if ((await mtime(c.mermaid)) > (await mtime(c.source))) mermaidSvg = await fs.readFile(c.mermaid, 'utf8');
			else {
				mermaid ??= await openBrowser();
				const rendered = await mermaid.extract(await fs.readFile(c.source, 'utf8'));
				mermaidSvg = rendered.svg || '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="20"><text y="14">Mermaid did not render</text></svg>';
				await fs.writeFile(c.mermaid, mermaidSvg);
			}
			const size = await page.evaluate(
				(a, b) => {
					const place = (id, text) => {
						const host = document.getElementById(id);
						host.innerHTML = text;
						const svg = host.querySelector('svg');
						const vb = svg.viewBox && svg.viewBox.baseVal;
						if (vb && vb.width > 0) {
							svg.setAttribute('width', vb.width);
							svg.setAttribute('height', vb.height);
						}
						svg.style.maxWidth = 'none';
						svg.style.display = 'block';
					};
					place('a', a);
					place('b', b);
					const r = document.getElementById('row').getBoundingClientRect();
					return { width: Math.ceil(r.width), height: Math.ceil(r.height) };
				},
				mermaidSvg,
				rocSvg,
			);
			const scale = Math.min(2, 4000 / Math.max(size.width, size.height, 1));
			await page.setViewport({ width: Math.max(1, size.width), height: Math.max(1, size.height), deviceScaleFactor: scale });
			await (await page.$('#row')).screenshot({ path: c.png });
			console.log(`${c.name}: ${c.png}`);
		}
	} finally {
		await browser.close();
		if (mermaid) await mermaid.close();
	}
}

await main();
