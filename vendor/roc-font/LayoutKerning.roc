import Sfnt
import Bytes
import LayoutCommon
import LayoutGsub

## Pair positioning: the pair adjustment lookups of `GPOS` (lookup type
## 2, directly or through an extension) that a shaping plan lists, and the
## horizontal format 0 subtables of a TrueType `kern` table, which HarfBuzz
## applies when the plan's `GPOS` language system has no `kern` feature.
##
## Reading checks every offset and count a positioning step will follow
## and keeps the tables' bytes; positioning reads coverage, class
## definitions, pair sets and value records in place. Reading therefore
## allocates a few lists per table, not per pair, pair set or glyph. The
## checked subtables are one flat list in lookup list order; `ends` holds,
## for each lookup of the lookup list, the end of its subtables in that
## list (a lookup no feature reaches, or of another type, has none).
##
## `Kern` is a `kern` format 0 subtable: `count` pairs of six bytes from
## `at`, sorted by their first and second glyph (reading checks the order,
## since lookups search it). `Sets` is GPOS pair format 1 and `Classes`
## pair format 2; their fields are offsets into the table and the
## subtable's value formats. Of each value record the x and y placement
## and the x advance are used (horizontal text); device tables are not.
LayoutKerning := {
	data : List(U8),
	common : LayoutCommon,
	subtables : List(Pair),
	ends : List(U64),
	digests : List({ a : U64, b : U64, c : U64 }),
	kern_data : List(U8),
	kern_subtables : List(Pair),
	kern_digests : List({ a : U64, b : U64, c : U64 }),
	has_gpos : Bool,
	has_kern : Bool,
}.{

	Pair : [
		Kern({ at : U64, count : U64 }),
		Sets({ at : U64, coverage : U64, set_count : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 }),
		Classes({ at : U64, coverage : U64, rows : U64, columns : U64, width : U64, height : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 }),
	]

	## The `GPOS` part of reading.
	Gpos : { data : List(U8), common : LayoutCommon, subtables : List(Pair), ends : List(U64), digests : List({ a : U64, b : U64, c : U64 }) }

	## The `kern` part of reading.
	Legacy : { data : List(U8), subtables : List(Pair), digests : List({ a : U64, b : U64, c : U64 }) }

	## A value record's effect on one glyph.
	Value : { dx : I64, dy : I64, ax : I64 }

	## One pair's effect: on the first glyph, on the second, whether the
	## pair skips the second glyph (it has a second value record) and
	## whether any value is not zero.
	Found : { first : Value, second : Value, skips : Bool, nonzero : Bool }

	## Adjustments per glyph, index-aligned with the run, and the run with
	## unsafe-to-break flags set.
	Positions : { items : List(LayoutGsub.Item), dx : List(I64), dy : List(I64), ax : List(I64) }

	## No positioning.
	none : LayoutKerning
	none = { data: [], common: LayoutCommon.none, subtables: [], ends: [], digests: [], kern_data: [], kern_subtables: [], kern_digests: [], has_gpos: False, has_kern: False }

	## Put the two parts together; either may be absent (or dropped).
	combine : [Present(Gpos), Absent], [Present(Legacy), Absent] -> LayoutKerning
	combine = |gpos, legacy| {
		with_gpos = match gpos {
			Present(g) => { ..LayoutKerning.none, data: g.data, common: g.common, subtables: g.subtables, ends: g.ends, digests: g.digests, has_gpos: True }
			Absent => LayoutKerning.none
		}
		match legacy {
			Present(k) => { ..with_gpos, kern_data: k.data, kern_subtables: k.subtables, kern_digests: k.digests, has_kern: True }
			Absent => with_gpos
		}
	}

	## The script and feature lists of `GPOS`, for choosing lookups.
	common_of : LayoutKerning -> LayoutCommon
	common_of = |kerning| kerning.common

	## Whether the font has a `GPOS` table, and a `kern` table.
	has_gpos : LayoutKerning -> Bool
	has_gpos = |kerning| kerning.has_gpos

	has_kern : LayoutKerning -> Bool
	has_kern = |kerning| kerning.has_kern

	## How many subtables reading kept, for tests of reading costs.
	stored_size : LayoutKerning -> U64
	stored_size = |kerning| kerning.subtables.len() + kerning.kern_subtables.len()

	no_value : Value
	no_value = { dx: 0, dy: 0, ax: 0 }

	# ------------------------------------------------------------ applying

	## Position a run: the plan's `GPOS` pair lookups in order, each where
	## both glyphs' masks share a bit with its mask, then, when `legacy` is
	## `Kern(mask)`, each `kern` subtable in turn. Values add up. Glyphs
	## at or past `glyph_count` are never a first glyph of `GPOS` pair
	## formats; as a second glyph they are in class 0.
	position : LayoutKerning, List({ index : U64, mask : U64 }), [Kern(U64), NoKern], List(LayoutGsub.Item), U64 -> Positions
	position = |kerning, plan, legacy, items, glyph_count| {
		count = items.len()
		var $out = { items, dx: List.repeat(0, count), dy: List.repeat(0, count), ax: List.repeat(0, count) }
		for entry in plan {
			start = if (entry.index == 0) 0 else kerning.ends.get(entry.index - 1) ?? 0
			end = kerning.ends.get(entry.index) ?? 0
			if end > start {
				$out = LayoutKerning.apply_lookup(kerning.data, kerning.subtables, kerning.digests, start, end, entry.mask, $out, glyph_count, False)
			}
		}
		match legacy {
			Kern(mask) => {
				for k in 0..<kerning.kern_subtables.len() {
					$out = LayoutKerning.apply_lookup(kerning.kern_data, kerning.kern_subtables, kerning.kern_digests, k, k + 1, mask, $out, glyph_count, True)
				}
			}
			NoKern => {}
		}
		$out
	}

	# One lookup (subtables `start ..< end`) over the whole run. With
	# `split`, a `kern` table's value is split between the pair as HarfBuzz
	# splits it: half (rounded down) on the first glyph's advance, the rest
	# on the second glyph's advance and offset. The lists are local
	# variables, not fields of a record passed around, so each stays unique
	# and is changed in place.
	apply_lookup : List(U8), List(Pair), List({ a : U64, b : U64, c : U64 }), U64, U64, U64, Positions, U64, Bool -> Positions
	apply_lookup = |data, subtables, digests, start, end, mask, positions, glyph_count, split| {
		{ items, dx, dy, ax } = positions
		count = items.len()
		var $items = items
		var $dx = dx
		var $dy = dy
		var $ax = ax
		var $i = 0
		while $i + 1 < count {
			first = $items.get($i) ?? LayoutGsub.no_item
			second = $items.get($i + 1) ?? LayoutGsub.no_item
			if !LayoutGsub.applies(first.mask, mask) or !LayoutGsub.applies(second.mask, mask) {
				$i = $i + 1
			} else {
				match LayoutKerning.pair(data, subtables, digests, start, end, first.glyph, second.glyph, glyph_count) {
					Applied(found) => {
						j = $i + 1
						values =
							if split {
								kern = found.first.ax
								kern1 = kern.shr_wrap(1)
								kern2 = kern - kern1
								{ first: { dx: 0, dy: 0, ax: kern1 }, second: { dx: kern2, dy: 0, ax: kern2 } }
							} else {
								{ first: found.first, second: found.second }
							}
						# `$i < j < count`, the length of every list.
						$dx = $dx.set($i, ($dx.get($i) ?? 0) + values.first.dx) ?? []
						$dy = $dy.set($i, ($dy.get($i) ?? 0) + values.first.dy) ?? []
						$ax = $ax.set($i, ($ax.get($i) ?? 0) + values.first.ax) ?? []
						$dx = $dx.set(j, ($dx.get(j) ?? 0) + values.second.dx) ?? []
						$dy = $dy.set(j, ($dy.get(j) ?? 0) + values.second.dy) ?? []
						$ax = $ax.set(j, ($ax.get(j) ?? 0) + values.second.ax) ?? []
						if found.nonzero {
							$items = LayoutKerning.unsafe_to_break($items, $i, j + 1)
						}
						if found.skips {
							$items = LayoutKerning.unsafe_to_break($items, $i, j + 2)
						}
						$i = if (found.skips) j + 1 else j
					}
					NotApplied => {
						$i = $i + 1
					}
				}
			}
		}
		{ items: $items, dx: $dx, dy: $dy, ax: $ax }
	}

	## HarfBuzz's `unsafe_to_break(start, end)` within a run.
	unsafe_to_break : List(LayoutGsub.Item), U64, U64 -> List(LayoutGsub.Item)
	unsafe_to_break = |items, start, end_raw| {
		end = end_raw.min(items.len())
		if end_raw - start > 255 or end < start + 2 {
			items
		} else {
			LayoutGsub.flag_range(items, start, end, LayoutGsub.min_cluster(items, start, end, 0xFFFFFFFFFFFFFFFF))
		}
	}

	# The first subtable of a lookup that has the pair decides it.
	pair : List(U8), List(Pair), List({ a : U64, b : U64, c : U64 }), U64, U64, U64, U64, U64 -> [Applied(Found), NotApplied]
	pair = |data, subtables, digests, start, end, left, right, glyph_count| {
		var $result = NotApplied
		var $k = start
		while $k < end {
			# The digest rules out most first glyphs without a search.
			may = LayoutKerning.may_have(digests.get($k) ?? LayoutKerning.full, left)
			outcome = if !may {
				NotApplied
			} else match subtables.get($k) {
				Ok(Kern(k)) => LayoutKerning.kern_pair(data, k.at, k.count, left, right)
				Ok(Sets(s)) if left < glyph_count => LayoutKerning.set_pair(data, s, left, right)
				Ok(Classes(c)) if left < glyph_count => LayoutKerning.class_pair(data, c, left, right, glyph_count)
				_ => NotApplied
			}
			match outcome {
				Applied(found) => {
					$result = Applied(found)
					$k = end
				}
				NotApplied => {
					$k = $k + 1
				}
			}
		}
		$result
	}

	kern_pair : List(U8), U64, U64, U64, U64 -> [Applied(Found), NotApplied]
	kern_pair = |data, at, count, left, right|
		if left > 0xFFFF or right > 0xFFFF {
			NotApplied
		} else {
			key = left * 65536 + right
			var $low = 0
			var $high = count
			var $result = NotApplied
			while $low < $high {
				mid = ($low + $high) // 2
				r = at + 6 * mid
				probe = Bytes.u32(data, r)
				if key < probe {
					$high = mid
				} else if key > probe {
					$low = mid + 1
				} else {
					value = Bytes.i16(data, r + 4)
					# A zero value is no kerning (HarfBuzz skips the pair).
					$result = if (value == 0) NotApplied else Applied({ first: { dx: 0, dy: 0, ax: value }, second: LayoutKerning.no_value, skips: False, nonzero: True })
					$low = $high
				}
			}
			$result
		}

	# Pair format 1: the first glyph's coverage index picks a pair set, in
	# which the second glyph is looked up.
	set_pair : List(U8), { at : U64, coverage : U64, set_count : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 }, U64, U64 -> [Applied(Found), NotApplied]
	set_pair = |data, s, left, right|
		match LayoutKerning.covered(data, s.coverage, left) {
			Ok(index) if index < s.set_count => {
				set = s.at + Bytes.u16(data, s.at + 10 + 2 * index)
				record = 2 + s.size1 + s.size2
				var $low = 0
				var $high = Bytes.u16(data, set)
				var $result = NotApplied
				while $low < $high {
					mid = ($low + $high) // 2
					r = set + 2 + record * mid
					probe = Bytes.u16(data, r)
					if right < probe {
						$high = mid
					} else if right > probe {
						$low = mid + 1
					} else {
						$result = Applied(LayoutKerning.found(data, r + 2, s.format1, r + 2 + s.size1, s.format2))
						$low = $high
					}
				}
				$result
			}
			_ => NotApplied
		}

	# Pair format 2: a grid of first classes by second classes. A class past
	# the grid matches nothing.
	class_pair : List(U8), { at : U64, coverage : U64, rows : U64, columns : U64, width : U64, height : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 }, U64, U64, U64 -> [Applied(Found), NotApplied]
	class_pair = |data, c, left, right, glyph_count|
		if LayoutKerning.covered(data, c.coverage, left).is_err() {
			NotApplied
		} else {
			row = LayoutKerning.class_of(data, c.rows, left)
			column = if (right < glyph_count) LayoutKerning.class_of(data, c.columns, right) else 0
			if row >= c.height or column >= c.width {
				NotApplied
			} else {
				r = c.at + 16 + (c.size1 + c.size2) * (row * c.width + column)
				Applied(LayoutKerning.found(data, r, c.format1, r + c.size1, c.format2))
			}
		}

	found : List(U8), U64, U64, U64, U64 -> Found
	found = |data, first_at, format1, second_at, format2| {
		first = LayoutKerning.value(data, first_at, format1)
		second = LayoutKerning.value(data, second_at, format2)
		nonzero = first.dx != 0 or first.dy != 0 or first.ax != 0 or second.dx != 0 or second.dy != 0 or second.ax != 0
		{ first, second, skips: format2 != 0, nonzero }
	}

	## The coverage index of a glyph in a checked coverage table: a sorted
	## glyph array (format 1) or ranges with their first index (format 2).
	## Ranges are searched as stored; one whose last glyph comes before its
	## first matches nothing.
	covered : List(U8), U64, U64 -> Try(U64, [NotCovered])
	covered = |data, at, glyph| {
		count = Bytes.u16(data, at + 2)
		var $low = 0
		var $high = count
		var $result = Err(NotCovered)
		if Bytes.u16(data, at) == 1 {
			while $low < $high {
				mid = ($low + $high) // 2
				probe = Bytes.u16(data, at + 4 + 2 * mid)
				if glyph < probe {
					$high = mid
				} else if glyph > probe {
					$low = mid + 1
				} else {
					$result = Ok(mid)
					$low = $high
				}
			}
		} else {
			while $low < $high {
				mid = ($low + $high) // 2
				r = at + 4 + 6 * mid
				if glyph < Bytes.u16(data, r) {
					$high = mid
				} else if glyph > Bytes.u16(data, r + 2) {
					$low = mid + 1
				} else {
					$result = Ok(Bytes.u16(data, r + 4) + glyph - Bytes.u16(data, r))
					$low = $high
				}
			}
		}
		$result
	}

	## A glyph's class in a checked class definition: an array of classes
	## from a start glyph (format 1) or ranges (format 2). Other glyphs are
	## in class 0.
	class_of : List(U8), U64, U64 -> U64
	class_of = |data, at, glyph|
		if Bytes.u16(data, at) == 1 {
			start = Bytes.u16(data, at + 2)
			if (glyph >= start and glyph - start < Bytes.u16(data, at + 4)) Bytes.u16(data, at + 6 + 2 * (glyph - start)) else 0
		} else {
			var $low = 0
			var $high = Bytes.u16(data, at + 2)
			var $result = 0
			while $low < $high {
				mid = ($low + $high) // 2
				r = at + 4 + 6 * mid
				if glyph < Bytes.u16(data, r) {
					$high = mid
				} else if glyph > Bytes.u16(data, r + 2) {
					$low = mid + 1
				} else {
					$result = Bytes.u16(data, r + 4)
					$low = $high
				}
			}
			$result
		}

	# Size in bytes of a value record.
	value_size : U64 -> U64
	value_size = |format| 2 * format.bitwise_and(0xFF).to_u8_wrap().count_one_bits().to_u64()

	## A value record's x placement, y placement and x advance; fields it
	## lacks are 0. The y advance only matters to vertical text.
	value : List(U8), U64, U64 -> Value
	value = |data, at, format| {
		dx = if (format.bitwise_and(1) == 0) 0 else Bytes.i16(data, at)
		y_at = at + 2 * format.bitwise_and(1)
		dy = if (format.bitwise_and(2) == 0) 0 else Bytes.i16(data, y_at)
		x_at = at + 2 * format.bitwise_and(3).to_u8_wrap().count_one_bits().to_u64()
		ax = if (format.bitwise_and(4) == 0) 0 else Bytes.i16(data, x_at)
		{ dx, dy, ax }
	}

	# ------------------------------------------------------------ digests

	## A digest of a subtable's first glyphs, as HarfBuzz keeps for coverage:
	## three 64-bit masks of the glyph index's bits 0-5, 4-9 and 9-14. A
	## glyph whose three bits are not all set is certainly not covered, so
	## the subtable is skipped without searching it; one whose bits are set
	## may be covered and is searched. Built in one pass over each coverage
	## table (or `kern` pair list) when reading. On Inter's kerning bench this
	## skips most coverage searches (see `scripts/bench.py --ops kerning`).
	digests : List(U8), List([Kern({ at : U64, count : U64 }), Sets({ at : U64, coverage : U64, set_count : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 }), Classes({ at : U64, coverage : U64, rows : U64, columns : U64, width : U64, height : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 })]) -> List({ a : U64, b : U64, c : U64 })
	digests = |data, subtables| {
		var $out = List.with_capacity(subtables.len())
		for subtable in subtables {
			var $d = LayoutKerning.empty_digest
			match subtable {
				Kern(k) => {
					for p in 0..<k.count {
						left = Bytes.u16(data, k.at + 6 * p)
						$d = LayoutKerning.add_range($d, left, left)
					}
				}
				Sets(t) => {
					$d = LayoutKerning.coverage_digest(data, t.coverage)
				}
				Classes(t) => {
					$d = LayoutKerning.coverage_digest(data, t.coverage)
				}
			}
			$out = $out.append($d)
		}
		$out
	}

	empty_digest : { a : U64, b : U64, c : U64 }
	empty_digest = { a: 0, b: 0, c: 0 }

	full : { a : U64, b : U64, c : U64 }
	full = { a: 0xFFFFFFFFFFFFFFFF, b: 0xFFFFFFFFFFFFFFFF, c: 0xFFFFFFFFFFFFFFFF }

	coverage_digest : List(U8), U64 -> { a : U64, b : U64, c : U64 }
	coverage_digest = |data, at| {
		count = Bytes.u16(data, at + 2)
		var $d = LayoutKerning.empty_digest
		if Bytes.u16(data, at) == 1 {
			for i in 0..<count {
				g = Bytes.u16(data, at + 4 + 2 * i)
				$d = LayoutKerning.add_range($d, g, g)
			}
		} else {
			for i in 0..<count {
				r = at + 4 + 6 * i
				first = Bytes.u16(data, r)
				last = Bytes.u16(data, r + 2)
				if first <= last {
					$d = LayoutKerning.add_range($d, first, last)
				}
			}
		}
		$d
	}

	add_range : { a : U64, b : U64, c : U64 }, U64, U64 -> { a : U64, b : U64, c : U64 }
	add_range = |d, first, last| {
		a: d.a.bitwise_or(LayoutKerning.mask(first, last, 0)),
		b: d.b.bitwise_or(LayoutKerning.mask(first, last, 4)),
		c: d.c.bitwise_or(LayoutKerning.mask(first, last, 9)),
	}

	# The bits of `first >> shift` up to `last >> shift`, modulo 64.
	mask : U64, U64, U8 -> U64
	mask = |first, last, shift| {
		low = first.shr_zf_wrap(shift)
		high = last.shr_zf_wrap(shift)
		one : U64
		one = 1
		all : U64
		all = 0xFFFFFFFFFFFFFFFF
		if high - low >= 63 {
			all
		} else {
			lb = low.bitwise_and(63).to_u8_wrap()
			hb = high.bitwise_and(63).to_u8_wrap()
			if lb <= hb {
				(one.shl_wrap(hb - lb + 1) - 1).shl_wrap(lb)
			} else {
				all.shl_wrap(lb).bitwise_or(one.shl_wrap(hb + 1) - 1)
			}
		}
	}

	may_have : { a : U64, b : U64, c : U64 }, U64 -> Bool
	may_have = |d, g|
		d.a.shr_zf_wrap(g.bitwise_and(63).to_u8_wrap()).bitwise_and(1) == 1
			and d.b.shr_zf_wrap(g.shr_zf_wrap(4).bitwise_and(63).to_u8_wrap()).bitwise_and(1) == 1
			and d.c.shr_zf_wrap(g.shr_zf_wrap(9).bitwise_and(63).to_u8_wrap()).bitwise_and(1) == 1

	# ------------------------------------------------------------ reading

	## Reading work is counted in steps: one per table visited and one per
	## entry checked. Offsets may point many times at the same data, so a few
	## bytes could otherwise describe billions of entries; a table that takes
	## more than eight steps per byte (plus a fixed allowance) is refused.
	## `spend` adds a visit costing `cost` entries to `steps`, failing when
	## the table's allowance is exceeded, before the entries are visited.
	spend : List(U8), U64, U64 -> Try(U64, [Bad(U64)])
	spend = |data, steps, cost| {
		total = steps + cost + 1
		if (total > 8 * data.len() + 16384) Err(Bad(0)) else Ok(total)
	}

	## The pair adjustment lookups of a font file's `GPOS` that features
	## reach. A table listing more than `max_lookups` lookups is over the
	## limit.
	from_gpos : List(U8), List(Sfnt.Table), U64, U64 -> Try([Present(Gpos), Absent], [BadTable({ table : Str, offset : U32 }), OverLimit(Str)])
	from_gpos = |bytes, tables, count_of_glyphs, max_lookups|
		match Sfnt.located(bytes, tables, "GPOS", 10) {
			Missing => Ok(Absent)
			Bad(at) => Err(Sfnt.bad("GPOS", at))
			Found({ data, offset }) =>
				if Bytes.u16(data, Bytes.u16(data, 8)) > max_lookups {
					Err(OverLimit("max_lookups"))
				} else {
					match LayoutKerning.read_gpos(data, count_of_glyphs) {
						Ok(gpos) => Ok(Present(gpos))
						Err(Bad(at)) => Err(Sfnt.bad("GPOS", offset + at))
					}
				}
		}

	## The horizontal pair subtables of a font file's TrueType `kern` table.
	## As OTS (and so browsers) treat it, a table whose pairs are out of
	## order can be dropped (`Drop`), while one whose structure does not fit
	## rejects the font (`Reject`).
	from_kern : List(U8), List(Sfnt.Table) -> Try([Present(Legacy), Absent], [Drop([BadTable({ table : Str, offset : U32 })]), Reject([BadTable({ table : Str, offset : U32 })])])
	from_kern = |bytes, tables|
		match Sfnt.located(bytes, tables, "kern", 4) {
			Missing => Ok(Absent)
			Bad(at) => Err(Reject(Sfnt.bad("kern", at)))
			Found({ data, offset }) =>
				match LayoutKerning.read_kern(data) {
					Ok(kern) => Ok(Present(kern))
					Err(Unsorted(at)) => Err(Drop(Sfnt.bad("kern", offset + at)))
					Err(Bad(at)) => Err(Reject(Sfnt.bad("kern", offset + at)))
				}
		}

	## Every pair adjustment lookup a feature of a `GPOS` table lists, with
	## its script and feature lists. Problems give their offset in the table.
	read_gpos : List(U8), U64 -> Try(Gpos, [Bad(U64)])
	read_gpos = |gpos, glyph_count| {
		size = gpos.len()
		read_common = LayoutCommon.read(gpos)?
		common = read_common.common
		lookups = Bytes.u16(gpos, 8)
		used = LayoutCommon.all_feature_lookups(common)
		var $steps = read_common.steps
		var $subtables = []
		var $ends = List.with_capacity(common.lookup_count)
		for index in 0..<common.lookup_count {
			if used.get(index) ?? False {
				lookup = lookups + Bytes.u16(gpos, lookups + 2 + 2 * index)
				kind = Bytes.u16(gpos, lookup)
				count = Bytes.u16(gpos, lookup + 4)
				if !Bytes.fits(lookup, 6 + 2 * count, size) {
					return Err(Bad(lookup))
				}
				if kind == 2 or kind == 9 {
					$steps = LayoutKerning.spend(gpos, $steps, count)?
					for s in 0..<count {
						at = lookup + Bytes.u16(gpos, lookup + 6 + 2 * s)
						# An extension subtable points at the real one; one of
						# another lookup type is not pair positioning.
						target = if kind == 9 and Bytes.fits(at, 8, size) and Bytes.u16(gpos, at + 2) == 2 {
							Some(at + Bytes.u32(gpos, at + 4))
						} else if kind == 2 {
							Some(at)
						} else {
							None
						}
						match target {
							Some(start) => {
								done = LayoutKerning.read_pair(gpos, start, glyph_count, $steps)?
								$steps = done.steps
								$subtables = $subtables.append(done.value)
							}
							None => {}
						}
					}
				}
			}
			$ends = $ends.append($subtables.len())
		}
		Ok({ data: gpos, common, subtables: $subtables, ends: $ends, digests: LayoutKerning.digests(gpos, $subtables) })
	}

	read_pair : List(U8), U64, U64, U64 -> Try({ value : [Kern({ at : U64, count : U64 }), Sets({ at : U64, coverage : U64, set_count : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 }), Classes({ at : U64, coverage : U64, rows : U64, columns : U64, width : U64, height : U64, format1 : U64, format2 : U64, size1 : U64, size2 : U64 })], steps : U64 }, [Bad(U64)])
	read_pair = |data, at, glyph_count, steps| {
		size = data.len()
		if !Bytes.fits(at, 10, size) {
			Err(Bad(at))
		} else {
			format = Bytes.u16(data, at)
			coverage = at + Bytes.u16(data, at + 2)
			after_coverage = LayoutKerning.check_coverage(data, coverage, steps)?
			format1 = Bytes.u16(data, at + 4)
			format2 = Bytes.u16(data, at + 6)
			size1 = LayoutKerning.value_size(format1)
			size2 = LayoutKerning.value_size(format2)
			if format == 1 {
				set_count = Bytes.u16(data, at + 8)
				if !Bytes.fits(at + 10, 2 * set_count, size) {
					Err(Bad(at))
				} else {
					after = LayoutKerning.check_sets(data, at, coverage, set_count, 2 + size1 + size2, glyph_count, after_coverage)?
					Ok({ value: Sets({ at, coverage, set_count, format1, format2, size1, size2 }), steps: after })
				}
			} else if format == 2 {
				if !Bytes.fits(at, 16, size) {
					Err(Bad(at))
				} else {
					height = Bytes.u16(data, at + 12)
					width = Bytes.u16(data, at + 14)
					if !Bytes.fits(at + 16, (size1 + size2) * width * height, size) {
						Err(Bad(at))
					} else {
						rows = at + Bytes.u16(data, at + 8)
						columns = at + Bytes.u16(data, at + 10)
						after_rows = LayoutKerning.check_classes(data, rows, after_coverage)?
						after = LayoutKerning.check_classes(data, columns, after_rows)?
						Ok({ value: Classes({ at, coverage, rows, columns, width, height, format1, format2, size1, size2 }), steps: after })
					}
				}
			} else {
				Err(Bad(at))
			}
		}
	}

	check_coverage : List(U8), U64, U64 -> Try(U64, [Bad(U64)])
	check_coverage = |data, at, steps| {
		format = Bytes.u16(data, at)
		count = Bytes.u16(data, at + 2)
		if format == 1 and Bytes.fits(at, 4 + 2 * count, data.len()) {
			LayoutKerning.spend(data, steps, count)
		} else if format == 2 and Bytes.fits(at, 4 + 6 * count, data.len()) {
			LayoutKerning.spend(data, steps, count)
		} else {
			Err(Bad(at))
		}
	}

	check_classes : List(U8), U64, U64 -> Try(U64, [Bad(U64)])
	check_classes = |data, at, steps| {
		format = Bytes.u16(data, at)
		if format == 1 and Bytes.fits(at, 6, data.len()) {
			count = Bytes.u16(data, at + 4)
			if (Bytes.fits(at + 6, 2 * count, data.len())) LayoutKerning.spend(data, steps, count) else Err(Bad(at))
		} else if format == 2 and Bytes.fits(at, 4, data.len()) {
			count = Bytes.u16(data, at + 2)
			if (Bytes.fits(at + 4, 6 * count, data.len())) LayoutKerning.spend(data, steps, count) else Err(Bad(at))
		} else {
			Err(Bad(at))
		}
	}

	# Pair format 1: the pair set of every coverage index a query can reach
	# (one whose glyph the font has) lies inside the table. Sets of glyphs
	# past the font are never looked at, so they are not checked.
	check_sets : List(U8), U64, U64, U64, U64, U64, U64 -> Try(U64, [Bad(U64)])
	check_sets = |data, at, coverage, set_count, record, glyph_count, steps| {
		size = data.len()
		count = Bytes.u16(data, coverage + 2)
		var $steps = LayoutKerning.spend(data, steps, set_count)?
		var $ok = True
		if Bytes.u16(data, coverage) == 1 {
			for i in 0..<count {
				if i < set_count and Bytes.u16(data, coverage + 4 + 2 * i) < glyph_count {
					$ok = $ok and LayoutKerning.set_fits(data, at, i, record, size)
				}
			}
		} else {
			for i in 0..<count {
				r = coverage + 4 + 6 * i
				first = Bytes.u16(data, r)
				last = Bytes.u16(data, r + 2)
				index = Bytes.u16(data, r + 4)
				if first <= last and first < glyph_count and index < set_count {
					span = (last.min(glyph_count - 1) - first + 1).min(set_count - index)
					$steps = LayoutKerning.spend(data, $steps, span)?
					for k in 0..<span {
						$ok = $ok and LayoutKerning.set_fits(data, at, index + k, record, size)
					}
				}
			}
		}
		if ($ok) Ok($steps) else Err(Bad(at))
	}

	set_fits : List(U8), U64, U64, U64, U64 -> Bool
	set_fits = |data, at, index, record, size| {
		set = at + Bytes.u16(data, at + 10 + 2 * index)
		Bytes.fits(set, 2 + record * Bytes.u16(data, set), size)
	}

	## A TrueType `kern` table: each horizontal format 0 subtable, in order.
	## Apple's version 1.0 layout of the table is read too, as browsers do.
	## Pairs must be sorted by first and then second glyph, since lookups
	## search them; browsers (through OTS) drop a table whose pairs are not.
	read_kern : List(U8) -> Try(Legacy, [Bad(U64), Unsorted(U64)])
	read_kern = |kern| {
		version = Bytes.u16(kern, 0)
		if version == 1 {
			LayoutKerning.read_apple_kern(kern)
		} else if version != 0 {
			Err(Bad(0))
		} else {
			count = Bytes.u16(kern, 2)
			var $at = 4
			var $subtables = []
			for _ in 0..<count {
				if !Bytes.fits($at, 14, kern.len()) {
					return Err(Bad($at))
				}
				length = Bytes.u16(kern, $at + 2)
				coverage = Bytes.u16(kern, $at + 4)
				pairs = Bytes.u16(kern, $at + 6)
				if coverage == 0x0001 {
					if !Bytes.fits($at + 14, 6 * pairs, kern.len()) {
						return Err(Bad($at))
					}
					LayoutKerning.check_sorted(kern, $at + 14, pairs)?
					$subtables = $subtables.append(Kern({ at: $at + 14, count: pairs }))
				}
				$at = $at + length.max(6)
			}
			Ok({ data: kern, subtables: $subtables, digests: LayoutKerning.digests(kern, $subtables) })
		}
	}

	# Pairs at `at` in strictly increasing order of their first and second
	# glyph; the first pair out of order is the problem.
	check_sorted : List(U8), U64, U64 -> Try({}, [Unsorted(U64)])
	check_sorted = |kern, at, count| {
		var $k = 1
		while $k < count {
			if Bytes.u32(kern, at + 6 * $k) <= Bytes.u32(kern, at + 6 * ($k - 1)) {
				return Err(Unsorted(at + 6 * $k))
			}
			$k = $k + 1
		}
		Ok({})
	}

	# Apple's layout: a 32-bit version and count, and subtables with a 32-bit
	# length and an 8-bit coverage (vertical, cross-stream and variation
	# flags) followed by the format.
	read_apple_kern : List(U8) -> Try(Legacy, [Bad(U64), Unsorted(U64)])
	read_apple_kern = |kern| {
		count = Bytes.u32(kern, 4)
		if Bytes.u16(kern, 2) != 0 or !Bytes.fits(8, 0, kern.len()) {
			Err(Bad(0))
		} else {
			var $at = 8
			var $subtables = []
			var $k = 0
			while $k < count {
				length = Bytes.u32(kern, $at)
				if length < 16 or !Bytes.fits($at, length, kern.len()) {
					return Err(Bad($at))
				}
				coverage = Bytes.u8(kern, $at + 4)
				format = Bytes.u8(kern, $at + 5)
				if coverage.bitwise_and(0xE0) == 0 and format == 0 {
					pairs = Bytes.u16(kern, $at + 8)
					if !Bytes.fits($at + 16, 6 * pairs, kern.len()) {
						return Err(Bad($at))
					}
					LayoutKerning.check_sorted(kern, $at + 16, pairs)?
					$subtables = $subtables.append(Kern({ at: $at + 16, count: pairs }))
				}
				$at = $at + length
				$k = $k + 1
			}
			Ok({ data: kern, subtables: $subtables, digests: LayoutKerning.digests(kern, $subtables) })
		}
	}
}
