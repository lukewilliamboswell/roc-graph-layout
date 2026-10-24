import "FontInter.ttf" as inter_file : List(U8)
import FontShape
import FontTest

## What text measurement needs from a TrueType or OpenType font file: each
## glyph's advance width and the horizontal extent of its outline, which
## glyph draws each character, the default ligatures and contextual forms,
## pair kerning, and the font's ascent and descent. Outlines are not kept.
##
## `from_bytes` reads any font file and reports what is wrong with one it
## cannot use; the bytes are never trusted. `inter` is Inter Regular, the
## font the Mermaid comparisons are measured with, built in so that the
## common case needs no font file.
##
## All lengths are in font units; divide by `units_per_em` and multiply by
## the font size for pixels.
Font := {
	units_per_em : F64,
	ascent : F64,
	descent : F64,
	advances : List(U16),
	ink : List({ left : I16, right : I16 }),
	ranges : List({ first : U32, last : U32, glyph : U32 }),
	kerning : List(
		List(
			[
				Pairs({ keys : List(U32), first : List(I16), second : List(I16), skips : Bool }),
				Sets({ coverage : List({ first : U64, last : U64, index : U64 }), slots : List(U32), starts : List(U32), seconds : List(U16), first : List(I16), second : List(I16), skips : Bool }),
				Classes({ coverage : List({ first : U64, last : U64, index : U64 }), rows : List({ first : U64, last : U64, index : U64 }), columns : List({ first : U64, last : U64, index : U64 }), width : U64, height : U64, first : List(I16), second : List(I16), skips : Bool }),
			],
		),
	),
	shaping : FontShape,
}.{

	## Why bytes could not be read as a font. `NotAFont` covers files that are
	## too short, have an unknown signature, or are font collections.
	## `MissingTable` and `BadTable` name the table (`head`, `hhea`, `maxp`,
	## `hmtx`, `cmap`, `OS/2`, `loca`, `glyf`, `GSUB`, `GPOS` or `kern`); a bad table
	## extends past the file or has an internal offset or count that does not
	## fit. `NoUnicodeMapping` means no character map uses Unicode (formats 4
	## or 12).
	Problem : [NotAFont, MissingTable(Str), BadTable(Str), BadUnitsPerEm, NoUnicodeMapping]

	## Inter Regular (version 4, SIL Open Font License 1.1), as a metrics-only
	## file: its outlines are reduced to their bounding boxes.
	inter : Font
	inter = match Font.from_bytes(inter_file) {
		Ok(font) => font
		# The built-in file is checked by a test below; an empty font measures
		# every character with the missing-glyph rules.
		Err(_) => Font.empty
	}

	empty : Font
	empty = { units_per_em: 1000.0, ascent: 0.0, descent: 0.0, advances: [0], ink: [{ left: 0, right: 0 }], ranges: [], kerning: [], shaping: FontShape.none }

	units_per_em : Font -> F64
	units_per_em = |font| font.units_per_em

	## Height above the baseline, in font units.
	ascent : Font -> F64
	ascent = |font| font.ascent

	## Depth below the baseline, in font units (positive).
	descent : Font -> F64
	descent = |font| font.descent

	## The glyph that draws a Unicode code point, if the font has one.
	glyph : Font, U32 -> Try(U64, [Missing])
	glyph = |font, code_point| {
		ranges = font.ranges
		var $low = 0
		var $high = ranges.len()
		var $result = Err(Missing)
		while $low < $high {
			mid = ($low + $high) // 2
			range = ranges.get(mid) ?? { first: 1, last: 0, glyph: 0 }
			if code_point < range.first {
				$high = mid
			} else if code_point > range.last {
				$low = mid + 1
			} else {
				$result = Ok((range.glyph + (code_point - range.first)).to_u64())
				$low = $high
			}
		}
		$result
	}

	## How many glyphs the font has; glyph indices run below this.
	glyph_total : Font -> U64
	glyph_total = |font| font.advances.len()

	## A glyph's advance width. Indices past the last glyph have none.
	advance : Font, U64 -> F64
	advance = |font, index| (font.advances.get(index) ?? 0).to_f64()

	## The horizontal extent of a glyph's outline, or `NoInk` for a glyph that
	## draws nothing (such as a space) or a font without TrueType outlines.
	ink : Font, U64 -> [Ink({ left : F64, right : F64 }), NoInk]
	ink = |font, index|
		match font.ink.get(index) {
			Ok(box) if box.left <= box.right => Ink({ left: box.left.to_f64(), right: box.right.to_f64() })
			_ => NoInk
		}

	## Kerning for a run of glyphs, as the change to each glyph's advance. Each
	## kerning lookup runs over the whole run in order and its adjustments add
	## up, as a shaping engine applies the `kern` feature.
	kerning : Font, List(U64) -> List(F64)
	kerning = |font, glyphs| {
		count = glyphs.len()
		glyph_count = font.advances.len()
		var $adjust = List.repeat(0.0, count)
		for lookup in font.kerning {
			var $i = 0
			while $i + 1 < count {
				left = glyphs.get($i) ?? 0
				right = glyphs.get($i + 1) ?? 0
				match Font.pair(lookup, left, right, glyph_count) {
					Applied(found) => {
						# `$i + 1 < count`, so both indices are in bounds.
						a = ($adjust.get($i) ?? 0.0) + found.first
						$adjust = $adjust.set($i, a) ?? []
						b = ($adjust.get($i + 1) ?? 0.0) + found.second
						$adjust = $adjust.set($i + 1, b) ?? []
						$i = if (found.skips) $i + 2 else $i + 1
					}
					NotApplied => {
						$i = $i + 1
					}
				}
			}
		}
		$adjust
	}

	# The first subtable of a lookup that has the pair decides it. A first
	# glyph the font does not have is never kerned by `GPOS`; a second one
	# is in class 0.
	pair : List(Subtable), U64, U64, U64 -> [Applied({ first : F64, second : F64, skips : Bool }), NotApplied]
	pair = |subtables, left, right, glyph_count| {
		var $result = NotApplied
		var $k = 0
		while $k < subtables.len() {
			outcome = match subtables.get($k) {
				Ok(Pairs(list)) => Font.pair_in_list(list.keys, list.first, list.second, list.skips, left, right)
				Ok(Sets(sets)) if left < glyph_count => Font.pair_in_sets(sets.coverage, sets.slots, sets.starts, sets.seconds, sets.first, sets.second, sets.skips, left, right)
				Ok(Classes(grid)) if left < glyph_count => Font.pair_in_classes(grid.coverage, grid.rows, grid.columns, grid.width, grid.height, grid.first, grid.second, grid.skips, left, right, glyph_count)
				_ => NotApplied
			}
			match outcome {
				Applied(found) => {
					$result = Applied(found)
					$k = subtables.len()
				}
				NotApplied => {
					$k = $k + 1
				}
			}
		}
		$result
	}

	pair_in_list : List(U32), List(I16), List(I16), Bool, U64, U64 -> [Applied({ first : F64, second : F64, skips : Bool }), NotApplied]
	pair_in_list = |keys, first, second, skips, left, right| {
		if left > 0xFFFF or right > 0xFFFF {
			NotApplied
		} else {
			key = left.to_u32_wrap().shl_wrap(16).bitwise_or(right.to_u32_wrap())
			var $low = 0
			var $high = keys.len()
			var $result = NotApplied
			while $low < $high {
				mid = ($low + $high) // 2
				probe = keys.get(mid) ?? 0
				if key < probe {
					$high = mid
				} else if key > probe {
					$low = mid + 1
				} else {
					$result = Applied({ first: (first.get(mid) ?? 0).to_f64(), second: (second.get(mid) ?? 0).to_f64(), skips })
					$low = $high
				}
			}
			$result
		}
	}

	# The first glyph's coverage index picks a pair set; the second glyph is
	# looked up in it.
	pair_in_sets : List({ first : U64, last : U64, index : U64 }), List(U32), List(U32), List(U16), List(I16), List(I16), Bool, U64, U64 -> [Applied({ first : F64, second : F64, skips : Bool }), NotApplied]
	pair_in_sets = |coverage, slots, starts, seconds, first, second, skips, left, right|
		match FontShape.covered(coverage, left) {
			Err(_) => NotApplied
			Ok(index) => {
				slot = (slots.get(index) ?? Font.no_set).to_u64()
				var $low = (starts.get(slot) ?? 0).to_u64()
				var $high = (starts.get(slot + 1) ?? 0).to_u64()
				var $result = NotApplied
				while $low < $high {
					mid = ($low + $high) // 2
					probe = (seconds.get(mid) ?? 0).to_u64()
					if right < probe {
						$high = mid
					} else if right > probe {
						$low = mid + 1
					} else {
						$result = Applied({ first: (first.get(mid) ?? 0).to_f64(), second: (second.get(mid) ?? 0).to_f64(), skips })
						$low = $high
					}
				}
				$result
			}
		}

	pair_in_classes : List({ first : U64, last : U64, index : U64 }), List({ first : U64, last : U64, index : U64 }), List({ first : U64, last : U64, index : U64 }), U64, U64, List(I16), List(I16), Bool, U64, U64, U64 -> [Applied({ first : F64, second : F64, skips : Bool }), NotApplied]
	pair_in_classes = |coverage, rows, columns, width, height, first, second, skips, left, right, glyph_count|
		if FontShape.covered(coverage, left).is_err() {
			NotApplied
		} else {
			row = FontShape.class_of(rows, left)
			column = if (right < glyph_count) FontShape.class_of(columns, right) else 0
			if row >= height or column >= width {
				NotApplied
			} else {
				at = row * width + column
				Applied({ first: (first.get(at) ?? 0).to_f64(), second: (second.get(at) ?? 0).to_f64(), skips })
			}
		}

	## Read a font file. Every independent problem is reported.
	from_bytes : List(U8) -> Try(Font, List(Problem))
	from_bytes = |bytes| {
		match Font.directory(bytes) {
			Err(problem) => Err([problem])
			Ok(tables) => {
				head = Font.read_head(bytes, tables)
				hhea = Font.read_hhea(bytes, tables)
				maxp = Font.read_maxp(bytes, tables)
				cmap = Font.read_cmap(bytes, tables)
				os2 = Font.read_os2(bytes, tables)
				var $problems = []
				$problems = Font.collect($problems, head)
				$problems = Font.collect($problems, hhea)
				$problems = Font.collect($problems, maxp)
				$problems = Font.collect($problems, cmap)
				$problems = Font.collect($problems, os2)
				match (head, hhea, maxp) {
					(Ok(h), Ok(hh), Ok(count_of_glyphs)) => {
						advances = Font.read_hmtx(bytes, tables, hh.metric_count, count_of_glyphs)
						extents = Font.read_ink(bytes, tables, h.long_offsets, count_of_glyphs)
						pairs = Font.read_kerning(bytes, tables, count_of_glyphs)
						shaping = Font.read_shaping(bytes, tables)
						$problems = Font.collect($problems, shaping)
						$problems = Font.collect($problems, advances)
						$problems = Font.collect($problems, extents)
						$problems = Font.collect($problems, pairs)
						match (advances, extents, pairs, cmap, os2, shaping) {
							(Ok(a), Ok(i), Ok(k), Ok(c), Ok(o), Ok(sh)) if $problems.is_empty() => {
								lines = Font.vertical(hh, o)
								Ok({
									units_per_em: h.units_per_em,
									ascent: lines.ascent,
									descent: lines.descent,
									advances: a,
									ink: i,
									ranges: Font.clip_ranges(c, count_of_glyphs),
									kerning: k,
									shaping: sh,
								})
							}
							_ => Err($problems)
						}
					}
					_ => Err($problems)
				}
			}
		}
	}

	# Character runs whose glyphs the font has: a run whose glyphs go past the
	# last one is cut short there.
	clip_ranges : List({ first : U32, last : U32, glyph : U32 }), U64 -> List({ first : U32, last : U32, glyph : U32 })
	clip_ranges = |ranges, count_of_glyphs|
		ranges
			.keep_if(|range| range.glyph.to_u64() < count_of_glyphs)
			.map(
				|range| {
					room = count_of_glyphs - 1 - range.glyph.to_u64()
					last = range.last.to_u64().min(range.first.to_u64() + room)
					{ first: range.first, last: last.to_u32_wrap(), glyph: range.glyph }
				},
			)

	collect : List(Problem), Try(a, Problem) -> List(Problem)
	collect = |problems, result|
		match result {
			Ok(_) => problems
			Err(problem) => problems.append(problem)
		}

	# Ascent and descent as a browser takes them: the typographic values when
	# the font asks for them (`USE_TYPO_METRICS`), else `hhea`, else the
	# typographic values, else the Windows ones.
	vertical : { ascent : F64, descent : F64, metric_count : U64 }, [Present({ use_typo : Bool, typo_ascent : F64, typo_descent : F64, win_ascent : F64, win_descent : F64 }), Absent] -> { ascent : F64, descent : F64 }
	vertical = |hhea, os2|
		match os2 {
			Present(o) if o.use_typo => { ascent: o.typo_ascent, descent: -o.typo_descent }
			_ if hhea.ascent != 0.0 or hhea.descent != 0.0 => { ascent: hhea.ascent, descent: -hhea.descent }
			Present(o) if o.typo_ascent != 0.0 or o.typo_descent != 0.0 => { ascent: o.typo_ascent, descent: -o.typo_descent }
			Present(o) => { ascent: o.win_ascent, descent: o.win_descent }
			Absent => { ascent: 0.0, descent: 0.0 }
		}

	# ------------------------------------------------------------ bytes

	u8 : List(U8), U64 -> U64
	u8 = |bytes, at| (bytes.get(at) ?? 0).to_u64()

	u16 : List(U8), U64 -> U64
	u16 = |bytes, at| Font.u8(bytes, at) * 256 + Font.u8(bytes, at + 1)

	i16 : List(U8), U64 -> I64
	i16 = |bytes, at| {
		v = Font.u16(bytes, at).to_i64_wrap()
		if (v >= 32768) v - 65536 else v
	}

	u32 : List(U8), U64 -> U64
	u32 = |bytes, at| Font.u16(bytes, at) * 65536 + Font.u16(bytes, at + 2)

	# Whether `len` bytes from `start` lie inside a table of `size` bytes.
	fits : U64, U64, U64 -> Bool
	fits = |start, len, size| start <= size and len <= size - start

	Table : { tag : U64, offset : U64, length : U64 }

	directory : List(U8) -> Try(List(Table), Problem)
	directory = |bytes| {
		version = Font.u32(bytes, 0)
		count = Font.u16(bytes, 4)
		if bytes.len() < 12 or (version != 0x00010000 and version != 0x74727565 and version != 0x4F54544F) {
			Err(NotAFont)
		} else if !Font.fits(12, 16 * count, bytes.len()) {
			Err(NotAFont)
		} else {
			var $tables = List.with_capacity(count)
			for i in 0..<count {
				at = 12 + 16 * i
				$tables = $tables.append({ tag: Font.u32(bytes, at), offset: Font.u32(bytes, at + 8), length: Font.u32(bytes, at + 12) })
			}
			Ok($tables)
		}
	}

	# A table's bytes, checked to lie inside the file and to hold at least
	# `minimum` bytes.
	table : List(U8), List(Table), Str, U64 -> [Found(List(U8)), Missing, Bad]
	table = |bytes, tables, name, minimum| {
		tag = Font.tag_of(name)
		match tables.find_first(|t| t.tag == tag) {
			Err(_) => Missing
			Ok(t) =>
				if Font.fits(t.offset, t.length, bytes.len()) and t.length >= minimum {
					Found(bytes.sublist({ start: t.offset, len: t.length }))
				} else {
					Bad
				}
		}
	}

	tag_of : Str -> U64
	tag_of = |name| name.to_utf8().fold(0, |acc, b| acc * 256 + b.to_u64())

	required : List(U8), List(Table), Str, U64 -> Try(List(U8), Problem)
	required = |bytes, tables, name, minimum|
		match Font.table(bytes, tables, name, minimum) {
			Found(data) => Ok(data)
			Missing => Err(MissingTable(name))
			Bad => Err(BadTable(name))
		}

	# ------------------------------------------------------------ tables

	read_head : List(U8), List(Table) -> Try({ units_per_em : F64, long_offsets : Bool }, Problem)
	read_head = |bytes, tables| {
		head = Font.required(bytes, tables, "head", 54)?
		units = Font.u16(head, 18)
		if units < 16 or units > 16384 {
			Err(BadUnitsPerEm)
		} else {
			Ok({ units_per_em: units.to_f64(), long_offsets: Font.i16(head, 50) == 1 })
		}
	}

	read_hhea : List(U8), List(Table) -> Try({ ascent : F64, descent : F64, metric_count : U64 }, Problem)
	read_hhea = |bytes, tables| {
		hhea = Font.required(bytes, tables, "hhea", 36)?
		count = Font.u16(hhea, 34)
		if count == 0 {
			Err(BadTable("hhea"))
		} else {
			Ok({ ascent: Font.i16(hhea, 4).to_f64(), descent: Font.i16(hhea, 6).to_f64(), metric_count: count })
		}
	}

	read_maxp : List(U8), List(Table) -> Try(U64, Problem)
	read_maxp = |bytes, tables| {
		maxp = Font.required(bytes, tables, "maxp", 6)?
		count = Font.u16(maxp, 4)
		if (count == 0) Err(BadTable("maxp")) else Ok(count)
	}

	read_os2 : List(U8), List(Table) -> Try([Present({ use_typo : Bool, typo_ascent : F64, typo_descent : F64, win_ascent : F64, win_descent : F64 }), Absent], Problem)
	read_os2 = |bytes, tables|
		match Font.table(bytes, tables, "OS/2", 78) {
			Missing => Ok(Absent)
			Bad => Err(BadTable("OS/2"))
			Found(os2) =>
				Ok(
					Present({
						use_typo: Font.u16(os2, 62).bitwise_and(0x80) != 0,
						typo_ascent: Font.i16(os2, 68).to_f64(),
						typo_descent: Font.i16(os2, 70).to_f64(),
						win_ascent: Font.u16(os2, 74).to_f64(),
						win_descent: Font.u16(os2, 76).to_f64(),
					}),
				)
		}

	read_hmtx : List(U8), List(Table), U64, U64 -> Try(List(U16), Problem)
	read_hmtx = |bytes, tables, metric_count, count_of_glyphs| {
		long = metric_count.min(count_of_glyphs)
		hmtx = Font.required(bytes, tables, "hmtx", 4 * long)?
		var $advances = List.with_capacity(count_of_glyphs)
		for g in 0..<count_of_glyphs {
			at = 4 * g.min(long - 1)
			$advances = $advances.append(Font.u16(hmtx, at).to_u16_wrap())
		}
		Ok($advances)
	}

	# Outline extents from the TrueType glyph headers; a font without them
	# (CFF outlines) has no ink extents.
	read_ink : List(U8), List(Table), Bool, U64 -> Try(List({ left : I16, right : I16 }), Problem)
	read_ink = |bytes, tables, long_offsets, count_of_glyphs| {
		none = { left: 1, right: 0 }
		match (Font.table(bytes, tables, "loca", 0), Font.table(bytes, tables, "glyf", 0)) {
			(Bad, _) => Err(BadTable("loca"))
			(_, Bad) => Err(BadTable("glyf"))
			(Found(loca), Found(glyf)) => {
				size = if (long_offsets) 4 else 2
				if !Font.fits(0, size * (count_of_glyphs + 1), loca.len()) {
					Err(BadTable("loca"))
				} else {
					offset = |g| if (long_offsets) Font.u32(loca, 4 * g) else 2 * Font.u16(loca, 2 * g)
					var $ink = List.with_capacity(count_of_glyphs)
					var $bad = False
					for g in 0..<count_of_glyphs {
						start = offset(g)
						end = offset(g + 1)
						if end < start or end > glyf.len() {
							$bad = True
							$ink = $ink.append(none)
						} else if end - start >= 10 {
							$ink = $ink.append({ left: Font.i16(glyf, start + 2).to_i16_wrap(), right: Font.i16(glyf, start + 6).to_i16_wrap() })
						} else {
							$ink = $ink.append(none)
						}
					}
					if ($bad) Err(BadTable("loca")) else Ok($ink)
				}
			}
			_ => Ok(List.repeat(none, count_of_glyphs))
		}
	}

	# The Unicode character map, as runs of consecutive code points drawn by
	# consecutive glyphs, in code point order.
	read_cmap : List(U8), List(Table) -> Try(List({ first : U32, last : U32, glyph : U32 }), Problem)
	read_cmap = |bytes, tables| {
		cmap = Font.required(bytes, tables, "cmap", 4)?
		count = Font.u16(cmap, 2)
		if !Font.fits(4, 8 * count, cmap.len()) {
			Err(BadTable("cmap"))
		} else {
			var $best = { score: 0, offset: 0 }
			for i in 0..<count {
				at = 4 + 8 * i
				platform_id = Font.u16(cmap, at)
				encoding = Font.u16(cmap, at + 2)
				offset = Font.u32(cmap, at + 4)
				format = if (Font.fits(offset, 2, cmap.len())) Font.u16(cmap, offset) else 0
				unicode = platform_id == 0 or (platform_id == 3 and (encoding == 1 or encoding == 10))
				score = if (unicode and format == 12) 2 else if (unicode and format == 4 and encoding != 10) 1 else 0
				if score > $best.score {
					$best = { score, offset }
				}
			}
			if $best.score == 0 {
				Err(NoUnicodeMapping)
			} else if $best.score == 2 {
				Font.cmap_groups(cmap, $best.offset)
			} else {
				Font.cmap_segments(cmap, $best.offset)
			}
		}
	}

	cmap_groups : List(U8), U64 -> Try(List({ first : U32, last : U32, glyph : U32 }), Problem)
	cmap_groups = |cmap, at| {
		count = Font.u32(cmap, at + 12)
		if !Font.fits(at, 16, cmap.len()) or !Font.fits(at + 16, 12 * count, cmap.len()) {
			Err(BadTable("cmap"))
		} else {
			var $ranges = List.with_capacity(count)
			var $bad = False
			var $previous = 0
			for i in 0..<count {
				g = at + 16 + 12 * i
				first = Font.u32(cmap, g)
				last = Font.u32(cmap, g + 4)
				start_glyph = Font.u32(cmap, g + 8)
				if last < first or (i > 0 and first <= $previous) or last > 0x10FFFF {
					$bad = True
				} else {
					$ranges = $ranges.append({ first: first.to_u32_wrap(), last: last.to_u32_wrap(), glyph: start_glyph.to_u32_wrap() })
				}
				$previous = last
			}
			if ($bad) Err(BadTable("cmap")) else Ok($ranges)
		}
	}

	cmap_segments : List(U8), U64 -> Try(List({ first : U32, last : U32, glyph : U32 }), Problem)
	cmap_segments = |cmap, at| {
		segments = Font.u16(cmap, at + 6) // 2
		ends = at + 14
		starts = ends + 2 * segments + 2
		deltas = starts + 2 * segments
		range_offsets = deltas + 2 * segments
		if !Font.fits(at, 14, cmap.len()) or !Font.fits(ends, 8 * segments + 2, cmap.len()) {
			Err(BadTable("cmap"))
		} else {
			var $out = { done: [], open: None }
			var $bad = False
			var $previous_end = 0
			for s in 0..<segments {
				last = Font.u16(cmap, ends + 2 * s)
				first = Font.u16(cmap, starts + 2 * s)
				delta = Font.u16(cmap, deltas + 2 * s)
				range_offset = Font.u16(cmap, range_offsets + 2 * s)
				if last < first or (s > 0 and first <= $previous_end) {
					$bad = True
				} else if range_offset == 0 {
					for c in first..<(last + 1) {
						if c != 0xFFFF {
							$out = Font.runs_add($out, c, (c + delta) % 65536)
						}
					}
				} else {
					for c in first..<(last + 1) {
						if c != 0xFFFF {
							slot = range_offsets + 2 * s + range_offset + 2 * (c - first)
							if !Font.fits(slot, 2, cmap.len()) {
								$bad = True
							} else {
								raw = Font.u16(cmap, slot)
								if raw != 0 {
									$out = Font.runs_add($out, c, (raw + delta) % 65536)
								}
							}
						}
					}
				}
				$previous_end = last
			}
			if ($bad) Err(BadTable("cmap")) else Ok(Font.runs_finish($out))
		}
	}

	# Consecutive runs built from code points given in increasing order.
	Runs : { done : List({ first : U32, last : U32, glyph : U32 }), open : [None, Some({ first : U32, last : U32, glyph : U32 })] }

	runs_add : Runs, U64, U64 -> Runs
	runs_add = |runs, code_point, glyph_index| {
		c = code_point.to_u32_wrap()
		g = glyph_index.to_u32_wrap()
		if glyph_index == 0 {
			runs
		} else {
			match runs.open {
				Some(run) if run.last + 1 == c and run.glyph + (run.last - run.first) + 1 == g => { done: runs.done, open: Some({ first: run.first, last: c, glyph: run.glyph }) }
				Some(run) => { done: runs.done.append({ first: run.first, last: run.last, glyph: run.glyph }), open: Some({ first: c, last: c, glyph: g }) }
				None => { done: runs.done, open: Some({ first: c, last: c, glyph: g }) }
			}
		}
	}

	runs_finish : Runs -> List({ first : U32, last : U32, glyph : U32 })
	runs_finish = |runs|
		match runs.open {
			Some(run) => runs.done.append({ first: run.first, last: run.last, glyph: run.glyph })
			None => runs.done
		}

	read_shaping : List(U8), List(Table) -> Try(FontShape, Problem)
	read_shaping = |bytes, tables|
		match Font.table(bytes, tables, "GSUB", 10) {
			Missing => Ok(FontShape.none)
			Bad => Err(BadTable("GSUB"))
			Found(gsub) => FontShape.read(gsub).map_err(|_| BadTable("GSUB"))
		}

	## The glyphs that draw a run after the font's default substitutions
	## (ligatures and contextual forms). Each glyph keeps the index of the
	## first character it draws.
	substitute : Font, List({ glyph : U64, cluster : U64 }) -> List({ glyph : U64, cluster : U64 })
	substitute = |font, items| FontShape.apply(font.shaping, items)

	# ------------------------------------------------------------ kerning

	# Kerning subtables. `Pairs` holds a `kern` table's pairs as sorted keys
	# (first glyph in the high 16 bits). `Sets` is GPOS pair format 1: each
	# coverage index has a slot, whose pairs are `starts[slot]` up to
	# `starts[slot + 1]` of `seconds`, `first` and `second`; pair sets shared
	# by several glyphs are stored once. `Classes` is GPOS pair format 2: a
	# grid of `height` first classes by `width` second classes, empty when its
	# value records hold nothing. Coverage and classes are glyph ranges.
	Subtable : [
		Pairs({ keys : List(U32), first : List(I16), second : List(I16), skips : Bool }),
		Sets({ coverage : List({ first : U64, last : U64, index : U64 }), slots : List(U32), starts : List(U32), seconds : List(U16), first : List(I16), second : List(I16), skips : Bool }),
		Classes({ coverage : List({ first : U64, last : U64, index : U64 }), rows : List({ first : U64, last : U64, index : U64 }), columns : List({ first : U64, last : U64, index : U64 }), width : U64, height : U64, first : List(I16), second : List(I16), skips : Bool }),
	]

	# The slot of a coverage index whose glyphs the font does not have.
	no_set : U32
	no_set = 0xFFFFFFFF

	# How many entries a subtable stores, for tests of reading costs.
	stored_size : Subtable -> U64
	stored_size = |subtable|
		match subtable {
			Pairs(p) => p.keys.len()
			Sets(s) => s.coverage.len() + s.slots.len() + s.seconds.len()
			Classes(c) => c.coverage.len() + c.rows.len() + c.columns.len() + c.first.len()
		}

	# Pair kerning from the `kern` feature of `GPOS`, or, for a font without
	# `GPOS`, from a TrueType `kern` table.
	read_kerning : List(U8), List(Table), U64 -> Try(List(List(Subtable)), Problem)
	read_kerning = |bytes, tables, count_of_glyphs|
		match Font.table(bytes, tables, "GPOS", 10) {
			Bad => Err(BadTable("GPOS"))
			Found(gpos) => Font.read_gpos(gpos, count_of_glyphs).map_err(|_| BadTable("GPOS"))
			Missing =>
				match Font.table(bytes, tables, "kern", 4) {
					Bad => Err(BadTable("kern"))
					Found(kern) => Font.read_kern(kern)
					Missing => Ok([])
				}
		}

	# Reading work is counted as for `GSUB` (see `FontShape.spend`), so a
	# table whose offsets share data cannot make reading it, or kerning with
	# it, cost more than a few steps per byte.
	read_gpos : List(U8), U64 -> Try(List(List(Subtable)), [Bad])
	read_gpos = |gpos, count_of_glyphs| {
		features = Font.u16(gpos, 6)
		lookups = Font.u16(gpos, 8)
		feature_count = Font.u16(gpos, features)
		lookup_count = Font.u16(gpos, lookups)
		if !Font.fits(features, 2 + 6 * feature_count, gpos.len()) or !Font.fits(lookups, 2 + 2 * lookup_count, gpos.len()) {
			Err(Bad)
		} else {
			# Lookup indices of every `kern` feature, deduplicated, in order.
			var $steps = FontShape.spend(gpos, 0, feature_count)?
			var $wanted = List.repeat(False, lookup_count)
			for f in 0..<feature_count {
				record = features + 2 + 6 * f
				if Font.u32(gpos, record) == Font.tag_of("kern") {
					feature = features + Font.u16(gpos, record + 4)
					count = Font.u16(gpos, feature + 2)
					if !Font.fits(feature, 4 + 2 * count, gpos.len()) {
						return Err(Bad)
					}
					$steps = FontShape.spend(gpos, $steps, count)?
					for j in 0..<count {
						index = Font.u16(gpos, feature + 4 + 2 * j)
						if index < lookup_count {
							$wanted = $wanted.set(index, True) ?? []
						} else {
							return Err(Bad)
						}
					}
				}
			}
			var $result = []
			for index in 0..<lookup_count {
				if $wanted.get(index) ?? False {
					lookup = lookups + Font.u16(gpos, lookups + 2 + 2 * index)
					done = Font.read_lookup(gpos, lookup, count_of_glyphs, $steps)?
					$steps = done.steps
					$result = $result.append(done.value)
				}
			}
			Ok($result)
		}
	}

	read_lookup : List(U8), U64, U64, U64 -> Try({ value : List(Subtable), steps : U64 }, [Bad])
	read_lookup = |gpos, lookup, count_of_glyphs, steps| {
		kind = Font.u16(gpos, lookup)
		count = Font.u16(gpos, lookup + 4)
		if !Font.fits(lookup, 6 + 2 * count, gpos.len()) {
			Err(Bad)
		} else {
			var $steps = FontShape.spend(gpos, steps, count)?
			var $subtables = []
			for s in 0..<count {
				at = lookup + Font.u16(gpos, lookup + 6 + 2 * s)
				# An extension subtable points at the real one.
				target = if kind == 9 and Font.fits(at, 8, gpos.len()) and Font.u16(gpos, at + 2) == 2 {
					Some(at + Font.u32(gpos, at + 4))
				} else if kind == 2 {
					Some(at)
				} else {
					None
				}
				match target {
					Some(start) => {
						done = Font.read_pair_subtable(gpos, start, count_of_glyphs, $steps)?
						$steps = done.steps
						$subtables = $subtables.append(done.value)
					}
					None => {}
				}
			}
			Ok({ value: $subtables, steps: $steps })
		}
	}

	# Size in bytes of a value record, and where its x advance sits in it.
	value_size : U64 -> U64
	value_size = |format| 2 * format.bitwise_and(0xFF).to_u8_wrap().count_one_bits().to_u64()

	x_advance : List(U8), U64, U64 -> I16
	x_advance = |data, at, format|
		if format.bitwise_and(4) == 0 {
			0
		} else {
			skip = 2 * format.bitwise_and(3).to_u8_wrap().count_one_bits().to_u64()
			Font.i16(data, at + skip).to_i16_wrap()
		}

	read_pair_subtable : List(U8), U64, U64, U64 -> Try({ value : Subtable, steps : U64 }, [Bad])
	read_pair_subtable = |data, at, count_of_glyphs, steps| {
		if !Font.fits(at, 10, data.len()) {
			Err(Bad)
		} else {
			format = Font.u16(data, at)
			read = FontShape.read_coverage(data, at + Font.u16(data, at + 2), steps)?
			coverage = read.value
			after_coverage = read.steps
			format1 = Font.u16(data, at + 4)
			format2 = Font.u16(data, at + 6)
			size1 = Font.value_size(format1)
			size2 = Font.value_size(format2)
			skips = format2 != 0
			if format == 1 {
				Font.read_pair_sets(data, at, coverage, after_coverage, { format1, format2, size1, size2, skips }, count_of_glyphs)
			} else if format == 2 {
				if !Font.fits(at, 16, data.len()) {
					Err(Bad)
				} else {
					height = Font.u16(data, at + 12)
					width = Font.u16(data, at + 14)
					record = size1 + size2
					if !Font.fits(at + 16, record * width * height, data.len()) {
						Err(Bad)
					} else {
						class1 = FontShape.read_classes(data, at + Font.u16(data, at + 8), after_coverage)?
						rows = class1.value
						class2 = FontShape.read_classes(data, at + Font.u16(data, at + 10), class1.steps)?
						columns = class2.value
						# Empty value records take no bytes, however many
						# cells there are; they are not stored.
						cells = if (record == 0) 0 else width * height
						after = FontShape.spend(data, class2.steps, cells)?
						var $first = List.with_capacity(cells)
						var $second = List.with_capacity(cells)
						for cell in 0..<cells {
							r = at + 16 + record * cell
							$first = $first.append(Font.x_advance(data, r, format1))
							$second = $second.append(Font.x_advance(data, r + size1, format2))
						}
						Ok({ value: Classes({ coverage, rows, columns, width, height, first: $first, second: $second, skips }), steps: after })
					}
				}
			} else {
				Err(Bad)
			}
		}
	}

	# Pair format 1: the sets of the coverage indices of glyphs the font has,
	# each distinct set read once.
	read_pair_sets : List(U8), U64, List({ first : U64, last : U64, index : U64 }), U64, { format1 : U64, format2 : U64, size1 : U64, size2 : U64, skips : Bool }, U64 -> Try({ value : Subtable, steps : U64 }, [Bad])
	read_pair_sets = |data, at, coverage, steps, values, count_of_glyphs| {
		set_count = Font.u16(data, at + 8)
		if !Font.fits(at + 10, 2 * set_count, data.len()) {
			Err(Bad)
		} else {
			var $steps = FontShape.spend(data, steps, set_count)?
			var $used = List.repeat(False, set_count)
			for range in coverage {
				if range.first <= range.last and range.first < count_of_glyphs and range.index < set_count {
					span = (range.last.min(count_of_glyphs - 1) - range.first + 1).min(set_count - range.index)
					$steps = FontShape.spend(data, $steps, span)?
					for k in 0..<span {
						# `range.index + k < set_count`, the length of `$used`.
						$used = $used.set(range.index + k, True) ?? []
					}
				}
			}
			record = 2 + values.size1 + values.size2
			var $slot_of = Dict.empty()
			var $slots = List.with_capacity(set_count)
			var $starts = [0]
			var $seconds = []
			var $first = []
			var $second = []
			for k in 0..<set_count {
				if $used.get(k) ?? False {
					offset = Font.u16(data, at + 10 + 2 * k)
					match $slot_of.get(offset) {
						Ok(slot) => {
							$slots = $slots.append(slot)
						}
						Err(_) => {
							set = at + offset
							count = Font.u16(data, set)
							if !Font.fits(set, 2 + record * count, data.len()) {
								return Err(Bad)
							}
							$steps = FontShape.spend(data, $steps, count)?
							for p in 0..<count {
								r = set + 2 + record * p
								$seconds = $seconds.append(Font.u16(data, r).to_u16_wrap())
								$first = $first.append(Font.x_advance(data, r + 2, values.format1))
								$second = $second.append(Font.x_advance(data, r + 2 + values.size1, values.format2))
							}
							slot = ($starts.len() - 1).to_u32_wrap()
							$starts = $starts.append($seconds.len().to_u32_wrap())
							$slot_of = $slot_of.insert(offset, slot)
							$slots = $slots.append(slot)
						}
					}
				} else {
					$slots = $slots.append(Font.no_set)
				}
			}
			Ok({ value: Sets({ coverage, slots: $slots, starts: $starts, seconds: $seconds, first: $first, second: $second, skips: values.skips }), steps: $steps })
		}
	}

	# A TrueType `kern` table: each horizontal format 0 subtable is a lookup.
	# Apple's version 1.0 layout of the table is read too, as browsers do.
	read_kern : List(U8) -> Try(List(List(Subtable)), Problem)
	read_kern = |kern| {
		version = Font.u16(kern, 0)
		if version == 1 {
			Font.read_apple_kern(kern)
		} else {
			count = Font.u16(kern, 2)
			var $at = 4
			var $lookups = []
			var $ok = version == 0
			for _ in 0..<count {
				if $ok {
					if !Font.fits($at, 14, kern.len()) {
						$ok = False
					} else {
						length = Font.u16(kern, $at + 2)
						coverage = Font.u16(kern, $at + 4)
						pairs = Font.u16(kern, $at + 6)
						if coverage == 0x0001 {
							match Font.kern_pairs(kern, $at + 14, pairs) {
								Ok(lookup) => {
									$lookups = $lookups.append(lookup)
								}
								Err(_) => {
									$ok = False
								}
							}
						}
						$at = $at + length.max(6)
					}
				}
			}
			if ($ok) Ok($lookups) else Err(BadTable("kern"))
		}
	}

	# Apple's layout: a 32-bit version and count, and subtables with a 32-bit
	# length and an 8-bit coverage (vertical, cross-stream and variation
	# flags) followed by the format.
	read_apple_kern : List(U8) -> Try(List(List(Subtable)), Problem)
	read_apple_kern = |kern| {
		count = Font.u32(kern, 4)
		var $at = 8
		var $lookups = []
		var $ok = Font.u16(kern, 2) == 0 and Font.fits(8, 0, kern.len())
		var $k = 0
		while $ok and $k < count {
			length = Font.u32(kern, $at)
			if length < 16 or !Font.fits($at, length, kern.len()) {
				$ok = False
			} else {
				coverage = Font.u8(kern, $at + 4)
				format = Font.u8(kern, $at + 5)
				if coverage.bitwise_and(0xE0) == 0 and format == 0 {
					match Font.kern_pairs(kern, $at + 16, Font.u16(kern, $at + 8)) {
						Ok(lookup) => {
							$lookups = $lookups.append(lookup)
						}
						Err(_) => {
							$ok = False
						}
					}
				}
				$at = $at + length
			}
			$k = $k + 1
		}
		if ($ok) Ok($lookups) else Err(BadTable("kern"))
	}

	# Format 0 pairs: left, right, value.
	kern_pairs : List(U8), U64, U64 -> Try(List(Subtable), [Bad])
	kern_pairs = |kern, at, pairs|
		if !Font.fits(at, 6 * pairs, kern.len()) {
			Err(Bad)
		} else {
			var $keys = List.with_capacity(pairs)
			var $first = List.with_capacity(pairs)
			for p in 0..<pairs {
				r = at + 6 * p
				$keys = $keys.append(Font.u32(kern, r).to_u32_wrap())
				$first = $first.append(Font.i16(kern, r + 4).to_i16_wrap())
			}
			Ok([Pairs({ keys: $keys, first: $first, second: [], skips: False })])
		}
}

expect
	match Font.from_bytes(inter_file) {
		Ok(font) => Font.glyph_total(font) == 2937 and Font.units_per_em(font) == 2048.0
		Err(_) => False
	}

expect
	match Font.from_bytes([]) {
		Err(problems) => problems == [NotAFont]
		Ok(_) => False
	}

expect
	match Font.from_bytes([0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) {
		Err(problems) => problems == [MissingTable("head"), MissingTable("hhea"), MissingTable("maxp"), MissingTable("cmap")]
		Ok(_) => False
	}

# Inter's default substitutions: `->` becomes one arrow glyph, and an
# asterisk after a capital is raised.
expect Font.substitute(Font.inter, [{ glyph: 1459, cluster: 0 }, { glyph: 1517, cluster: 1 }]) == [{ glyph: 1805, cluster: 0 }]
expect Font.substitute(Font.inter, [{ glyph: 137, cluster: 0 }, { glyph: 1547, cluster: 1 }]) == [{ glyph: 137, cluster: 0 }, { glyph: 1548, cluster: 1 }]
expect Font.substitute(Font.inter, [{ glyph: 993, cluster: 0 }]) == [{ glyph: 993, cluster: 0 }]

# A truncated file: its tables run past the end.
expect
	match Font.from_bytes(inter_file.take_first(4096)) {
		Err(problems) => !problems.is_empty() and problems.all(|p| p != NotAFont)
		Ok(_) => False
	}

# Every byte of a font corrupted in turn never crashes reading.
expect {
	var $read = 0
	for k in 0..<16 {
		at = (k * 9973 + 12) % inter_file.len()
		match Font.from_bytes(inter_file.set(at, 0xFF) ?? inter_file) {
			Ok(_) => {
				$read = $read + 1
			}
			Err(problems) => {
				$read = $read + (if (problems.is_empty()) 100 else 1)
			}
		}
	}
	$read == 16
}

# ------------------------------------------------------------ test helpers
#
# Synthetic fonts are built from `FontTest.basic`: four glyphs (0 missing,
# 1 `A`, 2 `B`, 3 `C`) with advances 500 to 800 and 1000 units per em.

read_tables : List({ tag : Str, data : List(U8) }) -> Try(Font, List(Font.Problem))
read_tables = |tables| Font.from_bytes(FontTest.file(tables))

problems_of : List({ tag : Str, data : List(U8) }) -> List(Font.Problem)
problems_of = |tables|
	match read_tables(tables) {
		Ok(_) => []
		Err(found) => found
	}

# `basic` with one table replaced or added.
basic_with : Str, List(U8) -> List({ tag : Str, data : List(U8) })
basic_with = |tag, data| FontTest.replace(FontTest.basic, tag, data)

# The glyph of each code point, 9999 where the font has none.
glyphs_for : List({ tag : Str, data : List(U8) }), List(U32) -> List(U64)
glyphs_for = |tables, code_points|
	match read_tables(tables) {
		Ok(font) => code_points.map(|cp| Font.glyph(font, cp) ?? 9999)
		Err(_) => []
	}

# A font whose only character map is the given subtable.
cmap_only : U64, U64, List(U8) -> List({ tag : Str, data : List(U8) })
cmap_only = |system, encoding, subtable| basic_with("cmap", FontTest.cmap([{ system, encoding, subtable }]))

kerning_of : List({ tag : Str, data : List(U8) }), List(U64) -> List(F64)
kerning_of = |tables, glyphs|
	match read_tables(tables) {
		Ok(font) => Font.kerning(font, glyphs)
		Err(_) => [9999.0]
	}

# A `GPOS` table whose `kern` feature uses every lookup given.
gpos : List({ kind : U64, subtables : List(List(U8)) }) -> List(U8)
gpos = |lookups| FontTest.layout("DFLT", [{ tag: "kern", lookups: FontTest.counting(lookups.len()) }], lookups)

# Pairs (1, 2) -50 and (1, 3) -30, and (2, 1) +20, x advance of the first
# glyph only.
simple_pairs : List(U8)
simple_pairs = FontTest.pair1(4, 0, [{ glyph: 1, pairs: [{ second: 2, values: [-50] }, { second: 3, values: [-30] }] }, { glyph: 2, pairs: [{ second: 1, values: [20] }] }])

# ------------------------------------------------------------ reading a font

# The minimal font: metrics, glyph count and advances. Without `OS/2` the
# vertical metrics come from `hhea`; without `loca`/`glyf` nothing has ink.
expect {
	match read_tables(FontTest.basic) {
		Ok(font) =>
			Font.glyph_total(font) == 4
				and Font.units_per_em(font) == 1000.0
				and Font.ascent(font) == 800.0
				and Font.descent(font) == 200.0
				and [0, 1, 2, 3, 4, 1000000].map(|g| Font.advance(font, g)) == [500.0, 600.0, 700.0, 800.0, 0.0, 0.0]
				and [0, 1, 3].all(|g| Font.ink(font, g) == NoInk)
				and Font.kerning(font, [1, 2, 3]) == [0.0, 0.0, 0.0]
				and Font.substitute(font, [{ glyph: 1, cluster: 0 }]) == [{ glyph: 1, cluster: 0 }]
		Err(_) => False
	}
}

# Reading is deterministic.
expect FontTest.file(FontTest.basic) == FontTest.file(FontTest.basic)
expect {
	bytes = FontTest.file(FontTest.basic)
	match (Font.from_bytes(bytes), Font.from_bytes(bytes)) {
		(Ok(a), Ok(b)) => a.advances == b.advances and a.ranges == b.ranges and a.ink == b.ink and a.ascent == b.ascent
		_ => False
	}
}

# ------------------------------------------------------------ cmap format 4

# Delta segments: the first and last character of each segment map, the
# characters just outside do not.
expect {
	cmap = FontTest.cmap4([{ first: 0x20, last: 0x22, delta: 65536 - 0x1F, glyphs: [] }, { first: 0x30, last: 0x30, delta: 65536 - 0x2D, glyphs: [] }])
	glyphs_for(cmap_only(3, 1, cmap), [0x1F, 0x20, 0x21, 0x22, 0x23, 0x2F, 0x30, 0x31]) == [9999, 1, 2, 3, 9999, 9999, 3, 9999]
}

# Segments that map through a glyph array (idRangeOffset), with and without
# a delta, beside a delta segment; a zero entry leaves its character
# unmapped.
expect {
	cmap = FontTest.cmap4([
		{ first: 0x41, last: 0x42, delta: 1, glyphs: [1, 2] },
		{ first: 0x50, last: 0x50, delta: 65536 - 0x4F, glyphs: [] },
		{ first: 0x61, last: 0x63, delta: 0, glyphs: [3, 0, 2] },
	])
	glyphs_for(cmap_only(3, 1, cmap), [0x40, 0x41, 0x42, 0x43, 0x50, 0x61, 0x62, 0x63, 0x64]) == [9999, 2, 3, 9999, 1, 3, 9999, 2, 9999]
}

# The delta wraps modulo 65536 at the top of the range; U+FFFF and code
# points beyond the Basic Multilingual Plane are never mapped by format 4.
expect {
	cmap = FontTest.cmap4([{ first: 0xFFFE, last: 0xFFFE, delta: 4, glyphs: [] }])
	glyphs_for(cmap_only(3, 1, cmap), [0xFFFD, 0xFFFE, 0xFFFF, 0x10000, 0x10FFFF]) == [9999, 2, 9999, 9999, 9999]
}

# Platform 0 (Unicode) is a Unicode mapping too.
expect glyphs_for(cmap_only(0, 3, FontTest.cmap4([{ first: 0x41, last: 0x41, delta: 65536 - 0x40, glyphs: [] }])), [0x41]) == [1]

# A character mapped to a glyph the font does not have is unmapped, and a
# run that only partly fits keeps the characters whose glyphs exist.
expect {
	cmap = FontTest.cmap4([{ first: 0x44, last: 0x44, delta: 65536 + 9 - 0x44, glyphs: [] }, { first: 0x45, last: 0x48, delta: 65536 + 2 - 0x45, glyphs: [] }])
	glyphs_for(cmap_only(3, 1, cmap), [0x44, 0x45, 0x46, 0x47, 0x48]) == [9999, 2, 3, 9999, 9999]
}

# Segments out of order are a bad table.
expect {
	cmap = FontTest.cmap4([{ first: 0x50, last: 0x51, delta: 0, glyphs: [] }, { first: 0x41, last: 0x42, delta: 0, glyphs: [] }])
	problems_of(cmap_only(3, 1, cmap)) == [BadTable("cmap")]
}

expect {
	cmap = FontTest.cmap4([{ first: 0x41, last: 0x45, delta: 0, glyphs: [] }, { first: 0x45, last: 0x46, delta: 0, glyphs: [] }])
	problems_of(cmap_only(3, 1, cmap)) == [BadTable("cmap")]
}

# A glyph array that runs past the end of the table.
expect {
	table = FontTest.cmap([{ system: 3, encoding: 1, subtable: FontTest.cmap4([{ first: 0x41, last: 0x43, delta: 0, glyphs: [1, 2, 3] }]) }])
	problems_of(basic_with("cmap", table.drop_last(2))) == [BadTable("cmap")]
}

# A segment count larger than the table.
expect {
	table = FontTest.cmap([{ system: 3, encoding: 1, subtable: FontTest.u16(4).concat(FontTest.u16(14)).concat(FontTest.u16(0)).concat(FontTest.u16(0xFFFE)).concat(List.repeat(0, 6)) }])
	problems_of(basic_with("cmap", table)) == [BadTable("cmap")]
}

# ------------------------------------------------------------ cmap format 12

expect {
	cmap = FontTest.cmap12([{ first: 0x41, last: 0x43, glyph: 1 }, { first: 0x1F600, last: 0x1F601, glyph: 2 }])
	glyphs_for(cmap_only(3, 10, cmap), [0x40, 0x41, 0x43, 0x44, 0x1F5FF, 0x1F600, 0x1F601, 0x1F602, 0x10FFFF]) == [9999, 1, 3, 9999, 9999, 2, 3, 9999, 9999]
}

# Groups whose glyphs run past the last glyph keep the glyphs that exist.
expect {
	cmap = FontTest.cmap12([{ first: 0x50, last: 0x55, glyph: 2 }, { first: 0x60, last: 0x60, glyph: 4 }])
	glyphs_for(cmap_only(3, 10, cmap), [0x50, 0x51, 0x52, 0x55, 0x60]) == [2, 3, 9999, 9999, 9999]
}

# The highest code point Unicode allows.
expect glyphs_for(cmap_only(0, 4, FontTest.cmap12([{ first: 0x10FFFF, last: 0x10FFFF, glyph: 3 }])), [0x10FFFF]) == [3]

# Format 12 is preferred to format 4, whatever the record order.
expect {
	table = FontTest.cmap([
		{ system: 3, encoding: 1, subtable: FontTest.cmap4([{ first: 0x41, last: 0x41, delta: 65536 - 0x40, glyphs: [] }]) },
		{ system: 3, encoding: 10, subtable: FontTest.cmap12([{ first: 0x41, last: 0x41, glyph: 2 }]) },
	])
	glyphs_for(basic_with("cmap", table), [0x41]) == [2]
}

expect problems_of(cmap_only(3, 10, FontTest.cmap12([{ first: 0x50, last: 0x55, glyph: 1 }, { first: 0x41, last: 0x42, glyph: 1 }]))) == [BadTable("cmap")]
expect problems_of(cmap_only(3, 10, FontTest.cmap12([{ first: 0x50, last: 0x55, glyph: 1 }, { first: 0x55, last: 0x56, glyph: 1 }]))) == [BadTable("cmap")]
expect problems_of(cmap_only(3, 10, FontTest.cmap12([{ first: 0x50, last: 0x4F, glyph: 1 }]))) == [BadTable("cmap")]
expect problems_of(cmap_only(3, 10, FontTest.cmap12([{ first: 0x10FFFF, last: 0x110000, glyph: 1 }]))) == [BadTable("cmap")]

# A huge group count is checked against the table before anything is
# allocated.
expect {
	subtable = FontTest.u16(12).concat(FontTest.u16(0)).concat(FontTest.u32(16)).concat(FontTest.u32(0)).concat(FontTest.u32(0xFFFFFFFF))
	problems_of(cmap_only(3, 10, subtable)) == [BadTable("cmap")]
}

# ------------------------------------------------------------ cmap selection

# No Unicode subtable: a Macintosh one, a format 12 one under an encoding
# that is not Unicode, a format 4 one under the full-repertoire encoding,
# an unknown format, an offset past the table, or no subtables at all.
expect problems_of(cmap_only(1, 0, FontTest.cmap4([{ first: 0x41, last: 0x41, delta: 0, glyphs: [] }]))) == [NoUnicodeMapping]
expect problems_of(cmap_only(3, 0, FontTest.cmap12([{ first: 0x41, last: 0x41, glyph: 1 }]))) == [NoUnicodeMapping]
expect problems_of(cmap_only(3, 10, FontTest.cmap4([{ first: 0x41, last: 0x41, delta: 0, glyphs: [] }]))) == [NoUnicodeMapping]
expect problems_of(cmap_only(3, 1, FontTest.u16(6).concat(List.repeat(0, 8)))) == [NoUnicodeMapping]
expect problems_of(basic_with("cmap", FontTest.u16(0).concat(FontTest.u16(1)).concat(FontTest.u16(3)).concat(FontTest.u16(1)).concat(FontTest.u32(5000)))) == [NoUnicodeMapping]
expect problems_of(basic_with("cmap", FontTest.u16(0).concat(FontTest.u16(0)))) == [NoUnicodeMapping]

# More encoding records than the table holds.
expect problems_of(basic_with("cmap", FontTest.u16(0).concat(FontTest.u16(3)).concat(List.repeat(0, 8)))) == [BadTable("cmap")]

# ------------------------------------------------------------ hmtx

# Glyphs past the long metrics take the last advance.
expect {
	match read_tables(FontTest.basic.map(|t| if (t.tag == "hhea") { tag: t.tag, data: FontTest.hhea(800, -200, 2) } else if (t.tag == "hmtx") { tag: t.tag, data: FontTest.hmtx([500, 600]).concat([0, 0, 0, 0]) } else t)) {
		Ok(font) => [0, 1, 2, 3, 4].map(|g| Font.advance(font, g)) == [500.0, 600.0, 600.0, 600.0, 0.0]
		Err(_) => False
	}
}

# One long metric covers every glyph.
expect {
	match read_tables(FontTest.basic.map(|t| if (t.tag == "hhea") { tag: t.tag, data: FontTest.hhea(800, -200, 1) } else if (t.tag == "hmtx") { tag: t.tag, data: FontTest.hmtx([432]) } else t)) {
		Ok(font) => [0, 1, 2, 3].map(|g| Font.advance(font, g)) == [432.0, 432.0, 432.0, 432.0]
		Err(_) => False
	}
}

# More long metrics than glyphs: only the glyphs' metrics are needed.
expect {
	match read_tables(basic_with("hhea", FontTest.hhea(800, -200, 60000))) {
		Ok(font) => Font.advance(font, 3) == 800.0
		Err(_) => False
	}
}

# The largest advance a font can hold.
expect {
	match read_tables(basic_with("hmtx", FontTest.hmtx([65535, 0, 1, 2]))) {
		Ok(font) => Font.advance(font, 0) == 65535.0
		Err(_) => False
	}
}

expect problems_of(basic_with("hmtx", FontTest.hmtx([500, 600, 700]))) == [BadTable("hmtx")]
expect problems_of(FontTest.without(FontTest.basic, "hmtx")) == [MissingTable("hmtx")]

# ------------------------------------------------------------ loca and glyf

outline_glyphs : List(List(U8))
outline_glyphs = [[], FontTest.outline(10, 490), [], FontTest.outline(-5, 700)]

with_outlines : Bool, { loca : List(U8), glyf : List(U8) } -> List({ tag : Str, data : List(U8) })
with_outlines = |long, tables|
	basic_with("head", FontTest.head(1000, long))
		.append({ tag: "loca", data: tables.loca })
		.append({ tag: "glyf", data: tables.glyf })

inks_of : List({ tag : Str, data : List(U8) }) -> List([Ink({ left : F64, right : F64 }), NoInk])
inks_of = |tables|
	match read_tables(tables) {
		Ok(font) => [0, 1, 2, 3, 4].map(|g| Font.ink(font, g))
		Err(_) => []
	}

# Glyph extents from short and from long offsets; glyphs without an
# outline, and glyph indices past the last glyph, have no ink.
expect inks_of(with_outlines(False, FontTest.outlines(outline_glyphs, False))) == [NoInk, Ink({ left: 10.0, right: 490.0 }), NoInk, Ink({ left: -5.0, right: 700.0 }), NoInk]
expect inks_of(with_outlines(True, FontTest.outlines(outline_glyphs, True))) == [NoInk, Ink({ left: 10.0, right: 490.0 }), NoInk, Ink({ left: -5.0, right: 700.0 }), NoInk]

# A glyph shorter than its header, and one whose extent is inverted.
expect inks_of(with_outlines(False, FontTest.outlines([[], [1, 2, 3, 4], FontTest.outline(5, 4), []], False))) == [NoInk, NoInk, NoInk, NoInk, NoInk]

# The `loca` format must match `head`: short offsets read as long ones
# run past the end of `loca`.
expect problems_of(with_outlines(True, FontTest.outlines(outline_glyphs, False))) == [BadTable("loca")]

# Too few offsets, an offset past `glyf`, and offsets that go backwards.
expect problems_of(with_outlines(False, { loca: FontTest.outlines(outline_glyphs, False).loca.drop_last(2), glyf: FontTest.outlines(outline_glyphs, False).glyf })) == [BadTable("loca")]
expect problems_of(with_outlines(False, { loca: [0, 0, 0, 5, 0, 5, 0, 10, 0, 11], glyf: FontTest.outlines(outline_glyphs, False).glyf })) == [BadTable("loca")]
expect problems_of(with_outlines(False, { loca: [0, 0, 0, 5, 0, 5, 0, 2, 0, 10], glyf: FontTest.outlines(outline_glyphs, False).glyf })) == [BadTable("loca")]

# `loca` without `glyf` (or the reverse) gives no extents.
expect inks_of(basic_with("loca", FontTest.outlines(outline_glyphs, False).loca)) == [NoInk, NoInk, NoInk, NoInk, NoInk]

# ------------------------------------------------------------ vertical metrics

vertical_of : List({ tag : Str, data : List(U8) }) -> { ascent : F64, descent : F64 }
vertical_of = |tables|
	match read_tables(tables) {
		Ok(font) => { ascent: Font.ascent(font), descent: Font.descent(font) }
		Err(_) => { ascent: -1.0, descent: -1.0 }
	}

expect vertical_of(basic_with("OS/2", FontTest.os2({ use_typo: True, typo_ascent: 900, typo_descent: -300, win_ascent: 1000, win_descent: 400 }))) == { ascent: 900.0, descent: 300.0 }
expect vertical_of(basic_with("OS/2", FontTest.os2({ use_typo: False, typo_ascent: 900, typo_descent: -300, win_ascent: 1000, win_descent: 400 }))) == { ascent: 800.0, descent: 200.0 }
expect vertical_of(FontTest.replace(basic_with("hhea", FontTest.hhea(0, 0, 4)), "OS/2", FontTest.os2({ use_typo: False, typo_ascent: 900, typo_descent: -300, win_ascent: 1000, win_descent: 400 }))) == { ascent: 900.0, descent: 300.0 }
expect vertical_of(FontTest.replace(basic_with("hhea", FontTest.hhea(0, 0, 4)), "OS/2", FontTest.os2({ use_typo: False, typo_ascent: 0, typo_descent: 0, win_ascent: 1000, win_descent: 400 }))) == { ascent: 1000.0, descent: 400.0 }
expect vertical_of(basic_with("hhea", FontTest.hhea(0, 0, 4))) == { ascent: 0.0, descent: 0.0 }

# ------------------------------------------------------------ problems

expect Font.from_bytes(List.repeat(0, 11)).is_err()
expect problems_of([]) == [MissingTable("head"), MissingTable("hhea"), MissingTable("maxp"), MissingTable("cmap")]

# Signatures: TrueType, `true` and `OTTO` are fonts; a collection is not.
expect {
	match Font.from_bytes(FontTest.u32(0x74727565).concat(FontTest.file(FontTest.basic).drop_first(4))) {
		Ok(_) => True
		Err(_) => False
	}
}
expect {
	match Font.from_bytes(FontTest.u32(0x4F54544F).concat(FontTest.file(FontTest.basic).drop_first(4))) {
		Ok(_) => True
		Err(_) => False
	}
}
expect {
	match Font.from_bytes(FontTest.u32(0x74746366).concat(FontTest.file(FontTest.basic).drop_first(4))) {
		Err(found) => found == [NotAFont]
		Ok(_) => False
	}
}

# A table directory longer than the file.
expect {
	match Font.from_bytes(FontTest.patch(FontTest.file(FontTest.basic), 4, FontTest.u16(200))) {
		Err(found) => found == [NotAFont]
		Ok(_) => False
	}
}

# Each required table missing on its own.
expect ["head", "hhea", "maxp", "cmap"].all(|tag| problems_of(FontTest.without(FontTest.basic, tag)) == [MissingTable(tag)])

# Without `head`, `hhea` or `maxp` the tables that depend on them are not
# read, so only the missing table is reported.
expect problems_of(FontTest.without(FontTest.basic.append({ tag: "GPOS", data: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] }), "maxp")) == [MissingTable("maxp")]

# Tables too short for their fields, and empty counts.
expect problems_of(basic_with("head", FontTest.head(1000, False).drop_last(1))) == [BadTable("head")]
expect problems_of(basic_with("hhea", FontTest.hhea(800, -200, 4).drop_last(1))) == [BadTable("hhea")]
expect problems_of(basic_with("hhea", FontTest.hhea(800, -200, 0))) == [BadTable("hhea")]
expect problems_of(basic_with("maxp", FontTest.maxp(0))) == [BadTable("maxp")]
expect problems_of(basic_with("maxp", [0, 0, 0, 0, 0])) == [BadTable("maxp")]
expect problems_of(basic_with("OS/2", FontTest.os2({ use_typo: False, typo_ascent: 0, typo_descent: 0, win_ascent: 0, win_descent: 0 }).take_first(77))) == [BadTable("OS/2")]
expect problems_of(basic_with("cmap", [0, 0, 0])) == [BadTable("cmap")]

# A table whose length runs past the end of the file.
expect {
	bytes = FontTest.file(FontTest.basic)
	# The first record is `head`; its length is at byte 12 + 12.
	match Font.from_bytes(FontTest.patch(bytes, 24, FontTest.u32(100000))) {
		Err(found) => found == [BadTable("head")]
		Ok(_) => False
	}
}
expect {
	bytes = FontTest.file(FontTest.basic)
	match Font.from_bytes(FontTest.patch(bytes, 20, FontTest.u32(0xFFFFFFFF))) {
		Err(found) => found == [BadTable("head")]
		Ok(_) => False
	}
}

# Units per em must lie in 16 to 16384.
expect problems_of(basic_with("head", FontTest.head(15, False))) == [BadUnitsPerEm]
expect problems_of(basic_with("head", FontTest.head(16385, False))) == [BadUnitsPerEm]
expect problems_of(basic_with("head", FontTest.head(0, False))) == [BadUnitsPerEm]
expect problems_of(basic_with("head", FontTest.head(16, False))) == []
expect problems_of(basic_with("head", FontTest.head(16384, False))) == []

# Independent problems are reported together, in table order.
expect {
	tables = FontTest.basic
		.map(
			|t|
				if t.tag == "head" {
					{ tag: t.tag, data: FontTest.head(1, False) }
				} else if t.tag == "hhea" {
					{ tag: t.tag, data: FontTest.hhea(1, 1, 0) }
				} else if t.tag == "cmap" {
					{ tag: t.tag, data: FontTest.cmap([{ system: 1, encoding: 0, subtable: FontTest.cmap4([]) }]) }
				} else {
					t
				},
		)
		.append({ tag: "OS/2", data: [0] })
	problems_of(tables) == [BadUnitsPerEm, BadTable("hhea"), NoUnicodeMapping, BadTable("OS/2")]
}

expect {
	tables = FontTest.basic
		.map(|t| if (t.tag == "hmtx") { tag: t.tag, data: [0, 1] } else t)
		.concat([{ tag: "GSUB", data: List.repeat(0xFF, 12) }, { tag: "GPOS", data: List.repeat(0xFF, 12) }, { tag: "loca", data: [0] }, { tag: "glyf", data: [] }])
	problems_of(tables) == [BadTable("GSUB"), BadTable("hmtx"), BadTable("loca"), BadTable("GPOS")]
}

# Every prefix of a font, and every byte of it set to 0 or 0xFF, is read or
# rejected with problems; nothing crashes.
full_font : List(U8)
full_font = {
	outlines = FontTest.outlines(outline_glyphs, False)
	FontTest.file(
		FontTest.basic.concat([
			{ tag: "OS/2", data: FontTest.os2({ use_typo: True, typo_ascent: 900, typo_descent: -300, win_ascent: 1000, win_descent: 400 }) },
			{ tag: "loca", data: outlines.loca },
			{ tag: "glyf", data: outlines.glyf },
			{ tag: "GPOS", data: gpos([{ kind: 2, subtables: [simple_pairs] }]) },
			{ tag: "GSUB", data: FontTest.layout("latn", [{ tag: "liga", lookups: [0] }], [{ kind: 4, subtables: [FontTest.pack([U16(1), Ref(FontTest.coverage1([1])), U16(1), Ref(FontTest.pack([U16(1), Ref(FontTest.pack([U16(3), U16(2), U16(2)]))]))])] }]) },
		]),
	)
}

expect {
	match Font.from_bytes(full_font) {
		Ok(font) =>
			Font.kerning(font, [1, 2]) == [-50.0, 0.0]
				and Font.substitute(font, [{ glyph: 1, cluster: 0 }, { glyph: 2, cluster: 1 }]) == [{ glyph: 3, cluster: 0 }]
				and Font.ascent(font) == 900.0
		Err(_) => False
	}
}

expect {
	var $outcomes = 0
	for n in 0..<full_font.len() {
		match Font.from_bytes(full_font.take_first(n)) {
			Ok(_) => {
				$outcomes = $outcomes + 1
			}
			Err(found) => {
				$outcomes = $outcomes + (if (found.is_empty()) 1000000 else 1)
			}
		}
	}
	$outcomes == full_font.len()
}

expect {
	var $outcomes = 0
	for at in 0..<full_font.len() {
		for value in [0, 0x7F, 0xFF] {
			match Font.from_bytes(full_font.set(at, value) ?? []) {
				Ok(font) => {
					# Queries on whatever was read are total.
					_ = Font.kerning(font, [0, 1, 2, 3, 70000])
					_ = Font.substitute(font, [{ glyph: 1, cluster: 0 }, { glyph: 2, cluster: 1 }, { glyph: 70000, cluster: 2 }])
					$outcomes = $outcomes + (if (Font.units_per_em(font) >= 16.0) 1 else 1000000)
				}
				Err(found) => {
					$outcomes = $outcomes + (if (found.is_empty()) 1000000 else 1)
				}
			}
		}
	}
	$outcomes == 3 * full_font.len()
}

# The sample font that seeds the fuzz targets reads, with every table in
# use: format 12 is preferred, metrics repeat past the long ones, `OS/2`
# typographic metrics apply, and `GPOS` overrides `kern`.
expect {
	match Font.from_bytes(FontTest.sample) {
		Ok(font) =>
			Font.glyph_total(font) == 40
				and Font.units_per_em(font) == 2048.0
				and Font.ascent(font) == 1800.0
				and Font.descent(font) == 400.0
				and [0x41, 0x5A, 0x61, 0x1F600].map(|cp| Font.glyph(font, cp) ?? 9999) == [1, 26, 9999, 30]
				and [0, 3, 39].map(|g| Font.advance(font, g)) == [1000.0, 1300.0, 1300.0]
				and [0, 1, 2].map(|g| Font.ink(font, g)) == [NoInk, Ink({ left: -4.0, right: 10.0 }), Ink({ left: -3.0, right: 20.0 })]
				and Font.kerning(font, [1, 2]) == [-61.0, 2.0]
				and Font.substitute(font, [7, 1, 2, 3].map_with_index(|glyph, cluster| { glyph, cluster })).map(|item| item.glyph) == [7, 11, 2, 3]
		Err(_) => False
	}
}

# The fonts the scaling fuzz target builds read, at every size.
expect {
	[[0, 1, 2, 3, 4, 5], [1, 2, 3, 4, 5, 0], [2, 4], [3, 3, 3], [5], []].all(
		|choices|
			[1, 2, 16].all(
				|copies|
					match Font.from_bytes(FontTest.scaled(choices, copies)) {
						Ok(font) => Font.glyph_total(font) == 16 + 4 * choices.len() * copies
						Err(_) => False
					},
			),
	)
}

# Patching bytes wraps positions to the length.
expect FontTest.mutate([1, 2, 3], [0, 0, 4, 9, 0, 0, 0, 7, 0, 0]) == [7, 9, 3]
expect FontTest.mutate([], [0, 0, 4, 9]) == []

# ------------------------------------------------------------ GPOS kerning

# Format 1: pairs listed per first glyph. Pairs not listed, and glyphs not
# covered, are not adjusted; an empty or single-glyph run has no pairs.
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }])), [1, 2, 3, 1]) == [-50.0, 0.0, 0.0, 0.0]
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }])), [2, 1, 3]) == [20.0, -30.0, 0.0]
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }])), []) == []
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }])), [1]) == [0.0]
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }])), [1, 70000, 2]) == [0.0, 0.0, 0.0]

# The x advance is found after an x placement in the value record; other
# fields are ignored.
expect {
	subtable = FontTest.pair1(0x05 + 0x0A, 0, [{ glyph: 1, pairs: [{ second: 2, values: [7, 8, -40, 9] }] }])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2]) == [-40.0, 0.0]
}

# A record without an x advance adjusts nothing.
expect {
	subtable = FontTest.pair1(0x01, 0, [{ glyph: 1, pairs: [{ second: 2, values: [7] }] }])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2]) == [0.0, 0.0]
}

# With a value for the second glyph, the second glyph is adjusted and the
# pair after it is skipped.
expect {
	subtable = FontTest.pair1(4, 4, [{ glyph: 1, pairs: [{ second: 2, values: [-10, 5] }] }, { glyph: 2, pairs: [{ second: 3, values: [-7, 0] }] }])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2, 3, 1, 2]) == [-10.0, 5.0, 0.0, -10.0, 5.0]
}
expect {
	subtable = FontTest.pair1(4, 0, [{ glyph: 1, pairs: [{ second: 2, values: [-10] }] }, { glyph: 2, pairs: [{ second: 3, values: [-7] }] }])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2, 3]) == [-10.0, -7.0, 0.0]
}

# Format 2: classes. Glyph 1 is first class 0, glyphs 2 and 3 first class
# 1; glyphs 2 and 3 are second class 1, others second class 0.
class_pairs : List(U8)
class_pairs = FontTest.pair2(4, 0, FontTest.coverage1([1, 2, 3]), FontTest.classes1(1, [0, 1, 1]), FontTest.classes2([{ first: 2, last: 3, class: 1 }]), 2, 2, [0, -11, -22, -33])

expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [class_pairs] }])), [1, 2, 3, 1, 0, 1]) == [-11.0, -33.0, -22.0, 0.0, 0.0, 0.0]

# A first glyph outside the coverage is not adjusted, even when its class
# has values.
expect {
	subtable = FontTest.pair2(4, 0, FontTest.coverage1([2]), FontTest.classes1(1, [1, 1, 1]), FontTest.classes2([]), 2, 1, [0, -5])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2, 3]) == [0.0, -5.0, 0.0]
}

# A class past the class counts is not adjusted.
expect {
	subtable = FontTest.pair2(4, 0, FontTest.coverage1([1, 2]), FontTest.classes1(1, [0, 5]), FontTest.classes1(1, [7, 0, 0]), 1, 1, [-5])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2, 2, 1, 1]) == [-5.0, 0.0, 0.0, 0.0, 0.0]
}

# Format 2 with a second value record skips the pair after it.
expect {
	subtable = FontTest.pair2(4, 4, FontTest.coverage1([1, 2, 3]), FontTest.classes1(1, [0, 0, 0]), FontTest.classes1(1, [0, 0, 0]), 1, 1, [-3, 2])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2, 3]) == [-3.0, 2.0, 0.0]
}

# In a lookup, the first subtable that has the pair decides it; later
# lookups add to it.
expect {
	first = FontTest.pair1(4, 0, [{ glyph: 1, pairs: [{ second: 3, values: [-1] }] }])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [first, simple_pairs] }])), [1, 2, 1, 3]) == [-50.0, 20.0, -1.0, 0.0]
}
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }, { kind: 2, subtables: [class_pairs] }])), [1, 2]) == [-61.0, 0.0]

# Extension lookups (type 9) hold their subtables behind a 32-bit offset.
expect kerning_of(basic_with("GPOS", gpos([{ kind: 9, subtables: [FontTest.extension(2, simple_pairs), FontTest.extension(2, class_pairs)] }])), [1, 2, 3]) == [-50.0, -33.0, 0.0]

# Lookups of other types, extensions of other types, and lookups of other
# features are not kerning.
expect kerning_of(basic_with("GPOS", gpos([{ kind: 1, subtables: [simple_pairs] }, { kind: 9, subtables: [FontTest.extension(4, simple_pairs)] }])), [1, 2]) == [0.0, 0.0]
expect kerning_of(basic_with("GPOS", FontTest.layout("DFLT", [{ tag: "mark", lookups: [0] }], [{ kind: 2, subtables: [simple_pairs] }])), [1, 2]) == [0.0, 0.0]

# Pair formats 1 and 2 with a coverage of format 2.
expect {
	subtable = FontTest.pack([U16(1), Ref(FontTest.coverage2([{ first: 1, last: 2, index: 0 }])), U16(4), U16(0), U16(2), Ref(FontTest.pack([U16(1), U16(3), I16(-9)])), Ref(FontTest.pack([U16(1), U16(3), I16(-8)]))])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 3, 2, 3]) == [-9.0, 0.0, -8.0, 0.0]
}

# A GPOS table takes precedence over a `kern` table.
expect kerning_of(basic_with("GPOS", gpos([])).append({ tag: "kern", data: FontTest.kern([{ coverage: 1, pairs: [{ left: 1, right: 2, value: -5 }] }]) }), [1, 2]) == [0.0, 0.0]

# Broken GPOS tables: a lookup index past the lookups, an unknown pair
# format, a coverage past the table, a truncated table, and pair sets that
# do not fit.
expect problems_of(basic_with("GPOS", FontTest.layout("DFLT", [{ tag: "kern", lookups: [3] }], [{ kind: 2, subtables: [simple_pairs] }]))) == [BadTable("GPOS")]
expect problems_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [FontTest.patch(simple_pairs, 0, FontTest.u16(3))] }]))) == [BadTable("GPOS")]
expect problems_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [FontTest.patch(simple_pairs, 2, FontTest.u16(60000))] }]))) == [BadTable("GPOS")]
expect problems_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [simple_pairs] }]).drop_last(3))) == [BadTable("GPOS")]
expect problems_of(basic_with("GPOS", [0, 1, 0, 0, 0, 10, 0, 10, 0, 10, 0, 0])) == []
expect problems_of(basic_with("GPOS", [0, 1, 0, 0, 0, 10, 0, 10, 0, 10])) == [BadTable("GPOS")]
expect problems_of(basic_with("GPOS", [0, 1, 0, 0, 0, 10, 0])) == [BadTable("GPOS")]

# A class grid larger than the table.
expect problems_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [FontTest.pair2(4, 0, FontTest.coverage1([1]), FontTest.classes1(1, [0]), FontTest.classes1(1, [0]), 100, 100, [])] }]))) == [BadTable("GPOS")]

## fuzz regression: a class grid whose value records are empty takes no
## bytes however many classes it has; it must not take time or memory in
## proportion to the 65535 x 65535 cells.
expect kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [FontTest.pair2(0, 0, FontTest.coverage1([1]), FontTest.classes1(1, [0]), FontTest.classes1(1, [0]), 65535, 65535, [])] }])), [1, 2]) == [0.0, 0.0]

# Coverage ranges that overlap are read as browsers read them, and are
# not expanded glyph by glyph: a few bytes of them could list billions of
# glyphs. A range that goes backwards covers nothing.
expect {
	ranges = List.repeat({ first: 0, last: 65535, index: 0 }, 20).append({ first: 9, last: 2, index: 0 })
	subtable = FontTest.pack([U16(1), Ref(FontTest.coverage2(ranges)), U16(4), U16(0), U16(0)])
	tables = basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }]))
	problems_of(tables) == [] and kerning_of(tables, [1, 2]) == [0.0, 0.0]
}
expect {
	set = FontTest.pack([U16(1), U16(2), I16(-9)])
	subtable = FontTest.pack([U16(1), Ref(FontTest.coverage2([{ first: 3, last: 1, index: 0 }, { first: 1, last: 1, index: 0 }])), U16(4), U16(0), U16(1), Ref(set)])
	kerning_of(basic_with("GPOS", gpos([{ kind: 2, subtables: [subtable] }])), [1, 2, 3, 2]) == [-9.0, 0.0, 0.0, 0.0]
}

# A pair set shared by many first glyphs is read once, not once per glyph.
expect {
	n = 300
	set = FontTest.pack([U16(n)].concat(FontTest.counting(n).join_map(|g| [U16(g), I16(-1)])))
	# Every set offset points at the one set, after the coverage.
	subtable = FontTest.pack([U16(1), U16(10 + 2 * n), U16(4), U16(0), U16(n)].concat(List.repeat(U16(20 + 2 * n), n)).append(Raw(FontTest.coverage2([{ first: 0, last: n - 1, index: 0 }]))).append(Raw(set)))
	tables = FontTest.basic
		.map(|t| if (t.tag == "maxp") { tag: t.tag, data: FontTest.maxp(n) } else t)
		.append({ tag: "GPOS", data: gpos([{ kind: 2, subtables: [subtable] }]) })
	match read_tables(tables) {
		Ok(font) => {
			stored = font.kerning.join_map(|lookup| lookup.map(Font.stored_size)).sum()
			Font.kerning(font, [5, 7, 299, 0]) == [-1.0, -1.0, -1.0, 0.0] and stored < 4 * n
		}
		Err(_) => False
	}
}

# Many lookups that all point at one lookup with many subtables, all the
# same: more work than the table could describe without sharing, so the
# table is refused.
expect {
	lookups = 300
	header = [U32(0x00010000), U16(10), U16(12), U16(0)]
	features = [U16(0), U16(1), Tag("kern"), U16(8), U16(0), U16(lookups)].concat(FontTest.counting(lookups).map(|i| U16(i)))
	# The lookup list: every offset points at one lookup after the list.
	lookup_at = 2 + 2 * lookups
	list = [U16(lookups)].concat(List.repeat(U16(lookup_at), lookups))
	lookup = [U16(2), U16(0), U16(lookups)].concat(List.repeat(U16(6 + 2 * lookups), lookups))
	table = FontTest.pack(header).concat(FontTest.pack(features)).concat(FontTest.pack(list)).concat(FontTest.pack(lookup)).concat(simple_pairs)
	patched = FontTest.patch(table, 8, FontTest.u16(24 + 2 * lookups))
	problems_of(basic_with("GPOS", patched)) == [BadTable("GPOS")]
}

# ------------------------------------------------------------ legacy kern

expect kerning_of(basic_with("kern", FontTest.kern([{ coverage: 1, pairs: [{ left: 1, right: 2, value: -50 }, { left: 2, right: 3, value: -30 }] }])), [1, 2, 3, 1]) == [-50.0, -30.0, 0.0, 0.0]

# Each horizontal subtable is applied in turn and the adjustments add up;
# vertical and cross-stream subtables are ignored.
expect {
	kern = FontTest.kern([
		{ coverage: 1, pairs: [{ left: 1, right: 2, value: -50 }] },
		{ coverage: 0, pairs: [{ left: 1, right: 2, value: -1000 }] },
		{ coverage: 5, pairs: [{ left: 1, right: 2, value: -2000 }] },
		{ coverage: 1, pairs: [{ left: 1, right: 2, value: 7 }] },
	])
	kerning_of(basic_with("kern", kern), [1, 2]) == [-43.0, 0.0]
}

expect problems_of(basic_with("kern", FontTest.kern([{ coverage: 1, pairs: [{ left: 1, right: 2, value: -50 }] }]).drop_last(1))) == [BadTable("kern")]
expect problems_of(basic_with("kern", FontTest.patch(FontTest.kern([]), 2, FontTest.u16(3)))) == [BadTable("kern")]

# A `kern` table in Apple's layout (version 1.0), as browsers read it:
# horizontal format 0 subtables kern; vertical, cross-stream and variation
# subtables and other formats do not.
apple_kern : List({ coverage : U64, format : U64, pairs : List({ left : U64, right : U64, value : I64 }) }) -> List(U8)
apple_kern = |subtables| {
	body = subtables.join_map(
		|t| {
			n = t.pairs.len()
			FontTest.u32(16 + 6 * n)
				.concat([t.coverage.to_u8_wrap(), t.format.to_u8_wrap(), 0, 0])
				.concat(FontTest.pack([U16(n), U16(0), U16(0), U16(0)].concat(t.pairs.join_map(|p| [U16(p.left), U16(p.right), I16(p.value)]))))
		},
	)
	FontTest.u32(0x00010000).concat(FontTest.u32(subtables.len())).concat(body)
}

expect {
	kern = apple_kern([
		{ coverage: 0, format: 0, pairs: [{ left: 1, right: 2, value: -50 }, { left: 2, right: 3, value: 4 }] },
		{ coverage: 0x80, format: 0, pairs: [{ left: 1, right: 2, value: -1000 }] },
		{ coverage: 0x40, format: 0, pairs: [{ left: 1, right: 2, value: -1000 }] },
		{ coverage: 0x20, format: 0, pairs: [{ left: 1, right: 2, value: -1000 }] },
		{ coverage: 0, format: 2, pairs: [{ left: 1, right: 2, value: -1000 }] },
		{ coverage: 0, format: 0, pairs: [{ left: 1, right: 2, value: -1 }] },
	])
	kerning_of(basic_with("kern", kern), [1, 2, 3]) == [-51.0, 4.0, 0.0]
}
expect problems_of(basic_with("kern", apple_kern([{ coverage: 0, format: 0, pairs: [{ left: 1, right: 2, value: -50 }] }]).drop_last(1))) == [BadTable("kern")]
expect problems_of(basic_with("kern", FontTest.patch(apple_kern([]), 4, FontTest.u32(0xFFFFFFFF)))) == [BadTable("kern")]
expect problems_of(basic_with("kern", FontTest.patch(apple_kern([{ coverage: 0, format: 0, pairs: [] }]), 8, FontTest.u32(8)))) == [BadTable("kern")]
expect kerning_of(basic_with("kern", apple_kern([])), [1, 2]) == [0.0, 0.0]

# ------------------------------------------------------------ Inter

# Known values, checked against fontTools and HarfBuzz reading the same
# file.
expect {
	font = Font.inter
	Font.ascent(font) == 1984.0 and Font.descent(font) == 494.0 and Font.glyph_total(font) == 2937
}
expect {
	font = Font.inter
	cps = [0x41, 0x56, 0x54, 0x6F, 0x2D, 0x3E, 0x20, 0x2A, 0x31, 0xE9, 0x20AC, 0x2192, 0x1F852, 0x378, 0x10FFFF]
	cps.map(|cp| Font.glyph(font, cp) ?? 9999) == [2, 456, 411, 790, 1459, 1517, 1777, 1547, 1342, 618, 1316, 1805, 1807, 9999, 9999]
}
expect {
	font = Font.inter
	[2, 456, 411, 790, 1459, 1517, 1777, 1547, 1342, 618, 1316, 1805, 2936].map(|g| Font.advance(font, g)) == [1413.0, 1413.0, 1322.0, 1228.0, 942.0, 1355.0, 576.0, 1026.0, 833.0, 1194.0, 1365.0, 1954.0, 434.0]
}
expect {
	font = Font.inter
	[0, 2, 1547, 1548, 1777, 1805, 2936].map(|g| Font.ink(font, g)) == [Ink({ left: 328.0, right: 1016.0 }), Ink({ left: 52.0, right: 1361.0 }), Ink({ left: 114.0, right: 912.0 }), Ink({ left: 195.0, right: 1126.0 }), NoInk, Ink({ left: 256.0, right: 1752.0 }), Ink({ left: 80.0, right: 354.0 })]
}

# Kerning pairs A V, T o, V A, A A, W a, y period, T y, L T, and A with the
# raised asterisk.
expect {
	font = Font.inter
	pairs = [(2, 456), (411, 790), (456, 2), (2, 2), (459, 507), (998, 1502), (411, 998), (281, 411), (2, 1548)]
	pairs.map(|(l, r)| Font.kerning(font, [l, r])) == [[-140.0, 0.0], [-160.0, 0.0], [-140.0, 0.0], [30.0, 0.0], [-104.0, 0.0], [-90.0, 0.0], [-128.0, 0.0], [-197.0, 0.0], [-69.0, 0.0]]
}

# Inter shaped by HarfBuzz 15.0.0 (through uharfbuzz 0.57.0) with its default
# features: the glyphs, the first character each draws, and each glyph's
# advance including kerning, in font units.
inter_cases : List({ text : Str, code_points : List(U32), glyphs : List(U64), clusters : List(U64), advances : List(F64) })
inter_cases = [
	{ text: "Hello World", code_points: [72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100], glyphs: [161, 614, 736, 736, 790, 1777, 459, 790, 852, 736, 597], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], advances: [1522.0, 1194.0, 496.0, 496.0, 1228.0, 576.0, 1914.0, 1228.0, 803.0, 496.0, 1254.0] },
	{ text: "A->B", code_points: [65, 45, 62, 66], glyphs: [2, 1829, 65], clusters: [0, 1, 3], advances: [1413.0, 1954.0, 1340.0] },
	{ text: "x --> y", code_points: [120, 32, 45, 45, 62, 32, 121], glyphs: [993, 1777, 1806, 1777, 998], clusters: [0, 1, 2, 5, 6], advances: [1118.0, 576.0, 2746.0, 576.0, 1151.0] },
	{ text: "<->", code_points: [60, 45, 62], glyphs: [1814], clusters: [0], advances: [2746.0] },
	{ text: "->>", code_points: [45, 62, 62], glyphs: [1805, 1517], clusters: [0, 2], advances: [1954.0, 1355.0] },
	{ text: "<-", code_points: [60, 45], glyphs: [1800], clusters: [0], advances: [1954.0] },
	{ text: "=>", code_points: [61, 62], glyphs: [1808], clusters: [0], advances: [1954.0] },
	{ text: "<=", code_points: [60, 61], glyphs: [1516, 1520], clusters: [0, 1], advances: [1355.0, 1355.0] },
	{ text: "!=", code_points: [33, 61], glyphs: [1427, 1533], clusters: [0, 1], advances: [589.0, 1355.0] },
	{ text: "==", code_points: [61, 61], glyphs: [1520, 1520], clusters: [0, 1], advances: [1355.0, 1355.0] },
	{ text: "...", code_points: [46, 46, 46], glyphs: [1502, 1502, 1502], clusters: [0, 1, 2], advances: [590.0, 590.0, 590.0] },
	{ text: "--", code_points: [45, 45], glyphs: [1459, 1459], clusters: [0, 1], advances: [942.0, 942.0] },
	{ text: "---", code_points: [45, 45, 45], glyphs: [1459, 1459, 1459], clusters: [0, 1, 2], advances: [942.0, 942.0, 942.0] },
	{ text: "A*", code_points: [65, 42], glyphs: [2, 1548], clusters: [0, 1], advances: [1344.0, 1321.0] },
	{ text: "1*", code_points: [49, 42], glyphs: [1342, 1548], clusters: [0, 1], advances: [833.0, 1321.0] },
	{ text: "a*", code_points: [97, 42], glyphs: [507, 1547], clusters: [0, 1], advances: [1150.0, 1026.0] },
	{ text: "A*B", code_points: [65, 42, 66], glyphs: [2, 1548, 65], clusters: [0, 1, 2], advances: [1344.0, 1321.0, 1340.0] },
	{ text: "(a+b)*c", code_points: [40, 97, 43, 98, 41, 42, 99], glyphs: [1437, 507, 1522, 578, 1438, 1547, 586], clusters: [0, 1, 2, 3, 4, 5, 6], advances: [747.0, 1150.0, 1355.0, 1231.0, 747.0, 1026.0, 1170.0] },
	{ text: "12:30", code_points: [49, 50, 58, 51, 48], glyphs: [1342, 1343, 1506, 1345, 1341], clusters: [0, 1, 2, 3, 4], advances: [833.0, 1249.0, 590.0, 1265.0, 1292.0] },
	{ text: "A:B", code_points: [65, 58, 66], glyphs: [2, 1506, 65], clusters: [0, 1, 2], advances: [1413.0, 590.0, 1340.0] },
	{ text: "AVATAR", code_points: [65, 86, 65, 84, 65, 82], glyphs: [2, 456, 2, 411, 2, 384], clusters: [0, 1, 2, 3, 4, 5], advances: [1273.0, 1273.0, 1239.0, 1148.0, 1413.0, 1318.0] },
	{ text: "Tomorrow", code_points: [84, 111, 109, 111, 114, 114, 111, 119], glyphs: [411, 790, 766, 790, 852, 852, 790, 984], clusters: [0, 1, 2, 3, 4, 5, 6, 7], advances: [1162.0, 1228.0, 1794.0, 1228.0, 803.0, 737.0, 1191.0, 1676.0] },
	{ text: "WAVE", code_points: [87, 65, 86, 69], glyphs: [459, 2, 456, 95], clusters: [0, 1, 2, 3], advances: [1902.0, 1273.0, 1413.0, 1231.0] },
	{ text: "Typography", code_points: [84, 121, 112, 111, 103, 114, 97, 112, 104, 121], glyphs: [411, 998, 843, 790, 658, 852, 507, 843, 670, 998], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], advances: [1194.0, 1151.0, 1254.0, 1228.0, 1256.0, 771.0, 1150.0, 1254.0, 1181.0, 1151.0] },
	{ text: "LT", code_points: [76, 84], glyphs: [281, 411], clusters: [0, 1], advances: [961.0, 1322.0] },
	{ text: "Yo", code_points: [89, 111], glyphs: [472, 790], clusters: [0, 1], advances: [1233.0, 1228.0] },
	{ text: "P.", code_points: [80, 46], glyphs: [375, 1502], clusters: [0, 1], advances: [1239.0, 590.0] },
	{ text: "r,", code_points: [114, 44], glyphs: [852, 1501], clusters: [0, 1], advances: [643.0, 590.0] },
	{ text: "\"quoted\"", code_points: [34, 113, 117, 111, 116, 101, 100, 34], glyphs: [1485, 849, 915, 790, 889, 614, 597, 1485], clusters: [0, 1, 2, 3, 4, 5, 6, 7], advances: [924.0, 1254.0, 1211.0, 1228.0, 650.0, 1194.0, 1254.0, 954.0] },
	{ text: "[box]", code_points: [91, 98, 111, 120, 93], glyphs: [1439, 578, 790, 993, 1441], clusters: [0, 1, 2, 3, 4], advances: [747.0, 1254.0, 1182.0, 1118.0, 747.0] },
	{ text: "{curly}", code_points: [123, 99, 117, 114, 108, 121, 125], glyphs: [1443, 586, 915, 852, 736, 998, 1444], clusters: [0, 1, 2, 3, 4, 5, 6], advances: [850.0, 1170.0, 1211.0, 803.0, 506.0, 1151.0, 873.0] },
	{ text: "A/B", code_points: [65, 47, 66], glyphs: [2, 1455, 65], clusters: [0, 1, 2], advances: [1453.0, 738.0, 1340.0] },
	{ text: "50%", code_points: [53, 48, 37], glyphs: [1347, 1341, 1744], clusters: [0, 1, 2], advances: [1215.0, 1292.0, 2011.0] },
	{ text: "office fi fl", code_points: [111, 102, 102, 105, 99, 101, 32, 102, 105, 32, 102, 108], glyphs: [790, 647, 647, 689, 586, 614, 1777, 647, 689, 1777, 647, 736], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], advances: [1228.0, 678.0, 758.0, 496.0, 1170.0, 1194.0, 576.0, 758.0, 496.0, 576.0, 758.0, 496.0] },
	{ text: "Façade", code_points: [70, 97, 231, 97, 100, 101], glyphs: [137, 507, 589, 507, 597, 614], clusters: [0, 1, 2, 3, 4, 5], advances: [1159.0, 1150.0, 1190.0, 1150.0, 1254.0, 1194.0] },
	{ text: "Ünïcödé", code_points: [220, 110, 239, 99, 246, 100, 233], glyphs: [429, 773, 692, 586, 791, 597, 618], clusters: [0, 1, 2, 3, 4, 5, 6], advances: [1524.0, 1210.0, 496.0, 1170.0, 1228.0, 1254.0, 1194.0] },
	{ text: "€100 → £5", code_points: [8364, 49, 48, 48, 32, 8594, 32, 163, 53], glyphs: [1316, 1342, 1341, 1341, 1777, 1829, 1777, 1312, 1347], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8], advances: [1365.0, 833.0, 1292.0, 1292.0, 576.0, 1954.0, 576.0, 1251.0, 1215.0] },
	{ text: "x×y", code_points: [120, 215, 121], glyphs: [993, 1524, 998], clusters: [0, 1, 2], advances: [1118.0, 1355.0, 1151.0] },
	{ text: "αβγ", code_points: [945, 946, 947], glyphs: [1110, 1136, 1137], clusters: [0, 1, 2], advances: [1360.0, 1220.0, 1151.0] },
	{ text: "Привет", code_points: [1055, 1088, 1080, 1074, 1077, 1090], glyphs: [2434, 848, 1262, 1254, 641, 1280], clusters: [0, 1, 2, 3, 4, 5], advances: [1522.0, 1254.0, 1211.0, 1157.0, 1194.0, 954.0] },
	{ text: "Is it ready?", code_points: [73, 115, 32, 105, 116, 32, 114, 101, 97, 100, 121, 63], glyphs: [197, 871, 1777, 689, 889, 1777, 852, 614, 507, 597, 998, 1431], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], advances: [550.0, 1081.0, 576.0, 496.0, 670.0, 576.0, 737.0, 1214.0, 1150.0, 1264.0, 1151.0, 1047.0] },
	{ text: "Start", code_points: [83, 116, 97, 114, 116], glyphs: [397, 889, 507, 852, 889], clusters: [0, 1, 2, 3, 4], advances: [1314.0, 680.0, 1150.0, 803.0, 670.0] },
	{ text: "End", code_points: [69, 110, 100], glyphs: [95, 773, 597], clusters: [0, 1, 2], advances: [1231.0, 1210.0, 1254.0] },
	{ text: "Process data", code_points: [80, 114, 111, 99, 101, 115, 115, 32, 100, 97, 116, 97], glyphs: [375, 852, 790, 586, 614, 871, 871, 1777, 597, 507, 889, 507], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], advances: [1308.0, 737.0, 1228.0, 1170.0, 1194.0, 1081.0, 1081.0, 576.0, 1254.0, 1150.0, 680.0, 1150.0] },
	{ text: "#1", code_points: [35, 49], glyphs: [1453, 1342], clusters: [0, 1], advances: [1297.0, 833.0] },
	{ text: "@at ~tilde ^caret _under_", code_points: [64, 97, 116, 32, 126, 116, 105, 108, 100, 101, 32, 94, 99, 97, 114, 101, 116, 32, 95, 117, 110, 100, 101, 114, 95], glyphs: [1445, 507, 889, 1777, 1528, 889, 689, 736, 597, 614, 1777, 1546, 586, 507, 852, 614, 889, 1777, 1543, 915, 773, 597, 614, 852, 1543], clusters: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24], advances: [1978.0, 1150.0, 670.0, 576.0, 1355.0, 670.0, 496.0, 496.0, 1254.0, 1194.0, 576.0, 965.0, 1190.0, 1150.0, 737.0, 1194.0, 670.0, 576.0, 934.0, 1211.0, 1210.0, 1254.0, 1194.0, 771.0, 934.0] },
	{ text: "1/2", code_points: [49, 47, 50], glyphs: [1342, 1455, 1343], clusters: [0, 1, 2], advances: [833.0, 738.0, 1249.0] },
	{ text: "+-", code_points: [43, 45], glyphs: [1522, 1459], clusters: [0, 1], advances: [1355.0, 942.0] },
	{ text: ":-)", code_points: [58, 45, 41], glyphs: [1506, 1471, 1447], clusters: [0, 1, 2], advances: [590.0, 942.0, 747.0] },
]

inter_shaped : { text : Str, code_points : List(U32), glyphs : List(U64), clusters : List(U64), advances : List(F64) } -> Bool
inter_shaped = |case| {
	font = Font.inter
	items = case.code_points.map_with_index(|cp, i| { glyph: Font.glyph(font, cp) ?? 0, cluster: i })
	shaped = Font.substitute(font, items)
	glyphs = shaped.map(|item| item.glyph)
	advances = glyphs.map2(Font.kerning(font, glyphs), |g, k| Font.advance(font, g) + k)
	glyphs == case.glyphs and shaped.map(|item| item.cluster) == case.clusters and advances == case.advances
}

expect inter_cases.len() > 40 and inter_cases.keep_if(|case| !inter_shaped(case)).map(|case| case.text) == []
