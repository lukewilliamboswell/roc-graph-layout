import Geom

## Internal shared route construction: the uniform rules every point-placing
## algorithm inherits for turning positions into routes. Straight edges are
## boundary-clipped lines; parallel edges bow apart as cubic curves computed
## in a canonical direction so oppositely directed copies take distinct
## sides; self-loops are smooth teardrops pointing along a caller-supplied
## per-node outward direction (ring algorithms point away from the ring's
## center, free-placement algorithms away from their component's centroid).
## `normalize` then translates a finished drawing — positions and every
## route point, curve controls included — so its tight box sits at the
## origin.
EdgeRoutes :: {}.{

	## The safe footprint of a box whatever its angle: its diagonal.
	diagonal : { width : F64, height : F64 } -> F64
	diagonal = |size| Geom.hypot(size.width, size.height)

	## For each edge, its rank among the edges joining the same unordered
	## node pair, and how many there are — what deterministic fanning needs.
	pair_slot : List(Bool), List(U64), List(U64), U64, U64, U64, U64 -> U64
	pair_slot = |occupied, lows, highs, lo, hi, start, step| {
		capacity = occupied.len()
		slot = (start + step) % capacity
		if step + 1 >= capacity or !(occupied.get(slot) ?? False) or ((lows.get(slot) ?? 0) == lo and (highs.get(slot) ?? 0) == hi) {
			slot
		} else {
			EdgeRoutes.pair_slot(occupied, lows, highs, lo, hi, start, step + 1)
		}
	}

	parallel_ranks : List({ from : U64, to : U64 }) -> List({ rank : U64, count : U64 })
	parallel_ranks = |edges| {
		key_of = |edge| {
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
			{ lo, hi }
		}
		capacity = edges.len() * 2 + 1
		counted = edges.fold(
			{ occupied: List.repeat(False, capacity), lows: List.repeat(0, capacity), highs: List.repeat(0, capacity), counts: List.repeat(0, capacity) },
			|table, edge| {
				key = key_of(edge)
				start = key.lo.times_wrap(11400714819323198485).plus_wrap(key.hi.times_wrap(14029467366897019727)) % capacity
				slot = EdgeRoutes.pair_slot(table.occupied, table.lows, table.highs, key.lo, key.hi, start, 0)
				{
					occupied: table.occupied.set(slot, True) ?? [],
					lows: table.lows.set(slot, key.lo) ?? [],
					highs: table.highs.set(slot, key.hi) ?? [],
					counts: table.counts.set(slot, (table.counts.get(slot) ?? 0) + 1) ?? [],
				}
			},
		)
		ranked = edges.fold_with_index(
			{ seen: List.repeat(0, capacity), ranks: List.repeat({ rank: 0, count: 1 }, edges.len()) },
			|state, edge, index| {
				key = key_of(edge)
				start = key.lo.times_wrap(11400714819323198485).plus_wrap(key.hi.times_wrap(14029467366897019727)) % capacity
				slot = EdgeRoutes.pair_slot(counted.occupied, counted.lows, counted.highs, key.lo, key.hi, start, 0)
				rank = state.seen.get(slot) ?? 0
				count = counted.counts.get(slot) ?? 1
				{
					seen: state.seen.set(slot, rank + 1) ?? [],
					ranks: state.ranks.set(index, { rank, count }) ?? [],
				}
			},
		)
		ranked.ranks
	}

	## A smooth closed teardrop beside the node, pointing along the given
	## outward unit direction: out from the boundary, around, and back —
	## sized from the node's extent and the gap so it clears the node
	## deterministically. A zero direction falls back to pointing up.
	self_loop : { x : F64, y : F64 }, { x : F64, y : F64 }, { width : F64, height : F64 }, F64 -> Geom.Route
	self_loop = |center, outward, size, node_gap| {
		length = Geom.hypot(outward.x, outward.y)
		d = if length > 0 {
			{ x: outward.x / length, y: outward.y / length }
		} else {
			{ x: 0, y: 0 - 1.0 }
		}
		t = { x: 0 - d.y, y: d.x }
		g = (EdgeRoutes.diagonal(size) + node_gap) / 8
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
	## midpoint offsets computed in canonical (low index to high index)
	## direction, and self-loops as teardrops along `outward` directions
	## (one per node, index-aligned).
	route_edges : List({ from : U64, to : U64 }), List({ x : F64, y : F64 }), List({ x : F64, y : F64 }), List({ width : F64, height : F64 }), F64 -> List(Geom.Route)
	route_edges = |edges, positions, outwards, nodes, node_gap| {
		ranks = EdgeRoutes.parallel_ranks(edges)
		edges.map_with_index(
			|edge, index| {
				from_point = positions.get(edge.from) ?? { x: 0, y: 0 }
				from_size = nodes.get(edge.from) ?? { width: 0, height: 0 }
				if edge.from == edge.to {
					outward = outwards.get(edge.from) ?? { x: 0, y: 0 - 1.0 }
					EdgeRoutes.self_loop(from_point, outward, from_size, node_gap)
				} else {
					to_point = positions.get(edge.to) ?? { x: 0, y: 0 }
					to_size = nodes.get(edge.to) ?? { width: 0, height: 0 }
					a = Geom.clip_to_node(from_point, from_size, to_point)
					b = Geom.clip_to_node(to_point, to_size, from_point)
					fan = ranks.get(index) ?? { rank: 0, count: 1 }
					if fan.count == 1 {
						Line(a, b)
					} else {
						# Fan geometry in one canonical direction (lower node
						# index to higher) so oppositely directed parallel
						# edges take distinct sides; only the finished
						# segment's orientation follows the edge itself.
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
	## extent and every route point (curve control points included — the
	## convex hull property makes that a safe bound) sits with its top-left
	## corner at the origin.
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
					Curves(segments) =>
						segments.fold(
							acc,
							|inner, seg| extend(extend(extend(extend(inner, seg.from), seg.ctl_a), seg.ctl_b), seg.to),
						)
					},
		)

		dx = Geom.saturate(0 - box.min_x)
		dy = Geom.saturate(0 - box.min_y)
		shift = |p| { x: Geom.saturate(p.x + dx), y: Geom.saturate(p.y + dy) }

		{
			positions: positions.map(shift),
			bounds: { ..Geom.empty_bounds, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) },
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

## Parallel ranks preserve source order across interleaved and oppositely
## directed copies of the same unordered node pair.
expect
	EdgeRoutes.parallel_ranks([
		{ from: 0, to: 1 },
		{ from: 2, to: 3 },
		{ from: 1, to: 0 },
		{ from: 0, to: 1 },
		{ from: 3, to: 2 },
	])
		== [
			{ rank: 0, count: 3 },
			{ rank: 0, count: 2 },
			{ rank: 1, count: 3 },
			{ rank: 2, count: 3 },
			{ rank: 1, count: 2 },
		]

## A single edge between separated nodes is a boundary-to-boundary line.
expect {
	routes = EdgeRoutes.route_edges(
		[{ from: 0, to: 1 }],
		[{ x: 0, y: 0 }, { x: 20, y: 0 }],
		[{ x: 0, y: 0 - 1.0 }, { x: 0, y: 0 - 1.0 }],
		[{ width: 10, height: 10 }, { width: 10, height: 10 }],
		8,
	)
	routes == [Line({ x: 5, y: 0 }, { x: 15, y: 0 })]
}

## Oppositely directed parallel edges bow to distinct sides while each route
## still runs in its own edge's direction.
expect {
	routes = EdgeRoutes.route_edges(
		[{ from: 0, to: 1 }, { from: 1, to: 0 }],
		[{ x: 0, y: 0 }, { x: 20, y: 0 }],
		[{ x: 0, y: 0 - 1.0 }, { x: 0, y: 0 - 1.0 }],
		[{ width: 10, height: 10 }, { width: 10, height: 10 }],
		8,
	)
	match (routes.get(0), routes.get(1)) {
		(Ok(Curves([a])), Ok(Curves([b]))) => {
			backwards = { from: a.to, ctl_a: a.ctl_b, ctl_b: a.ctl_a, to: a.from }
			b != backwards and b.from == a.to and b.to == a.from
		}

		_ => False
	}
}

## A self-loop is a closed two-segment teardrop starting on the node
## boundary along the outward direction; a zero outward direction points up.
expect {
	routes = EdgeRoutes.route_edges(
		[{ from: 0, to: 0 }],
		[{ x: 50, y: 50 }],
		[{ x: 0, y: 0 }],
		[{ width: 10, height: 10 }],
		8,
	)
	match routes.get(0) {
		Ok(Curves([first, second])) =>
			first.from == second.to
				and first.from == { x: 50, y: 45 }
					and second.from == first.to

		_ => False
	}
}

## Normalize shifts positions and every curve control point together and
## reports the tight box over nodes and route extents.
expect {
	raw_positions = [{ x: 0 - 10.0, y: 5 }]
	sizes = [{ width: 4, height: 4 }]
	routes = [Curves([{ from: { x: 0 - 10.0, y: 5 }, ctl_a: { x: 0 - 20.0, y: 0 }, ctl_b: { x: 0 - 20.0, y: 10 }, to: { x: 0 - 10.0, y: 5 } }])]
	result = EdgeRoutes.normalize(raw_positions, sizes, routes)
	result.positions == [{ x: 10, y: 5 }]
		and result.bounds == { x: 0, y: 0, width: 12, height: 10 }
}
