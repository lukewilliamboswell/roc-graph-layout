import ForceLayout
import Geom
import RadialLayout
import StressLayout
import Trig

## Pure helpers behind `Graph.Circular`: joint validation, the greedy
## affinity ring ordering with its adjacent-swap crossing polish, and the
## projection of that order onto a circle sized from node extents.
CircularInternals :: {}.{

	## `[0, 1, .., n - 1]`, the building block for walking a bounded range.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	validation_problems : Graph.Spec, Graph.CircularSettings -> List(Graph.Problem)
	validation_problems = |spec, settings| {
		node_problems = spec.nodes.fold_with_index(
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

		edge_problems = spec.edges.fold_with_index(
			node_problems,
			|problems, edge, index| {
				from_problems = if edge.from >= spec.nodes.len() {
					problems.append(MissingEdgeStart(index, edge.from))
				} else {
					problems
				}

				if edge.to >= spec.nodes.len() {
					from_problems.append(MissingEdgeEnd(index, edge.to))
				} else {
					from_problems
				}
			},
		)

		gap_problems = if !F64.is_finite(settings.node_gap) or settings.node_gap < 0 {
			edge_problems.append(InvalidNodeGap)
		} else {
			edge_problems
		}

		if F64.is_finite(settings.start_angle) {
			gap_problems
		} else {
			gap_problems.append(InvalidStartAngle)
		}
	}

	## Non-loop neighbor lists in both directions, in edge order. Parallel
	## edges appear once per copy, so affinity weighs them naturally.
	neighbor_lists : U64, List({ from : U64, to : U64 }) -> List(List(U64))
	neighbor_lists = |node_count, edges|
		edges.fold(
			List.repeat([], node_count),
			|lists, edge|
				if edge.from == edge.to {
					lists
				} else {
					from_list = lists.get(edge.from) ?? []
					with_from = lists.set(edge.from, from_list.append(edge.to)) ?? lists
					to_list = with_from.get(edge.to) ?? []
					with_from.set(edge.to, to_list.append(edge.from)) ?? with_from
				},
		)

	## The first node in `by_degree` at or after `cursor` that is not yet
	## seated, advancing the cursor past everything it skips.
	next_unplaced : List(U64), List(Bool), U64 -> { pick : [Some(U64), None], cursor : U64 }
	next_unplaced = |by_degree, placed, cursor|
		match by_degree.get(cursor) {
			Err(_) => { pick: None, cursor }
			Ok(candidate) =>
				if placed.get(candidate) ?? False {
					CircularInternals.next_unplaced(by_degree, placed, cursor + 1)
				} else {
					{ pick: Some(candidate), cursor }
				}
			}

	## Ring order by greedy affinity: start from the best-connected node,
	## then repeatedly seat the unplaced node with the most edges to the one
	## just seated — neighbors want to sit adjacent on the ring — falling
	## back to the best-connected unplaced node when the chain runs out (a
	## new component, or no unplaced neighbors). Ties break toward the lower
	## index throughout, so the order is deterministic.
	ring_order : U64, List({ from : U64, to : U64 }) -> List(U64)
	ring_order = |node_count, edges| {
		neighbors = CircularInternals.neighbor_lists(node_count, edges)
		by_degree = CircularInternals.indices_up_to(node_count).sort_with(
			|a, b| {
				da = (neighbors.get(a) ?? []).len()
				db = (neighbors.get(b) ?? []).len()
				if da > db {
					LT
				} else if da < db {
					GT
				} else if a < b {
					LT
				} else {
					GT
				}
			},
		)

		seeded = { order: [], placed: List.repeat(False, node_count), cursor: 0 }
		CircularInternals.indices_up_to(node_count).fold(
			seeded,
			|state, _step| {
				affinity_pick = match (
					if state.order.is_empty() {
						Err(Empty)
					} else {
						state.order.get(state.order.len() - 1)
					}
				) {
					Err(_) => None
					Ok(last) => {
						nb = neighbors.get(last) ?? []
						nb.fold(
							None,
							|best, candidate|
								if state.placed.get(candidate) ?? False {
									best
								} else {
									weight = nb.count_if(|w| w == candidate)
									match best {
										None => Some({ node: candidate, weight })
										Some(b) =>
											if weight > b.weight or (weight == b.weight and candidate < b.node) {
												Some({ node: candidate, weight })
											} else {
												best
											}
										}
								},
						)
					}
				}

				match affinity_pick {
					Some(found) => {
						order: state.order.append(found.node),
						placed: state.placed.set(found.node, True) ?? state.placed,
						cursor: state.cursor,
					}

					None => {
						advanced = CircularInternals.next_unplaced(by_degree, state.placed, state.cursor)
						match advanced.pick {
							None => state
							Some(node) => {
								order: state.order.append(node),
								placed: state.placed.set(node, True) ?? state.placed,
								cursor: advanced.cursor,
							}
						}
					}
				}
			},
		).order
	}

	## Each node's seat around the ring: the inverse of the ring sequence.
	seats_of : List(U64), U64 -> List(U64)
	seats_of = |sequence, node_count|
		sequence.fold_with_index(
			List.repeat(0, node_count),
			|acc, node, seat| acc.set(node, seat) ?? acc,
		)

	## Whether two chords of the ring cross: never when they share an
	## endpoint; otherwise exactly when one endpoint of the second sits
	## strictly between the endpoints of the first, and the other does not.
	chords_cross : { a : U64, b : U64 }, { a : U64, b : U64 } -> Bool
	chords_cross = |e, f|
		if f.a == e.a or f.a == e.b or f.b == e.a or f.b == e.b {
			False
		} else {
			lo = if e.a < e.b {
				e.a
			} else {
				e.b
			}
			hi = if e.a < e.b {
				e.b
			} else {
				e.a
			}
			a_inside = f.a > lo and f.a < hi
			b_inside = f.b > lo and f.b < hi
			a_inside != b_inside
		}

	## Crossings involving at least one edge incident to `u` or `v`, each
	## crossing pair counted once. Self-loops never cross anything.
	crossings_touching : List({ from : U64, to : U64 }), List(U64), U64, U64 -> U64
	crossings_touching = |edges, seats, u, v| {
		touching = edges.map(
			|e| e.from != e.to and (e.from == u or e.to == u or e.from == v or e.to == v),
		)

		edges.fold_with_index(
			0,
			|acc, e, i|
				if !(touching.get(i) ?? False) {
					acc
				} else {
					e_seats = { a: seats.get(e.from) ?? 0, b: seats.get(e.to) ?? 0 }
					edges.fold_with_index(
						acc,
						|inner, f, j|
							if j == i or f.from == f.to {
								inner
							} else if (touching.get(j) ?? False) and j < i {
								# already counted with the roles swapped
								inner
							} else {
								f_seats = { a: seats.get(f.from) ?? 0, b: seats.get(f.to) ?? 0 }
								if CircularInternals.chords_cross(e_seats, f_seats) {
									inner + 1
								} else {
									inner
								}
							},
					)
				},
		)
	}

	## One polish round: walk every cyclic adjacency in seat order and swap
	## the two seated nodes whenever that strictly reduces the crossings
	## their edges are involved in — the same adjacent-swap machinery the
	## layer sweep uses, bent around a ring.
	polish_round : List(U64), List({ from : U64, to : U64 }), U64 -> { sequence : List(U64), improved : Bool }
	polish_round = |sequence, edges, node_count|
		CircularInternals.indices_up_to(sequence.len()).fold(
			{ sequence, improved: False },
			|state, seat| {
				next_seat = if seat + 1 == state.sequence.len() {
					0
				} else {
					seat + 1
				}
				u = state.sequence.get(seat) ?? 0
				v = state.sequence.get(next_seat) ?? 0
				seats = CircularInternals.seats_of(state.sequence, node_count)
				before = CircularInternals.crossings_touching(edges, seats, u, v)
				half_swapped = seats.set(u, seats.get(v) ?? 0) ?? seats
				swapped_seats = half_swapped.set(v, seats.get(u) ?? 0) ?? half_swapped
				after = CircularInternals.crossings_touching(edges, swapped_seats, u, v)

				if after < before {
					half_sequence = state.sequence.set(seat, v) ?? state.sequence
					swapped_sequence = half_sequence.set(next_seat, u) ?? half_sequence
					{ sequence: swapped_sequence, improved: True }
				} else {
					state
				}
			},
		)

	## Bounded adjacent-swap polish: rounds run until one makes no swap or
	## the cap is reached, so termination never depends on convergence.
	polish : List(U64), List({ from : U64, to : U64 }), U64, U64 -> List(U64)
	polish = |sequence, edges, node_count, round_cap|
		if sequence.len() < 4 or edges.len() < 2 {
			sequence
		} else {
			CircularInternals.indices_up_to(round_cap).fold(
				{ sequence, done: False },
				|state, _round|
					if state.done {
						state
					} else {
						round = CircularInternals.polish_round(state.sequence, edges, node_count)
						{ sequence: round.sequence, done: !round.improved }
					},
			).sequence
		}

	## The safe footprint of a box on the ring whatever its angle: its
	## diagonal. Zero-size nodes take only the configured gap.
	diagonal : { width : F64, height : F64 } -> F64
	diagonal = |node| Geom.hypot(node.width, node.height)

	## Projects the ring sequence onto a circle: every node takes an arc
	## slot of its diagonal plus `node_gap`, the circumference is the sum of
	## the slots, and the radius follows from it — then grows further if any
	## adjacent pair needs it, because centers sit a chord apart and a chord
	## is shorter than its arc, so arc-length spacing alone can overlap
	## neighbors on small rings. Returns raw (uncentered) positions and each
	## node's angle, both index-aligned to the spec.
	place_on_ring : List(U64),
	List({ width : F64, height : F64 }),
	Graph.CircularSettings -> {
		positions : List({ x : F64, y : F64 }),
		angles : List(F64),
	}
	place_on_ring = |sequence, nodes, settings| {
		slots = sequence.map(
			|node| CircularInternals.diagonal(nodes.get(node) ?? { width: 0, height: 0 }) + settings.node_gap,
		)
		circumference = slots.fold(0, |acc, s| acc + s)
		safe_circumference = if circumference > 0 {
			circumference
		} else {
			1
		}
		arc_radius = circumference / Trig.tau
		seat_count = sequence.len()
		radius = if seat_count < 2 {
			arc_radius
		} else {
			CircularInternals.indices_up_to(seat_count).fold(
				arc_radius,
				|acc, seat| {
					next_seat = if seat + 1 == seat_count {
						0
					} else {
						seat + 1
					}
					slot_a = slots.get(seat) ?? 0
					slot_b = slots.get(next_seat) ?? 0
					required = (slot_a + slot_b) / 2
					half_angle = Trig.tau * (slot_a + slot_b) / (4 * safe_circumference)
					chord_per_radius = 2 * Trig.sin(half_angle)
					if required > 0 and chord_per_radius > 0 {
						acc.max(required / chord_per_radius)
					} else {
						acc
					}
				},
			)
		}
		dir_sign = match settings.winding {
			Clockwise => 1.0
			CounterClockwise => 0 - 1.0
		}

		node_count = nodes.len()
		placed = sequence.fold(
			{
				positions: List.repeat({ x: 0, y: 0 }, node_count),
				angles: List.repeat(settings.start_angle, node_count),
				arc_cursor: 0.0,
			},
			|state, node| {
				slot = CircularInternals.diagonal(nodes.get(node) ?? { width: 0, height: 0 }) + settings.node_gap
				angle = settings.start_angle + dir_sign * Trig.tau * ((state.arc_cursor + slot / 2) / safe_circumference)
				point = { x: radius * Trig.cos(angle), y: radius * Trig.sin(angle) }
				{
					positions: state.positions.set(node, point) ?? state.positions,
					angles: state.angles.set(node, angle) ?? state.angles,
					arc_cursor: state.arc_cursor + slot,
				}
			},
		)

		{ positions: placed.positions, angles: placed.angles }
	}

	## For each edge, its rank among the edges joining the same unordered
	## node pair, and how many there are — what deterministic fanning needs.
	parallel_ranks : List({ from : U64, to : U64 }) -> List({ rank : U64, count : U64 })
	parallel_ranks = |edges| {
		keyed = edges.map_with_index(
			|edge, index| {
				lo = if edge.from < edge.to {
					edge.from
				} else {
					edge.to
				}
				hi = if edge.from < edge.to {
					edge.to
				} else {
					edge.from
				}
				{ lo, hi, index }
			},
		)
		sorted = keyed.sort_with(
			|a, b|
				if a.lo < b.lo {
					LT
				} else if a.lo > b.lo {
					GT
				} else if a.hi < b.hi {
					LT
				} else if a.hi > b.hi {
					GT
				} else if a.index < b.index {
					LT
				} else {
					GT
				},
		)

		grouped = sorted.fold(
			{ finished: [], run: [] },
			|state, entry|
				match state.run.get(0) {
					Ok(head) =>
						if head.lo == entry.lo and head.hi == entry.hi {
							{ finished: state.finished, run: state.run.append(entry) }
						} else {
							{ finished: state.finished.append(state.run), run: [entry] }
						}

					Err(_) => { finished: state.finished, run: [entry] }
				},
		)
		runs = if grouped.run.is_empty() {
			grouped.finished
		} else {
			grouped.finished.append(grouped.run)
		}

		runs.fold(
			List.repeat({ rank: 0, count: 1 }, edges.len()),
			|acc, run|
				run.fold_with_index(
					acc,
					|inner, entry, rank| inner.set(entry.index, { rank, count: run.len() }) ?? inner,
				),
		)
	}

	## A smooth teardrop beside the node, pointing away from the ring's
	## center: two mirror-symmetric cubic segments that leave the node's
	## boundary along its own angle, round an apex, and close back on the
	## same boundary point — sized from the node's extent and the gap so
	## the loop clears the node deterministically.
	self_loop : { x : F64, y : F64 }, F64, { width : F64, height : F64 }, F64 -> Geom.Route
	self_loop = |center, angle, size, node_gap| {
		d = { x: Trig.cos(angle), y: Trig.sin(angle) }
		t = { x: 0 - Trig.sin(angle), y: Trig.cos(angle) }
		g = (CircularInternals.diagonal(size) + node_gap) / 8
		b = Geom.clip_to_node(center, size, { x: center.x + d.x, y: center.y + d.y })
		apex = { x: b.x + d.x * (4 * g), y: b.y + d.y * (4 * g) }
		Curves([
			{
				from: b,
				ctl_a: { x: b.x + d.x * (2 * g) + t.x * (2 * g), y: b.y + d.y * (2 * g) + t.y * (2 * g) },
				ctl_b: { x: apex.x + t.x * (2 * g), y: apex.y + t.y * (2 * g) },
				to: apex,
			},
			{
				from: apex,
				ctl_a: { x: apex.x - t.x * (2 * g), y: apex.y - t.y * (2 * g) },
				ctl_b: { x: b.x + d.x * (2 * g) - t.x * (2 * g), y: b.y + d.y * (2 * g) - t.y * (2 * g) },
				to: b,
			},
		])
	}

	## One route per edge, in spec order: straight boundary-to-boundary
	## lines, parallel edges bowed apart as cubic curves with deterministic
	## midpoint offsets, and self-loops as teardrop curves outside the ring.
	## Endpoints attach where the straight chord crosses each node's box.
	route_edges : List({ from : U64, to : U64 }), List({ x : F64, y : F64 }), List(F64), List({ width : F64, height : F64 }), F64 -> List(Geom.Route)
	route_edges = |edges, positions, angles, nodes, node_gap| {
		ranks = CircularInternals.parallel_ranks(edges)
		edges.map_with_index(
			|edge, index| {
				from_point = positions.get(edge.from) ?? { x: 0, y: 0 }
				from_size = nodes.get(edge.from) ?? { width: 0, height: 0 }
				if edge.from == edge.to {
					CircularInternals.self_loop(from_point, angles.get(edge.from) ?? 0, from_size, node_gap)
				} else {
					to_point = positions.get(edge.to) ?? { x: 0, y: 0 }
					to_size = nodes.get(edge.to) ?? { width: 0, height: 0 }
					a = Geom.clip_to_node(from_point, from_size, to_point)
					b = Geom.clip_to_node(to_point, to_size, from_point)
					fan = ranks.get(index) ?? { rank: 0, count: 1 }
					if fan.count == 1 {
						Line(a, b)
					} else {
						# Fan geometry is computed in one canonical direction
						# (lower node index to higher) so that oppositely
						# directed parallel edges take distinct sides rather
						# than reversing both rank sign and normal sign into
						# the same physical bow; only the finished segment's
						# orientation follows the edge's own direction.
						is_reversed = edge.from > edge.to
						ca = if is_reversed {
							b
						} else {
							a
						}
						cb = if is_reversed {
							a
						} else {
							b
						}
						dx = cb.x - ca.x
						dy = cb.y - ca.y
						length = Geom.hypot(dx, dy)
						normal = if length > 0 {
							{ x: 0 - dy / length, y: dx / length }
						} else {
							{ x: 0, y: 0 - 1.0 }
						}
						offset = (fan.rank.to_f64() - (fan.count - 1).to_f64() / 2) * (node_gap / 2)
						# 4/3 makes the cubic pass through the offset midpoint at t = 1/2
						bow = offset * 4 / 3
						ctl_a = { x: ca.x + dx / 3 + normal.x * bow, y: ca.y + dy / 3 + normal.y * bow }
						ctl_b = { x: ca.x + dx * 2 / 3 + normal.x * bow, y: ca.y + dy * 2 / 3 + normal.y * bow }
						if is_reversed {
							Curves([{ from: cb, ctl_a: ctl_b, ctl_b: ctl_a, to: ca }])
						} else {
							Curves([{ from: ca, ctl_a, ctl_b, to: cb }])
						}
					}
				}
			},
		)
	}

	## Translates the finished drawing so the tight box over every node
	## extent and every route point sits with its top-left corner at the
	## origin.
	normalize : List({ x : F64, y : F64 }),
	List({ width : F64, height : F64 }),
	List(Geom.Route) -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List(Geom.Route),
	}
	normalize = |positions, nodes, routes| {
		box0 = match positions.get(0) {
			Ok(p) => {
				node = nodes.get(0) ?? { width: 0, height: 0 }
				{ min_x: p.x - node.width / 2, min_y: p.y - node.height / 2, max_x: p.x + node.width / 2, max_y: p.y + node.height / 2 }
			}

			Err(_) => { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
		}

		node_box = positions.fold_with_index(
			box0,
			|acc, p, index| {
				node = nodes.get(index) ?? { width: 0, height: 0 }
				{
					min_x: acc.min_x.min(p.x - node.width / 2),
					min_y: acc.min_y.min(p.y - node.height / 2),
					max_x: acc.max_x.max(p.x + node.width / 2),
					max_y: acc.max_y.max(p.y + node.height / 2),
				}
			},
		)

		extend = |acc, p| {
			min_x: acc.min_x.min(p.x),
			min_y: acc.min_y.min(p.y),
			max_x: acc.max_x.max(p.x),
			max_y: acc.max_y.max(p.y),
		}
		box = routes.fold(
			node_box,
			|acc, route|
				match route {
					Line(from, to) => extend(extend(acc, from), to)
					Polyline(points) => points.fold(acc, extend)
					# control points bound the curve by the convex-hull property
					Curves(segments) =>
						segments.fold(
							acc,
							|seg_acc, seg| extend(extend(extend(extend(seg_acc, seg.from), seg.ctl_a), seg.ctl_b), seg.to),
						)
					},
		)

		dx = 0 - box.min_x
		dy = 0 - box.min_y
		shift = |p| { x: p.x + dx, y: p.y + dy }

		{
			positions: positions.map(shift),
			bounds: { ..Geom.empty_bounds, width: box.max_x - box.min_x, height: box.max_y - box.min_y },
			routes: routes.map(
				|route| match route {
					Line(from, to) => Line(shift(from), shift(to))
					Polyline(points) => Polyline(points.map(shift))
					Curves(segments) =>
						Curves(
							segments.map(
								|seg| { from: shift(seg.from), ctl_a: shift(seg.ctl_a), ctl_b: shift(seg.ctl_b), to: shift(seg.to) },
							),
						)
					},
			),
		}
	}
}

## A validated and precomputed circular layout.
##
## `Circular` has no per-run arguments — its ordering criteria determine the
## drawing uniquely — so `build` computes the complete result once, and
## `run` only returns it.
CircularPrepared := { result : Graph.Result }.{
	round_cap : U64
	round_cap = 4

	build : Graph.Spec, Graph.CircularSettings -> [Ok(CircularPrepared), Err(List(Graph.Problem))]
	build = |spec, settings| {
		problems = CircularInternals.validation_problems(spec, settings)

		if !problems.is_empty() {
			Err(problems)
		} else {
			node_count = spec.nodes.len()
			sequence = CircularInternals.ring_order(node_count, spec.edges)
			polished = CircularInternals.polish(sequence, spec.edges, node_count, CircularPrepared.round_cap)
			ring = CircularInternals.place_on_ring(polished, spec.nodes, settings)
			routes = CircularInternals.route_edges(spec.edges, ring.positions, ring.angles, spec.nodes, settings.node_gap)
			normalized = CircularInternals.normalize(ring.positions, spec.nodes, routes)

			prepared : CircularPrepared
			prepared = {
				result: {
					layout: normalized,
					order: CircularInternals.seats_of(polished, node_count),
				},
			}
			Ok(prepared)
		}
	}

	run : CircularPrepared -> Graph.Result
	run = |prepared| prepared.result

	layout : Graph.Spec, Graph.CircularSettings -> [Ok(Graph.Result), Err(List(Graph.Problem))]
	layout = |spec, settings|
		match CircularPrepared.build(spec, settings) {
			Ok(prepared) => Ok(prepared.run())
			Err(problems) => Err(problems)
		}
}

## General-graph layouts for data whose meaning comes from connectivity: any
## sized graph, no structure claimed beyond nodes and edges. Four readings of
## the same input:
##
## - `layout_circular` — all nodes on one ring, neighbors seated together.
## - `layout_force` — organic clusters from a seeded physical simulation
##   (one-call form here; the `ForceLayout` module has the reusable
##   prepare/place/run surface, position hints, and pins).
## - `layout_stress` — drawn distances tracking graph distances (one-call
##   form here; the reusable surface is in `StressLayout`).
## - `layout_radial` — concentric rings by depth from a root (one-call
##   form here; the reusable surface is in `RadialLayout`).
##
## For repeated circular layouts of unchanged input, call `prepare_circular`
## once and pass the result to `layout_circular_prepared`.
Graph := [].{

	## The shared input every layout family consumes: sized nodes and the
	## edges between them. A node is identified by its index in `nodes` and
	## an edge by its index in `edges`; every output list aligns to those
	## orders.
	Spec : {
		nodes : List({ width : F64, height : F64 }),
		edges : List({ from : U64, to : U64 }),
	}

	## General-graph input is the shared spec itself.
	Input : Spec

	## Space between neighbors on the ring, where the first node sits
	## (radians), and which way around the ring the order runs. The radius
	## is derived from node extents and the gap, not configured.
	CircularSettings : {
		node_gap : F64,
		start_angle : F64,
		winding : [Clockwise, CounterClockwise],
	}

	## Invalid sizes, spacing, or edge endpoints found while checking input.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidStartAngle,
	]

	## Geometry plus each node's seat around the ring, counted from the
	## start angle in winding order.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		order : List(U64),
	}

	## The empty graph. Replace by record update.
	default_spec : Spec
	default_spec = { nodes: [], edges: [] }

	## General-graph input defaults to the empty spec.
	default_input : Input
	default_input = Graph.default_spec

	## Circular settings that produce a readable ring in common cases: the
	## first node sits at twelve o'clock and seats follow clockwise.
	default_circular_settings : CircularSettings
	default_circular_settings = { node_gap: 24, start_angle: 0 - Trig.tau / 4, winding: Clockwise }

	## Check the input and settings, then cache the layout they determine.
	prepare_circular : Input, CircularSettings -> [Ok(CircularPrepared), Err(List(Problem))]
	prepare_circular = |input, settings| CircularPrepared.build(input, settings)

	## Return the previously computed circular layout. This operation cannot
	## fail.
	layout_circular_prepared : CircularPrepared -> Result
	layout_circular_prepared = |prepared| prepared.run()

	## Check and lay out input in one call, read as a ring: every node on
	## one circle, neighbors seated together, crossings reduced.
	layout_circular : Input, CircularSettings -> [Ok(Result), Err(List(Problem))]
	layout_circular = |input, settings| CircularPrepared.layout(input, settings)

	## Force settings that produce a readable organic drawing in common
	## cases; see the `ForceLayout` module for what each dial changes.
	default_force_settings : {
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		opening_angle : F64,
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	}
	default_force_settings = ForceLayout.force_defaults

	## The default force run arguments: the fixed seed and no position hints.
	default_force_run : { seed : U32, hints : List({ x : F64, y : F64 }) }
	default_force_run = ForceLayout.force_default_run

	## Check and lay out input in one call, read organically: connected
	## nodes pull together, everything else pushes apart, and clusters
	## emerge from the balance. The seed selects among equally valid
	## drawings. For repeated layouts, position hints, or pinned nodes, use
	## the `ForceLayout` module's prepare/place/run surface.
	layout_force : Input,
	{
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		opening_angle : F64,
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	},
	{ seed : U32, hints : List({ x : F64, y : F64 }) } -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				components : List(U64),
				convergence : { iterations : U64, converged : Bool },
			},
		),
		Err(
			List(
				[
					InvalidNodeWidth(U64),
					InvalidNodeHeight(U64),
					MissingEdgeStart(U64, U64),
					MissingEdgeEnd(U64, U64),
					InvalidNodeGap,
					InvalidRepulsion,
					InvalidGravity,
					InvalidOpeningAngle,
					InvalidTolerance,
					MissingPin(U64),
					InvalidPin(U64),
				],
			),
		),
	]
	layout_force = |input, settings, run_args| ForceLayout.layout_force(input, settings, run_args)

	## Stress settings that produce a readable distance-faithful drawing in
	## common cases; see the `StressLayout` module for what each dial
	## changes.
	default_stress_settings : {
		node_gap : F64,
		mode : [Exact, Pivots(U64)],
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	}
	default_stress_settings = StressLayout.stress_defaults

	## The default stress run arguments: the fixed seed and no position
	## hints.
	default_stress_run : { seed : U32, hints : List({ x : F64, y : F64 }) }
	default_stress_run = StressLayout.stress_default_run

	## Check and lay out input in one call, read metrically: how far apart
	## two nodes are drawn tracks how far apart they are in the graph. For
	## repeated layouts, position hints, or pinned nodes, use the
	## `StressLayout` module's prepare/place/run surface.
	layout_stress : Input,
	{
		node_gap : F64,
		mode : [Exact, Pivots(U64)],
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	},
	{ seed : U32, hints : List({ x : F64, y : F64 }) } -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				components : List(U64),
				convergence : { iterations : U64, converged : Bool },
			},
		),
		Err(
			List(
				[
					InvalidNodeWidth(U64),
					InvalidNodeHeight(U64),
					MissingEdgeStart(U64, U64),
					MissingEdgeEnd(U64, U64),
					InvalidNodeGap,
					InvalidPivotCount,
					InvalidTolerance,
					MissingPin(U64),
					InvalidPin(U64),
				],
			),
		),
	]
	layout_stress = |input, settings, run_args| StressLayout.layout_stress(input, settings, run_args)

	## Radial settings that produce a readable ringed drawing in common
	## cases; see the `RadialLayout` module for what each dial changes.
	default_radial_settings : {
		root : [Auto, Node(U64)],
		ring_gap : F64,
		node_gap : F64,
		start_angle : F64,
		winding : [Clockwise, CounterClockwise],
	}
	default_radial_settings = RadialLayout.radial_defaults

	## Check and lay out input in one call, read as centrality: concentric
	## rings by depth from a root, everything oriented around one thing.
	## For the reusable prepare/run surface, use the `RadialLayout` module.
	layout_radial : Input,
	{
		root : [Auto, Node(U64)],
		ring_gap : F64,
		node_gap : F64,
		start_angle : F64,
		winding : [Clockwise, CounterClockwise],
	} -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				rings : List(U64),
				components : List(U64),
			},
		),
		Err(
			List(
				[
					InvalidNodeWidth(U64),
					InvalidNodeHeight(U64),
					MissingEdgeStart(U64, U64),
					MissingEdgeEnd(U64, U64),
					InvalidRingGap,
					InvalidNodeGap,
					InvalidStartAngle,
					InvalidRoot(U64),
				],
			),
		),
	]
	layout_radial = |input, settings| RadialLayout.layout_radial(input, settings)
}

## The empty graph has a defined circular layout: no positions, no routes,
## zero-size bounds at the origin.
expect Graph.layout_circular(Graph.default_input, Graph.default_circular_settings) == Ok({
	layout: { positions: [], bounds: Geom.empty_bounds, routes: [] },
	order: [],
})

## A single node sits centered on itself at the origin.
expect {
	spec = { ..Graph.default_spec, nodes: [{ width: 10, height: 6 }] }
	match Graph.layout_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) => {
			p = result.layout.positions.get(0) ?? Geom.point(0, 0)
			(p.x - 5).abs() < 1e-9 and (p.y - 3).abs() < 1e-9 and result.order == [0]
		}
	}
}

## Affinity ordering recovers a cycle: every edge of a six-cycle joins two
## nodes seated next to each other on the ring.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 6)
	edges = [
		{ from: 0, to: 1 },
		{ from: 1, to: 2 },
		{ from: 2, to: 3 },
		{ from: 3, to: 4 },
		{ from: 4, to: 5 },
		{ from: 5, to: 0 },
	]
	match Graph.layout_circular({ nodes, edges }, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) =>
			edges.all(
				|edge| {
					a = result.order.get(edge.from) ?? 0
					b = result.order.get(edge.to) ?? 0
					gap = (a + 6 - b) % 6
					gap == 1 or gap == 5
				},
			)
		}
}

## Equal nodes sit equidistant from the ring's center.
expect {
	nodes = List.repeat({ width: 8, height: 8 }, 5)
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }]
	match Graph.layout_circular({ nodes, edges }, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) => {
			count = result.layout.positions.len().to_f64()
			center_x = result.layout.positions.fold(0, |acc, p| acc + p.x) / count
			center_y = result.layout.positions.fold(0, |acc, p| acc + p.y) / count
			first = result.layout.positions.get(0) ?? Geom.point(0, 0)
			first_r = ((first.x - center_x) * (first.x - center_x) + (first.y - center_y) * (first.y - center_y)).sqrt()
			result.layout.positions.all(
				|p| {
					r = ((p.x - center_x) * (p.x - center_x) + (p.y - center_y) * (p.y - center_y)).sqrt()
					(r - first_r).abs() < 1e-9
				},
			)
		}
	}
}

## A self-loop routes as a smooth closed teardrop beside its node: exactly
## two cubic segments of finite points that start and end at the same point
## on the node's boundary.
expect {
	spec = { nodes: [{ width: 10, height: 10 }], edges: [{ from: 0, to: 0 }] }
	match Graph.layout_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) =>
			match result.layout.routes.get(0) {
				Ok(Curves(segments)) => {
					zero = Geom.point(0, 0)
					fallback = { from: zero, ctl_a: zero, ctl_b: zero, to: zero }
					first = segments.get(0) ?? fallback
					last = segments.get(1) ?? fallback
					finite = segments.all(
						|seg| [seg.from, seg.ctl_a, seg.ctl_b, seg.to].all(
							|p| F64.is_finite(p.x) and F64.is_finite(p.y),
						),
					)
					center = result.layout.positions.get(0) ?? zero
					dx = (first.from.x - center.x).abs()
					dy = (first.from.y - center.y).abs()
					on_boundary =
						((dx - 5).abs() < 1e-9 and dy <= 5 + 1e-9)
							or ((dy - 5).abs() < 1e-9 and dx <= 5 + 1e-9)
					segments.len() == 2 and finite and last.to == first.from and on_boundary
				}

				_ => False
			}
		}
}

## Parallel edges fan apart: two edges over the same pair take different
## cubic bows, offset to opposite sides.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }, { from: 0, to: 1 }],
	}
	match Graph.layout_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) =>
			match (result.layout.routes.get(0), result.layout.routes.get(1)) {
				(Ok(Curves(a)), Ok(Curves(b))) => a != b
				_ => False
			}
		}
}

## Oppositely directed parallel edges also fan to distinct sides: reversing
## one edge's direction must not fold its bow onto the other's, so the
## second route is not merely the first traversed backwards.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }, { from: 1, to: 0 }],
	}
	match Graph.layout_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) =>
			match (result.layout.routes.get(0), result.layout.routes.get(1)) {
				(Ok(Curves([seg_a])), Ok(Curves([seg_b]))) => {
					backwards = { from: seg_a.to, ctl_a: seg_a.ctl_b, ctl_b: seg_a.ctl_a, to: seg_a.from }
					seg_b != backwards and seg_b.from == seg_a.to and seg_b.to == seg_a.from
				}

				_ => False
			}
		}
}

## Adjacent nodes clear each other by at least their required distance even
## on tiny rings, where equal arc spacing alone would overlap them: centers
## sit a chord apart, and the radius grows until the chord suffices.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [],
	}
	settings = { ..Graph.default_circular_settings, node_gap: 0 }
	match Graph.layout_circular(spec, settings) {
		Err(_) => False
		Ok(result) => {
			a = result.layout.positions.get(0) ?? Geom.point(0, 0)
			b = result.layout.positions.get(1) ?? Geom.point(0, 0)
			distance = Geom.hypot(b.x - a.x, b.y - a.y)
			distance + 1e-9 >= Geom.hypot(10, 10)
		}
	}
}

## Extreme finite sizes stay finite: the diagonal is computed without
## squaring the raw dimensions, so near-maximum nodes do not overflow the
## geometry to infinity.
expect {
	spec = {
		nodes: [{ width: 1.0e300, height: 1.0e300 }, { width: 1.0e300, height: 1.0e300 }],
		edges: [{ from: 0, to: 1 }],
	}
	match Graph.layout_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) =>
			result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
				and F64.is_finite(result.layout.bounds.width)
					and F64.is_finite(result.layout.bounds.height)
		}
}

## A chord's endpoints attach to the node boundaries, not the centers: each
## endpoint sits exactly on its own node's box, at the half-extent on the
## exit axis and within the half-extent on the other.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	match Graph.layout_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(result) => {
			on_boundary = |p, c| {
				dx = (p.x - c.x).abs()
				dy = (p.y - c.y).abs()
				((dx - 5).abs() < 1e-9 and dy <= 5 + 1e-9)
					or ((dy - 5).abs() < 1e-9 and dx <= 5 + 1e-9)
			}
			c0 = result.layout.positions.get(0) ?? Geom.point(0, 0)
			c1 = result.layout.positions.get(1) ?? Geom.point(0, 0)
			match result.layout.routes.get(0) {
				Ok(Line(a, b)) => on_boundary(a, c0) and on_boundary(b, c1)
				_ => False
			}
		}
	}
}

## Circular `build` reports every independent problem it finds, across both
## the input and the settings.
expect {
	spec = {
		nodes: [{ width: -1, height: 3 }],
		edges: [{ from: 0, to: 2 }],
	}
	settings = { ..Graph.default_circular_settings, node_gap: -4, start_angle: F64.infinity }

	Graph.prepare_circular(spec, settings) == Err([
		InvalidNodeWidth(0),
		MissingEdgeEnd(0, 2),
		InvalidNodeGap,
		InvalidStartAngle,
	])
}

## The one-shot circular API is exactly build followed by run.
expect {
	spec = {
		nodes: [{ width: 8, height: 4 }, { width: 8, height: 4 }],
		edges: [{ from: 0, to: 1 }],
	}
	match Graph.prepare_circular(spec, Graph.default_circular_settings) {
		Err(_) => False
		Ok(prepared) => Graph.layout_circular(spec, Graph.default_circular_settings) == Ok(prepared.run())
	}
}

## Identical input and settings produce identical circular output.
expect {
	spec = {
		nodes: List.repeat({ width: 12, height: 8 }, 7),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 1, to: 3 },
			{ from: 2, to: 4 },
			{ from: 4, to: 5 },
			{ from: 5, to: 6 },
			{ from: 6, to: 0 },
		],
	}
	Graph.layout_circular(spec, Graph.default_circular_settings) == Graph.layout_circular(spec, Graph.default_circular_settings)
}

## The one-call force layout is exactly the ForceLayout module's: same
## validation, same geometry, bit for bit.
expect {
	spec = {
		nodes: List.repeat({ width: 20, height: 20 }, 4),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 0 }],
	}
	Graph.layout_force(spec, Graph.default_force_settings, Graph.default_force_run)
		== ForceLayout.layout_force(spec, ForceLayout.force_defaults, ForceLayout.force_default_run)
}

## The one-call stress layout is exactly the StressLayout module's.
expect {
	spec = {
		nodes: List.repeat({ width: 20, height: 20 }, 3),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
	}
	Graph.layout_stress(spec, Graph.default_stress_settings, Graph.default_stress_run)
		== StressLayout.layout_stress(spec, StressLayout.stress_defaults, StressLayout.stress_default_run)
}

## Force and stress one-shots report aggregated problems through Graph.
expect {
	bad = { nodes: [{ width: 0 - 1.0, height: 2 }], edges: [{ from: 0, to: 5 }] }
	force_err = match Graph.layout_force(bad, Graph.default_force_settings, Graph.default_force_run) {
		Err(problems) => problems.len() >= 2
		Ok(_) => False
	}
	stress_err = match Graph.layout_stress(bad, Graph.default_stress_settings, Graph.default_stress_run) {
		Err(problems) => problems.len() >= 2
		Ok(_) => False
	}
	force_err and stress_err
}

## The one-call radial layout is exactly the RadialLayout module's.
expect {
	spec = {
		nodes: List.repeat({ width: 20, height: 20 }, 5),
		edges: [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 0, to: 3 }, { from: 0, to: 4 }],
	}
	Graph.layout_radial(spec, Graph.default_radial_settings)
		== RadialLayout.layout_radial(spec, RadialLayout.radial_defaults)
}
