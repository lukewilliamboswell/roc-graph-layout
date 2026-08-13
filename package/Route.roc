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
		p4 = input.ports.fold_with_index(
			p3,
			|acc, port, i| {
				a = if port.node < input.graph.nodes.len() {
					acc
				} else {
					acc.append(InvalidPortNode(i))
				}
				if F64.is_finite(port.offset) and port.offset >= 0 and port.offset <= 1 {
					a
				} else {
					a.append(InvalidPortOffset(i))
				}
			},
		)
		p5 = input.port_bindings.fold_with_index(
			p4,
			|acc, binding, i| {
				a = if binding.edge < input.graph.edges.len() {
					acc
				} else {
					acc.append(InvalidBindingEdge(i))
				}
				b = if binding.port < input.ports.len() {
					a
				} else {
					a.append(InvalidBindingPort(i))
				}
				owner_ok = match (input.graph.edges.get(binding.edge), input.ports.get(binding.port)) {
					(Ok(edge), Ok(port)) =>
						match binding.endpoint {
							From => port.node == edge.from
							To => port.node == edge.to
						}
					_ => True
				}
				c = if owner_ok {
					b
				} else {
					b.append(BindingNodeMismatch(i))
				}
				duplicate = input.port_bindings.fold_with_index(False, |found, other, j| found or (j < i and other.edge == binding.edge and other.endpoint == binding.endpoint))
				if duplicate {
					c.append(DuplicateEndpointBinding(i))
				} else {
					c
				}
			},
		)
		p6 = input.labels.fold_with_index(
			p5,
			|acc, label, i| {
				box = match label {
					NodeLabel(value) => value.box
					PortLabel(value) => value.box
					EdgeLabel(value) => value.box
				}
				target = match label {
					NodeLabel(value) => if value.node < input.graph.nodes.len() {
						acc
					} else {
						acc.append(InvalidLabelNode(i))
					}
					PortLabel(value) => if value.port < input.ports.len() {
						acc
					} else {
						acc.append(InvalidLabelPort(i))
					}
					EdgeLabel(value) => if value.edge < input.graph.edges.len() {
						acc
					} else {
						acc.append(InvalidLabelEdge(i))
					}
				}
				b = if F64.is_finite(box.width) and box.width >= 0 {
					target
				} else {
					target.append(InvalidLabelWidth(i))
				}
				if F64.is_finite(box.height) and box.height >= 0 {
					b
				} else {
					b.append(InvalidLabelHeight(i))
				}
			},
		)
		p7 = if F64.is_finite(settings.clearance) and settings.clearance >= 0 {
			p6
		} else {
			p6.append(InvalidClearance)
		}
		p8 = if F64.is_finite(settings.bend_penalty) and settings.bend_penalty >= 0 {
			p7
		} else {
			p7.append(InvalidBendPenalty)
		}
		p9 = if F64.is_finite(settings.congestion_penalty) and settings.congestion_penalty >= 0 {
			p8
		} else {
			p8.append(InvalidCongestionPenalty)
		}
		if F64.is_finite(settings.track_gap) and settings.track_gap >= 0 {
			p9
		} else {
			p9.append(InvalidTrackGap)
		}
	}

	port_point : Route.Port, List({ width : F64, height : F64 }), List({ x : F64, y : F64 }) -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 } }
	port_point = |port, nodes, positions| {
		n = nodes.get(port.node) ?? { width: 0, height: 0 }
		p = positions.get(port.node) ?? { x: 0, y: 0 }
		match port.side {
			Top => { point: { x: p.x - n.width / 2 + n.width * port.offset, y: p.y - n.height / 2 }, outward: { x: 0, y: 0 - 1.0 } }
			Right => { point: { x: p.x + n.width / 2, y: p.y - n.height / 2 + n.height * port.offset }, outward: { x: 1, y: 0 } }
			Bottom => { point: { x: p.x - n.width / 2 + n.width * port.offset, y: p.y + n.height / 2 }, outward: { x: 0, y: 1 } }
			Left => { point: { x: p.x - n.width / 2, y: p.y - n.height / 2 + n.height * port.offset }, outward: { x: 0 - 1.0, y: 0 } }
		}
	}

	bound_port : U64, Route.Endpoint, List(Route.PortBinding), List(Route.Port) -> [Some(Route.Port), None]
	bound_port = |edge, endpoint, bindings, ports|
		match bindings.find_first(|b| b.edge == edge and b.endpoint == endpoint) {
			Ok(b) =>
				match ports.get(b.port) {
					Ok(p) => Some(p)
					Err(_) => None
				}
			Err(_) => None
		}

	terminal : U64, Route.Endpoint, { from : U64, to : U64 }, Route.Input -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 } }
	terminal = |edge_index, endpoint, edge, input| {
		node = match endpoint {
			From => edge.from
			To => edge.to
		}
		match RouteInternals.bound_port(edge_index, endpoint, input.port_bindings, input.ports) {
			Some(port) => RouteInternals.port_point(port, input.graph.nodes, input.positions)
			None => {
				center = input.positions.get(node) ?? { x: 0, y: 0 }
				other_index = match endpoint {
					From => edge.to
					To => edge.from
				}
				other = input.positions.get(other_index) ?? center
				size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
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
				{ point, outward }
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
					box = { min_x: p.x - n.width / 2 - settings.clearance, min_y: p.y - n.height / 2 - settings.clearance, max_x: p.x + n.width / 2 + settings.clearance, max_y: p.y + n.height / 2 + settings.clearance }
					clear and RouteInternals.segment_hits(a, b, box) == False
				},
			)
			Err(_) => ok
		},
	)

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
				cost + length + bend + shared.to_f64() * settings.congestion_penalty
			}
			Err(_) => cost
		},
	)

	route_one : U64, { from : U64, to : U64 }, Route.Input, Route.Settings, { rank : U64, count : U64 }, List(Geom.Route) -> Geom.Route
	route_one = |index, edge, input, settings, fan, prior| {
		a = RouteInternals.terminal(index, From, edge, input)
		b = RouteInternals.terminal(index, To, edge, input)
		track = (fan.rank.to_f64() - (fan.count - 1).to_f64() / 2) * settings.track_gap
		if edge.from == edge.to {
			# A rectangular exterior loop; bound ports still determine its first and last point.
			d = settings.clearance + settings.track_gap * (fan.rank + 1).to_f64()
			ap = { x: a.point.x + a.outward.x * d, y: a.point.y + a.outward.y * d }
			bp = { x: b.point.x + b.outward.x * d, y: b.point.y + b.outward.y * d }
			node = input.graph.nodes.get(edge.from) ?? { width: 0, height: 0 }
			center = input.positions.get(edge.from) ?? a.point
			lane = center.y - node.height / 2 - d - settings.track_gap
			# Going through one shared exterior lane keeps every segment
			# axis-aligned even when both unbound endpoints coincide.
			Polyline(RouteInternals.simplify([a.point, ap, { x: ap.x, y: lane }, { x: bp.x, y: lane }, bp, b.point]))
		} else {
			ap = { x: a.point.x + a.outward.x * settings.clearance, y: a.point.y + a.outward.y * settings.clearance }
			bp = { x: b.point.x + b.outward.x * settings.clearance, y: b.point.y + b.outward.y * settings.clearance }
			hv = [a.point, ap, { x: bp.x, y: ap.y + track }, bp, b.point]
			vh = [a.point, ap, { x: ap.x + track, y: bp.y }, bp, b.point]
			hv_clear = RouteInternals.clear_path(hv, input, settings, edge.from, edge.to)
			vh_clear = RouteInternals.clear_path(vh, input, settings, edge.from, edge.to)
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
				extent = input.positions.fold_with_index(
					ap.y.min(bp.y),
					|m, p, node| if node == edge.from or node == edge.to {
						m
					} else {
						n = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
						m.min(p.y - n.height / 2 - settings.clearance)
					},
				)
				lane = extent - settings.track_gap * (index + 1).to_f64() - settings.clearance
				[a.point, ap, { x: ap.x, y: lane }, { x: bp.x, y: lane }, bp, b.point]
			}
			Polyline(RouteInternals.simplify(chosen))
		}
	}

	overlaps_box : { x : F64, y : F64 }, F64, F64, { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }, F64 -> Bool
	overlaps_box = |p, width, height, box, gap| p.x + width / 2 + gap > box.min_x and p.x - width / 2 - gap < box.max_x and p.y + height / 2 + gap > box.min_y and p.y - height / 2 - gap < box.max_y

	label_clear : { x : F64, y : F64 }, Route.LabelBox, Route.Input, Route.Settings, List({ point : { x : F64, y : F64 }, box : Route.LabelBox }), List(Geom.Route) -> Bool
	label_clear = |p, label_box, input, settings, placed, routes| {
		nodes_clear = input.positions.fold_with_index(
			True,
			|ok, center, i| {
				n = input.graph.nodes.get(i) ?? { width: 0, height: 0 }
				ok and RouteInternals.overlaps_box(p, label_box.width, label_box.height, { min_x: center.x - n.width / 2, min_y: center.y - n.height / 2, max_x: center.x + n.width / 2, max_y: center.y + n.height / 2 }, settings.clearance) == False
			},
		)
		labels_clear = placed.all(|old| RouteInternals.overlaps_box(p, label_box.width, label_box.height, { min_x: old.point.x - old.box.width / 2, min_y: old.point.y - old.box.height / 2, max_x: old.point.x + old.box.width / 2, max_y: old.point.y + old.box.height / 2 }, settings.clearance) == False)
		routes_clear = routes.fold_with_index(
			True,
			|ok, route, _edge| {
				points = RouteInternals.route_points(route)
				points.fold_with_index(
					ok,
					|clear, a, j| match points.get(j + 1) {
						Ok(b) => clear and RouteInternals.segment_hits(a, b, { min_x: p.x - label_box.width / 2 - settings.clearance, min_y: p.y - label_box.height / 2 - settings.clearance, max_x: p.x + label_box.width / 2 + settings.clearance, max_y: p.y + label_box.height / 2 + settings.clearance }) == False
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

	label_box : Route.Label -> Route.LabelBox
	label_box = |label| match label {
		NodeLabel(value) => value.box
		PortLabel(value) => value.box
		EdgeLabel(value) => value.box
	}

	node_label_point : { x : F64, y : F64 }, { width : F64, height : F64 }, Route.LabelBox, Route.Side, F64 -> { x : F64, y : F64 }
	node_label_point = |center, node, box, side, gap| match side {
		Top => { x: center.x, y: center.y - node.height / 2 - gap - box.height / 2 }
		Right => { x: center.x + node.width / 2 + gap + box.width / 2, y: center.y }
		Bottom => { x: center.x, y: center.y + node.height / 2 + gap + box.height / 2 }
		Left => { x: center.x - node.width / 2 - gap - box.width / 2, y: center.y }
	}

	edge_label_points : Route.EdgeLabelAt, Route.LabelSide, Route.LabelBox, Geom.Route, { from : U64, to : U64 }, Route.Input, Route.Settings -> List({ x : F64, y : F64 })
	edge_label_points = |at, side, box, route, edge, input, settings| {
		from = input.positions.get(edge.from) ?? { x: 0, y: 0 }
		to = input.positions.get(edge.to) ?? from
		base = match at {
			Middle => RouteInternals.midpoint(route)
			NearSource => {
				points = RouteInternals.route_points(route)
				points.get(1) ?? RouteInternals.midpoint(route)
			}
			NearTarget => {
				points = RouteInternals.route_points(route)
				index = if points.len() >= 2 {
					points.len() - 2
				} else {
					0
				}
				points.get(index) ?? RouteInternals.midpoint(route)
			}
		}
		dx = to.x - from.x
		dy = to.y - from.y
		d = Geom.hypot(dx, dy)
		normal = if d == 0 {
			{ x: 0, y: 0 - 1.0 }
		} else {
			{ x: dy / d, y: (0 - dx) / d }
		}
		offset = Geom.hypot(box.width, box.height) / 2 + settings.clearance
		left = { x: base.x + normal.x * offset, y: base.y + normal.y * offset }
		right = { x: base.x - normal.x * offset, y: base.y - normal.y * offset }
		match side {
			Either => [left, right]
			LeftOfRoute => [left]
			RightOfRoute => [right]
		}
	}

	finish : Route.Input, Route.Settings, List(Geom.Route) -> Route.Result
	finish = |input, settings, raw_routes| {
		placed_labels = input.labels.fold(
			[],
			|placed, label| {
				box = RouteInternals.label_box(label)
				candidates = match label {
					NodeLabel(value) => {
						center = input.positions.get(value.node) ?? { x: 0, y: 0 }
						node = input.graph.nodes.get(value.node) ?? { width: 0, height: 0 }
						[RouteInternals.node_label_point(center, node, box, value.side, settings.clearance)]
					}
					PortLabel(value) => {
						port = input.ports.get(value.port) ?? { node: 0, side: Top, offset: 0 }
						attachment = RouteInternals.port_point(port, input.graph.nodes, input.positions)
						distance = settings.clearance + Geom.hypot(box.width * attachment.outward.x, box.height * attachment.outward.y) / 2
						[{ x: attachment.point.x + attachment.outward.x * distance, y: attachment.point.y + attachment.outward.y * distance }]
					}
					EdgeLabel(value) => {
						edge = input.graph.edges.get(value.edge) ?? { from: 0, to: 0 }
						route = raw_routes.get(value.edge) ?? Polyline([])
						RouteInternals.edge_label_points(value.at, value.side, box, route, edge, input, settings)
					}
				}
				base = candidates.first() ?? { x: 0, y: 0 }
				point = candidates.find_first(|p| RouteInternals.label_clear(p, box, input, settings, placed, raw_routes)) ?? {
					node_top = input.positions.fold(base.y, |m, p| m.min(p.y))
					route_top = raw_routes.fold(node_top, |m, route| RouteInternals.route_points(route).fold(m, |lowest, p| lowest.min(p.y)))
					label_top = placed.fold(route_top, |m, old| m.min(old.point.y - old.box.height / 2))
					{ x: base.x, y: label_top - settings.clearance - box.height / 2 }
				}
				placed.append({ point, box })
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
		box = input.labels.fold_with_index(
			route_box,
			|b, label, i| {
				p = raw_labels.get(i) ?? { x: 0, y: 0 }
				label_size = RouteInternals.label_box(label)
				{ min_x: b.min_x.min(p.x - label_size.width / 2), min_y: b.min_y.min(p.y - label_size.height / 2), max_x: b.max_x.max(p.x + label_size.width / 2), max_y: b.max_y.max(p.y + label_size.height / 2) }
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
		label_boxes = raw_labels.map_with_index(
			|p, i| {
				size = RouteInternals.label_box(input.labels.get(i) ?? NodeLabel({ node: 0, box: { width: 0, height: 0 }, side: Top }))
				center = shift(p)
				{ x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height }
			},
		)
		{ layout: { positions: input.positions.map(shift), routes: raw_routes.map(shift_route), bounds: { ..Geom.empty_bounds, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) } }, label_boxes }
	}

	compute : Route.Input, Route.Settings -> Route.Result
	compute = |input, settings| {
		ranks = EdgeRoutes.parallel_ranks(input.graph.edges)
		routes = input.graph.edges.fold_with_index([], |prior, edge, i| prior.append(RouteInternals.route_one(i, edge, input, settings, ranks.get(i) ?? { rank: 0, count: 1 }, prior)))
		RouteInternals.finish(input, settings, routes)
	}

	routes_finite : List(Geom.Route) -> Bool
	routes_finite = |routes| routes.all(|route| RouteInternals.route_points(route).all(RouteInternals.finite_point))
}

## Input and settings checked once, with all reusable routing data retained.
RoutePrepared := { input : Route.Input, settings : Route.Settings }.{
	build : Route.Input, Route.Settings -> [Ok(RoutePrepared), Err(List(Route.Problem))]
	build = |input, settings| {
		problems = RouteInternals.problems(input, settings)
		if problems.is_empty() {
			prepared : RoutePrepared
			prepared = { input, settings }
			Ok(prepared)
		} else {
			Err(problems)
		}
	}

	run : RoutePrepared -> Route.Result
	run = |prepared| RouteInternals.compute(prepared.input, prepared.settings)
}

## Placement-independent routing for an already positioned, sized graph.
## `orthogonal` produces deterministic axis-aligned polylines, honors optional
## boundary ports, separates parallel edges into stable tracks, gives self-loops
## exterior rectangular paths, and places measured label boxes as part of the
## same collision-aware routing pass.
Route :: {}.{
	Side : [Top, Right, Bottom, Left]
	Endpoint : [From, To]
	Port : { node : U64, side : Side, offset : F64 }
	PortBinding : { edge : U64, endpoint : Endpoint, port : U64 }
	LabelBox : { width : F64, height : F64 }

	LabelSide : [Either, LeftOfRoute, RightOfRoute]
	EdgeLabelAt : [Middle, NearSource, NearTarget]
	Label : [
		NodeLabel({ node : U64, box : LabelBox, side : Side }),
		PortLabel({ port : U64, box : LabelBox }),
		EdgeLabel({ edge : U64, box : LabelBox, at : EdgeLabelAt, side : LabelSide }),
	]

	Input : { graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }, positions : List({ x : F64, y : F64 }), ports : List(Port), port_bindings : List(PortBinding), labels : List(Label) }

	## `clearance` is the empty space kept around node boxes. `track_gap`
	## separates parallel edges. `bend_penalty` favors fewer turns over a
	## shorter path, while `congestion_penalty` favors a distinct corridor over
	## one already used by earlier edges. All four values use layout units;
	## zero disables the corresponding spacing or preference.
	Settings : { clearance : F64, bend_penalty : F64, congestion_penalty : F64, track_gap : F64 }
	Result : { layout : { positions : List({ x : F64, y : F64 }), routes : List(Geom.Route), bounds : { x : F64, y : F64, width : F64, height : F64 } }, label_boxes : List(Geom.Rect) }
	Problem : [InvalidNodeWidth(U64), InvalidNodeHeight(U64), PositionCountMismatch, InvalidPosition(U64), InvalidEdgeFrom(U64), InvalidEdgeTo(U64), InvalidPortNode(U64), InvalidPortOffset(U64), InvalidBindingEdge(U64), InvalidBindingPort(U64), BindingNodeMismatch(U64), DuplicateEndpointBinding(U64), InvalidLabelNode(U64), InvalidLabelPort(U64), InvalidLabelEdge(U64), InvalidLabelWidth(U64), InvalidLabelHeight(U64), RouteCountMismatch, InvalidRoute, InvalidClearance, InvalidBendPenalty, InvalidCongestionPenalty, InvalidTrackGap]

	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, positions: [], ports: [], port_bindings: [], labels: [] }

	## Readable default clearance and parallel-edge separation, with modest
	## preferences for fewer bends and less shared routing.
	default_settings : Settings
	default_settings = { clearance: 8, bend_penalty: 16, congestion_penalty: 4, track_gap: 6 }

	prepare : Input, Settings -> [Ok(RoutePrepared), Err(List(Problem))]
	prepare = |input, settings| RoutePrepared.build(input, settings)
	orthogonal_prepared : RoutePrepared -> Result
	orthogonal_prepared = |prepared| prepared.run()
	orthogonal : Input, Settings -> [Ok(Result), Err(List(Problem))]
	orthogonal = |input, settings|
		match RoutePrepared.build(input, settings) {
			Ok(prepared) => Ok(prepared.run())
			Err(problems) => Err(problems)
		}

	## Place labels against caller-provided final routes. This is useful when a
	## family adds structural waypoints after its routing phase. The returned
	## layout is normalized exactly like `orthogonal`, so routes and label boxes
	## always share one coordinate system.
	place_labels : Input, Settings, List(Geom.Route) -> [Ok(Result), Err(List(Problem))]
	place_labels = |input, settings, routes| {
		base = RouteInternals.problems(input, settings)
		problems = if routes.len() != input.graph.edges.len() {
			base.append(RouteCountMismatch)
		} else if !RouteInternals.routes_finite(routes) {
			base.append(InvalidRoute)
		} else {
			base
		}
		if problems.is_empty() {
			Ok(RouteInternals.finish(input, settings, routes))
		} else {
			Err(problems)
		}
	}
}

expect Route.orthogonal(Route.default_input, Route.default_settings) == Ok({ layout: { positions: [], routes: [], bounds: Geom.empty_bounds }, label_boxes: [] })

expect {
	input = { graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }], ports: [{ node: 0, side: Right, offset: 0.5 }], port_bindings: [{ edge: 0, endpoint: From, port: 0 }], labels: [EdgeLabel({ edge: 0, box: { width: 8, height: 4 }, at: Middle, side: Either })] }
	match Route.orthogonal(input, Route.default_settings) {
		Ok(result) => result.layout.routes.len() == 1 and result.label_boxes.len() == 1
		Err(_) => False
	}
}

expect {
	bad = { ..Route.default_input, graph: { nodes: [{ width: 0 - 1.0, height: F64.nan }], edges: [{ from: 0, to: 2 }] }, positions: [] }
	Route.prepare(bad, { ..Route.default_settings, clearance: 0 - 1.0 }) == Err([InvalidNodeWidth(0), InvalidNodeHeight(0), PositionCountMismatch, InvalidEdgeTo(0), InvalidClearance])
}

## A large bend penalty selects the equally clear candidate with fewer bends.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }] }
	match (Route.orthogonal(input, { ..Route.default_settings, bend_penalty: 0 }), Route.orthogonal(input, { ..Route.default_settings, bend_penalty: 1000 })) {
		(Ok(a), Ok(b)) => a.layout.routes.len() == b.layout.routes.len()
		_ => False
	}
}

## Two labels on crossing routes are placed in distinct clear boxes.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }], edges: [{ from: 0, to: 1 }, { from: 2, to: 3 }] }, positions: [{ x: 0, y: 0 }, { x: 60, y: 60 }, { x: 0, y: 60 }, { x: 60, y: 0 }], labels: [EdgeLabel({ edge: 0, box: { width: 20, height: 10 }, at: Middle, side: Either }), EdgeLabel({ edge: 1, box: { width: 20, height: 10 }, at: Middle, side: Either })] }
	match Route.orthogonal(input, Route.default_settings) {
		Ok(result) =>
			match (result.label_boxes.get(0), result.label_boxes.get(1)) {
				(Ok(a), Ok(b)) => a != b
				_ => False
			}
		Err(_) => False
	}
}

## Node, port, source, middle, and target labels all retain label input order;
## repeated labels on one edge are valid and receive distinct boxes.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 20, height: 20 }, { width: 20, height: 20 }], edges: [{ from: 0, to: 1 }] },
		positions: [{ x: 0, y: 0 }, { x: 100, y: 0 }],
		ports: [{ node: 0, side: Right, offset: 0.5 }],
		labels: [
			NodeLabel({ node: 0, box: { width: 24, height: 8 }, side: Top }),
			PortLabel({ port: 0, box: { width: 16, height: 8 } }),
			EdgeLabel({ edge: 0, box: { width: 20, height: 8 }, at: NearSource, side: LeftOfRoute }),
			EdgeLabel({ edge: 0, box: { width: 20, height: 8 }, at: Middle, side: RightOfRoute }),
			EdgeLabel({ edge: 0, box: { width: 20, height: 8 }, at: NearTarget, side: Either }),
		],
	}
	match Route.orthogonal(input, Route.default_settings) {
		Ok(result) => result.label_boxes.len() == 5 and result.label_boxes.all(|box| F64.is_finite(box.x) and F64.is_finite(box.y)) and result.label_boxes.fold_with_index(True, |distinct, box, i| distinct and result.label_boxes.take_first(i).all(|before| before.x != box.x or before.y != box.y))
		Err(_) => False
	}
}

## Validation aggregates independent owner and box problems by label index.
expect {
	bad = { ..Route.default_input, labels: [NodeLabel({ node: 2, box: { width: 0 - 1.0, height: F64.nan }, side: Top }), PortLabel({ port: 3, box: { width: 1, height: 1 } })] }
	Route.prepare(bad, Route.default_settings) == Err([InvalidLabelNode(0), InvalidLabelWidth(0), InvalidLabelHeight(0), InvalidLabelPort(1)])
}

## fuzz regression: repeated self-loops on zero-size nodes at coincident
## positions still consist entirely of horizontal and vertical segments.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }, { width: 7, height: 7 }], edges: [{ from: 5, to: 5 }, { from: 0, to: 0 }, { from: 0, to: 0 }, { from: 0, to: 0 }] }, positions: [{ x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }, { x: 53, y: 53 }] }
	match Route.orthogonal(input, Route.default_settings) {
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
