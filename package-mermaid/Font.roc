import "FontInter.ttf" as inter_file : List(U8)
import FontShape

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
				Classes({ rows : List(U16), columns : List(U16), width : U64, height : U64, first : List(I16), second : List(I16), skips : Bool }),
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
		var $adjust = List.repeat(0.0, count)
		for lookup in font.kerning {
			var $i = 0
			while $i + 1 < count {
				left = glyphs.get($i) ?? 0
				right = glyphs.get($i + 1) ?? 0
				match Font.pair(lookup, left, right) {
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

	# The first subtable of a lookup that covers the pair decides it.
	pair : List([Pairs({ keys : List(U32), first : List(I16), second : List(I16), skips : Bool }), Classes({ rows : List(U16), columns : List(U16), width : U64, height : U64, first : List(I16), second : List(I16), skips : Bool })]), U64, U64 -> [Applied({ first : F64, second : F64, skips : Bool }), NotApplied]
	pair = |subtables, left, right| {
		var $result = NotApplied
		var $k = 0
		while $k < subtables.len() {
			outcome = match subtables.get($k) {
				Ok(Pairs(list)) => Font.pair_in_list(list.keys, list.first, list.second, list.skips, left, right)
				Ok(Classes(grid)) => Font.pair_in_classes(grid.rows, grid.columns, grid.width, grid.height, grid.first, grid.second, grid.skips, left, right)
				Err(_) => NotApplied
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

	pair_in_classes : List(U16), List(U16), U64, U64, List(I16), List(I16), Bool, U64, U64 -> [Applied({ first : F64, second : F64, skips : Bool }), NotApplied]
	pair_in_classes = |rows, columns, width, height, first, second, skips, left, right| {
		row = (rows.get(left) ?? 0xFFFF).to_u64()
		column = (columns.get(right) ?? 0).to_u64()
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
									ranges: c.keep_if(|range| range.glyph.to_u64() + (range.last - range.first).to_u64() < count_of_glyphs),
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

	Subtable : [
		Pairs({ keys : List(U32), first : List(I16), second : List(I16), skips : Bool }),
		Classes({ rows : List(U16), columns : List(U16), width : U64, height : U64, first : List(I16), second : List(I16), skips : Bool }),
	]

	# Pair kerning from the `kern` feature of `GPOS`, or, for a font without
	# `GPOS`, from a TrueType `kern` table.
	read_kerning : List(U8), List(Table), U64 -> Try(List(List(Subtable)), Problem)
	read_kerning = |bytes, tables, count_of_glyphs|
		match Font.table(bytes, tables, "GPOS", 10) {
			Bad => Err(BadTable("GPOS"))
			Found(gpos) => Font.read_gpos(gpos, count_of_glyphs)
			Missing =>
				match Font.table(bytes, tables, "kern", 4) {
					Bad => Err(BadTable("kern"))
					Found(kern) => Font.read_kern(kern)
					Missing => Ok([])
				}
		}

	read_gpos : List(U8), U64 -> Try(List(List(Subtable)), Problem)
	read_gpos = |gpos, count_of_glyphs| {
		bad = BadTable("GPOS")
		features = Font.u16(gpos, 6)
		lookups = Font.u16(gpos, 8)
		feature_count = Font.u16(gpos, features)
		lookup_count = Font.u16(gpos, lookups)
		if !Font.fits(features, 2 + 6 * feature_count, gpos.len()) or !Font.fits(lookups, 2 + 2 * lookup_count, gpos.len()) {
			Err(bad)
		} else {
			# Lookup indices of every `kern` feature, deduplicated, in order.
			var $wanted = List.repeat(False, lookup_count)
			var $ok = True
			for f in 0..<feature_count {
				record = features + 2 + 6 * f
				if Font.u32(gpos, record) == Font.tag_of("kern") {
					feature = features + Font.u16(gpos, record + 4)
					count = Font.u16(gpos, feature + 2)
					if !Font.fits(feature, 4 + 2 * count, gpos.len()) {
						$ok = False
					} else {
						for j in 0..<count {
							index = Font.u16(gpos, feature + 4 + 2 * j)
							if index < lookup_count {
								$wanted = $wanted.set(index, True) ?? []
							} else {
								$ok = False
							}
						}
					}
				}
			}
			if !$ok {
				Err(bad)
			} else {
				var $result = Ok([])
				for index in 0..<lookup_count {
					if $wanted.get(index) ?? False {
						lookup = lookups + Font.u16(gpos, lookups + 2 + 2 * index)
						$result = match ($result, Font.read_lookup(gpos, lookup, count_of_glyphs)) {
							(Ok(done), Ok(subtables)) => Ok(done.append(subtables))
							(Err(e), _) => Err(e)
							(_, Err(e)) => Err(e)
						}
					}
				}
				$result
			}
		}
	}

	read_lookup : List(U8), U64, U64 -> Try(List(Subtable), Problem)
	read_lookup = |gpos, lookup, count_of_glyphs| {
		kind = Font.u16(gpos, lookup)
		count = Font.u16(gpos, lookup + 4)
		if !Font.fits(lookup, 6 + 2 * count, gpos.len()) {
			Err(BadTable("GPOS"))
		} else {
			var $subtables = []
			var $ok = True
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
					Some(start) =>
						match Font.read_pair_subtable(gpos, start, count_of_glyphs) {
							Ok(subtable) => {
								$subtables = $subtables.append(subtable)
							}
							Err(_) => {
								$ok = False
							}
						}
					None => {}
				}
			}
			if ($ok) Ok($subtables) else Err(BadTable("GPOS"))
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

	read_pair_subtable : List(U8), U64, U64 -> Try(Subtable, [Bad])
	read_pair_subtable = |data, at, count_of_glyphs| {
		if !Font.fits(at, 10, data.len()) {
			Err(Bad)
		} else {
			format = Font.u16(data, at)
			coverage = Font.read_coverage(data, at + Font.u16(data, at + 2))?
			format1 = Font.u16(data, at + 4)
			format2 = Font.u16(data, at + 6)
			size1 = Font.value_size(format1)
			size2 = Font.value_size(format2)
			skips = format2 != 0
			if format == 1 {
				set_count = Font.u16(data, at + 8)
				if !Font.fits(at + 10, 2 * set_count, data.len()) {
					Err(Bad)
				} else {
					var $keys = []
					var $first = []
					var $second = []
					var $ok = True
					for covered in coverage {
						if covered.index < set_count and covered.glyph < count_of_glyphs {
							set = at + Font.u16(data, at + 10 + 2 * covered.index)
							count = Font.u16(data, set)
							record = 2 + size1 + size2
							if !Font.fits(set, 2 + record * count, data.len()) {
								$ok = False
							} else {
								for p in 0..<count {
									r = set + 2 + record * p
									$keys = $keys.append(covered.glyph.to_u32_wrap().shl_wrap(16).bitwise_or(Font.u16(data, r).to_u32_wrap()))
									$first = $first.append(Font.x_advance(data, r + 2, format1))
									$second = $second.append(Font.x_advance(data, r + 2 + size1, format2))
								}
							}
						}
					}
					if ($ok) Ok(Pairs({ keys: $keys, first: $first, second: $second, skips })) else Err(Bad)
				}
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
						class1 = Font.read_classes(data, at + Font.u16(data, at + 8), count_of_glyphs)?
						class2 = Font.read_classes(data, at + Font.u16(data, at + 10), count_of_glyphs)?
						var $rows = List.repeat(0xFFFF, count_of_glyphs)
						for covered in coverage {
							if covered.glyph < count_of_glyphs {
								$rows = $rows.set(covered.glyph, class1.get(covered.glyph) ?? 0) ?? []
							}
						}
						var $first = List.with_capacity(width * height)
						var $second = List.with_capacity(width * height)
						for cell in 0..<(width * height) {
							r = at + 16 + record * cell
							$first = $first.append(Font.x_advance(data, r, format1))
							$second = $second.append(Font.x_advance(data, r + size1, format2))
						}
						Ok(Classes({ rows: $rows, columns: class2, width, height, first: $first, second: $second, skips }))
					}
				}
			} else {
				Err(Bad)
			}
		}
	}

	# The glyphs a coverage table lists, with their coverage indices.
	read_coverage : List(U8), U64 -> Try(List({ glyph : U64, index : U64 }), [Bad])
	read_coverage = |data, at| {
		format = Font.u16(data, at)
		count = Font.u16(data, at + 2)
		if format == 1 and Font.fits(at, 4 + 2 * count, data.len()) {
			var $out = List.with_capacity(count)
			for i in 0..<count {
				$out = $out.append({ glyph: Font.u16(data, at + 4 + 2 * i), index: i })
			}
			Ok($out)
		} else if format == 2 and Font.fits(at, 4 + 6 * count, data.len()) {
			var $out = []
			var $ok = True
			for i in 0..<count {
				r = at + 4 + 6 * i
				start = Font.u16(data, r)
				end = Font.u16(data, r + 2)
				index = Font.u16(data, r + 4)
				if end < start {
					$ok = False
				} else {
					for g in start..<(end + 1) {
						$out = $out.append({ glyph: g, index: index + g - start })
					}
				}
			}
			if ($ok) Ok($out) else Err(Bad)
		} else {
			Err(Bad)
		}
	}

	# A class definition table as a class per glyph (0 when unlisted).
	read_classes : List(U8), U64, U64 -> Try(List(U16), [Bad])
	read_classes = |data, at, count_of_glyphs| {
		format = Font.u16(data, at)
		var $classes = List.repeat(0, count_of_glyphs)
		if format == 1 and Font.fits(at, 6, data.len()) {
			start = Font.u16(data, at + 2)
			count = Font.u16(data, at + 4)
			if Font.fits(at + 6, 2 * count, data.len()) {
				for i in 0..<count {
					g = start + i
					if g < count_of_glyphs {
						$classes = $classes.set(g, Font.u16(data, at + 6 + 2 * i).to_u16_wrap()) ?? []
					}
				}
				Ok($classes)
			} else {
				Err(Bad)
			}
		} else if format == 2 and Font.fits(at, 4, data.len()) {
			count = Font.u16(data, at + 2)
			if Font.fits(at + 4, 6 * count, data.len()) {
				var $ok = True
				for i in 0..<count {
					r = at + 4 + 6 * i
					start = Font.u16(data, r)
					end = Font.u16(data, r + 2)
					class = Font.u16(data, r + 4).to_u16_wrap()
					if end < start {
						$ok = False
					} else {
						for g in start..<(end.min(count_of_glyphs) + 1) {
							if g < count_of_glyphs {
								$classes = $classes.set(g, class) ?? []
							}
						}
					}
				}
				if ($ok) Ok($classes) else Err(Bad)
			} else {
				Err(Bad)
			}
		} else {
			Err(Bad)
		}
	}

	# A TrueType `kern` table: each horizontal format 0 subtable is a lookup.
	read_kern : List(U8) -> Try(List(List(Subtable)), Problem)
	read_kern = |kern| {
		count = Font.u16(kern, 2)
		var $at = 4
		var $lookups = []
		var $ok = Font.u16(kern, 0) == 0
		for _ in 0..<count {
			if $ok {
				if !Font.fits($at, 14, kern.len()) {
					$ok = False
				} else {
					length = Font.u16(kern, $at + 2)
					coverage = Font.u16(kern, $at + 4)
					pairs = Font.u16(kern, $at + 6)
					if coverage == 0x0001 {
						if !Font.fits($at + 14, 6 * pairs, kern.len()) {
							$ok = False
						} else {
							var $keys = List.with_capacity(pairs)
							var $first = List.with_capacity(pairs)
							for p in 0..<pairs {
								r = $at + 14 + 6 * p
								$keys = $keys.append(Font.u32(kern, r).to_u32_wrap())
								$first = $first.append(Font.i16(kern, r + 4).to_i16_wrap())
							}
							$lookups = $lookups.append([Pairs({ keys: $keys, first: $first, second: [], skips: False })])
						}
					}
					$at = $at + length.max(6)
				}
			}
		}
		if ($ok) Ok($lookups) else Err(BadTable("kern"))
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
