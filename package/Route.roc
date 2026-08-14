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
		p5c = input.boundaries.fold_with_index(
			p5b,
			|acc, rule, i| {
				a = if rule.node < input.graph.nodes.len() {
					acc
				} else {
					acc.append(InvalidBoundaryNode(i))
				}
				duplicate = input.boundaries.fold_with_index(False, |found, other, j| found or (j < i and other.node == rule.node))
				if duplicate {
					a.append(DuplicateBoundary(i))
				} else {
					a
				}
			},
		)
		p5d = input.group_attachments.fold_with_index(
			p5c,
			|acc, rule, i| {
				edge_valid = rule.edge < input.graph.edges.len()
				group_valid = rule.group < input.groups.len()
				a = if edge_valid {
					acc
				} else {
					acc.append(InvalidGroupAttachmentEdge(i))
				}
				b = if group_valid {
					a
				} else {
					a.append(InvalidGroupAttachmentGroup(i))
				}
				valid_fixed = match rule.attachment {
					Fixed(payload) => F64.is_finite(payload.offset) and payload.offset >= 0 and payload.offset <= 1
					_ => True
				}
				c = if valid_fixed {
					b
				} else {
					b.append(InvalidGroupAttachmentOffset(i))
				}
				duplicate = input.group_attachments.fold_with_index(False, |found, other, j| found or (j < i and other.edge == rule.edge and other.group == rule.group))
				d = if duplicate {
					c.append(DuplicateGroupAttachment(i))
				} else {
					c
				}
				if edge_valid and group_valid {
					edge = input.graph.edges.get(rule.edge) ?? { from: 0, to: 0 }
					from_inside = RouteInternals.node_in_group(edge.from, rule.group, input)
					to_inside = RouteInternals.node_in_group(edge.to, rule.group, input)
					if from_inside != to_inside {
						d
					} else {
						d.append(GroupAttachmentNotBoundary(i))
					}
				} else {
					d
				}
			},
		)
		p6 = input.edge_labels.fold_with_index(
			p5d,
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
				c
			},
		)
		p6b = input.shared_ends.fold_with_index(
			p6,
			|acc, rule, i| {
				a = if rule.edges.len() >= 2 {
					acc
				} else {
					acc.append(SharedEndNeedsEdges(i))
				}
				valid_edges = rule.edges.keep_if(|edge| edge < input.graph.edges.len())
				b = if valid_edges.len() == rule.edges.len() {
					a
				} else {
					a.append(InvalidSharedEndEdge(i))
				}
				duplicate_edge = rule.edges.fold_with_index(False, |found, edge, j| found or rule.edges.take_first(j).contains(edge))
				c = if duplicate_edge {
					b.append(DuplicateSharedEndEdge(i))
				} else {
					b
				}
				valid_attachment = match rule.attachment {
					Fixed(payload) => F64.is_finite(payload.offset) and payload.offset >= 0 and payload.offset <= 1
					_ => True
				}
				c2 = if valid_attachment {
					c
				} else {
					c.append(InvalidSharedEndAttachmentOffset(i))
				}
				common = match valid_edges.first() {
					Ok(edge_index) => {
						edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
						Ok(
							match rule.endpoint {
								From => edge.from
								To => edge.to
							},
						)
					}
					Err(_) => Err(NoSharedEnd)
				}
				same_end = valid_edges.all(
					|edge_index| {
						edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
						node = match rule.endpoint {
							From => edge.from
							To => edge.to
						}
						common == Ok(node)
					},
				)
				d = if same_end {
					c2
				} else {
					c2.append(SharedEndMismatch(i))
				}
				ambiguous_attachment = valid_edges.any(|edge| input.attachments.any(|attachment| attachment.edge == edge and attachment.endpoint == rule.endpoint))
				e = if ambiguous_attachment == False {
					d
				} else {
					d.append(SharedEndMemberAttachment(i))
				}
				overlaps = input.shared_ends.fold_with_index(False, |found, other, j| found or (j < i and rule.edges.any(|edge| other.edges.contains(edge))))
				if overlaps {
					e.append(SharedEndOverlap(i))
				} else {
					e
				}
			},
		)
		p7 = if F64.is_finite(settings.obstacle_gap) and settings.obstacle_gap >= 0 {
			p6b
		} else {
			p6b.append(InvalidObstacleGap)
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

	node_in_group = |node, group, input| match input.memberships.find_first(|membership| membership.node == node) {
		Ok(membership) => RouteInternals.group_in_chain(membership.group, group, input.groups, input.groups.len() + 1)
		Err(_) => False
	}

	boundary_outline = |node, rules| match rules.find_first(|rule| rule.node == node) {
		Ok(rule) => rule.outline
		Err(_) => Rectangle
	}

	fixed_point : { x : F64, y : F64 }, { width : F64, height : F64 }, Route.Side, F64, Route.Outline -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 }, side : Route.Side }
	fixed_point = |center, size, side, offset, node_outline| {
		x_radius = size.width / 2
		y_radius = size.height / 2
		along = offset * 2 - 1
		curve = (1 - along * along).max(0).sqrt()
		match (node_outline, side) {
			(Rectangle, Top) => { point: { x: center.x - x_radius + size.width * offset, y: center.y - y_radius }, outward: { x: 0, y: 0 - 1.0 }, side }
			(Rectangle, Right) => { point: { x: center.x + x_radius, y: center.y - y_radius + size.height * offset }, outward: { x: 1, y: 0 }, side }
			(Rectangle, Bottom) => { point: { x: center.x - x_radius + size.width * offset, y: center.y + y_radius }, outward: { x: 0, y: 1 }, side }
			(Rectangle, Left) => { point: { x: center.x - x_radius, y: center.y - y_radius + size.height * offset }, outward: { x: 0 - 1.0, y: 0 }, side }
			(Ellipse, Top) => { point: { x: center.x + x_radius * along, y: center.y - y_radius * curve }, outward: { x: 0, y: 0 - 1.0 }, side }
			(Ellipse, Right) => { point: { x: center.x + x_radius * curve, y: center.y + y_radius * along }, outward: { x: 1, y: 0 }, side }
			(Ellipse, Bottom) => { point: { x: center.x + x_radius * along, y: center.y + y_radius * curve }, outward: { x: 0, y: 1 }, side }
			(Ellipse, Left) => { point: { x: center.x - x_radius * curve, y: center.y + y_radius * along }, outward: { x: 0 - 1.0, y: 0 }, side }
		}
	}

	clip_ellipse = |center, size, toward| {
		dx = toward.x - center.x
		dy = toward.y - center.y
		rx = size.width / 2
		ry = size.height / 2
		if dx == 0 and dy == 0 or rx == 0 or ry == 0 {
			center
		} else {
			scale = 1 / ((dx / rx) * (dx / rx) + (dy / ry) * (dy / ry)).sqrt()
			{ x: center.x + dx * scale, y: center.y + dy * scale }
		}
	}

	terminal : U64, Route.Endpoint, { from : U64, to : U64 }, Route.Input -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 }, side : Route.Side }
	terminal = |edge_index, endpoint, edge, input| {
		node = match endpoint {
			From => edge.from
			To => edge.to
		}
		center = input.positions.get(node) ?? { x: 0, y: 0 }
		size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
		node_outline = RouteInternals.boundary_outline(node, input.boundaries)
		rule = RouteInternals.attachment_rule(edge_index, endpoint, input.attachments)
		match rule {
			Fixed(payload) => RouteInternals.fixed_point(center, size, payload.side, payload.offset, node_outline)
			On(side) => RouteInternals.fixed_point(center, size, side, 0.5, node_outline)
			Automatic => {
				other_index = match endpoint {
					From => edge.to
					To => edge.from
				}
				other = input.positions.get(other_index) ?? center
				point = match node_outline {
					Rectangle => Geom.clip_to_node(center, size, other)
					Ellipse => RouteInternals.clip_ellipse(center, size, other)
				}
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

	group_chain = |group, groups, acc, fuel| if fuel == 0 {
		acc
	} else {
		next = acc.append(group)
		match groups.get(group) {
			Ok(item) => match item.parent {
				Root => next
				Parent(parent) => RouteInternals.group_chain(parent, groups, next, fuel - 1)
			}
			Err(_) => next
		}
	}

	node_chain = |node, input| match input.memberships.find_first(|membership| membership.node == node) {
		Ok(membership) => RouteInternals.group_chain(membership.group, input.groups, [], input.groups.len() + 1)
		Err(_) => []
	}

	portal_on_group = |rule, toward, input| {
		group = input.groups.get(rule.group) ?? { rect: Geom.empty_bounds, parent: Root }
		rect = group.rect
		center = { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }
		size = { width: rect.width, height: rect.height }
		selected = match rule.attachment {
			Fixed(payload) => RouteInternals.fixed_point(center, size, payload.side, payload.offset, Rectangle)
			On(side) => RouteInternals.fixed_point(center, size, side, 0.5, Rectangle)
			Automatic => {
				point = Geom.clip_to_node(center, size, toward)
				dx = point.x - center.x
				dy = point.y - center.y
				side = if dx.abs() >= dy.abs() {
					if dx < 0 {
						Left
					} else {
						Right
					}
				} else if dy < 0 {
					Top
				} else {
					Bottom
				}
				outward = match side {
					Top => { x: 0, y: 0 - 1.0 }
					Right => { x: 1, y: 0 }
					Bottom => { x: 0, y: 1 }
					Left => { x: 0 - 1.0, y: 0 }
				}
				{ point, outward, side }
			}
		}
		offset = match selected.side {
			Top => if rect.width == 0 {
				0
			} else {
				(selected.point.x - rect.x) / rect.width
			}
			Bottom => if rect.width == 0 {
				0
			} else {
				(selected.point.x - rect.x) / rect.width
			}
			Left => if rect.height == 0 {
				0
			} else {
				(selected.point.y - rect.y) / rect.height
			}
			Right => if rect.height == 0 {
				0
			} else {
				(selected.point.y - rect.y) / rect.height
			}
		}
		{ group: rule.group, point: selected.point, outward: selected.outward, side: selected.side, offset }
	}

	edge_portals = |edge_index, edge, input| {
		from_chain = RouteInternals.node_chain(edge.from, input)
		to_chain_inner = RouteInternals.node_chain(edge.to, input)
		to_chain = to_chain_inner.fold([], |acc, group| [group].concat(acc))
		from_rules = from_chain.keep_oks(|group| input.group_attachments.find_first(|rule| rule.edge == edge_index and rule.group == group))
		to_rules = to_chain.keep_oks(|group| input.group_attachments.find_first(|rule| rule.edge == edge_index and rule.group == group))
		from_toward = input.positions.get(edge.to) ?? { x: 0, y: 0 }
		to_toward = input.positions.get(edge.from) ?? { x: 0, y: 0 }
		from_rules.map(
			|rule| {
				portal = RouteInternals.portal_on_group(rule, from_toward, input)
				{ group: portal.group, point: portal.point, outward: portal.outward, side: portal.side, offset: portal.offset, leaving: True }
			},
		).concat(
			to_rules.map(
				|rule| {
					portal = RouteInternals.portal_on_group(rule, to_toward, input)
					{ group: portal.group, point: portal.point, outward: portal.outward, side: portal.side, offset: portal.offset, leaving: False }
				},
			),
		)
	}

	portal_stops = |portal, gap, input| {
		group = input.groups.get(portal.group) ?? { rect: Geom.empty_bounds, parent: Root }
		usable_gap = if group.rect.width == 0 or group.rect.height == 0 {
			0
		} else {
			gap
		}
		inside = { x: portal.point.x - portal.outward.x * usable_gap, y: portal.point.y - portal.outward.y * usable_gap }
		outside = { x: portal.point.x + portal.outward.x * usable_gap, y: portal.point.y + portal.outward.y * usable_gap }
		if portal.leaving {
			{ approach: inside, departure: outside }
		} else {
			{ approach: outside, departure: inside }
		}
	}

	reverse_portals = |portals| portals.fold(
		[],
		|acc, portal| [
			{
				..portal,
				leaving: if portal.leaving {
					False
				} else {
					True
				},
			},
		].concat(acc),
	)

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

	simplify_preserving = |points, preserved| points.fold(
		[],
		|acc, p| if acc.is_empty() {
			[p]
		} else {
			last = acc.get(acc.len() - 1) ?? { x: F64.nan, y: F64.nan }
			if p == last {
				acc
			} else if acc.len() >= 2 {
				before = acc.get(acc.len() - 2) ?? last
				if ((before.x == last.x and last.x == p.x) or (before.y == last.y and last.y == p.y)) and !preserved.contains(last) {
					(acc.drop_last(1)).append(p)
				} else {
					acc.append(p)
				}
			} else {
				acc.append(p)
			}
		},
	)

	reverse_points = |points| points.fold([], |acc, point| [point].concat(acc))

	join_shared = |branch, trunk, endpoint| {
		branch_points = RouteInternals.route_points(branch)
		trunk_points = RouteInternals.route_points(trunk)
		Polyline(
			match endpoint {
				To => RouteInternals.simplify(branch_points.concat(trunk_points.drop_first(1)))
				From => RouteInternals.simplify(RouteInternals.reverse_points(trunk_points).concat(branch_points.drop_first(1)))
			},
		)
	}

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

	route_leg : { x : F64, y : F64 }, { x : F64, y : F64 }, List({ min_x : F64, min_y : F64, max_x : F64, max_y : F64 }), Route.Settings, List(Geom.Route) -> List({ x : F64, y : F64 })
	route_leg = |start, finish, boxes, settings, prior| {
		hv = [start, { x: finish.x, y: start.y }, finish]
		vh = [start, { x: start.x, y: finish.y }, finish]
		hv_clear = RouteInternals.path_visible(hv, boxes)
		vh_clear = RouteInternals.path_visible(vh, boxes)
		if hv_clear and vh_clear {
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
			searched = RouteInternals.shortest_grid(start, finish, boxes, settings, prior)
			if searched.is_empty() {
				exterior_y = boxes.fold(start.y.min(finish.y), |top, box| top.min(box.min_y)) - settings.edge_gap
				[start, { x: start.x, y: exterior_y }, { x: finish.x, y: exterior_y }, finish]
			} else {
				searched
			}
		}
	}

	route_one : U64, { from : U64, to : U64 }, Route.Input, Route.Settings, { rank : U64, count : U64 }, List(Geom.Route) -> Geom.Route
	route_one = |index, edge, input, settings, fan, prior| {
		a = RouteInternals.terminal(index, From, edge, input)
		b = RouteInternals.terminal(index, To, edge, input)
		portals = RouteInternals.edge_portals(index, edge, input)
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
		} else if portals.is_empty() {
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
		} else {
			ap = { x: a.point.x + a.outward.x * settings.obstacle_gap, y: a.point.y + a.outward.y * settings.obstacle_gap }
			bp = { x: b.point.x + b.outward.x * settings.obstacle_gap, y: b.point.y + b.outward.y * settings.obstacle_gap }
			boxes = RouteInternals.obstacles(input, settings, edge.from, edge.to)
			through = portals.fold(
				{ points: [a.point, ap], current: ap },
				|state, portal| {
					stops = RouteInternals.portal_stops(portal, settings.obstacle_gap, input)
					leg = RouteInternals.route_leg(state.current, stops.approach, boxes, settings, prior)
					{ points: state.points.concat(leg.drop_first(1)).concat([portal.point, stops.departure]), current: stops.departure }
				},
			)
			last_leg = RouteInternals.route_leg(through.current, bp, boxes, settings, prior)
			Polyline(RouteInternals.simplify_preserving(through.points.concat(last_leg.drop_first(1)).append(b.point), portals.map(|portal| portal.point)))
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

	point_along = |points, remaining, index, fuel| if fuel == 0 {
		points.last() ?? { x: 0, y: 0 }
	} else {
		a = points.get(index) ?? { x: 0, y: 0 }
		match points.get(index + 1) {
			Err(_) => a
			Ok(b) => {
				length = (b.x - a.x).abs() + (b.y - a.y).abs()
				if remaining <= length {
					ratio = if length == 0 {
						0
					} else {
						remaining / length
					}
					{ x: a.x + (b.x - a.x) * ratio, y: a.y + (b.y - a.y) * ratio }
				} else {
					RouteInternals.point_along(points, remaining - length, index + 1, fuel - 1)
				}
			}
		}
	}

	anchor_for : Geom.Route, Route.LabelPlacement -> { x : F64, y : F64 }
	anchor_for = |route, placement| {
		ps = RouteInternals.route_points(route)
		if ps.is_empty() {
			{ x: 0, y: 0 }
		} else {
			total = ps.fold_with_index(
				0,
				|length, a, i| match ps.get(i + 1) {
					Ok(b) => length + (b.x - a.x).abs() + (b.y - a.y).abs()
					Err(_) => length
				},
			)
			fraction = match placement {
				Center => 0.5
				Near(From) => 0.15
				Near(To) => 0.85
			}
			RouteInternals.point_along(ps, total * fraction, 0, ps.len() + 1)
		}
	}

	anchor_fraction = |route, fraction| {
		points = RouteInternals.route_points(route)
		total = points.fold_with_index(
			0,
			|length, a, i| match points.get(i + 1) {
				Ok(b) => length + (b.x - a.x).abs() + (b.y - a.y).abs()
				Err(_) => length
			},
		)
		RouteInternals.point_along(points, total * fraction, 0, points.len() + 1)
	}

	local_label_candidates = |route, base, width, height, settings, rings| {
		points = RouteInternals.route_points(route)
		segment = points.fold_with_index(
			{ horizontal: True, length: 0.0 },
			|best, a, i| match points.get(i + 1) {
				Ok(b) => {
					on_segment = if a.x == b.x {
						base.x == a.x and base.y >= a.y.min(b.y) and base.y <= a.y.max(b.y)
					} else if a.y == b.y {
						base.y == a.y and base.x >= a.x.min(b.x) and base.x <= a.x.max(b.x)
					} else {
						False
					}
					length = (b.x - a.x).abs() + (b.y - a.y).abs()
					if on_segment and length > best.length {
						{ horizontal: a.y == b.y, length }
					} else {
						best
					}
				}
				Err(_) => best
			},
		)
		step = if segment.horizontal {
			height / 2 + settings.obstacle_gap + settings.edge_gap
		} else {
			width / 2 + settings.obstacle_gap + settings.edge_gap
		}
		normal = rings.map(
			|ring| {
				distance = step * ring.to_f64()
				if segment.horizontal {
					[{ x: base.x, y: base.y - distance }, { x: base.x, y: base.y + distance }]
				} else {
					[{ x: base.x - distance, y: base.y }, { x: base.x + distance, y: base.y }]
				}
			},
		).join()
		[base].concat(normal)
	}

	label_candidates = |route, placement, width, height, settings| {
		fractions = match placement {
			Near(From) => [0.15, 0.22, 0.30, 0.38, 0.46]
			Near(To) => [0.85, 0.78, 0.70, 0.62, 0.54]
			Center => [0.50, 0.42, 0.58, 0.34, 0.66]
		}
		local = fractions.map(
			|fraction| {
				anchor = RouteInternals.anchor_fraction(route, fraction)
				RouteInternals.local_label_candidates(route, anchor, width, height, settings, [1, 2])
			},
		).join()
		desired = RouteInternals.anchor_fraction(route, fractions.first() ?? 0.5)
		local.concat(RouteInternals.local_label_candidates(route, desired, width, height, settings, [3, 4, 5, 6, 7, 8]).drop_first(1))
	}

	segment_crossings = |a, b, rect| if a.x == b.x {
		[rect.y, rect.y + rect.height].keep_if(|y| y >= a.y.min(b.y) and y <= a.y.max(b.y) and a.x >= rect.x and a.x <= rect.x + rect.width).map(|y| { x: a.x, y })
	} else if a.y == b.y {
		[rect.x, rect.x + rect.width].keep_if(|x| x >= a.x.min(b.x) and x <= a.x.max(b.x) and a.y >= rect.y and a.y <= rect.y + rect.height).map(|x| { x, y: a.y })
	} else {
		[]
	}

	crossing_at = |group, rect, point| {
		side = if point.y == rect.y {
			Top
		} else if point.x == rect.x + rect.width {
			Right
		} else if point.y == rect.y + rect.height {
			Bottom
		} else {
			Left
		}
		offset = match side {
			Top => if rect.width == 0 {
				0
			} else {
				(point.x - rect.x) / rect.width
			}
			Bottom => if rect.width == 0 {
				0
			} else {
				(point.x - rect.x) / rect.width
			}
			Left => if rect.height == 0 {
				0
			} else {
				(point.y - rect.y) / rect.height
			}
			Right => if rect.height == 0 {
				0
			} else {
				(point.y - rect.y) / rect.height
			}
		}
		{ group, point, side, offset }
	}

	route_crossings = |route, groups| {
		points = RouteInternals.route_points(route)
		groups.fold_with_index(
			[],
			|acc, group, group_index| points.fold_with_index(
				acc,
				|found, a, i| match points.get(i + 1) {
					Ok(b) => RouteInternals.segment_crossings(a, b, group.rect).fold(
						found,
						|crossings, point| if crossings.any(|crossing| crossing.group == group_index and crossing.point == point) {
							crossings
						} else {
							crossings.append(RouteInternals.crossing_at(group_index, group.rect, point))
						},
					)
					Err(_) => found
				},
			),
		)
	}

	shared_geometry : Route.SharedEndRule, Route.Input, Route.Settings, List(Geom.Route) -> { junction : Geom.Point, trunk : Geom.Route, branches : List(Geom.Route) }
	shared_geometry = |rule, input, settings, prior| {
		first_index = rule.edges.first() ?? 0
		first_edge = input.graph.edges.get(first_index) ?? { from: 0, to: 0 }
		common_node = match rule.endpoint {
			From => first_edge.from
			To => first_edge.to
		}
		common_center = input.positions.get(common_node) ?? { x: 0, y: 0 }
		common_size = input.graph.nodes.get(common_node) ?? { width: 0, height: 0 }
		opposite_centers = rule.edges.map(
			|edge_index| {
				edge = input.graph.edges.get(edge_index) ?? first_edge
				node = match rule.endpoint {
					From => edge.to
					To => edge.from
				}
				input.positions.get(node) ?? common_center
			},
		)
		count = opposite_centers.len().to_f64()
		centroid = opposite_centers.fold({ x: 0, y: 0 }, |sum, point| { x: sum.x + point.x / count, y: sum.y + point.y / count })
		automatic_side = if (centroid.x - common_center.x).abs() >= (centroid.y - common_center.y).abs() {
			if centroid.x < common_center.x {
				Left
			} else {
				Right
			}
		} else if centroid.y < common_center.y {
			Top
		} else {
			Bottom
		}
		common_outline = RouteInternals.boundary_outline(common_node, input.boundaries)
		common_terminal = match rule.attachment {
			Automatic => RouteInternals.fixed_point(common_center, common_size, automatic_side, 0.5, common_outline)
			On(side) => RouteInternals.fixed_point(common_center, common_size, side, 0.5, common_outline)
			Fixed(payload) => RouteInternals.fixed_point(common_center, common_size, payload.side, payload.offset, common_outline)
		}
		clearance = settings.obstacle_gap + settings.edge_gap
		junction = if common_terminal.outward.x != 0 {
			desired = (common_terminal.point.x + centroid.x) / 2
			{
				x: if common_terminal.outward.x > 0 {
					desired.max(common_terminal.point.x + clearance)
				} else {
					desired.min(common_terminal.point.x - clearance)
				},
				y: common_terminal.point.y,
			}
		} else {
			desired = (common_terminal.point.y + centroid.y) / 2
			{
				x: common_terminal.point.x,
				y: if common_terminal.outward.y > 0 {
					desired.max(common_terminal.point.y + clearance)
				} else {
					desired.min(common_terminal.point.y - clearance)
				},
			}
		}
		common_portals = RouteInternals.edge_portals(first_index, first_edge, input).keep_if(|portal| RouteInternals.node_in_group(common_node, portal.group, input))
		ordered_common = match rule.endpoint {
			From => RouteInternals.reverse_portals(common_portals)
			To => common_portals
		}
		boxes = RouteInternals.obstacles(input, settings, first_edge.from, first_edge.to)
		trunk_forward = ordered_common.fold(
			{ points: [junction], current: junction },
			|state, portal| {
				stops = RouteInternals.portal_stops(portal, settings.obstacle_gap, input)
				leg = RouteInternals.route_leg(state.current, stops.approach, boxes, settings, prior)
				{ points: state.points.concat(leg.drop_first(1)).concat([portal.point, stops.departure]), current: stops.departure }
			},
		)
		approach = { x: common_terminal.point.x + common_terminal.outward.x * settings.obstacle_gap, y: common_terminal.point.y + common_terminal.outward.y * settings.obstacle_gap }
		last = RouteInternals.route_leg(trunk_forward.current, approach, boxes, settings, prior)
		trunk_points = RouteInternals.simplify_preserving(trunk_forward.points.concat(last.drop_first(1)).append(common_terminal.point), ordered_common.map(|portal| portal.point))
		branches = rule.edges.map(
			|edge_index| {
				edge = input.graph.edges.get(edge_index) ?? first_edge
				opposite_endpoint = match rule.endpoint {
					From => To
					To => From
				}
				selected_terminal = RouteInternals.terminal(edge_index, opposite_endpoint, edge, input)
				forward_portals = RouteInternals.edge_portals(edge_index, edge, input).keep_if(|portal| RouteInternals.node_in_group(common_node, portal.group, input) == False)
				portals = match rule.endpoint {
					From => RouteInternals.reverse_portals(forward_portals)
					To => forward_portals
				}
				branch_boxes = RouteInternals.obstacles(input, settings, edge.from, edge.to)
				through = portals.fold(
					{ points: [selected_terminal.point], current: selected_terminal.point },
					|state, portal| {
						stops = RouteInternals.portal_stops(portal, settings.obstacle_gap, input)
						leg = RouteInternals.route_leg(state.current, stops.approach, branch_boxes, settings, prior)
						{ points: state.points.concat(leg.drop_first(1)).concat([portal.point, stops.departure]), current: stops.departure }
					},
				)
				final = RouteInternals.route_leg(through.current, junction, branch_boxes, settings, prior)
				points = RouteInternals.simplify_preserving(through.points.concat(final.drop_first(1)), portals.map(|portal| portal.point))
				if rule.endpoint == From {
					Polyline(RouteInternals.reverse_points(points))
				} else {
					Polyline(points)
				}
			},
		)
		{ junction, trunk: Polyline(trunk_points), branches }
	}

	compute : Route.Input, Route.Settings -> Route.Result
	compute = |input, settings| {
		ranks = EdgeRoutes.parallel_ranks(input.graph.edges)
		independent_routes = input.graph.edges.fold_with_index([], |routes, edge, i| routes.append(RouteInternals.route_one(i, edge, input, settings, ranks.get(i) ?? { rank: 0, count: 1 }, routes)))
		shared = input.shared_ends.fold([], |acc, rule| acc.append(RouteInternals.shared_geometry(rule, input, settings, independent_routes)))
		raw_routes = input.shared_ends.fold_with_index(
			independent_routes,
			|routes, rule, shared_index| {
				geometry = shared.get(shared_index) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				rule.edges.fold_with_index(routes, |updated, edge, branch_index| updated.set(edge, geometry.branches.get(branch_index) ?? Polyline([])) ?? [])
			},
		)
		label_routes = input.shared_ends.fold_with_index(
			raw_routes,
			|routes, rule, shared_index| {
				geometry = shared.get(shared_index) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				rule.edges.fold(routes, |updated, edge| updated.set(edge, RouteInternals.join_shared(updated.get(edge) ?? Polyline([]), geometry.trunk, rule.endpoint)) ?? [])
			},
		)
		placed_labels = input.edge_labels.fold(
			[],
			|placed, label| {
				base = RouteInternals.anchor_for(label_routes.get(label.edge) ?? Polyline([]), label.placement)
				candidates = RouteInternals.label_candidates(label_routes.get(label.edge) ?? Polyline([]), label.placement, label.width, label.height, settings)
				point = candidates.find_first(|p| RouteInternals.label_clear(p, label, input, settings, placed, label_routes)) ?? {
					node_top = input.positions.fold_with_index(
						base.y,
						|top, p, i| {
							node = input.graph.nodes.get(i) ?? { width: 0, height: 0 }
							top.min(p.y - node.height / 2)
						},
					)
					route_top = label_routes.fold(node_top, |top, route| RouteInternals.route_points(route).fold(top, |m, p| m.min(p.y)))
					clear_top = placed.fold(route_top, |top, old| top.min(old.point.y - old.height / 2 - settings.obstacle_gap))
					{ x: base.x, y: clear_top - label.height / 2 - settings.obstacle_gap - settings.edge_gap }
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
		route_box = raw_routes.concat(shared.map(|item| item.trunk)).fold(node_box, |box, route| RouteInternals.route_points(route).fold(box, |b, p| { min_x: b.min_x.min(p.x), min_y: b.min_y.min(p.y), max_x: b.max_x.max(p.x), max_y: b.max_y.max(p.y) }))
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
		independent_attachments = input.graph.edges.map_with_index(
			|edge, i| {
				from = RouteInternals.terminal(i, From, edge, input)
				to = RouteInternals.terminal(i, To, edge, input)
				{ from: { point: shift(from.point), side: from.side }, to: { point: shift(to.point), side: to.side } }
			},
		)
		attachments = input.shared_ends.fold_with_index(
			independent_attachments,
			|all, rule, shared_index| {
				geometry = shared.get(shared_index) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				trunk_points = RouteInternals.route_points(geometry.trunk)
				common_point = trunk_points.last() ?? geometry.junction
				before_common = trunk_points.drop_last(1).last() ?? geometry.junction
				selected_side = if before_common.x < common_point.x {
					Left
				} else if before_common.x > common_point.x {
					Right
				} else if before_common.y < common_point.y {
					Top
				} else {
					Bottom
				}
				rule.edges.fold(
					all,
					|updated, edge_index| {
						old = updated.get(edge_index) ?? { from: { point: common_point, side: selected_side }, to: { point: common_point, side: selected_side } }
						next = match rule.endpoint {
							From => { ..old, from: { point: shift(common_point), side: selected_side } }
							To => { ..old, to: { point: shift(common_point), side: selected_side } }
						}
						updated.set(edge_index, next) ?? []
					},
				)
			},
		)
		group_crossings = raw_routes.map_with_index(
			|route, edge_index| {
				edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
				portals = RouteInternals.edge_portals(edge_index, edge, input)
				RouteInternals.route_crossings(route, input.groups).map(
					|crossing| match portals.find_first(|portal| portal.group == crossing.group and portal.point == crossing.point) {
						Ok(portal) => { group: portal.group, point: shift(portal.point), side: portal.side, offset: portal.offset }
						Err(_) => { ..crossing, point: shift(crossing.point) }
					},
				)
			},
		)
		groups = input.groups.map(|group| { x: Geom.saturate(group.rect.x + dx), y: Geom.saturate(group.rect.y + dy), width: group.rect.width, height: group.rect.height })
		shared_routes = input.shared_ends.map_with_index(
			|rule, i| {
				geometry = shared.get(i) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				{ edges: rule.edges, endpoint: rule.endpoint, junction: shift(geometry.junction), trunk: shift_route(geometry.trunk), group_crossings: RouteInternals.route_crossings(geometry.trunk, input.groups).map(|crossing| { ..crossing, point: shift(crossing.point) }) }
			},
		)
		{ layout: { positions: input.positions.map(shift), routes: raw_routes.map(shift_route), bounds: { ..Geom.empty_bounds, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) } }, groups, label_anchors: raw_labels.map(shift), attachments, group_crossings, shared_routes }
	}
}

## Placement-independent routing for an already positioned, sized graph.
## `layout` produces deterministic axis-aligned polylines, honors sparse
## attachment rules, separates parallel edges into stable tracks, gives
## self-loops exterior paths, and returns one anchor for every sparse edge
## label in label input order. Labels may be centered on an edge or placed
## near either end, so relationship names, roles, and multiplicities can be
## positioned without putting text or styling into the geometry API. Group
## attachments are exact boundary crossings: routes approach and leave them
## perpendicularly instead of following the group outline.
##
## Nodes use their rectangular size as their boundary by default. A sparse
## boundary rule makes attachment points follow an ellipse inside the same
## sized box; routing still treats that box as the node's obstacle.
##
## A sparse group attachment constrains where a cross-group edge crosses one
## boundary. Automatic chooses a side facing the other endpoint, `On` chooses
## the middle of one side, and `Fixed` chooses a normalized offset along it.
## Nested constraints are crossed in ancestry order and every resulting leg
## is routed around obstacles.
##
## A shared-end rule gives two or more edges one intentional junction at a
## node they have in common and selects the shared trunk's node attachment.
## Member edges must not repeat an attachment rule at that common end. Their
## index-aligned edge routes stop at the
## junction; `shared_routes` contains the single trunk to draw from the
## junction to the common node. This represents UML generalization and other
## converging relationships without drawing coincident independent edges.
Route :: {}.{
	Side : [Top, Right, Bottom, Left]
	Endpoint : [From, To]
	Attachment : [Automatic, On(Side), Fixed({ side : Side, offset : F64 })]
	AttachmentRule : { edge : U64, endpoint : Endpoint, attachment : Attachment }
	Outline : [Rectangle, Ellipse]
	BoundaryRule : { node : U64, outline : Outline }
	Group : { rect : Geom.Rect, parent : [Root, Parent(U64)] }
	Membership : { node : U64, group : U64 }
	GroupAttachmentRule : { edge : U64, group : U64, attachment : Attachment }
	LabelPlacement : [Center, Near(Endpoint)]
	EdgeLabel : { edge : U64, width : F64, height : F64, placement : LabelPlacement }
	SharedEndRule : { edges : List(U64), endpoint : Endpoint, attachment : Attachment }

	Input : { graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }, positions : List({ x : F64, y : F64 }), groups : List(Group), memberships : List(Membership), attachments : List(AttachmentRule), group_attachments : List(GroupAttachmentRule), boundaries : List(BoundaryRule), edge_labels : List(EdgeLabel), shared_ends : List(SharedEndRule) }

	## `obstacle_gap` is the empty space kept around node and group boxes. `edge_gap`
	## separates parallel edges. `bend_penalty` favors fewer turns over a
	## shorter path, while `shared_path_penalty` favors a distinct corridor over
	## one already used by earlier edges. All four values use layout units;
	## zero disables the corresponding spacing or preference.
	Settings : { obstacle_gap : F64, bend_penalty : F64, shared_path_penalty : F64, edge_gap : F64 }
	SelectedAttachment : { point : Geom.Point, side : Side }
	EdgeAttachments : { from : SelectedAttachment, to : SelectedAttachment }
	GroupCrossing : { group : U64, point : Geom.Point, side : Side, offset : F64 }
	SharedRoute : { edges : List(U64), endpoint : Endpoint, junction : Geom.Point, trunk : Geom.Route, group_crossings : List(GroupCrossing) }
	Result : { layout : { positions : List(Geom.Point), routes : List(Geom.Route), bounds : Geom.Rect }, groups : List(Geom.Rect), label_anchors : List(Geom.Point), attachments : List(EdgeAttachments), group_crossings : List(List(GroupCrossing)), shared_routes : List(SharedRoute) }
	Problem := [InvalidNodeWidth(U64), InvalidNodeHeight(U64), PositionCountMismatch, InvalidPosition(U64), InvalidEdgeFrom(U64), InvalidEdgeTo(U64), InvalidAttachmentEdge(U64), InvalidAttachmentOffset(U64), DuplicateAttachment(U64), InvalidGroupRect(U64), InvalidGroupParent(U64), InvalidMembershipNode(U64), InvalidMembershipGroup(U64), DuplicateMembership(U64), InvalidBoundaryNode(U64), DuplicateBoundary(U64), InvalidGroupAttachmentEdge(U64), InvalidGroupAttachmentGroup(U64), InvalidGroupAttachmentOffset(U64), DuplicateGroupAttachment(U64), GroupAttachmentNotBoundary(U64), InvalidLabelEdge(U64), InvalidLabelWidth(U64), InvalidLabelHeight(U64), SharedEndNeedsEdges(U64), InvalidSharedEndEdge(U64), DuplicateSharedEndEdge(U64), InvalidSharedEndAttachmentOffset(U64), SharedEndMismatch(U64), SharedEndMemberAttachment(U64), SharedEndOverlap(U64), InvalidObstacleGap, InvalidBendPenalty, InvalidSharedPathPenalty, InvalidEdgeGap].{

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
			InvalidBoundaryNode(rule) => "Boundary rule ${rule.to_str()} refers to a node that does not exist."
			DuplicateBoundary(rule) => "Boundary rule ${rule.to_str()} repeats a rule for the same node."
			InvalidGroupAttachmentEdge(rule) => "Group attachment ${rule.to_str()} refers to an edge that does not exist."
			InvalidGroupAttachmentGroup(rule) => "Group attachment ${rule.to_str()} refers to a group that does not exist."
			InvalidGroupAttachmentOffset(rule) => "Group attachment ${rule.to_str()} has an offset outside the range from 0 to 1."
			DuplicateGroupAttachment(rule) => "Group attachment ${rule.to_str()} repeats a rule for the same edge and group."
			GroupAttachmentNotBoundary(rule) => "Group attachment ${rule.to_str()} must name a group containing exactly one end of its edge."
			InvalidLabelEdge(label) => "Edge label ${label.to_str()} refers to an edge that does not exist."
			InvalidLabelWidth(label) => "Edge label ${label.to_str()} has a width that is negative or not finite."
			InvalidLabelHeight(label) => "Edge label ${label.to_str()} has a height that is negative or not finite."
			SharedEndNeedsEdges(rule) => "Shared end ${rule.to_str()} must contain at least two edges."
			InvalidSharedEndEdge(rule) => "Shared end ${rule.to_str()} refers to an edge that does not exist."
			DuplicateSharedEndEdge(rule) => "Shared end ${rule.to_str()} repeats an edge."
			SharedEndMismatch(rule) => "Every edge in shared end ${rule.to_str()} must have the same node at the selected end."
			InvalidSharedEndAttachmentOffset(rule) => "Shared end ${rule.to_str()} has an attachment offset outside the range from 0 to 1."
			SharedEndMemberAttachment(rule) => "Shared end ${rule.to_str()} conflicts with a member edge attachment at the common node; set the attachment on the shared end only."
			SharedEndOverlap(rule) => "Shared end ${rule.to_str()} contains an edge already used by an earlier shared end."
			InvalidObstacleGap => "The obstacle gap must be a finite number that is zero or greater."
			InvalidBendPenalty => "The bend penalty must be a finite number that is zero or greater."
			InvalidSharedPathPenalty => "The shared-path penalty must be a finite number that is zero or greater."
			InvalidEdgeGap => "The edge gap must be a finite number that is zero or greater."
		}
	}

	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, positions: [], groups: [], memberships: [], attachments: [], group_attachments: [], boundaries: [], edge_labels: [], shared_ends: [] }

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

expect Route.layout(Route.default_input, Route.default_settings) == Ok({ layout: { positions: [], routes: [], bounds: Geom.empty_bounds }, groups: [], label_anchors: [], attachments: [], group_crossings: [], shared_routes: [] })

## Shared ends return one trunk while their source-aligned branch routes meet
## at exactly one junction. The default remains opt-in and empty.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 12, height: 12 }, { width: 12, height: 12 }, { width: 16, height: 12 }], edges: [{ from: 0, to: 2 }, { from: 1, to: 2 }] },
		positions: [{ x: 0, y: 80 }, { x: 80, y: 80 }, { x: 40, y: 0 }],
		shared_ends: [{ edges: [0, 1], endpoint: To, attachment: On(Bottom) }],
	}
	match Route.layout(input, Route.default_settings) {
		Ok(result) => match result.shared_routes.first() {
			Ok(shared) => {
				branch_ends = result.layout.routes.map(|route| RouteInternals.route_points(route).last())
				trunk = RouteInternals.route_points(shared.trunk)
				to_point = match result.attachments.get(0) {
					Ok(ends) => Ok(ends.to.point)
					Err(_) => Err(NoAttachment)
				}
				final_approach = match (trunk.drop_last(1).last(), trunk.last(), result.attachments.get(0)) {
					(Ok(before), Ok(at_node), Ok(ends)) => before.x == at_node.x and before.y > at_node.y and ends.to.side == Bottom
					_ => False
				}
				branch_ends == [Ok(shared.junction), Ok(shared.junction)] and trunk.first() == Ok(shared.junction) and trunk.last() == to_point and final_approach
			}
			Err(_) => False
		}
		Err(_) => False
	}
}

## A shared end owns its common attachment. Invalid shared offsets and
## ambiguous member-edge rules are reported together in shared-rule order.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 10 }, 3), edges: [{ from: 0, to: 2 }, { from: 1, to: 2 }] },
		positions: [{ x: 0, y: 40 }, { x: 40, y: 40 }, { x: 20, y: 0 }],
		attachments: [{ edge: 0, endpoint: To, attachment: On(Bottom) }],
		shared_ends: [{ edges: [0, 1], endpoint: To, attachment: Fixed({ side: Bottom, offset: 2 }) }],
	}
	Route.layout(input, Route.default_settings) == Err([InvalidSharedEndAttachmentOffset(0), SharedEndMemberAttachment(0)])
}

## Labels on an ordinary association remain near that edge when separate
## inheritance edges use a shared trunk. Normal candidates expand locally
## before the final exterior fallback, and label order remains input-aligned.
expect {
	input = {
		..Route.default_input,
		graph: {
			nodes: [{ width: 120, height: 48 }, { width: 120, height: 48 }, { width: 120, height: 48 }, { width: 120, height: 48 }, { width: 112, height: 64 }],
			edges: [{ from: 1, to: 0 }, { from: 2, to: 0 }, { from: 3, to: 0 }, { from: 4, to: 1 }],
		},
		positions: [{ x: 220, y: 40 }, { x: 140, y: 240 }, { x: 280, y: 240 }, { x: 420, y: 240 }, { x: 0, y: 240 }],
		edge_labels: [{ edge: 3, width: 54, height: 18, placement: Center }, { edge: 3, width: 18, height: 18, placement: Near(From) }, { edge: 3, width: 26, height: 18, placement: Near(To) }],
		shared_ends: [{ edges: [0, 1, 2], endpoint: To, attachment: On(Bottom) }],
	}
	match Route.layout(input, Route.default_settings) {
		Err(_) => False
		Ok(result) => {
			association_from = result.layout.positions.get(4) ?? { x: 0, y: 0 }
			association_to = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			edge_y = (association_from.y + association_to.y) / 2
			near_edge = result.label_anchors.all(|anchor| (anchor.y - edge_y).abs() <= 120)
			association = result.layout.routes.get(3) ?? Polyline([])
			local = input.edge_labels.fold_with_index(
				True,
				|ok, label, i| {
					anchor = result.label_anchors.get(i) ?? { x: F64.infinity, y: F64.infinity }
					desired = RouteInternals.anchor_for(association, label.placement)
					ok and (anchor.x - desired.x).abs() + (anchor.y - desired.y).abs() <= 120
				},
			)
			inside = result.label_anchors.fold_with_index(
				True,
				|ok, anchor, i| {
					label = input.edge_labels.get(i) ?? { edge: 0, width: 0, height: 0, placement: Center }
					ok and anchor.x - label.width / 2 >= 0 and anchor.y - label.height / 2 >= 0 and anchor.x + label.width / 2 <= result.layout.bounds.width and anchor.y + label.height / 2 <= result.layout.bounds.height
				},
			)
			result.label_anchors.len() == 3 and near_edge and local and inside
		}
	}
}

expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }], attachments: [{ edge: 0, endpoint: From, attachment: Fixed({ side: Right, offset: 0.5 }) }], edge_labels: [{ edge: 0, width: 8, height: 4, placement: Center }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => result.layout.routes.len() == 1 and result.label_anchors.len() == 1
		Err(_) => False
	}
}

## Nested group attachments are applied in ancestry order even when their
## sparse rules arrive in the opposite order. Each selected portal is retained
## as a route point and reported with its side and normalized offset.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] },
		positions: [{ x: 30, y: 40 }, { x: 150, y: 40 }, { x: 85, y: 50 }],
		groups: [{ rect: { x: 0, y: 0, width: 100, height: 100 }, parent: Root }, { rect: { x: 10, y: 10, width: 60, height: 60 }, parent: Parent(0) }],
		memberships: [{ node: 0, group: 1 }],
		group_attachments: [{ edge: 0, group: 0, attachment: Fixed({ side: Right, offset: 0.75 }) }, { edge: 0, group: 1, attachment: Fixed({ side: Right, offset: 0.25 }) }],
	}
	match Route.layout(input, Route.default_settings) {
		Err(_) => False
		Ok(result) => match result.layout.routes.first() {
			Ok(Polyline(points)) => {
				outer = result.groups.get(0) ?? Geom.empty_bounds
				inner = result.groups.get(1) ?? Geom.empty_bounds
				inner_portal = { x: inner.x + inner.width, y: inner.y + inner.height * 0.25 }
				outer_portal = { x: outer.x + outer.width, y: outer.y + outer.height * 0.75 }
				inner_index = points.find_first_index(|point| point == inner_portal)
				outer_index = points.find_first_index(|point| point == outer_portal)
				inner_crossing = (result.group_crossings.first() ?? []).find_first(|crossing| crossing.group == 1 and crossing.point == inner_portal)
				outer_crossing = (result.group_crossings.first() ?? []).find_first(|crossing| crossing.group == 0 and crossing.point == outer_portal)
				blocker = result.layout.positions.get(2) ?? { x: 0, y: 0 }
				blocker_box = { min_x: blocker.x - 5 - Route.default_settings.obstacle_gap, min_y: blocker.y - 5 - Route.default_settings.obstacle_gap, max_x: blocker.x + 5 + Route.default_settings.obstacle_gap, max_y: blocker.y + 5 + Route.default_settings.obstacle_gap }
				clear = points.fold_with_index(
					True,
					|ok, point, i| match points.get(i + 1) {
						Ok(next) => ok and RouteInternals.segment_hits(point, next, blocker_box) == False
						Err(_) => ok
					},
				)
				crosses_perpendicularly = |index, portal| if index == 0 or index + 1 >= points.len() {
					False
				} else {
					before = points.get(index - 1) ?? portal
					after = points.get(index + 1) ?? portal
					before.y == portal.y and after.y == portal.y and before.x < portal.x and after.x > portal.x
				}
				match (inner_index, outer_index, inner_crossing, outer_crossing) {
					(Ok(a), Ok(b), Ok(ic), Ok(oc)) => clear and a < b and crosses_perpendicularly(a, inner_portal) and crosses_perpendicularly(b, outer_portal) and ic.side == Right and ic.offset == 0.25 and oc.side == Right and oc.offset == 0.75
					_ => False
				}
			}
			_ => False
		}
	}
}

## All independent group-attachment problems are reported in sparse-rule
## order, including a valid group that does not separate the edge endpoints.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 1, height: 1 }, { width: 1, height: 1 }], edges: [{ from: 0, to: 1 }] },
		positions: [{ x: 0, y: 0 }, { x: 1, y: 1 }],
		groups: [{ rect: { x: 0, y: 0, width: 10, height: 10 }, parent: Root }],
		memberships: [{ node: 0, group: 0 }, { node: 1, group: 0 }],
		group_attachments: [{ edge: 9, group: 9, attachment: Fixed({ side: Top, offset: 2 }) }, { edge: 0, group: 0, attachment: Automatic }, { edge: 0, group: 0, attachment: On(Left) }],
	}
	Route.layout(input, Route.default_settings) == Err([InvalidGroupAttachmentEdge(0), InvalidGroupAttachmentGroup(0), InvalidGroupAttachmentOffset(0), GroupAttachmentNotBoundary(1), DuplicateGroupAttachment(2), GroupAttachmentNotBoundary(2)])
}

## A degenerate group boundary still has a finite, defined portal. An offset
## along a zero-length side is reported as zero.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 0, height: 0 }, { width: 0, height: 0 }], edges: [{ from: 0, to: 1 }] },
		positions: [{ x: 0, y: 0 }, { x: 20, y: 20 }],
		groups: [{ rect: { x: 5, y: 5, width: 0, height: 10 }, parent: Root }],
		memberships: [{ node: 0, group: 0 }],
		group_attachments: [{ edge: 0, group: 0, attachment: Fixed({ side: Top, offset: 0.7 }) }],
	}
	match Route.layout(input, Route.default_settings) {
		Ok(result) => match (result.group_crossings.first() ?? []).find_first(|crossing| crossing.group == 0) {
			Ok(crossing) => crossing.side == Top and crossing.offset == 0 and F64.is_finite(crossing.point.x) and F64.is_finite(crossing.point.y)
			Err(_) => False
		}
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
	input = { ..Route.default_input, graph: { nodes: [{ width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }], edges: [{ from: 0, to: 1 }, { from: 2, to: 3 }] }, positions: [{ x: 0, y: 0 }, { x: 60, y: 60 }, { x: 0, y: 60 }, { x: 60, y: 0 }], edge_labels: [{ edge: 0, width: 20, height: 10, placement: Center }, { edge: 1, width: 20, height: 10, placement: Center }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) =>
			match (result.label_anchors.get(0), result.label_anchors.get(1)) {
				(Ok(a), Ok(b)) => a != b
				_ => False
			}
		Err(_) => False
	}
}

## Several labels may describe one edge. Their anchors remain aligned with
## label input order, and endpoint roles choose opposite parts of the route.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 200, y: 0 }], edge_labels: [{ edge: 0, width: 12, height: 6, placement: Near(From) }, { edge: 0, width: 24, height: 8, placement: Center }, { edge: 0, width: 12, height: 6, placement: Near(To) }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => match (result.label_anchors.get(0), result.label_anchors.get(1), result.label_anchors.get(2)) {
			(Ok(from_label), Ok(center_label), Ok(to_label)) => from_label.x < center_label.x and center_label.x < to_label.x
			_ => False
		}
		Err(_) => False
	}
}

## Ellipse attachments follow the curved boundary for automatic and fixed
## endpoints while keeping a cardinal departure side for orthogonal routing.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 20, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }], boundaries: [{ node: 0, outline: Ellipse }], attachments: [{ edge: 0, endpoint: From, attachment: Fixed({ side: Right, offset: 0.75 }) }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => match result.attachments.first() {
			Ok(ends) => {
				local_x = ends.from.point.x - (result.layout.positions.first() ?? Geom.point(0, 0)).x
				local_y = ends.from.point.y - (result.layout.positions.first() ?? Geom.point(0, 0)).y
				(local_x * local_x) / 100 + (local_y * local_y) / 25 > 0.999999 and (local_x * local_x) / 100 + (local_y * local_y) / 25 < 1.000001 and ends.from.side == Right
			}
			Err(_) => False
		}
		Err(_) => False
	}
}

## Side-only and automatic ellipse attachments use the same declared outline.
expect {
	base = { ..Route.default_input, graph: { nodes: [{ width: 20, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [{ x: 0, y: 0 }, { x: 40, y: 20 }], boundaries: [{ node: 0, outline: Ellipse }] }
	edge = base.graph.edges.first() ?? { from: 0, to: 1 }
	automatic = RouteInternals.terminal(0, From, edge, base)
	on_top = RouteInternals.terminal(0, From, edge, { ..base, attachments: [{ edge: 0, endpoint: From, attachment: On(Top) }] })
	automatic_value = (automatic.point.x * automatic.point.x) / 100 + (automatic.point.y * automatic.point.y) / 25
	automatic_value > 0.999999 and automatic_value < 1.000001 and on_top.point == { x: 0, y: 0 - 5.0 } and on_top.side == Top
}

## Boundary problems are aggregated and identify positions in the sparse
## rule list, including a repeated rule for an otherwise valid node.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }], edges: [] }, positions: [{ x: 0, y: 0 }], boundaries: [{ node: 4, outline: Ellipse }, { node: 0, outline: Ellipse }, { node: 0, outline: Rectangle }] }
	Route.layout(input, Route.default_settings) == Err([InvalidBoundaryNode(0), DuplicateBoundary(2)])
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
