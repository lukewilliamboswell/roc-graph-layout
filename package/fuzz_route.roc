app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Route

byte_at = |bytes, i| bytes.get(i) ?? 0

orthogonal = |route| match route {
	Line(a, b) => a.x == b.x or a.y == b.y
	Polyline(points) => points.fold_with_index(
		True,
		|ok, a, i| match points.get(i + 1) {
			Ok(b) => ok and (a.x == b.x or a.y == b.y)
			Err(_) => ok
		},
	)
	Curves(_) => False
}

finite_route = |route| match route {
	Line(a, b) => F64.is_finite(a.x) and F64.is_finite(a.y) and F64.is_finite(b.x) and F64.is_finite(b.y)
	Polyline(points) => points.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
	Curves(_) => False
}

finite_point = |point| F64.is_finite(point.x) and F64.is_finite(point.y)

route_points = |route| match route {
	Line(a, b) => [a, b]
	Polyline(points) => points
	Curves(_) => []
}

segment_hits = |a, b, box| if a.x == b.x {
	a.x > box.min_x and a.x < box.max_x and a.y.min(b.y) < box.max_y and a.y.max(b.y) > box.min_y
} else if a.y == b.y {
	a.y > box.min_y and a.y < box.max_y and a.x.min(b.x) < box.max_x and a.x.max(b.x) > box.min_x
} else {
	True
}

route_avoids_nodes = |edge, route, input, gap| {
	points = route_points(route)
	input.positions.fold_with_index(
		True,
		|clear, center, node| if node == edge.from or node == edge.to {
			clear
		} else {
			size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
			box = { min_x: center.x - size.width / 2 - gap, min_y: center.y - size.height / 2 - gap, max_x: center.x + size.width / 2 + gap, max_y: center.y + size.height / 2 + gap }
			from = input.positions.get(edge.from) ?? center
			to = input.positions.get(edge.to) ?? center
			impossible = (from.x > box.min_x and from.x < box.max_x and from.y > box.min_y and from.y < box.max_y) or (to.x > box.min_x and to.x < box.max_x and to.y > box.min_y and to.y < box.max_y)
			clear and (impossible or points.fold_with_index(True, |free, a, i| match points.get(i + 1) {
				Ok(b) => free and !segment_hits(a, b, box)
				Err(_) => free
			}))
		},
	)
}

side_at = |byte| match byte % 4 {
	0 => Top
	1 => Right
	2 => Bottom
	_ => Left
}

ellipse_attachment = |edge_index, endpoint, edge, input, result| {
	node = match endpoint {
		From => edge.from
		To => edge.to
	}
	is_ellipse = input.boundaries.any(|rule| rule.node == node and rule.outline == Ellipse)
	size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
	center = result.layout.positions.get(node) ?? { x: 0, y: 0 }
	ends = result.attachments.get(edge_index) ?? { from: { point: center, side: Top }, to: { point: center, side: Top } }
	selected = match endpoint {
		From => ends.from
		To => ends.to
	}
	other_node = match endpoint {
		From => edge.to
		To => edge.from
	}
	other = result.layout.positions.get(other_node) ?? center
	has_rule = input.attachments.any(|rule| rule.edge == edge_index and rule.endpoint == endpoint)
	should_touch = is_ellipse and size.width > 0 and size.height > 0 and (has_rule or other != center)
	if should_touch {
		dx = selected.point.x - center.x
		dy = selected.point.y - center.y
		value = (dx * dx) / ((size.width / 2) * (size.width / 2)) + (dy * dy) / ((size.height / 2) * (size.height / 2))
		F64.is_finite(value) and value > 0.99999 and value < 1.00001
	} else {
		True
	}
}

terminal_escape = |edge_index, endpoint, edge, input, result| {
	points = route_points(result.layout.routes.get(edge_index) ?? Polyline([]))
	selected_ends = result.attachments.get(edge_index) ?? { from: { point: { x: 0, y: 0 }, side: Top }, to: { point: { x: 0, y: 0 }, side: Top } }
	selected = match endpoint { From => selected_ends.from, To => selected_ends.to }
	node = match endpoint { From => edge.from, To => edge.to }
	center = input.positions.get(node) ?? selected.point
	size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
	escape = match selected.side {
		Top => { x: selected.point.x, y: center.y - size.height / 2 - Route.default_settings.obstacle_gap }
		Right => { x: center.x + size.width / 2 + Route.default_settings.obstacle_gap, y: selected.point.y }
		Bottom => { x: selected.point.x, y: center.y + size.height / 2 + Route.default_settings.obstacle_gap }
		Left => { x: center.x - size.width / 2 - Route.default_settings.obstacle_gap, y: selected.point.y }
	}
	neighbor = match endpoint {
		From => points.get(1) ?? selected.point
		To => if points.len() < 2 { selected.point } else { points.get(points.len() - 2) ?? selected.point }
	}
	outward = match selected.side { Top => { x: 0, y: 0 - 1.0 }, Right => { x: 1, y: 0 }, Bottom => { x: 0, y: 1 }, Left => { x: 0 - 1.0, y: 0 } }
	required = (escape.x - selected.point.x).abs() + (escape.y - selected.point.y).abs()
	advance = (neighbor.x - selected.point.x) * outward.x + (neighbor.y - selected.point.y) * outward.y
	straight = (outward.x == 0 and neighbor.x == selected.point.x) or (outward.y == 0 and neighbor.y == selected.point.y)
	attached = match endpoint { From => points.first() == Ok(selected.point), To => points.last() == Ok(selected.point) }
	attached and straight and advance >= required
}

test = |bytes| {
	n = (byte_at(bytes, 0) % 8).to_u64()
	nodes = List.repeat({ width: 0.0, height: 0.0 }, n).map_with_index(|_, i| { width: (byte_at(bytes, 1 + i) % 31).to_f64(), height: (byte_at(bytes, 9 + i) % 31).to_f64() })
	positions = List.repeat({ x: 0.0, y: 0.0 }, n).map_with_index(|_, i| { x: (byte_at(bytes, 17 + i) % 101).to_f64(), y: (byte_at(bytes, 25 + i) % 101).to_f64() })
	edge_count = if n == 0 {
		0
	} else {
		(byte_at(bytes, 33) % 12).to_u64()
	}
	edges = List.repeat({ from: 0, to: 0 }, edge_count).map_with_index(|_, i| { from: byte_at(bytes, 34 + i * 2).to_u64() % n, to: byte_at(bytes, 35 + i * 2).to_u64() % n })
	shared_pair = edges.fold_with_index(
		[],
		|found, edge, i| if found.is_empty() {
			match edges.find_first_index(|other| other.to == edge.to and other != edge) {
				Ok(j) if j != i => [i, j]
				_ => found
			}
		} else {
			found
		},
	)
	shared_ends = if shared_pair.len() == 2 {
		[{ edges: shared_pair, endpoint: To, attachment: On(side_at(byte_at(bytes, 207))) }]
	} else {
		[]
	}
	groups = if n == 0 {
		[]
	} else {
		center = positions.first() ?? { x: 0, y: 0 }
		size = nodes.first() ?? { width: 0, height: 0 }
		[
			{ rect: { x: center.x - size.width / 2 - 30, y: center.y - size.height / 2 - 30, width: size.width + 60, height: size.height + 60 }, parent: Root },
			{ rect: { x: center.x - size.width / 2 - 15, y: center.y - size.height / 2 - 15, width: size.width + 30, height: size.height + 30 }, parent: Parent(0) },
		]
	}
	memberships = if n == 0 {
		[]
	} else {
		[{ node: 0, group: 1 }]
	}
	group_attachments = edges.map_with_index(
		|edge, edge_index| if (edge.from == 0) != (edge.to == 0) {
			offset_a = (byte_at(bytes, 155 + edge_index) % 101).to_f64() / 100
			offset_b = (byte_at(bytes, 167 + edge_index) % 101).to_f64() / 100
			[
				{ edge: edge_index, group: 0, attachment: Fixed({ side: side_at(byte_at(bytes, 179 + edge_index)), offset: offset_a }) },
				{ edge: edge_index, group: 1, attachment: Fixed({ side: side_at(byte_at(bytes, 191 + edge_index)), offset: offset_b }) },
			]
		} else {
			[]
		},
	).join()
	boundaries = List.repeat({}, n).map_with_index(|_, i| i).keep_if(|i| byte_at(bytes, 58 + i) % 2 == 1).map(|node| { node, outline: Ellipse })
	attachments = edges.map_with_index(
		|_, edge| {
			choice = byte_at(bytes, 70 + edge) % 3
			if choice == 0 {
				[]
			} else if choice == 1 {
				[{ edge, endpoint: From, attachment: On(side_at(byte_at(bytes, 82 + edge))) }]
			} else {
				offset = (byte_at(bytes, 94 + edge) % 101).to_f64() / 100
				[{ edge, endpoint: From, attachment: Fixed({ side: side_at(byte_at(bytes, 106 + edge)), offset }) }]
			}
		},
	).join()
	label_count = if edge_count == 0 {
		0
	} else {
		3 + (byte_at(bytes, 118) % 6).to_u64()
	}
	edge_labels = List.repeat({}, label_count).map_with_index(
		|_, i| {
			placement = match if i < 3 {
				i
			} else {
				(byte_at(bytes, 119 + i) % 3).to_u64()
			} {
				0 => Center
				1 => Near(From)
				_ => Near(To)
			}
			edge = if i < 3 {
				0
			} else {
				byte_at(bytes, 128 + i).to_u64() % edge_count
			}
			{ edge, width: (byte_at(bytes, 137 + i) % 41).to_f64(), height: (byte_at(bytes, 146 + i) % 21).to_f64(), placement }
		},
	)
	guides = if edge_count == 0 {
		[]
	} else {
		[{ edge: 0, points: [{ x: (byte_at(bytes, 214) % 101).to_f64(), y: (byte_at(bytes, 215) % 101).to_f64() }, { x: (byte_at(bytes, 216) % 101).to_f64(), y: (byte_at(bytes, 217) % 101).to_f64() }] }]
	}
	input = { ..Route.default_input, graph: { nodes, edges }, positions, groups, memberships, group_attachments, boundaries, attachments, edge_labels, shared_ends, guides }
	invalid = { ..input, group_attachments: [{ edge: edge_count, group: groups.len(), attachment: Fixed({ side: Top, offset: 2 }) }] }
	invalid_ok = match Route.layout(invalid, Route.default_settings) {
		Err(problems) => {
			found = problems.fold(
				{ edge: False, group: False, offset: False },
				|state, problem| match problem {
					InvalidGroupAttachmentEdge(0) => { ..state, edge: True }
					InvalidGroupAttachmentGroup(0) => { ..state, group: True }
					InvalidGroupAttachmentOffset(0) => { ..state, offset: True }
					_ => state
				},
			)
			found.edge and found.group and found.offset
		}
		Ok(_) => False
	}
	match Route.layout(input, Route.default_settings) {
		Ok(a) => {
			aligned = a.layout.routes.len() == edges.len() and a.attachments.len() == edges.len() and a.group_crossings.len() == edges.len() and a.label_anchors.len() == edge_labels.len() and a.shared_routes.len() == shared_ends.len()
			labels_in_bounds = edge_labels.fold_with_index(
				True,
				|ok, label, i| {
					anchor = a.label_anchors.get(i) ?? { x: F64.nan, y: F64.nan }
					ok and anchor.x - label.width / 2 >= a.layout.bounds.x and anchor.y - label.height / 2 >= a.layout.bounds.y and anchor.x + label.width / 2 <= a.layout.bounds.x + a.layout.bounds.width and anchor.y + label.height / 2 <= a.layout.bounds.y + a.layout.bounds.height
				},
			)
			finite_shared = a.shared_routes.all(|shared| finite_point(shared.junction) and orthogonal(shared.trunk) and finite_route(shared.trunk) and shared.edges.len() >= 2)
			finite_crossings = a.group_crossings.join().all(|crossing| finite_point(crossing.point) and F64.is_finite(crossing.offset) and crossing.offset >= 0 and crossing.offset <= 1)
			finite = a.layout.routes.all(|r| orthogonal(r) and finite_route(r)) and a.layout.positions.all(finite_point) and a.label_anchors.all(finite_point) and a.attachments.all(|ends| finite_point(ends.from.point) and finite_point(ends.to.point)) and finite_crossings and F64.is_finite(a.layout.bounds.x) and F64.is_finite(a.layout.bounds.y) and F64.is_finite(a.layout.bounds.width) and F64.is_finite(a.layout.bounds.height)
			ellipses = edges.fold_with_index(True, |ok, edge, i| ok and ellipse_attachment(i, From, edge, input, a) and ellipse_attachment(i, To, edge, input, a))
			terminals = edges.fold_with_index(
				True,
				|ok, edge, i| {
					shared = shared_ends.any(|rule| rule.edges.contains(i))
					ok and (edge.from == edge.to or shared or (terminal_escape(i, From, edge, input, a) and terminal_escape(i, To, edge, input, a)))
				},
			)
			clear_nodes = edges.fold_with_index(True, |ok, edge, i| ok and route_avoids_nodes(edge, a.layout.routes.get(i) ?? Polyline([]), input, Route.default_settings.obstacle_gap))
			portals = group_attachments.all(
				|rule| {
					crossings = (a.group_crossings.get(rule.edge) ?? []).keep_if(|crossing| crossing.group == rule.group)
					match crossings.first() {
						Ok(crossing) => crossings.len() == 1 and match rule.attachment {
							Fixed(selected) => crossing.side == selected.side and (crossing.offset - selected.offset).abs() < 0.000001
							_ => True
						}
						Err(_) => False
					}
				},
			)
			if invalid_ok and aligned and labels_in_bounds and finite and finite_shared and ellipses and terminals and clear_nodes and portals and a.layout.positions == positions and Route.layout(input, Route.default_settings) == Ok(a) {
				Fuzz.keep
			} else {
				crash "route geometry contract failed"
			}
		}
		Err(_) => crash "valid generated routing input was rejected"
	}
}

target = Fuzz.target_with({ name: "graph-layout-route", generator: Fuzz.list(Fuzz.u8, 208), test, show: |input| Str.inspect(input) })
