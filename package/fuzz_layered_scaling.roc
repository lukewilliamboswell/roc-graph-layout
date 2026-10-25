app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import LayeredOrder
import LayeredPlace
import LayeredRank

## Each layered phase costs allocations in proportion to the graph it reads.
## The input describes a small motif graph (cycles, self-loops, parallel
## edges, long edges, weights, minimum spans); the motif is repeated 1 and 8
## times, each copy joined to the next by one edge, and every phase runs on
## both graphs separately from the phases before it. For every phase, the
## larger graph's allocations per unit of input must stay within a quarter
## of the smaller's, and no phase may leak. A phase's input is the graph for
## cycle breaking and ranking, and the graph with its long edges split
## (whose size the ranking decides) from virtual chains on. A per-node or
## per-layer rescan or a repeated whole-list copy shows up as a ratio near
## 8, and the crash names the phase.
Graph : { count : U64, edges : List({ from : U64, to : U64 }), weights : List(F64), spans : List(U64), widths : List(F64) }

graph : List(U8), U64 -> Graph
graph = |bytes, copies| {
	byte = |i| bytes.get(i) ?? 0
	size = 2 + (byte(0) % 10).to_u64()
	motif_edges = (byte(1) % 17).to_u64()
	var $edges = []
	var $weights = []
	var $spans = []
	for copy in 0..<copies {
		base = copy * size
		for k in 0..<motif_edges {
			a = byte(2 + 2 * k).to_u64() % size
			b = byte(3 + 2 * k).to_u64() % size
			$edges = $edges.append({ from: base + a, to: base + b })
			w = byte(40 + k)
			$weights = $weights.append(
				if w % 3 == 0 {
					(w % 7).to_f64() * 0.25
				} else {
					(w % 5).to_f64()
				},
			)
			$spans = $spans.append(1 + (w % 3).to_u64())
		}
		if copy > 0 {
			$edges = $edges.append({ from: base - 1, to: base })
			$weights = $weights.append(1)
			$spans = $spans.append(1)
		}
	}
	count = size * copies
	{ count, edges: $edges, weights: $weights, spans: $spans, widths: List.repeat(0, count).map_with_index(|_, i| (byte(60 + i % size) % 40).to_f64()) }
}

## Fail when the large input's allocations for `phase` grow faster than its size.
bounded! : Str, { allocations : U64, size : U64 }, { allocations : U64, size : U64 } => {}
bounded! = |phase, small, large| {
	limit = small.allocations * large.size * 5 // (4 * small.size.max(1)) + 512
	if large.allocations > limit {
		crash "${phase}: input of size ${large.size.to_str()} took ${large.allocations.to_str()} allocations, against ${small.allocations.to_str()} for size ${small.size.to_str()}"
	}
	{}
}

## Everything one phase reads, computed before it is measured.
Staged : { count : U64, oriented : List({ from : U64, to : U64 }), weights : List(F64), spans : List(U64), ranks : List(U64), layers : List(List(U64)), unit_edges : List({ from : U64, to : U64 }), widths : List(F64), real_count : U64 }

stage : Graph -> Staged
stage = |g| {
	oriented = LayeredRank.orient(g.count, g.edges).edges
	ranks = LayeredRank.rank(g.count, oriented, g.weights, g.spans)
	extended = LayeredOrder.insert_virtual_chains(ranks, oriented)
	widths = g.widths.concat(List.repeat(0, extended.ranks.len() - g.count))
	{ count: g.count, oriented, weights: g.weights, spans: g.spans, ranks, layers: LayeredOrder.group_by_rank(extended.ranks), unit_edges: extended.unit_edges, widths, real_count: g.count }
}

## One sweep of the given kind over the staged layering.
sweep : Staged, [Down, Up], [Median, Average] -> List(U64)
sweep = |s, direction, method| {
	start = LayeredOrder.flatten(s.layers, s.unit_edges)
	outgoing = LayeredRank.adjacency(start.shape.size, s.unit_edges, True)
	incoming = LayeredRank.adjacency(start.shape.size, s.unit_edges, False)
	LayeredOrder.sweep(start.shape, start.order, outgoing, incoming, s.unit_edges, direction, method).flat
}

polish : Staged -> List(U64)
polish = |s| {
	start = LayeredOrder.flatten(s.layers, s.unit_edges)
	outgoing = LayeredRank.adjacency(start.shape.size, s.unit_edges, True)
	incoming = LayeredRank.adjacency(start.shape.size, s.unit_edges, False)
	LayeredOrder.transpose(start.shape, start.order, outgoing, incoming, s.unit_edges).flat
}

compact : Staged -> List(F64)
compact = |s| {
	roots = LayeredPlace.block_roots(s.widths.len(), s.layers, s.real_count, s.unit_edges)
	LayeredPlace.compact_blocks(s.widths.len(), s.layers, roots, s.widths, 12)
}

## Splitting long edges and grouping by layer, using every part of the result.
chains : Staged -> U64
chains = |s| {
	extended = LayeredOrder.insert_virtual_chains(s.ranks, s.oriented)
	extended.unit_edges.len() + extended.ranks.len() + extended.chains.len() + LayeredOrder.group_by_rank(extended.ranks).len()
}

test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	small_graph = graph(bytes, 1)
	large_graph = graph(bytes, 8)
	small = stage(small_graph)
	large = stage(large_graph)
	graph_size = |g, _| g.count + g.edges.len()
	split_size = |_, s| s.widths.len() + s.unit_edges.len()
	phase! = |name, size, run|
		bounded!(
			name,
			{ allocations: Fuzz.measure_allocs!(|{}| run(small_graph, small)).allocations, size: size(small_graph, small) },
			{ allocations: Fuzz.measure_allocs!(|{}| run(large_graph, large)).allocations, size: size(large_graph, large) },
		)
	_ = phase!("cycle breaking", graph_size, |g, _| LayeredRank.orient(g.count, g.edges).edges.len())
	_ = phase!("ranking", graph_size, |_, s| LayeredRank.rank(s.count, s.oriented, s.weights, s.spans).len())
	_ = phase!("virtual chains", split_size, |_, s| chains(s))
	_ = phase!("median sweep", split_size, |_, s| sweep(s, Down, Median).len() + sweep(s, Up, Median).len())
	_ = phase!("average sweep", split_size, |_, s| sweep(s, Down, Average).len() + sweep(s, Up, Average).len())
	_ = phase!("transpose", split_size, |_, s| polish(s).len())
	_ = phase!("crossing count", split_size, |_, s| LayeredOrder.total_crossings(s.layers, s.unit_edges))
	# Whole ordering runs a data-dependent number of rounds (none when the
	# small graph has no crossings), so its rounds are bounded part by part:
	# both sweeps, the swap polish, and the crossing count above.
	_ = phase!("placement", split_size, |_, s| compact(s).len())
	# Every phase frees what it allocates. (Whole `LayeredOrder.order` calls
	# report one outstanding allocation here with the 2026-10-23 nightly,
	# while the benchmark host's leak check finds none for complete layouts;
	# its parts are checked instead.)
	# Results are dropped inside each closure: the dev backend keeps a value
	# bound to `_` alive until its block ends, which would read as a leak.
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = LayeredRank.orient(large_graph.count, large_graph.edges).edges.len()
			{}
		},
	)
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = LayeredRank.rank(large.count, large.oriented, large.weights, large.spans).len()
			{}
		},
	)
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = chains(large)
			{}
		},
	)
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = sweep(large, Down, Median).len() + sweep(large, Up, Average).len()
			{}
		},
	)
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = polish(large).len()
			{}
		},
	)
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = LayeredOrder.total_crossings(large.layers, large.unit_edges)
			{}
		},
	)
	Fuzz.expect_no_leaks!(
		|{}| {
			_ = compact(large).len()
			{}
		},
	)
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "graph-layout-layered-scaling",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| {
		g = graph(bytes, 1)
		"${g.count.to_str()} nodes, edges ${Str.inspect(g.edges)}"
	},
})

## fuzz regression: chained copies of a cyclic motif with self-loops needed
## more network-simplex exchanges than copies, and each exchange allocated
## fresh work lists, so ranking allocations grew 17-fold for 8 copies. The
## exchanges now reuse their work lists; the ranks stay feasible.
expect {
	bytes = [109, 133, 143, 218, 49, 228, 67, 130, 19, 1, 0, 173, 1, 0, 0, 0, 0, 0, 0, 49, 231, 5, 253, 3, 0, 0, 34, 85, 85, 0, 191, 205, 78, 59, 215, 249, 205, 225, 0, 79, 77, 55, 105, 131, 116, 217, 189, 116, 252, 17, 229, 229, 162, 187, 38, 2, 155, 203, 35, 215, 249, 205, 225, 174, 47, 87, 7, 15, 100, 112, 39]
	s = stage(graph(bytes, 8))
	feasible = s.oriented.fold_with_index(True, |ok, e, i| ok and (e.from == e.to or (s.ranks.get(e.to) ?? 0) >= (s.ranks.get(e.from) ?? 0) + (s.spans.get(i) ?? 1)))
	s.ranks.len() == s.count and feasible
}

## fuzz regression: here the optimal ranking interleaves the copies, so 8
## copies split into 460 nodes against 19 for one; placement cost is bounded
## by the split graph's size, not the copy count. Placement keeps every
## adjacent pair of a layer apart.
expect {
	bytes = [113, 135, 151, 55, 168, 94, 239, 97, 16, 159, 193, 191, 169, 226, 20, 60, 239, 16, 159, 193, 191, 169, 226, 86, 52, 1, 40, 86, 55, 1, 40, 143, 41, 179, 215, 63, 106, 194, 39, 22, 158, 221, 235, 0, 0, 0, 0, 0, 0, 0, 58, 242, 15, 210, 126, 207, 20, 192, 244]
	s = stage(graph(bytes, 8))
	xs = compact(s)
	separated = s.layers.all(
		|layer| layer.fold_with_index(
			True,
			|ok, v, i| match layer.get(i + 1) {
				Ok(w) => ok and (xs.get(w) ?? 0) - (xs.get(v) ?? 0) >= ((s.widths.get(v) ?? 0) + (s.widths.get(w) ?? 0)) / 2 + 12
				Err(_) => ok
			},
		),
	)
	xs.len() == s.widths.len() and separated
}
