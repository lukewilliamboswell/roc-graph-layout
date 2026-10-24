app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Font
import FontTest
import FlowGeometry
import TextMeasure
import "FontInter.ttf" as inter_file : List(U8)

## The shaping and measuring contract on arbitrary text. The input is the
## text's bytes (read as UTF-8, invalid sequences replaced), then
## optionally a 0xFF byte (never part of UTF-8) and a font: a real font
## file or a recipe for a nearly valid one, as the font reading target
## takes them (see `FontTest.fuzz_font`). Without a font, or with one that
## cannot be read, the text is shaped with Inter.
##
## Substitution is deterministic, keeps every glyph's cluster inside the
## run, and never gives more than `4 n + 32` glyphs for `n` characters
## (at most 36 per character); kerning gives one finite adjustment per
## glyph. Measuring is deterministic and gives finite, non-negative sizes.
## Measuring 8 times the text (16 against 2 copies on one line, or 128
## against 16 copies when both wrap) must not take more than about 8 times
## the allocations, and must free what it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	split = split_at_marker(bytes)
	read = if (split.font.is_empty()) Err([]) else Font.from_bytes(FontTest.fuzz_font(split.font, inter_file))
	font = read ?? Font.inter
	# Inter's lines have height. Another font's ascent and descent may add up
	# to nothing (or less), and then its lines have none.
	tall = read.is_err()
	text = Str.from_utf8_lossy(split.text)
	code_points = decode(text.to_utf8())
	n = code_points.len()
	missing = Font.glyph_total(font)
	items = code_points.map_with_index(|cp, i| { glyph: Font.glyph(font, cp) ?? missing, cluster: i })
	shaped = Font.substitute(font, items)
	if shaped != Font.substitute(font, items) {
		crash "substituting the same run twice gave different glyphs"
	}
	if shaped.len() > 4 * n + 32 or (n > 0 and shaped.len() > 36 * n) {
		crash "substitution turned ${n.to_str()} characters into ${shaped.len().to_str()} glyphs"
	}
	if !shaped.all(|item| item.cluster < n) {
		crash "substitution gave a cluster outside the run"
	}
	glyphs = shaped.map(|item| item.glyph)
	kerned = Font.kerning(font, glyphs)
	if kerned.len() != glyphs.len() or !kerned.all(|k| F64.is_finite(k)) {
		crash "kerning is not one finite adjustment per glyph"
	}
	style = { font, size: 14.0, line_height: 1.1, wrap: Width(120.0), align: Middle }
	measured = TextMeasure.block(text, style)
	if measured != TextMeasure.block(text, style) {
		crash "measuring the same text twice gave different sizes"
	}
	if !block_ok(measured, tall) or !block_ok(TextMeasure.block(text, { ..style, wrap: NoWrap, align: Start }), tall) {
		crash "a measured size is not finite and non-negative"
	}
	# Unwrapped, 2 and 16 copies are both one line per line of the text.
	unwrapped = { ..style, wrap: NoWrap }
	scaling!(repeated(text, 2), repeated(text, 16), unwrapped)
	# Wrapped, compare only when 16 copies already wrap, so both sizes
	# break lines (a single line costs less per character than several).
	wraps = TextMeasure.block(repeated(text, 16), style).lines.len() > TextMeasure.block(repeated(text, 16), unwrapped).lines.len()
	if wraps {
		scaling!(repeated(text, 16), repeated(text, 128), style)
	}
	Fuzz.keep
}

split_at_marker : List(U8) -> { text : List(U8), font : List(U8) }
split_at_marker = |bytes| {
	var $i = 0
	while $i < bytes.len() and (bytes.get($i) ?? 0) != 0xFF {
		$i = $i + 1
	}
	{ text: bytes.take_first($i), font: bytes.drop_first($i + 1) }
}

## Code points of valid UTF-8.
decode : List(U8) -> List(U32)
decode = |bytes| {
	var $out = []
	var $i = 0
	while $i < bytes.len() {
		b = (bytes.get($i) ?? 0).to_u32()
		len = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4
		var $cp = if (len == 1) b else if (len == 2) b.bitwise_and(0x1F) else if (len == 3) b.bitwise_and(0x0F) else b.bitwise_and(0x07)
		for k in 1..<len {
			$cp = $cp.shl_wrap(6).bitwise_or((bytes.get($i + k) ?? 0).to_u32().bitwise_and(0x3F))
		}
		$out = $out.append($cp)
		$i = $i + len
	}
	$out
}

## Up to 64 bytes' worth of the text, repeated.
repeated : Str, U64 -> Str
repeated = |text, copies| {
	piece = Str.from_utf8_lossy(text.to_utf8().take_first(64))
	Str.join_with(List.repeat(piece, copies), " ")
}

## Measuring 8 times the text costs about 8 times the allocations, and
## frees them all.
scaling! : Str, Str, TextMeasure.Style => {}
scaling! = |small, large, style| {
	small_cost = Fuzz.measure_allocs!(|{}| TextMeasure.block(small, style))
	large_cost = Fuzz.measure_allocs!(|{}| TextMeasure.block(large, style))
	Fuzz.expect_no_leaks!(|{}| TextMeasure.block(large, style))
	if large_cost.allocations > 10 * small_cost.allocations + 256 {
		crash "measuring 8 times the text took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()}"
	}
}

valid : F64 -> Bool
valid = |value| F64.is_finite(value) and value >= 0.0

block_ok : FlowGeometry.TextBlock, Bool -> Bool
block_ok = |b, tall| valid(b.width) and valid(b.height) and (!tall or b.width == 0.0 or b.height > 0.0)

target = Fuzz.target_with!({
	name: "mermaid-font-shape",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(split_at_marker(bytes).text)),
})
