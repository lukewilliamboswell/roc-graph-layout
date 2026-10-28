import { openBrowserSession } from './browser.mjs';
// Pixel comparison of two SVG drawings in the pinned browser with the pinned
// font, shared by `visual.mjs` (drawing stage) and `e2e.mjs` (whole
// pipeline). Authoring only; never part of a Roc package.
import fs from 'node:fs/promises';
import { createRequire } from 'node:module';
import { FONT_FAMILY, FONT_FILE } from './oracle.mjs';

const require = createRequire(import.meta.url);

// Device pixels per CSS pixel in the comparison images.
export const SCALE = 2;

// The family names the pinned font is registered under: the oracle's, and
// the one `Mermaid.svg` names, so a document from the public API renders
// with the same font as Mermaid's.
const FAMILIES = [FONT_FAMILY, 'Inter'];

// Launches a browser with one page set up for `compare`.
export async function openRaster() {
	const browser = await openBrowserSession();
	const page = await browser.newPage();
	await page.setRequestInterception(true);
	page.on('request', request => (request.url().startsWith('data:') ? request.continue() : request.abort()));
	await page.setViewport({ width: 1200, height: 800, deviceScaleFactor: SCALE });
	const font = (await fs.readFile(FONT_FILE)).toString('base64');
	const faces = FAMILIES.map(f => `@font-face{font-family:"${f}";src:url(data:font/ttf;base64,${font}) format("truetype");}`).join('');
	await page.setContent(
		`<!doctype html><html><head><style>${faces}` +
			`body{margin:0;background:#fff}.cell{display:inline-block;background:#fff;line-height:0;vertical-align:top}</style></head>` +
			`<body><div id="a" class="cell"></div><div id="b" class="cell"></div></body></html>`,
	);
	await page.evaluate(async families => {
		for (const family of families) {
			await document.fonts.load(`16px "${family}"`);
			if (!document.fonts.check(`16px "${family}"`)) throw new Error(`font ${family} failed to load`);
		}
	}, FAMILIES);
	return { page, close: () => browser.close() };
}

// The view box an SVG document declares, or null.
export function viewBoxOf(svgText) {
	const m = /<svg\b[^>]*\bviewBox="([^"]*)"/.exec(svgText);
	if (!m) return null;
	const [x, y, width, height] = m[1].trim().split(/[\s,]+/).map(Number);
	return [x, y, width, height].every(Number.isFinite) ? { x, y, width, height } : null;
}

// Renders each SVG at its own view box size (one CSS pixel per unit), with
// the view boxes' top left corners aligned, screenshots each, and compares
// them in the page over the larger of the two sizes (the smaller drawing is
// padded with white). Returns the scores and a PNG (data URL) of Mermaid |
// Roc | difference, where red marks pixels only the second image draws and
// blue pixels only the first draws.
//
// `score` is the share of inked pixels (in either image) that the other
// image does not match within one CSS pixel; `strict` is the share that
// differs in place. With `maxShift` (CSS pixels), the second image is also
// translated by the whole device pixels within that reach that best overlay
// the first, giving `shift` and `shifted_score`, and a fourth panel with
// that difference when the shift is not zero: a drawing displaced as a
// whole scores badly in place but well shifted.
export async function compare(page, svgA, boxA, svgB, boxB = boxA, { maxShift = 0 } = {}) {
	const size = box => ({ w: Math.max(1, Math.ceil(box.width)), h: Math.max(1, Math.ceil(box.height)) });
	const a = size(boxA);
	const b = size(boxB);
	const cap = v => Math.min(8000, v);
	await page.setViewport({ width: cap(a.w + b.w + 40), height: cap(Math.max(a.h, b.h) + 20), deviceScaleFactor: SCALE });
	await page.evaluate(
		(textA, textB, sa, sb, va, vb) => {
			const place = (id, text, s, view) => {
				const host = document.getElementById(id);
				host.innerHTML = text;
				const svg = host.querySelector('svg');
				// Expand only the white raster cell, preserving one CSS pixel per
				// SVG unit. Rounding the viewport alone would rescale the drawing.
				svg.setAttribute('viewBox', `${view.x} ${view.y} ${s.w} ${s.h}`);
				svg.setAttribute('width', s.w);
				svg.setAttribute('height', s.h);
				svg.style.maxWidth = 'none';
				svg.style.display = 'block';
				svg.style.width = `${s.w}px`;
				svg.style.height = `${s.h}px`;
				svg.style.clipPath = `inset(0 ${s.w-view.width}px ${s.h-view.height}px 0)`;
				const transform = svg.getScreenCTM();
				if (Math.abs(transform.a-1)>1e-9 || Math.abs(transform.d-1)>1e-9 || transform.b!==0 || transform.c!==0) throw new Error('raster comparison rescaled an SVG');
				host.style.width = `${s.w}px`;
				host.style.height = `${s.h}px`;
			};
			place('a', textA, sa, va);
			place('b', textB, sb, vb);
		},
		svgA,
		svgB,
		a,
		b,
		boxA,
		boxB,
	);
	const shotA = await (await page.$('#a')).screenshot({ encoding: 'base64' });
	const shotB = await (await page.$('#b')).screenshot({ encoding: 'base64' });
	return page.evaluate(
		async (a, b, scale, maxShift) => {
			const load = src =>
				new Promise((resolve, reject) => {
					const img = new Image();
					img.onload = () => resolve(img);
					img.onerror = reject;
					img.src = `data:image/png;base64,${src}`;
				});
			const [ia, ib] = await Promise.all([load(a), load(b)]);
			const w = Math.max(ia.width, ib.width);
			const h = Math.max(ia.height, ib.height);
			const pixels = (img, dx = 0, dy = 0) => {
				const c = document.createElement('canvas');
				c.width = w;
				c.height = h;
				const ctx = c.getContext('2d');
				ctx.fillStyle = '#fff';
				ctx.fillRect(0, 0, w, h);
				ctx.drawImage(img, dx, dy);
				return ctx.getImageData(0, 0, w, h).data;
			};
			const close = (p, i, q, j) => Math.max(Math.abs(p[i] - q[j]), Math.abs(p[i + 1] - q[j + 1]), Math.abs(p[i + 2] - q[j + 2])) <= 40;
			const inked = (p, i) => p[i] + p[i + 1] + p[i + 2] < 3 * 250;
			const radius = scale; // one CSS pixel
			// Scores `pb` against `pa`, painting the difference into `diff`.
			const judge = (pa, pb, diff) => {
				const matchedNear = (p, q, x, y) => {
					const i = (y * w + x) * 4;
					for (let dy = -radius; dy <= radius; dy++) {
						const yy = y + dy;
						if (yy < 0 || yy >= h) continue;
						for (let dx = -radius; dx <= radius; dx++) {
							const xx = x + dx;
							if (xx < 0 || xx >= w) continue;
							if (close(p, i, q, (yy * w + xx) * 4)) return true;
						}
					}
					return false;
				};
				let ink = 0;
				let strict = 0;
				let loose = 0;
				for (let y = 0; y < h; y++) {
					for (let x = 0; x < w; x++) {
						const i = (y * w + x) * 4;
						const shade = 255 - Math.round((255 - (pa[i] + pa[i + 1] + pa[i + 2]) / 3) * 0.25);
						diff.data[i] = shade;
						diff.data[i + 1] = shade;
						diff.data[i + 2] = shade;
						diff.data[i + 3] = 255;
						if (!inked(pa, i) && !inked(pb, i)) continue;
						ink += 1;
						if (!close(pa, i, pb, i)) strict += 1;
						const aMissing = !matchedNear(pa, pb, x, y);
						const bMissing = !matchedNear(pb, pa, x, y);
						if (aMissing || bMissing) {
							loose += 1;
							// red: the second image's pixel has no match in the first; blue: the reverse.
							if (bMissing && inked(pb, i)) {
								diff.data[i] = 230;
								diff.data[i + 1] = 30;
								diff.data[i + 2] = 30;
							} else {
								diff.data[i] = 30;
								diff.data[i + 1] = 80;
								diff.data[i + 2] = 230;
							}
						}
					}
				}
				return { ink, strict: ink ? strict / ink : 0, score: ink ? loose / ink : 0 };
			};
			// The whole-device-pixel translation of the second image, within
			// `maxShift` CSS pixels, under which most of the first image's ink
			// lands on ink; ties go to the smaller shift.
			const bestShift = (pa, pb) => {
				const reach = Math.round(maxShift * scale);
				const ink = [];
				for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (inked(pa, (y * w + x) * 4)) ink.push(y * w + x);
				const mask = new Uint8Array(w * h);
				for (let k = 0; k < w * h; k++) mask[k] = inked(pb, k * 4) ? 1 : 0;
				let best = { dx: 0, dy: 0, hits: -1 };
				for (let dy = -reach; dy <= reach; dy++) {
					for (let dx = -reach; dx <= reach; dx++) {
						let hits = 0;
						for (const k of ink) {
							const x = (k % w) - dx;
							const y = Math.floor(k / w) - dy;
							if (x >= 0 && x < w && y >= 0 && y < h) hits += mask[y * w + x];
						}
						const better = hits > best.hits || (hits === best.hits && Math.abs(dx) + Math.abs(dy) < Math.abs(best.dx) + Math.abs(best.dy));
						if (better) best = { dx, dy, hits };
					}
				}
				return best;
			};
			const pa = pixels(ia);
			const pb = pixels(ib);
			const shift = maxShift > 0 ? bestShift(pa, pb) : { dx: 0, dy: 0 };
			const shifted = shift.dx !== 0 || shift.dy !== 0;
			const panels = shifted ? 4 : 3;
			const out = document.createElement('canvas');
			out.width = w * panels;
			out.height = h;
			const octx = out.getContext('2d');
			octx.fillStyle = '#fff';
			octx.fillRect(0, 0, w * panels, h);
			octx.drawImage(ia, 0, 0);
			octx.drawImage(ib, w, 0);
			const diff = octx.createImageData(w, h);
			const result = judge(pa, pb, diff);
			octx.putImageData(diff, w * 2, 0);
			let moved = result;
			if (shifted) {
				const diff2 = octx.createImageData(w, h);
				moved = judge(pa, pixels(ib, shift.dx, shift.dy), diff2);
				octx.putImageData(diff2, w * 3, 0);
			}
			return {
				...result,
				shift: { dx: shift.dx / scale, dy: shift.dy / scale },
				shifted_score: moved.score,
				png: out.toDataURL('image/png'),
			};
		},
		shotA,
		shotB,
		SCALE,
		maxShift,
	);
}

// Writes a comparison's PNG data URL to a file.
export const writePng = (file, dataUrl) => fs.writeFile(file, Buffer.from(dataUrl.split(',')[1], 'base64'));
