app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import RouteLanes

## Lane separation agrees with its definition: a movable segment moves by
## its rank among the movable segments it overlaps on the same line, centred
## on the line, and every other segment keeps its coordinate. The input
## gives segments on a few shared lines (so overlaps, touching ends, equal
## extents and both directions are common), already in edge and segment
## order as the router lists them.
##
## The segments are also repeated as 1 and 8 copies, each copy on its own
## lines; separating the copies may allocate at most a little more than 8
## times as often as one, and frees everything. Placing all 8 copies on the
## same lines must also stay within that bound, since one line of many
## overlapping segments is counted with sorted ends, not pairwise.
segments : List(U8), U64, Bool -> List(RouteLanes.Segment)
segments = |bytes, copies, shared_lines| {
	byte = |i| (bytes.get(i) ?? 0).to_u64()
	count = byte(0) % 24
	var $out = []
	for copy in 0..<copies {
		line_shift = if shared_lines {
			0
		} else {
			copy.to_f64() * 1000
		}
		for k in 0..<count {
			low = (byte(10 + 3 * k) % 9).to_f64() * 5
			span = (byte(11 + 3 * k) % 4).to_f64() * 5
			flags = byte(12 + 3 * k)
			$out = $out.append({
				edge: copy * count + k / 3,
				index: k % 3,
				horizontal: flags % 2 == 0,
				coord: (flags / 2 % 3).to_f64() * 10 + line_shift,
				low,
				high: low + span,
				movable: flags / 6 % 4 != 0 and span > 0,
			})
		}
	}
	$out
}

## The original definition: compare with every other segment.
reference : List(RouteLanes.Segment), F64 -> List(F64)
reference = |all, gap| all.map(
	|segment| if !segment.movable {
		segment.coord
	} else {
		peers = all.keep_if(|other| other.movable and other.horizontal == segment.horizontal and other.coord == segment.coord and other.low < segment.high and segment.low < other.high)
		if peers.len() <= 1 {
			segment.coord
		} else {
			rank = peers.find_first_index(|other| other.edge == segment.edge and other.index == segment.index) ?? 0
			segment.coord + (rank.to_f64() - (peers.len() - 1).to_f64() / 2) * gap
		}
	},
)

same_bits : List(F64), List(F64) -> Bool
same_bits = |a, b| a.len() == b.len() and a.map_with_index(|x, i| { x, i }).all(|item| item.x.to_bits() == (b.get(item.i) ?? F64.nan).to_bits())

test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	gap = (bytes.get(1) ?? 0).to_f64() / 8
	small = segments(bytes, 1, False)
	if !same_bits(RouteLanes.lanes(small, gap), reference(small, gap)) {
		crash "lane separation disagrees with its definition"
	}
	stacked = segments(bytes, 3, True)
	if !same_bits(RouteLanes.lanes(stacked, gap), reference(stacked, gap)) {
		crash "lane separation disagrees with its definition on a crowded line"
	}
	small_cost = Fuzz.measure_allocs!(|{}| RouteLanes.lanes(small, gap)).allocations
	apart = segments(bytes, 8, False)
	together = segments(bytes, 8, True)
	apart_cost = Fuzz.measure_allocs!(|{}| RouteLanes.lanes(apart, gap)).allocations
	together_cost = Fuzz.measure_allocs!(|{}| RouteLanes.lanes(together, gap)).allocations
	# Results are dropped inside each closure: the dev backend keeps a value
	# bound to `_` alive until its block ends, which would read as a leak.
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = RouteLanes.lanes(together, gap)
			{}
		},
	)
	if apart_cost > small_cost * 10 + 256 or together_cost > small_cost * 10 + 256 {
		crash "8 copies took ${apart_cost.to_str()} (apart) and ${together_cost.to_str()} (together) allocations, against ${small_cost.to_str()} for one"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "graph-layout-route-lanes",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect(segments(bytes, 1, False)),
})

expect {
	List.repeat(0, 96).map_with_index(|_, i| i).all(
		|seed| {
			bytes = List.repeat(0, 96).map_with_index(|_, i| ((i * 29 + seed * 113 + (i * seed) % 19) % 256).to_u8_wrap())
			gap = (seed % 7).to_f64()
			one = segments(bytes, 1, False)
			crowded = segments(bytes, 3, True)
			same_bits(RouteLanes.lanes(one, gap), reference(one, gap)) and same_bits(RouteLanes.lanes(crowded, gap), reference(crowded, gap))
		},
	)
}
