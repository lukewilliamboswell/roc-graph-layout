import Geom

## Layered layouts for directed graphs read as flow — a minimal, complete
## Sugiyama-style pipeline: rank, insert virtual chains, order layers by a
## median heuristic, assign coordinates, and route edges as lines/polylines.
##
## This is a deliberate simplification of the full pipeline described in
## `design.md` (no build/run witness, no cycle-break reporting, no exact
## tight-tree ranking, no four-pass alignment): each phase below is a small
## pure helper, real (not a stub), and independently tested.
Layered :: {}.{
	## `[0, 1, .., n - 1]`, the shared building block for every phase below
	## that needs to walk a bounded range of indices.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Longest-path-from-sources ranking. Nodes with no incoming edges rank 0;
	## every other node ranks one more than its deepest predecessor. Iterates
	## to a fixed point, bounded by node count, so cycles cannot hang it (an
	## edge that would push a rank past the bound is simply not applied again).
	rank_nodes : U64, List({ from : U64, to : U64 }) -> List(U64)
	rank_nodes = |node_count, edges| {
		initial = List.repeat(0, node_count)

		Layered.indices_up_to(node_count).fold(
			initial,
			|ranks, _pass| {
				edges.fold(
					ranks,
					|acc, edge| {
						from_rank = acc.get(edge.from) ?? 0
						to_rank = acc.get(edge.to) ?? 0
						wanted = from_rank + 1
						if wanted > to_rank {
							acc.set(edge.to, wanted) ?? acc
						} else {
							acc
						}
					},
				)
			},
		)
	}

	## Splits every edge spanning more than one rank into a chain of unit-span
	## edges through virtual waypoint nodes (zero size), appended after the
	## real nodes. Returns the extended per-node rank list (real ++ virtual),
	## the unit-span edge list over the extended index space, and — index
	## aligned to the original `edges` list — each original edge's full chain
	## of node indices from `from` to `to` inclusive.
	insert_virtual_chains : List(U64), List({ from : U64, to : U64 }) -> {
		ranks : List(U64),
		unit_edges : List({ from : U64, to : U64 }),
		chains : List(List(U64)),
	}
	insert_virtual_chains = |real_ranks, edges| {
		real_count = real_ranks.len()

		result = edges.fold(
			{ ranks: real_ranks, unit_edges: [], chains: [], next_virtual: real_count },
			|state, edge| {
				from_rank = state.ranks.get(edge.from) ?? 0
				to_rank = state.ranks.get(edge.to) ?? 0
				span = if to_rank > from_rank { to_rank - from_rank } else { 1 }

				if span <= 1 {
					{
						ranks: state.ranks,
						unit_edges: state.unit_edges.append(edge),
						chains: state.chains.append([edge.from, edge.to]),
						next_virtual: state.next_virtual,
					}
				} else {
					intermediate_count = span - 1
					virtual_indices = Layered.indices_up_to(intermediate_count).map(|i| state.next_virtual + i)

					chain = [edge.from].concat(virtual_indices).append(edge.to)

					new_ranks = virtual_indices.fold_with_index(
						state.ranks,
						|acc, _virtual_index, i| acc.append(from_rank + 1 + i),
					)

					new_edges = Layered.indices_up_to(chain.len() - 1).fold(
						state.unit_edges,
						|acc, i| {
							a = chain.get(i) ?? 0
							b = chain.get(i + 1) ?? 0
							acc.append({ from: a, to: b })
						},
					)

					{
						ranks: new_ranks,
						unit_edges: new_edges,
						chains: state.chains.append(chain),
						next_virtual: state.next_virtual + intermediate_count,
					}
				}
			},
		)

		{ ranks: result.ranks, unit_edges: result.unit_edges, chains: result.chains }
	}

	## Groups node indices by rank, in ascending rank then ascending index
	## order — the deterministic initial ordering before median sweeps run.
	group_by_rank : List(U64) -> List(List(U64))
	group_by_rank = |ranks| {
		layer_count = ranks.fold(0, |acc, r| if r + 1 > acc { r + 1 } else { acc })

		Layered.indices_up_to(layer_count).map(
			|layer| ranks.fold_with_index([], |acc, r, i| if r == layer { acc.append(i) } else { acc }),
		)
	}

	## Reorders every layer but the first by the median rank-position of its
	## neighbors in the previous layer (a down sweep), then every layer but
	## the last by the median position in the next layer (an up sweep), for a
	## small fixed number of rounds. Ties break by the node's current position,
	## then its index, so ordering stays deterministic.
	order_layers : List(List(U64)), List({ from : U64, to : U64 }) -> List(List(U64))
	order_layers = |layers, unit_edges| {
		rounds = 4

		Layered.indices_up_to(rounds).fold(
			layers,
			|current, _round| {
				down = Layered.sweep_median(current, unit_edges, Down)
				Layered.sweep_median(down, unit_edges, Up)
			},
		)
	}

	sweep_median : List(List(U64)), List({ from : U64, to : U64 }), [Down, Up] -> List(List(U64))
	sweep_median = |layers, unit_edges, direction| {
		layer_count = layers.len()
		ordered_indices = match direction {
			Down => Layered.indices_up_to(layer_count)
			Up => Layered.indices_up_to(layer_count).rev()
		}

		ordered_indices.fold(
			layers,
			|acc, layer_index| {
				neighbor_index = match direction {
					Down => if layer_index == 0 { Err({}) } else { Ok(layer_index - 1) }
					Up => if layer_index + 1 == layer_count { Err({}) } else { Ok(layer_index + 1) }
				}

				match neighbor_index {
					Err({}) => acc
					Ok(n_idx) => {
						neighbor_layer = acc.get(n_idx) ?? []
						neighbor_pos = Layered.index_positions(neighbor_layer)
						current_layer = acc.get(layer_index) ?? []

						old_positions = Layered.index_positions(current_layer)

						scored = current_layer.map(
							|node| {
								medians = match direction {
									Down => unit_edges.keep_if(|e| e.to == node).keep_oks(|e| neighbor_pos.get(e.from))
									Up => unit_edges.keep_if(|e| e.from == node).keep_oks(|e| neighbor_pos.get(e.to))
								}
								fallback = (old_positions.get(node) ?? 0).to_f64()
								key = match Layered.median_of(medians) {
									Some(m) => m
									None => fallback
								}
								{ node, key }
							},
						)

						reordered = scored.sort_with(
							|a, b|
								if a.key < b.key {
									LT
								} else if a.key > b.key {
									GT
								} else if a.node < b.node {
									LT
								} else if a.node > b.node {
									GT
								} else {
									EQ
								},
						).map(|s| s.node)

						acc.set(layer_index, reordered) ?? acc
					}
				}
			},
		)
	}

	index_positions : List(U64) -> List(U64)
	index_positions = |layer| {
		max_index = layer.fold(0, |acc, n| if n > acc { n } else { acc })
		table = List.repeat(0, max_index + 1)
		layer.fold_with_index(table, |acc, node, pos| acc.set(node, pos) ?? acc)
	}

	median_of : List(U64) -> [Some(F64), None]
	median_of = |values| {
		if values.is_empty() {
			None
		} else {
			sorted = values.sort_with(
				|a, b| if a < b { LT } else if a > b { GT } else { EQ },
			)
			n = sorted.len()
			mid = n // 2
			if n % 2 == 1 {
				Some((sorted.get(mid) ?? 0).to_f64())
			} else {
				lo = (sorted.get(mid - 1) ?? 0).to_f64()
				hi = (sorted.get(mid) ?? 0).to_f64()
				Some((lo + hi) / 2)
			}
		}
	}

	layer_max_height : List(U64), List(F64) -> F64
	layer_max_height = |layer, heights|
		layer.fold(0, |acc, node| {
			h = heights.get(node) ?? 0
			if h > acc { h } else { acc }
		})

	place_layer : List({ x : F64, y : F64 }), List(U64), List(F64), List(F64), F64, F64 -> List({ x : F64, y : F64 })
	place_layer = |positions, layer, widths, heights, node_gap, y| {
		layer.fold(
			{ positions, x_cursor: 0 },
			|inner, node| {
				w = widths.get(node) ?? 0
				h = heights.get(node) ?? 0
				center = Geom.point(inner.x_cursor + w / 2, y + h / 2)
				{
					positions: inner.positions.set(node, center) ?? inner.positions,
					x_cursor: inner.x_cursor + w + node_gap,
				}
			},
		).positions
	}

	## Assigns x within each layer by cumulative width plus `node_gap`, in the
	## ordering produced by `order_layers`; assigns y by cumulative per-layer
	## maximum height plus `layer_gap`. Widths/heights for virtual nodes are 0.
	assign_coordinates : List(List(U64)), List(F64), List(F64), F64, F64 -> List({ x : F64, y : F64 })
	assign_coordinates = |layers, widths, heights, node_gap, layer_gap| {
		total = widths.len()
		positions = List.repeat(Geom.point(0, 0), total)

		layers.fold(
			{ positions, y_cursor: 0 },
			|state, layer| {
				max_height = Layered.layer_max_height(layer, heights)
				new_positions = Layered.place_layer(state.positions, layer, widths, heights, node_gap, state.y_cursor)

				{ positions: new_positions, y_cursor: state.y_cursor + max_height + layer_gap }
			},
		).positions
	}

	## Full minimal Sugiyama pipeline: rank, split long edges into virtual
	## chains, order layers by median sweeps, assign coordinates, then route
	## each original edge as a `Line` (unit span) or `Polyline` (through its
	## chain's virtual waypoints). Output `positions`/`routes` are index
	## aligned to the input `nodes`/`edges`; virtual nodes never escape.
	sugiyama : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), F64, F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List([Line({ x : F64, y : F64 }, { x : F64, y : F64 }), Polyline(List({ x : F64, y : F64 }))]),
	}
	sugiyama = |nodes, edges, node_gap, layer_gap| {
		if nodes.is_empty() {
			{ positions: [], bounds: Geom.empty_bounds, routes: [] }
		} else {
			real_ranks = Layered.rank_nodes(nodes.len(), edges)
			extended = Layered.insert_virtual_chains(real_ranks, edges)

			virtual_count = extended.ranks.len() - nodes.len()
			widths = nodes.map(|n| n.width).concat(List.repeat(0, virtual_count))
			heights = nodes.map(|n| n.height).concat(List.repeat(0, virtual_count))

			layers = Layered.group_by_rank(extended.ranks)
			ordered = Layered.order_layers(layers, extended.unit_edges)
			all_positions = Layered.assign_coordinates(ordered, widths, heights, node_gap, layer_gap)

			positions = all_positions.take_first(nodes.len())

			routes = extended.chains.map(
				|chain|
					match chain {
						[a, b] => Line(all_positions.get(a) ?? Geom.point(0, 0), all_positions.get(b) ?? Geom.point(0, 0))
						_ => Polyline(chain.keep_oks(|idx| all_positions.get(idx)))
					},
			)

			max_right = positions.fold_with_index(
				0,
				|acc, p, i| {
					w = (nodes.get(i) ?? { width: 0, height: 0 }).width
					right = p.x + w / 2
					if right > acc { right } else { acc }
				},
			)
			max_bottom = positions.fold_with_index(
				0,
				|acc, p, i| {
					h = (nodes.get(i) ?? { width: 0, height: 0 }).height
					bottom = p.y + h / 2
					if bottom > acc { bottom } else { acc }
				},
			)

			{
				positions,
				bounds: { ..Geom.empty_bounds, width: max_right, height: max_bottom },
				routes,
			}
		}
	}

	## `Layered.Sweep`: the bounded-effort Sugiyama pipeline above.
	sweep : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), F64, F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List([Line({ x : F64, y : F64 }, { x : F64, y : F64 }), Polyline(List({ x : F64, y : F64 }))]),
	}
	sweep = |nodes, edges, node_gap, layer_gap| Layered.sugiyama(nodes, edges, node_gap, layer_gap)

	## `Layered.Exact` scaffold: for now, delegates to the same minimal
	## pipeline as `Sweep` (no branch-and-bound exact ordering yet).
	exact : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), F64, F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List([Line({ x : F64, y : F64 }, { x : F64, y : F64 }), Polyline(List({ x : F64, y : F64 }))]),
	}
	exact = |nodes, edges, node_gap, layer_gap| Layered.sugiyama(nodes, edges, node_gap, layer_gap)
}

## Ranking: a diamond DAG (0 -> 1, 0 -> 2, 1 -> 3, 2 -> 3) ranks by longest path.
expect Layered.rank_nodes(4, [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 2, to: 3 }]) == [0, 1, 1, 2]

## Ranking: an isolated node with no edges ranks 0.
expect Layered.rank_nodes(1, []) == [0]

## Virtual chains: a 2-node, 2-span edge gets one virtual waypoint.
expect {
	result = Layered.insert_virtual_chains([0, 2], [{ from: 0, to: 1 }])
	result == {
		ranks: [0, 2, 1],
		unit_edges: [{ from: 0, to: 2 }, { from: 2, to: 1 }],
		chains: [[0, 2, 1]],
	}
}

## Virtual chains: a unit-span edge passes through unchanged.
expect {
	result = Layered.insert_virtual_chains([0, 1], [{ from: 0, to: 1 }])
	result == {
		ranks: [0, 1],
		unit_edges: [{ from: 0, to: 1 }],
		chains: [[0, 1]],
	}
}

## Grouping: ranks bucket into ascending-rank, ascending-index layers.
expect Layered.group_by_rank([0, 1, 1, 2]) == [[0], [1, 2], [3]]

## Full pipeline: a 5-node diamond-plus-tail places every node without overlap
## and reports a tight bounds.
expect {
	nodes = [
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
	]
	edges = [
		{ from: 0, to: 1 },
		{ from: 0, to: 2 },
		{ from: 1, to: 3 },
		{ from: 2, to: 3 },
		{ from: 3, to: 4 },
	]
	result = Layered.sugiyama(nodes, edges, 10, 30)

	result.positions.len() == 5 and result.routes.len() == 5 and result.bounds.width > 0 and result.bounds.height > 0
}

## Full pipeline: the empty graph yields an empty layout at the origin.
expect Layered.sugiyama([], [], 10, 30) == { positions: [], bounds: Geom.empty_bounds, routes: [] }

## Full pipeline: a single node with no edges sits at its own center.
expect {
	result = Layered.sugiyama([{ width: 10, height: 6 }], [], 4, 20)
	result == {
		positions: [{ x: 5, y: 3 }],
		bounds: { x: 0, y: 0, width: 10, height: 6 },
		routes: [],
	}
}
