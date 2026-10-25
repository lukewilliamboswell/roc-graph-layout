app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Font
import FontTest
import "FontInter.ttf" as inter_file : List(U8)

## The font reading contract on untrusted bytes: reading never crashes, is
## deterministic, and either succeeds or reports at least one problem. On
## success every metric is finite and every query is total: character
## lookups give glyphs the font has, advances and outline extents are
## finite, kerning keeps one adjustment per glyph, and substitution keeps
## its clusters in range and never grows a run past `4 n + 32` glyphs.
##
## Inputs are fonts or recipes for nearly valid fonts (see
## `FontTest.fuzz_font`): real font files, or Inter or the synthetic
## `FontTest.sample` with bytes patched or cut short.
##
## Reading cost also grows linearly: the input's bytes choose the contents
## of `FontTest.scaled` fonts, read at 2 and 16 copies; the larger must not
## take more than about 8 times the allocations, and reading must free what
## it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	font_bytes = FontTest.fuzz_font(bytes, inter_file)
	first = Font.from_bytes(font_bytes)
	if summary(first) != summary(Font.from_bytes(font_bytes)) {
		crash "reading the same bytes twice gave different results"
	}
	match first {
		Err([]) => crash "bytes were rejected without a problem"
		Err(_) => {}
		Ok(font) => check(font)
	}
	small = FontTest.scaled(bytes, 2)
	large = FontTest.scaled(bytes, 16)
	small_cost = Fuzz.measure_allocs!(|{}| Font.from_bytes(small))
	large_cost = Fuzz.measure_allocs!(|{}| Font.from_bytes(large))
	# Results are dropped inside each closure: the dev backend keeps a value
	# bound to `_` alive until its block ends, which would read as a leak.
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = Font.from_bytes(large)
			{}
		},
	)
	if large_cost.allocations > 10 * small_cost.allocations + 256 {
		crash "reading a font 8 times larger took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()}"
	}
	match large_cost.value {
		Ok(_) => Fuzz.keep
		Err(_) => crash "a scaled font was not read"
	}
}

## Code points worth asking about: the edges of the planes and of ranges
## fonts commonly map, and the characters the synthetic fonts map.
code_points : List(U32)
code_points = [0, 1, 0x20, 0x41, 0x5A, 0x61, 0x7E, 0x7F, 0xA0, 0xFF, 0x100, 0x400, 0x401, 0x2192, 0xD800, 0xFFFD, 0xFFFE, 0xFFFF, 0x10000, 0x1F600, 0x1F852, 0x10FFFF, 0x110000, 0xFFFFFFFF]

## Glyph indices worth asking about, beyond the font's own.
probe_glyphs : Font -> List(U64)
probe_glyphs = |font| {
	total = Font.glyph_total(font)
	[0, 1, 2, 3, 7, 9, 11, 30, 1805, 2936, total - 1, total, total + 1, 65535, 65536, 0xFFFFFFFFFFFFFFFF]
}

## Everything observable about a read, for comparing two reads.
summary : Try(Font, List(Font.Problem)) -> Str
summary = |result|
	match result {
		Err(problems) => Str.inspect(problems)
		Ok(font) => {
			glyphs = probe_glyphs(font)
			run = glyphs.map_with_index(|glyph, cluster| { glyph, cluster })
			Str.inspect((
				Font.units_per_em(font),
				Font.ascent(font),
				Font.descent(font),
				Font.glyph_total(font),
				code_points.map(|cp| Font.glyph(font, cp) ?? 0xFFFFFFFF),
				glyphs.map(|g| Font.advance(font, g)),
				glyphs.map(|g| Font.ink(font, g)),
				Font.kerning(font, glyphs),
				Font.substitute(font, run),
			))
		}
	}

finite : F64 -> Bool
finite = |value| F64.is_finite(value)

check : Font => {}
check = |font| {
	total = Font.glyph_total(font)
	units = Font.units_per_em(font)
	if total == 0 or !(units >= 16.0 and units <= 16384.0) or !finite(Font.ascent(font)) or !finite(Font.descent(font)) {
		crash "a font's metrics are out of range"
	}
	for cp in code_points {
		match Font.glyph(font, cp) {
			Ok(g) if g >= total => crash "a character maps to a glyph the font does not have"
			_ => {}
		}
	}
	glyphs = probe_glyphs(font)
	for g in glyphs {
		if !finite(Font.advance(font, g)) or Font.advance(font, g) < 0.0 {
			crash "an advance is not finite and non-negative"
		}
		match Font.ink(font, g) {
			Ink(box) if !finite(box.left) or !finite(box.right) or box.left > box.right => crash "an outline extent is not finite"
			_ => {}
		}
	}
	runs = [glyphs, [], [1], [7, 1, 2, 3, 1, 2], List.repeat(1, 40), FontTest.counting(64)]
	for run in runs {
		kerned = Font.kerning(font, run)
		if kerned.len() != run.len() or !kerned.all(finite) {
			crash "kerning is not one finite adjustment per glyph"
		}
		shaped = Font.substitute(font, run.map_with_index(|glyph, cluster| { glyph, cluster }))
		if shaped.len() > 4 * run.len() + 32 {
			crash "substitution grew a run of ${run.len().to_str()} glyphs to ${shaped.len().to_str()}"
		}
		if !shaped.all(|item| item.cluster < run.len()) {
			crash "substitution gave a cluster outside the run"
		}
	}
}

target = Fuzz.target_with!({
	name: "mermaid-font-read",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect(bytes.take_first(64)),
})
