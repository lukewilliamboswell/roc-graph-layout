// Mermaid reference oracle. Authoring and CI only; never part of a Roc package.
//
// Renders Mermaid source in a pinned browser with a pinned font and records
// what Mermaid understood (its parsed model) and where it put everything (its
// layout facts). Records are cached by a key over every input that can change
// them, so a record is recomputed only when the source, Mermaid, the browser,
// the font, the configuration, or this extractor changes.
//
//   node oracle.mjs record <file.mmd | dir>...   write <name>.oracle.json beside each case
//   node oracle.mjs check  <file.mmd | dir>...   fail if any record is missing or stale (no browser)
//   node oracle.mjs corpus <input-dir> <cache-dir>  record raw fuzz corpus files by content key
//
// Options: --force recomputes even when the key matches.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// Bump when the shape or meaning of a record changes.
const EXTRACTOR_VERSION = 6;
export const FONT_FAMILY = 'Oracle Inter';
export const FONT_FILE = path.join(here, 'fonts', 'Inter-Regular.ttf');
const CASE_TIMEOUT_MS = 20000;

// Fixed configuration. HTML labels are off so every label is SVG text whose
// width is measured by the pinned font, not by HTML line breaking.
export const CONFIG = {
	startOnLoad: false,
	securityLevel: 'strict',
	deterministicIds: true,
	deterministicIDSeed: 'oracle',
	htmlLabels: false,
	fontFamily: `"${FONT_FAMILY}"`,
	themeVariables: { fontFamily: `"${FONT_FAMILY}"` },
	flowchart: { htmlLabels: false },
};

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const installedVersion = name => require(`${name}/package.json`).version;

async function provenance() {
	return {
		extractor: EXTRACTOR_VERSION,
		mermaid: installedVersion('mermaid'),
		// Puppeteer pins the exact browser build it downloads.
		puppeteer: installedVersion('puppeteer'),
		font_sha256: sha256(await fs.readFile(FONT_FILE)),
		config: CONFIG,
	};
}

const keyOf = (prov, sourceBytes) => sha256(JSON.stringify({ prov, source: sha256(sourceBytes) }));

// ---------------------------------------------------------------- browser side

// Runs inside the page. Returns a record body for one source text.
async function extractInPage(source) {
	// Some shapes are drawn with unseeded random jitter; a fixed generator,
	// reset per case, makes the markup reproducible. (mulberry32)
	let seed = 0x9e3779b9;
	Math.random = () => {
		seed = (seed + 0x6d2b79f5) | 0;
		let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
	const m = globalThis.mermaid;
	const result = { accepted: false };
	let diagram;
	try {
		diagram = await m.mermaidAPI.getDiagramFromText(source);
	} catch (error) {
		result.error = String(error && error.message ? error.message : error).slice(0, 2000);
		return result;
	}
	result.accepted = true;
	result.diagram_type = diagram.type;
	if (diagram.type !== 'flowchart-v2' && diagram.type !== 'flowchart') return result;

	const db = diagram.db;
	const textOf = value => (value === undefined || value === null ? null : String(value));
	// Stored text as a reader sees it: Mermaid's entity placeholders restored,
	// line-break tags as newlines, then HTML character references decoded.
	const display = value => {
		if (value === undefined || value === null) return null;
		const restored = String(value).replace(/ﬂ°°/g, '&#').replace(/ﬂ°/g, '&').replace(/¶ß/g, ';');
		const area = document.createElement('textarea');
		area.innerHTML = restored.replace(/<br\s*\/?>/gi, '\n');
		return area.value;
	};
	result.flowchart = {
		direction: textOf(db.getDirection()),
		nodes: [...db.getVertices().values()].map(v => ({
			id: v.id,
			text: textOf(v.text),
			label: display(v.text),
			shape: textOf(v.type),
			label_type: v.labelType,
			classes: v.classes,
			styles: v.styles,
		})),
		edges: db.getEdges().map(e => ({
			from: e.start,
			to: e.end,
			id: e.isUserDefinedId ? e.id : null,
			type: textOf(e.type),
			stroke: textOf(e.stroke),
			length: e.length ?? 1,
			text: e.text ?? '',
			label: display(e.text ?? ''),
			label_type: e.labelType,
			classes: e.classes,
		})),
		subgraphs: db.getSubGraphs().map(s => ({
			id: s.id,
			title: s.title,
			label: display(s.title),
			nodes: s.nodes,
			dir: textOf(s.dir),
			classes: s.classes,
		})),
		classes: [...db.getClasses().values()].map(c => ({ id: c.id, styles: c.styles, text_styles: c.textStyles })),
	};

	// What Mermaid hands its layout engine, after its own measurement.
	const data = db.getData();
	result.layout_input = {
		nodes: data.nodes.map(n => ({
			id: n.id,
			is_group: !!n.isGroup,
			parent: n.parentId ?? null,
			declaration_index: n.colorIndex ?? null,
			shape: n.shape ?? null,
			padding: n.padding ?? null,
			min_width: n.minWidth ?? null,
		})),
		edges: data.edges.map(e => ({
			id: e.id,
			from: e.start,
			to: e.end,
			minlen: e.minlen ?? 1,
			arrow_start: e.arrowTypeStart ?? null,
			arrow_end: e.arrowTypeEnd ?? null,
			pattern: e.pattern ?? null,
			thickness: e.thickness ?? null,
			curve: e.curve ?? null,
			styles: e.style ?? [],
		})),
	};

	// Render and read the resulting geometry in root SVG coordinates.
	const host = document.getElementById('host');
	host.replaceChildren();
	let svgText;
	try {
		svgText = (await m.render('oracle', source, host)).svg;
	} catch (error) {
		result.render_error = String(error && error.message ? error.message : error).slice(0, 2000);
		return result;
	}
	host.innerHTML = svgText;
	const svg = host.querySelector('svg');
	const toRoot = svg.getScreenCTM().inverse();
	const box = el => {
		if (!el) return null;
		const b = el.getBBox();
		const mtx = toRoot.multiply(el.getScreenCTM());
		const p = new DOMPoint(b.x, b.y).matrixTransform(mtx);
		const q = new DOMPoint(b.x + b.width, b.y + b.height).matrixTransform(mtx);
		return { x: Math.min(p.x, q.x), y: Math.min(p.y, q.y), width: Math.abs(q.x - p.x), height: Math.abs(q.y - p.y) };
	};
	const origin = el => {
		const p = new DOMPoint(0, 0).matrixTransform(toRoot.multiply(el.getScreenCTM()));
		return { x: p.x, y: p.y };
	};
	const vb = svg.viewBox.baseVal;
	// A subgraph named as an edge endpoint is also a vertex, but it is drawn
	// as a cluster rather than a node.
	const groupIds = new Set(db.getSubGraphs().map(s => s.id));
	result.layout = {
		view_box: { x: vb.x, y: vb.y, width: vb.width, height: vb.height },
		nodes: [...db.getVertices().values()].filter(v => !groupIds.has(v.id)).map(v => {
			const el = svg.querySelector(`[id="${CSS.escape(`oracle-${v.domId}`)}"]`);
			if (!el) return { id: v.id, missing: true };
			return {
				id: v.id,
				center: origin(el),
				box: box(el.querySelector('.label-container') ?? el),
				outer: box(el),
				label: box(el.querySelector('g.label text')),
			};
		}),
		clusters: db.getSubGraphs().map(s => {
			const el = svg.querySelector(`g.cluster[id="${CSS.escape(`oracle-${s.id}`)}"]`);
			if (!el) return { id: s.id, missing: true };
			return { id: s.id, box: box(el.querySelector('rect')), label: box(el.querySelector('.cluster-label text')) };
		}),
		edges: data.edges.map(e => {
			const el = svg.querySelector(`path[data-id="${CSS.escape(e.id)}"]`);
			if (!el) return { id: e.id, missing: true };
			const raw = el.getAttribute('data-points');
			const labelEl = svg.querySelector(`g.edgeLabel g.label[data-id="${CSS.escape(e.id)}"]`);
			return {
				id: e.id,
				points: raw ? JSON.parse(atob(raw)) : null,
				path: el.getAttribute('d'),
				marker_start: el.getAttribute('marker-start'),
				marker_end: el.getAttribute('marker-end'),
				label: labelEl && labelEl.querySelector('text') && labelEl.textContent.trim() !== '' ? box(labelEl.querySelector('text')) : null,
			};
		}),
	};
	// Label text as Mermaid measured it: the rendered rows and the text's own
	// box at unit scale. The boxes above are read through the page's scaling,
	// which changes how the browser lays out text by a fraction of a pixel;
	// Mermaid measured each label before the drawing had a viewBox, so drop it
	// to read the same numbers Mermaid sized its shapes from.
	svg.removeAttribute('viewBox');
	svg.removeAttribute('width');
	svg.style.maxWidth = '';
	const text = el => {
		if (!el) return null;
		const b = el.getBBox();
		const rows = [...el.querySelectorAll('tspan.text-outer-tspan')].map(row => row.textContent);
		return { rows, box: { x: b.x, y: b.y, width: b.width, height: b.height } };
	};
	for (const node of result.layout.nodes) {
		if (node.missing) continue;
		const el = svg.querySelector(`[id="${CSS.escape(`oracle-${db.getVertices().get(node.id).domId}`)}"]`);
		node.text = text(el.querySelector('g.label text'));
	}
	for (const cluster of result.layout.clusters) {
		if (cluster.missing) continue;
		const el = svg.querySelector(`g.cluster[id="${CSS.escape(`oracle-${cluster.id}`)}"]`);
		cluster.text = text(el.querySelector('.cluster-label text'));
	}
	for (const edge of result.layout.edges) {
		if (edge.missing) continue;
		const labelEl = svg.querySelector(`g.edgeLabel g.label[data-id="${CSS.escape(edge.id)}"]`);
		edge.text = labelEl && labelEl.querySelector('text') && labelEl.textContent.trim() !== '' ? text(labelEl.querySelector('text')) : null;
	}
	result.svg_sha256 = null; // filled on the Node side
	result.svg = svgText;
	return result;
}

// ------------------------------------------------------------------ node side

export async function openBrowser() {
	const puppeteer = require('puppeteer');
	// The page only loads the pinned local Mermaid bundle and the pinned font;
	// every network request is refused below. The sandbox is disabled because
	// common Linux hosts block the unprivileged namespaces Chrome needs.
	const browser = await puppeteer.launch({ headless: true, args: ['--no-sandbox', '--font-render-hinting=none'] });
	const font = (await fs.readFile(FONT_FILE)).toString('base64');
	const mermaidJs = require.resolve('mermaid/dist/mermaid.min.js');

	async function freshPage() {
		const page = await browser.newPage();
		await page.setRequestInterception(true);
		page.on('request', request => (request.url().startsWith('data:') ? request.continue() : request.abort()));
		await page.setContent(
			`<!doctype html><html><head><style>@font-face{font-family:"${FONT_FAMILY}";src:url(data:font/ttf;base64,${font}) format("truetype");}` +
				`body{margin:0;font-family:"${FONT_FAMILY}"}</style></head><body><div id="host"></div></body></html>`,
		);
		await page.addScriptTag({ path: mermaidJs });
		await page.evaluate(async (config, family) => {
			await document.fonts.load(`16px "${family}"`);
			if (!document.fonts.check(`16px "${family}"`)) throw new Error('oracle font failed to load');
			globalThis.mermaid.initialize(config);
		}, CONFIG, FONT_FAMILY);
		return page;
	}

	let page = await freshPage();
	return {
		version: await browser.version(),
		async extract(source) {
			const run = page.evaluate(extractInPage, source);
			let timer;
			const timeout = new Promise(resolve => {
				timer = setTimeout(() => resolve({ accepted: null, error: 'oracle timeout' }), CASE_TIMEOUT_MS);
			});
			const out = await Promise.race([run.catch(error => ({ accepted: null, error: `oracle failure: ${error.message}` })), timeout]);
			clearTimeout(timer);
			// A timeout or page crash leaves the page in an unknown state.
			if (out.accepted === null) {
				await page.close().catch(() => {});
				page = await freshPage();
			}
			return out;
		},
		close: () => browser.close(),
	};
}

async function record(prov, browser, sourceBytes) {
	const key = keyOf(prov, sourceBytes);
	let source;
	try {
		source = new TextDecoder('utf-8', { fatal: true }).decode(sourceBytes);
	} catch {
		return { schema: EXTRACTOR_VERSION, key, provenance: { ...prov, browser: browser.version }, utf8: false, accepted: false };
	}
	const body = await browser.extract(source);
	if (body.svg !== undefined) {
		body.svg_sha256 = sha256(body.svg);
		delete body.svg;
	}
	return { schema: EXTRACTOR_VERSION, key, provenance: { ...prov, browser: browser.version }, utf8: true, source, ...body };
}

async function caseFiles(args) {
	const out = [];
	for (const arg of args) {
		const stat = await fs.stat(arg);
		if (stat.isDirectory()) {
			for (const entry of (await fs.readdir(arg)).sort()) {
				if (entry.endsWith('.mmd')) out.push(path.join(arg, entry));
			}
		} else {
			out.push(arg);
		}
	}
	return out;
}

const recordPath = file => file.replace(/\.mmd$/, '.oracle.json');

async function storedKey(file) {
	try {
		return JSON.parse(await fs.readFile(file, 'utf8')).key;
	} catch {
		return null;
	}
}

const write = (file, value) => fs.writeFile(file, JSON.stringify(value, null, '\t') + '\n');

async function main() {
	const argv = process.argv.slice(2);
	const force = argv.includes('--force');
	const [command, ...args] = argv.filter(a => a !== '--force');
	const prov = await provenance();

	if (command === 'check') {
		let stale = 0;
		for (const file of await caseFiles(args)) {
			if ((await storedKey(recordPath(file))) !== keyOf(prov, await fs.readFile(file))) {
				console.error(`stale or missing oracle record: ${recordPath(file)}`);
				stale += 1;
			}
		}
		if (stale > 0) {
			console.error(`${stale} record(s) need: node tools/mermaid-oracle/oracle.mjs record ${args.join(' ')}`);
			process.exit(1);
		}
		return;
	}

	if (command === 'record') {
		const files = await caseFiles(args);
		const todo = [];
		for (const file of files) {
			const bytes = await fs.readFile(file);
			if (force || (await storedKey(recordPath(file))) !== keyOf(prov, bytes)) todo.push({ file, bytes });
		}
		console.log(`${files.length} case(s), ${todo.length} to record`);
		if (todo.length === 0) return;
		const browser = await openBrowser();
		try {
			for (const { file, bytes } of todo) {
				await write(recordPath(file), await record(prov, browser, bytes));
				console.log(`recorded ${recordPath(file)}`);
			}
		} finally {
			await browser.close();
		}
		return;
	}

	if (command === 'corpus') {
		const [inputDir, cacheDir] = args;
		await fs.mkdir(cacheDir, { recursive: true });
		const entries = (await fs.readdir(inputDir)).sort();
		const cached = new Set(await fs.readdir(cacheDir));
		let browser = null;
		let recorded = 0;
		try {
			for (const entry of entries) {
				const file = path.join(inputDir, entry);
				if (!(await fs.stat(file)).isFile()) continue;
				const bytes = await fs.readFile(file);
				const name = `${keyOf(prov, bytes)}.json`;
				if (!force && cached.has(name)) continue;
				browser ??= await openBrowser();
				await write(path.join(cacheDir, name), { corpus_file: entry, ...(await record(prov, browser, bytes)) });
				recorded += 1;
			}
		} finally {
			if (browser) await browser.close();
		}
		console.log(`${entries.length} corpus file(s), ${recorded} newly recorded into ${cacheDir}`);
		return;
	}

	console.error('usage: oracle.mjs record|check <file.mmd | dir>... | corpus <input-dir> <cache-dir> [--force]');
	process.exit(2);
}

// Importable for its pinned configuration and browser setup; runs only as a script.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
