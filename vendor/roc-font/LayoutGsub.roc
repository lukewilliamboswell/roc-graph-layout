import Sfnt
import LayoutCommon

## Glyph substitution from a font's `GSUB` table: single, multiple and
## ligature substitutions and contextual rules (lookup types 1, 2, 4, 5, 6
## and 7), applied lookup by lookup as a shaping plan lists them. Which
## lookups apply (the features chosen for a script, language and direction)
## is the plan's business (`Shaper`); this module reads every lookup a
## feature can reach and applies a list of them.
##
## Lookup flags (skipping marks or ligatures) are not interpreted.
##
## The prepared data is flat: every subtable, coverage range, glyph value
## and contextual rule of the font lives in one of five lists, and nested
## structure is expressed by offsets and lengths into them. Reading
## allocates per list, not per ligature or rule, and applying reads only
## scalar records, so looking at a subtable costs no reference counting.
##
## A glyph of a run carries its cluster (the text offset it came from) and
## a mask: one bit per feature group of the plan (a lookup applies at a
## glyph when their masks share a bit) and `unsafe`, the unsafe-to-break
## flag. Clusters merge and flags are set as HarfBuzz merges and sets them
## at its monotone cluster levels (`hb-buffer.hh`, `hb-ot-layout-gsubgpos.hh`).
LayoutGsub := {
	common : LayoutCommon,
	lookups : List({ start : U64, count : U64, mode : U64, d0 : U64, d1 : U64, d2 : U64 }),
	subtables : List(
		{
			kind : U64,
			coverage : U64,
			coverage_len : U64,
			delta : I64,
			data : U64,
			data_len : U64,
			match_kind : U64,
			back : U64,
			back_len : U64,
			input : U64,
			input_len : U64,
			ahead : U64,
			ahead_len : U64,
		},
	),
	ranges : List({ first : U64, last : U64, index : U64 }),
	values : List(U64),
	rules : List({ back : U64, back_len : U64, input : U64, input_len : U64, ahead : U64, ahead_len : U64, records : U64, records_len : U64 }),
}.{

	Range : { first : U64, last : U64, index : U64 }

	Ranges : List(Range)

	## One lookup: its subtables are `subtables[start ..< start + count]`.
	## `mode` is 0 when every subtable is a single substitution (applied in
	## place), 1 when every one is a single or ligature substitution (applied
	## by compacting in place), 2 otherwise. `d0`, `d1` and `d2` are a digest
	## of every glyph its subtables cover (see `may_start`). A lookup no
	## feature reaches is not read and has no subtables.
	Lookup : { start : U64, count : U64, mode : U64, d0 : U64, d1 : U64, d2 : U64 }

	## One subtable. `coverage` and `coverage_len` select its coverage in
	## `ranges`. By `kind`:
	##
	## - 1 (single): `delta` when `data_len` is 0, else the substitutes are
	##   `values[data ..< data + data_len]`.
	## - 2 (multiple): `data_len` sequences; `values[data + s]` and
	##   `values[data + s + 1]` bound sequence `s` in `values`.
	## - 4 (ligature): `data_len` ligature sets bounded likewise in `values`;
	##   a set holds ligatures as `glyph, n, component 2, ..., component n+1`.
	## - 5 (context and chained context): `data_len` rule sets bounded
	##   likewise in `rules`. `match_kind` is 0 for glyphs, 1 for classes
	##   (`back`, `input` and `ahead` select the class definitions in
	##   `ranges`), 2 for coverages (each match is a start and length in
	##   `ranges`, two values).
	Sub : {
		kind : U64,
		coverage : U64,
		coverage_len : U64,
		delta : I64,
		data : U64,
		data_len : U64,
		match_kind : U64,
		back : U64,
		back_len : U64,
		input : U64,
		input_len : U64,
		ahead : U64,
		ahead_len : U64,
	}

	## A contextual rule: spans of matches in `values` (the input after its
	## first glyph, backtrack nearest first, lookahead), and its nested
	## lookup records as `at, lookup` pairs.
	Rule : { back : U64, back_len : U64, input : U64, input_len : U64, ahead : U64, ahead_len : U64, records : U64, records_len : U64 }

	## The lists being filled while reading, and the reading work spent.
	Built : { subtables : List(Sub), ranges : Ranges, values : List(U64), rules : List(Rule), steps : U64 }

	## One glyph of a run: its cluster and its mask (see the module notes).
	Item : { glyph : U64, cluster : U64, mask : U64 }

	## The bounds of one application: a run never grows past `limit`
	## glyphs, lookups called from contextual rules are applied at most
	## `budget` times in all, and at most `depth` deep.
	Limits : { limit : U64, budget : U64, depth : U64 }

	## A contextual rule being applied: its matched input starts at `start`
	## and is `length` glyphs long now; `next` is its next lookup record;
	## `before` the run's length before the record being applied.
	Frame : { rule : Rule, start : U64, length : U64, next : U64, before : U64 }

	## No substitutions.
	none : LayoutGsub
	none = { common: LayoutCommon.none, lookups: [], subtables: [], ranges: [], values: [], rules: [] }

	## The unsafe-to-break flag in an item's mask. Lookup masks never hold it.
	unsafe : U64
	unsafe = 0x8000000000000000

	## The longest input a contextual rule may match (HarfBuzz's
	## `HB_MAX_CONTEXT_LENGTH`); longer rules never match.
	max_context : U64
	max_context = 64

	no_item : Item
	no_item = { glyph: 0, cluster: 0, mask: 0 }

	no_lookup : Lookup
	no_lookup = { start: 0, count: 0, mode: 0, d0: 0, d1: 0, d2: 0 }

	no_sub : Sub
	no_sub = { kind: 0, coverage: 0, coverage_len: 0, delta: 0, data: 0, data_len: 0, match_kind: 0, back: 0, back_len: 0, input: 0, input_len: 0, ahead: 0, ahead_len: 0 }

	no_rule : Rule
	no_rule = { back: 0, back_len: 0, input: 0, input_len: 0, ahead: 0, ahead_len: 0, records: 0, records_len: 0 }

	no_frame : Frame
	no_frame = { rule: LayoutGsub.no_rule, start: 0, length: 0, next: 0, before: 0 }

	## The script and feature lists, for choosing lookups.
	common_of : LayoutGsub -> LayoutCommon
	common_of = |shape| shape.common

	# ------------------------------------------------------------ applying

	## Apply lookups to a run, in the order given; each applies where a
	## glyph's mask shares a bit with the lookup's `mask`. Each lookup passes
	## over the run once, left to right. Past `limits`, a substitution that
	## would grow the run past its limit is not made, and contextual rules
	## match but call no more lookups; the run stays total and finite.
	apply : LayoutGsub, List({ index : U64, mask : U64 }), List(Item), Limits -> List(Item)
	apply = |shape, plan, items, limits| {
		var $run = items
		# The previous run of a general lookup, whose allocation the next one
		# writes into.
		var $spare = []
		var $ops = 0
		for entry in plan {
			lookup = shape.lookups.get(entry.index) ?? LayoutGsub.no_lookup
			if lookup.count > 0 {
				if lookup.mode == 0 {
					$run = LayoutGsub.apply_singles(shape, lookup, entry.mask, $run)
				} else if lookup.mode == 1 {
					$run = LayoutGsub.apply_compacting(shape, lookup, entry.mask, $run)
				} else if LayoutGsub.any_start(lookup, $run) {
					{ run: applied, spare: freed, ops: spent } = LayoutGsub.apply_general(shape, lookup, entry.mask, $run, $spare, limits, $ops)
					$run = applied
					$spare = freed
					$ops = spent
				}
			}
		}
		$run
	}

	applies : U64, U64 -> Bool
	applies = |item_mask, lookup_mask| item_mask.bitwise_and(lookup_mask) != 0

	# A lookup of single substitutions only: each glyph is replaced in place.
	apply_singles : LayoutGsub, Lookup, U64, List(Item) -> List(Item)
	apply_singles = |shape, lookup, mask, items| {
		var $run = items
		n = $run.len()
		var $i = 0
		while $i < n {
			item = $run.get($i) ?? LayoutGsub.no_item
			if LayoutGsub.may_start(lookup, item.glyph) and LayoutGsub.applies(item.mask, mask) {
				match LayoutGsub.simple_at(shape, lookup, mask, $run, $i) {
					One(found) =>
						if found.glyph != item.glyph {
							# `$i < n`, the run's length.
							$run = $run.set($i, { ..item, glyph: found.glyph }) ?? []
						}
					Skip => {}
				}
			}
			$i = $i + 1
		}
		$run
	}

	# A lookup of single and ligature substitutions: the run only shrinks, so
	# results are written over the run behind the read position. A ligature
	# reads only glyphs after the read position, which are not yet written;
	# merging clusters may change those glyphs' clusters and the clusters of
	# glyphs already written.
	apply_compacting : LayoutGsub, Lookup, U64, List(Item) -> List(Item)
	apply_compacting = |shape, lookup, mask, items| {
		var $run = items
		n = $run.len()
		var $read = 0
		var $write = 0
		while $read < n {
			item = $run.get($read) ?? LayoutGsub.no_item
			found = if LayoutGsub.may_start(lookup, item.glyph) and LayoutGsub.applies(item.mask, mask) {
				match LayoutGsub.simple_at(shape, lookup, mask, $run, $read) {
					One(one) => one
					Skip => { glyph: item.glyph, next: $read + 1 }
				}
			} else {
				{ glyph: item.glyph, next: $read + 1 }
			}
			if found.next > $read + 1 {
				# A ligature of the glyphs `$read ..< found.next`.
				# Destructured, so the run is not also held by a record.
				{ run: merged, cluster } = LayoutGsub.merge_ligature($run, $write, $read, found.next)
				# `$write <= $read < n`.
				$run = merged.set($write, { ..item, glyph: found.glyph, cluster }) ?? []
			} else if $write != $read or found.glyph != item.glyph {
				# `$write <= $read < n`, the run's length.
				$run = $run.set($write, { ..item, glyph: found.glyph }) ?? []
			}
			$write = $write + 1
			$read = found.next
		}
		if $write < n {
			$run.take_first($write)
		} else {
			$run
		}
	}

	## Merge the clusters of a ligature's components, `run[start ..< end]`,
	## as HarfBuzz's `merge_clusters` does: they take their smallest cluster,
	## and so do the glyphs after them that share the last component's
	## cluster and the glyphs before `written` that share the first's. Glyphs
	## from `written` to `start` are not part of the run (already consumed).
	merge_ligature : List(Item), U64, U64, U64 -> { run : List(Item), cluster : U64 }
	merge_ligature = |run, written, start, end| {
		first = (run.get(start) ?? LayoutGsub.no_item).cluster
		last = (run.get(end - 1) ?? LayoutGsub.no_item).cluster
		cluster = LayoutGsub.min_cluster(run, start, end, first)
		forward = if (cluster != last) LayoutGsub.rewrite_forward(run, end, last, cluster) else run
		backward = if (cluster != first) LayoutGsub.rewrite_backward(forward, written, first, cluster) else forward
		{ run: backward, cluster }
	}

	## The smallest cluster of `run[start ..< end]` and `init`.
	min_cluster : List(Item), U64, U64, U64 -> U64
	min_cluster = |run, start, end, init| {
		var $c = init
		var $p = start
		while $p < end {
			$c = $c.min((run.get($p) ?? LayoutGsub.no_item).cluster)
			$p = $p + 1
		}
		$c
	}

	## Give `cluster` to the items from `from` on whose cluster is `old`, up
	## to the first that differs.
	rewrite_forward : List(Item), U64, U64, U64 -> List(Item)
	rewrite_forward = |run, from, old, cluster| {
		var $run = run
		var $p = from
		var $going = True
		while $going and $p < $run.len() {
			item = $run.get($p) ?? LayoutGsub.no_item
			if item.cluster == old {
				# `$p` is below the run's length.
				$run = $run.set($p, { ..item, cluster }) ?? []
				$p = $p + 1
			} else {
				$going = False
			}
		}
		$run
	}

	## Give `cluster` to the items before `end` whose cluster is `old`, back
	## to the first that differs.
	rewrite_backward : List(Item), U64, U64, U64 -> List(Item)
	rewrite_backward = |run, end, old, cluster| {
		var $run = run
		var $p = end.min(run.len())
		var $going = True
		while $going and $p > 0 {
			item = $run.get($p - 1) ?? LayoutGsub.no_item
			if item.cluster == old {
				# `$p - 1` is below the run's length.
				$run = $run.set($p - 1, { ..item, cluster }) ?? []
				$p = $p - 1
			} else {
				$going = False
			}
		}
		$run
	}

	## Set the unsafe-to-break flag on `run[start ..< end]` as HarfBuzz's
	## `_infos_set_glyph_flags` does at monotone cluster levels, for a range
	## whose smallest cluster is `cluster`: the glyphs after the first
	## cluster's, or before the last cluster's.
	flag_range : List(Item), U64, U64, U64 -> List(Item)
	flag_range = |run, start, end_raw, cluster| {
		end = end_raw.min(run.len())
		if start >= end {
			run
		} else {
			first = (run.get(start) ?? LayoutGsub.no_item).cluster
			last = (run.get(end - 1) ?? LayoutGsub.no_item).cluster
			var $run = run
			if cluster != first and cluster != last {
				for p in start..<end {
					item = $run.get(p) ?? LayoutGsub.no_item
					if item.cluster != cluster {
						# `p < end <= len`.
						$run = $run.set(p, { ..item, mask: item.mask.bitwise_or(LayoutGsub.unsafe) }) ?? []
					}
				}
			} else if cluster == first {
				var $p = end
				while $p > start and ($run.get($p - 1) ?? LayoutGsub.no_item).cluster != first {
					item = $run.get($p - 1) ?? LayoutGsub.no_item
					# `start < $p <= end <= len`.
					$run = $run.set($p - 1, { ..item, mask: item.mask.bitwise_or(LayoutGsub.unsafe) }) ?? []
					$p = $p - 1
				}
			} else {
				var $p = start
				while $p < end and ($run.get($p) ?? LayoutGsub.no_item).cluster != last {
					item = $run.get($p) ?? LayoutGsub.no_item
					# `$p < end <= len`.
					$run = $run.set($p, { ..item, mask: item.mask.bitwise_or(LayoutGsub.unsafe) }) ?? []
					$p = $p + 1
				}
			}
			$run
		}
	}

	## Mark a matched contextual rule unsafe to break, as HarfBuzz's
	## `unsafe_to_break_from_outbuffer` does: its backtrack is
	## `before[back ..< before.len()]`, its input and lookahead
	## `after[start ..< end]`. Ranges longer than 255 glyphs are not marked
	## (HarfBuzz's bound).
	flag_rule : List(Item), U64, List(Item), U64, U64 -> { before : List(Item), after : List(Item) }
	flag_rule = |before, back, after, start, end|
		if (before.len() - back) + (end - start) > 255 {
			{ before, after }
		} else {
			cluster = LayoutGsub.min_cluster(before, back, before.len(), LayoutGsub.min_cluster(after, start, end, 0xFFFFFFFFFFFFFFFF))
			{ before: LayoutGsub.flag_range(before, back, before.len(), cluster), after: LayoutGsub.flag_range(after, start, end, cluster) }
		}

	# Any lookup: a new run is written, since multiple substitutions and
	# contextual rules may grow it. Backtrack context is read from what has
	# been written. The new run is written into `spare`'s allocation, and the
	# old run's is returned for the next general lookup.
	apply_general : LayoutGsub, Lookup, U64, List(Item), List(Item), Limits, U64 -> { run : List(Item), spare : List(Item), ops : U64 }
	apply_general = |shape, lookup, mask, input_list, spare, limits, ops| {
		n = input_list.len()
		var $input = input_list
		var $out = spare.clear().reserve(n)
		var $ops = ops
		var $frames = []
		var $i = 0
		while $i < n {
			item = $input.get($i) ?? LayoutGsub.no_item
			if LayoutGsub.may_start(lookup, item.glyph) and LayoutGsub.applies(item.mask, mask) {
				match LayoutGsub.step(shape, lookup, mask, $out, $input, $i, limits.limit) {
					One(found) => {
						if found.next > $i + 1 {
							{ run: merged, cluster } = LayoutGsub.merge_ligature($input, 0, $i, found.next)
							first = item.cluster
							$input = merged
							$out = if (cluster != first) LayoutGsub.rewrite_backward($out, $out.len(), first, cluster) else $out
							$out = $out.append({ ..item, glyph: found.glyph, cluster })
						} else {
							$out = $out.append({ ..item, glyph: found.glyph })
						}
						$i = found.next
					}
					Sequence(span) => {
						if span.end == span.start {
							{ out: kept, input: rest } = LayoutGsub.delete_glyph($out, $input, $i)
							$out = kept
							$input = rest
						}
						for p in span.start..<span.end {
							$out = $out.append({ ..item, glyph: shape.values.get(p) ?? 0 })
						}
						$i = $i + 1
					}
					Nested(rule) => {
						# The matched input is copied to the end of the new run
						# and the rule's lookups change it there; backtrack
						# context may read the whole new run.
						written = $out.len()
						window = rule.input_len + 1
						{ before: flagged_out, after: flagged_in } = LayoutGsub.flag_rule($out, written - rule.back_len, $input, $i, $i + window + rule.ahead_len)
						$out = flagged_out
						$input = flagged_in
						# The window may grow only as far as the whole run may.
						taken = written + (n - $i - window)
						room = if (limits.limit >= taken) limits.limit - taken else 0
						$out = $out.concat($input.sublist({ start: $i, len: window }))
						{ buffer: grown, ops: spent, next: _, frames: stack } = LayoutGsub.run_rule(shape, rule, window, $out, written, written, mask, written + room, limits, $ops, $frames)
						$out = grown
						$ops = spent
						$frames = stack
						$i = $i + window
					}
					Skip => {
						$out = $out.append(item)
						$i = $i + 1
					}
				}
			} else {
				$out = $out.append(item)
				$i = $i + 1
			}
		}
		{ run: $out, spare: $input.clear(), ops: $ops }
	}

	## Delete `input[i]` (a multiple substitution by no glyphs), merging its
	## cluster as HarfBuzz's `delete_glyph` does: nothing when a neighbour
	## shares it; else into the glyphs written before it when its cluster is
	## smaller than theirs; else, with nothing written, into the next glyph.
	delete_glyph : List(Item), List(Item), U64 -> { out : List(Item), input : List(Item) }
	delete_glyph = |out, input, i| {
		c = (input.get(i) ?? LayoutGsub.no_item).cluster
		next = input.get(i + 1)
		previous = out.last()
		shared_next = match next {
			Ok(item) => item.cluster == c
			Err(_) => False
		}
		shared_previous = match previous {
			Ok(item) => item.cluster == c
			Err(_) => False
		}
		if shared_next or shared_previous {
			{ out, input }
		} else {
			match (previous, next) {
				(Ok(p), _) =>
					if (c < p.cluster) { out: LayoutGsub.rewrite_backward(out, out.len(), p.cluster, c), input } else { out, input }
				(Err(_), Ok(after)) => {
					cluster = c.min(after.cluster)
					{ out, input: if (cluster != after.cluster) LayoutGsub.rewrite_forward(input, i + 1, after.cluster, cluster) else input }
				}
				_ => { out, input }
			}
		}
	}

	## Whether a lookup could apply anywhere in a run.
	any_start : Lookup, List(Item) -> Bool
	any_start = |lookup, run| {
		var $found = False
		var $i = 0
		n = run.len()
		while $i < n {
			if LayoutGsub.may_start(lookup, (run.get($i) ?? LayoutGsub.no_item).glyph) {
				$found = True
				$i = n
			} else {
				$i = $i + 1
			}
		}
		$found
	}

	## Whether a lookup may apply at a glyph. Every subtable needs the glyph
	## at the current position to be in its coverage, so a lookup keeps a
	## digest of every covered glyph: three 64-bit masks indexed by glyph
	## bits 0–5, 4–9 and 9–14. A glyph whose bit is clear in any mask is
	## covered by no subtable; the converse need not hold.
	may_start : Lookup, U64 -> Bool
	may_start = |lookup, glyph|
		lookup.d0.shr_wrap(glyph.bitwise_and(63).to_u8_wrap()).bitwise_and(1) == 1
			and lookup.d1.shr_wrap(glyph.shr_wrap(4).bitwise_and(63).to_u8_wrap()).bitwise_and(1) == 1
			and lookup.d2.shr_wrap(glyph.shr_wrap(9).bitwise_and(63).to_u8_wrap()).bitwise_and(1) == 1

	# Add the glyphs `first` to `last` to one mask of a digest.
	digest_range : U64, U8, U64, U64 -> U64
	digest_range = |mask, shift, first, last|
		if first > last {
			mask
		} else {
			low = first.shr_wrap(shift)
			high = last.shr_wrap(shift)
			if high - low >= 63 {
				0xFFFFFFFFFFFFFFFF
			} else {
				var $mask = mask
				var $k = low
				while $k <= high {
					$mask = $mask.bitwise_or((1.U64).shl_wrap($k.bitwise_and(63).to_u8_wrap()))
					$k = $k + 1
				}
				$mask
			}
		}

	# The first single or ligature subtable of a lookup that applies at `i`:
	# the glyph it writes and where reading continues.
	simple_at : LayoutGsub, Lookup, U64, List(Item), U64 -> [One({ glyph : U64, next : U64 }), Skip]
	simple_at = |shape, lookup, mask, run, i| {
		item = run.get(i) ?? LayoutGsub.no_item
		end = lookup.start + lookup.count
		var $result = Skip
		var $k = lookup.start
		while $k < end {
			sub = shape.subtables.get($k) ?? LayoutGsub.no_sub
			outcome = match LayoutGsub.covered_in(shape.ranges, sub.coverage, sub.coverage_len, item.glyph) {
				Err(_) => Skip
				Ok(at) =>
					if sub.kind == 1 {
						One({ glyph: LayoutGsub.single(shape.values, sub, at, item.glyph), next: i + 1 })
					} else if sub.kind == 4 {
						match LayoutGsub.ligature_at(shape.values, sub, at, run, i, mask) {
							Found(found) => One({ glyph: found.glyph, next: i + 1 + found.count })
							NotFound => Skip
						}
					} else {
						Skip
					}
			}
			match outcome {
				One(_) => {
					$result = outcome
					$k = end
				}
				Skip => {
					$k = $k + 1
				}
			}
		}
		$result
	}

	# The first subtable of a lookup that applies at `i` of `input`, with
	# `out` written so far: what it writes and where reading continues.
	step : LayoutGsub, Lookup, U64, List(Item), List(Item), U64, U64 -> [One({ glyph : U64, next : U64 }), Sequence({ start : U64, end : U64 }), Nested(Rule), Skip]
	step = |shape, lookup, mask, out, input, i, limit| {
		item = input.get(i) ?? LayoutGsub.no_item
		end = lookup.start + lookup.count
		var $result = Skip
		var $k = lookup.start
		while $k < end {
			sub = shape.subtables.get($k) ?? LayoutGsub.no_sub
			outcome = if sub.kind == 5 {
				match LayoutGsub.rule_at(shape, sub, out, 0, out.len(), input, i) {
					Found(rule) => Nested(rule)
					NotFound => Skip
				}
			} else {
				match LayoutGsub.covered_in(shape.ranges, sub.coverage, sub.coverage_len, item.glyph) {
					Err(_) => Skip
					Ok(at) =>
						if sub.kind == 1 {
							One({ glyph: LayoutGsub.single(shape.values, sub, at, item.glyph), next: i + 1 })
						} else if sub.kind == 2 {
							span = LayoutGsub.sequence(shape.values, sub, at)
							length = if (span.found) span.end - span.start else 1
							if out.len() + length + (input.len() - i) > limit + 1 {
								Skip
							} else if span.found {
								Sequence({ start: span.start, end: span.end })
							} else {
								One({ glyph: item.glyph, next: i + 1 })
							}
						} else if sub.kind == 4 {
							match LayoutGsub.ligature_at(shape.values, sub, at, input, i, mask) {
								Found(found) => One({ glyph: found.glyph, next: i + 1 + found.count })
								NotFound => Skip
							}
						} else {
							Skip
						}
				}
			}
			match outcome {
				Skip => {
					$k = $k + 1
				}
				_ => {
					$result = outcome
					$k = end
				}
			}
		}
		$result
	}

	single : List(U64), Sub, U64, U64 -> U64
	single = |values, sub, at, glyph|
		if sub.data_len == 0 {
			(glyph.to_i64_wrap() + sub.delta).bitwise_and(0xFFFF).to_u64_wrap()
		} else if at < sub.data_len {
			values.get(sub.data + at) ?? glyph
		} else {
			glyph
		}

	# Sequence `at` of a multiple substitution as a span of `values`;
	# `found` is false when the subtable has no such sequence.
	sequence : List(U64), Sub, U64 -> { found : Bool, start : U64, end : U64 }
	sequence = |values, sub, at|
		if at < sub.data_len {
			start = values.get(sub.data + at) ?? 0
			end = values.get(sub.data + at + 1) ?? 0
			{ found: True, start, end: end.max(start) }
		} else {
			{ found: False, start: 0, end: 0 }
		}

	# The first ligature of set `at` whose other components follow `i`, each
	# with a mask sharing a bit with the lookup's (as HarfBuzz matches
	# ligature components).
	ligature_at : List(U64), Sub, U64, List(Item), U64, U64 -> [Found({ glyph : U64, count : U64 }), NotFound]
	ligature_at = |values, sub, at, buffer, i, mask|
		if at >= sub.data_len {
			NotFound
		} else {
			end = values.get(sub.data + at + 1) ?? 0
			var $result = NotFound
			var $p = values.get(sub.data + at) ?? 0
			while $p < end {
				glyph = values.get($p) ?? 0
				count = values.get($p + 1) ?? 0
				var $same = i + count < buffer.len()
				var $j = 0
				while $same and $j < count {
					component = buffer.get(i + 1 + $j) ?? LayoutGsub.no_item
					if component.glyph != (values.get($p + 2 + $j) ?? 0) or !LayoutGsub.applies(component.mask, mask) {
						$same = False
					}
					$j = $j + 1
				}
				if $same {
					$result = Found({ glyph, count })
					$p = end
				} else {
					$p = $p + 2 + count
				}
			}
			$result
		}

	# The first rule of a context subtable that matches at `i` of `after`,
	# with backtrack read from the end of `before` (its items from `floor`
	# to `before_end`).
	rule_at : LayoutGsub, Sub, List(Item), U64, U64, List(Item), U64 -> [Found(Rule), NotFound]
	rule_at = |shape, sub, before, floor, before_end, after, i| {
		glyph = (after.get(i) ?? LayoutGsub.no_item).glyph
		match LayoutGsub.covered_in(shape.ranges, sub.coverage, sub.coverage_len, glyph) {
			Err(_) => NotFound
			Ok(at) => {
				slot = if (sub.match_kind == 1) LayoutGsub.class_in(shape.ranges, sub.input, sub.input_len, glyph) else if (sub.data_len == 1) 0 else at
				if slot >= sub.data_len {
					NotFound
				} else {
					last = shape.values.get(sub.data + slot + 1) ?? 0
					var $result = NotFound
					var $r = shape.values.get(sub.data + slot) ?? 0
					while $r < last {
						rule = shape.rules.get($r) ?? LayoutGsub.no_rule
						if LayoutGsub.matches(shape, rule, sub, before, floor, before_end, after, i) {
							$result = Found(rule)
							$r = last
						} else {
							$r = $r + 1
						}
					}
					$result
				}
			}
		}
	}

	# Run a rule's nested lookups over its matched input, which starts at
	# `i` of `buffer` and is `matched` glyphs long, then say where reading
	# continues. Backtrack context is read no further back than `floor`.
	# Rules matched by nested lookups are applied the same way, through an
	# explicit stack of frames rather than recursion: at most `limits.depth`
	# rules deep (deeper rules match but call nothing), and at most
	# `limits.budget` nested lookups in all, counted in `ops`.
	run_rule : LayoutGsub, Rule, U64, List(Item), U64, U64, U64, U64, Limits, U64, List(Frame) -> { buffer : List(Item), next : U64, ops : U64, frames : List(Frame) }
	run_rule = |shape, rule, matched, buffer, floor, i, mask, limit, limits, ops, spare| {
		var $buffer = buffer
		var $ops = ops
		# The stack reuses `spare`'s allocation, so a rule costs none.
		var $frames = spare.clear().append({ rule, start: i, length: matched, next: 0, before: 0 })
		var $next = i + matched.max(1)
		while !$frames.is_empty() {
			depth = $frames.len()
			top = $frames.last() ?? LayoutGsub.no_frame
			if top.next >= top.rule.records_len or depth > limits.depth {
				# The rule is done: the run continues after its input, and its
				# growth counts towards the rule that called it.
				$frames = $frames.drop_last(1)
				$next = top.start + top.length.max(1)
				match $frames.last() {
					Ok(parent) => {
						grown = $buffer.len() + parent.length
						updated = { ..parent, length: if (grown >= parent.before) grown - parent.before else 0 }
						# The list is not empty: it holds `parent`.
						$frames = $frames.set($frames.len() - 1, updated) ?? []
					}
					Err(_) => {}
				}
			} else {
				r = top.next
				at = shape.values.get(top.rule.records + 2 * r) ?? 0
				lookup = shape.values.get(top.rule.records + 2 * r + 1) ?? 0
				# The list is not empty: it holds `top`.
				$frames = $frames.set(depth - 1, { ..top, next: r + 1 }) ?? []
				if at < top.length and $ops < limits.budget {
					$ops = $ops + 1
					before = $buffer.len()
					match LayoutGsub.apply_lookup(shape, lookup, $buffer, floor, top.start + at, mask, limit) {
						Applied(changed) => {
							$buffer = changed
							grown = $buffer.len() + top.length
							$frames = $frames.set(depth - 1, { ..top, next: r + 1, length: if (grown >= before) grown - before else 0 }) ?? []
						}
						NotApplied(same) => {
							$buffer = same
						}
						Matched({ buffer: flagged, rule: inner }) => {
							$buffer = flagged
							$frames = ($frames.set(depth - 1, { ..top, next: r + 1, before }) ?? []).append({ rule: inner, start: top.start + at, length: inner.input_len + 1, next: 0, before: 0 })
						}
					}
				}
			}
		}
		{ buffer: $buffer, next: $next, ops: $ops, frames: $frames }
	}

	# A nested lookup at `i`: the first of its subtables that applies there.
	# A contextual rule that matches is marked unsafe to break and returned
	# for the caller to apply; other substitutions change the buffer in
	# place.
	apply_lookup : LayoutGsub, U64, List(Item), U64, U64, U64, U64 -> [Applied(List(Item)), NotApplied(List(Item)), Matched({ buffer : List(Item), rule : Rule })]
	apply_lookup = |shape, index, buffer, floor, i, mask, limit| {
		lookup = shape.lookups.get(index) ?? LayoutGsub.no_lookup
		end = lookup.start + lookup.count
		var $outcome = NotApplied(buffer)
		var $k = lookup.start
		while $k < end {
			current = match $outcome {
				NotApplied(b) => b
				_ => []
			}
			$outcome = LayoutGsub.apply_subtable(shape, shape.subtables.get($k) ?? LayoutGsub.no_sub, current, floor, i, mask, limit)
			$k = match $outcome {
				NotApplied(_) => $k + 1
				_ => end
			}
		}
		$outcome
	}

	# One nested subtable at `i`.
	apply_subtable : LayoutGsub, Sub, List(Item), U64, U64, U64, U64 -> [Applied(List(Item)), NotApplied(List(Item)), Matched({ buffer : List(Item), rule : Rule })]
	apply_subtable = |shape, sub, buffer, floor, i, mask, limit| {
		item = buffer.get(i) ?? LayoutGsub.no_item
		if i >= buffer.len() {
			NotApplied(buffer)
		} else if sub.kind == 5 {
			match LayoutGsub.rule_at(shape, sub, buffer, floor, i, buffer, i) {
				Found(rule) => {
					# The backtrack, input and lookahead all lie in `buffer`.
					back = i - rule.back_len
					end = i + rule.input_len + 1 + rule.ahead_len
					flagged = if (rule.back_len + (end - i) > 255) buffer else LayoutGsub.flag_both(buffer, back, i, end)
					Matched({ buffer: flagged, rule })
				}
				NotFound => NotApplied(buffer)
			}
		} else {
			match LayoutGsub.covered_in(shape.ranges, sub.coverage, sub.coverage_len, item.glyph) {
				Err(_) => NotApplied(buffer)
				Ok(at) =>
					if sub.kind == 1 {
						glyph = LayoutGsub.single(shape.values, sub, at, item.glyph)
						# `i` is in bounds (checked above).
						Applied(buffer.set(i, { ..item, glyph }) ?? [])
					} else if sub.kind == 2 {
						span = LayoutGsub.sequence(shape.values, sub, at)
						length = if (span.found) span.end - span.start else 1
						if buffer.len() + length > limit + 1 {
							NotApplied(buffer)
						} else if span.found {
							Applied(LayoutGsub.splice_sequence(buffer, i, shape.values, span.start, span.end))
						} else {
							# The glyph is replaced by itself.
							Applied(buffer)
						}
					} else if sub.kind == 4 {
						match LayoutGsub.ligature_at(shape.values, sub, at, buffer, i, mask) {
							Found(found) => Applied(LayoutGsub.splice_ligature(buffer, i, found.glyph, found.count))
							NotFound => NotApplied(buffer)
						}
					} else {
						NotApplied(buffer)
					}
			}
		}
	}

	## `flag_rule` for a rule whose backtrack `[back, i)` and input and
	## lookahead `[i, end)` lie in one buffer.
	flag_both : List(Item), U64, U64, U64 -> List(Item)
	flag_both = |buffer, back, i, end| {
		cluster = LayoutGsub.min_cluster(buffer, back, end.min(buffer.len()), 0xFFFFFFFFFFFFFFFF)
		LayoutGsub.flag_range(LayoutGsub.flag_range(buffer, back, i, cluster), i, end, cluster)
	}

	# Replace the item at `i` (in bounds) by the glyphs `values[start ..<
	# end]`, moving the items after it. Only the items after `i` move, so the
	# cost is the length of the rule's matched input, not of the run. No
	# glyphs delete the item, merging its cluster as `delete_glyph` does.
	splice_sequence : List(Item), U64, List(U64), U64, U64 -> List(Item)
	splice_sequence = |buffer, i, values, start, end| {
		length = end - start
		n = buffer.len()
		item = buffer.get(i) ?? LayoutGsub.no_item
		if length == 0 {
			var $buffer = buffer
			# Merge first, while the neighbours are in place.
			merged = LayoutGsub.delete_in_place($buffer, i)
			$buffer = merged
			for p in i..<(n - 1) {
				# `p + 1 < n`, the buffer's length.
				$buffer = $buffer.set(p, $buffer.get(p + 1) ?? LayoutGsub.no_item) ?? []
			}
			$buffer.take_first(n - 1)
		} else {
			var $buffer = buffer
			grow = length - 1
			var $k = 0
			while $k < grow {
				$buffer = $buffer.append(LayoutGsub.no_item)
				$k = $k + 1
			}
			var $p = n - 1
			while $p > i {
				# `$p + grow < n + grow`, the buffer's length.
				$buffer = $buffer.set($p + grow, $buffer.get($p) ?? LayoutGsub.no_item) ?? []
				$p = $p - 1
			}
			for k in 0..<length {
				# `i + k < i + length <= n + grow`.
				$buffer = $buffer.set(i + k, { ..item, glyph: values.get(start + k) ?? 0 }) ?? []
			}
			$buffer
		}
	}

	## `delete_glyph` within one buffer: the glyphs before `i` are those
	## written, the glyphs after it those still to read.
	delete_in_place : List(Item), U64 -> List(Item)
	delete_in_place = |buffer, i| {
		c = (buffer.get(i) ?? LayoutGsub.no_item).cluster
		next = buffer.get(i + 1)
		previous = if (i > 0) buffer.get(i - 1) else Err(OutOfBounds)
		shared_next = match next {
			Ok(item) => item.cluster == c
			Err(_) => False
		}
		shared_previous = match previous {
			Ok(item) => item.cluster == c
			Err(_) => False
		}
		if shared_next or shared_previous {
			buffer
		} else {
			match (previous, next) {
				(Ok(p), _) => if (c < p.cluster) LayoutGsub.rewrite_backward(buffer, i, p.cluster, c) else buffer
				(Err(_), Ok(after)) => {
					cluster = c.min(after.cluster)
					if (cluster != after.cluster) LayoutGsub.rewrite_forward(buffer, i + 1, after.cluster, cluster) else buffer
				}
				_ => buffer
			}
		}
	}

	# Replace the item at `i` and the `count` after it (all in bounds) by
	# one ligature glyph, moving the items after them, with their clusters
	# merged as `merge_ligature` merges them.
	splice_ligature : List(Item), U64, U64, U64 -> List(Item)
	splice_ligature = |buffer, i, glyph, count| {
		n = buffer.len()
		item = buffer.get(i) ?? LayoutGsub.no_item
		{ run: merged, cluster } = LayoutGsub.merge_ligature(buffer, i, i, i + 1 + count)
		# `i < n`, and every index below is under `n`.
		var $buffer = merged.set(i, { ..item, glyph, cluster }) ?? []
		for p in (i + 1)..<(n - count) {
			$buffer = $buffer.set(p, $buffer.get(p + count) ?? LayoutGsub.no_item) ?? []
		}
		$buffer.take_first(n - count)
	}

	# The rule's input after the first glyph, its backtrack (nearest first,
	# from `before[floor ..< before_end]`) and its lookahead all match around
	# `i`. Rules with more input than `max_context` never match.
	matches : LayoutGsub, Rule, Sub, List(Item), U64, U64, List(Item), U64 -> Bool
	matches = |shape, rule, sub, before, floor, before_end, buffer, i| {
		input_end = i + 1 + rule.input_len
		if rule.input_len + 1 > LayoutGsub.max_context or before_end < floor + rule.back_len or input_end + rule.ahead_len > buffer.len() {
			False
		} else {
			stride = if (sub.match_kind == 2) 2 else 1
			var $ok = True
			var $k = 0
			while $ok and $k < rule.back_len {
				g = (before.get(before_end - 1 - $k) ?? LayoutGsub.no_item).glyph
				$ok = LayoutGsub.match_one(shape, sub.match_kind, sub.back, sub.back_len, rule.back + stride * $k, g)
				$k = $k + 1
			}
			$k = 0
			while $ok and $k < rule.input_len {
				g = (buffer.get(i + 1 + $k) ?? LayoutGsub.no_item).glyph
				$ok = LayoutGsub.match_one(shape, sub.match_kind, sub.input, sub.input_len, rule.input + stride * $k, g)
				$k = $k + 1
			}
			$k = 0
			while $ok and $k < rule.ahead_len {
				g = (buffer.get(input_end + $k) ?? LayoutGsub.no_item).glyph
				$ok = LayoutGsub.match_one(shape, sub.match_kind, sub.ahead, sub.ahead_len, rule.ahead + stride * $k, g)
				$k = $k + 1
			}
			$ok
		}
	}

	# Whether a glyph matches the match stored at `values[at]`: the glyph
	# itself, a class in the class definition `classes`, or a coverage.
	match_one : LayoutGsub, U64, U64, U64, U64, U64 -> Bool
	match_one = |shape, kind, classes, classes_len, at, glyph| {
		value = shape.values.get(at) ?? 0
		if kind == 0 {
			value == glyph
		} else if kind == 1 {
			LayoutGsub.class_in(shape.ranges, classes, classes_len, glyph) == value
		} else {
			LayoutGsub.covered_in(shape.ranges, value, shape.values.get(at + 1) ?? 0, glyph).is_ok()
		}
	}

	## The coverage index of a glyph.
	covered : Ranges, U64 -> Try(U64, [NotCovered])
	covered = |ranges, glyph| LayoutGsub.covered_in(ranges, 0, ranges.len(), glyph)

	## The coverage index of a glyph in the coverage `ranges[start ..< start
	## + len]`.
	covered_in : Ranges, U64, U64, U64 -> Try(U64, [NotCovered])
	covered_in = |ranges, start, len, glyph| {
		var $low = 0
		var $high = len
		var $result = Err(NotCovered)
		while $low < $high {
			mid = ($low + $high) // 2
			range = ranges.get(start + mid) ?? { first: 1, last: 0, index: 0 }
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
	class_of = |ranges, glyph| LayoutGsub.class_in(ranges, 0, ranges.len(), glyph)

	## A glyph's class in the class definition `ranges[start ..< start +
	## len]`.
	class_in : Ranges, U64, U64, U64 -> U64
	class_in = |ranges, start, len, glyph| {
		var $low = 0
		var $high = len
		var $result = 0
		while $low < $high {
			mid = ($low + $high) // 2
			range = ranges.get(start + mid) ?? { first: 1, last: 0, index: 0 }
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
	u32 = |bytes, at| LayoutGsub.u16(bytes, at) * 65536 + LayoutGsub.u16(bytes, at + 2)

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
	spend : List(U8), U64, U64 -> Try(U64, [Bad(U64)])
	spend = |data, steps, cost| {
		total = steps + cost + 1
		if (total > 8 * data.len() + 16384) Err(Bad(0)) else Ok(total)
	}

	## The lookups of a font file's `GSUB` that features reach, or none for a
	## font without `GSUB`. A table listing more than `max_lookups` lookups
	## is over the limit.
	from_tables : List(U8), List(Sfnt.Table), U64 -> Try(LayoutGsub, [BadTable({ table : Str, offset : U32 }), OverLimit(Str)])
	from_tables = |bytes, tables, max_lookups|
		match Sfnt.located(bytes, tables, "GSUB", 10) {
			Missing => Ok(LayoutGsub.none)
			Bad(at) => Err(Sfnt.bad("GSUB", at))
			Found({ data: gsub, offset }) =>
				if LayoutGsub.u16(gsub, LayoutGsub.u16(gsub, 8)) > max_lookups {
					Err(OverLimit("max_lookups"))
				} else {
					LayoutGsub.read(gsub).map_err(|Bad(at)| Sfnt.bad("GSUB", offset + at))
				}
		}

	## Read a `GSUB` table: its script and feature lists, every lookup a
	## feature lists, and every lookup their rules call. Problems give their
	## offset in the table.
	read : List(U8) -> Try(LayoutGsub, [Bad(U64)])
	read = |gsub| {
		read_common = LayoutCommon.read(gsub)?
		common = read_common.common
		lookups = LayoutGsub.u16(gsub, 8)
		lookup_count = common.lookup_count
		used = LayoutCommon.all_feature_lookups(common)
		start = LayoutGsub.indices(0, lookup_count).keep_if(|index| used.get(index) ?? False)
		# Read the chosen lookups and those their rules call.
		var $lookups = List.repeat(LayoutGsub.no_lookup, lookup_count)
		var $built = { subtables: [], ranges: [], values: [], rules: [], steps: read_common.steps }
		var $seen = List.repeat(False, lookup_count)
		var $pending = start
		while !$pending.is_empty() {
			index = $pending.last() ?? 0
			$pending = $pending.drop_last(1)
			if !($seen.get(index) ?? True) {
				# Every pending index is below `lookup_count`.
				$seen = $seen.set(index, True) ?? []
				lookup = lookups + LayoutGsub.u16(gsub, lookups + 2 + 2 * index)
				first = $built.subtables.len()
				$built = LayoutGsub.read_lookup(gsub, lookup, $built)?
				end = $built.subtables.len()
				var $mode = 0
				var $d0 = 0
				var $d1 = 0
				var $d2 = 0
				for k in first..<end {
					sub = $built.subtables.get(k) ?? LayoutGsub.no_sub
					$mode = if (sub.kind == 1) $mode else if (sub.kind == 4) $mode.max(1) else 2
					for r in sub.coverage..<(sub.coverage + sub.coverage_len) {
						range = $built.ranges.get(r) ?? { first: 1, last: 0, index: 0 }
						$d0 = LayoutGsub.digest_range($d0, 0, range.first, range.last)
						$d1 = LayoutGsub.digest_range($d1, 4, range.first, range.last)
						$d2 = LayoutGsub.digest_range($d2, 9, range.first, range.last)
					}
					if sub.kind == 5 {
						# The lookups this subtable's rules call, in rule order.
						rules_end = $built.values.get(sub.data + sub.data_len) ?? 0
						for r in ($built.values.get(sub.data) ?? 0)..<rules_end {
							rule = $built.rules.get(r) ?? LayoutGsub.no_rule
							for j in 0..<rule.records_len {
								called = $built.values.get(rule.records + 2 * j + 1) ?? 0
								if called >= lookup_count {
									return Err(Bad(lookup))
								}
								$pending = $pending.append(called)
							}
						}
					}
				}
				# `index < lookup_count`, the length of `$lookups`.
				$lookups = $lookups.set(index, { start: first, count: end - first, mode: $mode, d0: $d0, d1: $d1, d2: $d2 }) ?? []
			}
		}
		{ subtables, ranges, values, rules, steps: _ } = $built
		Ok({ common, lookups: $lookups, subtables, ranges, values, rules })
	}

	read_lookup : List(U8), U64, Built -> Try(Built, [Bad(U64)])
	read_lookup = |data, lookup, built| {
		kind = LayoutGsub.u16(data, lookup)
		count = LayoutGsub.u16(data, lookup + 4)
		if !LayoutGsub.fits(lookup, 6 + 2 * count, data.len()) {
			Err(Bad(lookup))
		} else {
			steps = LayoutGsub.spend(data, built.steps, count)?
			var $built = { ..built, steps }
			for s in 0..<count {
				at = lookup + LayoutGsub.u16(data, lookup + 6 + 2 * s)
				real = if kind == 7 {
					if !LayoutGsub.fits(at, 8, data.len()) {
						return Err(Bad(lookup))
					}
					{ kind: LayoutGsub.u16(data, at + 2), at: at + LayoutGsub.u32(data, at + 4) }
				} else {
					{ kind, at }
				}
				$built = LayoutGsub.read_subtable(data, real.kind, real.at, $built)?
			}
			Ok($built)
		}
	}

	read_subtable : List(U8), U64, U64, Built -> Try(Built, [Bad(U64)])
	read_subtable = |data, kind, at, { subtables, ranges, values, rules, steps }| {
		if !LayoutGsub.fits(at, 6, data.len()) {
			Err(Bad(at))
		} else {
			format = LayoutGsub.u16(data, at)
			if kind == 1 {
				cov = LayoutGsub.append_coverage(data, at + LayoutGsub.u16(data, at + 2), steps, ranges)?
				base = { ..LayoutGsub.no_sub, kind: 1, coverage: cov.start, coverage_len: cov.len }
				if format == 1 {
					raw = LayoutGsub.u16(data, at + 4).to_i64_wrap()
					delta = if (raw >= 32768) raw - 65536 else raw
					Ok({ subtables: subtables.append({ ..base, delta }), ranges: cov.ranges, values, rules, steps: cov.steps })
				} else if format == 2 {
					glyphs = LayoutGsub.count_u16s(data, at + 4, cov.steps)?
					first = values.len()
					var $values = values
					for k in 0..<glyphs.count {
						$values = $values.append(LayoutGsub.u16(data, at + 6 + 2 * k))
					}
					Ok({ subtables: subtables.append({ ..base, data: first, data_len: glyphs.count }), ranges: cov.ranges, values: $values, rules, steps: glyphs.steps })
				} else {
					Err(Bad(at))
				}
			} else if kind == 2 and format == 1 {
				cov = LayoutGsub.append_coverage(data, at + LayoutGsub.u16(data, at + 2), steps, ranges)?
				offsets = LayoutGsub.count_u16s(data, at + 4, cov.steps)?
				var $steps = offsets.steps
				# Bounds of each sequence, filled in as the sequences are read.
				bounds = values.len()
				var $values = values.concat(List.repeat(0, offsets.count + 1))
				for s in 0..<offsets.count {
					sequence_at = at + LayoutGsub.u16(data, at + 6 + 2 * s)
					seq = LayoutGsub.count_u16s(data, sequence_at, $steps)?
					$steps = seq.steps
					# `bounds + s` is within the slots added above.
					$values = $values.set(bounds + s, $values.len()) ?? []
					for k in 0..<seq.count {
						$values = $values.append(LayoutGsub.u16(data, sequence_at + 2 + 2 * k))
					}
				}
				$values = $values.set(bounds + offsets.count, $values.len()) ?? []
				sub = { ..LayoutGsub.no_sub, kind: 2, coverage: cov.start, coverage_len: cov.len, data: bounds, data_len: offsets.count }
				Ok({ subtables: subtables.append(sub), ranges: cov.ranges, values: $values, rules, steps: $steps })
			} else if kind == 4 and format == 1 {
				cov = LayoutGsub.append_coverage(data, at + LayoutGsub.u16(data, at + 2), steps, ranges)?
				offsets = LayoutGsub.count_u16s(data, at + 4, cov.steps)?
				var $steps = offsets.steps
				# Bounds of each ligature set, filled in as the sets are read.
				bounds = values.len()
				var $values = values.concat(List.repeat(0, offsets.count + 1))
				for s in 0..<offsets.count {
					set = at + LayoutGsub.u16(data, at + 6 + 2 * s)
					ligatures = LayoutGsub.count_u16s(data, set, $steps)?
					$steps = ligatures.steps
					# `bounds + s` is within the slots added above.
					$values = $values.set(bounds + s, $values.len()) ?? []
					for l in 0..<ligatures.count {
						lig = set + LayoutGsub.u16(data, set + 2 + 2 * l)
						count = LayoutGsub.u16(data, lig + 2)
						if count == 0 or !LayoutGsub.fits(lig, 2 + 2 * count, data.len()) {
							return Err(Bad(at))
						}
						$steps = LayoutGsub.spend(data, $steps, count)?
						$values = $values.append(LayoutGsub.u16(data, lig)).append(count - 1)
						for k in 1..<count {
							$values = $values.append(LayoutGsub.u16(data, lig + 2 + 2 * k))
						}
					}
				}
				$values = $values.set(bounds + offsets.count, $values.len()) ?? []
				sub = { ..LayoutGsub.no_sub, kind: 4, coverage: cov.start, coverage_len: cov.len, data: bounds, data_len: offsets.count }
				Ok({ subtables: subtables.append(sub), ranges: cov.ranges, values: $values, rules, steps: $steps })
			} else if kind == 5 or kind == 6 {
				LayoutGsub.read_context(data, kind == 6, format, at, { subtables, ranges, values, rules, steps })
			} else {
				# Alternate (3) and reverse chaining (8) substitutions are not
				# applied by default.
				Ok({ subtables, ranges, values, rules, steps })
			}
		}
	}

	read_context : List(U8), Bool, U64, U64, Built -> Try(Built, [Bad(U64)])
	read_context = |data, chained, format, at, { subtables, ranges, values, rules, steps }| {
		if format == 3 {
			if chained {
				back = LayoutGsub.append_coverages(data, at, at + 2, steps, ranges, values)?
				input_at = at + 4 + 2 * back.count
				input = LayoutGsub.append_coverages(data, at, input_at, back.steps, back.ranges, back.values)?
				ahead_at = input_at + 2 + 2 * input.count
				ahead = LayoutGsub.append_coverages(data, at, ahead_at, input.steps, input.ranges, input.values)?
				records = LayoutGsub.append_records(data, ahead_at + 2 + 2 * ahead.count, ahead.steps, ahead.values)?
				if input.count == 0 {
					Err(Bad(at))
				} else {
					rule = { back: back.start, back_len: back.count, input: input.start + 2, input_len: input.count - 1, ahead: ahead.start, ahead_len: ahead.count, records: records.start, records_len: records.count }
					LayoutGsub.context3_of(input.start, rule, { subtables, ranges: ahead.ranges, values: records.values, rules, steps: records.steps })
				}
			} else {
				count = LayoutGsub.u16(data, at + 2)
				record_count = LayoutGsub.u16(data, at + 4)
				if count == 0 or !LayoutGsub.fits(at, 6 + 2 * count, data.len()) {
					Err(Bad(at))
				} else {
					var $steps = steps
					var $ranges = ranges
					var $values = values
					first = $values.len()
					for k in 0..<count {
						coverage = LayoutGsub.append_coverage(data, at + LayoutGsub.u16(data, at + 6 + 2 * k), $steps, $ranges)?
						$steps = coverage.steps
						$ranges = coverage.ranges
						$values = $values.append(coverage.start).append(coverage.len)
					}
					records = LayoutGsub.append_record_list(data, at + 6 + 2 * count, record_count, $steps, $values)?
					rule = { ..LayoutGsub.no_rule, input: first + 2, input_len: count - 1, records: records.start, records_len: records.count }
					LayoutGsub.context3_of(first, rule, { subtables, ranges: $ranges, values: records.values, rules, steps: records.steps })
				}
			}
		} else if format == 1 or format == 2 {
			cov = LayoutGsub.append_coverage(data, at + LayoutGsub.u16(data, at + 2), steps, ranges)?
			var $steps = cov.steps
			var $ranges = cov.ranges
			by_class = format == 2
			# Offsets to class definitions, then to the rule sets. A null
			# offset (allowed for backtrack and lookahead classes) puts every
			# glyph in class 0.
			class_offsets = if (!by_class) [] else if (chained) [4, 6, 8] else [4]
			var $classes = []
			for o in class_offsets {
				offset = LayoutGsub.u16(data, at + o)
				if offset == 0 {
					$classes = $classes.append({ start: $ranges.len(), len: 0 })
				} else {
					classes = LayoutGsub.append_classes(data, at + offset, $steps, $ranges)?
					$steps = classes.steps
					$ranges = classes.ranges
					$classes = $classes.append({ start: classes.start, len: classes.len })
				}
			}
			sets_at = at + 4 + 2 * class_offsets.len()
			offsets = LayoutGsub.count_u16s(data, sets_at, $steps)?
			$steps = offsets.steps
			# Bounds of each rule set in `rules`, filled in as the sets are
			# read.
			bounds = values.len()
			var $values = values.concat(List.repeat(0, offsets.count + 1))
			var $rules = rules
			for s in 0..<offsets.count {
				o = LayoutGsub.u16(data, sets_at + 2 + 2 * s)
				# `bounds + s` is within the slots added above.
				$values = $values.set(bounds + s, $rules.len()) ?? []
				if o != 0 {
					set = at + o
					count = LayoutGsub.count_u16s(data, set, $steps)?
					$steps = count.steps
					for r in 0..<count.count {
						done = LayoutGsub.read_rule(data, chained, set + LayoutGsub.u16(data, set + 2 + 2 * r), $steps, $values, $rules)?
						$steps = done.steps
						$values = done.values
						$rules = done.rules
					}
				}
			}
			$values = $values.set(bounds + offsets.count, $rules.len()) ?? []
			absent = { start: 0, len: 0 }
			back_classes = $classes.get(0) ?? absent
			input_classes = if (chained) ($classes.get(1) ?? absent) else ($classes.get(0) ?? absent)
			ahead_classes = $classes.get(2) ?? absent
			sub = {
				kind: 5,
				coverage: cov.start,
				coverage_len: cov.len,
				delta: 0,
				data: bounds,
				data_len: offsets.count,
				match_kind: if (by_class) 1 else 0,
				back: back_classes.start,
				back_len: back_classes.len,
				input: input_classes.start,
				input_len: input_classes.len,
				ahead: ahead_classes.start,
				ahead_len: ahead_classes.len,
			}
			Ok({ subtables: subtables.append(sub), ranges: $ranges, values: $values, rules: $rules, steps: $steps })
		} else {
			Err(Bad(at))
		}
	}

	# A context subtable of format 3: one rule set holding one rule, whose
	# coverage is the first input coverage (a start and length at
	# `values[first]`).
	context3_of : U64, Rule, Built -> Try(Built, [Bad(U64)])
	context3_of = |first, rule, { subtables, ranges, values, rules, steps }| {
		coverage = values.get(first) ?? 0
		coverage_len = values.get(first + 1) ?? 0
		bounds = values.len()
		sub = { ..LayoutGsub.no_sub, kind: 5, coverage, coverage_len, data: bounds, data_len: 1, match_kind: 2 }
		Ok({ subtables: subtables.append(sub), ranges, values: values.append(rules.len()).append(rules.len() + 1), rules: rules.append(rule), steps })
	}

	read_rule : List(U8), Bool, U64, U64, List(U64), List(Rule) -> Try({ values : List(U64), rules : List(Rule), steps : U64 }, [Bad(U64)])
	read_rule = |data, chained, at, steps, values, rules| {
		if chained {
			back = LayoutGsub.count_u16s(data, at, steps)?
			back_start = values.len()
			var $values = values
			for k in 0..<back.count {
				$values = $values.append(LayoutGsub.u16(data, at + 2 + 2 * k))
			}
			input_at = at + 2 + 2 * back.count
			input_count = LayoutGsub.u16(data, input_at)
			if input_count == 0 or !LayoutGsub.fits(input_at, 2 + 2 * (input_count - 1), data.len()) {
				Err(Bad(at))
			} else {
				counted = LayoutGsub.spend(data, back.steps, input_count)?
				input_start = $values.len()
				for k in 1..<input_count {
					$values = $values.append(LayoutGsub.u16(data, input_at + 2 * k))
				}
				ahead_at = input_at + 2 * input_count
				ahead = LayoutGsub.count_u16s(data, ahead_at, counted)?
				ahead_start = $values.len()
				for k in 0..<ahead.count {
					$values = $values.append(LayoutGsub.u16(data, ahead_at + 2 + 2 * k))
				}
				records = LayoutGsub.append_records(data, ahead_at + 2 + 2 * ahead.count, ahead.steps, $values)?
				rule = { back: back_start, back_len: back.count, input: input_start, input_len: input_count - 1, ahead: ahead_start, ahead_len: ahead.count, records: records.start, records_len: records.count }
				Ok({ values: records.values, rules: rules.append(rule), steps: records.steps })
			}
		} else {
			input_count = LayoutGsub.u16(data, at)
			record_count = LayoutGsub.u16(data, at + 2)
			if input_count == 0 or !LayoutGsub.fits(at, 4 + 2 * (input_count - 1), data.len()) {
				Err(Bad(at))
			} else {
				counted = LayoutGsub.spend(data, steps, input_count)?
				input_start = values.len()
				var $values = values
				for k in 1..<input_count {
					$values = $values.append(LayoutGsub.u16(data, at + 2 + 2 * k))
				}
				records = LayoutGsub.append_record_list(data, at + 2 + 2 * input_count, record_count, counted, $values)?
				rule = { ..LayoutGsub.no_rule, input: input_start, input_len: input_count - 1, records: records.start, records_len: records.count }
				Ok({ values: records.values, rules: rules.append(rule), steps: records.steps })
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

	# A count followed by that many 16-bit values: checks they fit and
	# spends the work of reading them, returning the count.
	count_u16s : List(U8), U64, U64 -> Try({ count : U64, steps : U64 }, [Bad(U64)])
	count_u16s = |data, at, steps| {
		count = LayoutGsub.u16(data, at)
		if !LayoutGsub.fits(at, 2 + 2 * count, data.len()) {
			Err(Bad(at))
		} else {
			after = LayoutGsub.spend(data, steps, count)?
			Ok({ count, steps: after })
		}
	}

	# A count at `at` followed by offsets (from `base`) to coverage tables.
	# Each coverage is added to `ranges`, and its start and length to
	# `values` from `start`.
	append_coverages : List(U8), U64, U64, U64, Ranges, List(U64) -> Try({ start : U64, count : U64, ranges : Ranges, values : List(U64), steps : U64 }, [Bad(U64)])
	append_coverages = |data, base, at, steps, ranges, values| {
		offsets = LayoutGsub.count_u16s(data, at, steps)?
		var $steps = offsets.steps
		var $ranges = ranges
		var $values = values
		start = $values.len()
		for k in 0..<offsets.count {
			coverage = LayoutGsub.append_coverage(data, base + LayoutGsub.u16(data, at + 2 + 2 * k), $steps, $ranges)?
			$steps = coverage.steps
			$ranges = coverage.ranges
			$values = $values.append(coverage.start).append(coverage.len)
		}
		Ok({ start, count: offsets.count, ranges: $ranges, values: $values, steps: $steps })
	}

	append_records : List(U8), U64, U64, List(U64) -> Try({ start : U64, count : U64, values : List(U64), steps : U64 }, [Bad(U64)])
	append_records = |data, at, steps, values| LayoutGsub.append_record_list(data, at + 2, LayoutGsub.u16(data, at), steps, values)

	# Nested lookup records, added to `values` as `at, lookup` pairs.
	append_record_list : List(U8), U64, U64, U64, List(U64) -> Try({ start : U64, count : U64, values : List(U64), steps : U64 }, [Bad(U64)])
	append_record_list = |data, at, count, steps, values|
		if !LayoutGsub.fits(at, 4 * count, data.len()) {
			Err(Bad(at))
		} else {
			after = LayoutGsub.spend(data, steps, count)?
			start = values.len()
			var $values = values
			for k in 0..<count {
				$values = $values.append(LayoutGsub.u16(data, at + 4 * k)).append(LayoutGsub.u16(data, at + 4 * k + 2))
			}
			Ok({ start, count, values: $values, steps: after })
		}

	## A coverage table as ranges of glyphs with their first coverage index.
	read_coverage : List(U8), U64, U64 -> Try({ value : Ranges, steps : U64 }, [Bad(U64)])
	read_coverage = |data, at, steps| {
		done = LayoutGsub.append_coverage(data, at, steps, [])?
		Ok({ value: done.ranges, steps: done.steps })
	}

	# A coverage table, added to `ranges` from `start` (`len` ranges).
	# Consecutive glyphs of a format 1 table are merged into one range.
	append_coverage : List(U8), U64, U64, Ranges -> Try({ start : U64, len : U64, ranges : Ranges, steps : U64 }, [Bad(U64)])
	append_coverage = |data, at, steps, ranges| {
		format = LayoutGsub.u16(data, at)
		count = LayoutGsub.u16(data, at + 2)
		start = ranges.len()
		if format == 1 and LayoutGsub.fits(at, 4 + 2 * count, data.len()) {
			after = LayoutGsub.spend(data, steps, count)?
			var $out = ranges
			for i in 0..<count {
				g = LayoutGsub.u16(data, at + 4 + 2 * i)
				merged = if $out.len() > start {
					match $out.last() {
						Ok(last) if last.last + 1 == g and last.index + (last.last - last.first) + 1 == i => Ok({ first: last.first, last: g, index: last.index })
						_ => Err(NotMerged)
					}
				} else {
					Err(NotMerged)
				}
				$out = match merged {
					# The list is not empty: it holds the range being merged.
					Ok(range) => $out.set($out.len() - 1, range) ?? []
					Err(_) => $out.append({ first: g, last: g, index: i })
				}
			}
			Ok({ start, len: $out.len() - start, ranges: $out, steps: after })
		} else if format == 2 and LayoutGsub.fits(at, 4 + 6 * count, data.len()) {
			after = LayoutGsub.spend(data, steps, count)?
			Ok({ start, len: count, ranges: LayoutGsub.append_range_records(data, at + 4, count, ranges), steps: after })
		} else {
			Err(Bad(at))
		}
	}

	## A class definition as ranges whose `index` is the class.
	read_classes : List(U8), U64, U64 -> Try({ value : Ranges, steps : U64 }, [Bad(U64)])
	read_classes = |data, at, steps| {
		done = LayoutGsub.append_classes(data, at, steps, [])?
		Ok({ value: done.ranges, steps: done.steps })
	}

	# A class definition, added to `ranges` from `start` (`len` ranges).
	append_classes : List(U8), U64, U64, Ranges -> Try({ start : U64, len : U64, ranges : Ranges, steps : U64 }, [Bad(U64)])
	append_classes = |data, at, steps, ranges| {
		format = LayoutGsub.u16(data, at)
		start = ranges.len()
		if format == 1 and LayoutGsub.fits(at, 6, data.len()) {
			first = LayoutGsub.u16(data, at + 2)
			count = LayoutGsub.u16(data, at + 4)
			if LayoutGsub.fits(at + 6, 2 * count, data.len()) {
				after = LayoutGsub.spend(data, steps, count)?
				var $out = ranges
				for k in 0..<count {
					$out = $out.append({ first: first + k, last: first + k, index: LayoutGsub.u16(data, at + 6 + 2 * k) })
				}
				Ok({ start, len: count, ranges: $out, steps: after })
			} else {
				Err(Bad(at))
			}
		} else if format == 2 and LayoutGsub.fits(at, 4, data.len()) {
			count = LayoutGsub.u16(data, at + 2)
			if LayoutGsub.fits(at + 4, 6 * count, data.len()) {
				after = LayoutGsub.spend(data, steps, count)?
				Ok({ start, len: count, ranges: LayoutGsub.append_range_records(data, at + 4, count, ranges), steps: after })
			} else {
				Err(Bad(at))
			}
		} else {
			Err(Bad(at))
		}
	}

	# Range records (first, last, value). They should be in increasing order
	# without overlaps, and lookups by binary search assume so, but they are
	# not checked: some fonts in use break the rule, and browsers read them
	# anyway. A range whose last glyph comes before its first matches no
	# glyph.
	append_range_records : List(U8), U64, U64, Ranges -> Ranges
	append_range_records = |data, at, count, ranges| {
		var $out = ranges
		for i in 0..<count {
			r = at + 6 * i
			$out = $out.append({ first: LayoutGsub.u16(data, r), last: LayoutGsub.u16(data, r + 2), index: LayoutGsub.u16(data, r + 4) })
		}
		$out
	}
}
