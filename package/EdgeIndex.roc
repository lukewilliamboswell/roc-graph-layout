## Stable source-indexed adjacency shared by ranking and layout phases.
## Offset tables avoid nested growing lists and preserve input edge order.
EdgeIndex :: {}.{
	Table : { offsets : List(U64), items : List(U64) }

	## Table of `edges` grouped by source (`by_from`) or target. Edges
	## with an endpoint outside `0 ..< node_count` are left out.
	build : U64, List({ from : U64, to : U64 }), Bool -> Table
	build = |node_count, edges, by_from| {
		var $offsets = List.repeat(0, node_count + 1)
		for e in edges {
			key = if by_from {
				e.from
			} else {
				e.to
			}
			if key < node_count and e.from < node_count and e.to < node_count {
				$offsets = $offsets.set(key + 1, ($offsets.get(key + 1) ?? 0) + 1) ?? []
			}
		}
		for i in 0..<node_count {
			$offsets = $offsets.set(i + 1, ($offsets.get(i + 1) ?? 0) + ($offsets.get(i) ?? 0)) ?? []
		}
		offsets = $offsets
		var $fill = offsets
		var $items = List.repeat(0, offsets.get(node_count) ?? 0)
		for i in 0..<edges.len() {
			e = edges.get(i) ?? { from: 0, to: 0 }
			key = if by_from {
				e.from
			} else {
				e.to
			}
			if key < node_count and e.from < node_count and e.to < node_count {
				at = $fill.get(key) ?? 0
				$items = $items.set(at, i) ?? []
				$fill = $fill.set(key, at + 1) ?? []
			}
		}
		{ offsets, items: $items }
	}

	## The edge indices of node `v` in an adjacency table.
	items : Table, U64 -> List(U64)
	items = |adj, v| {
		start = adj.offsets.get(v) ?? 0
		end = adj.offsets.get(v + 1) ?? start
		adj.items.sublist({ start, len: end - start })
	}

}
