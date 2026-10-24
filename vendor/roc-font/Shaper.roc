import Face
import LayoutCommon
import LayoutGsub
import LayoutKerning
import ShaperTags

## Shaping with HarfBuzz's default shaper: choosing lookups for a script,
## language, direction and features (a plan, as `hb-ot-map.cc` and
## `hb-ot-shape.cc` build one), then mapping text to glyphs, substituting,
## positioning and finishing the run.
##
## Internal. What is not done yet, each a documented difference from
## HarfBuzz: Unicode-based steps (normalisation, default ignorables, space
## fallbacks, mirroring for right-to-left text, grapheme clusters, mark
## classes without `GDEF`), lookup flags, GSUB types 3 and 8, GPOS types
## other than pair adjustment, automatic fractions and `rand`. Features
## beyond 62 that vary across the text are dropped, as HarfBuzz drops
## features when its mask bits run out.
Shaper :: {}.{

	Options : {
		script : Str,
		language : Str,
		direction : [FromScript, LeftToRight, RightToLeft],
		features : List({ tag : Str, value : U32, start : U32, end : U32 }),
		growth : U64,
		operations : U64,
	}

	## A plan: the lookups to apply in order with their masks, the ranges of
	## text where features that vary are on or off, and the direction.
	Plan : {
		reverse_input : Bool,
		reverse_output : Bool,
		gsub : List({ index : U64, mask : U64 }),
		gpos : List({ index : U64, mask : U64 }),
		kern : [Kern(U64), NoKern],
		default_mask : U64,
		ranges : List({ bit : U64, on : Bool, start : U64, end : U64 }),
		growth : U64,
		operations : U64,
	}

	Run : { glyphs : List(U32), advances : List({ x : I32, y : I32 }), offsets : List({ x : I32, y : I32 }), clusters : List(U32), flags : List(U8) }

	## A requested feature: `global` when it covers all text.
	Request : { tag : U64, value : U64, global : Bool, stage : U64 }

	## A feature after merging requests for its tag.
	Merged : { tag : U64, max : U64, default : U64, global : Bool, stage : U64 }

	global_bit : U64
	global_bit = 1

	empty_run : Run
	empty_run = { glyphs: [], advances: [], offsets: [], clusters: [], flags: [] }

	tag : Str -> U64
	tag = |name| ShaperTags.tag_of(name)

	# ------------------------------------------------------------ planning

	## A feature tag from a string: up to four bytes, padded with spaces.
	feature_tag : Str -> U64
	feature_tag = |name| ShaperTags.tag_from_bytes(name.to_utf8())

	plan : Face, Options -> Plan
	plan = |face, options| {
		requested = match options.direction {
			LeftToRight => Ltr
			RightToLeft => Rtl
			FromScript =>
				match ShaperTags.script_direction(options.script) {
					Rtl => Rtl
					_ => Ltr
				}
		}
		native = ShaperTags.script_direction(options.script)
		reverse_input = match (native, requested) {
			(Ltr, Rtl) => True
			(Rtl, Ltr) => True
			_ => False
		}
		shaped_rtl = match (reverse_input, requested) {
			(True, Rtl) => False
			(True, Ltr) => True
			(False, Rtl) => True
			(False, Ltr) => False
		}
		# The features HarfBuzz's default shaper asks for, then the caller's.
		direction_features = match requested {
			Ltr => [{ tag: Shaper.tag("ltra"), value: 1, global: True, stage: 1 }, { tag: Shaper.tag("ltrm"), value: 1, global: True, stage: 1 }]
			Rtl => [{ tag: Shaper.tag("rtla"), value: 1, global: True, stage: 1 }, { tag: Shaper.tag("rtlm"), value: 1, global: False, stage: 1 }]
		}
		defaults = ["abvm", "blwm", "ccmp", "locl", "mark", "mkmk", "rlig", "calt", "clig", "curs", "dist", "kern", "liga", "rclt"].map(|t| { tag: Shaper.tag(t), value: 1, global: True, stage: 1 })
		user = options.features.map(|f| { tag: Shaper.feature_tag(f.tag), value: f.value.to_u64(), global: f.start == 0 and f.end == 0xFFFFFFFF, stage: 1 })
		requests = [{ tag: Shaper.tag("rvrn"), value: 1, global: True, stage: 0 }].concat(direction_features).concat(defaults).concat(user)
		merged = Shaper.merge(requests)
		# Masks: the global bit for features on everywhere with value 1, else
		# a bit of their own (HarfBuzz gives them a field; only on and off
		# matter here). Features with no value anywhere are left out.
		var $bits = []
		var $next_bit = 1
		var $default_mask = Shaper.global_bit
		for f in merged {
			bit = if f.max == 0 {
				0
			} else if f.global and f.max == 1 {
				Shaper.global_bit
			} else if $next_bit < 63 {
				b = (1.U64).shl_wrap($next_bit.to_u8_wrap())
				$next_bit = $next_bit + 1
				if f.default != 0 {
					$default_mask = $default_mask.bitwise_or(b)
				}
				b
			} else {
				0
			}
			$bits = $bits.append(bit)
		}
		lang = ShaperTags.language_tags(options.language)
		script_tags = match lang.scripts {
			Given(t) => [t]
			NotGiven => ShaperTags.script_tags(options.script)
		}
		gsub_common = LayoutGsub.common_of(Face.gsub(face))
		kerning = Face.kerning(face)
		gpos_common = LayoutKerning.common_of(kerning)
		gsub_langsys = LayoutCommon.select_langsys(gsub_common, LayoutCommon.select_script(gsub_common, script_tags), lang.languages)
		gpos_langsys = LayoutCommon.select_langsys(gpos_common, LayoutCommon.select_script(gpos_common, script_tags), lang.languages)
		gsub = Shaper.lookups(gsub_common, gsub_langsys, merged, $bits, 2)
		gpos = Shaper.lookups(gpos_common, gpos_langsys, merged, $bits, 1)
		kern_tag = Shaper.tag("kern")
		kern_mask = Shaper.mask_of(merged, $bits, kern_tag)
		has_gpos_kern = LayoutCommon.find_feature(gpos_common, gpos_langsys, kern_tag) != LayoutCommon.no_feature
		kern = if (LayoutKerning.has_kern(kerning) and kern_mask != 0 and (!has_gpos_kern or !LayoutKerning.has_gpos(kerning))) Kern(kern_mask) else NoKern
		# Ranges, in the caller's order: a later one wins where they overlap.
		var $ranges = []
		for f in options.features {
			if !(f.start == 0 and f.end == 0xFFFFFFFF) {
				bit = Shaper.mask_of(merged, $bits, Shaper.feature_tag(f.tag))
				if bit != 0 and bit != Shaper.global_bit {
					$ranges = $ranges.append({ bit, on: f.value != 0, start: f.start.to_u64(), end: f.end.to_u64() })
				}
			}
		}
		{
			reverse_input,
			reverse_output: shaped_rtl,
			gsub,
			gpos,
			kern,
			default_mask: $default_mask,
			ranges: $ranges,
			growth: options.growth,
			operations: options.operations,
		}
	}

	## Merge requests by tag, as HarfBuzz's map builder merges them: a
	## global request sets the value everywhere, a ranged one makes the
	## feature vary and raises its largest value; the earliest stage wins.
	## Tags keep the order of their first request.
	merge : List(Request) -> List(Merged)
	merge = |requests| {
		var $out = []
		for r in requests {
			match $out.find_first_index(|m| m.tag == r.tag) {
				Err(_) => {
					$out = $out.append({ tag: r.tag, max: r.value, default: if (r.global) r.value else 0, global: r.global, stage: r.stage })
				}
				Ok(i) => {
					m = $out.get(i) ?? { tag: 0, max: 0, default: 0, global: False, stage: 0 }
					updated =
						if r.global {
							{ ..m, global: True, max: r.value, default: r.value, stage: m.stage.min(r.stage) }
						} else {
							{ ..m, global: False, max: m.max.max(r.value), stage: m.stage.min(r.stage) }
						}
					# `find_first_index` gave an index in the list.
					$out = $out.set(i, updated) ?? []
				}
			}
		}
		$out
	}

	mask_of : List(Merged), List(U64), U64 -> U64
	mask_of = |merged, bits, wanted|
		match merged.find_first_index(|m| m.tag == wanted) {
			Ok(i) => bits.get(i) ?? 0
			Err(_) => 0
		}

	## The lookups of a table for the merged features, stage by stage, each
	## stage in lookup index order with the masks of every feature that
	## lists the lookup. The language system's required feature applies
	## everywhere, in its tag's stage if a feature has that tag, else in the
	## first.
	lookups : LayoutCommon, U64, List(Merged), List(U64), U64 -> List({ index : U64, mask : U64 })
	lookups = |common, langsys, merged, bits, stages| {
		required = LayoutCommon.required_feature(common, langsys)
		required_tag = if (required == LayoutCommon.no_feature) 0 else LayoutCommon.feature_tag(common, required)
		required_stage = match merged.find_first(|m| m.tag == required_tag and required != LayoutCommon.no_feature) {
			Ok(m) => m.stage.min(stages - 1)
			Err(_) => 0
		}
		var $out = []
		for stage in 0..<stages {
			var $masks = List.repeat(0, common.lookup_count)
			if required != LayoutCommon.no_feature and required_stage == stage {
				for lookup in LayoutCommon.feature_lookups(common, required) {
					# Feature lookups are below the lookup count.
					$masks = $masks.set(lookup, ($masks.get(lookup) ?? 0).bitwise_or(Shaper.global_bit)) ?? []
				}
			}
			for k in 0..<merged.len() {
				m = merged.get(k) ?? { tag: 0, max: 0, default: 0, global: False, stage: 0 }
				bit = bits.get(k) ?? 0
				if bit != 0 and m.stage.min(stages - 1) == stage {
					index = LayoutCommon.find_feature(common, langsys, m.tag)
					if index != LayoutCommon.no_feature {
						for lookup in LayoutCommon.feature_lookups(common, index) {
							$masks = $masks.set(lookup, ($masks.get(lookup) ?? 0).bitwise_or(bit)) ?? []
						}
					}
				}
			}
			for index in 0..<common.lookup_count {
				mask = $masks.get(index) ?? 0
				if mask != 0 {
					$out = $out.append({ index, mask })
				}
			}
		}
		$out
	}

	# ------------------------------------------------------------ shaping

	## Text as scalars with the UTF-8 byte offset each starts at.
	decode : Str -> List({ scalar : U32, offset : U32 })
	decode = |text| {
		bytes = text.to_utf8()
		count = bytes.len()
		var $out = List.with_capacity(count)
		var $i = 0
		while $i < count {
			b0 = (bytes.get($i) ?? 0).to_u32()
			width = if (b0 < 0x80) 1 else if (b0 < 0xE0) 2 else if (b0 < 0xF0) 3 else 4
			var $cp = if (width == 1) b0 else if (width == 2) b0.bitwise_and(0x1F) else if (width == 3) b0.bitwise_and(0x0F) else b0.bitwise_and(0x07)
			for k in 1..<width {
				$cp = $cp.shl_wrap(6).bitwise_or((bytes.get($i + k) ?? 0).to_u32().bitwise_and(0x3F))
			}
			$out = $out.append({ scalar: $cp, offset: $i.min(0xFFFFFFFF).to_u32_wrap() })
			$i = $i + width
		}
		$out
	}

	## The mask of a glyph from text at `offset`: the default, then each
	## range that covers the offset, in order.
	mask_at : Plan, U64 -> U64
	mask_at = |p, offset| {
		var $mask = p.default_mask
		for r in p.ranges {
			if offset >= r.start and offset < r.end {
				$mask = if (r.on) $mask.bitwise_or(r.bit) else $mask.bitwise_and(r.bit.bitwise_xor(0xFFFFFFFFFFFFFFFF))
			}
		}
		$mask
	}

	clamp : I64 -> I32
	clamp = |v| v.max(-2147483648).min(2147483647).to_i32_wrap()

	shape : Face, Face.Location, Plan, List({ scalar : U32, offset : U32 }) -> Run
	shape = |face, location, p, scalars| {
		n = scalars.len()
		if n == 0 {
			return Shaper.empty_run
		}
		var $items = List.with_capacity(n)
		for s in scalars {
			glyph = Face.glyph(face, s.scalar) ?? 0
			$items = $items.append({ glyph, cluster: s.offset.to_u64(), mask: Shaper.mask_at(p, s.offset.to_u64()) })
		}
		ordered = if (p.reverse_input) Shaper.reversed($items) else $items
		limit = (p.growth * n).max(16384)
		budget = (p.operations * n).max(16384)
		substituted = LayoutGsub.apply(Face.gsub(face), p.gsub, ordered, { limit, budget, depth: Face.max_depth(face) })
		positioned = LayoutKerning.position(Face.kerning(face), p.gpos, p.kern, substituted, Face.glyph_count(face))
		items = positioned.items
		count = items.len()
		var $glyphs = List.with_capacity(count)
		var $advances = List.with_capacity(count)
		var $offsets = List.with_capacity(count)
		var $clusters = List.with_capacity(count)
		for k in 0..<count {
			i = if (p.reverse_output) count - 1 - k else k
			item = items.get(i) ?? LayoutGsub.no_item
			advance = Face.advance(face, location, item.glyph).to_i64() + (positioned.ax.get(i) ?? 0)
			$glyphs = $glyphs.append(item.glyph.min(0xFFFFFFFF).to_u32_wrap())
			$advances = $advances.append({ x: Shaper.clamp(advance), y: 0 })
			$offsets = $offsets.append({ x: Shaper.clamp(positioned.dx.get(i) ?? 0), y: Shaper.clamp(positioned.dy.get(i) ?? 0) })
			$clusters = $clusters.append(item.cluster.min(0xFFFFFFFF).to_u32_wrap())
		}
		{ glyphs: $glyphs, advances: $advances, offsets: $offsets, clusters: $clusters, flags: Shaper.flags(items, p.reverse_output) }
	}

	reversed : List(a) -> List(a)
	reversed = |list| {
		n = list.len()
		var $out = List.with_capacity(n)
		var $k = n
		while $k > 0 {
			match list.get($k - 1) {
				Ok(x) => {
					$out = $out.append(x)
				}
				Err(_) => {}
			}
			$k = $k - 1
		}
		$out
	}

	## Unsafe-to-break flags in output order, the same on every glyph of a
	## cluster (consecutive glyphs with one cluster), as HarfBuzz's
	## `hb_propagate_flags` makes them.
	flags : List(LayoutGsub.Item), Bool -> List(U8)
	flags = |items, reverse| {
		count = items.len()
		var $out = List.with_capacity(count)
		var $k = 0
		while $k < count {
			at = |j| items.get(if (reverse) count - 1 - j else j) ?? LayoutGsub.no_item
			cluster = at($k).cluster
			var $end = $k
			var $unsafe = False
			while $end < count and at($end).cluster == cluster {
				if at($end).mask.bitwise_and(LayoutGsub.unsafe) != 0 {
					$unsafe = True
				}
				$end = $end + 1
			}
			for _ in $k..<$end {
				$out = $out.append(if ($unsafe) 1 else 0)
			}
			$k = $end
		}
		$out
	}
}
