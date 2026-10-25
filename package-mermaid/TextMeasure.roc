import "FontInter.ttf" as inter_file : List(U8)
import font.Font
import Bytes
import FlowGeometry

## Lays out label text as Mermaid does when it draws labels as SVG text, and
## measures the result the way a browser measures it. The text is a label as
## displayed, such as `Flowchart` reads it: line-break tags already turned
## into newlines and character references decoded.
##
## Text breaks into lines at newlines and at a literal `\n`. Each line is
## read as words separated by white space, so runs of white space collapse
## to one space. Unlike Mermaid, which drops `>` from text that has no `<`,
## every character is kept. With a wrapping width, words move to the next line once a
## line would grow wider than it, and a word wider than it on its own is
## split between characters.
##
## A line's width is the sum of its glyph advances with pair kerning, word
## by word, extended where a glyph's outline reaches past its advance. A
## block's height runs from the top of its first non-empty line to the
## bottom of its last: `line_height` times the font size per line step,
## plus the font's ascent and descent rounded to whole pixels. A block
## without any text measures 0 by 0.
##
## Characters the font has no glyph for are measured as Chrome on Linux
## draws them from its fallback fonts: wide East Asian characters take one
## em, emoji the advance of Noto Color Emoji (about 1.25 em), invisible
## format characters nothing, and anything else the width of the font's
## missing-glyph box. A line with such an emoji reaches 0.25 em below the
## baseline, as the emoji font does.
TextMeasure :: {}.{

	## Inter Regular (version 4, SIL Open Font License 1.1), the font the
	## Mermaid comparisons are measured with, as a metrics-only file: its
	## outlines are reduced to their bounding boxes.
	inter : Font
	inter = match Font.from_bytes(inter_file, Font.ReadOptions.{}) {
		Ok(font) => font
		# Evaluated when the package is compiled, so a file that does not read
		# fails the build; a test below also checks it.
		Err(_) => crash "FontInter.ttf does not read as a font"
	}

	## `align` is how lines line up with each other: `Middle` centres each line
	## on the block, `Start` starts every line at the same place. It only
	## changes the width of a block whose lines overhang differently.
	Style : { font : Font, size : F64, line_height : F64, wrap : [Width(F64), NoWrap], align : [Start, Middle] }

	block : Str, Style -> FlowGeometry.TextBlock
	block = |text, style| {
		metrics = TextMeasure.metrics_of(style)
		bytes = text.to_utf8()
		escaped = bytes.contains('<')
		var $rows = []
		for raw in TextMeasure.split_lines(bytes) {
			words = TextMeasure.line_words(raw, escaped)
			$rows = match style.wrap {
				Width(limit) => $rows.concat(TextMeasure.wrap(metrics, words, limit))
				NoWrap => $rows.append(words)
			}
		}
		var $found = False
		var $first = 0
		var $last = 0
		var $low = 0.0
		var $high = 0.0
		var $top = 0.0
		var $bottom = 0.0
		var $index = $rows.len() - $rows.len()
		var $lines = List.with_capacity($rows.len())
		for row in $rows {
			$lines = $lines.append(Str.join_with(row.map(|word| Str.from_utf8_lossy(word)), " "))
			if !row.is_empty() {
				extent = TextMeasure.line_extent(metrics, row)
				shift = match style.align {
					Middle => -extent.advance / 2.0
					Start => 0.0
				}
				if !$found {
					$low = extent.left + shift
					$high = extent.right + shift
					$top = extent.ascent
					$first = $index
					$found = True
				} else {
					$low = $low.min(extent.left + shift)
					$high = $high.max(extent.right + shift)
				}
				$bottom = extent.descent
				$last = $index
			}
			$index = $index + 1
		}
		if !$found {
			{ lines: $lines, width: 0.0, height: 0.0 }
		} else {
			step = style.line_height * style.size
			height = ($last - $first).to_f64() * step + $top + $bottom
			{ lines: $lines, width: TextMeasure.finite($high - $low), height: TextMeasure.finite(height) }
		}
	}

	finite : F64 -> F64
	finite = |value| if (F64.is_finite(value) and value > 0.0) value else 0.0

	# Per-style constants: the shaping plan, fixed-point scale (1/65536 px per
	# font unit step), and the rounded ascent and descent of the font and of
	# the emoji fallback font.
	Metrics : { font : Font, plan : Font.ShapePlan, size : F64, scale : F64, em : F64, ascent : F64, descent : F64, emoji_ascent : F64, emoji_descent : F64 }

	metrics_of : Style -> Metrics
	metrics_of = |style| {
		units = Font.units_per_em(style.font).to_f64()
		vertical = Font.metrics(style.font)
		size = if (F64.is_finite(style.size) and style.size > 0.0) style.size else 0.0
		pixels = size / units
		{
			font: style.font,
			# Characters, not graphemes: a glyph's cluster is its first
			# character, as a browser splits words between characters.
			plan: Font.plan(style.font, Font.ShapeOptions.{ clusters: Characters }),
			size,
			scale: size * 65536.0 / units,
			em: size,
			ascent: TextMeasure.round(vertical.ascent.to_f64() * pixels),
			descent: TextMeasure.round(vertical.descent.to_f64() * pixels),
			emoji_ascent: TextMeasure.round(0.95 * size),
			emoji_descent: TextMeasure.round(0.25 * size),
		}
	}

	sum : List(F64) -> F64
	sum = |values| values.fold(0.0, |total, value| total + value)

	floor : F64 -> F64
	floor = |value| value.div_floor_by(1.0)

	ceil : F64 -> F64
	ceil = |value| -((-value).div_floor_by(1.0))

	round : F64 -> F64
	round = |value| TextMeasure.floor(value + 0.5)

	# ------------------------------------------------------------ lines and words

	## Raw lines: breaks at `\n` and at a backslash followed by `n`.
	split_lines : List(U8) -> List(List(U8))
	split_lines = |bytes| {
		var $lines = []
		var $start = 0
		var $i = 0
		while $i < bytes.len() {
			b = Bytes.at(bytes, $i)
			skip = if b == '\n' {
				1
			} else if b == '\\' and Bytes.at(bytes, $i + 1) == 'n' {
				2
			} else {
				0
			}
			if skip > 0 {
				$lines = $lines.append(bytes.sublist({ start: $start, len: $i - $start }))
				$i = $i + skip
				$start = $i
			} else {
				$i = $i + 1
			}
		}
		$lines.append(bytes.sublist({ start: $start, len: bytes.len() - $start }))
	}

	## Words of one line, separated by white space. Mermaid passes label text
	## through an HTML sanitizer that escapes `<`, `>` and the no-break space
	## only when the text contains a `<`; otherwise a no-break space separates
	## words like any other space. In that case Mermaid's word pattern also
	## drops every `>`, which deletes what the author wrote, so here `>` is an
	## ordinary character: `a -> b` keeps its arrow. This is a deliberate
	## difference from Mermaid.
	line_words : List(U8), Bool -> List(List(U8))
	line_words = |line, escaped| {
		var $words = []
		var $i = 0
		while $i < line.len() {
			space = TextMeasure.separator_len(line, $i, escaped)
			if space > 0 {
				$i = $i + space
			} else {
				var $j = $i
				while $j < line.len() and TextMeasure.separator_len(line, $j, escaped) == 0 {
					$j = $j + Bytes.char_len(Bytes.at(line, $j))
				}
				end = $j.min(line.len())
				$words = $words.append(line.sublist({ start: $i, len: end - $i }))
				$i = end
			}
		}
		$words
	}

	separator_len : List(U8), U64, Bool -> U64
	separator_len = |bytes, at, escaped| {
		b = Bytes.at(bytes, at)
		if escaped and b == 0xC2 and Bytes.at(bytes, at + 1) == 0xA0 {
			0
		} else {
			Bytes.space_len(bytes, at)
		}
	}

	# ------------------------------------------------------------ wrapping

	## Mermaid's greedy wrapping: a line takes words while it fits; a word that
	## does not fit on an empty line is split after as many whole characters
	## as fit (at least one), and the rest continues as the next word.
	wrap : Metrics, List(List(U8)), F64 -> List(List(List(U8)))
	wrap = |metrics, words, limit| {
		if TextMeasure.row_width(metrics, words) <= limit {
			[words]
		} else {
			# Pending words, last to be taken first.
			var $pending = words.fold_rev([], |word, stack| stack.append(word))
			var $rows = []
			var $row = []
			var $width = 0.0
			while !$pending.is_empty() {
				next = $pending.last() ?? []
				$pending = $pending.drop_last(1)
				added = if ($row.is_empty()) TextMeasure.fragment_width(metrics, next, False) else TextMeasure.fragment_width(metrics, next, True)
				if $width + added <= limit {
					$row = $row.append(next)
					$width = $width + added
				} else if !$row.is_empty() {
					$rows = $rows.append($row)
					$pending = $pending.append(next)
					$row = []
					$width = 0.0
				} else {
					split = TextMeasure.split_word(metrics, next, limit)
					$rows = $rows.append([split.head])
					if !split.rest.is_empty() {
						$pending = $pending.append(split.rest)
					}
				}
			}
			if !$row.is_empty() {
				$rows = $rows.append($row)
			}
			$rows
		}
	}

	row_width : Metrics, List(List(U8)) -> F64
	row_width = |metrics, row| {
		var $width = 0.0
		var $index = 0
		for word in row {
			$width = $width + TextMeasure.fragment_width(metrics, word, $index > 0)
			$index = $index + 1
		}
		$width
	}

	split_word : Metrics, List(U8), F64 -> { head : List(U8), rest : List(U8) }
	split_word = |metrics, word, limit| {
		shaped = TextMeasure.shape(metrics, word)
		clusters = TextMeasure.clusters(word)
		# `ends` are byte offsets where clusters end; a glyph lies inside a
		# prefix when the byte offset of its first character does.
		# Each candidate prefix of whole characters is shaped on its own, as the
		# browser measures it: ligatures and contextual forms can differ at its
		# end. Past a budget of shaped characters, a prefix is measured from the
		# whole word's glyphs instead (those whose first character lies inside
		# it), which keeps the cost linear for pathological words.
		var $taken = 0
		var $characters = 0
		var $glyphs = 0
		var $sum = 0.0
		var $budget = 4096
		var $going = True
		var $c = 0
		while $going and $c < clusters.len() {
			cluster = clusters.get($c) ?? { end: word.len(), code_points: 1 }
			end = $characters + cluster.code_points
			var $candidate = $sum
			var $k = $glyphs
			while $k < shaped.clusters.len() and (shaped.clusters.get($k) ?? cluster.end) < cluster.end {
				$candidate = $candidate + (shaped.advances.get($k) ?? 0.0)
				if $k > 0 {
					$candidate = $candidate + (shaped.pairs.get($k - 1) ?? 0.0)
				}
				$k = $k + 1
			}
			width = if $budget >= end {
				$budget = $budget - end
				TextMeasure.fragment_width(metrics, word.sublist({ start: 0, len: cluster.end }), False)
			} else {
				TextMeasure.pixels64($candidate)
			}
			if width <= limit {
				$sum = $candidate
				$glyphs = $k
				$characters = end
				$taken = cluster.end
				$c = $c + 1
			} else {
				$going = False
			}
		}
		head_len = if $taken == 0 {
			(clusters.first() ?? { end: word.len(), code_points: 1 }).end
		} else {
			$taken
		}
		{ head: word.sublist({ start: 0, len: head_len }), rest: word.sublist({ start: head_len, len: word.len() - head_len }) }
	}

	## Character boundaries a browser keeps together when it splits a word:
	## combining marks, variation selectors, emoji modifiers and tags, the
	## character after a zero-width joiner, and regional indicator pairs stay
	## with what precedes them.
	clusters : List(U8) -> List({ end : U64, code_points : U64 })
	clusters = |bytes| {
		var $out = []
		var $i = 0
		var $previous = 0
		var $regional_run = 0
		while $i < bytes.len() {
			cp = Bytes.code_point(bytes, $i)
			next = $i + Bytes.char_len(Bytes.at(bytes, $i))
			regional = cp >= 0x1F1E6 and cp <= 0x1F1FF
			joins = $i > 0 and (TextMeasure.is_extender(cp) or $previous == 0x200D or (regional and $regional_run % 2 == 1))
			$regional_run = if (regional) $regional_run + 1 else 0
			if joins and !$out.is_empty() {
				last = $out.last() ?? { end: 0, code_points: 0 }
				# `$out` is not empty here.
				$out = $out.set($out.len() - 1, { end: next.min(bytes.len()), code_points: last.code_points + 1 }) ?? []
			} else {
				$out = $out.append({ end: next.min(bytes.len()), code_points: 1 })
			}
			$previous = cp
			$i = next
		}
		$out
	}

	is_extender : U32 -> Bool
	is_extender = |cp|
		(cp >= 0x0300 and cp <= 0x036F)
			or (cp >= 0x1AB0 and cp <= 0x1AFF)
			or (cp >= 0x1DC0 and cp <= 0x1DFF)
			or (cp >= 0x20D0 and cp <= 0x20FF)
			or (cp >= 0xFE20 and cp <= 0xFE2F)
			or (cp >= 0xFE00 and cp <= 0xFE0F)
			or cp == 0x200D
			or (cp >= 0x1F3FB and cp <= 0x1F3FF)
			or (cp >= 0xE0020 and cp <= 0xE007F)
			or (cp >= 0xE0100 and cp <= 0xE01EF)

	# ------------------------------------------------------------ shaping

	## Glyphs of one run after substitution: their advances and the kerning
	## between neighbours in 1/65536 px steps, their outline extents, and the
	## byte offset of the first character each draws.
	Shaped : { advances : List(F64), pairs : List(F64), ink : List([Ink({ left : F64, right : F64 }), NoInk]), clusters : List(U64) }

	shape : Metrics, List(U8) -> Shaped
	shape = |metrics, bytes| {
		font = metrics.font
		var $scalars = []
		var $i = 0
		while $i < bytes.len() {
			$scalars = $scalars.append({ scalar: Bytes.code_point(bytes, $i), offset: $i })
			$i = $i + Bytes.char_len(Bytes.at(bytes, $i))
		}
		run = Font.shape_scalars(font, metrics.plan, $scalars)
		count = run.glyphs.len()
		var $advances = List.with_capacity(count)
		var $pairs = List.with_capacity(count)
		var $ink = List.with_capacity(count)
		var $k = 0
		while $k < count {
			glyph = run.glyphs.get($k) ?? 0
			# The run's advance is the glyph's own plus its kerning; they are
			# rounded to the fixed-point grid separately, as the browser does.
			own = Font.advance(font, glyph)
			kerned = (run.advances.get($k) ?? { x: own, y: 0 }).x
			$pairs = $pairs.append(TextMeasure.floor((kerned - own).to_f64() * metrics.scale))
			# A character the font does not map is drawn from a fallback font.
			if Font.missing(run.flags.get($k) ?? 0) {
				fallback = TextMeasure.fallback(metrics, Bytes.code_point(bytes, run.clusters.get($k) ?? 0))
				$advances = $advances.append(fallback.advance)
				$ink = $ink.append(fallback.ink)
			} else {
				$advances = $advances.append(TextMeasure.floor(own.to_f64() * metrics.scale))
				$ink = $ink.append(TextMeasure.glyph_ink(metrics, Font.extents(font, glyph)))
			}
			$k = $k + 1
		}
		{ advances: $advances, pairs: $pairs, ink: $ink, clusters: run.clusters }
	}

	# A glyph's outline extent in pixels from its origin, rounded out to whole
	# pixels as the browser's glyph bounds are. A glyph whose outline cannot be
	# measured (CFF outlines, which Inter does not have) counts as drawing
	# nothing past its advance.
	glyph_ink : Metrics, [Extents({ x_min : I32, y_min : I32, x_max : I32, y_max : I32 }), Empty, Unknown] -> [Ink({ left : F64, right : F64 }), NoInk]
	glyph_ink = |metrics, extents|
		match extents {
			Extents(box) => {
				pixels = metrics.size / Font.units_per_em(metrics.font).to_f64()
				Ink({ left: TextMeasure.floor(box.x_min.to_f64() * pixels), right: TextMeasure.ceil(box.x_max.to_f64() * pixels) })
			}
			Empty => NoInk
			Unknown => NoInk
		}

	fallback : Metrics, U32 -> { advance : F64, ink : [Ink({ left : F64, right : F64 }), NoInk] }
	fallback = |metrics, cp|
		if TextMeasure.is_invisible(cp) {
			{ advance: 0.0, ink: NoInk }
		} else if TextMeasure.is_emoji(cp) {
			# Noto Color Emoji's 136 px advance at its 109 px strike.
			{ advance: TextMeasure.floor(metrics.em * 136.0 / 109.0 * 65536.0), ink: NoInk }
		} else if TextMeasure.is_wide(cp) {
			{ advance: TextMeasure.floor(metrics.em * 65536.0), ink: NoInk }
		} else {
			{ advance: TextMeasure.floor(Font.advance(metrics.font, 0).to_f64() * metrics.scale), ink: TextMeasure.glyph_ink(metrics, Font.extents(metrics.font, 0)) }
		}

	is_invisible : U32 -> Bool
	is_invisible = |cp|
		(cp >= 0x200B and cp <= 0x200F)
			or (cp >= 0x202A and cp <= 0x202E)
			or (cp >= 0x2060 and cp <= 0x2064)
			or cp == 0x00AD
			or cp == 0xFEFF
			or TextMeasure.is_extender(cp)

	is_emoji : U32 -> Bool
	is_emoji = |cp| (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF)

	## East Asian wide and fullwidth characters.
	is_wide : U32 -> Bool
	is_wide = |cp|
		(cp >= 0x1100 and cp <= 0x115F)
			or (cp >= 0x2E80 and cp <= 0x303E)
			or (cp >= 0x3041 and cp <= 0x33FF)
			or (cp >= 0x3400 and cp <= 0x4DBF)
			or (cp >= 0x4E00 and cp <= 0x9FFF)
			or (cp >= 0xA000 and cp <= 0xA4CF)
			or (cp >= 0xAC00 and cp <= 0xD7A3)
			or (cp >= 0xF900 and cp <= 0xFAFF)
			or (cp >= 0xFE30 and cp <= 0xFE4F)
			or (cp >= 0xFF00 and cp <= 0xFF60)
			or (cp >= 0xFFE0 and cp <= 0xFFE6)
			or (cp >= 0x20000 and cp <= 0x3FFFD)

	# ------------------------------------------------------------ measuring

	# Fixed-point width to pixels, rounded up to the browser's 1/64 px layout
	# unit.
	pixels64 : F64 -> F64
	pixels64 = |fixed| TextMeasure.ceil(fixed / 1024.0) / 64.0

	## The width a word takes on a line: alone, or with the space before it.
	fragment_width : Metrics, List(U8), Bool -> F64
	fragment_width = |metrics, word, spaced| {
		run = if (spaced) [' '].concat(word) else word
		shaped = TextMeasure.shape(metrics, run)
		TextMeasure.pixels64(TextMeasure.sum(shaped.advances) + TextMeasure.sum(shaped.pairs))
	}

	## A line's advance and the horizontal extent of what it draws, from its
	## start. Each word is laid out on its own and advances the line by its
	## rounded width.
	line_extent : Metrics, List(List(U8)) -> { advance : F64, left : F64, right : F64, ascent : F64, descent : F64 }
	line_extent = |metrics, row| {
		emoji = row.any(|word| TextMeasure.has_emoji_fallback(metrics.font, word))
		var $start = 0.0
		var $left = 0.0
		var $right = 0.0
		var $index = 0
		for word in row {
			run = if ($index > 0) [' '].concat(word) else word
			shaped = TextMeasure.shape(metrics, run)
			var $pen = 0.0
			var $k = 0
			for advance in shaped.advances {
				origin = $start + $pen / 65536.0
				match shaped.ink.get($k) {
					Ok(Ink(box)) => {
						$left = $left.min(origin + box.left)
						$right = $right.max(origin + box.right)
					}
					_ => {}
				}
				$pen = $pen + advance + (shaped.pairs.get($k) ?? 0.0)
				$k = $k + 1
			}
			$start = $start + TextMeasure.pixels64(TextMeasure.sum(shaped.advances) + TextMeasure.sum(shaped.pairs))
			$index = $index + 1
		}
		{
			advance: $start,
			left: $left,
			right: $right.max($start),
			ascent: if (emoji) metrics.ascent.max(metrics.emoji_ascent) else metrics.ascent,
			descent: if (emoji) metrics.descent.max(metrics.emoji_descent) else metrics.descent,
		}
	}

	## Whether a word has an emoji the font lacks, drawn from the emoji font,
	## whose deeper descent lowers the line's bottom.
	has_emoji_fallback : Font, List(U8) -> Bool
	has_emoji_fallback = |font, bytes| {
		var $i = 0
		var $found = False
		while !$found and $i < bytes.len() {
			cp = Bytes.code_point(bytes, $i)
			if TextMeasure.is_emoji(cp) and Font.glyph(font, cp).is_err() {
				$found = True
			}
			$i = $i + Bytes.char_len(Bytes.at(bytes, $i))
		}
		$found
	}
}

close : FlowGeometry.TextBlock, FlowGeometry.TextBlock -> Bool
close = |a, b| a.lines == b.lines and (a.width - b.width).abs() < 1.0e-9 and (a.height - b.height).abs() < 1.0e-9

expect Font.dropped(TextMeasure.inter).is_empty()

inter : TextMeasure.Style
inter = { font: TextMeasure.inter, size: 14.0, line_height: 1.1, wrap: Width(120.0), align: Middle }

expect TextMeasure.block("Square", inter) == { lines: ["Square"], width: 46.90625, height: 17.0 }
expect TextMeasure.block("x", inter) == { lines: ["x"], width: 8.0, height: 17.0 }
expect TextMeasure.block("j", { ..inter, align: Start }) == { lines: ["j"], width: 4.390625, height: 17.0 }
expect TextMeasure.block("", inter) == { lines: [""], width: 0.0, height: 0.0 }
expect TextMeasure.block("first\nsecond\nthird line here", inter).width == 90.59375
expect close(TextMeasure.block("one\n\nthree", inter), { lines: ["one", "", "three"], width: 34.234375, height: 47.8 })
expect TextMeasure.block("\nleading", inter) == { lines: ["", "leading"], width: 48.375, height: 17.0 }
expect TextMeasure.block("literal \\n backslash n", inter).lines == ["literal", "backslash n"]
expect close(TextMeasure.block("two   spaces   between", inter), { lines: ["two spaces", "between"], width: 75.84375, height: 32.4 })
expect
	close(
		TextMeasure.block("The quick brown fox jumps over the lazy dog and keeps running far away", inter),
		{ lines: ["The quick brown", "fox jumps over", "the lazy dog and", "keeps running far", "away"], width: 115.984375, height: 78.6 },
	)
expect
	TextMeasure.block("Supercalifragilisticexpialidocious-and-then-some-more-letters-to-force-a-split", inter).lines
		== ["Supercalifragilisti", "cexpialidocious-a", "nd-then-some-m", "ore-letters-to-for", "ce-a-split"]
expect TextMeasure.block("a & b < c", inter).lines == ["a & b < c"]
# Deliberately unlike Mermaid, which draws this as "a - b = c".
expect TextMeasure.block("a -> b => c", inter).lines == ["a -> b => c"]
expect TextMeasure.block("x>y", inter).lines == ["x>y"]
# Inter's contextual forms: a raised asterisk after a capital.
expect TextMeasure.block("F*", inter).width == 17.296875
expect TextMeasure.block("no\u(00A0)break  here", { ..inter, wrap: NoWrap }).lines == ["no break here"]
expect TextMeasure.block("x < y\u(00A0)z", { ..inter, wrap: NoWrap }).lines == ["x < y\u(00A0)z"]
expect TextMeasure.block("日本語のラベル", inter).width == 98.0
