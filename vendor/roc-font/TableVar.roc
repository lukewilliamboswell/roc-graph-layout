## Font variations: the design axes a variable font offers and their named
## instances (`fvar`), how the font bends those axes (`avar` version 1), and
## the stored deltas that move a value between masters (the
## `ItemVariationStore` with its `VariationRegionList` and
## `ItemVariationData` subtables, and the `DeltaSetIndexMap`), with the two
## tables built only from them: advance-width variations (`HVAR`) and
## font-wide metric variations (`MVAR`).
##
## Internal. Reading validates every offset, count and index once, before
## anything sized by the data is allocated, and reports every independent
## problem. After a successful read every query here is total.
##
## Numbers follow HarfBuzz bit for bit. HarfBuzz normalises coordinates and
## sums deltas in IEEE 754 single precision, and its results differ from
## exact arithmetic near rounding ties (`docs/variable-fonts.adoc`), so this
## module evaluates the same operations in the same order on single-precision
## bit patterns held in `U32`, with integer arithmetic only. Every value
## stays finite: inputs are bounded by the table formats and no operation
## here can overflow single precision.
TableVar := {
	# fvar, one entry per axis. Axis values are Fixed 16.16.
	tags : List(U32),
	minimum : List(I32),
	default : List(I32),
	maximum : List(I32),
	flags : List(U16),
	axis_names : List(U16),
	# fvar, one entry per named instance; coordinates of instance i on axis
	# a at i * axis count + a. A PostScript name id of 0xFFFF means none.
	instance_names : List(U16),
	instance_postscript : List(U16),
	instance_coords : List(I32),
	# avar: the segment map of axis a is entries map_starts[a] up to
	# map_starts[a + 1] of map_from and map_to (F2Dot14). Empty without avar.
	map_starts : List(U64),
	map_from : List(I16),
	map_to : List(I16),
}.{

	## What was wrong, where. `offset` is from the start of `table`.
	Problem : { table : Str, offset : U64, reason : Reason }

	Reason : [
		Truncated,
		UnsupportedVersion,
		BadFormat,
		BadRecordSize,
		TooManyAxes,
		AxisOrder,
		AxisCountMismatch,
		MapMissingIdentity,
		MapOrder,
		MapRange,
		TooManyRegions,
		RegionIndex,
		WordCount,
		DeltaIndex,
		ItemCount,
		TagOrder,
	]

	## An `ItemVariationStore` inside a checked table. Region r's axis a has
	## its start, peak and end (F2Dot14) at 3 * (r * axis_count + a). The
	## `ItemVariationData` subtable d has `item_counts[d]` rows of
	## `row_sizes[d]` bytes from `row_starts[d]` in `bytes`; its columns use
	## the regions `region_indexes[index_starts[d]]` up to
	## `index_starts[d + 1]`, the first `word_counts[d]` of them stored as
	## 16-bit deltas (32-bit when `long_words[d]`), the rest as 8-bit (16-bit).
	Store : {
		axis_count : U64,
		region_count : U64,
		regions : List(I16),
		item_counts : List(U64),
		word_counts : List(U64),
		long_words : List(Bool),
		index_starts : List(U64),
		region_indexes : List(U64),
		row_starts : List(U64),
		row_sizes : List(U64),
		bytes : List(U8),
	}

	## A `DeltaSetIndexMap`: entry i (the last entry for any i past the end)
	## is `entry_size` bytes at `start + i * entry_size` in `bytes`, holding
	## an outer index above `inner_bits` bits of inner index.
	DeltaMap : { start : U64, count : U64, entry_size : U64, inner_bits : U8, bytes : List(U8) }

	## `HVAR`: advance deltas by glyph, through a map, or with no map the
	## glyph id as the row of the first `ItemVariationData` (`Implicit`).
	Hvar : { store : Store, advances : [Implicit, Mapped(DeltaMap)] }

	## `MVAR`: per metric tag (sorted), the delta-set index of its delta.
	Mvar : { store : Store, tags : List(U32), outer : List(U64), inner : List(U64) }

	# ------------------------------------------------------------ limits

	## Axes accepted in `fvar`. The OpenType format allows 65535; real fonts
	## use fewer than 20. A provisional limit until `Font.Limits` carries it.
	axis_limit : U64
	axis_limit = 64

	## The specification's bound on `VariationRegionList.regionCount`.
	region_limit : U64
	region_limit = 32767

	## A delta-set index meaning "no variation".
	no_variation : U64
	no_variation = 0xFFFF

	# ------------------------------------------------------------ fvar and avar

	## Read `fvar` and, when present, `avar`. Every independent problem in
	## both is reported.
	read : List(U8), [Present(List(U8)), Absent] -> Try(TableVar, List(Problem))
	read = |fvar, avar|
		match TableVar.read_fvar(fvar) {
			Err(problems) =>
				match avar {
					Present(bytes) if bytes.len() >= 8 and TableVar.u16(bytes, 0) != 1 => Err(problems.append({ table: "avar", offset: 0, reason: UnsupportedVersion }))
					_ => Err(problems)
				}
			Ok(axes) =>
				match avar {
					Absent => Ok(axes)
					Present(bytes) =>
						match TableVar.read_avar(bytes, axes.tags.len()) {
							Err(problems) => Err(problems)
							Ok(maps) => Ok({ tags: axes.tags, minimum: axes.minimum, default: axes.default, maximum: axes.maximum, flags: axes.flags, axis_names: axes.axis_names, instance_names: axes.instance_names, instance_postscript: axes.instance_postscript, instance_coords: axes.instance_coords, map_starts: maps.starts, map_from: maps.from, map_to: maps.to })
						}
				}
		}

	read_fvar : List(U8) -> Try(TableVar, List(Problem))
	read_fvar = |bytes| {
		bad = |offset, reason| Err([{ table: "fvar", offset, reason }])
		size = bytes.len()
		if size < 16 {
			return bad(0, Truncated)
		}
		if TableVar.u16(bytes, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		axes_at = TableVar.u16(bytes, 4)
		count = TableVar.u16(bytes, 8)
		axis_size = TableVar.u16(bytes, 10)
		instance_count = TableVar.u16(bytes, 12)
		instance_size = TableVar.u16(bytes, 14)
		if axis_size != 20 {
			return bad(10, BadRecordSize)
		}
		if instance_size != 4 * count + 4 and instance_size != 4 * count + 6 {
			return bad(14, BadRecordSize)
		}
		if count > TableVar.axis_limit {
			return bad(8, TooManyAxes)
		}
		instances_at = axes_at + 20 * count
		if !TableVar.fits(axes_at, 20 * count, size) {
			return bad(axes_at, Truncated)
		}
		if !TableVar.fits(instances_at, instance_count * instance_size, size) {
			return bad(instances_at, Truncated)
		}
		var $tags = List.with_capacity(count)
		var $minimum = List.with_capacity(count)
		var $default = List.with_capacity(count)
		var $maximum = List.with_capacity(count)
		var $flags = List.with_capacity(count)
		var $names = List.with_capacity(count)
		var $problems = []
		for a in 0..<count {
			at = axes_at + 20 * a
			low = TableVar.i32(bytes, at + 4)
			middle = TableVar.i32(bytes, at + 8)
			high = TableVar.i32(bytes, at + 12)
			if low > middle or middle > high {
				$problems = $problems.append({ table: "fvar", offset: at, reason: AxisOrder })
			}
			$tags = $tags.append(TableVar.u32(bytes, at).to_u32_wrap())
			$minimum = $minimum.append(low.to_i32_wrap())
			$default = $default.append(middle.to_i32_wrap())
			$maximum = $maximum.append(high.to_i32_wrap())
			$flags = $flags.append(TableVar.u16(bytes, at + 16).to_u16_wrap())
			$names = $names.append(TableVar.u16(bytes, at + 18).to_u16_wrap())
		}
		has_postscript = instance_size == 4 * count + 6
		var $instance_names = List.with_capacity(instance_count)
		var $postscript = List.with_capacity(instance_count)
		var $coords = List.with_capacity(instance_count * count)
		for i in 0..<instance_count {
			at = instances_at + i * instance_size
			$instance_names = $instance_names.append(TableVar.u16(bytes, at).to_u16_wrap())
			for a in 0..<count {
				$coords = $coords.append(TableVar.i32(bytes, at + 4 + 4 * a).to_i32_wrap())
			}
			ps = if (has_postscript) TableVar.u16(bytes, at + 4 + 4 * count) else 0xFFFF
			$postscript = $postscript.append(ps.to_u16_wrap())
		}
		if !$problems.is_empty() {
			return Err($problems)
		}
		Ok({
			tags: $tags,
			minimum: $minimum,
			default: $default,
			maximum: $maximum,
			flags: $flags,
			axis_names: $names,
			instance_names: $instance_names,
			instance_postscript: $postscript,
			instance_coords: $coords,
			map_starts: [],
			map_from: [],
			map_to: [],
		})
	}

	# An avar version 1 segment map per axis. A map is empty (identity) or
	# holds -1 -> -1, 0 -> 0 and 1 -> 1, with source coordinates strictly
	# increasing, targets never decreasing, and every value in [-1, 1].
	read_avar : List(U8), U64 -> Try({ starts : List(U64), from : List(I16), to : List(I16) }, List(Problem))
	read_avar = |bytes, axis_count| {
		bad = |offset, reason| Err([{ table: "avar", offset, reason }])
		size = bytes.len()
		if size < 8 {
			return bad(0, Truncated)
		}
		if TableVar.u16(bytes, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		if TableVar.u16(bytes, 6) != axis_count {
			return bad(6, AxisCountMismatch)
		}
		# Each map is at least 2 bytes, so the axis count bounds the walk.
		var $at = 8
		var $starts = List.with_capacity(axis_count + 1)
		var $from = []
		var $to = []
		var $problems = []
		for _a in 0..<axis_count {
			$starts = $starts.append($from.len())
			if !TableVar.fits($at, 2, size) {
				return Err($problems.append({ table: "avar", offset: $at, reason: Truncated }))
			}
			count = TableVar.u16(bytes, $at)
			if !TableVar.fits($at + 2, 4 * count, size) {
				return Err($problems.append({ table: "avar", offset: $at, reason: Truncated }))
			}
			map_at = $at
			var $ok = True
			var $seen = 0
			var $previous_from = -0x8000
			var $previous_to = -0x8000
			for k in 0..<count {
				from = TableVar.i16(bytes, map_at + 2 + 4 * k)
				to = TableVar.i16(bytes, map_at + 4 + 4 * k)
				if from < -0x4000 or from > 0x4000 or to < -0x4000 or to > 0x4000 {
					if $ok {
						$problems = $problems.append({ table: "avar", offset: map_at + 2 + 4 * k, reason: MapRange })
					}
					$ok = False
				} else if k > 0 and (from <= $previous_from or to < $previous_to) {
					if $ok {
						$problems = $problems.append({ table: "avar", offset: map_at + 2 + 4 * k, reason: MapOrder })
					}
					$ok = False
				}
				if (from == -0x4000 and to == -0x4000) or (from == 0 and to == 0) or (from == 0x4000 and to == 0x4000) {
					$seen = $seen + 1
				}
				$previous_from = from
				$previous_to = to
				$from = $from.append(from.to_i16_wrap())
				$to = $to.append(to.to_i16_wrap())
			}
			if $ok and count > 0 and $seen != 3 {
				$problems = $problems.append({ table: "avar", offset: map_at, reason: MapMissingIdentity })
			}
			$at = map_at + 2 + 4 * count
		}
		$starts = $starts.append($from.len())
		if ($problems.is_empty()) Ok({ starts: $starts, from: $from, to: $to }) else Err($problems)
	}

	axis_total : TableVar -> U64
	axis_total = |tv| tv.tags.len()

	instance_total : TableVar -> U64
	instance_total = |tv| tv.instance_names.len()

	# ------------------------------------------------------------ coordinates

	## Normalised coordinates (F2Dot14, one per axis) for design-space values
	## given per axis tag. A tag the font lacks is ignored; an axis not given
	## takes its default; a later value for the same tag wins. Values are
	## `Dec`, rounded to the nearest single-precision value as HarfBuzz
	## receives a `float`.
	coords_for : TableVar, List({ tag : U32, value : Dec }) -> List(I16)
	coords_for = |tv, settings| {
		count = tv.tags.len()
		var $design = List.with_capacity(count)
		for a in 0..<count {
			$design = $design.append(TableVar.f32_from_fixed((tv.default.get(a) ?? 0).to_i64()))
		}
		for setting in settings {
			match TableVar.find_axis(tv.tags, setting.tag) {
				Ok(a) => {
					# `find_axis` returns an index below the axis count.
					$design = $design.set(a, TableVar.f32_from_ratio(Dec.to_attos(setting.value), 1_000_000_000_000_000_000)) ?? []
				}
				Err(_) => {}
			}
		}
		TableVar.coords_from_design(tv, $design)
	}

	## Normalised coordinates of named instance `index`, or the default
	## location (all zero) for an index past the instances.
	coords_of_instance : TableVar, U64 -> List(I16)
	coords_of_instance = |tv, index| {
		count = tv.tags.len()
		if index >= tv.instance_names.len() {
			return List.repeat(0, count)
		}
		var $design = List.with_capacity(count)
		for a in 0..<count {
			$design = $design.append(TableVar.f32_from_fixed((tv.instance_coords.get(index * count + a) ?? 0).to_i64()))
		}
		TableVar.coords_from_design(tv, $design)
	}

	find_axis : List(U32), U32 -> Try(U64, [Missing])
	find_axis = |tags, tag| {
		var $i = 0
		while $i < tags.len() {
			if (tags.get($i) ?? 0) == tag {
				return Ok($i)
			}
			$i = $i + 1
		}
		Err(Missing)
	}

	## Normalised coordinates for single-precision design values, one per
	## axis (a missing value is the default). This is HarfBuzz's
	## `hb_ot_var_normalize_coords`: clamp to the axis range, normalise to
	## 16.16, bend by `avar`, round to 16.16, then to F2Dot14 rounding half up.
	coords_from_design : TableVar, List(U32) -> List(I16)
	coords_from_design = |tv, design| {
		count = tv.tags.len()
		var $out = List.with_capacity(count)
		for a in 0..<count {
			low = TableVar.f32_from_fixed((tv.minimum.get(a) ?? 0).to_i64())
			middle = TableVar.f32_from_fixed((tv.default.get(a) ?? 0).to_i64())
			high = TableVar.f32_from_fixed((tv.maximum.get(a) ?? 0).to_i64())
			v = design.get(a) ?? middle
			n16 = TableVar.normalize_16(v, low, middle, high)
			mapped = TableVar.avar_16(tv, a, n16)
			$out = $out.append((mapped + 2).shr_wrap(2).to_i16_wrap())
		}
		$out
	}

	# HarfBuzz's `fvar` axis normalisation, in single precision, to 16.16.
	normalize_16 : U32, U32, U32, U32 -> I64
	normalize_16 = |value, low_raw, middle, high_raw| {
		low = TableVar.f32_min(middle, low_raw)
		high = TableVar.f32_max(middle, high_raw)
		v = TableVar.f32_min(TableVar.f32_max(value, low), high)
		if TableVar.f32_eq(v, middle) {
			0
		} else {
			span = if (TableVar.f32_lt(v, middle)) TableVar.f32_sub(middle, low) else TableVar.f32_sub(high, middle)
			x = TableVar.f32_div(TableVar.f32_sub(v, middle), span)
			TableVar.f32_round_half_up(TableVar.f32_mul(x, TableVar.f32_65536))
		}
	}

	# HarfBuzz's `avar` segment map lookup for a validated map, in single
	# precision, from 16.16 to 16.16.
	avar_16 : TableVar, U64, I64 -> I64
	avar_16 = |tv, axis, n16| {
		start = tv.map_starts.get(axis) ?? 0
		end = tv.map_starts.get(axis + 1) ?? 0
		if end <= start {
			return n16
		}
		value = TableVar.f32_from_ratio(n16.to_i128(), 65536)
		from = |k| TableVar.f32_from_ratio((tv.map_from.get(k) ?? 0).to_i128(), 16384)
		to = |k| TableVar.f32_from_ratio((tv.map_to.get(k) ?? 0).to_i128(), 16384)
		# Find the first entry at or above the value. A validated map starts
		# at -1 and ends at 1, and the value lies in [-1, 1].
		var $k = start
		while $k < end and TableVar.f32_lt(from($k), value) {
			$k = $k + 1
		}
		mapped =
			if $k < end and TableVar.f32_eq(from($k), value) {
				to($k)
			} else if $k == start or $k == end {
				# Unreachable for a validated map; HarfBuzz shifts.
				edge = if ($k == start) start else end - 1
				TableVar.f32_add(TableVar.f32_sub(value, from(edge)), to(edge))
			} else {
				before_from = from($k - 1)
				before_to = to($k - 1)
				denom = TableVar.f32_sub(from($k), before_from)
				rise = TableVar.f32_mul(TableVar.f32_sub(to($k), before_to), TableVar.f32_sub(value, before_from))
				TableVar.f32_add(before_to, TableVar.f32_div(rise, denom))
			}
		TableVar.f32_round_half_up(TableVar.f32_mul(mapped, TableVar.f32_65536))
	}

	# ------------------------------------------------------------ item variation store

	## Read the `ItemVariationStore` at `offset` in `table`'s bytes, for a
	## font with `axis_count` axes.
	read_store : List(U8), Str, U64, U64 -> Try(Store, List(Problem))
	read_store = |bytes, table, offset, axis_count| {
		bad = |at, reason| Err([{ table, offset: at, reason }])
		size = bytes.len()
		if !TableVar.fits(offset, 8, size) {
			return bad(offset, Truncated)
		}
		if TableVar.u16(bytes, offset) != 1 {
			return bad(offset, BadFormat)
		}
		list_at = offset + TableVar.u32(bytes, offset + 2)
		data_count = TableVar.u16(bytes, offset + 6)
		if !TableVar.fits(offset + 8, 4 * data_count, size) {
			return bad(offset + 8, Truncated)
		}
		if !TableVar.fits(list_at, 4, size) {
			return bad(offset + 2, Truncated)
		}
		if TableVar.u16(bytes, list_at) != axis_count {
			return bad(list_at, AxisCountMismatch)
		}
		region_count = TableVar.u16(bytes, list_at + 2)
		if region_count > TableVar.region_limit {
			return bad(list_at + 2, TooManyRegions)
		}
		if !TableVar.fits(list_at + 4, 6 * axis_count * region_count, size) {
			return bad(list_at + 4, Truncated)
		}
		var $regions = List.with_capacity(3 * axis_count * region_count)
		for i in 0..<(3 * axis_count * region_count) {
			$regions = $regions.append(TableVar.i16(bytes, list_at + 4 + 2 * i).to_i16_wrap())
		}
		var $problems = []
		var $item_counts = List.with_capacity(data_count)
		var $word_counts = List.with_capacity(data_count)
		var $long_words = List.with_capacity(data_count)
		var $index_starts = List.with_capacity(data_count + 1)
		var $region_indexes = []
		var $row_starts = List.with_capacity(data_count)
		var $row_sizes = List.with_capacity(data_count)
		for d in 0..<data_count {
			$index_starts = $index_starts.append($region_indexes.len())
			relative = TableVar.u32(bytes, offset + 8 + 4 * d)
			at = offset + relative
			var $items = 0
			var $words = 0
			var $long = False
			var $row = 0
			var $rows_at = 0
			if relative == 0 {
				# A null offset: a subtable with no rows, which no valid
				# delta-set index can reach.
				{}
			} else if !TableVar.fits(at, 6, size) {
				$problems = $problems.append({ table, offset: offset + 8 + 4 * d, reason: Truncated })
			} else {
				items = TableVar.u16(bytes, at)
				word_field = TableVar.u16(bytes, at + 2)
				columns = TableVar.u16(bytes, at + 4)
				words = word_field.bitwise_and(0x7FFF)
				long = word_field.bitwise_and(0x8000) != 0
				# Only used once `words <= columns` is checked.
				narrow = columns - words.min(columns)
				row = if (long) 4 * words + 2 * narrow else 2 * words + narrow
				if words > columns {
					$problems = $problems.append({ table, offset: at + 2, reason: WordCount })
				} else if !TableVar.fits(at + 6, 2 * columns, size) {
					$problems = $problems.append({ table, offset: at + 4, reason: Truncated })
				} else if !TableVar.fits(at + 6 + 2 * columns, items * row, size) {
					$problems = $problems.append({ table, offset: at, reason: Truncated })
				} else {
					var $bad_region = False
					for c in 0..<columns {
						r = TableVar.u16(bytes, at + 6 + 2 * c)
						if r >= region_count and !$bad_region {
							$problems = $problems.append({ table, offset: at + 6 + 2 * c, reason: RegionIndex })
							$bad_region = True
						}
						$region_indexes = $region_indexes.append(r)
					}
					$items = items
					$words = words
					$long = long
					$row = row
					$rows_at = at + 6 + 2 * columns
				}
			}
			$item_counts = $item_counts.append($items)
			$word_counts = $word_counts.append($words)
			$long_words = $long_words.append($long)
			$row_sizes = $row_sizes.append($row)
			$row_starts = $row_starts.append($rows_at)
		}
		$index_starts = $index_starts.append($region_indexes.len())
		if !$problems.is_empty() {
			return Err($problems)
		}
		Ok({
			axis_count,
			region_count,
			regions: $regions,
			item_counts: $item_counts,
			word_counts: $word_counts,
			long_words: $long_words,
			index_starts: $index_starts,
			region_indexes: $region_indexes,
			row_starts: $row_starts,
			row_sizes: $row_sizes,
			bytes,
		})
	}

	## Whether a delta-set index names a row of the store, or is
	## `no_variation` in both halves.
	valid_index : Store, U64, U64 -> Bool
	valid_index = |store, outer, inner|
		(outer == TableVar.no_variation and inner == TableVar.no_variation) or inner < (store.item_counts.get(outer) ?? 0)

	## The scalar of every region of a store at normalised coordinates, as
	## HarfBuzz's region cache holds it. Computed once per location.
	region_scalars : Store, List(I16) -> List(U32)
	region_scalars = |store, coords| {
		axes = store.axis_count
		var $out = List.with_capacity(store.region_count)
		for r in 0..<store.region_count {
			var $v = TableVar.f32_one
			var $a = 0
			while $a < axes {
				base = 3 * (r * axes + $a)
				factor = TableVar.axis_scalar(
					(coords.get($a) ?? 0).to_i64(),
					(store.regions.get(base) ?? 0).to_i64(),
					(store.regions.get(base + 1) ?? 0).to_i64(),
					(store.regions.get(base + 2) ?? 0).to_i64(),
				)
				if factor == 0 {
					$v = 0
					$a = axes
				} else {
					$v = TableVar.f32_mul($v, factor)
					$a = $a + 1
				}
			}
			$out = $out.append(TableVar.cache_scalar($v))
		}
		$out
	}

	# One axis's contribution to a region's scalar. The order of the tests is
	# the specification's, which gives malformed axes (start after peak, peak
	# after end, or a range across zero) a scalar of 1. The interpolation is
	# HarfBuzz's single-precision division.
	axis_scalar : I64, I64, I64, I64 -> U32
	axis_scalar = |coord, start, peak, end|
		if start > peak or peak > end {
			TableVar.f32_one
		} else if start < 0 and end > 0 and peak != 0 {
			TableVar.f32_one
		} else if peak == 0 or coord == peak {
			TableVar.f32_one
		} else if coord <= start or coord >= end {
			0
		} else if coord < peak {
			TableVar.f32_div(TableVar.f32_from_int(coord - start), TableVar.f32_from_int(peak - start))
		} else {
			TableVar.f32_div(TableVar.f32_from_int(end - coord), TableVar.f32_from_int(end - peak))
		}

	# HarfBuzz keeps a computed scalar as round(v * 2^30) in an int and
	# reads it back as that int times 2^-30. Scalars of 2^-7 and above are
	# unchanged; smaller ones lose bits below 2^-30.
	cache_scalar : U32 -> U32
	cache_scalar = |v| {
		q = TableVar.f32_round_half_up(TableVar.f32_mul(v, TableVar.f32_two_30))
		if (q == 0) 0 else TableVar.f32_mul(TableVar.f32_from_int(q), TableVar.f32_two_minus_30)
	}

	## The delta of row `inner` of subtable `outer`, as HarfBuzz sums it in
	## single precision, given the store's `scalars` at a location. An index
	## outside the store (only `no_variation` after validation) has none.
	delta : Store, List(U32), U64, U64 -> U32
	delta = |store, scalars, outer, inner| {
		items = store.item_counts.get(outer) ?? 0
		if inner >= items {
			return 0
		}
		first = store.index_starts.get(outer) ?? 0
		columns = (store.index_starts.get(outer + 1) ?? 0) - first
		words = store.word_counts.get(outer) ?? 0
		long = store.long_words.get(outer) ?? False
		row = (store.row_starts.get(outer) ?? 0) + inner * (store.row_sizes.get(outer) ?? 0)
		bytes = store.bytes
		var $sum = 0
		for c in 0..<columns {
			scalar = scalars.get(store.region_indexes.get(first + c) ?? 0) ?? 0
			if scalar != 0 {
				d =
					if long {
						if (c < words) TableVar.i32(bytes, row + 4 * c) else TableVar.i16(bytes, row + 4 * words + 2 * (c - words))
					} else if c < words {
						TableVar.i16(bytes, row + 2 * c)
					} else {
						TableVar.i8(bytes, row + 2 * words + (c - words))
					}
				$sum = TableVar.f32_add($sum, TableVar.f32_mul(scalar, TableVar.f32_from_int(d)))
			}
		}
		$sum
	}

	# ------------------------------------------------------------ delta-set index maps

	## Read the `DeltaSetIndexMap` at `offset` in `table`'s bytes, checking
	## that every entry names a row of `store` or is `no_variation`.
	read_delta_map : List(U8), Str, U64, Store -> Try(DeltaMap, List(Problem))
	read_delta_map = |bytes, table, offset, store| {
		bad = |at, reason| Err([{ table, offset: at, reason }])
		size = bytes.len()
		if !TableVar.fits(offset, 4, size) {
			return bad(offset, Truncated)
		}
		format = TableVar.u8(bytes, offset)
		entry_format = TableVar.u8(bytes, offset + 1)
		header =
			if format == 0 {
				Ok({ count: TableVar.u16(bytes, offset + 2), start: offset + 4 })
			} else if format == 1 and TableVar.fits(offset, 6, size) {
				Ok({ count: TableVar.u32(bytes, offset + 2), start: offset + 6 })
			} else if format == 1 {
				Err(Truncated)
			} else {
				Err(BadFormat)
			}
		match header {
			Err(reason) => bad(offset, reason)
			Ok({ count, start }) => {
				entry_size = entry_format.shr_zf_wrap(4).bitwise_and(3) + 1
				inner_bits = (entry_format.bitwise_and(0xF) + 1).to_u8_wrap()
				if count == 0 {
					return bad(offset, ItemCount)
				}
				if !TableVar.fits(start, count * entry_size, size) {
					return bad(start, Truncated)
				}
				map = { start, count, entry_size, inner_bits, bytes }
				var $i = 0
				while $i < count {
					index = TableVar.map_entry(map, $i)
					if !TableVar.valid_index(store, index.outer, index.inner) {
						return bad(start + $i * entry_size, DeltaIndex)
					}
					$i = $i + 1
				}
				Ok(map)
			}
		}
	}

	## The delta-set index for `i`: entry `i`, or the last entry past the end.
	map_entry : DeltaMap, U64 -> { outer : U64, inner : U64 }
	map_entry = |map, i| {
		at = map.start + map.entry_size * i.min(map.count - 1)
		var $u = 0
		for k in 0..<map.entry_size {
			$u = $u * 256 + TableVar.u8(map.bytes, at + k)
		}
		{ outer: $u.shr_zf_wrap(map.inner_bits), inner: $u.bitwise_and(TableVar.low_mask(map.inner_bits)) }
	}

	low_mask : U8 -> U64
	low_mask = |bits| (1.U64).shl_wrap(bits) - 1

	# ------------------------------------------------------------ HVAR and MVAR

	## Read `HVAR` for a font with `axis_count` axes and `glyph_count`
	## glyphs. Left and right side-bearing maps are not read.
	read_hvar : List(U8), U64, U64 -> Try(Hvar, List(Problem))
	read_hvar = |bytes, axis_count, glyph_count| {
		bad = |at, reason| Err([{ table: "HVAR", offset: at, reason }])
		if bytes.len() < 20 {
			return bad(0, Truncated)
		}
		if TableVar.u16(bytes, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		store_at = TableVar.u32(bytes, 4)
		map_at = TableVar.u32(bytes, 8)
		if store_at == 0 {
			return bad(4, Truncated)
		}
		store = TableVar.read_store(bytes, "HVAR", store_at, axis_count)?
		if map_at == 0 {
			# The glyph id is the row of the first subtable, which must have
			# a row for every glyph.
			if (store.item_counts.get(0) ?? 0) < glyph_count {
				bad(store_at, ItemCount)
			} else {
				Ok({ store, advances: Implicit })
			}
		} else {
			map = TableVar.read_delta_map(bytes, "HVAR", map_at, store)?
			Ok({ store, advances: Mapped(map) })
		}
	}

	## The change to a glyph's advance at a location, rounded as HarfBuzz
	## adds it to the `hmtx` advance (half up). A glyph past the font has none.
	advance_delta : Hvar, List(U32), U64 -> I64
	advance_delta = |hvar, scalars, glyph| {
		index =
			match hvar.advances {
				Implicit => { outer: 0, inner: glyph }
				Mapped(map) => TableVar.map_entry(map, glyph)
			}
		TableVar.f32_round_half_up(TableVar.delta(hvar.store, scalars, index.outer, index.inner))
	}

	## A glyph's advance at a location: the default advance plus its rounded
	## delta, never below zero (as HarfBuzz; `hmtx` advances are unsigned).
	advance : Hvar, List(U32), U64, I64 -> I64
	advance = |hvar, scalars, glyph, default_advance|
		(default_advance + TableVar.advance_delta(hvar, scalars, glyph)).max(0)

	## Read `MVAR` for a font with `axis_count` axes.
	read_mvar : List(U8), U64 -> Try(Mvar, List(Problem))
	read_mvar = |bytes, axis_count| {
		bad = |at, reason| Err([{ table: "MVAR", offset: at, reason }])
		size = bytes.len()
		if size < 12 {
			return bad(0, Truncated)
		}
		if TableVar.u16(bytes, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		record_size = TableVar.u16(bytes, 6)
		count = TableVar.u16(bytes, 8)
		store_at = TableVar.u16(bytes, 10)
		if record_size < 8 {
			return bad(6, BadRecordSize)
		}
		if !TableVar.fits(12, count * record_size, size) {
			return bad(12, Truncated)
		}
		empty_store = { axis_count, region_count: 0, regions: [], item_counts: [], word_counts: [], long_words: [], index_starts: [0], region_indexes: [], row_starts: [], row_sizes: [], bytes: [] }
		store =
			if store_at == 0 and count == 0 {
				empty_store
			} else if store_at == 0 {
				return bad(10, Truncated)
			} else {
				TableVar.read_store(bytes, "MVAR", store_at, axis_count)?
			}
		var $tags = List.with_capacity(count)
		var $outer = List.with_capacity(count)
		var $inner = List.with_capacity(count)
		var $problems = []
		for i in 0..<count {
			at = 12 + i * record_size
			tag = TableVar.u32(bytes, at)
			o = TableVar.u16(bytes, at + 4)
			n = TableVar.u16(bytes, at + 6)
			if i > 0 and tag <= (($tags.last() ?? 0).to_u64()) {
				$problems = $problems.append({ table: "MVAR", offset: at, reason: TagOrder })
			}
			if !TableVar.valid_index(store, o, n) {
				$problems = $problems.append({ table: "MVAR", offset: at + 4, reason: DeltaIndex })
			}
			$tags = $tags.append(tag.to_u32_wrap())
			$outer = $outer.append(o)
			$inner = $inner.append(n)
		}
		if ($problems.is_empty()) Ok({ store, tags: $tags, outer: $outer, inner: $inner }) else Err($problems)
	}

	## The delta of a metric (an `MVAR` tag such as `xhgt`) at a location,
	## unrounded: HarfBuzz rounds the default value plus this delta.
	metric_delta : Mvar, List(U32), U32 -> U32
	metric_delta = |mvar, scalars, tag| {
		var $low = 0
		var $high = mvar.tags.len()
		while $low < $high {
			mid = ($low + $high) // 2
			probe = mvar.tags.get(mid) ?? 0
			if tag < probe {
				$high = mid
			} else if tag > probe {
				$low = mid + 1
			} else {
				return TableVar.delta(mvar.store, scalars, mvar.outer.get(mid) ?? 0, mvar.inner.get(mid) ?? 0)
			}
		}
		0
	}

	## A metric at a location: `round(value + delta)` in single precision,
	## half up, as HarfBuzz computes it.
	metric : Mvar, List(U32), U32, I64 -> I64
	metric = |mvar, scalars, tag, value|
		TableVar.f32_round_half_up(TableVar.f32_add(TableVar.f32_from_int(value), TableVar.metric_delta(mvar, scalars, tag)))

	# ------------------------------------------------------------ single precision

	# IEEE 754 binary32 on bit patterns, rounding to nearest with ties to
	# even, with subnormals. Only finite values occur. A value unpacks to
	# sig * 2^exp with an integer significand.

	f32_one : U32
	f32_one = 0x3F800000

	f32_half : U32
	f32_half = 0x3F000000

	f32_65536 : U32
	f32_65536 = 0x47800000

	f32_two_30 : U32
	f32_two_30 = 0x4E800000

	f32_two_minus_30 : U32
	f32_two_minus_30 = 0x30800000

	f32_negative : U32 -> Bool
	f32_negative = |x| x.bitwise_and(0x80000000) != 0

	f32_sig : U32 -> U128
	f32_sig = |x| {
		field = x.shr_zf_wrap(23).bitwise_and(0xFF)
		fraction = x.bitwise_and(0x7FFFFF).to_u128()
		if (field == 0) fraction else fraction.bitwise_or(0x800000)
	}

	f32_exp : U32 -> I64
	f32_exp = |x| {
		field = x.shr_zf_wrap(23).bitwise_and(0xFF).to_i64()
		if (field == 0) -149 else field - 150
	}

	bit_length : U128 -> I64
	bit_length = |x| 128 - x.count_leading_zero_bits().to_i64()

	# Round sig * 2^exp to the nearest single-precision value. The lowest bit
	# of sig may stand for any nonzero remainder below it (a sticky bit), as
	# long as sig has at least two bits below the rounding position; the
	# widening below guarantees that.
	f32_pack : Bool, U128, I64 -> U32
	f32_pack = |negative, sig_in, exp_in| {
		sign = if (negative) 0x80000000 else 0
		if sig_in == 0 {
			return sign
		}
		n_in = TableVar.bit_length(sig_in)
		widen = if (n_in < 64) 64 - n_in else 0
		sig = sig_in.shl_wrap(widen.to_u8_wrap())
		exp = exp_in - widen
		n = n_in + widen
		top = exp + n - 1
		drop = if (top >= -126) n - 24 else -149 - exp
		if drop > n {
			return sign
		}
		kept = if (drop >= 128) 0 else sig.shr_zf_wrap(drop.to_u8_wrap())
		rest = sig - kept.shl_wrap(drop.to_u8_wrap())
		half = (1).shl_wrap((drop - 1).to_u8_wrap())
		rounded = if (rest > half or (rest == half and kept.bitwise_and(1) == 1)) kept + 1 else kept
		if top >= -126 {
			# A normal result: 24 significant bits, or 25 after rounding up.
			carry = rounded == 0x1000000
			m = if (carry) 0x800000 else rounded
			e = if (carry) top + 1 else top
			if e > 127 {
				sign.bitwise_or(0x7F800000)
			} else {
				sign.bitwise_or((e + 127).to_u32_wrap().shl_wrap(23)).bitwise_or((m - 0x800000).to_u32_wrap())
			}
		} else {
			# A subnormal result; rounding up to 2^23 gives the smallest
			# normal value, whose bit pattern is the same.
			sign.bitwise_or(rounded.to_u32_wrap())
		}
	}

	f32_from_int : I64 -> U32
	f32_from_int = |n|
		if (n < 0) TableVar.f32_pack(True, (0 - n.to_i128()).to_u128_wrap(), 0) else TableVar.f32_pack(False, n.to_u128_wrap(), 0)

	## The single-precision value nearest num / den, for 0 < den <= 2^64.
	f32_from_ratio : I128, U128 -> U32
	f32_from_ratio = |num, den| {
		negative = num < 0
		mag = if (negative) (0 - num).to_u128_wrap() else num.to_u128_wrap()
		if mag == 0 or den == 0 {
			return 0
		}
		length = TableVar.bit_length(mag)
		shift = if (length < 100) 100 - length else 0
		scaled = mag.shl_wrap(shift.to_u8_wrap())
		q = scaled // den
		r = scaled - q * den
		sticky = if (r != 0) 1 else 0
		TableVar.f32_pack(negative, q * 2 + sticky, 0 - shift - 1)
	}

	## A Fixed 16.16 value as HarfBuzz converts it: the integer rounded to
	## single precision, times 2^-16.
	f32_from_fixed : I64 -> U32
	f32_from_fixed = |raw| TableVar.f32_from_ratio(raw.to_i128(), 65536)

	f32_mul : U32, U32 -> U32
	f32_mul = |a, b| {
		negative = TableVar.f32_negative(a) != TableVar.f32_negative(b)
		sa = TableVar.f32_sig(a)
		sb = TableVar.f32_sig(b)
		if sa == 0 or sb == 0 {
			if (negative) 0x80000000 else 0
		} else {
			TableVar.f32_pack(negative, sa * sb, TableVar.f32_exp(a) + TableVar.f32_exp(b))
		}
	}

	## a / b for b not zero.
	f32_div : U32, U32 -> U32
	f32_div = |a, b| {
		negative = TableVar.f32_negative(a) != TableVar.f32_negative(b)
		sa = TableVar.f32_sig(a)
		sb = TableVar.f32_sig(b)
		if sa == 0 or sb == 0 {
			if (negative) 0x80000000 else 0
		} else {
			scaled = sa.shl_wrap(80)
			q = scaled // sb
			r = scaled - q * sb
			sticky = if (r != 0) 1 else 0
			TableVar.f32_pack(negative, q * 2 + sticky, TableVar.f32_exp(a) - TableVar.f32_exp(b) - 81)
		}
	}

	f32_add : U32, U32 -> U32
	f32_add = |a, b| {
		sa = TableVar.f32_sig(a)
		sb = TableVar.f32_sig(b)
		na = TableVar.f32_negative(a)
		nb = TableVar.f32_negative(b)
		if sa == 0 and sb == 0 {
			if (na and nb) 0x80000000 else 0
		} else if sa == 0 {
			b
		} else if sb == 0 {
			a
		} else {
			ea = TableVar.f32_exp(a)
			eb = TableVar.f32_exp(b)
			# Align on the smaller exponent. When the exponents are far apart
			# the smaller operand only decides rounding, so a sticky 1 stands
			# for it.
			aligned =
				if ea >= eb {
					gap = ea - eb
					if (gap <= 90) { x: sa.shl_wrap(gap.to_u8_wrap()), y: sb, exp: eb } else { x: sa.shl_wrap(92), y: 1, exp: ea - 92 }
				} else {
					gap = eb - ea
					if (gap <= 90) { x: sa, y: sb.shl_wrap(gap.to_u8_wrap()), exp: ea } else { x: 1, y: sb.shl_wrap(92), exp: eb - 92 }
				}
			if na == nb {
				TableVar.f32_pack(na, aligned.x + aligned.y, aligned.exp)
			} else if aligned.x > aligned.y {
				TableVar.f32_pack(na, aligned.x - aligned.y, aligned.exp)
			} else if aligned.y > aligned.x {
				TableVar.f32_pack(nb, aligned.y - aligned.x, aligned.exp)
			} else {
				0
			}
		}
	}

	f32_sub : U32, U32 -> U32
	f32_sub = |a, b| TableVar.f32_add(a, b.bitwise_xor(0x80000000))

	# An ordering key: -0 and +0 are equal.
	f32_key : U32 -> I64
	f32_key = |x| {
		magnitude = x.bitwise_and(0x7FFFFFFF).to_i64()
		if (TableVar.f32_negative(x)) 0 - magnitude else magnitude
	}

	f32_lt : U32, U32 -> Bool
	f32_lt = |a, b| TableVar.f32_key(a) < TableVar.f32_key(b)

	f32_eq : U32, U32 -> Bool
	f32_eq = |a, b| TableVar.f32_key(a) == TableVar.f32_key(b)

	# HarfBuzz's hb_min and hb_max: the first argument when neither is less.
	f32_min : U32, U32 -> U32
	f32_min = |a, b| if (TableVar.f32_lt(b, a)) b else a

	f32_max : U32, U32 -> U32
	f32_max = |a, b| if (TableVar.f32_lt(a, b)) b else a

	## The largest integer not above x. Magnitudes here stay far below
	## 2^62; larger ones saturate.
	f32_floor : U32 -> I64
	f32_floor = |x| {
		sig = TableVar.f32_sig(x)
		exp = TableVar.f32_exp(x)
		negative = TableVar.f32_negative(x)
		if sig == 0 {
			0
		} else if exp >= 0 {
			magnitude = if (exp > 38) 0x3FFFFFFFFFFFFFFF else sig.shl_wrap(exp.to_u8_wrap()).to_i64_wrap()
			if (negative) 0 - magnitude else magnitude
		} else {
			drop = 0 - exp
			whole = if (drop >= 128) 0 else sig.shr_zf_wrap(drop.to_u8_wrap())
			fraction = sig != whole.shl_wrap(drop.min(127).to_u8_wrap())
			w = whole.to_i64_wrap()
			if negative {
				if (fraction) 0 - w - 1 else 0 - w
			} else {
				w
			}
		}
	}

	## HarfBuzz's `roundf`: floor(x + 0.5) with the addition in single
	## precision, so halves round up (towards positive infinity).
	f32_round_half_up : U32 -> I64
	f32_round_half_up = |x| TableVar.f32_floor(TableVar.f32_add(x, TableVar.f32_half))

	# ------------------------------------------------------------ bytes

	u8 : List(U8), U64 -> U64
	u8 = |bytes, at| (bytes.get(at) ?? 0).to_u64()

	u16 : List(U8), U64 -> U64
	u16 = |bytes, at| TableVar.u8(bytes, at) * 256 + TableVar.u8(bytes, at + 1)

	u32 : List(U8), U64 -> U64
	u32 = |bytes, at| TableVar.u16(bytes, at) * 65536 + TableVar.u16(bytes, at + 2)

	i8 : List(U8), U64 -> I64
	i8 = |bytes, at| {
		v = TableVar.u8(bytes, at).to_i64_wrap()
		if (v >= 128) v - 256 else v
	}

	i16 : List(U8), U64 -> I64
	i16 = |bytes, at| {
		v = TableVar.u16(bytes, at).to_i64_wrap()
		if (v >= 32768) v - 65536 else v
	}

	i32 : List(U8), U64 -> I64
	i32 = |bytes, at| {
		v = TableVar.u32(bytes, at).to_i64_wrap()
		if (v >= 0x80000000) v - 0x100000000 else v
	}

	# Whether `len` bytes from `start` lie inside `size` bytes.
	fits : U64, U64, U64 -> Bool
	fits = |start, len, size| start <= size and len <= size - start
}
