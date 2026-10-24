// Writes a metrics-only copy of a TrueType font: everything `Font.roc` reads
// (head, hhea, maxp, OS/2, hmtx, a Unicode cmap, GSUB, GPOS) with each glyph's
// outline reduced to its bounding-box header. The result is what the package
// embeds as its default font, at a fraction of the original size; it is not
// meant for drawing.
//
//   node tools/mermaid-oracle/font_subset.mjs <in.ttf> <out.ttf>
import fs from 'node:fs';

const [input, output] = process.argv.slice(2);
if (!input || !output) {
	console.error('usage: font_subset.mjs <in.ttf> <out.ttf>');
	process.exit(2);
}

const b = fs.readFileSync(input);
const u16 = o => b.readUInt16BE(o);
const i16 = o => b.readInt16BE(o);
const u32 = o => b.readUInt32BE(o);
const tables = {};
for (let i = 0; i < u16(4); i++) {
	const r = 12 + 16 * i;
	tables[b.toString('latin1', r, r + 4)] = { off: u32(r + 8), len: u32(r + 12) };
}
const slice = tag => Buffer.from(b.subarray(tables[tag].off, tables[tag].off + tables[tag].len));
for (const tag of ['head', 'hhea', 'maxp', 'hmtx', 'cmap', 'loca', 'glyf']) {
	if (!tables[tag]) throw new Error(`${input} has no ${tag} table`);
}

const numGlyphs = u16(tables.maxp.off + 4);
const longLoca = i16(tables.head.off + 50) === 1;

// Unicode mapping from the best subtable (format 12 preferred, else format 4).
function unicodeMap() {
	const cm = tables.cmap.off;
	let best = null;
	for (let i = 0; i < u16(cm + 2); i++) {
		const p = u16(cm + 4 + 8 * i), e = u16(cm + 6 + 8 * i), o = cm + u32(cm + 8 + 8 * i);
		const unicode = p === 0 || (p === 3 && (e === 1 || e === 10));
		const fmt = u16(o);
		const score = unicode && fmt === 12 ? 2 : unicode && fmt === 4 && e !== 10 ? 1 : 0;
		if (score > (best?.score ?? 0)) best = { score, o };
	}
	const map = new Map();
	if (best.score === 2) {
		for (let i = 0; i < u32(best.o + 12); i++) {
			const r = best.o + 16 + 12 * i;
			for (let c = u32(r); c <= u32(r + 4); c++) map.set(c, u32(r + 8) + c - u32(r));
		}
	} else {
		const o = best.o, seg = u16(o + 6) / 2;
		const ends = o + 14, starts = ends + 2 * seg + 2, deltas = starts + 2 * seg, ros = deltas + 2 * seg;
		for (let i = 0; i < seg; i++) {
			const e = u16(ends + 2 * i), s = u16(starts + 2 * i), d = u16(deltas + 2 * i), ro = u16(ros + 2 * i);
			for (let c = s; c <= e && c !== 0xffff; c++) {
				let g = ro === 0 ? (c + d) & 0xffff : u16(ros + 2 * i + ro + 2 * (c - s));
				if (ro !== 0 && g !== 0) g = (g + d) & 0xffff;
				if (g !== 0) map.set(c, g);
			}
		}
	}
	return map;
}

function cmapTable() {
	const groups = [];
	for (const [c, g] of [...unicodeMap()].sort((x, y) => x[0] - y[0])) {
		if (g === 0 || g >= numGlyphs) continue;
		const last = groups[groups.length - 1];
		if (last && last.end + 1 === c && last.glyph + (last.end - last.start) + 1 === g) last.end = c;
		else groups.push({ start: c, end: c, glyph: g });
	}
	const sub = Buffer.alloc(16 + 12 * groups.length);
	sub.writeUInt16BE(12, 0);
	sub.writeUInt32BE(sub.length, 4);
	sub.writeUInt32BE(groups.length, 12);
	groups.forEach((g, i) => {
		sub.writeUInt32BE(g.start, 16 + 12 * i);
		sub.writeUInt32BE(g.end, 20 + 12 * i);
		sub.writeUInt32BE(g.glyph, 24 + 12 * i);
	});
	const head = Buffer.alloc(12);
	head.writeUInt16BE(0, 0);
	head.writeUInt16BE(1, 2);
	head.writeUInt16BE(3, 4);
	head.writeUInt16BE(10, 6);
	head.writeUInt32BE(12, 8);
	return Buffer.concat([head, sub]);
}

// Glyph headers only: numberOfContours 0 and the bounding box.
function glyfAndLoca() {
	const loca = tables.loca.off, glyf = tables.glyf.off;
	const offset = g => (longLoca ? u32(loca + 4 * g) : 2 * u16(loca + 2 * g));
	const parts = [];
	const offsets = [0];
	let at = 0;
	for (let g = 0; g < numGlyphs; g++) {
		if (offset(g + 1) - offset(g) >= 10) {
			const h = Buffer.alloc(10);
			h.writeInt16BE(0, 0);
			b.copy(h, 2, glyf + offset(g) + 2, glyf + offset(g) + 10);
			parts.push(h);
			at += 10;
		}
		offsets.push(at);
	}
	const locaOut = Buffer.alloc(2 * (numGlyphs + 1));
	offsets.forEach((o, i) => locaOut.writeUInt16BE(o / 2, 2 * i));
	return { glyf: Buffer.concat(parts), loca: locaOut };
}

const { glyf, loca } = glyfAndLoca();
const head = slice('head');
head.writeUInt32BE(0, 8); // checkSumAdjustment
head.writeInt16BE(0, 50); // short loca
const out = {
	head,
	hhea: slice('hhea'),
	maxp: slice('maxp'),
	hmtx: slice('hmtx'),
	cmap: cmapTable(),
	loca,
	glyf,
};
if (tables['OS/2']) out['OS/2'] = slice('OS/2');
if (tables.GPOS) out.GPOS = slice('GPOS');
if (tables.GSUB) out.GSUB = slice('GSUB');

const checksum = buf => {
	const padded = Buffer.concat([buf, Buffer.alloc((4 - (buf.length % 4)) % 4)]);
	let sum = 0;
	for (let i = 0; i < padded.length; i += 4) sum = (sum + padded.readUInt32BE(i)) >>> 0;
	return sum;
};

const tags = Object.keys(out).sort();
const header = Buffer.alloc(12 + 16 * tags.length);
header.writeUInt32BE(0x00010000, 0);
header.writeUInt16BE(tags.length, 4);
const pow = 2 ** Math.floor(Math.log2(tags.length));
header.writeUInt16BE(pow * 16, 6);
header.writeUInt16BE(Math.log2(pow), 8);
header.writeUInt16BE(tags.length * 16 - pow * 16, 10);
let offset = header.length;
const bodies = [];
tags.forEach((tag, i) => {
	const data = out[tag];
	const r = 12 + 16 * i;
	header.write(tag, r, 4, 'latin1');
	header.writeUInt32BE(checksum(data), r + 4);
	header.writeUInt32BE(offset, r + 8);
	header.writeUInt32BE(data.length, r + 12);
	const padded = Buffer.concat([data, Buffer.alloc((4 - (data.length % 4)) % 4)]);
	bodies.push(padded);
	offset += padded.length;
});
const file = Buffer.concat([header, ...bodies]);
const adjust = (0xb1b0afba - checksum(file)) >>> 0;
file.writeUInt32BE(adjust, header.length + bodies.slice(0, tags.indexOf('head')).reduce((n, x) => n + x.length, 0) + 8);
fs.writeFileSync(output, file);
console.log(`wrote ${output}: ${file.length} bytes, ${numGlyphs} glyphs, tables ${tags.join(' ')}`);
