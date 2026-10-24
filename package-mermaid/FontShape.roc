## Glyph substitution from a font's `GSUB` table: the ligatures and
## contextual alternates a browser applies by default (features `ccmp`,
## `rlig`, `liga`, `clig`, `calt` and `rclt`, for the Latin script or the
## default script). They change which glyphs draw a run of text, and so its
## width: Inter, for example, draws `->` as one arrow glyph and raises an
## asterisk next to capitals.
##
## Lookup flags (skipping marks or ligatures) are not interpreted.
FontShape := {
	lookups : List(
		List(
			[
				Single({ coverage : List({ first : U64, last : U64, index : U64 }), delta : I64, glyphs : List(U64) }),
				Multiple({ coverage : List({ first : U64, last : U64, index : U64 }), sequences : List(List(U64)) }),
				Ligature({ coverage : List({ first : U64, last : U64, index : U64 }), sets : List(List({ glyph : U64, rest : List(U64) })) }),
				Context(
					{
						coverage : List({ first : U64, last : U64, index : U64 }),
						by_class : Bool,
						back_classes : List({ first : U64, last : U64, index : U64 }),
						input_classes : List({ first : U64, last : U64, index : U64 }),
						ahead_classes : List({ first : U64, last : U64, index : U64 }),
						sets : List(
							List(
								{
									back : List([Glyph(U64), Class(U64), Covered(List({ first : U64, last : U64, index : U64 }))]),
									input : List([Glyph(U64), Class(U64), Covered(List({ first : U64, last : U64, index : U64 }))]),
									ahead : List([Glyph(U64), Class(U64), Covered(List({ first : U64, last : U64, index : U64 }))]),
									records : List({ at : U64, lookup : U64 }),
								},
							),
						),
					},
				),
			],
		),
	),
	active : List(U64),
}.{

	Ranges : List({ first : U64, last : U64, index : U64 })

	Match : [Glyph(U64), Class(U64), Covered(Ranges)]

	Rule : { back : List(Match), input : List(Match), ahead : List(Match), records : List({ at : U64, lookup : U64 }) }

	Subtable : [
		Single({ coverage : Ranges, delta : I64, glyphs : List(U64) }),
		Multiple({ coverage : Ranges, sequences : List(List(U64)) }),
		Ligature({ coverage : Ranges, sets : List(List({ glyph : U64, rest : List(U64) })) }),
		Context({ coverage : Ranges, by_class : Bool, back_classes : Ranges, input_classes : Ranges, ahead_classes : Ranges, sets : List(List(Rule)) }),
	]

	## One glyph of a run, with the index of the first character it draws.
	Item : { glyph : U64, cluster : U64 }

	## No substitutions.
	none : FontShape
	none = { lookups: [], active: [] }

	feature_tags : List(Str)
	feature_tags = ["ccmp", "rlig", "liga", "clig", "calt", "rclt"]

	# ------------------------------------------------------------ applying

	## Apply the default features to a run, lookup by lookup. Each lookup
	## passes over the run once, left to right, writing a new run.
	apply : FontShape, List(Item) -> List(Item)
	apply = |shape, items| {
		limit = 4 * items.len() + 32
		var $input = items
		for index in shape.active {
			subtables = shape.lookups.get(index) ?? []
			var $out = List.with_capacity($input.len())
			var $i = 0
			while $i < $input.len() {
				match FontShape.step(shape, subtables, $out, $input, $i, limit) {
					Stepped(done) => {
						$out = $out.concat(done.emit)
						$i = done.next
					}
					NotApplied => {
						$out = $out.append($input.get($i) ?? { glyph: 0, cluster: 0 })
						$i = $i + 1
					}
				}
			}
			$input = $out
		}
		$input
	}

	# The first subtable that applies at `i`: what it writes and where reading
	# continues. Backtrack context is read from what has been written.
	step : FontShape, List(Subtable), List(Item), List(Item), U64, U64 -> [Stepped({ emit : List(Item), next : U64 }), NotApplied]
	step = |shape, subtables, out, input, i, limit| {
		item = input.get(i) ?? { glyph: 0, cluster: 0 }
		var $result = NotApplied
		var $k = 0
		while $k < subtables.len() {
			outcome = match subtables.get($k) {
				Ok(Single(s)) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => Stepped({ emit: [{ glyph: FontShape.single(s.delta, s.glyphs, at, item.glyph), cluster: item.cluster }], next: i + 1 })
						Err(_) => NotApplied
					}
				Ok(Multiple(s)) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => {
							sequence = s.sequences.get(at) ?? [item.glyph]
							if out.len() + sequence.len() + (input.len() - i) > limit + 1 {
								NotApplied
							} else {
								Stepped({ emit: sequence.map(|g| { glyph: g, cluster: item.cluster }), next: i + 1 })
							}
						}
						Err(_) => NotApplied
					}
				Ok(Ligature(s)) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) =>
							match FontShape.ligature_at(s.sets.get(at) ?? [], input, i) {
								Found(found) => Stepped({ emit: [{ glyph: found.glyph, cluster: item.cluster }], next: i + 1 + found.count })
								NotFound => NotApplied
							}
						Err(_) => NotApplied
					}
				Ok(Context(s)) =>
					match FontShape.rule_at(s, out, out.len(), input, i) {
						Found(rule) => {
							window = input.sublist({ start: i, len: rule.input.len() + 1 })
							done = FontShape.substitute(shape, rule.records, window.len(), window, 0, 1, limit)
							Stepped({ emit: done.buffer, next: i + window.len() })
						}
						NotFound => NotApplied
					}
				Err(_) => NotApplied
			}
			match outcome {
				Stepped(done) => {
					$result = Stepped(done)
					$k = subtables.len()
				}
				NotApplied => {
					$k = $k + 1
				}
			}
		}
		$result
	}

	single : I64, List(U64), U64, U64 -> U64
	single = |delta, glyphs, at, glyph|
		if glyphs.is_empty() {
			(glyph.to_i64_wrap() + delta).bitwise_and(0xFFFF).to_u64_wrap()
		} else {
			glyphs.get(at) ?? glyph
		}

	# The first ligature of a set whose other components follow `i`.
	ligature_at : List({ glyph : U64, rest : List(U64) }), List(Item), U64 -> [Found({ glyph : U64, count : U64 }), NotFound]
	ligature_at = |set, buffer, i| {
		var $result = NotFound
		var $k = 0
		while $k < set.len() {
			candidate = set.get($k) ?? { glyph: 0, rest: [] }
			count = candidate.rest.len()
			var $same = i + count < buffer.len()
			var $j = 0
			while $same and $j < count {
				if ((buffer.get(i + 1 + $j) ?? { glyph: 0, cluster: 0 }).glyph) != (candidate.rest.get($j) ?? 0) {
					$same = False
				}
				$j = $j + 1
			}
			if $same {
				$result = Found({ glyph: candidate.glyph, count })
				$k = set.len()
			} else {
				$k = $k + 1
			}
		}
		$result
	}

	# The first rule of a context subtable that matches at `i` of `after`,
	# with backtrack read from the end of `before` (its first `before_end`
	# items).
	rule_at : { coverage : Ranges, by_class : Bool, back_classes : Ranges, input_classes : Ranges, ahead_classes : Ranges, sets : List(List(Rule)) }, List(Item), U64, List(Item), U64 -> [Found(Rule), NotFound]
	rule_at = |s, before, before_end, after, i| {
		glyph = (after.get(i) ?? { glyph: 0, cluster: 0 }).glyph
		match FontShape.covered(s.coverage, glyph) {
			Err(_) => NotFound
			Ok(at) => {
				slot = if (s.by_class) FontShape.class_of(s.input_classes, glyph) else if (s.sets.len() == 1) 0 else at
				rules = s.sets.get(slot) ?? []
				var $result = NotFound
				var $k = 0
				while $k < rules.len() {
					rule = rules.get($k) ?? { back: [], input: [], ahead: [], records: [] }
					if FontShape.matches(rule, s, before, before_end, after, i) {
						$result = Found(rule)
						$k = rules.len()
					} else {
						$k = $k + 1
					}
				}
				$result
			}
		}
	}

	# Nested lookups, applied in place on a rule's matched input.
	apply_lookup : FontShape, U64, List(Item), U64, U64, U64 -> [Applied({ buffer : List(Item), next : U64 }), NotApplied]
	apply_lookup = |shape, index, buffer, i, depth, limit| {
		subtables = shape.lookups.get(index) ?? []
		var $result = NotApplied
		var $k = 0
		while $k < subtables.len() {
			outcome = match subtables.get($k) {
				Ok(subtable) => FontShape.apply_subtable(shape, subtable, buffer, i, depth, limit)
				Err(_) => NotApplied
			}
			match outcome {
				Applied(done) => {
					$result = Applied(done)
					$k = subtables.len()
				}
				NotApplied => {
					$k = $k + 1
				}
			}
		}
		$result
	}

	apply_subtable : FontShape, Subtable, List(Item), U64, U64, U64 -> [Applied({ buffer : List(Item), next : U64 }), NotApplied]
	apply_subtable = |shape, subtable, buffer, i, depth, limit| {
		item = buffer.get(i) ?? { glyph: 0, cluster: 0 }
		if i >= buffer.len() {
			NotApplied
		} else {
			match subtable {
				Single(s) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => {
							glyph = if s.glyphs.is_empty() {
								(item.glyph.to_i64_wrap() + s.delta).bitwise_and(0xFFFF).to_u64_wrap()
							} else {
								s.glyphs.get(at) ?? item.glyph
							}
							# `i` is in bounds (checked above).
							Applied({ buffer: buffer.set(i, { glyph, cluster: item.cluster }) ?? [], next: i + 1 })
						}
						Err(_) => NotApplied
					}
				Multiple(s) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => {
							sequence = s.sequences.get(at) ?? [item.glyph]
							if buffer.len() + sequence.len() > limit + 1 {
								NotApplied
							} else {
								replaced = buffer
									.take_first(i)
									.concat(sequence.map(|g| { glyph: g, cluster: item.cluster }))
									.concat(buffer.drop_first(i + 1))
								Applied({ buffer: replaced, next: i + sequence.len() })
							}
						}
						Err(_) => NotApplied
					}
				Ligature(s) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) =>
							match FontShape.ligature_at(s.sets.get(at) ?? [], buffer, i) {
								Found(found) => {
									replaced = buffer.take_first(i).append({ glyph: found.glyph, cluster: item.cluster }).concat(buffer.drop_first(i + 1 + found.count))
									Applied({ buffer: replaced, next: i + 1 })
								}
								NotFound => NotApplied
							}
						Err(_) => NotApplied
					}
				Context(s) => FontShape.context(shape, s, buffer, i, depth, limit)
			}
		}
	}

	context : FontShape, { coverage : Ranges, by_class : Bool, back_classes : Ranges, input_classes : Ranges, ahead_classes : Ranges, sets : List(List(Rule)) }, List(Item), U64, U64, U64 -> [Applied({ buffer : List(Item), next : U64 }), NotApplied]
	context = |shape, s, buffer, i, depth, limit|
		match FontShape.rule_at(s, buffer, i, buffer, i) {
			Found(rule) => Applied(FontShape.substitute(shape, rule.records, rule.input.len() + 1, buffer, i, depth, limit))
			NotFound => NotApplied
		}

	# The rule's input after the first glyph, its backtrack (nearest first) and
	# its lookahead all match around `i`.
	matches : Rule, { coverage : Ranges, by_class : Bool, back_classes : Ranges, input_classes : Ranges, ahead_classes : Ranges, sets : List(List(Rule)) }, List(Item), U64, List(Item), U64 -> Bool
	matches = |rule, s, before, before_end, buffer, i| {
		input_end = i + 1 + rule.input.len()
		if before_end < rule.back.len() or input_end + rule.ahead.len() > buffer.len() {
			False
		} else {
			var $ok = True
			var $k = 0
			while $ok and $k < rule.back.len() {
				g = (before.get(before_end - 1 - $k) ?? { glyph: 0, cluster: 0 }).glyph
				$ok = FontShape.match_one(rule.back.get($k) ?? Glyph(0), s.back_classes, g)
				$k = $k + 1
			}
			$k = 0
			while $ok and $k < rule.input.len() {
				g = (buffer.get(i + 1 + $k) ?? { glyph: 0, cluster: 0 }).glyph
				$ok = FontShape.match_one(rule.input.get($k) ?? Glyph(0), s.input_classes, g)
				$k = $k + 1
			}
			$k = 0
			while $ok and $k < rule.ahead.len() {
				g = (buffer.get(input_end + $k) ?? { glyph: 0, cluster: 0 }).glyph
				$ok = FontShape.match_one(rule.ahead.get($k) ?? Glyph(0), s.ahead_classes, g)
				$k = $k + 1
			}
			$ok
		}
	}

	match_one : Match, Ranges, U64 -> Bool
	match_one = |m, classes, glyph|
		match m {
			Glyph(g) => g == glyph
			Class(c) => FontShape.class_of(classes, glyph) == c
			Covered(ranges) => FontShape.covered(ranges, glyph).is_ok()
		}

	# Run a rule's nested lookups over the matched input, then continue after
	# it.
	substitute : FontShape, List({ at : U64, lookup : U64 }), U64, List(Item), U64, U64, U64 -> { buffer : List(Item), next : U64 }
	substitute = |shape, records, matched, buffer, i, depth, limit| {
		var $buffer = buffer
		var $length = matched
		if depth < 8 {
			for record in records {
				if record.at < $length {
					before = $buffer.len()
					match FontShape.apply_lookup(shape, record.lookup, $buffer, i + record.at, depth + 1, limit) {
						Applied(done) => {
							$buffer = done.buffer
							grown = $buffer.len() + $length
							$length = if (grown >= before) grown - before else 0
						}
						NotApplied => {}
					}
				}
			}
		}
		{ buffer: $buffer, next: i + $length.max(1) }
	}

	## The coverage index of a glyph.
	covered : Ranges, U64 -> Try(U64, [NotCovered])
	covered = |ranges, glyph| {
		var $low = 0
		var $high = ranges.len()
		var $result = Err(NotCovered)
		while $low < $high {
			mid = ($low + $high) // 2
			range = ranges.get(mid) ?? { first: 1, last: 0, index: 0 }
			if glyph < range.first {
				$high = mid
			} else if glyph > range.last {
				$low = mid + 1
			} else {
				$result = Ok(range.index + glyph - range.first)
				$low = $high
			}
		}
		$result
	}

	## A glyph's class; classes are stored as ranges whose `index` is the
	## class.
	class_of : Ranges, U64 -> U64
	class_of = |ranges, glyph| {
		var $low = 0
		var $high = ranges.len()
		var $result = 0
		while $low < $high {
			mid = ($low + $high) // 2
			range = ranges.get(mid) ?? { first: 1, last: 0, index: 0 }
			if glyph < range.first {
				$high = mid
			} else if glyph > range.last {
				$low = mid + 1
			} else {
				$result = range.index
				$low = $high
			}
		}
		$result
	}

	# ------------------------------------------------------------ reading

	u16 : List(U8), U64 -> U64
	u16 = |bytes, at| (bytes.get(at) ?? 0).to_u64() * 256 + (bytes.get(at + 1) ?? 0).to_u64()

	u32 : List(U8), U64 -> U64
	u32 = |bytes, at| FontShape.u16(bytes, at) * 65536 + FontShape.u16(bytes, at + 2)

	fits : U64, U64, U64 -> Bool
	fits = |start, len, size| start <= size and len <= size - start

	tag : Str -> U64
	tag = |name| name.to_utf8().fold(0, |acc, b| acc * 256 + b.to_u64())

	## Read a `GSUB` table: the lookups of the default features, and every
	## lookup they call.
	read : List(U8) -> Try(FontShape, [Bad])
	read = |gsub| {
		if !FontShape.fits(0, 10, gsub.len()) {
			Err(Bad)
		} else {
			scripts = FontShape.u16(gsub, 4)
			features = FontShape.u16(gsub, 6)
			lookups = FontShape.u16(gsub, 8)
			lookup_count = FontShape.u16(gsub, lookups)
			feature_count = FontShape.u16(gsub, features)
			if !FontShape.fits(lookups, 2 + 2 * lookup_count, gsub.len()) or !FontShape.fits(features, 2 + 6 * feature_count, gsub.len()) {
				Err(Bad)
			} else {
				chosen = FontShape.default_features(gsub, scripts)?
				wanted = FontShape.feature_tags.map(FontShape.tag)
				var $start = []
				for f in chosen {
					if f < feature_count {
						record = features + 2 + 6 * f
						if wanted.contains(FontShape.u32(gsub, record)) {
							feature = features + FontShape.u16(gsub, record + 4)
							count = FontShape.u16(gsub, feature + 2)
							if !FontShape.fits(feature, 4 + 2 * count, gsub.len()) {
								return Err(Bad)
							}
							for j in 0..<count {
								index = FontShape.u16(gsub, feature + 4 + 2 * j)
								if index < lookup_count and !$start.contains(index) {
									$start = $start.append(index)
								}
							}
						}
					} else {
						return Err(Bad)
					}
				}
				# Read the chosen lookups and those their rules call.
				var $parsed = List.repeat([], lookup_count)
				var $seen = List.repeat(False, lookup_count)
				var $pending = $start
				while !$pending.is_empty() {
					index = $pending.last() ?? 0
					$pending = $pending.drop_last(1)
					if !($seen.get(index) ?? True) {
						$seen = $seen.set(index, True) ?? []
						lookup = lookups + FontShape.u16(gsub, lookups + 2 + 2 * index)
						subtables = FontShape.read_lookup(gsub, lookup)?
						for subtable in subtables {
							for called in FontShape.calls(subtable) {
								if called >= lookup_count {
									return Err(Bad)
								}
								$pending = $pending.append(called)
							}
						}
						$parsed = $parsed.set(index, subtables) ?? []
					}
				}
				Ok({ lookups: $parsed, active: FontShape.sorted($start) })
			}
		}
	}

	# Small lists of lookup indices; insertion sort.
	sorted : List(U64) -> List(U64)
	sorted = |items| {
		var $out = []
		for item in items {
			var $at = 0
			while $at < $out.len() and ($out.get($at) ?? 0) < item {
				$at = $at + 1
			}
			$out = $out.take_first($at).append(item).concat($out.drop_first($at))
		}
		$out
	}

	calls : Subtable -> List(U64)
	calls = |subtable|
		match subtable {
			Context(s) => s.sets.join_map(|rules| rules.join_map(|rule| rule.records.map(|r| r.lookup)))
			_ => []
		}

	# Feature indices of the `latn` script's default language, else the
	# default script's.
	default_features : List(U8), U64 -> Try(List(U64), [Bad])
	default_features = |gsub, scripts| {
		count = FontShape.u16(gsub, scripts)
		if !FontShape.fits(scripts, 2 + 6 * count, gsub.len()) {
			Err(Bad)
		} else {
			var $latin = None
			var $fallback = None
			for s in 0..<count {
				record = scripts + 2 + 6 * s
				name = FontShape.u32(gsub, record)
				script = scripts + FontShape.u16(gsub, record + 4)
				if name == FontShape.tag("latn") {
					$latin = Some(script)
				} else if name == FontShape.tag("DFLT") {
					$fallback = Some(script)
				}
			}
			chosen = match ($latin, $fallback) {
				(Some(script), _) => Some(script)
				(None, Some(script)) => Some(script)
				_ => None
			}
			match chosen {
				None => Ok([])
				Some(script) => {
					language = FontShape.u16(gsub, script)
					if language == 0 {
						Ok([])
					} else {
						at = script + language
						n = FontShape.u16(gsub, at + 4)
						if !FontShape.fits(at, 6 + 2 * n, gsub.len()) {
							Err(Bad)
						} else {
							required = FontShape.u16(gsub, at + 2)
							listed = FontShape.indices(0, n).map(|j| FontShape.u16(gsub, at + 6 + 2 * j))
							Ok(if (required == 0xFFFF) listed else listed.append(required))
						}
					}
				}
			}
		}
	}

	read_lookup : List(U8), U64 -> Try(List(Subtable), [Bad])
	read_lookup = |data, lookup| {
		kind = FontShape.u16(data, lookup)
		count = FontShape.u16(data, lookup + 4)
		if !FontShape.fits(lookup, 6 + 2 * count, data.len()) {
			Err(Bad)
		} else {
			var $subtables = []
			for s in 0..<count {
				at = lookup + FontShape.u16(data, lookup + 6 + 2 * s)
				real = if kind == 7 {
					if !FontShape.fits(at, 8, data.len()) {
						return Err(Bad)
					}
					{ kind: FontShape.u16(data, at + 2), at: at + FontShape.u32(data, at + 4) }
				} else {
					{ kind, at }
				}
				match FontShape.read_subtable(data, real.kind, real.at)? {
					Some(subtable) => {
						$subtables = $subtables.append(subtable)
					}
					None => {}
				}
			}
			Ok($subtables)
		}
	}

	read_subtable : List(U8), U64, U64 -> Try([Some(Subtable), None], [Bad])
	read_subtable = |data, kind, at| {
		if !FontShape.fits(at, 6, data.len()) {
			Err(Bad)
		} else {
			format = FontShape.u16(data, at)
			if kind == 1 {
				coverage = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2))?
				if format == 1 {
					raw = FontShape.u16(data, at + 4).to_i64_wrap()
					delta = if (raw >= 32768) raw - 65536 else raw
					Ok(Some(Single({ coverage, delta, glyphs: [] })))
				} else if format == 2 {
					glyphs = FontShape.read_u16s(data, at + 4)?
					Ok(Some(Single({ coverage, delta: 0, glyphs })))
				} else {
					Err(Bad)
				}
			} else if kind == 2 and format == 1 {
				coverage = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2))?
				offsets = FontShape.read_u16s(data, at + 4)?
				sequences = offsets.map_try(|o| FontShape.read_u16s(data, at + o))?
				Ok(Some(Multiple({ coverage, sequences })))
			} else if kind == 4 and format == 1 {
				coverage = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2))?
				offsets = FontShape.read_u16s(data, at + 4)?
				sets = offsets.map_try(
					|o| {
						set = at + o
						ligatures = FontShape.read_u16s(data, set)?
						ligatures.map_try(
							|l| {
								lig = set + l
								count = FontShape.u16(data, lig + 2)
								if count == 0 or !FontShape.fits(lig, 2 + 2 * count, data.len()) {
									Err(Bad)
								} else {
									Ok({ glyph: FontShape.u16(data, lig), rest: FontShape.indices(1, count).map(|k| FontShape.u16(data, lig + 2 + 2 * k)) })
								}
							},
						)
					},
				)?
				Ok(Some(Ligature({ coverage, sets })))
			} else if kind == 5 or kind == 6 {
				FontShape.read_context(data, kind == 6, format, at).map_ok(|subtable| Some(subtable))
			} else {
				# Alternate (3) and reverse chaining (8) substitutions are not
				# applied by default.
				Ok(None)
			}
		}
	}

	read_context : List(U8), Bool, U64, U64 -> Try(Subtable, [Bad])
	read_context = |data, chained, format, at| {
		empty = []
		if format == 3 {
			if chained {
				back = FontShape.read_coverages(data, at, at + 2)?
				input_at = at + 4 + 2 * back.len()
				input = FontShape.read_coverages(data, at, input_at)?
				ahead_at = input_at + 2 + 2 * input.len()
				ahead = FontShape.read_coverages(data, at, ahead_at)?
				records = FontShape.read_records(data, ahead_at + 2 + 2 * ahead.len())?
				first = input.first() ?? []
				if input.is_empty() {
					Err(Bad)
				} else {
					rule = { back: back.map(|c| Covered(c)), input: input.drop_first(1).map(|c| Covered(c)), ahead: ahead.map(|c| Covered(c)), records }
					Ok(Context({ coverage: first, by_class: False, back_classes: empty, input_classes: empty, ahead_classes: empty, sets: [[rule]] }))
				}
			} else {
				count = FontShape.u16(data, at + 2)
				record_count = FontShape.u16(data, at + 4)
				if count == 0 or !FontShape.fits(at, 6 + 2 * count, data.len()) {
					Err(Bad)
				} else {
					input = FontShape.indices(0, count).map_try(|k| FontShape.read_coverage(data, at + FontShape.u16(data, at + 6 + 2 * k)))?
					records = FontShape.read_record_list(data, at + 6 + 2 * count, record_count)?
					rule = { back: [], input: input.drop_first(1).map(|c| Covered(c)), ahead: [], records }
					Ok(Context({ coverage: input.first() ?? [], by_class: False, back_classes: empty, input_classes: empty, ahead_classes: empty, sets: [[rule]] }))
				}
			}
		} else if format == 1 or format == 2 {
			coverage = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2))?
			by_class = format == 2
			# Offsets to class definitions, then to the rule sets.
			class_offsets = if (!by_class) [] else if (chained) [4, 6, 8] else [4]
			classes = class_offsets.map_try(|o| FontShape.read_classes(data, at + FontShape.u16(data, at + o)))?
			sets_at = at + 4 + 2 * class_offsets.len()
			offsets = FontShape.read_u16s(data, sets_at)?
			kind = |g| if (by_class) Class(g) else Glyph(g)
			sets = offsets.map_try(
				|o|
					if o == 0 {
						Ok([])
					} else {
						set = at + o
						rules = FontShape.read_u16s(data, set)?
						rules.map_try(|r| FontShape.read_rule(data, chained, set + r, kind))
					},
			)?
			input_classes = if (chained) (classes.get(1) ?? []) else (classes.get(0) ?? [])
			Ok(Context({ coverage, by_class, back_classes: classes.get(0) ?? [], input_classes, ahead_classes: classes.get(2) ?? [], sets }))
		} else {
			Err(Bad)
		}
	}

	read_rule : List(U8), Bool, U64, (U64 -> Match) -> Try(Rule, [Bad])
	read_rule = |data, chained, at, kind| {
		if chained {
			back = FontShape.read_u16s(data, at)?
			input_at = at + 2 + 2 * back.len()
			input_count = FontShape.u16(data, input_at)
			if input_count == 0 or !FontShape.fits(input_at, 2 + 2 * (input_count - 1), data.len()) {
				Err(Bad)
			} else {
				input = FontShape.indices(1, input_count).map(|k| FontShape.u16(data, input_at + 2 * k))
				ahead_at = input_at + 2 * input_count
				ahead = FontShape.read_u16s(data, ahead_at)?
				records = FontShape.read_records(data, ahead_at + 2 + 2 * ahead.len())?
				Ok({ back: back.map(kind), input: input.map(kind), ahead: ahead.map(kind), records })
			}
		} else {
			input_count = FontShape.u16(data, at)
			record_count = FontShape.u16(data, at + 2)
			if input_count == 0 or !FontShape.fits(at, 4 + 2 * (input_count - 1), data.len()) {
				Err(Bad)
			} else {
				input = FontShape.indices(1, input_count).map(|k| FontShape.u16(data, at + 2 + 2 * k))
				records = FontShape.read_record_list(data, at + 2 + 2 * input_count, record_count)?
				Ok({ back: [], input: input.map(kind), ahead: [], records })
			}
		}
	}

	indices : U64, U64 -> List(U64)
	indices = |start, end| {
		var $out = []
		var $k = start
		while $k < end {
			$out = $out.append($k)
			$k = $k + 1
		}
		$out
	}

	# A count followed by that many 16-bit values.
	read_u16s : List(U8), U64 -> Try(List(U64), [Bad])
	read_u16s = |data, at| {
		count = FontShape.u16(data, at)
		if !FontShape.fits(at, 2 + 2 * count, data.len()) {
			Err(Bad)
		} else {
			Ok(FontShape.indices(0, count).map(|k| FontShape.u16(data, at + 2 + 2 * k)))
		}
	}

	# A count at `at` followed by offsets (from `base`) to coverage tables.
	read_coverages : List(U8), U64, U64 -> Try(List(Ranges), [Bad])
	read_coverages = |data, base, at| {
		offsets = FontShape.read_u16s(data, at)?
		offsets.map_try(|o| FontShape.read_coverage(data, base + o))
	}

	read_records : List(U8), U64 -> Try(List({ at : U64, lookup : U64 }), [Bad])
	read_records = |data, at| FontShape.read_record_list(data, at + 2, FontShape.u16(data, at))

	read_record_list : List(U8), U64, U64 -> Try(List({ at : U64, lookup : U64 }), [Bad])
	read_record_list = |data, at, count|
		if !FontShape.fits(at, 4 * count, data.len()) {
			Err(Bad)
		} else {
			Ok(FontShape.indices(0, count).map(|k| { at: FontShape.u16(data, at + 4 * k), lookup: FontShape.u16(data, at + 4 * k + 2) }))
		}

	## A coverage table as sorted ranges of glyphs with their first index.
	read_coverage : List(U8), U64 -> Try(Ranges, [Bad])
	read_coverage = |data, at| {
		format = FontShape.u16(data, at)
		count = FontShape.u16(data, at + 2)
		if format == 1 and FontShape.fits(at, 4 + 2 * count, data.len()) {
			var $out = []
			for i in 0..<count {
				g = FontShape.u16(data, at + 4 + 2 * i)
				$out = match $out.last() {
					Ok(last) if last.last + 1 == g and last.index + (last.last - last.first) + 1 == i => $out.set($out.len() - 1, { first: last.first, last: g, index: last.index }) ?? []
					_ => $out.append({ first: g, last: g, index: i })
				}
			}
			Ok($out)
		} else if format == 2 and FontShape.fits(at, 4 + 6 * count, data.len()) {
			FontShape.read_range_records(data, at + 4, count)
		} else {
			Err(Bad)
		}
	}

	## A class definition as sorted ranges whose `index` is the class.
	read_classes : List(U8), U64 -> Try(Ranges, [Bad])
	read_classes = |data, at| {
		format = FontShape.u16(data, at)
		if format == 1 and FontShape.fits(at, 6, data.len()) {
			start = FontShape.u16(data, at + 2)
			count = FontShape.u16(data, at + 4)
			if FontShape.fits(at + 6, 2 * count, data.len()) {
				Ok(FontShape.indices(0, count).map(|k| { first: start + k, last: start + k, index: FontShape.u16(data, at + 6 + 2 * k) }))
			} else {
				Err(Bad)
			}
		} else if format == 2 and FontShape.fits(at, 4, data.len()) {
			count = FontShape.u16(data, at + 2)
			if FontShape.fits(at + 4, 6 * count, data.len()) {
				FontShape.read_range_records(data, at + 4, count)
			} else {
				Err(Bad)
			}
		} else {
			Err(Bad)
		}
	}

	# Range records (first, last, value), which must be in increasing order.
	read_range_records : List(U8), U64, U64 -> Try(Ranges, [Bad])
	read_range_records = |data, at, count| {
		var $out = List.with_capacity(count)
		var $ok = True
		var $previous = 0
		for i in 0..<count {
			r = at + 6 * i
			first = FontShape.u16(data, r)
			last = FontShape.u16(data, r + 2)
			if last < first or (i > 0 and first <= $previous) {
				$ok = False
			}
			$out = $out.append({ first, last, index: FontShape.u16(data, r + 4) })
			$previous = last
		}
		if ($ok) Ok($out) else Err(Bad)
	}
}
