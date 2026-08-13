import Geom
import Route

## Internal portal-leg routing and normalization for Compound.
CompoundRouting :: {}.{
	stitch_route : Geom.Route, List({ x : F64, y : F64, width : F64, height : F64 }), List({ width : F64, height : F64 }), List({ x : F64, y : F64 }), { from : U64, to : U64 } -> Geom.Route
	stitch_route = |route, groups, nodes, positions, edge| {
		points = match route {
			Line(a, b) => [a, b]
			Polyline(ps) => ps
			Curves(segments) => segments.fold([], |acc, segment| acc.concat([segment.from, segment.to]))
		}
		match (points.first(), points.last()) {
			(Ok(from), Ok(to)) => {
				portals = groups.keep_oks(
					|rect| {
						from_inside = CompoundRouting.inside_rect(from, rect)
						to_inside = CompoundRouting.inside_rect(to, rect)
						if from_inside == to_inside {
							Err({})
						} else {
							Ok(
								CompoundRouting.boundary_portal(
									if from_inside {
										from
									} else {
										to
									},
									if from_inside {
										to
									} else {
										from
									},
									rect,
								),
							)
						}
					},
				).sort_with(
					|a, b| {
						ad = CompoundRouting.distance_sq(from, a)
						bd = CompoundRouting.distance_sq(from, b)
						if ad < bd {
							LT
						} else if ad > bd {
							GT
						} else {
							EQ
						}
					},
				)
				if portals.is_empty() {
					route
				} else {
					waypoints = [from].concat(portals).append(to)
					obstacles = groups.map(|rect| { min_x: rect.x, min_y: rect.y, max_x: rect.x + rect.width, max_y: rect.y + rect.height }).concat(
						positions.map_with_index(
							|position, node| {
								size = nodes.get(node) ?? { width: 0, height: 0 }
								{ min_x: position.x - size.width / 2, min_y: position.y - size.height / 2, max_x: position.x + size.width / 2, max_y: position.y + size.height / 2 }
							},
						),
					)
					orthogonal = waypoints.fold_with_index(
						[],
						|acc, point, i| match waypoints.get(i + 1) {
							Ok(next) => acc.concat(CompoundRouting.route_leg(point, next, obstacles, edge.from, edge.to, groups.len()))
							Err(_) => acc.append(point)
						},
					)
					Polyline(CompoundRouting.simplify_points(orthogonal))
				}
			}
			_ => route
		}
	}

	inside_rect = |point, rect| point.x >= rect.x and point.x <= rect.x + rect.width and point.y >= rect.y and point.y <= rect.y + rect.height

	distance_sq = |a, b| (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)

	boundary_portal = |inside, outside, rect| {
		dx = outside.x - inside.x
		dy = outside.y - inside.y
		tx = if dx > 0 {
			(rect.x + rect.width - inside.x) / dx
		} else if dx < 0 {
			(rect.x - inside.x) / dx
		} else {
			1000000000
		}
		ty = if dy > 0 {
			(rect.y + rect.height - inside.y) / dy
		} else if dy < 0 {
			(rect.y - inside.y) / dy
		} else {
			1000000000
		}
		t = tx.min(ty).max(0)
		{ x: Geom.saturate(inside.x + dx * t), y: Geom.saturate(inside.y + dy * t) }
	}

	route_leg : { x : F64, y : F64 }, { x : F64, y : F64 }, List({ min_x : F64, min_y : F64, max_x : F64, max_y : F64 }), U64, U64, U64 -> List({ x : F64, y : F64 })
	route_leg = |from, to, obstacles, from_node, to_node, group_count| {
		clear = |points| points.fold_with_index(
			True,
			|ok, a, i| match points.get(i + 1) {
				Ok(b) => obstacles.fold_with_index(
					ok,
					|free, box, obstacle_index| {
						is_endpoint_node = obstacle_index == group_count + from_node or obstacle_index == group_count + to_node
						endpoint_touches = CompoundRouting.inside_box_or_boundary(from, box) or CompoundRouting.inside_box_or_boundary(to, box)
						free and (is_endpoint_node or endpoint_touches or !CompoundRouting.segment_hits_box(a, b, box))
					},
				)
				Err(_) => ok
			},
		)
		hv = [from, { x: to.x, y: from.y }, to]
		vh = [from, { x: from.x, y: to.y }, to]
		if clear(hv) {
			hv.drop_last(1)
		} else if clear(vh) {
			vh.drop_last(1)
		} else {
			margin = Route.default_settings.clearance
			top = obstacles.fold(from.y.min(to.y), |value, box| value.min(box.min_y - margin))
			bottom = obstacles.fold(from.y.max(to.y), |value, box| value.max(box.max_y + margin))
			left = obstacles.fold(from.x.min(to.x), |value, box| value.min(box.min_x - margin))
			right = obstacles.fold(from.x.max(to.x), |value, box| value.max(box.max_x + margin))
			candidates = [
				[from, { x: from.x, y: top }, { x: to.x, y: top }, to],
				[from, { x: from.x, y: bottom }, { x: to.x, y: bottom }, to],
				[from, { x: left, y: from.y }, { x: left, y: to.y }, to],
				[from, { x: right, y: from.y }, { x: right, y: to.y }, to],
			]
			chosen = candidates.keep_if(clear).sort_with(
				|a, b| {
					a_length = CompoundRouting.path_length(a)
					b_length = CompoundRouting.path_length(b)
					if a_length < b_length {
						LT
					} else if a_length > b_length {
						GT
					} else {
						EQ
					}
				},
			).first() ?? hv
			chosen.drop_last(1)
		}
	}

	path_length = |points| points.fold_with_index(
		0,
		|length, point, i| match points.get(i + 1) {
			Ok(next) => length + (next.x - point.x).abs() + (next.y - point.y).abs()
			Err(_) => length
		},
	)

	inside_box_or_boundary = |point, box| point.x >= box.min_x and point.x <= box.max_x and point.y >= box.min_y and point.y <= box.max_y

	segment_hits_box = |a, b, box| if a.x == b.x {
		a.x > box.min_x and a.x < box.max_x and a.y.min(b.y) < box.max_y and a.y.max(b.y) > box.min_y
	} else if a.y == b.y {
		a.y > box.min_y and a.y < box.max_y and a.x.min(b.x) < box.max_x and a.x.max(b.x) > box.min_x
	} else {
		True
	}

	simplify_points = |points| points.fold(
		[],
		|acc, point| if acc.is_empty() {
			[point]
		} else {
			last = acc.last() ?? point
			if point == last {
				acc
			} else if acc.len() >= 2 {
				before = acc.get(acc.len() - 2) ?? last
				if (before.x == last.x and last.x == point.x) or (before.y == last.y and last.y == point.y) {
					acc.drop_last(1).append(point)
				} else {
					acc.append(point)
				}
			} else {
				acc.append(point)
			}
		},
	)

	move_route : Geom.Route, { x : F64, y : F64 } -> Geom.Route
	move_route = |route, delta| {
		move = |point| { x: Geom.saturate(point.x + delta.x), y: Geom.saturate(point.y + delta.y) }
		match route {
			Line(from, to) => Line(move(from), move(to))
			Polyline(points) => Polyline(points.map(move))
			Curves(segments) => Curves(segments.map(|segment| { from: move(segment.from), ctl_a: move(segment.ctl_a), ctl_b: move(segment.ctl_b), to: move(segment.to) }))
		}
	}

	route_points : Geom.Route -> List({ x : F64, y : F64 })
	route_points = |route| match route {
		Line(from, to) => [from, to]
		Polyline(points) => points
		Curves(segments) => segments.fold([], |points, segment| points.concat([segment.from, segment.ctl_a, segment.ctl_b, segment.to]))
	}

	route_midpoint = |route| {
		points = CompoundRouting.route_points(route)
		first = points.get((points.len() - 1) / 2) ?? { x: 0, y: 0 }
		second = points.get(points.len() / 2) ?? first
		{ x: (first.x + second.x) / 2, y: (first.y + second.y) / 2 }
	}

	drawing_extent = |root, shift, padding, nodes, positions, routes, labels, anchors| {
		start = { min_x: root.x + shift.x, min_y: root.y + shift.y, max_x: root.x + shift.x + root.width, max_y: root.y + shift.y + root.height }
		with_nodes = positions.fold_with_index(
			start,
			|box, point, node| {
				size = nodes.get(node) ?? { width: 0, height: 0 }
				{ min_x: box.min_x.min(point.x - size.width / 2), min_y: box.min_y.min(point.y - size.height / 2), max_x: box.max_x.max(point.x + size.width / 2), max_y: box.max_y.max(point.y + size.height / 2) }
			},
		)
		with_routes = routes.fold(with_nodes, |bounds, route| CompoundRouting.route_points(route).fold(bounds, |current, point| { min_x: current.min_x.min(point.x - padding), min_y: current.min_y.min(point.y - padding), max_x: current.max_x.max(point.x + padding), max_y: current.max_y.max(point.y + padding) }))
		box = labels.fold_with_index(
			with_routes,
			|bounds, label, index| {
				anchor = anchors.get(index) ?? { x: 0, y: 0 }
				{ min_x: bounds.min_x.min(anchor.x - label.width / 2 - padding), min_y: bounds.min_y.min(anchor.y - label.height / 2 - padding), max_x: bounds.max_x.max(anchor.x + label.width / 2 + padding), max_y: bounds.max_y.max(anchor.y + label.height / 2 + padding) }
			},
		)
		{ x: box.min_x, y: box.min_y, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) }
	}
}
