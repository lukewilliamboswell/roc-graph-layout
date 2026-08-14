import EdgeRoutes
import Geom

## Internal implementation for the placement-independent orthogonal router.
RouteInternals :: {}.{
	finite_point : { x : F64, y : F64 } -> Bool
	finite_point = |p| F64.is_finite(p.x) and F64.is_finite(p.y)

	problems : Route.Input, Route.Settings -> List(Route.Problem)
	problems = |input, settings| {
		p0 = input.graph.nodes.fold_with_index(
			[],
			|acc, n, i| {
				a = if F64.is_finite(n.width) and n.width >= 0 {
					acc
				} else {
					acc.append(InvalidNodeWidth(i))
				}
				if F64.is_finite(n.height) and n.height >= 0 {
					a
				} else {
					a.append(InvalidNodeHeight(i))
				}
			},
		)
		p1 = input.positions.fold_with_index(
			p0,
			|acc, p, i| if RouteInternals.finite_point(p) {
				acc
			} else {
				acc.append(InvalidPosition(i))
			},
		)
		p2 = if input.positions.len() == input.graph.nodes.len() {
			p1
		} else {
			p1.append(PositionCountMismatch)
		}
		p3 = input.graph.edges.fold_with_index(
			p2,
			|acc, e, i| {
				a = if e.from < input.graph.nodes.len() {
					acc
				} else {
					acc.append(InvalidEdgeFrom(i))
				}
				if e.to < input.graph.nodes.len() {
					a
				} else {
					a.append(InvalidEdgeTo(i))
				}
			},
		)
		p4 = input.attachments.fold_with_index(
			p3,
			|acc, rule, i| {
				a = if rule.edge < input.graph.edges.len() {
					acc
				} else {
					acc.append(InvalidAttachmentEdge(i))
				}
				valid_fixed = match rule.attachment {
					Fixed(payload) => F64.is_finite(payload.offset) and payload.offset >= 0 and payload.offset <= 1
					_ => True
				}
				b = if valid_fixed {
					a
				} else {
					a.append(InvalidAttachmentOffset(i))
				}
				duplicate = input.attachments.fold_with_index(False, |found, other, j| found or (j < i and other.edge == rule.edge and other.endpoint == rule.endpoint))
				if duplicate {
					b.append(DuplicateAttachment(i))
				} else {
					b
				}
			},
		)
		p5 = input.groups.fold_with_index(
			p4,
			|acc, group, i| {
				r = group.rect
				a = if F64.is_finite(r.x) and F64.is_finite(r.y) and F64.is_finite(r.width) and F64.is_finite(r.height) and r.width >= 0 and r.height >= 0 {
					acc
				} else {
					acc.append(InvalidGroupRect(i))
				}
				match group.parent {
					Root => a
					Parent(parent) if parent < i => a
					Parent(_) => a.append(InvalidGroupParent(i))
				}
			},
		)
		p5b = input.memberships.fold_with_index(
			p5,
			|acc, membership, i| {
				a = if membership.node < input.graph.nodes.len() {
					acc
				} else {
					acc.append(InvalidMembershipNode(i))
				}
				b = if membership.group < input.groups.len() {
					a
				} else {
					a.append(InvalidMembershipGroup(i))
				}
				duplicate = input.memberships.fold_with_index(False, |found, other, j| found or (j < i and other.node == membership.node))
				if duplicate {
					b.append(DuplicateMembership(i))
				} else {
					b
				}
			},
		)
		p6 = input.edge_labels.fold_with_index(
			p5b,
			|acc, label, i| {
				a = if label.edge < input.graph.edges.len() {
					acc
				} else {
					acc.append(InvalidLabelEdge(i))
				}
				b = if F64.is_finite(label.width) and label.width >= 0 {
					a
				} else {
					a.append(InvalidLabelWidth(i))
				}
				c = if F64.is_finite(label.height) and label.height >= 0 {
					b
				} else {
					b.append(InvalidLabelHeight(i))
				}
				duplicate = input.edge_labels.fold_with_index(False, |found, other, j| found or (j < i and other.edge == label.edge))
				if duplicate {
					c.append(DuplicateEdgeLabel(i))
				} else {
					c
				}
			},
		)
		p7 = if F64.is_finite(settings.obstacle_gap) and settings.obstacle_gap >= 0 {
			p6
		} else {
			p6.append(InvalidObstacleGap)
		}
		p8 = if F64.is_finite(settings.bend_penalty) and settings.bend_penalty >= 0 {
			p7
		} else {
			p7.append(InvalidBendPenalty)
		}
		p9 = if F64.is_finite(settings.shared_path_penalty) and settings.shared_path_penalty >= 0 {
			p8
		} else {
			p8.append(InvalidSharedPathPenalty)
		}
		if F64.is_finite(settings.edge_gap) and settings.edge_gap >= 0 {
			p9
		} else {
			p9.append(InvalidEdgeGap)
		}
	}

	attachment_rule : U64, Route.Endpoint, List(Route.AttachmentRule) -> Route.Attachment
	attachment_rule = |edge, endpoint, rules| match rules.find_first(|rule| rule.edge == edge and rule.endpoint == endpoint) {
		Ok(rule) => rule.attachment
		Err(_) => Automatic
	}

	fixed_point = |center, size, side, offset| match side {
		Top => { point: { x: center.x - size.width / 2 + size.width * offset, y: center.y - size.height / 2 }, outward: { x: 0, y: 0 - 1.0 }, side }
		Right => { point: { x: center.x + size.width / 2, y: center.y - size.height / 2 + size.height * offset }, outward: { x: 1, y: 0 }, side }
		Bottom => { point: { x: center.x - size.width / 2 + size.width * offset, y: center.y + size.height / 2 }, outward: { x: 0, y: 1 }, side }
		Left => { point: { x: center.x - size.width / 2, y: center.y - size.height / 2 + size.height * offset }, outward: { x: 0 - 1.0, y: 0 }, side }
	}

	terminal : U64, Route.Endpoint, { from : U64, to : U64 }, Route.Input -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 }, side : Route.Side }
	terminal = |edge_index, endpoint, edge, input| {
		node = match endpoint {
			From => edge.from
			To => edge.to
		}
		center = input.positions.get(node) ?? { x: 0, y: 0 }
		size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
		rule = RouteInternals.attachment_rule(edge_index, endpoint, input.attachments)
		match rule {
			Fixed(payload) => RouteInternals.fixed_point(center, size, payload.side, payload.offset)
			On(side) => RouteInternals.fixed_point(center, size, side, 0.5)
			Automatic => {
				other_index = match endpoint {
					From => edge.to
					To => edge.from
				}
				other = input.positions.get(other_index) ?? center
				point = Geom.clip_to_node(center, size, other)
				dx = point.x - center.x
				dy = point.y - center.y
				outward = if dx.abs() >= dy.abs() {
					{
						x: if dx < 0 {
							0 - 1.0
						} else {
							1.0
						},
						y: 0,
					}
				} else {
					{
						x: 0,
						y: if dy < 0 {
							0 - 1.0
						} else {
							1.0
						},
					}
				}
				side = if outward.x < 0 {
					Left
				} else if outward.x > 0 {
					Right
				} else if outward.y < 0 {
					Top
				} else {
					Bottom
				}
				{ point, outward, side }
			}
		}
	}

	simplify : List({ x : F64, y : F64 }) -> List({ x : F64, y : F64 })
	simplify = |points| points.fold(
		[],
		|acc, p| if acc.is_empty() {
			[p]
		} else {
			last = acc.get(acc.len() - 1) ?? { x: F64.nan, y: F64.nan }
			if p == last {
				acc
			} else if acc.len() >= 2 {
				before = acc.get(acc.len() - 2) ?? last
				if (before.x == last.x and last.x == p.x) or (before.y == last.y and last.y == p.y) {
					(acc.drop_last(1)).append(p)
				} else {
					acc.append(p)
				}
			} else {
				acc.append(p)
			}
		},
	)

	segment_hits : { x : F64, y : F64 }, { x : F64, y : F64 }, { min_x : F64, min_y : F64, max_x : F64, max_y : F64 } -> Bool
	segment_hits = |a, b, box| if a.x == b.x {
		a.x > box.min_x and a.x < box.max_x and a.y.min(b.y) < box.max_y and a.y.max(b.y) > box.min_y
	} else if a.y == b.y {
		a.y > box.min_y and a.y < box.max_y and a.x.min(b.x) < box.max_x and a.x.max(b.x) > box.min_x
	} else {
		False
	}

	clear_path : List({ x : F64, y : F64 }), Route.Input, Route.Settings, U64, U64 -> Bool
	clear_path = |points, input, settings, from, to| points.fold_with_index(
		True,
		|ok, a, i| match points.get(i + 1) {
			Ok(b) => input.positions.fold_with_index(
				ok,
				|clear, p, node| if node == from or node == to {
					clear
				} else {
					n = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
					box = { min_x: p.x - n.width / 2 - settings.obstacle_gap, min_y: p.y - n.height / 2 - settings.obstacle_gap, max_x: p.x + n.width / 2 + settings.obstacle_gap, max_y: p.y + n.height / 2 + settings.obstacle_gap }
					clear and RouteInternals.segment_hits(a, b, box) == False
				},
			)
			Err(_) => ok
		},
	)

	group_in_chain = |group, target, groups, fuel| if fuel == 0 {
		False
	} else if group == target {
		True
	} else {
		match groups.get(group) {
			Ok(item) => match item.parent {
				Root => False
				Parent(parent) => RouteInternals.group_in_chain(parent, target, groups, fuel - 1)
			}
			Err(_) => False
		}
	}

	obstacles = |input, settings, from, to| {
		nodes = input.positions.fold_with_index(
			[],
			|acc, p, node| if node == from or node == to {
				acc
			} else {
				n = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
				acc.append({ min_x: p.x - n.width / 2 - settings.obstacle_gap, min_y: p.y - n.height / 2 - settings.obstacle_gap, max_x: p.x + n.width / 2 + settings.obstacle_gap, max_y: p.y + n.height / 2 + settings.obstacle_gap })
			},
		)
		from_group = input.memberships.find_first(|membership| membership.node == from)
		to_group = input.memberships.find_first(|membership| membership.node == to)
		groups = input.groups.fold_with_index(
			[],
			|acc, group, group_index| {
				owns_endpoint = match (from_group, to_group) {
					(Ok(a), Ok(b)) => RouteInternals.group_in_chain(a.group, group_index, input.groups, input.groups.len() + 1) or RouteInternals.group_in_chain(b.group, group_index, input.groups, input.groups.len() + 1)
					(Ok(a), Err(_)) => RouteInternals.group_in_chain(a.group, group_index, input.groups, input.groups.len() + 1)
					(Err(_), Ok(b)) => RouteInternals.group_in_chain(b.group, group_index, input.groups, input.groups.len() + 1)
					_ => False
				}
				if owns_endpoint {
					acc
				} else {
					acc.append({ min_x: group.rect.x - settings.obstacle_gap, min_y: group.rect.y - settings.obstacle_gap, max_x: group.rect.x + group.rect.width + settings.obstacle_gap, max_y: group.rect.y + group.rect.height + settings.obstacle_gap })
				}
			},
		)
		nodes.concat(groups)
	}

	point_blocked = |point, boxes| boxes.any(|box| point.x > box.min_x and point.x < box.max_x and point.y > box.min_y and point.y < box.max_y)

	visible = |a, b, boxes| (a.x == b.x or a.y == b.y) and boxes.all(|box| RouteInternals.segment_hits(a, b, box) == False)

	path_visible = |points, boxes| points.fold_with_index(
		True,
		|clear, a, i| match points.get(i + 1) {
			Ok(b) => clear and RouteInternals.visible(a, b, boxes)
			Err(_) => clear
		},
	)

	unique_values = |values| values.fold(
		[],
		|acc, value| if acc.contains(value) {
			acc
		} else {
			acc.append(value)
		},
	)

	shared_count = |a, b, prior| {
		zero : U64
		zero = 0
		prior.fold(
			zero,
			|count, route| {
				points = RouteInternals.route_points(route)
				points.fold_with_index(
					count,
					|n, c, i| match points.get(i + 1) {
						Ok(d) => if RouteInternals.segment_hits(a, b, { min_x: c.x.min(d.x) - 0.000001, min_y: c.y.min(d.y) - 0.000001, max_x: c.x.max(d.x) + 0.000001, max_y: c.y.max(d.y) + 0.000001 }) {
							n + 1
						} else {
							n
						}
						Err(_) => n
					},
				)
			},
		)
	}

	grid_walk = |points, boxes, finish_index, start, settings, prior, distances, previous, visited, fuel| if fuel == 0 {
		{ distances, previous }
	} else {
		chosen = distances.fold_with_index(
			{ index: 0, distance: F64.infinity },
			|best, distance, i| if (visited.get(i) ?? True) == False and distance < best.distance {
				{ index: i, distance }
			} else {
				best
			},
		)
		if F64.is_finite(chosen.distance) == False or chosen.index == finish_index {
			{ distances, previous }
		} else {
			from_point = points.get(chosen.index) ?? start
			relaxed = points.fold_with_index(
				{ distances, previous },
				|state, point, i| if i == chosen.index or (visited.get(i) ?? False) or RouteInternals.visible(from_point, point, boxes) == False {
					state
				} else {
					previous_point = points.get(previous.get(chosen.index) ?? chosen.index) ?? from_point
					turn = if chosen.index == (previous.get(chosen.index) ?? chosen.index) or (previous_point.x == from_point.x) == (from_point.x == point.x) {
						0
					} else {
						settings.bend_penalty
					}
					shared = RouteInternals.shared_count(from_point, point, prior).to_f64() * settings.shared_path_penalty
					candidate = chosen.distance + (point.x - from_point.x).abs() + (point.y - from_point.y).abs() + turn + shared
					if candidate < (state.distances.get(i) ?? F64.infinity) {
						{ distances: state.distances.set(i, candidate) ?? [], previous: state.previous.set(i, chosen.index) ?? [] }
					} else {
						state
					}
				},
			)
			RouteInternals.grid_walk(points, boxes, finish_index, start, settings, prior, relaxed.distances, relaxed.previous, visited.set(chosen.index, True) ?? [], fuel - 1)
		}
	}

	grid_rebuild = |points, previous, start_index, index, start, finish, acc, fuel| if fuel == 0 or index == start_index {
		[start].concat(acc)
	} else {
		point = points.get(index) ?? finish
		RouteInternals.grid_rebuild(points, previous, start_index, previous.get(index) ?? start_index, start, finish, [point].concat(acc), fuel - 1)
	}

	shortest_grid = |start, finish, boxes, settings, prior| {
		xs = RouteInternals.unique_values([start.x, finish.x].concat(boxes.fold([], |acc, box| acc.concat([box.min_x, box.max_x]))))
		ys = RouteInternals.unique_values([start.y, finish.y].concat(boxes.fold([], |acc, box| acc.concat([box.min_y, box.max_y]))))
		points = xs.map(|x| ys.map(|y| { x, y })).join().keep_if(|point| RouteInternals.point_blocked(point, boxes) == False)
		start_index = points.find_first_index(|point| point == start) ?? 0
		finish_index = points.find_first_index(|point| point == finish) ?? start_index
		count = points.len()
		initial_distances = List.repeat(F64.infinity, count).set(start_index, 0) ?? []
		searched = RouteInternals.grid_walk(points, boxes, finish_index, start, settings, prior, initial_distances, List.repeat(count, count), List.repeat(False, count), count)
		if F64.is_finite(searched.distances.get(finish_index) ?? F64.infinity) == False {
			[]
		} else {
			RouteInternals.grid_rebuild(points, searched.previous, start_index, finish_index, start, finish, [], count + 1)
		}
	}

	path_cost : List({ x : F64, y : F64 }), List(Geom.Route), Route.Settings -> F64
	path_cost = |points, prior, settings| points.fold_with_index(
		0,
		|cost, a, i| match points.get(i + 1) {
			Ok(b) => {
				length = (b.x - a.x).abs() + (b.y - a.y).abs()
				bend = if i == 0 {
					0
				} else {
					p = points.get(i - 1) ?? a
					if (p.x == a.x) == (a.x == b.x) {
						0
					} else {
						settings.bend_penalty
					}
				}
				shared : U64
				shared = prior.fold(
					0,
					|count, route| RouteInternals.route_points(route).fold_with_index(
						count,
						|n, c, j| match RouteInternals.route_points(route).get(j + 1) {
							Ok(d) => if RouteInternals.segment_hits(a, b, { min_x: c.x.min(d.x) - 0.000001, min_y: c.y.min(d.y) - 0.000001, max_x: c.x.max(d.x) + 0.000001, max_y: c.y.max(d.y) + 0.000001 }) {
								n + 1
							} else {
								n
							}
							Err(_) => n
						},
					),
				)
				cost + length + bend + shared.to_f64() * settings.shared_path_penalty
			}
			Err(_) => cost
		},
	)

	route_one : U64, { from : U64, to : U64 }, Route.Input, Route.Settings, { rank : U64, count : U64 }, List(Geom.Route) -> Geom.Route
	route_one = |index, edge, input, settings, fan, prior| {
		a = RouteInternals.terminal(index, From, edge, input)
		b = RouteInternals.terminal(index, To, edge, input)
		track = (fan.rank.to_f64() - (fan.count - 1).to_f64() / 2) * settings.edge_gap
		if edge.from == edge.to {
			# A rectangular exterior loop; bound ports still determine its first and last point.
			d = settings.obstacle_gap + settings.edge_gap * (fan.rank + 1).to_f64()
			ap = { x: a.point.x + a.outward.x * d, y: a.point.y + a.outward.y * d }
			bp = { x: b.point.x + b.outward.x * d, y: b.point.y + b.outward.y * d }
			node = input.graph.nodes.get(edge.from) ?? { width: 0, height: 0 }
			center = input.positions.get(edge.from) ?? a.point
			lane = center.y - node.height / 2 - d - settings.edge_gap
			# Going through one shared exterior lane keeps every segment
			# axis-aligned even when both unbound endpoints coincide.
			Polyline(RouteInternals.simplify([a.point, ap, { x: ap.x, y: lane }, { x: bp.x, y: lane }, bp, b.point]))
		} else {
			ap = { x: a.point.x + a.outward.x * settings.obstacle_gap, y: a.point.y + a.outward.y * settings.obstacle_gap }
			bp = { x: b.point.x + b.outward.x * settings.obstacle_gap, y: b.point.y + b.outward.y * settings.obstacle_gap }
			hv = [a.point, ap, { x: bp.x, y: ap.y + track }, bp, b.point]
			vh = [a.point, ap, { x: ap.x + track, y: bp.y }, bp, b.point]
			boxes = RouteInternals.obstacles(input, settings, edge.from, edge.to)
			hv_clear = RouteInternals.path_visible(hv, boxes)
			vh_clear = RouteInternals.path_visible(vh, boxes)
			chosen = if hv_clear and vh_clear {
				if RouteInternals.path_cost(hv, prior, settings) <= RouteInternals.path_cost(vh, prior, settings) {
					hv
				} else {
					vh
				}
			} else if hv_clear {
				hv
			} else if vh_clear {
				vh
			} else {
				searched = RouteInternals.shortest_grid(a.point, b.point, boxes, settings, prior)
				if searched.is_empty() {
					exterior_y = boxes.fold(ap.y.min(bp.y), |top, box| top.min(box.min_y)) - settings.edge_gap
					[a.point, ap, { x: ap.x, y: exterior_y }, { x: bp.x, y: exterior_y }, bp, b.point]
				} else {
					searched
				}
			}
			Polyline(RouteInternals.simplify(chosen))
		}
	}

	overlaps_box : { x : F64, y : F64 }, F64, F64, { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }, F64 -> Bool
	overlaps_box = |p, width, height, box, gap| p.x + width / 2 + gap > box.min_x and p.x - width / 2 - gap < box.max_x and p.y + height / 2 + gap > box.min_y and p.y - height / 2 - gap < box.max_y

	label_clear : { x : F64, y : F64 }, Route.EdgeLabel, Route.Input, Route.Settings, List({ point : { x : F64, y : F64 }, width : F64, height : F64 }), List(Geom.Route) -> Bool
	label_clear = |p, label, input, settings, placed, routes| {
		nodes_clear = input.positions.fold_with_index(
			True,
			|ok, center, i| {
				n = input.graph.nodes.get(i) ?? { width: 0, height: 0 }
				ok and RouteInternals.overlaps_box(p, label.width, label.height, { min_x: center.x - n.width / 2, min_y: center.y - n.height / 2, max_x: center.x + n.width / 2, max_y: center.y + n.height / 2 }, settings.obstacle_gap) == False
			},
		)
		labels_clear = placed.all(|old| RouteInternals.overlaps_box(p, label.width, label.height, { min_x: old.point.x - old.width / 2, min_y: old.point.y - old.height / 2, max_x: old.point.x + old.width / 2, max_y: old.point.y + old.height / 2 }, settings.obstacle_gap) == False)
		routes_clear = routes.fold_with_index(
			True,
			|ok, route, edge| if edge == label.edge {
				ok
			} else {
				points = RouteInternals.route_points(route)
				points.fold_with_index(
					ok,
					|clear, a, j| match points.get(j + 1) {
						Ok(b) => clear and RouteInternals.segment_hits(a, b, { min_x: p.x - label.width / 2 - settings.obstacle_gap, min_y: p.y - label.height / 2 - settings.obstacle_gap, max_x: p.x + label.width / 2 + settings.obstacle_gap, max_y: p.y + label.height / 2 + settings.obstacle_gap }) == False
						Err(_) => clear
					},
				)
			},
		)
		nodes_clear and labels_clear and routes_clear
	}

	route_points : Geom.Route -> List({ x : F64, y : F64 })
	route_points = |route|
		match route {
			Line(a, b) => [a, b]
			Polyline(ps) => ps
			Curves(ss) => ss.fold([], |acc, s| acc.concat([s.from, s.ctl_a, s.ctl_b, s.to]))
		}

	midpoint : Geom.Route -> { x : F64, y : F64 }
	midpoint = |route| {
		ps = RouteInternals.route_points(route)
		if ps.is_empty() {
			{ x: 0, y: 0 }
		} else {
			a = ps.get((ps.len() - 1) / 2) ?? { x: 0, y: 0 }
			b = ps.get(ps.len() / 2) ?? a
			{ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }
		}
	}

	segment_crossings = |a, b, rect| if a.x == b.x {
		[rect.y, rect.y + rect.height].keep_if(|y| y >= a.y.min(b.y) and y <= a.y.max(b.y) and a.x >= rect.x and a.x <= rect.x + rect.width).map(|y| { x: a.x, y })
	} else if a.y == b.y {
		[rect.x, rect.x + rect.width].keep_if(|x| x >= a.x.min(b.x) and x <= a.x.max(b.x) and a.y >= rect.y and a.y <= rect.y + rect.height).map(|x| { x, y: a.y })
	} else {
		[]
	}

	route_crossings = |route, groups| {
		points = RouteInternals.route_points(route)
		groups.fold_with_index(
			[],
			|acc, group, group_index| points.fold_with_index(
				acc,
				|found, a, i| match points.get(i + 1) {
					Ok(b) => found.concat(RouteInternals.segment_crossings(a, b, group.rect).map(|point| { group: group_index, point }))
					Err(_) => found
				},
			),
		)
	}

	compute : Route.Input, Route.Settings -> Route.Result
	compute = |input, settings| {
		ranks = EdgeRoutes.parallel_ranks(input.graph.edges)
		raw_routes = input.graph.edges.fold_with_index([], |routes, edge, i| routes.append(RouteInternals.route_one(i, edge, input, settings, ranks.get(i) ?? { rank: 0, count: 1 }, routes)))
		placed_labels = input.edge_labels.fold(
			[],
			|placed, label| {
				base = RouteInternals.midpoint(raw_routes.get(label.edge) ?? Polyline([]))
				step = label.height / 2 + settings.obstacle_gap + settings.edge_gap
				candidates = [base, { x: base.x, y: base.y - step }, { x: base.x, y: base.y + step }, { x: base.x - label.width / 2 - step, y: base.y }, { x: base.x + label.width / 2 + step, y: base.y }]
				point = candidates.find_first(|p| RouteInternals.label_clear(p, label, input, settings, placed, raw_routes)) ?? {
					top = input.positions.fold(base.y, |m, p| m.min(p.y)) - label.height / 2 - settings.obstacle_gap - settings.edge_gap * (placed.len() + 1).to_f64()
					{ x: base.x, y: top }
				}
				placed.append({ point, width: label.width, height: label.height })
			},
		)
		raw_labels = placed_labels.map(|entry| entry.point)
		first_box = match input.positions.get(0) {
			Ok(p) => {
				n = input.graph.nodes.get(0) ?? { width: 0, height: 0 }
				{ min_x: p.x - n.width / 2, min_y: p.y - n.height / 2, max_x: p.x + n.width / 2, max_y: p.y + n.height / 2 }
			}
			Err(_) => { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
		}
		node_box = input.positions.fold_with_index(
			first_box,
			|box, p, i| {
				n = input.graph.nodes.get(i) ?? { width: 0, height: 0 }
				{ min_x: box.min_x.min(p.x - n.width / 2), min_y: box.min_y.min(p.y - n.height / 2), max_x: box.max_x.max(p.x + n.width / 2), max_y: box.max_y.max(p.y + n.height / 2) }
			},
		)
		route_box = raw_routes.fold(node_box, |box, route| RouteInternals.route_points(route).fold(box, |b, p| { min_x: b.min_x.min(p.x), min_y: b.min_y.min(p.y), max_x: b.max_x.max(p.x), max_y: b.max_y.max(p.y) }))
		box = input.edge_labels.fold_with_index(
			route_box,
			|b, label, i| {
				p = raw_labels.get(i) ?? { x: 0, y: 0 }
				{ min_x: b.min_x.min(p.x - label.width / 2), min_y: b.min_y.min(p.y - label.height / 2), max_x: b.max_x.max(p.x + label.width / 2), max_y: b.max_y.max(p.y + label.height / 2) }
			},
		)
		dx = Geom.saturate(0 - box.min_x)
		dy = Geom.saturate(0 - box.min_y)
		shift = |p| { x: Geom.saturate(p.x + dx), y: Geom.saturate(p.y + dy) }
		shift_route = |route|
			match route {
				Line(a, b) => Line(shift(a), shift(b))
				Polyline(ps) => Polyline(ps.map(shift))
				Curves(ss) => Curves(ss.map(|s| { from: shift(s.from), ctl_a: shift(s.ctl_a), ctl_b: shift(s.ctl_b), to: shift(s.to) }))
			}
		attachments = input.graph.edges.map_with_index(
			|edge, i| {
				from = RouteInternals.terminal(i, From, edge, input)
				to = RouteInternals.terminal(i, To, edge, input)
				{ from: { point: shift(from.point), side: from.side }, to: { point: shift(to.point), side: to.side } }
			},
		)
		group_crossings = raw_routes.map(|route| RouteInternals.route_crossings(route, input.groups).map(|crossing| { group: crossing.group, point: shift(crossing.point) }))
		groups = input.groups.map(|group| { x: Geom.saturate(group.rect.x + dx), y: Geom.saturate(group.rect.y + dy), width: group.rect.width, height: group.rect.height })
		{ layout: { positions: input.positions.map(shift), routes: raw_routes.map(shift_route), bounds: { ..Geom.empty_bounds, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) } }, groups, label_anchors: raw_labels.map(shift), attachments, group_crossings }
	}
}

## Placement-independent routing for an already positioned, sized graph.
## `layout` produces deterministic axis-aligned polylines, honors sparse
## attachment rules, separates parallel edges into stable tracks, gives
## self-loops exterior rectangular paths, and returns one anchor per sparse
## edge label.
Route :: {}.{
	Side : [Top, Right, Bottom, Left]
	Endpoint : [From, To]
	Attachment : [Automatic, On(Side), Fixed({ side : Side, offset : F64 })]
	AttachmentRule : { edge : U64, endpoint : Endpoint, attachment : Attachment }
	Group : { rect : Geom.Rect, parent : [Root, Parent(U64)] }
	Membership : { node : U64, group : U64 }
	EdgeLabel : { edge : U64, width : F64, height : F64 }

	Input : { graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }, positions : List({ x : F64, y : F64 }), groups : List(Group), memberships : List(Membership), attachments : List(AttachmentRule), edge_labels : List(EdgeLabel) }

	## `obstacle_gap` is the empty space kept around node and group boxes. `edge_gap`
	## separates parallel edges. `bend_penalty` favors fewer turns over a
	## shorter path, while `shared_path_penalty` favors a distinct corridor over
	## one already used by earlier edges. All four values use layout units;
	## zero disables the corresponding spacing or preference.
	Settings : { obstacle_gap : F64, bend_penalty : F64, shared_path_penalty : F64, edge_gap : F64 }
	SelectedAttachment : { point : Geom.Point, side : Side }
	EdgeAttachments : { from : SelectedAttachment, to : SelectedAttachment }
	GroupCrossing : { group : U64, point : Geom.Point }
	Result : { layout : { positions : List(Geom.Point), routes : List(Geom.Route), bounds : Geom.Rect }, groups : List(Geom.Rect), label_anchors : List(Geom.Point), attachments : List(EdgeAttachments), group_crossings : List(List(GroupCrossing)) }
	Problem := [InvalidNodeWidth(U64), InvalidNodeHeight(U64), PositionCountMismatch, InvalidPosition(U64), InvalidEdgeFrom(U64), InvalidEdgeTo(U64), InvalidAttachmentEdge(U64), InvalidAttachmentOffset(U64), DuplicateAttachment(U64), InvalidGroupRect(U64), InvalidGroupParent(U64), InvalidMembershipNode(U64), InvalidMembershipGroup(U64), DuplicateMembership(U64), InvalidLabelEdge(U64), InvalidLabelWidth(U64), InvalidLabelHeight(U64), DuplicateEdgeLabel(U64), InvalidObstacleGap, InvalidBendPenalty, InvalidSharedPathPenalty, InvalidEdgeGap].{

		## Turn one typed problem into a short explanation for a person reading a
		## log or error message. Numbers identify positions in the corresponding
		## input list and start at zero.
		to_str : Problem -> Str
		to_str = |problem| match problem {
			InvalidNodeWidth(node) => "Node ${node.to_str()} has a width that is negative or not a finite number."
			InvalidNodeHeight(node) => "Node ${node.to_str()} has a height that is negative or not a finite number."
			PositionCountMismatch => "The positions list must contain exactly one position for every node."
			InvalidPosition(node) => "Node ${node.to_str()} has a position whose x or y value is not finite."
			InvalidEdgeFrom(edge) => "Edge ${edge.to_str()} refers to a source node that does not exist."
			InvalidEdgeTo(edge) => "Edge ${edge.to_str()} refers to a target node that does not exist."
			InvalidAttachmentEdge(rule) => "Attachment rule ${rule.to_str()} refers to an edge that does not exist."
			InvalidAttachmentOffset(rule) => "Attachment rule ${rule.to_str()} has an offset outside the range from 0 to 1."
			DuplicateAttachment(rule) => "Attachment rule ${rule.to_str()} repeats a rule for the same end of an edge."
			InvalidGroupRect(group) => "Group ${group.to_str()} has a negative size or a coordinate that is not finite."
			InvalidGroupParent(group) => "Group ${group.to_str()} must refer to an earlier group as its parent."
			InvalidMembershipNode(membership) => "Membership ${membership.to_str()} refers to a node that does not exist."
			InvalidMembershipGroup(membership) => "Membership ${membership.to_str()} refers to a group that does not exist."
			DuplicateMembership(membership) => "Membership ${membership.to_str()} assigns a node that was already assigned to a group."
			InvalidLabelEdge(label) => "Edge label ${label.to_str()} refers to an edge that does not exist."
			InvalidLabelWidth(label) => "Edge label ${label.to_str()} has a width that is negative or not finite."
			InvalidLabelHeight(label) => "Edge label ${label.to_str()} has a height that is negative or not finite."
			DuplicateEdgeLabel(label) => "Edge label ${label.to_str()} repeats a label for the same edge."
			InvalidObstacleGap => "The obstacle gap must be a finite number that is zero or greater."
			InvalidBendPenalty => "The bend penalty must be a finite number that is zero or greater."
			InvalidSharedPathPenalty => "The shared-path penalty must be a finite number that is zero or greater."
			InvalidEdgeGap => "The edge gap must be a finite number that is zero or greater."
		}
	}

	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, positions: [], groups: [], memberships: [], attachments: [], edge_labels: [] }

	## Readable default clearance and parallel-edge separation, with modest
	## preferences for fewer bends and less shared routing.
	default_settings : Settings
	default_settings = { obstacle_gap: 8, bend_penalty: 16, shared_path_penalty: 4, edge_gap: 6 }

	layout : Input, Settings -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings| {
		problems = RouteInternals.problems(input, settings)
		if problems.is_empty() {
			Ok(RouteInternals.compute(input, settings))
		} else {
			Err(problems)
		}
	}
}

expect {
	problem : Route.Problem
	problem = InvalidEdgeTo(3)
	problem.to_str() == "Edge 3 refers to a target node that does not exist."
}

expect Route.layout(Route.default_input, Route.default_settings) == Ok({ layout: { positions: [], routes: [], bounds: Geom.empty_bounds }, groups: [], label_anchors: [], attachments: [], group_crossings: [] })

expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }], attachments: [{ edge: 0, endpoint: From, attachment: Fixed({ side: Right, offset: 0.5 }) }], edge_labels: [{ edge: 0, width: 8, height: 4 }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => result.layout.routes.len() == 1 and result.label_anchors.len() == 1
		Err(_) => False
	}
}

expect {
	bad = { ..Route.default_input, graph: { nodes: [{ width: 0 - 1.0, height: F64.nan }], edges: [{ from: 0, to: 2 }] }, positions: [] }
	Route.layout(bad, { ..Route.default_settings, obstacle_gap: 0 - 1.0 }) == Err([InvalidNodeWidth(0), InvalidNodeHeight(0), PositionCountMismatch, InvalidEdgeTo(0), InvalidObstacleGap])
}

## A large bend penalty selects the equally clear candidate with fewer bends.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }] }
	match (Route.layout(input, { ..Route.default_settings, bend_penalty: 0 }), Route.layout(input, { ..Route.default_settings, bend_penalty: 1000 })) {
		(Ok(a), Ok(b)) => a.layout.routes.len() == b.layout.routes.len()
		_ => False
	}
}

## Two labels on crossing routes are placed in distinct clear boxes.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }], edges: [{ from: 0, to: 1 }, { from: 2, to: 3 }] }, positions: [{ x: 0, y: 0 }, { x: 60, y: 60 }, { x: 0, y: 60 }, { x: 60, y: 0 }], edge_labels: [{ edge: 0, width: 20, height: 10 }, { edge: 1, width: 20, height: 10 }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) =>
			match (result.label_anchors.get(0), result.label_anchors.get(1)) {
				(Ok(a), Ok(b)) => a != b
				_ => False
			}
		Err(_) => False
	}
}

## A valid corridor that needs more than one dogleg is found around an
## unrelated node, and every returned segment remains axis-aligned and clear.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 30, height: 30 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 2 }] }, positions: [{ x: 0, y: 0 }, { x: 50, y: 0 }, { x: 100, y: 0 }] }
	match Route.layout(input, Route.default_settings) {
		Err(_) => False
		Ok(result) => match (result.layout.routes.first(), result.layout.positions.get(1)) {
			(Ok(Polyline(points)), Ok(center)) => {
				box = { min_x: center.x - 15 - Route.default_settings.obstacle_gap, min_y: center.y - 15 - Route.default_settings.obstacle_gap, max_x: center.x + 15 + Route.default_settings.obstacle_gap, max_y: center.y + 15 + Route.default_settings.obstacle_gap }
				points.fold_with_index(
					True,
					|clear, a, i| match points.get(i + 1) {
						Ok(b) => clear and (a.x == b.x or a.y == b.y) and RouteInternals.segment_hits(a, b, box) == False
						Err(_) => clear
					},
				)
			}
			_ => False
		}
	}
}

## fuzz regression: repeated self-loops on zero-size nodes at coincident
## positions still consist entirely of horizontal and vertical segments.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }], edges: [{ from: 5, to: 5 }, { from: 0, to: 0 }, { from: 0, to: 0 }, { from: 0, to: 0 }] }, positions: [{ x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => result.layout.routes.all(
			|route| match route {
				Polyline(points) => points.fold_with_index(
					True,
					|ok, a, i| match points.get(i + 1) {
						Ok(b) => ok and (a.x == b.x or a.y == b.y)
						Err(_) => ok
					},
				)
				_ => False
			},
		)
		Err(_) => False
	}
}
