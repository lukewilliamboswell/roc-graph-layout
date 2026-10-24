app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import EdgeRoutes
import RoutePorts

## Port spreading and parallel-edge ranks agree with their definitions.
##
## Route ends sharing a port are grouped by node, side and exact point
## (where `-0.0` and `0.0` are the same point) and ranked by their opposite
## ends with the edge index as the final tie-break, exactly as counting
## every earlier end of the same group would. Edges joining the same
## unordered node pair are ranked in edge order, exactly as scanning every
## earlier edge would.
##
## The input is also repeated as 1 and 8 copies on disjoint nodes. Both
## rankings may allocate at most a little more than 8 times as often for
## the copies, and free everything. Sorted, reverse-sorted and equal keys
## are common, so a quadratic sort or rescan shows up here.
End : { edge : U64, node : U64, side : U64, x : F64, y : F64, primary : F64, secondary : F64 }

ends : List(U8), U64 -> List(End)
ends = |bytes, copies| {
	byte = |i| (bytes.get(i) ?? 0).to_u64()
	count = byte(0) % 32
	order = byte(1) % 3
	var $out = []
	for copy in 0..<copies {
		for k in 0..<count {
			b = byte(8 + 2 * k)
			key = if order == 0 {
				k.to_f64()
			} else if order == 1 {
				(count - k).to_f64()
			} else {
				(byte(9 + 2 * k) % 3).to_f64()
			}
			$out = $out.append({
				edge: copy * count + k,
				node: copy * 4 + b % 3,
				side: b / 3 % 2,
				x: if b / 6 % 3 == 0 {
					-0.0
				} else {
					(b / 6 % 3).to_f64()
				},
				y: 0,
				primary: key,
				secondary: (b / 18 % 2).to_f64(),
			})
		}
	}
	$out
}

pairs : List(U8), U64 -> List({ from : U64, to : U64 })
pairs = |bytes, copies| {
	byte = |i| (bytes.get(i) ?? 0).to_u64()
	count = byte(2) % 40
	List.repeat(0, copies * count).map_with_index(
		|_, i| {
			copy = i / count.max(1)
			k = i % count.max(1)
			{ from: copy * 5 + byte(80 + 2 * k) % 5, to: copy * 5 + byte(81 + 2 * k) % 5 }
		},
	)
}

group_before = |items| |a, b| {
	p = items.get(a) ?? { edge: 0, node: 0, side: 0, x: 0, y: 0, primary: 0, secondary: 0 }
	q = items.get(b) ?? p
	if p.node != q.node {
		p.node < q.node
	} else if p.side != q.side {
		p.side < q.side
	} else if p.x != q.x {
		p.x < q.x
	} else {
		p.y < q.y
	}
}

same_group = |items| |a, b| {
	p = items.get(a) ?? { edge: 0, node: 0, side: 0, x: 0, y: 0, primary: 0, secondary: 0 }
	q = items.get(b) ?? p
	p.node == q.node and p.side == q.side and p.x == q.x and p.y == q.y
}

before = |items| |a, b| {
	p = items.get(a) ?? { edge: 0, node: 0, side: 0, x: 0, y: 0, primary: 0, secondary: 0 }
	q = items.get(b) ?? p
	if p.primary < q.primary {
		True
	} else if p.primary > q.primary {
		False
	} else if p.secondary < q.secondary {
		True
	} else if p.secondary > q.secondary {
		False
	} else {
		p.edge < q.edge
	}
}

ranked : List(End) -> List({ rank : U64, count : U64 })
ranked = |items| RoutePorts.ranks(items.len(), group_before(items), same_group(items), before(items))

## Count, for every end, the ends of its group and those before it.
reference_ranks : List(End) -> List({ rank : U64, count : U64 })
reference_ranks = |items| items.map_with_index(
	|_, i| {
		group = List.repeat(0, items.len()).map_with_index(|_, j| j).keep_if(|j| (same_group(items))(i, j))
		{ rank: group.keep_if(|j| (before(items))(j, i)).len(), count: group.len() }
	},
)

reference_parallel : List({ from : U64, to : U64 }) -> List({ rank : U64, count : U64 })
reference_parallel = |edges| {
	key = |e| { lo: e.from.min(e.to), hi: e.from.max(e.to) }
	edges.map_with_index(
		|edge, i| {
			same = |other| key(other) == key(edge)
			{ rank: edges.take_first(i).keep_if(same).len(), count: edges.keep_if(same).len() }
		},
	)
}

test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	small = ends(bytes, 1)
	if ranked(small) != reference_ranks(small) {
		crash "port ranks disagree with their definition"
	}
	small_pairs = pairs(bytes, 1)
	if EdgeRoutes.parallel_ranks(small_pairs) != reference_parallel(small_pairs) {
		crash "parallel ranks disagree with their definition"
	}
	large = ends(bytes, 8)
	large_pairs = pairs(bytes, 8)
	small_cost = Fuzz.measure_allocs!(|{}| ranked(small)).allocations + Fuzz.measure_allocs!(|{}| EdgeRoutes.parallel_ranks(small_pairs)).allocations
	large_cost = Fuzz.measure_allocs!(|{}| ranked(large)).allocations + Fuzz.measure_allocs!(|{}| EdgeRoutes.parallel_ranks(large_pairs)).allocations
	Fuzz.expect_no_leaks!(|{}| ranked(large))
	Fuzz.expect_no_leaks!(|{}| EdgeRoutes.parallel_ranks(large_pairs))
	if large_cost > small_cost * 10 + 256 {
		crash "8 copies took ${large_cost.to_str()} allocations, against ${small_cost.to_str()} for one"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "graph-layout-route-ports",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect({ ends: ends(bytes, 1), pairs: pairs(bytes, 1) }),
})

expect {
	List.repeat(0, 96).map_with_index(|_, i| i).all(
		|seed| {
			bytes = List.repeat(0, 200).map_with_index(|_, i| ((i * 41 + seed * 59 + (i * seed) % 13) % 256).to_u8_wrap())
			items = ends(bytes, 2)
			edges = pairs(bytes, 2)
			ranked(items) == reference_ranks(items) and EdgeRoutes.parallel_ranks(edges) == reference_parallel(edges)
		},
	)
}
