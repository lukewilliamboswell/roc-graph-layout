import FontTest

## Glyph substitution from a font's `GSUB` table: the ligatures, local
## forms and contextual alternates a browser applies by default to
## left-to-right text (features `rvrn`, `ltra`, `ltrm`, `ccmp`, `locl`,
## `rlig`, `liga`, `clig`, `calt` and `rclt`, for the Latin script's
## default language or the default script's). They change which glyphs
## draw a run of text, and so its width: Inter, for example, draws `->` as
## one arrow glyph and raises an asterisk next to capitals.
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
	feature_tags = ["rvrn", "ltra", "ltrm", "ccmp", "locl", "rlig", "liga", "clig", "calt", "rclt"]

	# ------------------------------------------------------------ applying

	## Apply the default features to a run, lookup by lookup. Each lookup
	## passes over the run once, left to right, writing a new run.
	##
	## Two bounds keep a hostile font from making this expensive: a run never
	## grows past `4 n + 32` glyphs for `n` input glyphs, and lookups called
	## from contextual rules (which may call further lookups, up to 8 deep)
	## are applied at most `64 n + 16384` times in all; past that, contextual
	## rules match but change nothing.
	apply : FontShape, List(Item) -> List(Item)
	apply = |shape, items| {
		limit = 4 * items.len() + 32
		budget = 64 * items.len() + 16384
		var $input = items
		var $ops = 0
		for index in shape.active {
			subtables = shape.lookups.get(index) ?? []
			var $out = List.with_capacity($input.len())
			var $i = 0
			while $i < $input.len() {
				done = FontShape.step(shape, subtables, $out, $input, $i, limit, { ops: $ops, budget })
				$ops = done.ops
				if done.applied {
					$out = $out.concat(done.emit)
					$i = done.next
				} else {
					$out = $out.append($input.get($i) ?? { glyph: 0, cluster: 0 })
					$i = $i + 1
				}
			}
			$input = $out
		}
		$input
	}

	# The first subtable that applies at `i`: what it writes and where reading
	# continues. Backtrack context is read from what has been written.
	step : FontShape, List(Subtable), List(Item), List(Item), U64, U64, { ops : U64, budget : U64 } -> { applied : Bool, emit : List(Item), next : U64, ops : U64 }
	step = |shape, subtables, out, input, i, limit, count| {
		item = input.get(i) ?? { glyph: 0, cluster: 0 }
		skipped = { applied: False, emit: [], next: i, ops: count.ops }
		var $result = skipped
		var $k = 0
		while $k < subtables.len() {
			outcome = match subtables.get($k) {
				Ok(Single(s)) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => { applied: True, emit: [{ glyph: FontShape.single(s.delta, s.glyphs, at, item.glyph), cluster: item.cluster }], next: i + 1, ops: count.ops }
						Err(_) => skipped
					}
				Ok(Multiple(s)) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => {
							sequence = s.sequences.get(at) ?? [item.glyph]
							if out.len() + sequence.len() + (input.len() - i) > limit + 1 {
								skipped
							} else {
								{ applied: True, emit: sequence.map(|g| { glyph: g, cluster: item.cluster }), next: i + 1, ops: count.ops }
							}
						}
						Err(_) => skipped
					}
				Ok(Ligature(s)) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) =>
							match FontShape.ligature_at(s.sets.get(at) ?? [], input, i) {
								Found(found) => { applied: True, emit: [{ glyph: found.glyph, cluster: item.cluster }], next: i + 1 + found.count, ops: count.ops }
								NotFound => skipped
							}
						Err(_) => skipped
					}
				Ok(Context(s)) =>
					match FontShape.rule_at(s, out, out.len(), input, i) {
						Found(rule) => {
							window = input.sublist({ start: i, len: rule.input.len() + 1 })
							# The window may grow only as far as the whole run may.
							taken = out.len() + (input.len() - i - window.len())
							room = if (limit >= taken) limit - taken else 0
							done = FontShape.substitute(shape, rule.records, window.len(), window, 0, 1, room, count)
							{ applied: True, emit: done.buffer, next: i + window.len(), ops: done.ops }
						}
						NotFound => skipped
					}
				Err(_) => skipped
			}
			if outcome.applied {
				$result = outcome
				$k = subtables.len()
			} else {
				$k = $k + 1
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
	apply_lookup : FontShape, U64, List(Item), U64, U64, U64, { ops : U64, budget : U64 } -> { applied : Bool, buffer : List(Item), next : U64, ops : U64 }
	apply_lookup = |shape, index, buffer, i, depth, limit, count| {
		subtables = shape.lookups.get(index) ?? []
		var $result = { applied: False, buffer, next: i, ops: count.ops }
		var $k = 0
		while $k < subtables.len() {
			outcome = match subtables.get($k) {
				Ok(subtable) => FontShape.apply_subtable(shape, subtable, buffer, i, depth, limit, count)
				Err(_) => { applied: False, buffer, next: i, ops: count.ops }
			}
			if outcome.applied {
				$result = outcome
				$k = subtables.len()
			} else {
				$k = $k + 1
			}
		}
		$result
	}

	apply_subtable : FontShape, Subtable, List(Item), U64, U64, U64, { ops : U64, budget : U64 } -> { applied : Bool, buffer : List(Item), next : U64, ops : U64 }
	apply_subtable = |shape, subtable, buffer, i, depth, limit, count| {
		item = buffer.get(i) ?? { glyph: 0, cluster: 0 }
		skipped = { applied: False, buffer, next: i, ops: count.ops }
		if i >= buffer.len() {
			skipped
		} else {
			match subtable {
				Single(s) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => {
							glyph = FontShape.single(s.delta, s.glyphs, at, item.glyph)
							# `i` is in bounds (checked above).
							{ applied: True, buffer: buffer.set(i, { glyph, cluster: item.cluster }) ?? [], next: i + 1, ops: count.ops }
						}
						Err(_) => skipped
					}
				Multiple(s) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) => {
							sequence = s.sequences.get(at) ?? [item.glyph]
							if buffer.len() + sequence.len() > limit + 1 {
								skipped
							} else {
								replaced = buffer
									.take_first(i)
									.concat(sequence.map(|g| { glyph: g, cluster: item.cluster }))
									.concat(buffer.drop_first(i + 1))
								{ applied: True, buffer: replaced, next: i + sequence.len(), ops: count.ops }
							}
						}
						Err(_) => skipped
					}
				Ligature(s) =>
					match FontShape.covered(s.coverage, item.glyph) {
						Ok(at) =>
							match FontShape.ligature_at(s.sets.get(at) ?? [], buffer, i) {
								Found(found) => {
									replaced = buffer.take_first(i).append({ glyph: found.glyph, cluster: item.cluster }).concat(buffer.drop_first(i + 1 + found.count))
									{ applied: True, buffer: replaced, next: i + 1, ops: count.ops }
								}
								NotFound => skipped
							}
						Err(_) => skipped
					}
				Context(s) =>
					match FontShape.rule_at(s, buffer, i, buffer, i) {
						Found(rule) => {
							done = FontShape.substitute(shape, rule.records, rule.input.len() + 1, buffer, i, depth, limit, count)
							{ applied: True, buffer: done.buffer, next: done.next, ops: done.ops }
						}
						NotFound => skipped
					}
			}
		}
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
	# it. Each nested lookup applied counts against the run's budget.
	substitute : FontShape, List({ at : U64, lookup : U64 }), U64, List(Item), U64, U64, U64, { ops : U64, budget : U64 } -> { buffer : List(Item), next : U64, ops : U64 }
	substitute = |shape, records, matched, buffer, i, depth, limit, count| {
		var $buffer = buffer
		var $length = matched
		var $ops = count.ops
		if depth < 8 {
			for record in records {
				if record.at < $length and $ops < count.budget {
					$ops = $ops + 1
					before = $buffer.len()
					done = FontShape.apply_lookup(shape, record.lookup, $buffer, i + record.at, depth + 1, limit, { ops: $ops, budget: count.budget })
					$ops = done.ops
					if done.applied {
						$buffer = done.buffer
						grown = $buffer.len() + $length
						$length = if (grown >= before) grown - before else 0
					}
				}
			}
		}
		{ buffer: $buffer, next: i + $length.max(1), ops: $ops }
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

	## Reading work is counted in steps: one per table visited and one per
	## entry read. Offsets may point many times at the same data, so a few
	## bytes could otherwise describe billions of entries; a table that takes
	## more than eight steps per byte (plus a fixed allowance) is refused.
	## `spend` adds a visit costing `cost` entries to `steps`, failing when
	## the table's allowance is exceeded. Checking happens before the entries
	## are read, so refusing is cheap.
	spend : List(U8), U64, U64 -> Try(U64, [Bad])
	spend = |data, steps, cost| {
		total = steps + cost + 1
		if (total > 8 * data.len() + 16384) Err(Bad) else Ok(total)
	}

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
				var $steps = FontShape.spend(gsub, 0, chosen.len())?
				var $active = List.repeat(False, lookup_count)
				for f in chosen {
					if f < feature_count {
						record = features + 2 + 6 * f
						if wanted.contains(FontShape.u32(gsub, record)) {
							feature = features + FontShape.u16(gsub, record + 4)
							count = FontShape.u16(gsub, feature + 2)
							if !FontShape.fits(feature, 4 + 2 * count, gsub.len()) {
								return Err(Bad)
							}
							$steps = FontShape.spend(gsub, $steps, count)?
							for j in 0..<count {
								index = FontShape.u16(gsub, feature + 4 + 2 * j)
								if index < lookup_count {
									# `index < lookup_count`, the length of `$active`.
									$active = $active.set(index, True) ?? []
								}
							}
						}
					} else {
						return Err(Bad)
					}
				}
				start = FontShape.indices(0, lookup_count).keep_if(|index| $active.get(index) ?? False)
				# Read the chosen lookups and those their rules call.
				var $parsed = List.repeat([], lookup_count)
				var $seen = List.repeat(False, lookup_count)
				var $pending = start
				while !$pending.is_empty() {
					index = $pending.last() ?? 0
					$pending = $pending.drop_last(1)
					if !($seen.get(index) ?? True) {
						# Every pending index is below `lookup_count`.
						$seen = $seen.set(index, True) ?? []
						lookup = lookups + FontShape.u16(gsub, lookups + 2 + 2 * index)
						done = FontShape.read_lookup(gsub, lookup, $steps)?
						subtables = done.value
						$steps = done.steps
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
				Ok({ lookups: $parsed, active: start })
			}
		}
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

	read_lookup : List(U8), U64, U64 -> Try({ value : List(Subtable), steps : U64 }, [Bad])
	read_lookup = |data, lookup, steps| {
		kind = FontShape.u16(data, lookup)
		count = FontShape.u16(data, lookup + 4)
		if !FontShape.fits(lookup, 6 + 2 * count, data.len()) {
			Err(Bad)
		} else {
			var $steps = FontShape.spend(data, steps, count)?
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
				done = FontShape.read_subtable(data, real.kind, real.at, $steps)?
				$steps = done.steps
				match done.value {
					Some(subtable) => {
						$subtables = $subtables.append(subtable)
					}
					None => {}
				}
			}
			Ok({ value: $subtables, steps: $steps })
		}
	}

	read_subtable : List(U8), U64, U64, U64 -> Try({ value : [Some(Subtable), None], steps : U64 }, [Bad])
	read_subtable = |data, kind, at, steps| {
		if !FontShape.fits(at, 6, data.len()) {
			Err(Bad)
		} else {
			format = FontShape.u16(data, at)
			if kind == 1 {
				got = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2), steps)?
				coverage = got.value
				after = got.steps
				if format == 1 {
					raw = FontShape.u16(data, at + 4).to_i64_wrap()
					delta = if (raw >= 32768) raw - 65536 else raw
					Ok({ value: Some(Single({ coverage, delta, glyphs: [] })), steps: after })
				} else if format == 2 {
					glyphs = FontShape.read_u16s(data, at + 4, after)?
					list = glyphs.value
					total = glyphs.steps
					Ok({ value: Some(Single({ coverage, delta: 0, glyphs: list })), steps: total })
				} else {
					Err(Bad)
				}
			} else if kind == 2 and format == 1 {
				got = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2), steps)?
				coverage = got.value
				offsets = FontShape.read_u16s(data, at + 4, got.steps)?
				var $steps = offsets.steps
				var $sequences = []
				for o in offsets.value {
					sequence = FontShape.read_u16s(data, at + o, $steps)?
					$steps = sequence.steps
					$sequences = $sequences.append(sequence.value)
				}
				Ok({ value: Some(Multiple({ coverage, sequences: $sequences })), steps: $steps })
			} else if kind == 4 and format == 1 {
				got = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2), steps)?
				coverage = got.value
				offsets = FontShape.read_u16s(data, at + 4, got.steps)?
				var $steps = offsets.steps
				var $sets = []
				for o in offsets.value {
					set = at + o
					ligatures = FontShape.read_u16s(data, set, $steps)?
					$steps = ligatures.steps
					var $ligatures = []
					for l in ligatures.value {
						lig = set + l
						count = FontShape.u16(data, lig + 2)
						if count == 0 or !FontShape.fits(lig, 2 + 2 * count, data.len()) {
							return Err(Bad)
						}
						$steps = FontShape.spend(data, $steps, count)?
						$ligatures = $ligatures.append({ glyph: FontShape.u16(data, lig), rest: FontShape.indices(1, count).map(|k| FontShape.u16(data, lig + 2 + 2 * k)) })
					}
					$sets = $sets.append($ligatures)
				}
				Ok({ value: Some(Ligature({ coverage, sets: $sets })), steps: $steps })
			} else if kind == 5 or kind == 6 {
				done = FontShape.read_context(data, kind == 6, format, at, steps)?
				subtable = done.value
				after = done.steps
				Ok({ value: Some(subtable), steps: after })
			} else {
				# Alternate (3) and reverse chaining (8) substitutions are not
				# applied by default.
				Ok({ value: None, steps })
			}
		}
	}

	read_context : List(U8), Bool, U64, U64, U64 -> Try({ value : Subtable, steps : U64 }, [Bad])
	read_context = |data, chained, format, at, steps| {
		empty = []
		if format == 3 {
			if chained {
				back = FontShape.read_coverages(data, at, at + 2, steps)?
				input_at = at + 4 + 2 * back.value.len()
				input = FontShape.read_coverages(data, at, input_at, back.steps)?
				ahead_at = input_at + 2 + 2 * input.value.len()
				ahead = FontShape.read_coverages(data, at, ahead_at, input.steps)?
				records = FontShape.read_records(data, ahead_at + 2 + 2 * ahead.value.len(), ahead.steps)?
				backs = back.value
				inputs = input.value
				aheads = ahead.value
				nested = records.value
				after = records.steps
				first = inputs.first() ?? []
				if inputs.is_empty() {
					Err(Bad)
				} else {
					rule = { back: backs.map(|c| Covered(c)), input: inputs.drop_first(1).map(|c| Covered(c)), ahead: aheads.map(|c| Covered(c)), records: nested }
					Ok({ value: Context({ coverage: first, by_class: False, back_classes: empty, input_classes: empty, ahead_classes: empty, sets: [[rule]] }), steps: after })
				}
			} else {
				count = FontShape.u16(data, at + 2)
				record_count = FontShape.u16(data, at + 4)
				if count == 0 or !FontShape.fits(at, 6 + 2 * count, data.len()) {
					Err(Bad)
				} else {
					var $steps = steps
					var $input = []
					for k in 0..<count {
						coverage = FontShape.read_coverage(data, at + FontShape.u16(data, at + 6 + 2 * k), $steps)?
						$steps = coverage.steps
						$input = $input.append(coverage.value)
					}
					records = FontShape.read_record_list(data, at + 6 + 2 * count, record_count, $steps)?
					nested = records.value
					after = records.steps
					rule = { back: [], input: $input.drop_first(1).map(|c| Covered(c)), ahead: [], records: nested }
					Ok({ value: Context({ coverage: $input.first() ?? [], by_class: False, back_classes: empty, input_classes: empty, ahead_classes: empty, sets: [[rule]] }), steps: after })
				}
			}
		} else if format == 1 or format == 2 {
			got = FontShape.read_coverage(data, at + FontShape.u16(data, at + 2), steps)?
			coverage = got.value
			var $steps = got.steps
			by_class = format == 2
			# Offsets to class definitions, then to the rule sets. A null
			# offset (allowed for backtrack and lookahead classes) puts every
			# glyph in class 0.
			class_offsets = if (!by_class) [] else if (chained) [4, 6, 8] else [4]
			var $classes = []
			for o in class_offsets {
				offset = FontShape.u16(data, at + o)
				if offset == 0 {
					$classes = $classes.append([])
				} else {
					classes = FontShape.read_classes(data, at + offset, $steps)?
					$steps = classes.steps
					$classes = $classes.append(classes.value)
				}
			}
			sets_at = at + 4 + 2 * class_offsets.len()
			offsets = FontShape.read_u16s(data, sets_at, $steps)?
			$steps = offsets.steps
			kind = |g| if (by_class) Class(g) else Glyph(g)
			var $sets = []
			for o in offsets.value {
				if o == 0 {
					$sets = $sets.append([])
				} else {
					set = at + o
					rules = FontShape.read_u16s(data, set, $steps)?
					$steps = rules.steps
					var $rules = []
					for r in rules.value {
						rule = FontShape.read_rule(data, chained, set + r, kind, $steps)?
						$steps = rule.steps
						$rules = $rules.append(rule.value)
					}
					$sets = $sets.append($rules)
				}
			}
			input_classes = if (chained) ($classes.get(1) ?? []) else ($classes.get(0) ?? [])
			Ok({ value: Context({ coverage, by_class, back_classes: $classes.get(0) ?? [], input_classes, ahead_classes: $classes.get(2) ?? [], sets: $sets }), steps: $steps })
		} else {
			Err(Bad)
		}
	}

	read_rule : List(U8), Bool, U64, (U64 -> Match), U64 -> Try({ value : Rule, steps : U64 }, [Bad])
	read_rule = |data, chained, at, kind, steps| {
		if chained {
			back = FontShape.read_u16s(data, at, steps)?
			input_at = at + 2 + 2 * back.value.len()
			input_count = FontShape.u16(data, input_at)
			if input_count == 0 or !FontShape.fits(input_at, 2 + 2 * (input_count - 1), data.len()) {
				Err(Bad)
			} else {
				counted = FontShape.spend(data, back.steps, input_count)?
				input = FontShape.indices(1, input_count).map(|k| FontShape.u16(data, input_at + 2 * k))
				ahead_at = input_at + 2 * input_count
				ahead = FontShape.read_u16s(data, ahead_at, counted)?
				records = FontShape.read_records(data, ahead_at + 2 + 2 * ahead.value.len(), ahead.steps)?
				backs = back.value
				aheads = ahead.value
				nested = records.value
				after = records.steps
				Ok({ value: { back: backs.map(kind), input: input.map(kind), ahead: aheads.map(kind), records: nested }, steps: after })
			}
		} else {
			input_count = FontShape.u16(data, at)
			record_count = FontShape.u16(data, at + 2)
			if input_count == 0 or !FontShape.fits(at, 4 + 2 * (input_count - 1), data.len()) {
				Err(Bad)
			} else {
				counted = FontShape.spend(data, steps, input_count)?
				input = FontShape.indices(1, input_count).map(|k| FontShape.u16(data, at + 2 + 2 * k))
				records = FontShape.read_record_list(data, at + 2 + 2 * input_count, record_count, counted)?
				nested = records.value
				after = records.steps
				Ok({ value: { back: [], input: input.map(kind), ahead: [], records: nested }, steps: after })
			}
		}
	}

	indices : U64, U64 -> List(U64)
	indices = |start, end| {
		var $out = List.with_capacity(if (end > start) end - start else 0)
		var $k = start
		while $k < end {
			$out = $out.append($k)
			$k = $k + 1
		}
		$out
	}

	# A count followed by that many 16-bit values.
	read_u16s : List(U8), U64, U64 -> Try({ value : List(U64), steps : U64 }, [Bad])
	read_u16s = |data, at, steps| {
		count = FontShape.u16(data, at)
		if !FontShape.fits(at, 2 + 2 * count, data.len()) {
			Err(Bad)
		} else {
			after = FontShape.spend(data, steps, count)?
			Ok({ value: FontShape.indices(0, count).map(|k| FontShape.u16(data, at + 2 + 2 * k)), steps: after })
		}
	}

	# A count at `at` followed by offsets (from `base`) to coverage tables.
	read_coverages : List(U8), U64, U64, U64 -> Try({ value : List(Ranges), steps : U64 }, [Bad])
	read_coverages = |data, base, at, steps| {
		offsets = FontShape.read_u16s(data, at, steps)?
		var $steps = offsets.steps
		var $out = []
		for o in offsets.value {
			coverage = FontShape.read_coverage(data, base + o, $steps)?
			$steps = coverage.steps
			$out = $out.append(coverage.value)
		}
		Ok({ value: $out, steps: $steps })
	}

	read_records : List(U8), U64, U64 -> Try({ value : List({ at : U64, lookup : U64 }), steps : U64 }, [Bad])
	read_records = |data, at, steps| FontShape.read_record_list(data, at + 2, FontShape.u16(data, at), steps)

	read_record_list : List(U8), U64, U64, U64 -> Try({ value : List({ at : U64, lookup : U64 }), steps : U64 }, [Bad])
	read_record_list = |data, at, count, steps|
		if !FontShape.fits(at, 4 * count, data.len()) {
			Err(Bad)
		} else {
			after = FontShape.spend(data, steps, count)?
			Ok({ value: FontShape.indices(0, count).map(|k| { at: FontShape.u16(data, at + 4 * k), lookup: FontShape.u16(data, at + 4 * k + 2) }), steps: after })
		}

	## A coverage table as ranges of glyphs with their first coverage index.
	read_coverage : List(U8), U64, U64 -> Try({ value : Ranges, steps : U64 }, [Bad])
	read_coverage = |data, at, steps| {
		format = FontShape.u16(data, at)
		count = FontShape.u16(data, at + 2)
		if format == 1 and FontShape.fits(at, 4 + 2 * count, data.len()) {
			after = FontShape.spend(data, steps, count)?
			var $out = []
			for i in 0..<count {
				g = FontShape.u16(data, at + 4 + 2 * i)
				$out = match $out.last() {
					Ok(last) if last.last + 1 == g and last.index + (last.last - last.first) + 1 == i => $out.set($out.len() - 1, { first: last.first, last: g, index: last.index }) ?? []
					_ => $out.append({ first: g, last: g, index: i })
				}
			}
			Ok({ value: $out, steps: after })
		} else if format == 2 and FontShape.fits(at, 4 + 6 * count, data.len()) {
			after = FontShape.spend(data, steps, count)?
			ranges = FontShape.read_range_records(data, at + 4, count)
			Ok({ value: ranges, steps: after })
		} else {
			Err(Bad)
		}
	}

	## A class definition as ranges whose `index` is the class.
	read_classes : List(U8), U64, U64 -> Try({ value : Ranges, steps : U64 }, [Bad])
	read_classes = |data, at, steps| {
		format = FontShape.u16(data, at)
		if format == 1 and FontShape.fits(at, 6, data.len()) {
			start = FontShape.u16(data, at + 2)
			count = FontShape.u16(data, at + 4)
			if FontShape.fits(at + 6, 2 * count, data.len()) {
				after = FontShape.spend(data, steps, count)?
				Ok({ value: FontShape.indices(0, count).map(|k| { first: start + k, last: start + k, index: FontShape.u16(data, at + 6 + 2 * k) }), steps: after })
			} else {
				Err(Bad)
			}
		} else if format == 2 and FontShape.fits(at, 4, data.len()) {
			count = FontShape.u16(data, at + 2)
			if FontShape.fits(at + 4, 6 * count, data.len()) {
				after = FontShape.spend(data, steps, count)?
				ranges = FontShape.read_range_records(data, at + 4, count)
				Ok({ value: ranges, steps: after })
			} else {
				Err(Bad)
			}
		} else {
			Err(Bad)
		}
	}

	# Range records (first, last, value). They should be in increasing order
	# without overlaps, and lookups by binary search assume so, but they are
	# not checked: some fonts in use break the rule, and browsers read them
	# anyway. A range whose last glyph comes before its first matches no
	# glyph.
	read_range_records : List(U8), U64, U64 -> Ranges
	read_range_records = |data, at, count|
		FontShape.indices(0, count).map(
			|i| {
				r = at + 6 * i
				{ first: FontShape.u16(data, r), last: FontShape.u16(data, r + 2), index: FontShape.u16(data, r + 4) }
			},
		)
}

# ------------------------------------------------------------ test helpers
#
# Each test builds a `GSUB` table with `FontTest` and shapes a run of glyph
# indices. Glyph indices are arbitrary numbers here; no font is needed.

items_of : List(U64) -> List(FontShape.Item)
items_of = |glyphs| glyphs.map_with_index(|glyph, i| { glyph, cluster: i })

# The glyphs of a shaped run, or [99999] when the table cannot be read.
shaped : List(U8), List(U64) -> List(U64)
shaped = |gsub, glyphs|
	match FontShape.read(gsub) {
		Ok(shape) => FontShape.apply(shape, items_of(glyphs)).map(|item| item.glyph)
		Err(_) => [99999]
	}

shaped_items : List(U8), List(U64) -> List(FontShape.Item)
shaped_items = |gsub, glyphs|
	match FontShape.read(gsub) {
		Ok(shape) => FontShape.apply(shape, items_of(glyphs))
		Err(_) => []
	}

readable : List(U8) -> Bool
readable = |gsub| FontShape.read(gsub).is_ok()

# A table whose `calt` feature uses the first lookup; the others are only
# reached from it.
first_active : List({ kind : U64, subtables : List(List(U8)) }) -> List(U8)
first_active = |lookups| FontTest.layout("latn", [{ tag: "calt", lookups: [0] }], lookups)

# A table whose `liga` feature uses every lookup.
all_active : List({ kind : U64, subtables : List(List(U8)) }) -> List(U8)
all_active = |lookups| FontTest.layout("latn", [{ tag: "liga", lookups: FontTest.counting(lookups.len()) }], lookups)

# Lookup 1 adds 10, lookup 2 replaces 2 by 20 and 3 by 30, for the context
# tests.
called_lookups : List({ kind : U64, subtables : List(List(U8)) })
called_lookups = [{ kind: 1, subtables: [FontTest.single1(FontTest.counting(40), 10)] }, { kind: 1, subtables: [FontTest.single2([2, 3], [20, 30])] }]

# ------------------------------------------------------------ single

expect shaped(all_active([{ kind: 1, subtables: [FontTest.single1([5, 6], 10)] }]), [5, 6, 7, 4]) == [15, 16, 7, 4]

# Deltas wrap modulo 65536.
expect shaped(all_active([{ kind: 1, subtables: [FontTest.single1([5], -6)] }]), [5]) == [65535]
expect shaped(all_active([{ kind: 1, subtables: [FontTest.single1([65535], 2)] }]), [65535]) == [1]

expect shaped(all_active([{ kind: 1, subtables: [FontTest.single2([5, 7], [50, 70])] }]), [5, 6, 7]) == [50, 6, 70]

# A coverage of format 2 (ranges with their first coverage index).
expect {
	shaped(all_active([{ kind: 1, subtables: [FontTest.pack([U16(2), Ref(FontTest.coverage2([{ first: 3, last: 4, index: 0 }, { first: 8, last: 8, index: 2 }])), U16(3), U16(30), U16(40), U16(80)])] }]), [3, 4, 5, 8, 9]) == [30, 40, 5, 80, 9]
}

# The first subtable that covers a glyph decides it.
expect shaped(all_active([{ kind: 1, subtables: [FontTest.single2([5], [50]), FontTest.single1([5, 6], 100)] }]), [5, 6]) == [50, 106]

# Clusters are kept.
expect shaped_items(all_active([{ kind: 1, subtables: [FontTest.single1([5], 1)] }]), [5, 5]) == [{ glyph: 6, cluster: 0 }, { glyph: 6, cluster: 1 }]

# ------------------------------------------------------------ multiple

expect shaped_items(all_active([{ kind: 2, subtables: [FontTest.multiple([5], [[1, 2, 3]])] }]), [4, 5, 6]) == [{ glyph: 4, cluster: 0 }, { glyph: 1, cluster: 1 }, { glyph: 2, cluster: 1 }, { glyph: 3, cluster: 1 }, { glyph: 6, cluster: 2 }]

# An empty sequence deletes the glyph.
expect shaped(all_active([{ kind: 2, subtables: [FontTest.multiple([5], [[]])] }]), [4, 5, 6]) == [4, 6]

# A run never grows past 4 n + 32 glyphs.
expect {
	result = shaped(all_active([{ kind: 2, subtables: [FontTest.multiple([1], [List.repeat(2, 100)])] }]), List.repeat(1, 10))
	result.len() <= 4 * 10 + 32 and result.len() >= 10
}

# ------------------------------------------------------------ ligature

ligature_table : List(U8)
ligature_table = all_active([{ kind: 4, subtables: [FontTest.ligature([1], [[{ glyph: 9, rest: [2, 3] }, { glyph: 8, rest: [2] }]])] }])

# The first ligature of the set that matches wins; an incomplete one at the
# end of the run does not apply.
expect shaped(ligature_table, [1, 2, 3]) == [9]
expect shaped(ligature_table, [1, 2, 4]) == [8, 4]
expect shaped(ligature_table, [1, 2]) == [8]
expect shaped(ligature_table, [1]) == [1]
expect shaped(ligature_table, [0, 1, 2, 3, 1, 2, 3]) == [0, 9, 9]
expect shaped_items(ligature_table, [7, 1, 2, 4]) == [{ glyph: 7, cluster: 0 }, { glyph: 8, cluster: 1 }, { glyph: 4, cluster: 3 }]

# A ligature with no components is a bad table.
expect !readable(all_active([{ kind: 4, subtables: [FontTest.pack([U16(1), Ref(FontTest.coverage1([1])), U16(1), Ref(FontTest.pack([U16(1), Ref(FontTest.pack([U16(9), U16(0)]))]))])] }]))

# ------------------------------------------------------------ context

# Format 1: glyph 1 then 2: add 10 to the first and replace the second.
expect {
	gsub = first_active([{ kind: 5, subtables: [FontTest.context1([1], [[FontTest.rule([2], [{ at: 0, lookup: 1 }, { at: 1, lookup: 2 }])]])] }].concat(called_lookups))
	shaped(gsub, [1, 2, 1, 3, 2]) == [11, 20, 1, 3, 2]
}

# Rules are tried in order; the first that matches applies.
expect {
	gsub = first_active([{ kind: 5, subtables: [FontTest.context1([1], [[FontTest.rule([3], [{ at: 0, lookup: 1 }]), FontTest.rule([2], [{ at: 1, lookup: 2 }])]])] }].concat(called_lookups))
	shaped(gsub, [1, 2, 1, 3]) == [1, 20, 11, 3]
}

# Format 2: glyphs 1 and 2 are class 1, glyph 3 class 2. Class 1 followed
# by class 2: add 10 to the class 2 glyph. Class 0 has no rules.
expect {
	classes = FontTest.classes1(1, [1, 1, 2])
	gsub = first_active([{ kind: 5, subtables: [FontTest.context2([1, 2, 3], classes, [[], [FontTest.rule([2], [{ at: 1, lookup: 1 }])]])] }].concat(called_lookups))
	shaped(gsub, [1, 3, 2, 3, 3, 4, 3]) == [1, 13, 2, 13, 3, 4, 3]
}

# Format 3: a coverage per position.
expect {
	gsub = first_active([{ kind: 5, subtables: [FontTest.context3([[1, 2], [3]], [{ at: 0, lookup: 1 }])] }].concat(called_lookups))
	shaped(gsub, [2, 3, 1, 1, 3]) == [12, 3, 1, 11, 3]
}

# Context of format 3 with no input is a bad table.
expect !readable(first_active([{ kind: 5, subtables: [FontTest.context3([], [])] }]))

# ------------------------------------------------------------ chained context

# Format 1: after 7, the pair 1 2, before 3: add 10 to the 2.
chained_glyphs : List(U8)
chained_glyphs = first_active([{ kind: 6, subtables: [FontTest.chain1([1], [[FontTest.chain_rule([7], [2], [3], [{ at: 1, lookup: 1 }])]])] }].concat(called_lookups))

expect shaped(chained_glyphs, [7, 1, 2, 3]) == [7, 1, 12, 3]
expect shaped(chained_glyphs, [1, 2, 3]) == [1, 2, 3]
expect shaped(chained_glyphs, [7, 1, 2, 4]) == [7, 1, 2, 4]
expect shaped(chained_glyphs, [7, 1, 2]) == [7, 1, 2]

# Backtrack is listed nearest first.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain1([1], [[FontTest.chain_rule([7, 8], [], [], [{ at: 0, lookup: 1 }])]])] }].concat(called_lookups))
	shaped(gsub, [8, 7, 1, 7, 8, 1]) == [8, 7, 11, 7, 8, 1]
}

# Backtrack reads the glyphs already substituted by the same lookup.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain3([[11]], [[1]], [], [{ at: 0, lookup: 1 }])] }, { kind: 1, subtables: [FontTest.single1([1], 10)] }])
	shaped(gsub, [11, 1, 1, 1]) == [11, 11, 11, 11]
}

# Format 2: glyph 7 is backtrack class 1; glyphs 1 and 2 input classes 1
# and 2; glyph 3 lookahead class 1.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain2([1], FontTest.classes1(7, [1]), FontTest.classes2([{ first: 1, last: 1, class: 1 }, { first: 2, last: 2, class: 2 }]), FontTest.classes1(3, [1]), [[], [FontTest.chain_rule([1], [2], [1], [{ at: 0, lookup: 1 }])]])] }].concat(called_lookups))
	shaped(gsub, [7, 1, 2, 3, 8, 1, 2, 3]) == [7, 11, 2, 3, 8, 1, 2, 3]
}

# Format 3: coverages for backtrack, input and lookahead; two lookup
# records.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain3([[7]], [[1], [2]], [[3]], [{ at: 0, lookup: 1 }, { at: 1, lookup: 1 }])] }].concat(called_lookups))
	shaped(gsub, [7, 1, 2, 3, 1, 2, 3]) == [7, 11, 12, 3, 1, 2, 3]
}

# A record that points past the matched input is ignored.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain3([], [[1]], [], [{ at: 5, lookup: 1 }, { at: 0, lookup: 2 }])] }].concat(called_lookups))
	shaped(gsub, [1, 1]) == [1, 1]
}

# A nested ligature shortens the input; a nested multiple substitution
# lengthens it, and later records see the new positions.
expect {
	gsub = first_active([
		{ kind: 6, subtables: [FontTest.chain3([], [[1], [2], [3]], [], [{ at: 0, lookup: 1 }, { at: 1, lookup: 2 }])] },
		{ kind: 4, subtables: [FontTest.ligature([1], [[{ glyph: 9, rest: [2] }]])] },
		{ kind: 1, subtables: [FontTest.single2([3], [30])] },
	])
	shaped(gsub, [1, 2, 3, 4]) == [9, 30, 4]
}
expect {
	gsub = first_active([
		{ kind: 6, subtables: [FontTest.chain3([], [[1], [2]], [], [{ at: 0, lookup: 1 }, { at: 3, lookup: 2 }])] },
		{ kind: 2, subtables: [FontTest.multiple([1], [[5, 5, 5]])] },
		{ kind: 1, subtables: [FontTest.single2([2], [20])] },
	])
	shaped(gsub, [1, 2, 4]) == [5, 5, 5, 20, 4]
}

# ------------------------------------------------------------ extension

expect shaped(all_active([{ kind: 7, subtables: [FontTest.extension(1, FontTest.single1([5], 10))] }]), [5, 6]) == [15, 6]
expect {
	gsub = first_active([{ kind: 7, subtables: [FontTest.extension(6, FontTest.chain3([], [[1]], [[2]], [{ at: 0, lookup: 1 }]))] }, { kind: 7, subtables: [FontTest.extension(1, FontTest.single1([1], 10))] }])
	shaped(gsub, [1, 2, 1]) == [11, 2, 1]
}

# An extension subtable past the table is a bad table.
expect !readable(all_active([{ kind: 7, subtables: [FontTest.pack([U16(1), U16(1), U32(100000)])] }]))

# Alternate (3) and reverse chaining (8) lookups are not applied by
# default; neither is an extension of them.
expect shaped(all_active([{ kind: 3, subtables: [FontTest.single1([5], 10)] }, { kind: 8, subtables: [FontTest.single1([5], 10)] }, { kind: 7, subtables: [FontTest.extension(3, FontTest.single1([5], 10))] }]), [5]) == [5]

# ------------------------------------------------------------ features

# Only the features a browser applies by default to left-to-right text
# apply: not small capitals, discretionary ligatures, right-to-left forms,
# or features of other tables.
expect {
	tags = ["rvrn", "ltra", "ltrm", "ccmp", "locl", "rlig", "liga", "clig", "calt", "rclt", "smcp", "dlig", "rtla", "rtlm", "kern", "mark"]
	lookups = tags.map(|_| { kind: 1, subtables: [FontTest.single1(FontTest.counting(200), 1)] })
	features = tags.map_with_index(|tag, i| { tag, lookups: [i] })
	shaped(FontTest.layout("latn", features, lookups), [5]) == [15]
}

# Lookups apply in lookup order, not feature order; a lookup listed by
# two features applies once.
expect {
	lookups = [{ kind: 1, subtables: [FontTest.single2([5], [6])] }, { kind: 1, subtables: [FontTest.single2([6], [7])] }]
	shaped(FontTest.layout("latn", [{ tag: "liga", lookups: [1, 0] }, { tag: "calt", lookups: [0] }], lookups), [5]) == [7]
}

# The default script is used when there is no Latin one; other scripts are
# not.
expect shaped(FontTest.layout("DFLT", [{ tag: "liga", lookups: [0] }], [{ kind: 1, subtables: [FontTest.single1([5], 1)] }]), [5]) == [6]
expect shaped(FontTest.layout("cyrl", [{ tag: "liga", lookups: [0] }], [{ kind: 1, subtables: [FontTest.single1([5], 1)] }]), [5]) == [5]

# Only the features the default language lists apply, and its required
# feature.
expect {
	lookups = [{ kind: 1, subtables: [FontTest.single1([5], 1)] }, { kind: 1, subtables: [FontTest.single1(FontTest.counting(200), 10)] }]
	features = [{ tag: "liga", lookups: [0] }, { tag: "calt", lookups: [1] }]
	shaped(FontTest.layout_listing("latn", [1], 0xFFFF, features, lookups), [5]) == [15] and shaped(FontTest.layout_listing("latn", [], 0, features, lookups), [5]) == [6]
}

# A listed feature past the feature list is a bad table; a feature's
# lookup past the lookup list is ignored.
expect !readable(FontTest.layout_listing("latn", [3], 0xFFFF, [{ tag: "liga", lookups: [0] }], [{ kind: 1, subtables: [FontTest.single1([5], 1)] }]))
expect shaped(FontTest.layout("latn", [{ tag: "liga", lookups: [0, 7] }], [{ kind: 1, subtables: [FontTest.single1([5], 1)] }]), [5]) == [6]

# A lookup reached only from a rule does not apply on its own; one that a
# rule calls past the lookup list is a bad table.
expect shaped(first_active([{ kind: 5, subtables: [FontTest.context3([[1]], [{ at: 0, lookup: 1 }])] }].concat(called_lookups)), [5, 2]) == [5, 2]
expect !readable(first_active([{ kind: 5, subtables: [FontTest.context3([[1]], [{ at: 0, lookup: 9 }])] }]))

# ------------------------------------------------------------ edge cases

expect shaped(all_active([{ kind: 1, subtables: [FontTest.single1([5], 1)] }]), []) == []
expect FontShape.apply(FontShape.none, items_of([1, 2, 3])) == items_of([1, 2, 3])

# Glyph indices no font has pass through every kind of lookup.
expect {
	gsub = all_active([
		{ kind: 1, subtables: [FontTest.single1([5], 1)] },
		{ kind: 2, subtables: [FontTest.multiple([5], [[1, 2]])] },
		{ kind: 4, subtables: [FontTest.ligature([1], [[{ glyph: 9, rest: [2] }]])] },
		{ kind: 6, subtables: [FontTest.chain3([[1]], [[2]], [[3]], [])] },
	])
	shaped(gsub, [70000, 1000000000, 0xFFFFFFFFFFFFFFFF]) == [70000, 1000000000, 0xFFFFFFFFFFFFFFFF]
}

# Lookups that call themselves stop at a fixed depth.
expect {
	gsub = first_active([{ kind: 5, subtables: [FontTest.context3([FontTest.counting(40)], [{ at: 0, lookup: 0 }, { at: 0, lookup: 1 }])] }].concat(called_lookups))
	result = shaped(gsub, [1])
	result.len() == 1 and result != [99999]
}

## fuzz regression: lookups whose rules call each other many times over
## must not take time exponential in the depth. Each of these rules calls
## its own lookup 50 times; without a limit on nested applications, one
## glyph would take 50^7 of them.
expect {
	calls = List.repeat({ at: 0, lookup: 0 }, 50)
	gsub = first_active([{ kind: 5, subtables: [FontTest.context3([[1]], calls.append({ at: 0, lookup: 1 }))] }, { kind: 1, subtables: [FontTest.single1([1], 0)] }])
	shaped(gsub, [1, 1, 1]) == [1, 1, 1]
}

## fuzz regression: a contextual rule that calls a multiple substitution
## once per input glyph must not grow the run past 4 n + 32 glyphs; each
## rule could otherwise grow its own window to that size.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain3([], [[1]], [], [{ at: 0, lookup: 1 }])] }, { kind: 2, subtables: [FontTest.multiple([1], [List.repeat(2, 60)])] }])
	result = shaped(gsub, List.repeat(1, 20))
	result.len() <= 4 * 20 + 32
}

# Applying is deterministic.
expect {
	gsub = first_active([{ kind: 6, subtables: [FontTest.chain3([[7]], [[1], [2]], [[3]], [{ at: 0, lookup: 1 }, { at: 1, lookup: 2 }])] }].concat(called_lookups))
	shaped(gsub, [7, 1, 2, 3, 7, 1, 2, 3]) == shaped(gsub, [7, 1, 2, 3, 7, 1, 2, 3])
}

# ------------------------------------------------------------ reading

expect !readable([])
expect !readable(List.repeat(0, 9))
expect shaped(List.repeat(0, 10), [5]) == [5]
expect readable(FontTest.layout("latn", [], []))

# Unknown subtable, coverage and class formats, and coverage tables past
# the table.
expect !readable(all_active([{ kind: 1, subtables: [FontTest.patch(FontTest.single1([5], 1), 0, FontTest.u16(3))] }]))
expect !readable(all_active([{ kind: 5, subtables: [FontTest.patch(FontTest.context3([[1]], []), 0, FontTest.u16(4))] }]))
expect !readable(all_active([{ kind: 1, subtables: [FontTest.patch(FontTest.single1([5], 1), 2, FontTest.u16(60000))] }]))
expect !readable(all_active([{ kind: 1, subtables: [FontTest.pack([U16(1), Ref(FontTest.pack([U16(3), U16(0)])), I16(1)])] }]))
expect !readable(first_active([{ kind: 5, subtables: [FontTest.context2([1], FontTest.pack([U16(3)]), [])] }]))

# Coverage and class ranges that overlap or are out of order are read, as
# browsers read them (Noto Sans Adlam Unjoined has a coverage whose ranges
# share a glyph); lookups in them stay total and deterministic.
expect {
	gsub = all_active([{ kind: 1, subtables: [FontTest.pack([U16(1), Ref(FontTest.coverage2([{ first: 1, last: 6, index: 0 }, { first: 6, last: 19, index: 6 }])), I16(100)])] }])
	shaped(gsub, [1, 6, 19, 20]) == [101, 106, 119, 20]
}
expect {
	gsub = all_active([{ kind: 1, subtables: [FontTest.pack([U16(1), Ref(FontTest.coverage2([{ first: 5, last: 9, index: 0 }, { first: 2, last: 3, index: 5 }, { first: 12, last: 11, index: 0 }])), I16(1)])] }])
	result = shaped(gsub, [2, 5, 7, 11, 12])
	result.len() == 5 and result == shaped(gsub, [2, 5, 7, 11, 12])
}
expect readable(first_active([{ kind: 5, subtables: [FontTest.context2([1], FontTest.classes2([{ first: 5, last: 9, class: 1 }, { first: 9, last: 10, class: 2 }]), [])] }]))

## fuzz regression: a chained context of format 2 may leave its backtrack
## and lookahead class definitions out (a null offset), putting every
## glyph in class 0; Noto Music does. Reading the subtable itself as a
## class definition refused the whole table.
expect {
	sets = [U16(0), FontTest.rule_set([FontTest.chain_rule([0], [], [0], [{ at: 0, lookup: 1 }])])]
	subtable = FontTest.pack([U16(2), Ref(FontTest.coverage1([1])), U16(0), Ref(FontTest.classes1(1, [1])), U16(0), U16(2)].concat(sets))
	gsub = first_active([{ kind: 6, subtables: [subtable] }].concat(called_lookups))
	shaped(gsub, [7, 1, 8, 1]) == [7, 11, 8, 1]
}

# Every prefix of a table with every kind of lookup, and every byte of it
# set to 0 or 0xFF, is read or refused; what is read applies without
# growing past the bound.
every_kind : List(U8)
every_kind = FontTest.every_lookup

expect readable(every_kind)

expect {
	var $outcomes = 0
	for n in 0..<every_kind.len() {
		match FontShape.read(every_kind.take_first(n)) {
			Ok(shape) => {
				run = items_of([7, 1, 2, 3, 1, 2])
				$outcomes = $outcomes + (if (FontShape.apply(shape, run).len() <= 4 * 6 + 32) 1 else 1000000)
			}
			Err(_) => {
				$outcomes = $outcomes + 1
			}
		}
	}
	$outcomes == every_kind.len()
}

expect {
	var $outcomes = 0
	for at in 0..<every_kind.len() {
		for value in [0, 1, 0xFF] {
			match FontShape.read(every_kind.set(at, value) ?? []) {
				Ok(shape) => {
					run = items_of([7, 1, 2, 3, 1, 2, 0, 9])
					$outcomes = $outcomes + (if (FontShape.apply(shape, run).len() <= 4 * 8 + 32) 1 else 1000000)
				}
				Err(_) => {
					$outcomes = $outcomes + 1
				}
			}
		}
	}
	$outcomes == 3 * every_kind.len()
}

## fuzz regression: lookups that share one subtable thousands of times are
## refused rather than read thousands of times over.
expect {
	count = 2000
	# A lookup list whose entries all point at one lookup, whose subtable
	# offsets all point at one subtable.
	lookup_list = [U16(count)].concat(List.repeat(U16(2 + 2 * count), count))
	lookup = [U16(1), U16(0), U16(count)].concat(List.repeat(U16(6 + 2 * count), count))
	body = FontTest.pack(lookup_list.concat(lookup)).concat(FontTest.single1(FontTest.counting(10), 1))
	features = FontTest.pack([U16(1), Tag("liga"), U16(8), U16(0), U16(count)].concat(FontTest.counting(count).map(|i| U16(i))))
	language = FontTest.pack([U16(0), U16(0xFFFF), U16(1), U16(0)])
	scripts = FontTest.pack([U16(1), Tag("latn"), Ref(FontTest.pack([Ref(language), U16(0)]))])
	header = FontTest.pack([U32(0x00010000), Ref(scripts), Ref(features), Ref(body)])
	!readable(header)
}

# The same sharing on a small scale is read.
expect {
	count = 3
	lookup_list = [U16(count)].concat(List.repeat(U16(2 + 2 * count), count))
	lookup = [U16(1), U16(0), U16(count)].concat(List.repeat(U16(6 + 2 * count), count))
	body = FontTest.pack(lookup_list.concat(lookup)).concat(FontTest.single1(FontTest.counting(10), 1))
	features = FontTest.pack([U16(1), Tag("liga"), U16(8), U16(0), U16(count)].concat(FontTest.counting(count).map(|i| U16(i))))
	language = FontTest.pack([U16(0), U16(0xFFFF), U16(1), U16(0)])
	scripts = FontTest.pack([U16(1), Tag("latn"), Ref(FontTest.pack([Ref(language), U16(0)]))])
	shaped(FontTest.pack([U32(0x00010000), Ref(scripts), Ref(features), Ref(body)]), [5]) == [8]
}
