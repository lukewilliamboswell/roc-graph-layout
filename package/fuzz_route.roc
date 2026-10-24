app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

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

point_on_route = |point, route| {
	points = route_points(route)
	points.fold_with_index(
		False,
		|found, a, i| match points.get(i + 1) {
			Ok(b) => found or (a.x == b.x and point.x == a.x and point.y >= a.y.min(b.y) and point.y <= a.y.max(b.y)) or (a.y == b.y and point.y == a.y and point.x >= a.x.min(b.x) and point.x <= a.x.max(b.x))
			Err(_) => found
		},
	)
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
			inside = |p| p.x > box.min_x and p.x < box.max_x and p.y > box.min_y and p.y < box.max_y
			# A box holding an end, or holding the point where a route must
			# finish its straight escape from a port, cannot be avoided.
			escape_from = points.get(1) ?? from
			escape_to = if points.len() < 2 {
				to
			} else {
				points.get(points.len() - 2) ?? to
			}
			impossible = inside(from) or inside(to) or inside(escape_from) or inside(escape_to)
			clear and (
				impossible or points.fold_with_index(
					True,
					|free, a, i| match points.get(i + 1) {
						Ok(b) => free and !segment_hits(a, b, box)
						Err(_) => free
					},
				)
			)
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
	selected = match endpoint {
		From => selected_ends.from
		To => selected_ends.to
	}
	node = match endpoint {
		From => edge.from
		To => edge.to
	}
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
		To => if points.len() < 2 {
			selected.point
		} else {
			points.get(points.len() - 2) ?? selected.point
		}
	}
	outward = match selected.side {
		Top => { x: 0, y: 0 - 1.0 }
		Right => { x: 1, y: 0 }
		Bottom => { x: 0, y: 1 }
		Left => { x: 0 - 1.0, y: 0 }
	}
	required = (escape.x - selected.point.x).abs() + (escape.y - selected.point.y).abs()
	advance = (neighbor.x - selected.point.x) * outward.x + (neighbor.y - selected.point.y) * outward.y
	straight = (outward.x == 0 and neighbor.x == selected.point.x) or (outward.y == 0 and neighbor.y == selected.point.y)
	attached = match endpoint {
		From => points.first() == Ok(selected.point)
		To => points.last() == Ok(selected.point)
	}
	attached and straight and advance >= required
}

test = |bytes| {
	n = (byte_at(bytes, 0) % 8).to_u64()
	nodes = List.repeat({ width: 0.0, height: 0.0 }, n).map_with_index(|_, i| { width: (byte_at(bytes, 1 + i) % 31).to_f64(), height: (byte_at(bytes, 9 + i) % 31).to_f64() })
	raw_positions = List.repeat({ x: 0.0, y: 0.0 }, n).map_with_index(|_, i| { x: (byte_at(bytes, 17 + i) % 101).to_f64(), y: (byte_at(bytes, 25 + i) % 101).to_f64() })
	# Only node 0 belongs to the groups drawn around it below. A node that
	# would overlap them (with clearance) is moved right of them, so the
	# drawing agrees with its memberships.
	positions = raw_positions.map_with_index(
		|p, i| {
			c = raw_positions.first() ?? { x: 0, y: 0 }
			s = nodes.first() ?? { width: 0, height: 0 }
			size = nodes.get(i) ?? { width: 0, height: 0 }
			reach = 40 + Route.default_settings.obstacle_gap * 2
			overlaps = (p.x - c.x).abs() < s.width / 2 + size.width / 2 + reach and (p.y - c.y).abs() < s.height / 2 + size.height / 2 + reach
			if i == 0 or !overlaps {
				p
			} else {
				{ x: c.x + s.width / 2 + reach + size.width / 2 + 1 + p.x, y: p.y }
			}
		},
	)
	edge_count = if n == 0 {
		0
	} else {
		(byte_at(bytes, 33) % 12).to_u64()
	}
	# `.max(1)` changes nothing when this closure runs, but works around
	# https://github.com/roc-lang/roc/issues/12556: optimized builds otherwise
	# assume the divisor is nonzero after the closure, even when it never ran.
	edges = List.repeat({ from: 0, to: 0 }, edge_count).map_with_index(|_, i| { from: byte_at(bytes, 34 + i * 2).to_u64() % n.max(1), to: byte_at(bytes, 35 + i * 2).to_u64() % n.max(1) })
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
			{ rect: { x: center.x - size.width / 2 - 40, y: center.y - size.height / 2 - 40, width: size.width + 80, height: size.height + 80 }, parent: Root },
			{ rect: { x: center.x - size.width / 2 - 20, y: center.y - size.height / 2 - 20, width: size.width + 40, height: size.height + 40 }, parent: Parent(0) },
		]
	}
	memberships = if n == 0 {
		[]
	} else {
		[{ node: 0, group: 1 }]
	}
	group_attachments = edges.map_with_index(
		|edge, edge_index| if (edge.from == 0) != (edge.to == 0) {
			# Fixed portals stay off the group corners, which lie on two sides
			# at once; `corner` below excludes them from the portal check too.
			offset_a = (byte_at(bytes, 155 + edge_index) % 99 + 1).to_f64() / 100
			offset_b = (byte_at(bytes, 167 + edge_index) % 99 + 1).to_f64() / 100
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
				byte_at(bytes, 128 + i).to_u64() % edge_count.max(1)
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
			labels_on_routes = edge_labels.fold_with_index(
				True,
				|ok, label, i| {
					anchor = a.label_anchors.get(i) ?? { x: F64.nan, y: F64.nan }
					on_edge = point_on_route(anchor, a.layout.routes.get(label.edge) ?? Polyline([]))
					on_shared = a.shared_routes.any(|shared| shared.edges.contains(label.edge) and point_on_route(anchor, shared.trunk))
					ok and (on_edge or on_shared)
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
					# Overlapping endpoint boxes may leave no clear escape.
					ok and (edge.from == edge.to or shared or boxes_overlap(edge, input) or (terminal_escape(i, From, edge, input, a) and terminal_escape(i, To, edge, input, a)))
				},
			)
			# A shared end's junction sits at a fixed distance from its common node,
			# so its branches are only required to be well formed.
			clear_nodes = edges.fold_with_index(True, |ok, edge, i| ok and (shared_ends.any(|rule| rule.edges.contains(i)) or route_avoids_nodes(edge, a.layout.routes.get(i) ?? Polyline([]), input, Route.default_settings.obstacle_gap)))
			# A portal fixed at offset 0 or 1 is a group corner, on two sides at
			# once; its single crossing is not well defined.
			# A node drawn inside a group it does not belong to must leave that
			# group's outline before entering through the portal, so the single
			# crossing is only required where membership and geometry agree.
			portals = group_attachments.keep_if(|rule| !corner(rule.attachment) and consistent(rule, edges, nodes, positions, groups)).all(
				|rule| {
					crossings = (a.group_crossings.get(rule.edge) ?? []).concat(a.shared_routes.keep_if(|shared| shared.edges.contains(rule.edge)).map(|shared| shared.group_crossings).join()).keep_if(|crossing| crossing.group == rule.group)
					match crossings.first() {
						Ok(crossing) => crossings.len() == 1 and match rule.attachment {
							Fixed(selected) => crossing.side == selected.side and (crossing.offset - selected.offset).abs() < 0.000001
							_ => True
						}
						Err(_) => False
					}
				},
			)
			# Clearance, escapes and single portal crossings are promised for
			# drawings whose node clearance boxes are apart, and where shared
			# ends do not also cross groups through fixed portals; crowded or
			# combined inputs need only the structural properties.
			separated = positions.map_with_index(|p, i| { p, i }).all(
				|first| positions.map_with_index(|q, j| { q, j }).all(
					|second| {
						s1 = nodes.get(first.i) ?? { width: 0, height: 0 }
						s2 = nodes.get(second.j) ?? { width: 0, height: 0 }
						reach = Route.default_settings.obstacle_gap * 2
						first.i >= second.j or (first.p.x - second.q.x).abs() >= (s1.width + s2.width) / 2 + reach or (first.p.y - second.q.y).abs() >= (s1.height + s2.height) / 2 + reach
					},
				),
			)
			geometric = separated and (shared_ends.is_empty() or group_attachments.is_empty())
			geometry_ok = !geometric or (terminals and clear_nodes and portals)
			if invalid_ok and aligned and labels_in_bounds and labels_on_routes and finite and finite_shared and ellipses and geometry_ok and a.layout.positions == positions and Route.layout(input, Route.default_settings) == Ok(a) {
				Fuzz.keep
			} else {
				crash "route geometry contract failed"
			}
		}
		Err(_) => crash "valid generated routing input was rejected"
	}
}

corner = |attachment| match attachment {
	Fixed(payload) => payload.offset == 0 or payload.offset == 1
	_ => False
}

## Whether neither end of the rule's edge overlaps the rule's group (with
## routing clearance) without belonging to it. In generated inputs only node
## 0 belongs to the groups, which surround it.
consistent = |rule, edges, nodes, positions, groups| {
	edge = edges.get(rule.edge) ?? { from: 0, to: 0 }
	rect = (groups.get(rule.group) ?? { rect: { x: 0, y: 0, width: 0, height: 0 }, parent: Root }).rect
	gap = Route.default_settings.obstacle_gap
	stray = |node| {
		p = positions.get(node) ?? { x: 0, y: 0 }
		size = nodes.get(node) ?? { width: 0, height: 0 }
		node != 0 and p.x + size.width / 2 + gap > rect.x and p.x - size.width / 2 - gap < rect.x + rect.width and p.y + size.height / 2 + gap > rect.y and p.y - size.height / 2 - gap < rect.y + rect.height
	}
	!stray(edge.from) and !stray(edge.to)
}

## Whether an edge's two (obstacle-inflated) node boxes overlap.
boxes_overlap = |edge, input| {
	gap = Route.default_settings.obstacle_gap
	a = input.positions.get(edge.from) ?? { x: 0, y: 0 }
	b = input.positions.get(edge.to) ?? { x: 0, y: 0 }
	sa = input.graph.nodes.get(edge.from) ?? { width: 0, height: 0 }
	sb = input.graph.nodes.get(edge.to) ?? { width: 0, height: 0 }
	(a.x - b.x).abs() < (sa.width + sb.width) / 2 + gap * 2 and (a.y - b.y).abs() < (sa.height + sb.height) / 2 + gap * 2
}

## The ungrouped part of the input, repeated as `copies` side-by-side
## copies on disjoint nodes: sizes, positions, edges (with self-loops and
## parallel edges), a guide and labels.
copied : List(U8), U64 -> Route.Input
copied = |bytes, copies| {
	n = (byte_at(bytes, 0) % 8).to_u64()
	edge_count = if n == 0 {
		0
	} else {
		(byte_at(bytes, 33) % 12).to_u64()
	}
	var $nodes = []
	var $positions = []
	var $edges = []
	var $guides = []
	var $labels = []
	for copy in 0..<copies {
		shift = copy.to_f64() * 300
		base = copy * n
		for i in 0..<n {
			$nodes = $nodes.append({ width: (byte_at(bytes, 1 + i) % 31).to_f64(), height: (byte_at(bytes, 9 + i) % 31).to_f64() })
			$positions = $positions.append({ x: (byte_at(bytes, 17 + i) % 101).to_f64() + shift, y: (byte_at(bytes, 25 + i) % 101).to_f64() })
		}
		for i in 0..<edge_count {
			$edges = $edges.append({ from: base + byte_at(bytes, 34 + i * 2).to_u64() % n.max(1), to: base + byte_at(bytes, 35 + i * 2).to_u64() % n.max(1) })
		}
		if edge_count > 0 {
			$guides = $guides.append({ edge: copy * edge_count, points: [{ x: (byte_at(bytes, 214) % 101).to_f64() + shift, y: (byte_at(bytes, 215) % 101).to_f64() }] })
			$labels = $labels.append({ edge: copy * edge_count, width: (byte_at(bytes, 137) % 41).to_f64(), height: (byte_at(bytes, 146) % 21).to_f64(), placement: Center })
		}
	}
	{ ..Route.default_input, graph: { nodes: $nodes, edges: $edges }, positions: $positions, guides: $guides, edge_labels: $labels }
}

## Routing 8 disjoint copies may allocate at most 20 times as often as
## routing one, and frees everything it allocates. Linear work gives about
## 8; the margin covers the logarithmic depth of sorts and tables, and an
## improvement sweep that one copy needs but the single drawing did not
## (sweeps are bounded by `max_sweeps`). Work per edge that grows with the
## drawing shows up as about 64.
scaling! : List(U8) => {}
scaling! = |bytes| {
	small = copied(bytes, 1)
	large = copied(bytes, 8)
	small_cost = Fuzz.measure_allocs!(|{}| Route.layout(small, Route.default_settings)).allocations
	large_cost = Fuzz.measure_allocs!(|{}| Route.layout(large, Route.default_settings)).allocations
	Fuzz.expect_no_leaks!(|{}| Route.layout(large, Route.default_settings))
	if large_cost > small_cost * 20 + 1024 {
		crash "routing 8 copies took ${large_cost.to_str()} allocations, against ${small_cost.to_str()} for one"
	}
	{}
}

test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	scaling!(bytes)
	test(bytes)
}

target = Fuzz.target_with!({ name: "graph-layout-route", generator: Fuzz.list(Fuzz.u8, 208), test!, show: |input| Str.inspect(input) })

## fuzz regression: nodes 3, 5 and 6 sit inside a group they do not belong
## to, so every L-shaped leg was blocked and the old exhaustive search gave
## up at once; edges 1 and 2 were drawn as single diagonal segments. The
## search now ignores obstacles holding a leg's end, and every route stays
## axis-aligned and finite.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 18, height: 27 }, { width: 1, height: 22 }, { width: 26, height: 0 }, { width: 4, height: 25 }, { width: 7, height: 20 }, { width: 29, height: 1 }, { width: 5, height: 6 }], edges: [{ from: 6, to: 6 }, { from: 5, to: 4 }, { from: 3, to: 5 }] },
		positions: [{ x: 75, y: 30 }, { x: 0, y: 33 }, { x: 4, y: 59 }, { x: 50, y: 60 }, { x: 29, y: 44 }, { x: 75, y: 7 }, { x: 70, y: 57 }],
		groups: [{ rect: { x: 36, y: -13.5, width: 78, height: 87 }, parent: Root }, { rect: { x: 51, y: 1.5, width: 48, height: 57 }, parent: Parent(0) }],
		memberships: [{ node: 0, group: 1 }],
		boundaries: [{ node: 4, outline: Ellipse }],
		guides: [{ edge: 0, points: [{ x: 0, y: 0 }, { x: 0, y: 0 }] }],
	}
	match Route.layout(input, Route.default_settings) {
		Ok(result) => result.layout.routes.all(|route| orthogonal(route) and finite_route(route))
		Err(_) => False
	}
}

## fuzz regression: ten edges leave one zero-size node from the same point,
## so the bundle was fanned sideways into lanes; edge 0's lane began outside
## the group it must leave through a fixed portal, and it crossed that
## group's outline twice. Routes with portals now start at their escape.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 0, height: 0 }, { width: 30, height: 8 }, { width: 25, height: 5 }], edges: [{ from: 0, to: 1 }].concat(List.repeat({ from: 0, to: 0 }, 9)) },
		positions: [{ x: 80, y: 21 }, { x: 7, y: 23 }, { x: 219.5, y: 74 }],
		groups: [{ rect: { x: 40, y: -19, width: 80, height: 80 }, parent: Root }, { rect: { x: 60, y: 1, width: 40, height: 40 }, parent: Parent(0) }],
		memberships: [{ node: 0, group: 1 }],
		group_attachments: [{ edge: 0, group: 0, attachment: Fixed({ side: Top, offset: 0.01 }) }, { edge: 0, group: 1, attachment: Fixed({ side: Top, offset: 0.01 }) }],
		guides: [{ edge: 0, points: [{ x: 0, y: 0 }, { x: 0, y: 0 }] }],
	}
	match Route.layout(input, Route.default_settings) {
		Ok(result) => {
			crossings = result.group_crossings.get(0) ?? []
			crossings.keep_if(|c| c.group == 0).len() == 1 and crossings.keep_if(|c| c.group == 1).len() == 1
		}
		Err(_) => False
	}
}
