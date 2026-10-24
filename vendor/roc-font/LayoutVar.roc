import TableVar

## Layout at any location of a variable font: the deltas `GPOS` adjustments
## take from the `GDEF` item variation store, and the alternate feature
## tables a `GSUB` or `GPOS` table substitutes at some locations.
##
## Internal. Three parts:
##
## - The `GDEF` item variation store (`GDEF` version 1.3 `itemVarStoreOffset`)
##   and its location state (`location`): region scalars, computed once per
##   location.
## - Value records with device offsets (`ValueRecord` `xPlaDevice`,
##   `yPlaDevice`, `xAdvDevice`, `yAdvDevice`): `check_gpos` checks, once,
##   every device a pair adjustment can reach; `x_advance` and `value` read a
##   value record in place and add each `VariationIndex` device's delta.
## - `FeatureVariations` (`GSUB`/`GPOS` version 1.1): condition sets and
##   feature table substitutions, read once and flattened, evaluated per
##   location by `substitutions_at`.
##
## Numbers follow HarfBuzz bit for bit (`TableVar` holds the single-precision
## arithmetic). A device delta is the store's single-precision sum rounded
## half up (`roundf` in HarfBuzz is `floor(x + 0.5)`), added to the value
## record's own value, each device separately. HarfBuzz applies no device
## at the default location (every coordinate zero), even where a malformed
## region would give a nonzero scalar there, so neither does this module.
## Hinting devices (delta formats 1 to 3) adjust by pixels per em, which a
## font-unit result never has, so they add nothing (HarfBuzz at a ppem of 0).
##
## After a successful read every query here is total.
LayoutVar := {
	# The GDEF store; with no store, one with no data subtables, in which
	# only `no_variation` is a valid index.
	store : TableVar.Store,
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
		DeviceFormat,
		AxisIndex,
		FeatureIndex,
		LookupIndex,
		SubstitutionOrder,
		NestingDepth,
		TooMuchWork,
	]

	## The location state for layout: whether any coordinate is nonzero
	## (HarfBuzz applies devices only then) and the `GDEF` store's region
	## scalars, as `TableVar.region_scalars` computes them.
	Location : { active : Bool, scalars : List(U32) }

	## A value record's four values at a location, in font units.
	Value : { x_placement : I64, y_placement : I64, x_advance : I64, y_advance : I64 }

	## A table's `FeatureVariations`, read and checked. Record r's condition
	## set is the postfix program `kinds[starts[r]]` up to `starts[r + 1]`
	## (with operands `a`, `b`, `c`); its substitutions are entries
	## `substitution_starts[r]` up to `substitution_starts[r + 1]` of
	## `features` (sorted feature indices) and `tables` (the offset in `data`
	## of each alternate feature table, 0 for one with no lookups).
	FeatureVariations : {
		data : List(U8),
		starts : List(U64),
		kinds : List(U8),
		a : List(I64),
		b : List(I64),
		c : List(I64),
		uses_values : Bool,
		substitution_starts : List(U64),
		features : List(U64),
		tables : List(U64),
	}

	# ------------------------------------------------------------ limits

	## Nested conditions accepted (HarfBuzz's `HB_MAX_NESTING_LEVEL`).
	nesting_limit : U64
	nesting_limit = 64

	## Reading work is counted in steps, one per table visited and one per
	## entry checked. Offsets may point many times at the same data, so a few
	## bytes could describe billions of entries; a table that takes more than
	## eight steps per byte (plus a fixed allowance) is refused, as
	## `LayoutKerning` refuses one.
	spend : List(U8), U64, U64 -> Try(U64, [TooMuchWork])
	spend = |data, steps, cost| {
		total = steps + cost + 1
		if (total > 8 * data.len() + 16384) Err(TooMuchWork) else Ok(total)
	}

	# ------------------------------------------------------------ GDEF

	## No `GDEF` store: every device delta is zero.
	none : U64 -> LayoutVar
	none = |axis_count| { store: LayoutVar.empty_store(axis_count) }

	empty_store : U64 -> TableVar.Store
	empty_store = |axis_count| { axis_count, region_count: 0, regions: [], item_counts: [], word_counts: [], long_words: [], index_starts: [0], region_indexes: [], row_starts: [], row_sizes: [], bytes: [] }

	## Read the item variation store of a `GDEF` table for a font with
	## `axis_count` axes. A `GDEF` before version 1.3, or with a null store
	## offset, has none.
	read_gdef : List(U8), U64 -> Try(LayoutVar, List(Problem))
	read_gdef = |gdef, axis_count| {
		bad = |at, reason| Err([{ table: "GDEF", offset: at, reason }])
		if gdef.len() < 4 {
			return bad(0, Truncated)
		}
		if TableVar.u16(gdef, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		if TableVar.u16(gdef, 2) < 3 {
			return Ok(LayoutVar.none(axis_count))
		}
		if gdef.len() < 18 {
			return bad(0, Truncated)
		}
		at = TableVar.u32(gdef, 14)
		if at == 0 {
			return Ok(LayoutVar.none(axis_count))
		}
		match TableVar.read_store(gdef, "GDEF", at, axis_count) {
			Ok(store) => Ok({ store: store })
			Err(problems) => Err(problems.map(LayoutVar.from_var))
		}
	}

	has_store : LayoutVar -> Bool
	has_store = |lv| !lv.store.item_counts.is_empty()

	from_var : TableVar.Problem -> Problem
	from_var = |p| {
		reason = match p.reason {
			Truncated => Truncated
			UnsupportedVersion => UnsupportedVersion
			BadFormat => BadFormat
			BadRecordSize => BadRecordSize
			TooManyAxes => TooManyAxes
			AxisOrder => AxisOrder
			AxisCountMismatch => AxisCountMismatch
			MapMissingIdentity => MapMissingIdentity
			MapOrder => MapOrder
			MapRange => MapRange
			TooManyRegions => TooManyRegions
			RegionIndex => RegionIndex
			WordCount => WordCount
			DeltaIndex => DeltaIndex
			ItemCount => ItemCount
			TagOrder => TagOrder
		}
		{ table: p.table, offset: p.offset, reason }
	}

	# ------------------------------------------------------------ location

	## The location state at normalised coordinates (F2Dot14, one per axis).
	## At the default location nothing is computed.
	location : LayoutVar, List(I16) -> Location
	location = |lv, coords|
		if coords.any(|c| c != 0) {
			{ active: True, scalars: TableVar.region_scalars(lv.store, coords) }
		} else {
			LayoutVar.default_location
		}

	## The default location: no device applies.
	default_location : Location
	default_location = { active: False, scalars: [] }

	## The delta of a `VariationIndex` (outer and inner index) at a
	## location, rounded half up as HarfBuzz rounds it (`em_scalef` at a
	## scale of units per em). `no_variation` has none.
	delta : LayoutVar, Location, U64, U64 -> I64
	delta = |lv, loc, outer, inner|
		if loc.active {
			TableVar.f32_round_half_up(TableVar.delta(lv.store, loc.scalars, outer, inner))
		} else {
			0
		}

	# ------------------------------------------------------------ value records

	## Size in bytes of a value record of a format. Only the eight defined
	## bits count, as in HarfBuzz and `LayoutKerning`.
	value_size : U64 -> U64
	value_size = |format| 2 * LayoutVar.bits(format, 0xFF)

	bits : U64, U64 -> U64
	bits = |format, mask| format.bitwise_and(mask).to_u8_wrap().count_one_bits().to_u64()

	## Whether a value format has a device offset that can vary the x
	## advance. Without one, `x_advance` is the stored value.
	varies_x_advance : U64 -> Bool
	varies_x_advance = |format| format.bitwise_and(0x40) != 0

	## The x advance of a checked value record at `at` in `data`, with
	## `format`, at a location: its stored value plus its device's delta.
	## Device offsets count from `base`: the pair set for pair adjustment
	## format 1, the subtable for format 2 (as HarfBuzz and fontTools).
	x_advance : LayoutVar, Location, List(U8), U64, U64, U64 -> I64
	x_advance = |lv, loc, data, base, at, format| {
		stored = if (format.bitwise_and(4) == 0) 0 else TableVar.i16(data, at + 2 * LayoutVar.bits(format, 3))
		if loc.active and format.bitwise_and(0x40) != 0 {
			stored + LayoutVar.device_delta(lv, loc, data, base, at + 2 * LayoutVar.bits(format, 0x3F))
		} else {
			stored
		}
	}

	## All four values of a checked value record at a location; see
	## `x_advance`. A y advance applies only to vertical text and the
	## placements only once glyph offsets are positioned; the caller picks.
	value : LayoutVar, Location, List(U8), U64, U64, U64 -> Value
	value = |lv, loc, data, base, at, format| {
		field = |bit| at + 2 * LayoutVar.bits(format, bit - 1)
		stored = |bit| if (format.bitwise_and(bit) == 0) 0 else TableVar.i16(data, field(bit))
		varied = |bit| if (loc.active and format.bitwise_and(bit) != 0) LayoutVar.device_delta(lv, loc, data, base, field(bit)) else 0
		{
			x_placement: stored(0x01) + varied(0x10),
			y_placement: stored(0x02) + varied(0x20),
			x_advance: stored(0x04) + varied(0x40),
			y_advance: stored(0x08) + varied(0x80),
		}
	}

	# The delta of the checked device whose offset (from `base`) is at
	# `field`: a `VariationIndex` table's, or none.
	device_delta : LayoutVar, Location, List(U8), U64, U64 -> I64
	device_delta = |lv, loc, data, base, field| {
		offset = TableVar.u16(data, field)
		if offset == 0 {
			0
		} else {
			device = base + offset
			if (TableVar.u16(data, device + 4) == 0x8000) LayoutVar.delta(lv, loc, TableVar.u16(data, device), TableVar.u16(data, device + 2)) else 0
		}
	}

	# ------------------------------------------------------------ checking devices

	## Check every device offset of every pair adjustment value record in a
	## `GPOS` table (lookup type 2, directly or through an extension) that a
	## query can reach: each device lies inside the table, has a delta format
	## of 1 to 3 or `VariationIndex` (0x8000), and a `VariationIndex` names a
	## row of the `GDEF` store or is `no_variation` in both halves. Returns
	## how many device offsets were checked. One problem is reported per bad
	## subtable. A pair set of a first glyph at or past `glyph_count` is never
	## looked at, so it is not checked (as `LayoutKerning`).
	check_gpos : LayoutVar, List(U8), U64 -> Try(U64, List(Problem))
	check_gpos = |lv, gpos, glyph_count| {
		bad = |at, reason| Err([{ table: "GPOS", offset: at, reason }])
		size = gpos.len()
		if size < 10 {
			return bad(0, Truncated)
		}
		if TableVar.u16(gpos, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		lookups = TableVar.u16(gpos, 8)
		if !TableVar.fits(lookups, 2, size) {
			return bad(8, Truncated)
		}
		lookup_count = TableVar.u16(gpos, lookups)
		if !TableVar.fits(lookups + 2, 2 * lookup_count, size) {
			return bad(lookups, Truncated)
		}
		var $steps = match LayoutVar.spend(gpos, 0, lookup_count) {
			Ok(s) => s
			Err(TooMuchWork) => return bad(lookups, TooMuchWork)
		}
		var $problems = []
		var $checked = 0
		for index in 0..<lookup_count {
			lookup = lookups + TableVar.u16(gpos, lookups + 2 + 2 * index)
			kind = TableVar.u16(gpos, lookup)
			count = TableVar.u16(gpos, lookup + 4)
			if kind != 2 and kind != 9 {
				{}
			} else if !TableVar.fits(lookup, 6 + 2 * count, size) {
				$problems = $problems.append({ table: "GPOS", offset: lookup, reason: Truncated })
			} else {
				for s in 0..<count {
					at = lookup + TableVar.u16(gpos, lookup + 6 + 2 * s)
					target =
						if kind == 2 {
							Pair(at)
						} else if !TableVar.fits(at, 8, size) {
							Broken(at)
						} else if TableVar.u16(gpos, at + 2) == 2 {
							Pair(at + TableVar.u32(gpos, at + 4))
						} else {
							Other
						}
					match target {
						Pair(start) =>
							match LayoutVar.check_pair(lv, gpos, start, glyph_count, $steps) {
								Ok(done) => {
									$steps = done.steps
									$checked = $checked + done.checked
								}
								Err(BadAt(problem)) => {
									$problems = $problems.append(problem)
								}
								Err(Exhausted(problem)) => return Err($problems.append(problem))
							}
						Broken(start) => {
							$problems = $problems.append({ table: "GPOS", offset: start, reason: Truncated })
						}
						Other => {}
					}
				}
			}
		}
		if ($problems.is_empty()) Ok($checked) else Err($problems)
	}

	## Check the devices of one pair adjustment subtable at `at`, spending
	## from `steps`. A subtable whose value formats have no device costs one
	## step. `Exhausted` means the table's work allowance ran out.
	check_pair : LayoutVar, List(U8), U64, U64, U64 -> Try({ steps : U64, checked : U64 }, [BadAt(Problem), Exhausted(Problem)])
	check_pair = |lv, data, at, glyph_count, steps| {
		size = data.len()
		bad = |offset, reason| Err(BadAt({ table: "GPOS", offset, reason }))
		if !TableVar.fits(at, 10, size) {
			return bad(at, Truncated)
		}
		format = TableVar.u16(data, at)
		format1 = TableVar.u16(data, at + 4)
		format2 = TableVar.u16(data, at + 6)
		if format1.bitwise_or(format2).bitwise_and(0xF0) == 0 {
			return Ok({ steps: steps + 1, checked: 0 })
		}
		size1 = LayoutVar.value_size(format1)
		size2 = LayoutVar.value_size(format2)
		coverage = at + TableVar.u16(data, at + 2)
		covered = TableVar.u16(data, coverage + 2)
		coverage_format = TableVar.u16(data, coverage)
		if !TableVar.fits(coverage, 4, size) {
			return bad(at + 2, Truncated)
		}
		if coverage_format != 1 and coverage_format != 2 {
			return bad(coverage, BadFormat)
		}
		if !TableVar.fits(coverage + 4, (if (coverage_format == 1) 2 else 6) * covered, size) {
			return bad(coverage, Truncated)
		}
		exhausted = |offset| Err(Exhausted({ table: "GPOS", offset, reason: TooMuchWork }))
		var $steps = match LayoutVar.spend(data, steps, covered) {
			Ok(s) => s
			Err(TooMuchWork) => return exhausted(coverage)
		}
		var $checked = 0
		if format == 1 {
			set_count = TableVar.u16(data, at + 8)
			if !TableVar.fits(at + 10, 2 * set_count, size) {
				return bad(at + 8, Truncated)
			}
			record = 2 + size1 + size2
			# The pair set indices a query can reach, each a run of
			# consecutive indices.
			for i in 0..<covered {
				span =
					if coverage_format == 1 {
						glyph = TableVar.u16(data, coverage + 4 + 2 * i)
						if (glyph < glyph_count and i < set_count) { first: i, count: 1 } else { first: 0, count: 0 }
					} else {
						r = coverage + 4 + 6 * i
						first = TableVar.u16(data, r)
						last = TableVar.u16(data, r + 2)
						index = TableVar.u16(data, r + 4)
						if first <= last and first < glyph_count and index < set_count {
							{ first: index, count: (last.min(glyph_count - 1) - first + 1).min(set_count - index) }
						} else {
							{ first: 0, count: 0 }
						}
					}
				for k in 0..<span.count {
					field = at + 10 + 2 * (span.first + k)
					set = at + TableVar.u16(data, field)
					pairs = TableVar.u16(data, set)
					if !TableVar.fits(set, 2, size) or !TableVar.fits(set + 2, record * pairs, size) {
						return bad(field, Truncated)
					}
					$steps = match LayoutVar.spend(data, $steps, pairs) {
						Ok(s) => s
						Err(TooMuchWork) => return exhausted(set)
					}
					for p in 0..<pairs {
						r = set + 2 + record * p
						match LayoutVar.check_devices(lv, data, set, r + 2, format1) {
							Ok(n) => {
								$checked = $checked + n
							}
							Err(problem) => return Err(BadAt(problem))
						}
						match LayoutVar.check_devices(lv, data, set, r + 2 + size1, format2) {
							Ok(n) => {
								$checked = $checked + n
							}
							Err(problem) => return Err(BadAt(problem))
						}
					}
				}
			}
		} else if format == 2 {
			if !TableVar.fits(at, 16, size) {
				return bad(at, Truncated)
			}
			height = TableVar.u16(data, at + 12)
			width = TableVar.u16(data, at + 14)
			cells = height * width
			if !TableVar.fits(at + 16, (size1 + size2) * cells, size) {
				return bad(at + 12, Truncated)
			}
			$steps = match LayoutVar.spend(data, $steps, cells) {
				Ok(s) => s
				Err(TooMuchWork) => return exhausted(at + 12)
			}
			for cell in 0..<cells {
				r = at + 16 + (size1 + size2) * cell
				match LayoutVar.check_devices(lv, data, at, r, format1) {
					Ok(n) => {
						$checked = $checked + n
					}
					Err(problem) => return Err(BadAt(problem))
				}
				match LayoutVar.check_devices(lv, data, at, r + size1, format2) {
					Ok(n) => {
						$checked = $checked + n
					}
					Err(problem) => return Err(BadAt(problem))
				}
			}
		} else {
			return bad(at, BadFormat)
		}
		Ok({ steps: $steps, checked: $checked })
	}

	## Check the device offsets of the value record at `at` (inside the
	## table) with `format`, counted from `base`. Returns how many there are.
	check_devices : LayoutVar, List(U8), U64, U64, U64 -> Try(U64, Problem)
	check_devices = |lv, data, base, at, format| {
		var $n = 0
		for bit in [0x10, 0x20, 0x40, 0x80] {
			if format.bitwise_and(bit) != 0 {
				LayoutVar.check_device(lv, data, base, at + 2 * LayoutVar.bits(format, bit - 1))?
				$n = $n + 1
			}
		}
		Ok($n)
	}

	check_device : LayoutVar, List(U8), U64, U64 -> Try({}, Problem)
	check_device = |lv, data, base, field| {
		offset = TableVar.u16(data, field)
		device = base + offset
		delta_format = TableVar.u16(data, device + 4)
		if offset == 0 {
			Ok({})
		} else if !TableVar.fits(device, 6, data.len()) {
			Err({ table: "GPOS", offset: field, reason: Truncated })
		} else if delta_format == 0x8000 {
			if (TableVar.valid_index(lv.store, TableVar.u16(data, device), TableVar.u16(data, device + 2))) Ok({}) else Err({ table: "GPOS", offset: device, reason: DeltaIndex })
		} else if delta_format >= 1 and delta_format <= 3 {
			Ok({})
		} else {
			Err({ table: "GPOS", offset: device + 4, reason: DeviceFormat })
		}
	}

	# ------------------------------------------------------------ feature variations

	## No feature variations.
	no_feature_variations : FeatureVariations
	no_feature_variations = { data: [], starts: [0], kinds: [], a: [], b: [], c: [], uses_values: False, substitution_starts: [0], features: [], tables: [] }

	# Condition program operations.
	op_true : U8
	op_true = 0

	op_false : U8
	op_false = 1

	op_range : U8
	op_range = 2

	op_value : U8
	op_value = 3

	op_and : U8
	op_and = 4

	op_or : U8
	op_or = 5

	op_not : U8
	op_not = 6

	## Read the `FeatureVariations` of a `GSUB` or `GPOS` table (`table` is
	## its tag, for problems) for a font with `axis_count` axes. A table
	## before version 1.1, or with a null offset, has none.
	##
	## Each record's condition set and its conditions are read into one flat
	## postfix program: axis ranges (format 1), values from the `GDEF` store
	## (format 2), and the combinations and, or and not (formats 3 to 5) as
	## HarfBuzz reads them. A null condition holds (HarfBuzz's format 0); a
	## condition of an unknown format does not hold, as the specification
	## asks. Conditions nest at most `nesting_limit` deep. Each substitution
	## names a feature of the table, in increasing order, and each alternate
	## feature table's lookups exist. Lookup variation records (version 1.1
	## of the `FeatureVariations` table, which HarfBuzz reads) are not read.
	read_feature_variations : List(U8), Str, LayoutVar, U64 -> Try(FeatureVariations, List(Problem))
	read_feature_variations = |data, table, lv, axis_count| {
		size = data.len()
		bad = |at, reason| Err([{ table, offset: at, reason }])
		if size < 10 {
			return bad(0, Truncated)
		}
		if TableVar.u16(data, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		if TableVar.u16(data, 2) < 1 {
			return Ok({ data, starts: [0], kinds: [], a: [], b: [], c: [], uses_values: False, substitution_starts: [0], features: [], tables: [] })
		}
		if size < 14 {
			return bad(0, Truncated)
		}
		base = TableVar.u32(data, 10)
		if base == 0 {
			return Ok({ data, starts: [0], kinds: [], a: [], b: [], c: [], uses_values: False, substitution_starts: [0], features: [], tables: [] })
		}
		features_at = TableVar.u16(data, 6)
		lookups_at = TableVar.u16(data, 8)
		if !TableVar.fits(features_at, 2, size) {
			return bad(6, Truncated)
		}
		if !TableVar.fits(lookups_at, 2, size) {
			return bad(8, Truncated)
		}
		feature_count = TableVar.u16(data, features_at)
		lookup_count = TableVar.u16(data, lookups_at)
		if !TableVar.fits(base, 8, size) {
			return bad(10, Truncated)
		}
		if TableVar.u16(data, base) != 1 {
			return bad(base, UnsupportedVersion)
		}
		count = TableVar.u32(data, base + 4)
		if !TableVar.fits(base + 8, 8 * count, size) {
			return bad(base + 4, Truncated)
		}
		var $steps = match LayoutVar.spend(data, 0, count) {
			Ok(s) => s
			Err(TooMuchWork) => return bad(base + 4, TooMuchWork)
		}
		var $problems = []
		var $program = { kinds: [], a: [], b: [], c: [], uses_values: False }
		var $starts = List.with_capacity(count + 1)
		var $substitution_starts = List.with_capacity(count + 1)
		var $features = []
		var $tables = []
		for r in 0..<count {
			record = base + 8 + 8 * r
			$starts = $starts.append($program.kinds.len())
			$substitution_starts = $substitution_starts.append($features.len())
			# The condition set.
			set_offset = TableVar.u32(data, record)
			match LayoutVar.read_condition_set(data, table, lv, axis_count, if (set_offset == 0) 0 else base + set_offset, $program, $steps) {
				Ok(done) => {
					$program = done.program
					$steps = done.steps
				}
				Err(Bad(problem)) => {
					$problems = $problems.append(problem)
				}
				Err(Exhausted(problem)) => return Err($problems.append(problem))
			}
			# The substitutions.
			substitutions_offset = TableVar.u32(data, record + 4)
			if substitutions_offset != 0 {
				at = base + substitutions_offset
				n = TableVar.u16(data, at + 4)
				if !TableVar.fits(at, 6, size) {
					$problems = $problems.append({ table, offset: record + 4, reason: Truncated })
				} else if TableVar.u16(data, at) != 1 {
					$problems = $problems.append({ table, offset: at, reason: UnsupportedVersion })
				} else if !TableVar.fits(at + 6, 6 * n, size) {
					$problems = $problems.append({ table, offset: at + 4, reason: Truncated })
				} else {
					$steps = match LayoutVar.spend(data, $steps, n) {
						Ok(s) => s
						Err(TooMuchWork) => return Err($problems.append({ table, offset: at + 4, reason: TooMuchWork }))
					}
					var $ok = True
					var $k = 0
					while $ok and $k < n {
						entry = at + 6 + 6 * $k
						feature = TableVar.u16(data, entry)
						alternate = TableVar.u32(data, entry + 2)
						feature_at = at + alternate
						lookup_total = TableVar.u16(data, feature_at + 2)
						problem =
							if feature >= feature_count {
								Some({ table, offset: entry, reason: FeatureIndex })
							} else if $k > 0 and feature <= TableVar.u16(data, entry - 6) {
								Some({ table, offset: entry, reason: SubstitutionOrder })
							} else if alternate == 0 {
								None
							} else if !TableVar.fits(feature_at, 4, size) or !TableVar.fits(feature_at + 4, 2 * lookup_total, size) {
								Some({ table, offset: entry + 2, reason: Truncated })
							} else {
								var $found = None
								var $j = 0
								while $j < lookup_total {
									if TableVar.u16(data, feature_at + 4 + 2 * $j) >= lookup_count {
										$found = Some({ table, offset: feature_at + 4 + 2 * $j, reason: LookupIndex })
										$j = lookup_total
									} else {
										$j = $j + 1
									}
								}
								$found
							}
						match problem {
							Some(p) => {
								$problems = $problems.append(p)
								$ok = False
							}
							None => {
								$steps = match LayoutVar.spend(data, $steps, if (alternate == 0) 0 else lookup_total) {
									Ok(s) => s
									Err(TooMuchWork) => return Err($problems.append({ table, offset: entry + 2, reason: TooMuchWork }))
								}
								$features = $features.append(feature)
								$tables = $tables.append(if (alternate == 0) 0 else feature_at)
							}
						}
						$k = $k + 1
					}
				}
			}
		}
		$starts = $starts.append($program.kinds.len())
		$substitution_starts = $substitution_starts.append($features.len())
		if !$problems.is_empty() {
			return Err($problems)
		}
		Ok({
			data,
			starts: $starts,
			kinds: $program.kinds,
			a: $program.a,
			b: $program.b,
			c: $program.c,
			uses_values: $program.uses_values,
			substitution_starts: $substitution_starts,
			features: $features,
			tables: $tables,
		})
	}

	Program : { kinds : List(U8), a : List(I64), b : List(I64), c : List(I64), uses_values : Bool }

	emit : Program, U8, I64, I64, I64 -> Program
	emit = |p, kind, a, b, c| { kinds: p.kinds.append(kind), a: p.a.append(a), b: p.b.append(b), c: p.c.append(c), uses_values: p.uses_values or kind == LayoutVar.op_value }

	# Append the postfix program of the condition set at `at` (0 for a null
	# offset: no conditions, which holds). Conditions are visited through an
	# explicit work list: `Visit` a condition at a depth, or `Emit` an
	# operation once its operands are in the program.
	read_condition_set : List(U8), Str, LayoutVar, U64, U64, Program, U64 -> Try({ program : Program, steps : U64 }, [Bad(Problem), Exhausted(Problem)])
	read_condition_set = |data, table, lv, axis_count, at, program_in, steps_in| {
		size = data.len()
		count = if (at == 0) 0 else TableVar.u16(data, at)
		if at != 0 and !TableVar.fits(at, 2 + 4 * count, size) {
			return Err(Bad({ table, offset: at, reason: Truncated }))
		}
		var $steps = match LayoutVar.spend(data, steps_in, count) {
			Ok(s) => s
			Err(TooMuchWork) => return Err(Exhausted({ table, offset: at, reason: TooMuchWork }))
		}
		var $program = program_in
		# The work list, as parallel lists: kind 0 visits the condition at
		# `place` (0 for null) at `depth`; kinds op_and, op_or and op_not emit
		# that operation with `place` operands.
		var $kinds = [LayoutVar.op_and]
		var $places = [count]
		var $depth = [0]
		for i in 0..<count {
			k = count - 1 - i
			offset = TableVar.u32(data, at + 2 + 4 * k)
			$kinds = $kinds.append(0)
			$places = $places.append(if (offset == 0) 0 else at + offset)
			$depth = $depth.append(1)
		}
		while !$kinds.is_empty() {
			last = $kinds.len() - 1
			kind = $kinds.get(last) ?? 0
			place = $places.get(last) ?? 0
			depth = $depth.get(last) ?? 0
			$kinds = $kinds.drop_last(1)
			$places = $places.drop_last(1)
			$depth = $depth.drop_last(1)
			$steps = match LayoutVar.spend(data, $steps, 0) {
				Ok(s) => s
				Err(TooMuchWork) => return Err(Exhausted({ table, offset: at, reason: TooMuchWork }))
			}
			if kind != 0 {
				$program = LayoutVar.emit($program, kind, place.to_i64_wrap(), 0, 0)
			} else if place == 0 {
				$program = LayoutVar.emit($program, LayoutVar.op_true, 0, 0, 0)
			} else if depth > LayoutVar.nesting_limit {
				return Err(Bad({ table, offset: place, reason: NestingDepth }))
			} else if !TableVar.fits(place, 2, size) {
				return Err(Bad({ table, offset: place, reason: Truncated }))
			} else {
				format = TableVar.u16(data, place)
				if format == 0 {
					$program = LayoutVar.emit($program, LayoutVar.op_true, 0, 0, 0)
				} else if format == 1 {
					if !TableVar.fits(place, 8, size) {
						return Err(Bad({ table, offset: place, reason: Truncated }))
					}
					axis = TableVar.u16(data, place + 2)
					if axis >= axis_count {
						return Err(Bad({ table, offset: place + 2, reason: AxisIndex }))
					}
					$program = LayoutVar.emit($program, LayoutVar.op_range, axis.to_i64_wrap(), TableVar.i16(data, place + 4), TableVar.i16(data, place + 6))
				} else if format == 2 {
					if !TableVar.fits(place, 8, size) {
						return Err(Bad({ table, offset: place, reason: Truncated }))
					}
					outer = TableVar.u16(data, place + 4)
					inner = TableVar.u16(data, place + 6)
					if !TableVar.valid_index(lv.store, outer, inner) {
						return Err(Bad({ table, offset: place + 4, reason: DeltaIndex }))
					}
					$program = LayoutVar.emit($program, LayoutVar.op_value, TableVar.i16(data, place + 2), outer.to_i64_wrap(), inner.to_i64_wrap())
				} else if format == 3 or format == 4 {
					n = TableVar.u8(data, place + 2)
					if !TableVar.fits(place, 3 + 3 * n, size) {
						return Err(Bad({ table, offset: place, reason: Truncated }))
					}
					$kinds = $kinds.append(if (format == 3) LayoutVar.op_and else LayoutVar.op_or)
					$places = $places.append(n)
					$depth = $depth.append(depth)
					for i in 0..<n {
						k = n - 1 - i
						field = place + 3 + 3 * k
						offset = TableVar.u8(data, field) * 65536 + TableVar.u16(data, field + 1)
						$kinds = $kinds.append(0)
						$places = $places.append(if (offset == 0) 0 else place + offset)
						$depth = $depth.append(depth + 1)
					}
				} else if format == 5 {
					if !TableVar.fits(place, 5, size) {
						return Err(Bad({ table, offset: place, reason: Truncated }))
					}
					offset = TableVar.u8(data, place + 2) * 65536 + TableVar.u16(data, place + 3)
					$kinds = $kinds.append(LayoutVar.op_not).append(0)
					$places = $places.append(1).append(if (offset == 0) 0 else place + offset)
					$depth = $depth.append(depth).append(depth + 1)
				} else {
					$program = LayoutVar.emit($program, LayoutVar.op_false, 0, 0, 0)
				}
			}
		}
		Ok({ program: $program, steps: $steps })
	}

	## The index of the first record whose conditions hold at normalised
	## coordinates `coords` (F2Dot14, one per axis), as HarfBuzz chooses it.
	matching_record : FeatureVariations, LayoutVar, List(I16) -> Try(U64, [NoMatch])
	matching_record = |fv, lv, coords| {
		records = fv.starts.len() - 1
		# Value conditions use unquantised scalars, as HarfBuzz evaluates
		# them without its scalar cache; with no coordinates they are zero.
		scalars = if (fv.uses_values and !coords.is_empty()) LayoutVar.exact_scalars(lv.store, coords) else []
		var $r = 0
		while $r < records {
			if LayoutVar.holds(fv, lv, coords, scalars, $r) {
				return Ok($r)
			}
			$r = $r + 1
		}
		Err(NoMatch)
	}

	## The feature table substitutions that apply at a location: for each
	## substituted feature (by index in the table's feature list, in
	## increasing order), the offset in the table of its alternate feature
	## table, or 0 for one with no lookups. Empty when no record matches.
	substitutions_at : FeatureVariations, LayoutVar, List(I16) -> List({ feature : U64, table : U64 })
	substitutions_at = |fv, lv, coords|
		match LayoutVar.matching_record(fv, lv, coords) {
			Ok(r) => {
				first = fv.substitution_starts.get(r) ?? 0
				last = fv.substitution_starts.get(r + 1) ?? 0
				var $out = List.with_capacity(last - first)
				for k in first..<last {
					$out = $out.append({ feature: fv.features.get(k) ?? 0, table: fv.tables.get(k) ?? 0 })
				}
				$out
			}
			Err(NoMatch) => []
		}

	## The lookup indices of a checked alternate feature table.
	lookups_of : FeatureVariations, U64 -> List(U64)
	lookups_of = |fv, at|
		if at == 0 {
			[]
		} else {
			n = TableVar.u16(fv.data, at + 2)
			var $out = List.with_capacity(n)
			for j in 0..<n {
				$out = $out.append(TableVar.u16(fv.data, at + 4 + 2 * j))
			}
			$out
		}

	# Evaluate record r's postfix program on a stack of booleans. A checked
	# program leaves exactly one value; each operation's operands are on
	# the stack, so every index below is in bounds.
	holds : FeatureVariations, LayoutVar, List(I16), List(U32), U64 -> Bool
	holds = |fv, lv, coords, scalars, r| {
		first = fv.starts.get(r) ?? 0
		last = fv.starts.get(r + 1) ?? 0
		var $stack = List.repeat(False, last - first)
		var $top = 0
		for i in first..<last {
			kind = fv.kinds.get(i) ?? 0
			a = fv.a.get(i) ?? 0
			if kind == LayoutVar.op_true {
				$stack = $stack.set($top, True) ?? []
				$top = $top + 1
			} else if kind == LayoutVar.op_false {
				$stack = $stack.set($top, False) ?? []
				$top = $top + 1
			} else if kind == LayoutVar.op_range {
				coord = (coords.get(a.to_u64_wrap()) ?? 0).to_i64()
				result = (fv.b.get(i) ?? 0) <= coord and coord <= (fv.c.get(i) ?? 0)
				$stack = $stack.set($top, result) ?? []
				$top = $top + 1
			} else if kind == LayoutVar.op_value {
				d = TableVar.delta(lv.store, scalars, (fv.b.get(i) ?? 0).to_u64_wrap(), (fv.c.get(i) ?? 0).to_u64_wrap())
				# default + delta > 0, exactly as HarfBuzz's double sum.
				result = TableVar.f32_lt(TableVar.f32_from_int(0 - a), d)
				$stack = $stack.set($top, result) ?? []
				$top = $top + 1
			} else if kind == LayoutVar.op_not {
				$stack = $stack.set($top - 1, !($stack.get($top - 1) ?? False)) ?? []
			} else {
				n = a.to_u64_wrap()
				var $result = kind == LayoutVar.op_and
				for k in ($top - n)..<$top {
					v = $stack.get(k) ?? False
					$result = if (kind == LayoutVar.op_and) $result and v else $result or v
				}
				$top = $top - n
				$stack = $stack.set($top, $result) ?? []
				$top = $top + 1
			}
		}
		$stack.get(0) ?? False
	}

	# Every region's scalar without HarfBuzz's cache quantisation.
	exact_scalars : TableVar.Store, List(I16) -> List(U32)
	exact_scalars = |store, coords| {
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
			$out = $out.append($v)
		}
		$out
	}
}
