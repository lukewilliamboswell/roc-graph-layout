import EdgeRoutes
import Geom
import Pack
import Paths
import Trig

## Pure helpers behind `Graph.Radial`: joint validation, per-component root
## selection, breadth-first ring assignment, neighbor-median ring ordering,
## chord-safe ring radii, and the angular projection that turns rings into
## positions.
RadialInternals :: {}.{

	## `[0, 1, .., n - 1]`, the building block for walking a bounded range.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Every independent input and settings problem, in input order first and
	## settings order second, so callers see the complete picture at once.
	validation_problems : GraphRadialPrepared.Spec, GraphRadialPrepared.Settings -> List(GraphRadialPrepared.Problem)
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

		ring_gap_problems = if !F64.is_finite(settings.ring_gap) or settings.ring_gap < 0 {
			edge_problems.append(InvalidRingGap)
		} else {
			edge_problems
		}

		node_gap_problems = if !F64.is_finite(settings.node_gap) or settings.node_gap < 0 {
			ring_gap_problems.append(InvalidNodeGap)
		} else {
			ring_gap_problems
		}

		angle_problems = if F64.is_finite(settings.start_angle) {
			node_gap_problems
		} else {
			node_gap_problems.append(InvalidStartAngle)
		}

		match settings.root {
			Auto => angle_problems
			Node(index) =>
				if index < spec.nodes.len() {
					angle_problems
				} else {
					angle_problems.append(InvalidRoot(index))
				}
			}
	}

	## A node's non-loop degree straight from the compressed adjacency, which
	## skips self-loops and counts each parallel edge copy.
	degree_of : Paths.Adjacency, U64 -> U64
	degree_of = |adj, node| {
		start = adj.offsets.get(node) ?? 0
		stop = adj.offsets.get(node + 1) ?? start
		stop - start
	}

	## The automatic root of one component: its highest non-loop degree,
	## ties toward the lowest index. Members arrive in ascending index
	## order, so keeping the first strict maximum breaks ties correctly.
	auto_root : Paths.Adjacency, List(U64) -> U64
	auto_root = |adj, members|
		members.fold(
			{ node: 0, degree: 0, found: False },
			|best, member| {
				degree = RadialInternals.degree_of(adj, member)
				if !best.found or degree > best.degree {
					{ node: member, degree, found: True }
				} else {
					best
				}
			},
		).node

	## The root one component actually uses: a configured `Node(i)` applies
	## to the component containing node `i`, and every other component falls
	## back to the automatic rule.
	component_root : Paths.Adjacency, List(U64), List(U64), U64, [Auto, Node(U64)] -> U64
	component_root = |adj, labels, members, component, configured|
		match configured {
			Auto => RadialInternals.auto_root(adj, members)
			Node(index) =>
				if labels.get(index) == Ok(component) {
					index
				} else {
					RadialInternals.auto_root(adj, members)
				}
			}

	## Appends one parent's undiscovered next-ring neighbors in ascending
	## index order, marking them seen — the "children grouped under their
	## parent, ties by index" half of BFS discovery order.
	collect_children : Paths.Adjacency, List(F64), F64, List(U64), List(Bool), U64 -> { order : List(U64), seen : List(Bool) }
	collect_children = |adj, distances, target, order, seen, parent| {
		sorted = Paths.neighbors_of(adj, parent).sort_with(
			|a, b|
				if a < b {
					LT
				} else {
					GT
				},
		)
		sorted.fold(
			{ order, seen },
			|inner, neighbor| {
				in_ring = (distances.get(neighbor) ?? F64.infinity) == target
				# `== False` rather than `!`: negating a `??`-derived Bool
				# miscompiles on the pinned nightly.
				unseen = (inner.seen.get(neighbor) ?? True) == False
				if in_ring and unseen {
					{
						order: inner.order.append(neighbor),
						seen: inner.seen.set(neighbor, True) ?? inner.seen,
					}
				} else {
					inner
				}
			},
		)
	}

	## Grows the ring list one BFS wave at a time, parent-major: ring
	## `d + 1` lists each ring-`d` node's children in parent order. Fuel
	## bounds the recursion by the node count.
	expand_ring_orders : Paths.Adjacency, List(F64), List(List(U64)), List(U64), List(Bool), U64, U64 -> List(List(U64))
	expand_ring_orders = |adj, distances, acc, current, seen, depth, fuel| {
		if current.is_empty() or fuel == 0 {
			acc
		} else {
			target = (depth + 1).to_f64()
			next = current.fold(
				{ order: [], seen },
				|state, parent| RadialInternals.collect_children(adj, distances, target, state.order, state.seen, parent),
			)
			if next.order.is_empty() {
				acc
			} else {
				RadialInternals.expand_ring_orders(adj, distances, acc.append(next.order), next.order, next.seen, depth + 1, fuel - 1)
			}
		}
	}

	## One component's rings in initial BFS discovery order: ring 0 is the
	## root alone, and each deeper ring groups children under their parent's
	## position in the previous ring, ties by index.
	ring_orders_from : Paths.Adjacency, List(F64), U64, U64 -> List(List(U64))
	ring_orders_from = |adj, distances, root, node_count| {
		unseen = List.repeat(False, node_count)
		seen = unseen.set(root, True) ?? unseen
		RadialInternals.expand_ring_orders(adj, distances, [[root]], [root], seen, 0, node_count)
	}

	## Each ring node's arc slot: its diagonal plus the configured gap. The
	## diagonal bounds a box's footprint at every angle, so slots are
	## direction-independent.
	ring_slots : List(U64), List({ width : F64, height : F64 }), F64 -> List(F64)
	ring_slots = |order, nodes, node_gap|
		order.map(
			|node| EdgeRoutes.diagonal(nodes.get(node) ?? { width: 0, height: 0 }) + node_gap,
		)

	## Each ring position's slot-center fraction of the full turn, in ring
	## order — the winding-independent angular coordinate the median sweeps
	## and the final angle assignment share.
	ring_fractions : List(U64), List({ width : F64, height : F64 }), F64 -> List(F64)
	ring_fractions = |order, nodes, node_gap| {
		slots = RadialInternals.ring_slots(order, nodes, node_gap)
		total = slots.fold(0, |acc, slot| acc + slot)
		safe_total = if total > 0 {
			total
		} else {
			1
		}
		slots.fold(
			{ list: [], cursor: 0.0 },
			|state, slot| {
				list: state.list.append((state.cursor + slot / 2) / safe_total),
				cursor: state.cursor + slot,
			},
		).list
	}

	## The median of a non-empty list: the middle value, or the mean of the
	## two middle values when the count is even.
	median_of : List(F64) -> F64
	median_of = |values| {
		sorted = values.sort_with(
			|a, b|
				if a < b {
					LT
				} else {
					GT
				},
		)
		m = sorted.len()
		if m % 2 == 1 {
			sorted.get(m / 2) ?? 0
		} else {
			((sorted.get(m / 2 - 1) ?? 0) + (sorted.get(m / 2) ?? 0)) / 2
		}
	}

	## Reorders one ring by each node's median neighbor angular position in
	## the previous ring — the layer sweep's median heuristic bent around a
	## ring. Nodes with no previous-ring neighbor keep their own current
	## angular position as the key, and ties break by current order, then
	## index.
	reorder_ring : Paths.Adjacency, List(F64), List(U64), List({ width : F64, height : F64 }), F64, List(F64), U64 -> List(U64)
	reorder_ring = |adj, distances, ring, nodes, node_gap, fraction_of, depth| {
		own_fractions = RadialInternals.ring_fractions(ring, nodes, node_gap)
		prev_target = (depth - 1).to_f64()

		keyed = ring.map_with_index(
			|node, position| {
				neighbor_fractions = Paths.neighbors_of(adj, node).fold(
					[],
					|acc, neighbor|
						if (distances.get(neighbor) ?? F64.infinity) == prev_target {
							acc.append(fraction_of.get(neighbor) ?? 0)
						} else {
							acc
						},
				)
				key = if neighbor_fractions.is_empty() {
					own_fractions.get(position) ?? 0
				} else {
					RadialInternals.median_of(neighbor_fractions)
				}
				{ node, position, key }
			},
		)

		keyed.sort_with(
			|a, b|
				if a.key < b.key {
					LT
				} else if a.key > b.key {
					GT
				} else if a.position < b.position {
					LT
				} else if a.position > b.position {
					GT
				} else if a.node < b.node {
					LT
				} else {
					GT
				},
		).map(|entry| entry.node)
	}

	## Up to three top-down median sweeps over one component's rings: each
	## sweep reorders ring `d` against the already-reordered ring `d - 1`.
	## The count is a hard bound, so termination never depends on
	## convergence.
	median_sweeps : Paths.Adjacency, List(F64), List(List(U64)), List({ width : F64, height : F64 }), F64, U64 -> List(List(U64))
	median_sweeps = |adj, distances, ring_orders, nodes, node_gap, node_count|
		RadialInternals.indices_up_to(3).fold(
			ring_orders,
			|swept, _sweep|
				RadialInternals.indices_up_to(swept.len()).fold(
					{ orders: swept, fraction_of: List.repeat(0.0, node_count) },
					|state, depth|
						if depth == 0 {
							state
						} else {
							prev_ring = state.orders.get(depth - 1) ?? []
							ring = state.orders.get(depth) ?? []
							if ring.len() < 2 {
								state
							} else {
								prev_fractions = RadialInternals.ring_fractions(prev_ring, nodes, node_gap)
								fraction_of = prev_ring.fold_with_index(
									state.fraction_of,
									|acc, node, position| acc.set(node, prev_fractions.get(position) ?? 0) ?? [],
								)
								reordered = RadialInternals.reorder_ring(adj, distances, ring, nodes, node_gap, fraction_of, depth)
								{ orders: state.orders.set(depth, reordered) ?? [], fraction_of }
							}
						},
				).orders,
		)

	## A ring's radial extent: the largest node diagonal on it, which bounds
	## every box's footprint whatever its angle.
	ring_extent : List(U64), List({ width : F64, height : F64 }) -> F64
	ring_extent = |order, nodes|
		order.fold(
			0,
			|acc, node| acc.max(EdgeRoutes.diagonal(nodes.get(node) ?? { width: 0, height: 0 })),
		)

	## Center-line radius per ring before crowding is considered: the root's
	## ring is radius 0, and each deeper ring clears the previous one by
	## both rings' half extents plus `ring_gap`.
	base_radii : List(F64), F64 -> List(F64)
	base_radii = |extents, ring_gap| {
		starts = extents.fold_with_index(
			{ starts: List.repeat(0.0, extents.len()), cursor: 0.0 },
			|state, extent, depth| { starts: state.starts.set(depth, state.cursor) ?? [], cursor: state.cursor + extent + ring_gap },
		).starts
		center_0 = (extents.get(0) ?? 0) / 2
		extents.map_with_index(
			|extent, depth| (starts.get(depth) ?? 0) + extent / 2 - center_0,
		)
	}

	## The smallest radius at which one ring's nodes fit: the circumference
	## must hold the summed arc slots, and every adjacent pair's chord must
	## reach its required clearance — centers sit a chord apart, and a chord
	## is shorter than its arc, so arc spacing alone can overlap neighbors
	## on small rings. A ring of one node needs no radius at all.
	required_radius : List(U64), List({ width : F64, height : F64 }), F64 -> F64
	required_radius = |order, nodes, node_gap| {
		seat_count = order.len()
		if seat_count < 2 {
			0
		} else {
			slots = RadialInternals.ring_slots(order, nodes, node_gap)
			total = slots.fold(0, |acc, slot| acc + slot)
			safe_total = if total > 0 {
				total
			} else {
				1
			}
			RadialInternals.indices_up_to(seat_count).fold(
				total / Trig.tau,
				|acc, seat| {
					next_seat = if seat + 1 == seat_count {
						0
					} else {
						seat + 1
					}
					slot_a = slots.get(seat) ?? 0
					slot_b = slots.get(next_seat) ?? 0
					required = (slot_a + slot_b) / 2
					half_angle = Trig.tau * (slot_a + slot_b) / (4 * safe_total)
					chord_per_radius = 2 * Trig.sin(half_angle)
					if required > 0 and chord_per_radius > 0 {
						acc.max(required / chord_per_radius)
					} else {
						acc
					}
				},
			)
		}
	}

	## Final ring radii: each ring takes the larger of its separation-based
	## radius and its crowding requirement, and any growth shifts every
	## deeper ring outward by the same amount so ring separation is
	## preserved.
	grow_radii : List(List(U64)), List(F64), List({ width : F64, height : F64 }), F64 -> List(F64)
	grow_radii = |ring_orders, base, nodes, node_gap|
		base.fold_with_index(
			{ radii: List.repeat(0.0, base.len()), shift: 0.0 },
			|state, base_radius, depth| {
				order = ring_orders.get(depth) ?? []
				shifted = base_radius + state.shift
				required = RadialInternals.required_radius(order, nodes, node_gap)
				final = shifted.max(required)
				{ radii: state.radii.set(depth, final) ?? [], shift: state.shift + (final - shifted) }
			},
		).radii

	## Projects one component's rings onto circles around its local origin:
	## cumulative arc slots map to `[start_angle, start_angle + tau)` in
	## winding order, each node centered in its slot, and the root sits at
	## the component center. Writes positions and ring depths into the
	## global index-aligned lists.
	place_rings : List(List(U64)), List(F64), List({ width : F64, height : F64 }), GraphRadialPrepared.Settings, List({ x : F64, y : F64 }), List(U64) -> { positions : List({ x : F64, y : F64 }), rings : List(U64) }
	place_rings = |ring_orders, radii, nodes, settings, positions0, rings0| {
		dir_sign = match settings.winding {
			Clockwise => 1.0
			CounterClockwise => 0 - 1.0
		}

		ring_orders.fold_with_index(
			{ positions: positions0, rings: rings0 },
			|state, order, depth| {
				radius = radii.get(depth) ?? 0
				slots = RadialInternals.ring_slots(order, nodes, settings.node_gap)
				total = slots.fold(0, |acc, slot| acc + slot)
				safe_total = if total > 0 {
					total
				} else {
					1
				}
				placed = order.fold_with_index(
					{ positions: state.positions, rings: state.rings, cursor: 0.0 },
					|inner, node, seat| {
						slot = slots.get(seat) ?? 0
						angle = settings.start_angle + dir_sign * Trig.tau * ((inner.cursor + slot / 2) / safe_total)
						point = { x: radius * Trig.cos(angle), y: radius * Trig.sin(angle) }
						{
							positions: inner.positions.set(node, point) ?? [],
							rings: inner.rings.set(node, depth) ?? [],
							cursor: inner.cursor + slot,
						}
					},
				)
				{ positions: placed.positions, rings: placed.rings }
			},
		)
	}

	## The whole successful pipeline: per-component roots, BFS rings, median
	## ordering, chord-safe radii, and angular placement; then component
	## boxes packed into shelves, positions translated, routes built along
	## per-node outward directions, and the finished drawing normalized to
	## the origin.
	layout_all : GraphRadialPrepared.Spec, GraphRadialPrepared.Settings -> GraphRadialPrepared.Result
	layout_all = |spec, settings| {
		node_count = spec.nodes.len()
		adj = Paths.adjacency(node_count, spec.edges)
		comp = Paths.components(adj)

		member_counts = comp.labels.fold(
			List.repeat(0, comp.count),
			|counts, label| counts.set(label, (counts.get(label) ?? 0) + 1) ?? [],
		)
		member_index = member_counts.fold(
			{ offsets: [0], total: 0 },
			|state, count| {
				total = state.total + count
				{ offsets: state.offsets.append(total), total }
			},
		)
		members_flat = RadialInternals.indices_up_to(node_count).fold(
			{ members: List.repeat(0, node_count), cursors: member_index.offsets.take_first(comp.count) },
			|state, node| {
				label = comp.labels.get(node) ?? 0
				cursor = state.cursors.get(label) ?? 0
				{
					members: state.members.set(cursor, node) ?? [],
					cursors: state.cursors.set(label, cursor + 1) ?? [],
				}
			},
		)

		per = RadialInternals.indices_up_to(comp.count).fold(
			{
				positions: List.repeat({ x: 0.0, y: 0.0 }, node_count),
				rings: List.repeat(0, node_count),
				boxes: [],
				centers: [],
				roots: [],
			},
			|state, component| {
				member_start = member_index.offsets.get(component) ?? 0
				member_stop = member_index.offsets.get(component + 1) ?? member_start
				members = RadialInternals.indices_up_to(member_stop - member_start).map(|index| members_flat.members.get(member_start + index) ?? 0)
				root = RadialInternals.component_root(adj, comp.labels, members, component, settings.root)
				distances = Paths.bfs_distances(adj, root)
				initial_orders = RadialInternals.ring_orders_from(adj, distances, root, node_count)
				orders = RadialInternals.median_sweeps(adj, distances, initial_orders, spec.nodes, settings.node_gap, node_count)
				extents = orders.map(|order| RadialInternals.ring_extent(order, spec.nodes))
				base = RadialInternals.base_radii(extents, settings.ring_gap)
				radii = RadialInternals.grow_radii(orders, base, spec.nodes, settings.node_gap)
				placed = RadialInternals.place_rings(orders, radii, spec.nodes, settings, state.positions, state.rings)

				first = members.get(0) ?? 0
				first_point = placed.positions.get(first) ?? { x: 0, y: 0 }
				first_size = spec.nodes.get(first) ?? { width: 0, height: 0 }
				box0 = {
					min_x: first_point.x - first_size.width / 2,
					min_y: first_point.y - first_size.height / 2,
					max_x: first_point.x + first_size.width / 2,
					max_y: first_point.y + first_size.height / 2,
				}
				box = members.fold(
					box0,
					|acc, member| {
						point = placed.positions.get(member) ?? { x: 0, y: 0 }
						size = spec.nodes.get(member) ?? { width: 0, height: 0 }
						{
							min_x: acc.min_x.min(point.x - size.width / 2),
							min_y: acc.min_y.min(point.y - size.height / 2),
							max_x: acc.max_x.max(point.x + size.width / 2),
							max_y: acc.max_y.max(point.y + size.height / 2),
						}
					},
				)

				{
					positions: placed.positions,
					rings: placed.rings,
					boxes: state.boxes.append({ width: box.max_x - box.min_x, height: box.max_y - box.min_y }),
					centers: state.centers.append({ x: (box.min_x + box.max_x) / 2, y: (box.min_y + box.max_y) / 2 }),
					roots: state.roots.append(root),
				}
			},
		)

		packed = Pack.pack(per.boxes, { gap: settings.node_gap * 2, target_aspect: 1.0 })

		positions = per.positions.map_with_index(
			|point, node| {
				component = comp.labels.get(node) ?? 0
				target = packed.positions.get(component) ?? { x: 0, y: 0 }
				center = per.centers.get(component) ?? { x: 0, y: 0 }
				{ x: point.x + target.x - center.x, y: point.y + target.y - center.y }
			},
		)

		outwards = RadialInternals.indices_up_to(node_count).map(
			|node| {
				component = comp.labels.get(node) ?? 0
				root = per.roots.get(component) ?? 0
				if root == node {
					{ x: 0.0, y: 0 - 1.0 }
				} else {
					root_point = positions.get(root) ?? { x: 0, y: 0 }
					point = positions.get(node) ?? { x: 0, y: 0 }
					dx = point.x - root_point.x
					dy = point.y - root_point.y
					length = Geom.hypot(dx, dy)
					if length > 0 {
						{ x: dx / length, y: dy / length }
					} else {
						{ x: 0.0, y: 0 - 1.0 }
					}
				}
			},
		)

		routes = EdgeRoutes.route_edges(spec.edges, positions, outwards, spec.nodes, settings.node_gap)

		{
			layout: EdgeRoutes.normalize(positions, spec.nodes, routes),
			rings: per.rings,
			components: comp.labels,
		}
	}

}

## A validated and precomputed radial layout of a general graph: concentric
## rings by breadth-first depth from a root — the reading is centrality,
## everything oriented around one thing. Each connected component gets its
## own ring system, and the component drawings pack into shelves.
##
## `Radial` has no per-run arguments — its criteria determine the drawing
## uniquely — so `build` computes the complete result once, and `run` only
## returns it.
GraphRadialPrepared := {
	result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		rings : List(U64),
		components : List(U64),
	},
}.{

	## The shared graph input: sized nodes and the edges between them. A
	## node is identified by its index in `nodes` and an edge by its index
	## in `edges`; every output list aligns to those orders.
	Spec : {
		nodes : List({ width : F64, height : F64 }),
		edges : List({ from : U64, to : U64 }),
	}

	## Which node sits at the center, how much empty space separates
	## consecutive rings, how much separates neighbors along a ring, where
	## the first node of each ring sits (radians), and which way around the
	## rings the order runs. Ring radii are derived from node extents and
	## the gaps, not configured.
	##
	## `Auto` roots each component at its highest-degree node (self-loops
	## not counted, ties toward the lowest index). `Node(i)` must name a
	## real node; it roots the component containing node `i`, and every
	## other component still uses the `Auto` rule.
	Settings : {
		root : [Auto, Node(U64)],
		ring_gap : F64,
		node_gap : F64,
		start_angle : F64,
		winding : [Clockwise, CounterClockwise],
	}

	## Invalid sizes, spacing, edge endpoints, or root found while checking
	## input. Every independent problem is reported in one result.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidRingGap,
		InvalidNodeGap,
		InvalidStartAngle,
		InvalidRoot(U64),
	]

	## Geometry plus two structural byproducts, both index-aligned to the
	## spec's nodes: `rings` is each node's breadth-first depth from its
	## component's root, and `components` is each node's connected-component
	## label, counted from 0 in order of each component's lowest node index.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		rings : List(U64),
		components : List(U64),
	}

	## Radial settings that produce a readable drawing in common cases: an
	## automatic root, generous ring separation, and each ring starting at
	## twelve o'clock running clockwise.
	defaults : GraphRadialPrepared.Settings
	defaults = { root: Auto, ring_gap: 40, node_gap: 24, start_angle: 0 - Trig.tau / 4, winding: Clockwise }

	## Check the input and settings, then cache the layout they determine.
	build : GraphRadialPrepared.Spec, GraphRadialPrepared.Settings -> [Ok(GraphRadialPrepared), Err(List(GraphRadialPrepared.Problem))]
	build = |spec, settings| {
		problems = RadialInternals.validation_problems(spec, settings)

		if !problems.is_empty() {
			Err(problems)
		} else {
			prepared : GraphRadialPrepared
			prepared = { result: RadialInternals.layout_all(spec, settings) }
			Ok(prepared)
		}
	}

	## Return the previously computed radial layout. This operation cannot
	## fail.
	finish : GraphRadialPrepared -> GraphRadialPrepared.Result
	finish = |prepared| prepared.result

	## Check and lay out input in one call, read as concentric rings by
	## depth from a root. Equivalent to `build` followed by `run`.
	complete : GraphRadialPrepared.Spec, GraphRadialPrepared.Settings -> [Ok(GraphRadialPrepared.Result), Err(List(GraphRadialPrepared.Problem))]
	complete = |spec, settings|
		match GraphRadialPrepared.build(spec, settings) {
			Ok(prepared) => Ok(prepared.finish())
			Err(problems) => Err(problems)
		}
}

## The empty graph has a defined radial layout: no positions, no routes,
## zero-size bounds at the origin, and empty structural byproducts.
expect GraphRadialPrepared.complete({ nodes: [], edges: [] }, GraphRadialPrepared.defaults) == Ok({
	layout: { positions: [], bounds: { x: 0, y: 0, width: 0, height: 0 }, routes: [] },
	rings: [],
	components: [],
})

## A single node sits centered at half its size, on ring 0 of component 0.
expect {
	spec = { nodes: [{ width: 10, height: 6 }], edges: [] }
	match GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults) {
		Err(_) => False
		Ok(result) => {
			p = result.layout.positions.get(0) ?? Geom.point(0, 0)
			(p.x - 5).abs() < 1e-9
				and (p.y - 3).abs() < 1e-9
					and result.rings == [0]
						and result.components == [0]
		}
	}
}

## A star: the automatic root picks the hub, every leaf lands on ring 1,
## and all leaves sit equidistant from the hub.
expect {
	spec = {
		nodes: List.repeat({ width: 10, height: 10 }, 6),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 0, to: 3 },
			{ from: 0, to: 4 },
			{ from: 0, to: 5 },
		],
	}
	match GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults) {
		Err(_) => False
		Ok(result) => {
			hub = result.layout.positions.get(0) ?? Geom.point(0, 0)
			first = result.layout.positions.get(1) ?? Geom.point(0, 0)
			first_r = Geom.hypot(first.x - hub.x, first.y - hub.y)
			equidistant = result.layout.positions.fold_with_index(
				True,
				|acc, p, index|
					if index == 0 {
						acc
					} else {
						r = Geom.hypot(p.x - hub.x, p.y - hub.y)
						acc and (r - first_r).abs() < 1e-9
					},
			)
			result.rings == [0, 1, 1, 1, 1, 1] and first_r > 0 and equidistant
		}
	}
}

## An explicit root is respected: rooting the same star at a leaf makes the
## hub ring 1 and the remaining leaves ring 2.
expect {
	spec = {
		nodes: List.repeat({ width: 10, height: 10 }, 6),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 0, to: 3 },
			{ from: 0, to: 4 },
			{ from: 0, to: 5 },
		],
	}
	settings = { ..GraphRadialPrepared.defaults, root: Node(1) }
	match GraphRadialPrepared.complete(spec, settings) {
		Err(_) => False
		Ok(result) => result.rings == [1, 0, 2, 2, 2, 2]
	}
}

## Wide flat nodes on ring 1 overlap neither the root nor each other: ring
## extents come from node diagonals, which bound a box's footprint at every
## angle.
expect {
	spec = {
		nodes: List.repeat({ width: 100, height: 10 }, 5),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 0, to: 3 },
			{ from: 0, to: 4 },
		],
	}
	match GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults) {
		Err(_) => False
		Ok(result) =>
			result.layout.positions.fold_with_index(
				True,
				|all_ok, a, i|
					all_ok
						and result.layout.positions.fold_with_index(
							True,
							|pair_ok, b, j| {
								separated =
									i == j
										or (a.x - b.x).abs() * 2 >= 100 + 100
											or (a.y - b.y).abs() * 2 >= 10 + 10
								pair_ok and separated
							},
						),
			)
		}
}

## A crowded ring grows its radius: eight equal nodes with a tiny ring gap
## cannot fit at the separation-based radius, so the ring expands until
## every adjacent pair clears its required distance.
expect {
	spec = {
		nodes: List.repeat({ width: 30, height: 30 }, 9),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 0, to: 3 },
			{ from: 0, to: 4 },
			{ from: 0, to: 5 },
			{ from: 0, to: 6 },
			{ from: 0, to: 7 },
			{ from: 0, to: 8 },
		],
	}
	settings = { ..GraphRadialPrepared.defaults, ring_gap: 2 }
	match GraphRadialPrepared.complete(spec, settings) {
		Err(_) => False
		Ok(result) => {
			hub = result.layout.positions.get(0) ?? Geom.point(0, 0)
			required = Geom.hypot(30, 30) + 24
			# The separation-based radius alone would be diagonal + ring_gap
			# = about 44.4; growth must push well past it.
			grew = result.layout.positions.fold_with_index(
				True,
				|acc, p, index|
					if index == 0 {
						acc
					} else {
						acc and Geom.hypot(p.x - hub.x, p.y - hub.y) > 80
					},
			)
			cleared = result.layout.positions.fold_with_index(
				True,
				|all_ok, a, i|
					if i == 0 {
						all_ok
					} else {
						all_ok
							and result.layout.positions.fold_with_index(
								True,
								|pair_ok, b, j|
									if j == 0 or j == i {
										pair_ok
									} else {
										pair_ok and Geom.hypot(a.x - b.x, a.y - b.y) + 1e-9 >= required
									},
							)
					},
			)
			grew and cleared
		}
	}
}

## `build` reports every independent problem it finds, across the input and
## the settings, the root included.
expect {
	spec = {
		nodes: [{ width: -1, height: 3 }],
		edges: [{ from: 0, to: 2 }],
	}
	settings = {
		root: Node(9),
		ring_gap: -1,
		node_gap: -4,
		start_angle: F64.infinity,
		winding: Clockwise,
	}

	GraphRadialPrepared.build(spec, settings) == Err([
		InvalidNodeWidth(0),
		MissingEdgeEnd(0, 2),
		InvalidRingGap,
		InvalidNodeGap,
		InvalidStartAngle,
		InvalidRoot(9),
	])
}

## Two disconnected stars each get their own ring system: rings restart per
## component, the automatic root rule applies per component, and the packed
## component drawings do not overlap.
expect {
	spec = {
		nodes: List.repeat({ width: 20, height: 20 }, 8),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 0, to: 3 },
			{ from: 5, to: 4 },
			{ from: 5, to: 6 },
			{ from: 5, to: 7 },
		],
	}
	match GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults) {
		Err(_) => False
		Ok(result) => {
			separated = result.layout.positions.fold_with_index(
				True,
				|all_ok, a, i| {
					label_a = result.components.get(i) ?? 0
					all_ok
						and result.layout.positions.fold_with_index(
							True,
							|pair_ok, b, j| {
								label_b = result.components.get(j) ?? 0
								apart =
									label_a == label_b
										or (a.x - b.x).abs() * 2 >= 20 + 20
											or (a.y - b.y).abs() * 2 >= 20 + 20
								pair_ok and apart
							},
						)
				},
			)
			result.rings == [0, 1, 1, 1, 1, 0, 1, 1]
				and result.components == [0, 0, 0, 0, 1, 1, 1, 1]
					and separated
		}
	}
}

## Identical input and settings produce identical output, self-loops and
## parallel edges included.
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
			{ from: 3, to: 3 },
			{ from: 0, to: 2 },
		],
	}
	GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults) == GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults)
}

## The one-shot API is exactly build followed by run.
expect {
	spec = {
		nodes: [{ width: 8, height: 4 }, { width: 8, height: 4 }, { width: 8, height: 4 }],
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
	}
	match GraphRadialPrepared.build(spec, GraphRadialPrepared.defaults) {
		Err(_) => False
		Ok(prepared) => GraphRadialPrepared.complete(spec, GraphRadialPrepared.defaults) == Ok(prepared.finish())
	}
}

## Cross-module face: modules only see each other's namesake type, so the
## public wiring reaches this module through these delegations.
RadialLayout := [].{
	radial_defaults : GraphRadialPrepared.Settings
	radial_defaults = GraphRadialPrepared.defaults

	prepare_radial : GraphRadialPrepared.Spec, GraphRadialPrepared.Settings -> [Ok(GraphRadialPrepared), Err(List(GraphRadialPrepared.Problem))]
	prepare_radial = |spec, settings| GraphRadialPrepared.build(spec, settings)

	run_radial : GraphRadialPrepared -> GraphRadialPrepared.Result
	run_radial = |prepared| prepared.finish()

	layout_radial : GraphRadialPrepared.Spec, GraphRadialPrepared.Settings -> [Ok(GraphRadialPrepared.Result), Err(List(GraphRadialPrepared.Problem))]
	layout_radial = |spec, settings| GraphRadialPrepared.complete(spec, settings)
}
