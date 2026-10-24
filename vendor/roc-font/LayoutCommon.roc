import Bytes

## The script list, language systems and feature list shared by `GSUB`
## and `GPOS` (OpenType "Layout common table formats"): which features a
## script and language system offers, and which lookups each feature
## uses.
##
## Internal. Reading checks every script, language system and feature
## table once: each lies inside the table, every feature index a language
## system lists names a feature, and the work is bounded (see `spend`).
## The checked tables are read in place afterwards, so choosing features
## for a shaping plan is total.
##
## Selection follows HarfBuzz (`hb-ot-layout.cc`, `hb-ot-map.cc`): script
## and language system records are found by binary search, as HarfBuzz
## finds them; the first of several features with one tag in a language
## system wins.
LayoutCommon := {
	data : List(U8),
	script_list : U64,
	script_count : U64,
	feature_list : U64,
	feature_count : U64,
	lookup_count : U64,
}.{

	## No scripts and no features.
	none : LayoutCommon
	none = { data: [], script_list: 0, script_count: 0, feature_list: 0, feature_count: 0, lookup_count: 0 }

	## A language system meaning "none": no features.
	no_langsys : U64
	no_langsys = 0

	no_feature : U64
	no_feature = 0xFFFF

	tag : Str -> U64
	tag = |name| name.to_utf8().fold(0, |acc, b| acc * 256 + b.to_u64())

	## Reading work, as `LayoutGsub` counts it: one step per table visited and
	## one per entry, at most eight per byte of the table plus 16384.
	spend : List(U8), U64, U64, U64 -> Try(U64, [Bad(U64)])
	spend = |data, steps, cost, at| {
		total = steps + cost + 1
		if (total > 8 * data.len() + 16384) Err(Bad(at)) else Ok(total)
	}

	## Check the script and feature lists of a `GSUB` or `GPOS` table.
	## Problems give their offset in the table. Returns the work spent too.
	read : List(U8) -> Try({ common : LayoutCommon, steps : U64 }, [Bad(U64)])
	read = |data| {
		size = data.len()
		if !Bytes.fits(0, 10, size) {
			return Err(Bad(0))
		}
		script_list = Bytes.u16(data, 4)
		feature_list = Bytes.u16(data, 6)
		lookup_list = Bytes.u16(data, 8)
		script_count = Bytes.u16(data, script_list)
		feature_count = Bytes.u16(data, feature_list)
		lookup_count = Bytes.u16(data, lookup_list)
		if !Bytes.fits(script_list, 2 + 6 * script_count, size) {
			return Err(Bad(script_list))
		}
		if !Bytes.fits(feature_list, 2 + 6 * feature_count, size) {
			return Err(Bad(feature_list))
		}
		if !Bytes.fits(lookup_list, 2 + 2 * lookup_count, size) {
			return Err(Bad(lookup_list))
		}
		var $steps = LayoutCommon.spend(data, 0, script_count + feature_count, 0)?
		for f in 0..<feature_count {
			offset = Bytes.u16(data, feature_list + 2 + 6 * f + 4)
			if offset != 0 {
				at = feature_list + offset
				count = Bytes.u16(data, at + 2)
				if !Bytes.fits(at, 4 + 2 * count, size) {
					return Err(Bad(at))
				}
			}
		}
		for s in 0..<script_count {
			script = script_list + Bytes.u16(data, script_list + 2 + 6 * s + 4)
			if !Bytes.fits(script, 4, size) {
				return Err(Bad(script))
			}
			langs = Bytes.u16(data, script + 2)
			if !Bytes.fits(script + 4, 6 * langs, size) {
				return Err(Bad(script))
			}
			$steps = LayoutCommon.spend(data, $steps, langs, script)?
			default = Bytes.u16(data, script)
			if default != 0 {
				$steps = LayoutCommon.check_langsys(data, script + default, feature_count, $steps)?
			}
			for l in 0..<langs {
				offset = Bytes.u16(data, script + 4 + 6 * l + 4)
				if offset != 0 {
					$steps = LayoutCommon.check_langsys(data, script + offset, feature_count, $steps)?
				}
			}
		}
		Ok({ common: { data, script_list, script_count, feature_list, feature_count, lookup_count }, steps: $steps })
	}

	check_langsys : List(U8), U64, U64, U64 -> Try(U64, [Bad(U64)])
	check_langsys = |data, at, feature_count, steps| {
		count = Bytes.u16(data, at + 4)
		if !Bytes.fits(at, 6 + 2 * count, data.len()) {
			return Err(Bad(at))
		}
		after = LayoutCommon.spend(data, steps, count, at)?
		required = Bytes.u16(data, at + 2)
		if required != LayoutCommon.no_feature and required >= feature_count {
			return Err(Bad(at + 2))
		}
		for k in 0..<count {
			if Bytes.u16(data, at + 6 + 2 * k) >= feature_count {
				return Err(Bad(at + 6 + 2 * k))
			}
		}
		Ok(after)
	}

	# ------------------------------------------------------------ selection

	## HarfBuzz's binary search over records of `stride` bytes starting at
	## `at`, keyed by the four-byte tag at their start.
	bsearch : List(U8), U64, U64, U64, U64 -> Try(U64, [NotFound])
	bsearch = |data, at, count, stride, key| {
		var $low = 0.I64
		var $high = count.to_i64_wrap() - 1
		while $low <= $high {
			mid = ($low + $high) // 2
			probe = Bytes.u32(data, at + stride * mid.to_u64_wrap())
			if key < probe {
				$high = mid - 1
			} else if key > probe {
				$low = mid + 1
			} else {
				return Ok(mid.to_u64_wrap())
			}
		}
		Err(NotFound)
	}

	## The script chosen for candidate tags (in order of preference), then
	## `DFLT`, `dflt` and `latn`, as HarfBuzz chooses. The result is the
	## offset of the script table, or `NoScript`.
	select_script : LayoutCommon, List(U64) -> [Script(U64), NoScript]
	select_script = |common, candidates| {
		all = candidates.concat([LayoutCommon.tag("DFLT"), LayoutCommon.tag("dflt"), LayoutCommon.tag("latn")])
		var $found = NoScript
		var $k = 0
		while $k < all.len() {
			key = all.get($k) ?? 0
			match LayoutCommon.bsearch(common.data, common.script_list + 2, common.script_count, 6, key) {
				Ok(index) => {
					$found = Script(common.script_list + Bytes.u16(common.data, common.script_list + 2 + 6 * index + 4))
					$k = all.len()
				}
				Err(_) => {
					$k = $k + 1
				}
			}
		}
		$found
	}

	## The language system chosen in a script for candidate tags, then
	## `dflt`, then the script's default language system: its offset, or
	## `no_langsys` for none.
	select_langsys : LayoutCommon, [Script(U64), NoScript], List(U64) -> U64
	select_langsys = |common, chosen, candidates|
		match chosen {
			NoScript => LayoutCommon.no_langsys
			Script(script) => {
				data = common.data
				count = Bytes.u16(data, script + 2)
				all = candidates.append(LayoutCommon.tag("dflt"))
				var $found = Bytes.u16(data, script)
				var $k = 0
				while $k < all.len() {
					match LayoutCommon.bsearch(data, script + 4, count, 6, all.get($k) ?? 0) {
						Ok(index) => {
							$found = Bytes.u16(data, script + 4 + 6 * index + 4)
							$k = all.len()
						}
						Err(_) => {
							$k = $k + 1
						}
					}
				}
				if ($found == 0) LayoutCommon.no_langsys else script + $found
			}
		}

	## The feature index of a tag in a language system (the first listed
	## feature with the tag), or `no_feature`.
	find_feature : LayoutCommon, U64, U64 -> U64
	find_feature = |common, langsys, key|
		if langsys == LayoutCommon.no_langsys {
			LayoutCommon.no_feature
		} else {
			data = common.data
			count = Bytes.u16(data, langsys + 4)
			var $found = LayoutCommon.no_feature
			var $k = 0
			while $k < count {
				index = Bytes.u16(data, langsys + 6 + 2 * $k)
				if Bytes.u32(data, common.feature_list + 2 + 6 * index) == key {
					$found = index
					$k = count
				} else {
					$k = $k + 1
				}
			}
			$found
		}

	## A language system's required feature, or `no_feature`.
	required_feature : LayoutCommon, U64 -> U64
	required_feature = |common, langsys|
		if (langsys == LayoutCommon.no_langsys) LayoutCommon.no_feature else Bytes.u16(common.data, langsys + 2)

	## The tag of a feature.
	feature_tag : LayoutCommon, U64 -> U64
	feature_tag = |common, index| Bytes.u32(common.data, common.feature_list + 2 + 6 * index)

	## The lookup indices a feature lists, below the lookup count (HarfBuzz
	## passes over the others).
	feature_lookups : LayoutCommon, U64 -> List(U64)
	feature_lookups = |common, index|
		if index >= common.feature_count {
			[]
		} else {
			data = common.data
			offset = Bytes.u16(data, common.feature_list + 2 + 6 * index + 4)
			if offset == 0 {
				[]
			} else {
				at = common.feature_list + offset
				count = Bytes.u16(data, at + 2)
				var $out = List.with_capacity(count)
				for k in 0..<count {
					lookup = Bytes.u16(data, at + 4 + 2 * k)
					if lookup < common.lookup_count {
						$out = $out.append(lookup)
					}
				}
				$out
			}
		}

	## Which lookups any feature lists (below the lookup count), read in
	## place.
	all_feature_lookups : LayoutCommon -> List(Bool)
	all_feature_lookups = |common| {
		data = common.data
		var $used = List.repeat(False, common.lookup_count)
		for f in 0..<common.feature_count {
			offset = Bytes.u16(data, common.feature_list + 2 + 6 * f + 4)
			if offset != 0 {
				at = common.feature_list + offset
				for k in 0..<Bytes.u16(data, at + 2) {
					lookup = Bytes.u16(data, at + 4 + 2 * k)
					if lookup < common.lookup_count {
						# Checked against the lookup count, the list's length.
						$used = $used.set(lookup, True) ?? []
					}
				}
			}
		}
		$used
	}
}
