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
	input = { ..Route.default_input, graph: { nodes, edges }, positions, groups, memberships, group_attachments, boundaries, attachments, edge_labels }
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
			aligned = a.layout.routes.len() == edges.len() and a.attachments.len() == edges.len() and a.group_crossings.len() == edges.len() and a.label_anchors.len() == edge_labels.len()
			finite_crossings = a.group_crossings.join().all(|crossing| finite_point(crossing.point) and F64.is_finite(crossing.offset) and crossing.offset >= 0 and crossing.offset <= 1)
			finite = a.layout.routes.all(|r| orthogonal(r) and finite_route(r)) and a.layout.positions.all(finite_point) and a.label_anchors.all(finite_point) and a.attachments.all(|ends| finite_point(ends.from.point) and finite_point(ends.to.point)) and finite_crossings and F64.is_finite(a.layout.bounds.width) and F64.is_finite(a.layout.bounds.height)
			ellipses = edges.fold_with_index(True, |ok, edge, i| ok and ellipse_attachment(i, From, edge, input, a) and ellipse_attachment(i, To, edge, input, a))
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
			if invalid_ok and aligned and finite and ellipses and portals and Route.layout(input, Route.default_settings) == Ok(a) {
				Fuzz.keep
			} else {
				crash "route geometry contract failed"
			}
		}
		Err(_) => crash "valid generated routing input was rejected"
	}
}

target = Fuzz.target_with({ name: "graph-layout-route", generator: Fuzz.list(Fuzz.u8, 208), test, show: |input| Str.inspect(input) })
