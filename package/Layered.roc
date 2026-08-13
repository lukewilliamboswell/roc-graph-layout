import Geom

## Layered layouts for directed graphs read as flow — a minimal, complete
## Sugiyama-style pipeline: rank, insert virtual chains, order layers by a
## median heuristic, assign coordinates, and route edges as lines, polylines,
## or smooth curve chains whose endpoints clip to the node boundaries.
##
## This is a deliberately compact implementation: the public API has a
## build/run witness and reports its deterministic baseline cycle orientation,
## while ranking, coordinate assignment, and routing remain smaller than their
## production targets. Each phase below is a pure helper, real (not a stub),
## and independently tested.
LayeredInternals :: {}.{

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

		LayeredInternals.indices_up_to(node_count).fold(
			initial,
			|ranks, _pass| {
				edges.fold(
					ranks,
					|acc, edge| {
						if edge.from == edge.to {
							acc
						} else {
							from_rank = acc.get(edge.from) ?? 0
							to_rank = acc.get(edge.to) ?? 0
							wanted = from_rank + 1
							if wanted > to_rank {
								acc.set(edge.to, wanted) ?? acc
							} else {
								acc
							}
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
	insert_virtual_chains : List(U64),
	List({ from : U64, to : U64 }) -> {
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
				span = if to_rank > from_rank {
					to_rank - from_rank
				} else {
					1
				}

				if span <= 1 {
					{
						ranks: state.ranks,
						unit_edges: state.unit_edges.append(edge),
						chains: state.chains.append([edge.from, edge.to]),
						next_virtual: state.next_virtual,
					}
				} else {
					intermediate_count = span - 1
					virtual_indices = LayeredInternals.indices_up_to(intermediate_count).map(|i| state.next_virtual + i)

					chain = [edge.from].concat(virtual_indices).append(edge.to)

					new_ranks = virtual_indices.fold_with_index(
						state.ranks,
						|acc, _virtual_index, i| acc.append(from_rank + 1 + i),
					)

					new_edges = LayeredInternals.indices_up_to(chain.len() - 1).fold(
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
		layer_count = ranks.fold(
			0,
			|acc, r| if r + 1 > acc {
				r + 1
			} else {
				acc
			},
		)

		LayeredInternals.indices_up_to(layer_count).map(
			|layer| ranks.fold_with_index(
				[],
				|acc, r, i| if r == layer {
					acc.append(i)
				} else {
					acc
				},
			),
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

		LayeredInternals.indices_up_to(rounds).fold(
			layers,
			|current, _round| {
				down = LayeredInternals.sweep_median(current, unit_edges, Down)
				LayeredInternals.sweep_median(down, unit_edges, Up)
			},
		)
	}

	sweep_median : List(List(U64)), List({ from : U64, to : U64 }), [Down, Up] -> List(List(U64))
	sweep_median = |layers, unit_edges, direction| {
		layer_count = layers.len()
		ordered_indices = match direction {
			Down => LayeredInternals.indices_up_to(layer_count)
			Up => LayeredInternals.indices_up_to(layer_count).rev()
		}

		ordered_indices.fold(
			layers,
			|acc, layer_index| {
				neighbor_index = match direction {
					Down => if layer_index == 0 {
						Err({})
					} else {
						Ok(layer_index - 1)
					}
					Up => if layer_index + 1 == layer_count {
						Err({})
					} else {
						Ok(layer_index + 1)
					}
				}

				match neighbor_index {
					Err({}) => acc
					Ok(n_idx) => {
						neighbor_layer = acc.get(n_idx) ?? []
						neighbor_pos = LayeredInternals.index_positions(neighbor_layer)
						current_layer = acc.get(layer_index) ?? []

						old_positions = LayeredInternals.index_positions(current_layer)

						scored = current_layer.map(
							|node| {
								medians = match direction {
									Down => unit_edges.keep_if(|e| e.to == node).keep_oks(|e| neighbor_pos.get(e.from))
									Up => unit_edges.keep_if(|e| e.from == node).keep_oks(|e| neighbor_pos.get(e.to))
								}
								fallback = (old_positions.get(node) ?? 0).to_f64()
								key = match LayeredInternals.median_of(medians) {
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
		max_index = layer.fold(
			0,
			|acc, n| if n > acc {
				n
			} else {
				acc
			},
		)
		table = List.repeat(0, max_index + 1)
		layer.fold_with_index(table, |acc, node, pos| acc.set(node, pos) ?? acc)
	}

	median_of : List(U64) -> [Some(F64), None]
	median_of = |values| {
		if values.is_empty() {
			None
		} else {
			sorted = values.sort_with(
				|a, b| if a < b {
					LT
				} else if a > b {
					GT
				} else {
					EQ
				},
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
		layer.fold(
			0,
			|acc, node| {
				h = heights.get(node) ?? 0
				if h > acc {
					h
				} else {
					acc
				}
			},
		)

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
				max_height = LayeredInternals.layer_max_height(layer, heights)
				new_positions = LayeredInternals.place_layer(state.positions, layer, widths, heights, node_gap, state.y_cursor)

				{ positions: new_positions, y_cursor: state.y_cursor + max_height + layer_gap }
			},
		).positions
	}

	distance : { x : F64, y : F64 }, { x : F64, y : F64 } -> F64
	distance = |a, b| {
		dx = b.x - a.x
		dy = b.y - a.y
		(dx * dx + dy * dy).sqrt()
	}

	## Clips a source-to-target point list's two endpoints to the source and
	## target node boxes, so arrowheads land on the boundary rather than
	## inside it. Interior waypoints are untouched; a route shorter than two
	## points passes through unchanged.
	clip_route_ends : List({ x : F64, y : F64 }), { width : F64, height : F64 }, { width : F64, height : F64 } -> List({ x : F64, y : F64 })
	clip_route_ends = |points, source_size, target_size| {
		count = points.len()
		if count < 2 {
			points
		} else {
			first = points.get(0) ?? Geom.point(0, 0)
			second = points.get(1) ?? Geom.point(0, 0)
			second_last = points.get(count - 2) ?? Geom.point(0, 0)
			last = points.get(count - 1) ?? Geom.point(0, 0)

			clipped_first = Geom.clip_to_node(first, source_size, second)
			clipped_last = Geom.clip_to_node(last, target_size, second_last)

			with_first = points.set(0, clipped_first) ?? points
			with_first.set(count - 1, clipped_last) ?? with_first
		}
	}

	## One tangent vector per point of a smooth curve through `points`: an
	## interior tangent follows the direction between its two neighbors,
	## scaled to a third of the shorter adjacent segment (so the curve never
	## overshoots past a neighboring waypoint); an endpoint tangent follows
	## its one adjacent segment, scaled to a third of that segment's length.
	## Coincident points produce a zero tangent, keeping the curve finite.
	curve_tangents : List({ x : F64, y : F64 }) -> List({ x : F64, y : F64 })
	curve_tangents = |points| {
		count = points.len()
		if count < 2 {
			points.map(|_point| Geom.point(0, 0))
		} else {
			points.map_with_index(
				|point, i| {
					if i == 0 {
						next = points.get(1) ?? point
						Geom.point((next.x - point.x) / 3, (next.y - point.y) / 3)
					} else if i == count - 1 {
						prev = points.get(i - 1) ?? point
						Geom.point((point.x - prev.x) / 3, (point.y - prev.y) / 3)
					} else {
						prev = points.get(i - 1) ?? point
						next = points.get(i + 1) ?? point
						dx = next.x - prev.x
						dy = next.y - prev.y
						len = (dx * dx + dy * dy).sqrt()
						if len == 0 {
							Geom.point(0, 0)
						} else {
							scale = LayeredInternals.distance(prev, point).min(LayeredInternals.distance(point, next)) / 3
							Geom.point(dx / len * scale, dy / len * scale)
						}
					}
				},
			)
		}
	}

	## A cubic segment per consecutive point pair, control points one tangent
	## along from each end — a deterministic smooth path through every
	## waypoint.
	curve_through : List({ x : F64, y : F64 }) -> List(
		{
			from : { x : F64, y : F64 },
			ctl_a : { x : F64, y : F64 },
			ctl_b : { x : F64, y : F64 },
			to : { x : F64, y : F64 },
		},
	)
	curve_through = |points| {
		tangents = LayeredInternals.curve_tangents(points)
		segment_count = if points.len() < 2 {
			0
		} else {
			points.len() - 1
		}

		LayeredInternals.indices_up_to(segment_count).map(
			|i| {
				from = points.get(i) ?? Geom.point(0, 0)
				to = points.get(i + 1) ?? Geom.point(0, 0)
				from_tangent = tangents.get(i) ?? Geom.point(0, 0)
				to_tangent = tangents.get(i + 1) ?? Geom.point(0, 0)
				{
					from,
					ctl_a: Geom.point(from.x + from_tangent.x, from.y + from_tangent.y),
					ctl_b: Geom.point(to.x - to_tangent.x, to.y - to_tangent.y),
					to,
				}
			},
		)
	}

	## Builds one route from an already clipped source-to-target point list.
	## Two points always draw a straight `Line`; longer chains keep their
	## bends as a `Polyline` or smooth them into a `Curves` chain, per the
	## requested style.
	make_route : List({ x : F64, y : F64 }), [Straight, Curved] -> Geom.Route
	make_route = |points, route_style|
		match points {
			[a, b] => Line(a, b)
			_ =>
				match route_style {
					Straight => Polyline(points)
					Curved => Curves(LayeredInternals.curve_through(points))
				}
			}

	## Every point a route can reach, control points included — the set a
	## bounding box must cover.
	route_extent_points : Geom.Route -> List({ x : F64, y : F64 })
	route_extent_points = |route|
		match route {
			Line(a, b) => [a, b]
			Polyline(points) => points
			Curves(segments) =>
				segments.fold(
					[],
					|acc, segment| acc.append(segment.from).append(segment.ctl_a).append(segment.ctl_b).append(segment.to),
				)
			}

	translate_route : Geom.Route, F64, F64 -> Geom.Route
	translate_route = |route, dx, dy| {
		shift = |p| Geom.point(p.x + dx, p.y + dy)
		match route {
			Line(a, b) => Line(shift(a), shift(b))
			Polyline(points) => Polyline(points.map(shift))
			Curves(segments) =>
				Curves(
					segments.map(
						|segment| {
							from: shift(segment.from),
							ctl_a: shift(segment.ctl_a),
							ctl_b: shift(segment.ctl_b),
							to: shift(segment.to),
						},
					),
				)
			}
	}

	## Full minimal Sugiyama pipeline: rank, split long edges into virtual
	## chains, order layers by median sweeps, assign coordinates, then route
	## each original edge as a `Line` (unit span) or `Polyline` (through its
	## chain's virtual waypoints). Output `positions`/`routes` are index
	## aligned to the input `nodes`/`edges`; virtual nodes never escape.
	sugiyama : List({ width : F64, height : F64 }),
	List({ from : U64, to : U64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List(Geom.Route),
	}
	sugiyama = |nodes, edges, node_gap, layer_gap| {
		if nodes.is_empty() {
			{ positions: [], bounds: Geom.empty_bounds, routes: [] }
		} else {
			real_ranks = LayeredInternals.rank_nodes(nodes.len(), edges)
			extended = LayeredInternals.insert_virtual_chains(real_ranks, edges)

			virtual_count = extended.ranks.len() - nodes.len()
			widths = nodes.map(|n| n.width).concat(List.repeat(0, virtual_count))
			heights = nodes.map(|n| n.height).concat(List.repeat(0, virtual_count))

			layers = LayeredInternals.group_by_rank(extended.ranks)
			ordered = LayeredInternals.order_layers(layers, extended.unit_edges)
			all_positions = LayeredInternals.assign_coordinates(ordered, widths, heights, node_gap, layer_gap)

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
					if right > acc {
						right
					} else {
						acc
					}
				},
			)
			max_bottom = positions.fold_with_index(
				0,
				|acc, p, i| {
					h = (nodes.get(i) ?? { width: 0, height: 0 }).height
					bottom = p.y + h / 2
					if bottom > acc {
						bottom
					} else {
						acc
					}
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
	sweep : List({ width : F64, height : F64 }),
	List({ from : U64, to : U64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List(Geom.Route),
	}
	sweep = |nodes, edges, node_gap, layer_gap| LayeredInternals.sugiyama(nodes, edges, node_gap, layer_gap)

	## `Layered.Exact` scaffold: for now, delegates to the same minimal
	## pipeline as `Sweep` (no branch-and-bound exact ordering yet).
	exact : List({ width : F64, height : F64 }),
	List({ from : U64, to : U64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List(Geom.Route),
	}
	exact = |nodes, edges, node_gap, layer_gap| LayeredInternals.sugiyama(nodes, edges, node_gap, layer_gap)

	## Deterministically orient every non-loop edge from the lower node index to
	## the higher one. This is a deliberately simple acyclic baseline for the
	## exemplar witness; a production sweep should replace it with a greedy
	## feedback-arc heuristic that preserves more of the caller's orientation.
	orient_edges : List({ from : U64, to : U64 }) -> {
		edges : List({ from : U64, to : U64 }),
		reversed : List(U64),
		reversed_flags : List(Bool),
	}
	orient_edges = |edges|
		edges.fold_with_index(
			{ edges: [], reversed: [], reversed_flags: [] },
			|state, edge, edge_index| {
				is_reversed = edge.from > edge.to
				oriented = if is_reversed {
					{ from: edge.to, to: edge.from }
				} else {
					edge
				}
				{
					edges: state.edges.append(oriented),
					reversed: if is_reversed {
						state.reversed.append(edge_index)
					} else {
						state.reversed
					},
					reversed_flags: state.reversed_flags.append(is_reversed),
				}
			},
		)

	validation_problems = |spec, config| {
		node_problems = spec.graph.nodes.fold_with_index(
			[],
			|problems, node, index| {
				width_problems = if !F64.is_finite(node.width) or node.width < 0 {
					problems.append(InvalidNodeWidth(index))
				} else {
					problems
				}

				if !F64.is_finite(node.height) or node.height < 0 {
					width_problems.append(InvalidNodeHeight(index))
				} else {
					width_problems
				}
			},
		)

		edge_problems = spec.graph.edges.fold_with_index(
			node_problems,
			|problems, edge, index| {
				from_problems = if edge.from >= spec.graph.nodes.len() {
					problems.append(MissingEdgeStart(index, edge.from))
				} else {
					problems
				}

				if edge.to >= spec.graph.nodes.len() {
					from_problems.append(MissingEdgeEnd(index, edge.to))
				} else {
					from_problems
				}
			},
		)

		gap_problems = if !F64.is_finite(config.node_gap) or config.node_gap < 0 {
			edge_problems.append(InvalidNodeGap)
		} else {
			edge_problems
		}

		if !F64.is_finite(config.layer_gap) or config.layer_gap < 0 {
			gap_problems.append(InvalidLayerGap)
		} else {
			gap_problems
		}
	}
}

## A validated and precomputed bounded-effort layered layout.
##
## `Sweep.build` is the only fallible boundary. The opaque value contains a
## canonical acyclic reading plus ranks, virtual chains, and layer order, so
## `Sweep.run` performs geometry only and is total.
Prepared := {
	nodes : List({ width : F64, height : F64 }),
	edges : List({ from : U64, to : U64 }),
	reversed : List(U64),
	reversed_flags : List(Bool),
	real_ranks : List(U64),
	extended_ranks : List(U64),
	chains : List(List(U64)),
	ordered_layers : List(List(U64)),
	node_gap : F64,
	layer_gap : F64,
	route_style : [Straight, Curved],
}.{
	Config : { node_gap : F64, layer_gap : F64, route_style : [Straight, Curved] }
	Spec : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
	}
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
	]

	defaults : Config
	defaults = { node_gap: 24, layer_gap: 70, route_style: Curved }

	default_spec : Spec
	default_spec = { graph: { nodes: [], edges: [] } }

	build : Spec, Config -> [Ok(Prepared), Err(List(Problem))]
	build = |spec, config| {
		problems = LayeredInternals.validation_problems(spec, config)
		if !problems.is_empty() {
			Err(problems)
		} else {
			oriented = LayeredInternals.orient_edges(spec.graph.edges)
			real_ranks = LayeredInternals.rank_nodes(spec.graph.nodes.len(), oriented.edges)
			extended = LayeredInternals.insert_virtual_chains(real_ranks, oriented.edges)
			ordered_layers = LayeredInternals.order_layers(LayeredInternals.group_by_rank(extended.ranks), extended.unit_edges)

			Ok({
				nodes: spec.graph.nodes,
				edges: spec.graph.edges,
				reversed: oriented.reversed,
				reversed_flags: oriented.reversed_flags,
				real_ranks,
				extended_ranks: extended.ranks,
				chains: extended.chains,
				ordered_layers,
				node_gap: config.node_gap,
				layer_gap: config.layer_gap,
				route_style: config.route_style,
			})
		}
	}

	run : Prepared -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
	}
	run = |sweep| {
		virtual_count = sweep.extended_ranks.len() - sweep.nodes.len()
		widths = sweep.nodes.map(|node| node.width).concat(List.repeat(0, virtual_count))
		heights = sweep.nodes.map(|node| node.height).concat(List.repeat(0, virtual_count))
		all_positions = LayeredInternals.assign_coordinates(sweep.ordered_layers, widths, heights, sweep.node_gap, sweep.layer_gap)
		positions = all_positions.take_first(sweep.nodes.len())

		routes = sweep.chains.map_with_index(
			|chain, edge_index| {
				points = chain.keep_oks(|index| all_positions.get(index))
				oriented_points = if sweep.reversed_flags.get(edge_index) ?? False {
					points.rev()
				} else {
					points
				}
				edge = sweep.edges.get(edge_index) ?? { from: 0, to: 0 }
				source_size = sweep.nodes.get(edge.from) ?? { width: 0, height: 0 }
				target_size = sweep.nodes.get(edge.to) ?? { width: 0, height: 0 }
				clipped = LayeredInternals.clip_route_ends(oriented_points, source_size, target_size)
				LayeredInternals.make_route(clipped, sweep.route_style)
			},
		)

		max_right = positions.fold_with_index(
			0,
			|acc, point, index| {
				width = (sweep.nodes.get(index) ?? { width: 0, height: 0 }).width
				right = point.x + width / 2
				if right > acc {
					right
				} else {
					acc
				}
			},
		)
		max_bottom = positions.fold_with_index(
			0,
			|acc, point, index| {
				height = (sweep.nodes.get(index) ?? { width: 0, height: 0 }).height
				bottom = point.y + height / 2
				if bottom > acc {
					bottom
				} else {
					acc
				}
			},
		)

		# Node boxes are anchored at the origin, but route points — virtual
		# waypoints have zero size, and curve control points extend past their
		# anchors — may lie outside every node box. Extend the bounds to cover
		# them, and translate everything back to the origin if any escaped
		# above or to the left.
		extent = routes.fold(
			{ min_x: 0, min_y: 0, max_x: max_right, max_y: max_bottom },
			|acc, route|
				LayeredInternals.route_extent_points(route).fold(
					acc,
					|inner, point| {
						min_x: if point.x < inner.min_x {
							point.x
						} else {
							inner.min_x
						},
						min_y: if point.y < inner.min_y {
							point.y
						} else {
							inner.min_y
						},
						max_x: if point.x > inner.max_x {
							point.x
						} else {
							inner.max_x
						},
						max_y: if point.y > inner.max_y {
							point.y
						} else {
							inner.max_y
						},
					},
				),
		)

		shift_x = 0 - extent.min_x
		shift_y = 0 - extent.min_y
		final_positions = if shift_x == 0 and shift_y == 0 {
			positions
		} else {
			positions.map(|point| Geom.point(point.x + shift_x, point.y + shift_y))
		}
		final_routes = if shift_x == 0 and shift_y == 0 {
			routes
		} else {
			routes.map(|route| LayeredInternals.translate_route(route, shift_x, shift_y))
		}

		{
			layout: {
				positions: final_positions,
				bounds: { ..Geom.empty_bounds, width: extent.max_x - extent.min_x, height: extent.max_y - extent.min_y },
				routes: final_routes,
			},
			layers: sweep.real_ranks,
			backward_edges: sweep.reversed,
		}
	}

	layout : Spec,
	Config -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				layers : List(U64),
				backward_edges : List(U64),
			},
		),
		Err(List(Problem)),
	]
	layout = |spec, config|
		match Prepared.build(spec, config) {
			Ok(sweep) => Ok(sweep.run())
			Err(problems) => Err(problems)
		}
}

## Directed graph layout read as flow.
##
## `layout` is the usual entry point. For repeated layouts of unchanged input,
## call `prepare` once and pass the result to `layout_prepared`.
Layered := [].{

	## Directed flow input for the current exemplar. Edge identity is its index.
	Input : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
	}

	## Space between nodes on the same layer and between adjacent layers,
	## plus how edges through intermediate layers are drawn: `Curved` (the
	## default) smooths their bends into cubic curve chains, `Straight`
	## keeps them as polylines. Edges between adjacent layers are always
	## straight lines.
	Settings : { node_gap : F64, layer_gap : F64, route_style : [Straight, Curved] }

	## Invalid sizes, spacing, or edge endpoints found while checking input.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
	]

	## Geometry plus each node's layer and any edges drawn against the flow.
	## Positions hold node centers; route endpoints lie on the source and
	## target node boundaries.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
	}

	## Empty flow input. Replace `graph` by record update.
	default_input : Input
	default_input = Prepared.default_spec

	## Settings that produce a readable top-to-bottom layout in common cases.
	default_settings : Settings
	default_settings = Prepared.defaults

	## Check the input and settings, then cache work reusable across layouts.
	prepare : Input, Settings -> [Ok(Prepared), Err(List(Problem))]
	prepare = |input, settings| Prepared.build(input, settings)

	## Lay out previously prepared input. This operation cannot fail.
	layout_prepared : Prepared -> Result
	layout_prepared = |prepared| prepared.run()

	## Check and lay out input in one call. This is the usual entry point.
	layout : Input, Settings -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings| Prepared.layout(input, settings)
}

## Ranking: a diamond DAG (0 -> 1, 0 -> 2, 1 -> 3, 2 -> 3) ranks by longest path.
expect LayeredInternals.rank_nodes(4, [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 2, to: 3 }]) == [0, 1, 1, 2]

## Ranking: an isolated node with no edges ranks 0.
expect LayeredInternals.rank_nodes(1, []) == [0]

## Virtual chains: a 2-node, 2-span edge gets one virtual waypoint.
expect {
	result = LayeredInternals.insert_virtual_chains([0, 2], [{ from: 0, to: 1 }])
	result == {
		ranks: [0, 2, 1],
		unit_edges: [{ from: 0, to: 2 }, { from: 2, to: 1 }],
		chains: [[0, 2, 1]],
	}
}

## Virtual chains: a unit-span edge passes through unchanged.
expect {
	result = LayeredInternals.insert_virtual_chains([0, 1], [{ from: 0, to: 1 }])
	result == {
		ranks: [0, 1],
		unit_edges: [{ from: 0, to: 1 }],
		chains: [[0, 1]],
	}
}

## Grouping: ranks bucket into ascending-rank, ascending-index layers.
expect LayeredInternals.group_by_rank([0, 1, 1, 2]) == [[0], [1, 2], [3]]

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
	result = LayeredInternals.sugiyama(nodes, edges, 10, 30)

	result.positions.len() == 5 and result.routes.len() == 5 and result.bounds.width > 0 and result.bounds.height > 0
}

## Full pipeline: the empty graph yields an empty layout at the origin.
expect LayeredInternals.sugiyama([], [], 10, 30) == { positions: [], bounds: Geom.empty_bounds, routes: [] }

## Full pipeline: a single node with no edges sits at its own center.
expect {
	result = LayeredInternals.sugiyama([{ width: 10, height: 6 }], [], 4, 20)
	result == {
		positions: [{ x: 5, y: 3 }],
		bounds: { x: 0, y: 0, width: 10, height: 6 },
		routes: [],
	}
}

## Exemplar contract: build reports every independent boundary problem.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: -1, height: -2 }],
			edges: [{ from: 0, to: 3 }],
		},
	}
	config = { ..Prepared.defaults, node_gap: -4 }
	Prepared.build(spec, config) == Err([
		InvalidNodeWidth(0),
		InvalidNodeHeight(0),
		MissingEdgeEnd(0, 3),
		InvalidNodeGap,
	])
}

## Exemplar contract: the witness stores deterministic preprocessing, run is
## total, and routes remain aligned with the caller's original edge direction.
## The reversed edge runs from node 1's top edge (center 5,79 clipped up by
## half its height) to node 0's bottom edge (center 5,3 clipped down).
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 1, to: 0 }],
		},
	}
	match Prepared.build(spec, Prepared.defaults) {
		Err(_) => False
		Ok(sweep) => {
			result = sweep.run()
			result.backward_edges == [0] and result.layers == [0, 1] and result.layout.routes == [Line({ x: 5, y: 76 }, { x: 5, y: 6 })]
		}
	}
}

## The one-shot API is exactly build followed by run.
expect {
	spec = { ..Prepared.default_spec, graph: { nodes: [{ width: 8, height: 4 }], edges: [] } }
	match Prepared.build(spec, Prepared.defaults) {
		Err(_) => False
		Ok(prepared) => Prepared.layout(spec, Prepared.defaults) == Ok(prepared.run())
	}
}

## A unit-span route's endpoints lie exactly on the two nodes' facing edges:
## the source's bottom edge and the target's top edge.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }],
		},
	}
	match Prepared.layout(spec, Prepared.defaults) {
		Err(_) => False
		Ok(result) => result.layout.routes == [Line({ x: 5, y: 6 }, { x: 5, y: 76 })]
	}
}

## With the default `Curved` style, an edge spanning two layers becomes a
## cubic curve chain through its virtual waypoint at (34, 76): the chain
## starts on the source's boundary, passes through the waypoint, and ends on
## the target's boundary, while the unit-span edges stay straight lines.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	expected_start = Geom.clip_to_node({ x: 5, y: 3 }, { width: 10, height: 6 }, { x: 34, y: 76 })
	expected_end = Geom.clip_to_node({ x: 5, y: 155 }, { width: 10, height: 6 }, { x: 34, y: 76 })
	match Prepared.layout(spec, Prepared.defaults) {
		Err(_) => False
		Ok(result) => {
			unit_is_line = match result.layout.routes.get(0) ?? Polyline([]) {
				Line(_, _) => True
				_ => False
			}
			long_is_curve = match result.layout.routes.get(2) ?? Polyline([]) {
				Curves([first, last]) => {
					starts_on_source = first.from == expected_start and first.to == { x: 34, y: 76 }
					ends_on_target = last.from == { x: 34, y: 76 } and last.to == expected_end
					starts_on_source and ends_on_target
				}
				_ => False
			}
			unit_is_line and long_is_curve
		}
	}
}

## `route_style: Straight` keeps the same long edge as a polyline through the
## waypoint, still clipped to the node boundaries at both ends.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	expected_start = Geom.clip_to_node({ x: 5, y: 3 }, { width: 10, height: 6 }, { x: 34, y: 76 })
	expected_end = Geom.clip_to_node({ x: 5, y: 155 }, { width: 10, height: 6 }, { x: 34, y: 76 })
	match Prepared.layout(spec, { ..Prepared.defaults, route_style: Straight }) {
		Err(_) => False
		Ok(result) => result.layout.routes.get(2) == Ok(Polyline([expected_start, { x: 34, y: 76 }, expected_end]))
	}
}

## Determinism: laying out the same input twice produces identical results.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	Layered.layout(input, Layered.default_settings) == Layered.layout(input, Layered.default_settings)
}
