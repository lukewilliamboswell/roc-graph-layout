import EdgeRoutes
import Geom
import RouteGrid
import RouteIndex
import RouteLanes
import RoutePorts
import RouteSort

## Internal implementation for the placement-independent orthogonal router.
RouteInternals :: {}.{
	Terminal : { point : Geom.Point, outward : Geom.Point, side : Route.Side }
	Bounds : { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }
	Portal : { group : U64, point : Geom.Point, outward : Geom.Point, side : Route.Side, offset : F64, leaving : Bool }
	View : { from : U64, to : U64, endpoints : Bool }
	Prior : { segments : RouteIndex.Segments, excluded : U64 }
	Context : {
		input : Route.Input,
		settings : Route.Settings,
		from_terminals : List(Terminal),
		to_terminals : List(Terminal),
		chains : List(List(U64)),
		waypoints : List(List(Geom.Point)),
		guides : List(List(Geom.Point)),
		portals : List(List(Portal)),
		crosses_boundary : List(Bool),
		node_boxes : List(Bounds),
		group_boxes : List(Bounds),
		obstacles : RouteIndex.Boxes,
		grid : RouteIndex.Grid,
	}

	zero_distance : F64
	zero_distance = 0
	zero_count : U64
	zero_count = 0

	finite_point : { x : F64, y : F64 } -> Bool
	finite_point = |p| F64.is_finite(p.x) and F64.is_finite(p.y)

	problems : Route.Input, Route.Settings -> List(Route.Problem)
	problems = |input, settings| {
		# Repeated rules are found by sorting, not by comparing every pair.
		attachment_at = |i| input.attachments.get(i) ?? { edge: 0, endpoint: From, attachment: Automatic }
		repeated_attachment = RouteInternals.repeated(
			input.attachments.len(),
			|a, b| (attachment_at(a)).edge < (attachment_at(b)).edge or ((attachment_at(a)).edge == (attachment_at(b)).edge and RouteInternals.endpoint_index((attachment_at(a)).endpoint) < RouteInternals.endpoint_index((attachment_at(b)).endpoint)),
			|a, b| (attachment_at(a)).edge == (attachment_at(b)).edge and (attachment_at(a)).endpoint == (attachment_at(b)).endpoint,
		)
		membership_node = |i| (input.memberships.get(i) ?? { node: 0, group: 0 }).node
		repeated_membership = RouteInternals.repeated(input.memberships.len(), |a, b| membership_node(a) < membership_node(b), |a, b| membership_node(a) == membership_node(b))
		boundary_node = |i| (input.boundaries.get(i) ?? { node: 0, outline: Rectangle }).node
		repeated_boundary = RouteInternals.repeated(input.boundaries.len(), |a, b| boundary_node(a) < boundary_node(b), |a, b| boundary_node(a) == boundary_node(b))
		group_rule_at = |i| input.group_attachments.get(i) ?? { edge: 0, group: 0, attachment: Automatic }
		repeated_group_attachment = RouteInternals.repeated(
			input.group_attachments.len(),
			|a, b| (group_rule_at(a)).edge < (group_rule_at(b)).edge or ((group_rule_at(a)).edge == (group_rule_at(b)).edge and (group_rule_at(a)).group < (group_rule_at(b)).group),
			|a, b| (group_rule_at(a)).edge == (group_rule_at(b)).edge and (group_rule_at(a)).group == (group_rule_at(b)).group,
		)
		waypoint_edge = |i| (input.waypoints.get(i) ?? { edge: 0, points: [] }).edge
		repeated_waypoints = RouteInternals.repeated(input.waypoints.len(), |a, b| waypoint_edge(a) < waypoint_edge(b), |a, b| waypoint_edge(a) == waypoint_edge(b))
		guide_edge = |i| (input.guides.get(i) ?? { edge: 0, points: [] }).edge
		repeated_guides = RouteInternals.repeated(input.guides.len(), |a, b| guide_edge(a) < guide_edge(b), |a, b| guide_edge(a) == guide_edge(b))
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
				duplicate = repeated_attachment.get(i) ?? False
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
				duplicate = repeated_membership.get(i) ?? False
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
				duplicate = repeated_boundary.get(i) ?? False
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
				duplicate = repeated_group_attachment.get(i) ?? False
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
		p6a = input.waypoints.fold_with_index(
			p6,
			|acc, rule, i| {
				a = if rule.edge < input.graph.edges.len() {
					acc
				} else {
					acc.append(InvalidWaypointEdge(i))
				}
				b = if rule.points.all(|point| RouteInternals.finite_point(point)) {
					a
				} else {
					a.append(InvalidWaypoint(i))
				}
				duplicate = repeated_waypoints.get(i) ?? False
				c = if duplicate {
					b.append(DuplicateWaypoints(i))
				} else {
					b
				}
				blocked = if rule.edge < input.graph.edges.len() and rule.points.all(|point| RouteInternals.finite_point(point)) and F64.is_finite(settings.obstacle_gap) and settings.obstacle_gap >= 0 {
					edge = input.graph.edges.get(rule.edge) ?? { from: 0, to: 0 }
					boxes = RouteInternals.obstacles(input, settings, edge.from, edge.to)
					rule.points.any(|point| RouteInternals.point_blocked(point, boxes))
				} else {
					False
				}
				if blocked {
					c.append(BlockedWaypoint(i))
				} else {
					c
				}
			},
		)
		p6g = input.guides.fold_with_index(
			p6a,
			|acc, rule, i| {
				a = if rule.edge < input.graph.edges.len() {
					acc
				} else {
					acc.append(InvalidGuideEdge(i))
				}
				b = if rule.points.all(|point| RouteInternals.finite_point(point)) {
					a
				} else {
					a.append(InvalidGuide(i))
				}
				duplicate = repeated_guides.get(i) ?? False
				if duplicate {
					b.append(DuplicateGuides(i))
				} else {
					b
				}
			},
		)
		p6b = input.shared_ends.fold_with_index(
			p6g,
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

	reverse_items = |items| items.fold([], |acc, item| [item].concat(acc))

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

	terminal_for : Route.Endpoint, { from : U64, to : U64 }, Route.Input, Route.Attachment, Route.Outline -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 }, side : Route.Side }
	terminal_for = |endpoint, edge, input, rule, node_outline| {
		node = match endpoint {
			From => edge.from
			To => edge.to
		}
		center = input.positions.get(node) ?? { x: 0, y: 0 }
		size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
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

	terminal : U64, Route.Endpoint, { from : U64, to : U64 }, Route.Input -> { point : { x : F64, y : F64 }, outward : { x : F64, y : F64 }, side : Route.Side }
	terminal = |edge_index, endpoint, edge, input| {
		node = match endpoint {
			From => edge.from
			To => edge.to
		}
		RouteInternals.terminal_for(endpoint, edge, input, RouteInternals.attachment_rule(edge_index, endpoint, input.attachments), RouteInternals.boundary_outline(node, input.boundaries))
	}

	escape_point = |selected, node, input, gap| {
		center = input.positions.get(node) ?? selected.point
		size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
		match selected.side {
			Top => { x: selected.point.x, y: center.y - size.height / 2 - gap }
			Right => { x: center.x + size.width / 2 + gap, y: selected.point.y }
			Bottom => { x: selected.point.x, y: center.y + size.height / 2 + gap }
			Left => { x: center.x - size.width / 2 - gap, y: selected.point.y }
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

	coordinate_on = |point, side| match side {
		Top | Bottom => point.x
		Left | Right => point.y
	}

	edge_order_key = |edge, side, input| {
		to = input.positions.get(edge.to) ?? { x: 0, y: 0 }
		from = input.positions.get(edge.from) ?? { x: 0, y: 0 }
		{ primary: RouteInternals.coordinate_on(to, side), secondary: RouteInternals.coordinate_on(from, side) }
	}

	port_order = |a, b| if a.primary < b.primary {
		Before
	} else if a.primary > b.primary {
		After
	} else if a.secondary < b.secondary {
		Before
	} else if a.secondary > b.secondary {
		After
	} else if a.edge < b.edge {
		Before
	} else if a.edge > b.edge {
		After
	} else if a.role < b.role {
		Before
	} else if a.role > b.role {
		After
	} else {
		Same
	}

	flex_offset_at = |count, rank, length, gap| {
		if length <= 0 {
			0.5
		} else if count <= 1 {
			0.5
		} else {
			margin = gap.min(length / (count + 1).to_f64())
			available = (length - margin * 2).max(0)
			actual_gap = gap.min(available / (count - 1).to_f64())
			start = (length - actual_gap * (count - 1).to_f64()) / 2
			(start + actual_gap * rank.to_f64()) / length
		}
	}

	side_index = |side| match side {
		Top => 0.U64
		Right => 1.U64
		Bottom => 2.U64
		Left => 3.U64
	}

	fan_point = |point, selected, fan, gap| {
		track = (fan.rank.to_f64() - (fan.count - 1).to_f64() / 2) * gap
		if selected.outward.x == 0 {
			{ x: point.x + track, y: point.y }
		} else {
			{ x: point.x, y: point.y + track }
		}
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

	proper_segment_intersection = |a, b, c, d| {
		if a.x == b.x and c.y == d.y {
			c.x > a.x.min(b.x) and c.x < a.x.max(b.x) and a.y > c.y.min(d.y) and a.y < c.y.max(d.y)
		} else if a.y == b.y and c.x == d.x {
			a.x > c.x.min(d.x) and a.x < c.x.max(d.x) and c.y > a.y.min(b.y) and c.y < a.y.max(b.y)
		} else if a.x == b.x and c.x == d.x and a.x == c.x {
			a.y.min(b.y) < c.y.max(d.y) and a.y.max(b.y) > c.y.min(d.y)
		} else if a.y == b.y and c.y == d.y and a.y == c.y {
			a.x.min(b.x) < c.x.max(d.x) and a.x.max(b.x) > c.x.min(d.x)
		} else {
			False
		}
	}

	simple_path = |points| points.fold_with_index(
		True,
		|simple, a, i| match points.get(i + 1) {
			Err(_) => simple
			Ok(b) => points.fold_with_index(
				simple,
				|clear, c, j| if j <= i + 1 {
					clear
				} else {
					match points.get(j + 1) {
						Ok(d) => clear and !RouteInternals.proper_segment_intersection(a, b, c, d)
						Err(_) => clear
					}
				},
			)
		},
	)

	overlaps_box : { x : F64, y : F64 }, F64, F64, { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }, F64 -> Bool
	overlaps_box = |p, width, height, box, gap| p.x + width / 2 + gap > box.min_x and p.x - width / 2 - gap < box.max_x and p.y + height / 2 + gap > box.min_y and p.y - height / 2 - gap < box.max_y

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

	label_candidates = |route, placement, _width, _height, _settings| {
		fractions = match placement {
			Near(From) => [0.15, 0.22, 0.30, 0.38, 0.46]
			Near(To) => [0.85, 0.78, 0.70, 0.62, 0.54]
			Center => [0.50, 0.42, 0.58, 0.34, 0.66]
		}
		fractions.map(|fraction| RouteInternals.anchor_fraction(route, fraction))
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

	proper_crossing = |a, b, c, d| if a.x == b.x and c.y == d.y {
		c.x.min(d.x) < a.x and a.x < c.x.max(d.x) and a.y.min(b.y) < c.y and c.y < a.y.max(b.y)
	} else if a.y == b.y and c.x == d.x {
		a.x.min(b.x) < c.x and c.x < a.x.max(b.x) and c.y.min(d.y) < a.y and a.y < c.y.max(d.y)
	} else {
		False
	}

	shared_length = |a, b, c, d| if a.y == b.y and c.y == d.y and a.y == c.y {
		(a.x.max(b.x).min(c.x.max(d.x)) - a.x.min(b.x).max(c.x.min(d.x))).max(0)
	} else if a.x == b.x and c.x == d.x and a.x == c.x {
		(a.y.max(b.y).min(c.y.max(d.y)) - a.y.min(b.y).max(c.y.min(d.y))).max(0)
	} else {
		0
	}

	stats_better = |a, b| if a.crossings < b.crossings {
		True
	} else if a.crossings > b.crossings {
		False
	} else if a.shared < b.shared {
		True
	} else if a.shared > b.shared {
		False
	} else if a.bends < b.bends {
		True
	} else if a.bends > b.bends {
		False
	} else {
		a.length < b.length
	}

	no_edge : U64
	no_edge = U64.highest

	endpoint_index = |endpoint| match endpoint {
		From => 0.U64
		To => 1.U64
	}

	## For each slot, the position of the first item that `slot_of` assigns to
	## it, or `no_edge`. Items assigned to no slot below `slots` are skipped.
	first_in_slot : U64, List(a), (a -> U64) -> List(U64)
	first_in_slot = |slots, items, slot_of| {
		var $first = List.repeat(RouteInternals.no_edge, slots)
		var $position = 0
		for item in items {
			slot = slot_of(item)
			if slot < slots and ($first.get(slot) ?? 0) == RouteInternals.no_edge {
				$first = $first.set(slot, $position) ?? []
			}
			$position = $position + 1
		}
		$first
	}

	## Item positions grouped by slot, each group in item order: slot `s` owns
	## `entries[offsets[s]..offsets[s + 1]]`.
	slot_lists : U64, List(a), (a -> U64) -> { offsets : List(U64), entries : List(U64) }
	slot_lists = |slots, items, slot_of| {
		item_slots = items.map(slot_of)
		var $counts = List.repeat(0, slots + 1)
		for slot in item_slots {
			if slot < slots {
				$counts = $counts.set(slot, ($counts.get(slot) ?? 0) + 1) ?? []
			}
		}
		var $offsets = List.with_capacity(slots + 1)
		var $total = 0
		for slot in 0..<(slots + 1) {
			$offsets = $offsets.append($total)
			$total = $total + ($counts.get(slot) ?? 0)
		}
		offsets = $offsets
		var $cursor = offsets
		var $entries = List.repeat(0, $total)
		var $position = 0
		for slot in item_slots {
			if slot < slots {
				at = $cursor.get(slot) ?? 0
				$entries = $entries.set(at, $position) ?? []
				$cursor = $cursor.set(slot, at + 1) ?? []
			}
			$position = $position + 1
		}
		{ offsets, entries: $entries }
	}

	## True for each item when an earlier item has the same key.
	repeated : U64, (U64, U64 -> Bool), (U64, U64 -> Bool) -> List(Bool)
	repeated = |count, key_before, same_key| RoutePorts.ranks(count, key_before, same_key, |a, b| a < b).map(|entry| entry.rank > 0)

	## Every edge end's selected attachment, from the first attachment and
	## boundary rule that apply to it.
	terminals : Route.Input -> { from : List(Terminal), to : List(Terminal) }
	terminals = |input| {
		edge_count = input.graph.edges.len()
		node_count = input.graph.nodes.len()
		rules = RouteInternals.first_in_slot(
			edge_count * 2,
			input.attachments,
			|rule| if rule.edge < edge_count {
				rule.edge * 2 + RouteInternals.endpoint_index(rule.endpoint)
			} else {
				RouteInternals.no_edge
			},
		)
		outlines = RouteInternals.first_in_slot(node_count, input.boundaries, |rule| rule.node)
		attachment_at = |slot| match input.attachments.get(rules.get(slot) ?? RouteInternals.no_edge) {
			Ok(rule) => rule.attachment
			Err(_) => Automatic
		}
		outline_of = |node| match input.boundaries.get(outlines.get(node) ?? RouteInternals.no_edge) {
			Ok(rule) => rule.outline
			Err(_) => Rectangle
		}
		{
			from: input.graph.edges.map_with_index(|edge, i| RouteInternals.terminal_for(From, edge, input, attachment_at(i * 2), outline_of(edge.from))),
			to: input.graph.edges.map_with_index(|edge, i| RouteInternals.terminal_for(To, edge, input, attachment_at(i * 2 + 1), outline_of(edge.to))),
		}
	}

	## Each node's containing groups, innermost first.
	node_chains : Route.Input -> List(List(U64))
	node_chains = |input| {
		members = RouteInternals.first_in_slot(input.graph.nodes.len(), input.memberships, |membership| membership.node)
		members.map(
			|position| match input.memberships.get(position) {
				Ok(membership) => RouteInternals.group_chain(membership.group, input.groups, [], input.groups.len() + 1)
				Err(_) => []
			},
		)
	}

	## The groups an edge leaves (innermost first) and then enters (outermost
	## first).
	chain_boundary = |from_chain, to_chain| {
		from_only = from_chain.keep_if(|group| !to_chain.contains(group))
		to_only = RouteInternals.reverse_items(to_chain.keep_if(|group| !from_chain.contains(group)))
		from_only.concat(to_only)
	}

	## The first group attachment rule for `edge` and `group`.
	group_rule : List(Route.GroupAttachmentRule), { offsets : List(U64), entries : List(U64) }, U64, U64 -> Try(Route.GroupAttachmentRule, [NoRule])
	group_rule = |rules, by_edge, edge, group| {
		var $slot = by_edge.offsets.get(edge) ?? 0
		end = by_edge.offsets.get(edge + 1) ?? 0
		var $found = Err(NoRule)
		while $slot < end {
			match rules.get(by_edge.entries.get($slot) ?? 0) {
				Ok(rule) if rule.group == group => {
					$found = Ok(rule)
					$slot = end
				}
				_ => {
					$slot = $slot + 1
				}
			}
		}
		$found
	}

	## Every edge's group portals in crossing order, from the group attachment
	## rules.
	all_portals : Route.Input, List(List(U64)) -> List(List(Portal))
	all_portals = |input, chains| {
		edge_count = input.graph.edges.len()
		by_edge = RouteInternals.slot_lists(edge_count, input.group_attachments, |rule| rule.edge)
		input.graph.edges.map_with_index(
			|edge, edge_index| {
				rule_for = |group| RouteInternals.group_rule(input.group_attachments, by_edge, edge_index, group)
				from_chain = chains.get(edge.from) ?? []
				to_chain = RouteInternals.reverse_items(chains.get(edge.to) ?? [])
				from_rules = from_chain.keep_oks(rule_for)
				to_rules = to_chain.keep_oks(rule_for)
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
			},
		)
	}

	## Flexible node attachments become fixed ones: each end on a node side
	## takes the next place on that side, in edge order.
	resolve_node_attachments : Route.Input, Route.Settings, { from : List(Terminal), to : List(Terminal) } -> List(Route.AttachmentRule)
	resolve_node_attachments = |input, settings, selected| {
		edge_count = input.graph.edges.len()
		rules = RouteInternals.first_in_slot(
			edge_count * 2,
			input.attachments,
			|rule| if rule.edge < edge_count {
				rule.edge * 2 + RouteInternals.endpoint_index(rule.endpoint)
			} else {
				RouteInternals.no_edge
			},
		)
		slot_count = input.graph.nodes.len() * 4.U64
		nowhere = { point: { x: 0, y: 0 }, outward: { x: 0, y: 0 }, side: Top }
		var $counts = List.repeat(RouteInternals.zero_count, slot_count)
		for edge_index in 0..<edge_count {
			edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
			from_slot = edge.from * 4 + RouteInternals.side_index((selected.from.get(edge_index) ?? nowhere).side)
			$counts = $counts.set(from_slot, ($counts.get(from_slot) ?? 0) + 1) ?? []
			to_slot = edge.to * 4 + RouteInternals.side_index((selected.to.get(edge_index) ?? nowhere).side)
			$counts = $counts.set(to_slot, ($counts.get(to_slot) ?? 0) + 1) ?? []
		}
		counts = $counts
		var $seen = List.repeat(RouteInternals.zero_count, slot_count)
		var $resolved = List.with_capacity(edge_count * 2)
		for use_index in 0..<(edge_count * 2) {
			edge_index = use_index // 2
			edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
			endpoint = if use_index % 2 == 0 {
				From
			} else {
				To
			}
			node = if use_index % 2 == 0 {
				edge.from
			} else {
				edge.to
			}
			side = if use_index % 2 == 0 {
				(selected.from.get(edge_index) ?? nowhere).side
			} else {
				(selected.to.get(edge_index) ?? nowhere).side
			}
			rule = match input.attachments.get(rules.get(use_index) ?? RouteInternals.no_edge) {
				Ok(found) => found.attachment
				Err(_) => Automatic
			}
			slot = node * 4.U64 + RouteInternals.side_index(side)
			rank = $seen.get(slot) ?? RouteInternals.zero_count
			count = counts.get(slot) ?? RouteInternals.zero_count + 1
			offset = match rule {
				Fixed(payload) => payload.offset
				_ => {
					size = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
					length = match side {
						Top | Bottom => size.width
						Left | Right => size.height
					}
					RouteInternals.flex_offset_at(count, rank, length, settings.edge_gap)
				}
			}
			$seen = $seen.set(slot, rank + 1) ?? []
			$resolved = $resolved.append({ edge: edge_index, endpoint, attachment: Fixed({ side, offset }) })
		}
		$resolved
	}

	## Flexible group portals become fixed ones, spread along their side in
	## order of the edges' endpoints.
	resolve_group_attachments : Route.Input, Route.Settings, List(List(U64)) -> List(Route.GroupAttachmentRule)
	resolve_group_attachments = |input, settings, chains| {
		by_edge = RouteInternals.slot_lists(input.graph.edges.len(), input.group_attachments, |rule| rule.edge)
		var $uses = []
		for edge_index in 0..<input.graph.edges.len() {
			edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
			for group in RouteInternals.chain_boundary(chains.get(edge.from) ?? [], chains.get(edge.to) ?? []) {
				rule = RouteInternals.group_rule(input.group_attachments, by_edge, edge_index, group) ?? { edge: edge_index, group, attachment: Automatic }
				toward = input.positions.get(edge.to) ?? { x: 0, y: 0 }
				portal = RouteInternals.portal_on_group(rule, toward, input)
				key = RouteInternals.edge_order_key(edge, portal.side, input)
				$uses = $uses.append({ edge: edge_index, role: group, group, side: portal.side, primary: key.primary, secondary: key.secondary, authored: rule.attachment })
			}
		}
		uses = $uses
		nothing = { edge: 0, role: 0, group: 0, side: Top, primary: 0, secondary: 0, authored: Automatic }
		at = |i| uses.get(i) ?? nothing
		places = RoutePorts.ranks(
			uses.len(),
			|a, b| (at(a)).group < (at(b)).group or ((at(a)).group == (at(b)).group and RouteInternals.side_index((at(a)).side) < RouteInternals.side_index((at(b)).side)),
			|a, b| (at(a)).group == (at(b)).group and (at(a)).side == (at(b)).side,
			|a, b| RouteInternals.port_order(at(a), at(b)) == Before,
		)
		uses.map_with_index(
			|use, i| {
				offset = match use.authored {
					Fixed(payload) => payload.offset
					_ => {
						place = places.get(i) ?? { rank: 0, count: 1 }
						rect = (input.groups.get(use.group) ?? { rect: Geom.empty_bounds, parent: Root }).rect
						length = match use.side {
							Top | Bottom => rect.width
							Left | Right => rect.height
						}
						RouteInternals.flex_offset_at(place.count, place.rank, length, settings.edge_gap)
					}
				}
				{ edge: use.edge, group: use.group, attachment: Fixed({ side: use.side, offset }) }
			},
		)
	}

	## For every edge end, its place among the ends that share its exact
	## attachment point, ordered by their opposite endpoints.
	endpoint_fan_table : Route.Input, { from : List(Terminal), to : List(Terminal) } -> List({ from : { rank : U64, count : U64 }, to : { rank : U64, count : U64 } })
	endpoint_fan_table = |input, selected| {
		nowhere = { point: { x: 0, y: 0 }, outward: { x: 0, y: 0 }, side: Top }
		uses = List.repeat(0, input.graph.edges.len() * 2).map_with_index(
			|_, use_index| {
				edge_index = use_index // 2
				role = use_index % 2
				edge = input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
				selected_end = if role == 0 {
					selected.from.get(edge_index) ?? nowhere
				} else {
					selected.to.get(edge_index) ?? nowhere
				}
				key = RouteInternals.edge_order_key(edge, selected_end.side, input)
				{
					edge: edge_index,
					role,
					node: if role == 0 {
						edge.from
					} else {
						edge.to
					},
					point: selected_end.point,
					side: RouteInternals.side_index(selected_end.side),
					primary: key.primary,
					secondary: key.secondary,
				}
			},
		)
		nothing = { edge: 0, role: 0, node: 0, point: { x: 0, y: 0 }, side: 0, primary: 0, secondary: 0 }
		at = |i| uses.get(i) ?? nothing
		group_before = |a, b| {
			ua = at(a)
			ub = at(b)
			if ua.node != ub.node {
				ua.node < ub.node
			} else if ua.side != ub.side {
				ua.side < ub.side
			} else if ua.role != ub.role {
				ua.role < ub.role
			} else if ua.point.x != ub.point.x {
				ua.point.x < ub.point.x
			} else {
				ua.point.y < ub.point.y
			}
		}
		same_group = |a, b| {
			ua = at(a)
			ub = at(b)
			ua.node == ub.node and ua.side == ub.side and ua.role == ub.role and ua.point == ub.point
		}
		places = RoutePorts.ranks(uses.len(), group_before, same_group, |a, b| RouteInternals.port_order(at(a), at(b)) == Before)
		input.graph.edges.map_with_index(|_, i| { from: places.get(i * 2) ?? { rank: 0, count: 1 }, to: places.get(i * 2 + 1) ?? { rank: 0, count: 1 } })
	}

	## Everything routing reads about the resolved input, computed once.
	context : Route.Input, Route.Settings, List(List(U64)) -> Context
	context = |input, settings, chains| {
		node_boxes = input.positions.map_with_index(
			|p, node| {
				n = input.graph.nodes.get(node) ?? { width: 0, height: 0 }
				{ min_x: p.x - n.width / 2 - settings.obstacle_gap, min_y: p.y - n.height / 2 - settings.obstacle_gap, max_x: p.x + n.width / 2 + settings.obstacle_gap, max_y: p.y + n.height / 2 + settings.obstacle_gap }
			},
		)
		group_boxes = input.groups.map(|group| { min_x: group.rect.x - settings.obstacle_gap, min_y: group.rect.y - settings.obstacle_gap, max_x: group.rect.x + group.rect.width + settings.obstacle_gap, max_y: group.rect.y + group.rect.height + settings.obstacle_gap })
		edge_count = input.graph.edges.len()
		waypoint_rules = RouteInternals.first_in_slot(edge_count, input.waypoints, |rule| rule.edge)
		guide_rules = RouteInternals.first_in_slot(edge_count, input.guides, |rule| rule.edge)
		selected = RouteInternals.terminals(input)
		{
			input,
			settings,
			from_terminals: selected.from,
			to_terminals: selected.to,
			chains,
			waypoints: waypoint_rules.map(
				|position| match input.waypoints.get(position) {
					Ok(rule) => rule.points
					Err(_) => []
				},
			),
			guides: guide_rules.map(
				|position| match input.guides.get(position) {
					Ok(rule) => rule.points
					Err(_) => []
				},
			),
			portals: RouteInternals.all_portals(input, chains),
			crosses_boundary: input.graph.edges.map(|edge| !RouteInternals.chain_boundary(chains.get(edge.from) ?? [], chains.get(edge.to) ?? []).is_empty()),
			node_boxes,
			group_boxes,
			obstacles: RouteIndex.boxes(node_boxes.concat(group_boxes)),
			grid: RouteIndex.grid_for(node_boxes, (input.graph.nodes.len() + edge_count) * 2),
		}
	}

	## Whether `group` contains either end of an edge between `from` and `to`.
	owns_end = |ctx, group, from, to| (ctx.chains.get(from) ?? []).contains(group) or (ctx.chains.get(to) ?? []).contains(group)

	## The obstacles one edge must avoid: every node box except, when
	## `endpoints` is false, its own two, and every group box that contains
	## neither end. Box ids below the node count are nodes; the rest groups.
	skips : Context, View -> (U64 -> Bool)
	skips = |ctx, view| {
		node_count = ctx.node_boxes.len()
		|id| if id < node_count {
			!view.endpoints and (id == view.from or id == view.to)
		} else {
			RouteInternals.owns_end(ctx, id - node_count, view.from, view.to)
		}
	}

	## The same obstacles as an ordered list: other nodes in node order, the
	## kept groups, then (with `endpoints`) the edge's own nodes.
	view_boxes : Context, View -> List(Bounds)
	view_boxes = |ctx, view| {
		node_count = ctx.node_boxes.len()
		nothing = { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
		var $boxes = List.with_capacity(node_count + ctx.group_boxes.len())
		for node in 0..<node_count {
			if node != view.from and node != view.to {
				$boxes = $boxes.append(ctx.node_boxes.get(node) ?? nothing)
			}
		}
		for group in 0..<ctx.group_boxes.len() {
			if !RouteInternals.owns_end(ctx, group, view.from, view.to) {
				$boxes = $boxes.append(ctx.group_boxes.get(group) ?? nothing)
			}
		}
		if view.endpoints {
			low = view.from.min(view.to)
			high = view.from.max(view.to)
			$boxes = $boxes.append(ctx.node_boxes.get(low) ?? nothing)
			if high != low {
				$boxes = $boxes.append(ctx.node_boxes.get(high) ?? nothing)
			}
		}
		$boxes
	}

	## Whether every segment of `points` is axis-aligned and clear of the
	## view's obstacles.
	view_visible : Context, View, List(Geom.Point) -> Bool
	view_visible = |ctx, view, points| {
		skip = RouteInternals.skips(ctx, view)
		points.fold_with_index(
			True,
			|clear, a, i| match points.get(i + 1) {
				Ok(b) => clear and (a.x == b.x or a.y == b.y) and !RouteIndex.segment_blocked(ctx.obstacles, a, b, skip)
				Err(_) => clear
			},
		)
	}

	## Whether every segment of `points` stays clear of every node box other
	## than the edge's own two.
	clear_path : Context, List(Geom.Point), U64, U64 -> Bool
	clear_path = |ctx, points, from, to| {
		node_count = ctx.node_boxes.len()
		skip = |id| id >= node_count or id == from or id == to
		points.fold_with_index(
			True,
			|ok, a, i| match points.get(i + 1) {
				Ok(b) => ok and !RouteIndex.segment_blocked(ctx.obstacles, a, b, skip)
				Err(_) => ok
			},
		)
	}

	shortest_grid = |start, finish, boxes, settings, prior| RouteGrid.shortest_touching(start, finish, boxes, settings.bend_penalty, settings.shared_path_penalty, RouteIndex.touch_boxes(prior.segments, prior.excluded))

	## Length plus bend and shared-segment penalties of a candidate path.
	path_cost : List(Geom.Point), Prior, Route.Settings -> F64
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
				shared = RouteIndex.touching(prior.segments, a, b, prior.excluded)
				cost + length + bend + shared.to_f64() * settings.shared_path_penalty
			}
			Err(_) => cost
		},
	)

	route_leg : Context, View, Geom.Point, Geom.Point, Prior -> List(Geom.Point)
	route_leg = |ctx, view, start, finish, prior| {
		settings = ctx.settings
		hv = [start, { x: finish.x, y: start.y }, finish]
		vh = [start, { x: start.x, y: finish.y }, finish]
		hv_clear = RouteInternals.view_visible(ctx, view, hv)
		vh_clear = RouteInternals.view_visible(ctx, view, vh)
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
			boxes = RouteInternals.view_boxes(ctx, view)
			searched = RouteInternals.shortest_grid(start, finish, boxes, settings, prior)
			if searched.is_empty() {
				exterior_y = boxes.fold(start.y.min(finish.y), |top, box| top.min(box.min_y)) - settings.edge_gap
				[start, { x: start.x, y: exterior_y }, { x: finish.x, y: exterior_y }, finish]
			} else {
				searched
			}
		}
	}

	guided_path_valid = |ctx, points, edge, a, b| {
		orthogonal = points.fold_with_index(
			True,
			|ok, point, i| match points.get(i + 1) {
				Ok(next) => ok and point != next and (point.x == next.x or point.y == next.y)
				Err(_) => ok
			},
		)
		from_next = points.get(1) ?? a.point
		to_previous = if points.len() < 2 {
			b.point
		} else {
			points.get(points.len() - 2) ?? b.point
		}
		leaves_from = (from_next.x - a.point.x) * a.outward.x + (from_next.y - a.point.y) * a.outward.y > 0
		enters_to = (to_previous.x - b.point.x) * b.outward.x + (to_previous.y - b.point.y) * b.outward.y > 0
		orthogonal and leaves_from and enters_to and RouteInternals.simple_path(points) and RouteInternals.clear_path(ctx, points, edge.from, edge.to)
	}

	terminal_path_valid = |ctx, points, edge, a, b| {
		input = ctx.input
		settings = ctx.settings
		from_escape = RouteInternals.escape_point(a, edge.from, input, settings.obstacle_gap)
		to_escape = RouteInternals.escape_point(b, edge.to, input, settings.obstacle_gap)
		from_next = points.get(1) ?? a.point
		to_previous = if points.len() < 2 {
			b.point
		} else {
			points.get(points.len() - 2) ?? b.point
		}
		from_required = (from_escape.x - a.point.x).abs() + (from_escape.y - a.point.y).abs()
		to_required = (to_escape.x - b.point.x).abs() + (to_escape.y - b.point.y).abs()
		from_advance = (from_next.x - a.point.x) * a.outward.x + (from_next.y - a.point.y) * a.outward.y
		to_advance = (to_previous.x - b.point.x) * b.outward.x + (to_previous.y - b.point.y) * b.outward.y
		from_straight = (a.outward.x == 0 and from_next.x == a.point.x) or (a.outward.y == 0 and from_next.y == a.point.y)
		to_straight = (b.outward.x == 0 and to_previous.x == b.point.x) or (b.outward.y == 0 and to_previous.y == b.point.y)
		orthogonal = points.fold_with_index(
			True,
			|ok, point, i| match points.get(i + 1) {
				Ok(next) => ok and (point.x == next.x or point.y == next.y)
				Err(_) => ok
			},
		)
		nothing = { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
		incident = [ctx.node_boxes.get(edge.from) ?? nothing, ctx.node_boxes.get(edge.to) ?? nothing]
		body_clear = points.fold_with_index(
			True,
			|ok, point, i| match points.get(i + 1) {
				Ok(next) if i > 0 and i + 2 < points.len() => ok and incident.all(|box| RouteInternals.segment_hits(point, next, box) == False)
				_ => ok
			},
		)
		points.first() == Ok(a.point) and points.last() == Ok(b.point) and orthogonal and from_straight and to_straight and from_advance >= from_required and to_advance >= to_required and body_clear and RouteInternals.simple_path(points)
	}

	route_through = |ctx, view, start, finish, waypoints, prior| {
		stops = waypoints.append(finish)
		stops.fold(
			{ points: [start], current: start },
			|state, stop| {
				leg = RouteInternals.route_leg(ctx, view, state.current, stop, prior)
				{ points: state.points.concat(leg.drop_first(1)), current: stop }
			},
		).points
	}

	route_one : Context, U64, { from : U64, to : U64 }, { rank : U64, count : U64 }, { from : { rank : U64, count : U64 }, to : { rank : U64, count : U64 } }, Prior, Bool -> Geom.Route
	route_one = |ctx, index, edge, parallel, endpoint_fan, prior, use_guides| {
		input = ctx.input
		settings = ctx.settings
		nowhere = { point: { x: 0, y: 0 }, outward: { x: 0, y: 0 }, side: Top }
		a = ctx.from_terminals.get(index) ?? nowhere
		b = ctx.to_terminals.get(index) ?? nowhere
		portals = ctx.portals.get(index) ?? []
		waypoints = ctx.waypoints.get(index) ?? []
		guides = if use_guides {
			ctx.guides.get(index) ?? []
		} else {
			[]
		}
		body = { from: edge.from, to: edge.to, endpoints: True }
		if edge.from == edge.to {
			# A rectangular exterior loop; bound ports still determine its first and last point.
			d = settings.obstacle_gap + settings.edge_gap * (parallel.rank + 1).to_f64()
			base_ap = RouteInternals.escape_point(a, edge.from, input, settings.obstacle_gap)
			base_bp = RouteInternals.escape_point(b, edge.to, input, settings.obstacle_gap)
			ap = { x: base_ap.x + a.outward.x * settings.edge_gap * (parallel.rank + 1).to_f64(), y: base_ap.y + a.outward.y * settings.edge_gap * (parallel.rank + 1).to_f64() }
			bp = { x: base_bp.x + b.outward.x * settings.edge_gap * (parallel.rank + 1).to_f64(), y: base_bp.y + b.outward.y * settings.edge_gap * (parallel.rank + 1).to_f64() }
			node = input.graph.nodes.get(edge.from) ?? { width: 0, height: 0 }
			center = input.positions.get(edge.from) ?? a.point
			lane = center.y - node.height / 2 - d - settings.edge_gap
			# Going through one shared exterior lane keeps every segment
			# axis-aligned even when both unbound endpoints coincide.
			Polyline(RouteInternals.simplify([a.point, ap, { x: ap.x, y: lane }, { x: bp.x, y: lane }, bp, b.point]))
		} else if portals.is_empty() and !waypoints.is_empty() {
			ap = RouteInternals.escape_point(a, edge.from, input, settings.obstacle_gap)
			bp = RouteInternals.escape_point(b, edge.to, input, settings.obstacle_gap)
			af = RouteInternals.fan_point(ap, a, endpoint_fan.from, settings.edge_gap)
			bf = RouteInternals.fan_point(bp, b, endpoint_fan.to, settings.edge_gap)
			through = RouteInternals.route_through(ctx, body, af, bf, waypoints, prior)
			Polyline(RouteInternals.simplify_preserving([a.point, ap, af].concat(through.drop_first(1)).concat([bf, bp, b.point]), waypoints))
		} else if portals.is_empty() and !guides.is_empty() {
			ap = RouteInternals.escape_point(a, edge.from, input, settings.obstacle_gap)
			bp = RouteInternals.escape_point(b, edge.to, input, settings.obstacle_gap)
			af = RouteInternals.fan_point(ap, a, endpoint_fan.from, settings.edge_gap)
			bf = RouteInternals.fan_point(bp, b, endpoint_fan.to, settings.edge_gap)
			through = RouteInternals.route_through(ctx, body, af, bf, guides, prior)
			candidate = RouteInternals.simplify([a.point, ap, af].concat(through.drop_first(1)).concat([bf, bp, b.point]))
			if RouteInternals.guided_path_valid(ctx, candidate, edge, a, b) and RouteInternals.terminal_path_valid(ctx, candidate, edge, a, b) {
				Polyline(candidate)
			} else {
				RouteInternals.route_one(ctx, index, edge, parallel, endpoint_fan, prior, False)
			}
		} else if portals.is_empty() {
			ap = RouteInternals.escape_point(a, edge.from, input, settings.obstacle_gap)
			bp = RouteInternals.escape_point(b, edge.to, input, settings.obstacle_gap)
			af = RouteInternals.fan_point(ap, a, endpoint_fan.from, settings.edge_gap)
			bf = RouteInternals.fan_point(bp, b, endpoint_fan.to, settings.edge_gap)
			hv = [a.point, ap, af, { x: bf.x, y: af.y }, bf, bp, b.point]
			vh = [a.point, ap, af, { x: af.x, y: bf.y }, bf, bp, b.point]
			hv_clear = RouteInternals.view_visible(ctx, body, hv.drop_first(1).drop_last(1))
			vh_clear = RouteInternals.view_visible(ctx, body, vh.drop_first(1).drop_last(1))
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
				boxes = RouteInternals.view_boxes(ctx, body)
				searched = RouteInternals.shortest_grid(af, bf, boxes, settings, prior)
				if searched.is_empty() {
					exterior_y = boxes.fold(af.y.min(bf.y), |top, box| top.min(box.min_y)) - settings.edge_gap
					[a.point, ap, af, { x: af.x, y: exterior_y }, { x: bf.x, y: exterior_y }, bf, bp, b.point]
				} else {
					[a.point, ap, af].concat(searched.drop_first(1)).concat([bf, bp, b.point])
				}
			}
			Polyline(RouteInternals.simplify(chosen))
		} else {
			ap = RouteInternals.escape_point(a, edge.from, input, settings.obstacle_gap)
			bp = RouteInternals.escape_point(b, edge.to, input, settings.obstacle_gap)
			af = RouteInternals.fan_point(ap, a, endpoint_fan.from, settings.edge_gap)
			bf = RouteInternals.fan_point(bp, b, endpoint_fan.to, settings.edge_gap)
			through = portals.fold(
				{ points: [a.point, ap, af], current: af },
				|state, portal| {
					stops = RouteInternals.portal_stops(portal, settings.obstacle_gap, input)
					leg = RouteInternals.route_leg(ctx, body, state.current, stops.approach, prior)
					{ points: state.points.concat(leg.drop_first(1)).concat([portal.point, stops.departure]), current: stops.departure }
				},
			)
			last_leg = RouteInternals.route_leg(ctx, body, through.current, bf, prior)
			Polyline(RouteInternals.simplify_preserving(through.points.concat(last_leg.drop_first(1)).concat([bp, b.point]), portals.map(|portal| portal.point)))
		}
	}

	## A label box around `p`, grown by `gap` on every side.
	label_reach : Geom.Point, F64, F64, F64 -> Bounds
	label_reach = |p, width, height, gap| { min_x: p.x - width / 2 - gap, min_y: p.y - height / 2 - gap, max_x: p.x + width / 2 + gap, max_y: p.y + height / 2 + gap }

	## Whether a label at `p` keeps clear of every node, every label placed
	## before it, and every route other than its own.
	label_clear = |p, label, ctx, placed, placed_index, nodes, routes| {
		gap = ctx.settings.obstacle_gap
		reach = RouteInternals.label_reach(p, label.width, label.height, gap)
		nothing = { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
		nodes_clear = RouteIndex.boxes_meeting(nodes, reach).all(|id| RouteInternals.overlaps_box(p, label.width, label.height, nodes.boxes.get(id) ?? nothing, gap) == False)
		labels_clear = RouteIndex.segments_meeting(placed_index, reach, RouteInternals.no_edge).all(
			|id| {
				old = placed.get(placed_index.owners.get(id) ?? 0) ?? { point: p, width: 0, height: 0 }
				RouteInternals.overlaps_box(p, label.width, label.height, { min_x: old.point.x - old.width / 2, min_y: old.point.y - old.height / 2, max_x: old.point.x + old.width / 2, max_y: old.point.y + old.height / 2 }, gap) == False
			},
		)
		routes_clear = RouteIndex.segments_meeting(routes, reach, label.edge).all(
			|id| RouteInternals.segment_hits(routes.starts.get(id) ?? p, routes.ends.get(id) ?? p, { min_x: p.x - label.width / 2 - gap, min_y: p.y - label.height / 2 - gap, max_x: p.x + label.width / 2 + gap, max_y: p.y + label.height / 2 + gap }) == False,
		)
		nodes_clear and labels_clear and routes_clear
	}

	shared_geometry : Context, Route.SharedEndRule, Prior -> { junction : Geom.Point, trunk : Geom.Route, branches : List(Geom.Route) }
	shared_geometry = |ctx, rule, prior| {
		input = ctx.input
		settings = ctx.settings
		nowhere = { point: { x: 0, y: 0 }, outward: { x: 0, y: 0 }, side: Top }
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
		common_chain = ctx.chains.get(common_node) ?? []
		common_portals = (ctx.portals.get(first_index) ?? []).keep_if(|portal| common_chain.contains(portal.group))
		ordered_common = match rule.endpoint {
			From => RouteInternals.reverse_portals(common_portals)
			To => common_portals
		}
		trunk_view = { from: first_edge.from, to: first_edge.to, endpoints: False }
		trunk_forward = ordered_common.fold(
			{ points: [junction], current: junction },
			|state, portal| {
				stops = RouteInternals.portal_stops(portal, settings.obstacle_gap, input)
				leg = RouteInternals.route_leg(ctx, trunk_view, state.current, stops.approach, prior)
				{ points: state.points.concat(leg.drop_first(1)).concat([portal.point, stops.departure]), current: stops.departure }
			},
		)
		approach = { x: common_terminal.point.x + common_terminal.outward.x * settings.obstacle_gap, y: common_terminal.point.y + common_terminal.outward.y * settings.obstacle_gap }
		last = RouteInternals.route_leg(ctx, trunk_view, trunk_forward.current, approach, prior)
		trunk_points = RouteInternals.simplify_preserving(trunk_forward.points.concat(last.drop_first(1)).append(common_terminal.point), ordered_common.map(|portal| portal.point))
		branches = rule.edges.map(
			|edge_index| {
				edge = input.graph.edges.get(edge_index) ?? first_edge
				selected_terminal = match rule.endpoint {
					From => ctx.to_terminals.get(edge_index) ?? nowhere
					To => ctx.from_terminals.get(edge_index) ?? nowhere
				}
				forward_portals = (ctx.portals.get(edge_index) ?? []).keep_if(|portal| common_chain.contains(portal.group) == False)
				portals = match rule.endpoint {
					From => RouteInternals.reverse_portals(forward_portals)
					To => forward_portals
				}
				branch_view = { from: edge.from, to: edge.to, endpoints: False }
				through = portals.fold(
					{ points: [selected_terminal.point], current: selected_terminal.point },
					|state, portal| {
						stops = RouteInternals.portal_stops(portal, settings.obstacle_gap, input)
						leg = RouteInternals.route_leg(ctx, branch_view, state.current, stops.approach, prior)
						{ points: state.points.concat(leg.drop_first(1)).concat([portal.point, stops.departure]), current: stops.departure }
					},
				)
				final = RouteInternals.route_leg(ctx, branch_view, through.current, junction, prior)
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

	## A route's crossings with, and length shared with, every other route,
	## together with its own bends and length.
	route_stats : Geom.Route, RouteIndex.Segments, U64, Route.Settings -> { crossings : U64, shared : F64, bends : U64, length : F64 }
	route_stats = |route, others, excluded, settings| {
		points = RouteInternals.route_points(route)
		own = points.fold_with_index(
			{ bends: 0.U64, length: 0.0.F64 },
			|state, a, i| match points.get(i + 1) {
				Ok(b) => {
					bend = if i == 0 {
						0.U64
					} else {
						before = points.get(i - 1) ?? a
						if (before.x == a.x) == (a.x == b.x) {
							0.U64
						} else {
							1.U64
						}
					}
					{ bends: state.bends + bend, length: state.length + (b.x - a.x).abs() + (b.y - a.y).abs() }
				}
				Err(_) => state
			},
		)
		# Shared lengths are summed in the order of the other route, this
		# route's segment, then the other route's segment.
		var $crossings = 0.U64
		var $overlaps = []
		for i in 0..<points.len().max(1) - 1 {
			a = points.get(i) ?? { x: 0, y: 0 }
			b = points.get(i + 1) ?? a
			for id in RouteIndex.segments_meeting(others, RouteIndex.segment_extent(a, b), excluded) {
				c = others.starts.get(id) ?? a
				d = others.ends.get(id) ?? a
				if RouteInternals.proper_crossing(a, b, c, d) {
					$crossings = $crossings + 1
				}
				length = RouteInternals.shared_length(a, b, c, d)
				if length > 0 {
					$overlaps = $overlaps.append({ route: others.owners.get(id) ?? 0, own: i, other: others.positions.get(id) ?? 0, length })
				}
			}
		}
		overlaps = $overlaps
		nothing = { route: 0, own: 0, other: 0, length: 0.0 }
		order = RouteSort.by(
			overlaps.len(),
			|x, y| {
				p = overlaps.get(x) ?? nothing
				q = overlaps.get(y) ?? nothing
				p.route < q.route or (p.route == q.route and (p.own < q.own or (p.own == q.own and p.other < q.other)))
			},
		)
		shared = order.fold(0.0, |sum, k| sum + (overlaps.get(k) ?? nothing).length)
		{
			crossings: $crossings,
			shared: if settings.shared_path_penalty == 0 {
				0
			} else {
				shared
			},
			bends: if settings.bend_penalty == 0 {
				0
			} else {
				own.bends
			},
			length: own.length,
		}
	}

	## Bounded whole-drawing improvement: each sweep reroutes, in alternating
	## edge order, every route that crosses or shares another or passes a
	## group portal, keeping a candidate only when it is strictly better.
	refine_routes : Context, List({ rank : U64, count : U64 }), List({ from : { rank : U64, count : U64 }, to : { rank : U64, count : U64 } }), List(Geom.Route), RouteIndex.Segments -> { routes : List(Geom.Route), segments : RouteIndex.Segments }
	refine_routes = |ctx, ranks, fan_table, routes, segments| {
		edge_count = ctx.input.graph.edges.len()
		var $routes = routes
		var $segments = segments
		var $sweep = 0
		var $fuel = ctx.settings.max_sweeps
		while $fuel > 0 {
			before = $routes
			for k in 0..<edge_count {
				edge_index = if $sweep % 2 == 0 {
					k
				} else {
					edge_count - 1 - k
				}
				edge = ctx.input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
				old = $routes.get(edge_index) ?? Polyline([])
				old_stats = RouteInternals.route_stats(old, $segments, edge_index, ctx.settings)
				affected = !(ctx.portals.get(edge_index) ?? []).is_empty() or old_stats.crossings > 0 or old_stats.shared > RouteInternals.zero_distance
				if affected {
					candidate = RouteInternals.route_one(ctx, edge_index, edge, ranks.get(edge_index) ?? { rank: 0, count: 1 }, fan_table.get(edge_index) ?? { from: { rank: 0.U64, count: 1.U64 }, to: { rank: 0.U64, count: 1.U64 } }, { segments: $segments, excluded: edge_index }, True)
					candidate_stats = RouteInternals.route_stats(candidate, $segments, edge_index, ctx.settings)
					if RouteInternals.stats_better(candidate_stats, old_stats) {
						$routes = $routes.set(edge_index, candidate) ?? []
						$segments = RouteIndex.set_route($segments, edge_index, RouteInternals.route_points(candidate))
					}
				}
			}
			if $routes == before {
				$fuel = 0
			} else {
				$fuel = $fuel - 1
				$sweep = $sweep + 1
			}
		}
		{ routes: $routes, segments: $segments }
	}

	## Every segment of every route, in route order.
	segment_records : List(Geom.Route) -> List(RouteLanes.Segment)
	segment_records = |routes| {
		var $found = []
		var $edge = 0
		for route in routes {
			points = RouteInternals.route_points(route)
			for index in 0..<points.len().max(1) - 1 {
				a = points.get(index) ?? { x: 0, y: 0 }
				b = points.get(index + 1) ?? a
				horizontal = a.y == b.y
				coord = if horizontal {
					a.y
				} else {
					a.x
				}
				low = if horizontal {
					a.x.min(b.x)
				} else {
					a.y.min(b.y)
				}
				high = if horizontal {
					a.x.max(b.x)
				} else {
					a.y.max(b.y)
				}
				# The first two and last two segments form the protected
				# attachment/escape/fan corridor. Lane separation may only
				# move the route body outside those terminal corridors.
				$found = $found.append({ edge: $edge, index, horizontal, coord, low, high, movable: index > 2 and index + 4 < points.len() and high > low })
			}
			$edge = $edge + 1
		}
		$found
	}

	nudge_one = |ctx, route, edge_index, edge, owned, coords| {
		points = RouteInternals.route_points(route)
		repeated_axis = points.fold_with_index(
			False,
			|found, a, i| if i == 0 {
				found
			} else {
				before = points.get(i - 1) ?? a
				after = points.get(i + 1) ?? a
				found or ((before.x == a.x) == (a.x == after.x))
			},
		)
		if points.len() < 4 or repeated_axis {
			route
		} else {
			moved = points.map_with_index(
				|point, i| if i == 0 or i + 1 == points.len() {
					point
				} else {
					before = owned.get(i - 1) ?? { edge: edge_index, index: i - 1, horizontal: True, coord: point.y, low: point.x, high: point.x, movable: False }
					after = owned.get(i) ?? before
					before_coord = coords.get(i - 1) ?? before.coord
					after_coord = coords.get(i) ?? after.coord
					if before.horizontal {
						{ x: after_coord, y: before_coord }
					} else {
						{ x: before_coord, y: after_coord }
					}
				},
			)
			nowhere = { point: { x: 0, y: 0 }, outward: { x: 0, y: 0 }, side: Top }
			a = ctx.from_terminals.get(edge_index) ?? nowhere
			b = ctx.to_terminals.get(edge_index) ?? nowhere
			if RouteInternals.view_visible(ctx, { from: edge.from, to: edge.to, endpoints: True }, moved.drop_first(1).drop_last(1)) and RouteInternals.terminal_path_valid(ctx, moved, edge, a, b) {
				Polyline(RouteInternals.simplify(moved))
			} else {
				route
			}
		}
	}

	## Spread coincident route bodies into lanes, keeping every route whose
	## moved form would lose clearance or a clean terminal.
	nudge_all : Context, List(Geom.Route) -> List(Geom.Route)
	nudge_all = |ctx, routes| {
		segments = RouteInternals.segment_records(routes)
		coords = RouteLanes.lanes(segments, ctx.settings.edge_gap)
		starts = routes.fold(
			[0],
			|acc, route| {
				count = RouteInternals.route_points(route).len().max(1) - 1
				acc.append((acc.last() ?? 0) + count)
			},
		)
		routes.map_with_index(
			|route, edge_index| {
				edge = ctx.input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
				crosses_group_boundary = ctx.crosses_boundary.get(edge_index) ?? False
				if (ctx.waypoints.get(edge_index) ?? []).is_empty() and !crosses_group_boundary {
					start = starts.get(edge_index) ?? 0
					count = (starts.get(edge_index + 1) ?? start) - start
					RouteInternals.nudge_one(ctx, route, edge_index, edge, segments.sublist({ start, len: count }), coords.sublist({ start, len: count }))
				} else {
					route
				}
			},
		)
	}

	nudge_routes = |routes, input, settings| RouteInternals.nudge_all(RouteInternals.context(input, settings, RouteInternals.node_chains(input)), routes)

	## Routes for every edge in edge order, each avoiding those before it.
	initial_routes : Context, List({ rank : U64, count : U64 }), List({ from : { rank : U64, count : U64 }, to : { rank : U64, count : U64 } }) -> { routes : List(Geom.Route), segments : RouteIndex.Segments }
	initial_routes = |ctx, ranks, fan_table| {
		edge_count = ctx.input.graph.edges.len()
		var $routes = List.with_capacity(edge_count)
		var $segments = RouteIndex.segments(ctx.grid, edge_count)
		for edge_index in 0..<edge_count {
			edge = ctx.input.graph.edges.get(edge_index) ?? { from: 0, to: 0 }
			route = RouteInternals.route_one(ctx, edge_index, edge, ranks.get(edge_index) ?? { rank: 0, count: 1 }, fan_table.get(edge_index) ?? { from: { rank: 0.U64, count: 1.U64 }, to: { rank: 0.U64, count: 1.U64 } }, { segments: $segments, excluded: RouteInternals.no_edge }, True)
			$routes = $routes.append(route)
			$segments = RouteIndex.set_route($segments, edge_index, RouteInternals.route_points(route))
		}
		{ routes: $routes, segments: $segments }
	}

	## Fix flexible attachments, then build the routing context.
	prepare : Route.Input, Route.Settings -> Context
	prepare = |original, settings| {
		chains = RouteInternals.node_chains(original)
		selected = RouteInternals.terminals(original)
		input = {
			..original,
			attachments: RouteInternals.resolve_node_attachments(original, settings, selected),
			group_attachments: RouteInternals.resolve_group_attachments(original, settings, chains),
		}
		RouteInternals.context(input, settings, chains)
	}

	compute : Route.Input, Route.Settings -> Route.Result
	compute = |original, settings| {
		ctx = RouteInternals.prepare(original, settings)
		input = ctx.input
		ranks = EdgeRoutes.parallel_ranks(input.graph.edges)
		fan_table = RouteInternals.endpoint_fan_table(input, { from: ctx.from_terminals, to: ctx.to_terminals })
		initial = RouteInternals.initial_routes(ctx, ranks, fan_table)
		refined = RouteInternals.refine_routes(ctx, ranks, fan_table, initial.routes, initial.segments)
		independent_routes = refined.routes
		shared = input.shared_ends.map(|rule| RouteInternals.shared_geometry(ctx, rule, { segments: refined.segments, excluded: RouteInternals.no_edge }))
		shared_branches = input.shared_ends.fold_with_index(
			independent_routes,
			|routes, rule, shared_index| {
				geometry = shared.get(shared_index) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				rule.edges.fold_with_index(routes, |updated, edge, branch_index| updated.set(edge, geometry.branches.get(branch_index) ?? Polyline([])) ?? [])
			},
		)
		raw_routes = RouteInternals.nudge_all(ctx, shared_branches)
		label_routes = input.shared_ends.fold_with_index(
			raw_routes,
			|routes, rule, shared_index| {
				geometry = shared.get(shared_index) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				rule.edges.fold(routes, |updated, edge| updated.set(edge, RouteInternals.join_shared(updated.get(edge) ?? Polyline([]), geometry.trunk, rule.endpoint)) ?? [])
			},
		)
		raw_labels = if input.edge_labels.is_empty() {
			[]
		} else {
			node_faces = RouteIndex.boxes(
				input.positions.map_with_index(
					|center, i| {
						n = input.graph.nodes.get(i) ?? { width: 0, height: 0 }
						{ min_x: center.x - n.width / 2, min_y: center.y - n.height / 2, max_x: center.x + n.width / 2, max_y: center.y + n.height / 2 }
					},
				),
			)
			route_segments = label_routes.fold_with_index(RouteIndex.segments(ctx.grid, label_routes.len()), |acc, route, edge| RouteIndex.set_route(acc, edge, RouteInternals.route_points(route)))
			var $placed = []
			var $placed_index = RouteIndex.segments(ctx.grid, input.edge_labels.len())
			for label in input.edge_labels {
				route = label_routes.get(label.edge) ?? Polyline([])
				base = RouteInternals.anchor_for(route, label.placement)
				candidates = RouteInternals.label_candidates(route, label.placement, label.width, label.height, settings)
				placed = $placed
				placed_index = $placed_index
				point = candidates.find_first(|p| RouteInternals.label_clear(p, label, ctx, placed, placed_index, node_faces, route_segments)) ?? base
				$placed_index = RouteIndex.set_route($placed_index, $placed.len(), [{ x: point.x - label.width / 2, y: point.y - label.height / 2 }, { x: point.x + label.width / 2, y: point.y + label.height / 2 }])
				$placed = $placed.append({ point, width: label.width, height: label.height })
			}
			$placed.map(|entry| entry.point)
		}
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
		nowhere = { point: { x: 0, y: 0 }, outward: { x: 0, y: 0 }, side: Top }
		independent_attachments = input.graph.edges.map_with_index(
			|_, i| {
				from = ctx.from_terminals.get(i) ?? nowhere
				to = ctx.to_terminals.get(i) ?? nowhere
				{ from: { point: from.point, side: from.side }, to: { point: to.point, side: to.side } }
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
							From => { ..old, from: { point: common_point, side: selected_side } }
							To => { ..old, to: { point: common_point, side: selected_side } }
						}
						updated.set(edge_index, next) ?? []
					},
				)
			},
		)
		group_crossings = if input.groups.is_empty() {
			raw_routes.map(|_| [])
		} else {
			raw_routes.map_with_index(
				|route, edge_index| {
					portals = ctx.portals.get(edge_index) ?? []
					RouteInternals.route_crossings(route, input.groups).map(
						|crossing| match portals.find_first(|portal| portal.group == crossing.group and portal.point == crossing.point) {
							Ok(portal) => { group: portal.group, point: portal.point, side: portal.side, offset: portal.offset }
							Err(_) => crossing
						},
					)
				},
			)
		}
		groups = input.groups.map(|group| group.rect)
		shared_routes = input.shared_ends.map_with_index(
			|rule, i| {
				geometry = shared.get(i) ?? { junction: { x: 0, y: 0 }, trunk: Polyline([]), branches: [] }
				{ edges: rule.edges, endpoint: rule.endpoint, junction: geometry.junction, trunk: geometry.trunk, group_crossings: RouteInternals.route_crossings(geometry.trunk, input.groups) }
			},
		)
		{ layout: { positions: input.positions, routes: raw_routes, bounds: { x: box.min_x, y: box.min_y, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) } }, groups, label_anchors: raw_labels, attachments, group_crossings, shared_routes }
	}
}

## Placement-independent routing for an already positioned, sized graph.
## `layout` produces deterministic axis-aligned polylines, honors sparse
## attachment rules, separates parallel edges into stable tracks, gives
## self-loops exterior paths, and returns one anchor for every sparse edge
## label in label input order. Every label anchor lies on its final edge path;
## labels may be centered on an edge or placed near either end, so relationship
## names, roles, and multiplicities remain visually attached without putting
## text or styling into the geometry API. Group
## attachments are exact boundary crossings: routes approach and leave them
## perpendicularly instead of following the group outline.
##
## Sparse waypoint rules are exact: a routed edge passes through every listed
## point in order. Sparse guide rules are preferences supplied by placement;
## the router discards a guided candidate when it would lose clearance,
## reverse, self-intersect, or approach a node from the wrong direction. The
## router never moves or normalizes caller geometry; `bounds.x` and `bounds.y`
## report the actual drawing origin.
##
## Nodes use their rectangular size as their boundary by default. A sparse
## boundary rule makes attachment points follow an ellipse inside the same
## sized box; routing still treats that box as the node's obstacle.
## Every ordinary route first travels outward from its selected attachment to
## the node's inflated routing boundary before it may turn. Edges sharing an
## exact attachment share that short terminal throat and then receive stable
## lanes. Refinement never moves these terminal corridors, so a route cannot
## return beneath an incident node after leaving its port. Exact waypoints
## remain obligations and can intentionally describe otherwise infeasible
## geometry; overlapping endpoint boxes may likewise leave no clear route.
##
## Every edge that enters or leaves a group receives one perpendicular portal
## on that boundary. Sparse group attachments override those automatic portals.
## `Automatic` lets the router choose a side and a distinct position, `On`
## fixes only the side, and `Fixed` chooses an exact normalized offset.
## Flexible ports sharing a side are ordered from their endpoints and separated
## by `edge_gap`; when a short side cannot fit that gap, spacing compresses
## uniformly while preserving order. Nested portals are crossed in ancestry
## order and every resulting route is kept clear of obstacles.
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
	WaypointRule : { edge : U64, points : List(Geom.Point) }
	GuideRule : { edge : U64, points : List(Geom.Point) }

	Input : { graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }, positions : List({ x : F64, y : F64 }), groups : List(Group), memberships : List(Membership), attachments : List(AttachmentRule), group_attachments : List(GroupAttachmentRule), boundaries : List(BoundaryRule), edge_labels : List(EdgeLabel), shared_ends : List(SharedEndRule), waypoints : List(WaypointRule), guides : List(GuideRule) }

	## `obstacle_gap` is the empty space kept around node and group boxes. `edge_gap`
	## separates flexible ports and parallel lanes. `bend_penalty` favors fewer
	## turns over a shorter candidate, while `shared_path_penalty` favors a
	## distinct corridor. Zero disables the corresponding preference.
	## `max_sweeps` bounds deterministic whole-drawing improvement passes; zero
	## keeps the initial routes and still performs port and lane assignment.
	Settings : { obstacle_gap : F64, bend_penalty : F64, shared_path_penalty : F64, edge_gap : F64, max_sweeps : U64 }
	SelectedAttachment : { point : Geom.Point, side : Side }
	EdgeAttachments : { from : SelectedAttachment, to : SelectedAttachment }
	GroupCrossing : { group : U64, point : Geom.Point, side : Side, offset : F64 }
	SharedRoute : { edges : List(U64), endpoint : Endpoint, junction : Geom.Point, trunk : Geom.Route, group_crossings : List(GroupCrossing) }
	Result : { layout : { positions : List(Geom.Point), routes : List(Geom.Route), bounds : Geom.Rect }, groups : List(Geom.Rect), label_anchors : List(Geom.Point), attachments : List(EdgeAttachments), group_crossings : List(List(GroupCrossing)), shared_routes : List(SharedRoute) }
	Problem := [InvalidNodeWidth(U64), InvalidNodeHeight(U64), PositionCountMismatch, InvalidPosition(U64), InvalidEdgeFrom(U64), InvalidEdgeTo(U64), InvalidAttachmentEdge(U64), InvalidAttachmentOffset(U64), DuplicateAttachment(U64), InvalidGroupRect(U64), InvalidGroupParent(U64), InvalidMembershipNode(U64), InvalidMembershipGroup(U64), DuplicateMembership(U64), InvalidBoundaryNode(U64), DuplicateBoundary(U64), InvalidGroupAttachmentEdge(U64), InvalidGroupAttachmentGroup(U64), InvalidGroupAttachmentOffset(U64), DuplicateGroupAttachment(U64), GroupAttachmentNotBoundary(U64), InvalidLabelEdge(U64), InvalidLabelWidth(U64), InvalidLabelHeight(U64), InvalidWaypointEdge(U64), InvalidWaypoint(U64), DuplicateWaypoints(U64), BlockedWaypoint(U64), InvalidGuideEdge(U64), InvalidGuide(U64), DuplicateGuides(U64), SharedEndNeedsEdges(U64), InvalidSharedEndEdge(U64), DuplicateSharedEndEdge(U64), InvalidSharedEndAttachmentOffset(U64), SharedEndMismatch(U64), SharedEndMemberAttachment(U64), SharedEndOverlap(U64), InvalidObstacleGap, InvalidBendPenalty, InvalidSharedPathPenalty, InvalidEdgeGap].{
		is_eq : _

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
			InvalidWaypointEdge(rule) => "Waypoint rule ${rule.to_str()} refers to an edge that does not exist."
			InvalidWaypoint(rule) => "Waypoint rule ${rule.to_str()} contains a point whose x or y value is not finite."
			DuplicateWaypoints(rule) => "Waypoint rule ${rule.to_str()} repeats a rule for the same edge."
			BlockedWaypoint(rule) => "Waypoint rule ${rule.to_str()} contains a point inside an unrelated obstacle."
			InvalidGuideEdge(rule) => "Guide rule ${rule.to_str()} refers to an edge that does not exist."
			InvalidGuide(rule) => "Guide rule ${rule.to_str()} contains a point whose x or y value is not finite."
			DuplicateGuides(rule) => "Guide rule ${rule.to_str()} repeats a rule for the same edge."
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
	default_input = { graph: { nodes: [], edges: [] }, positions: [], groups: [], memberships: [], attachments: [], group_attachments: [], boundaries: [], edge_labels: [], shared_ends: [], waypoints: [], guides: [] }

	## Readable clearance and lane separation, with four bounded joint sweeps.
	default_settings : Settings
	default_settings = { obstacle_gap: 8, bend_penalty: 16, shared_path_penalty: 4, edge_gap: 6, max_sweeps: 4 }

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

## Placement-independent routing preserves the caller's coordinate frame.
expect {
	positions = [Geom.point(0 - 40, 0 - 20), Geom.point(40, 20)]
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => result.layout.positions == positions and result.layout.bounds.x < 0 and result.layout.bounds.y < 0
		Err(_) => False
	}
}

## Ordered waypoint geometry survives routing and simplification.
expect {
	guide = Geom.point(30, 40)
	input = { ..Route.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [{ from: 0, to: 1 }] }, positions: [Geom.point(0, 0), Geom.point(60, 80)], waypoints: [{ edge: 0, points: [guide] }] }
	match Route.layout(input, Route.default_settings) {
		Ok(result) => match result.layout.routes.first() {
			Ok(Polyline(points)) => points.contains(guide)
			_ => False
		}
		Err(_) => False
	}
}

expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, positions: [Geom.point(0, 0)], waypoints: [{ edge: 2, points: [Geom.point(F64.nan, 0)] }, { edge: 2, points: [] }] }
	Route.layout(input, Route.default_settings) == Err([InvalidWaypointEdge(0), InvalidWaypoint(0), InvalidWaypointEdge(1), DuplicateWaypoints(1)])
}

## Soft guides are validated independently from exact waypoints.
expect {
	input = { ..Route.default_input, graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, positions: [Geom.point(0, 0)], guides: [{ edge: 2, points: [Geom.point(F64.nan, 0)] }, { edge: 2, points: [] }] }
	Route.layout(input, Route.default_settings) == Err([InvalidGuideEdge(0), InvalidGuide(0), InvalidGuideEdge(1), DuplicateGuides(1)])
}

## A guide that doubles back is a preference, not an exact geometric
## obligation: the final route remains a simple forward path.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 20, height: 20 }, { width: 20, height: 20 }], edges: [{ from: 0, to: 1 }] },
		positions: [Geom.point(0, 0), Geom.point(120, 0)],
		attachments: [
			{ edge: 0, endpoint: From, attachment: Fixed({ side: Right, offset: 0.5 }) },
			{ edge: 0, endpoint: To, attachment: Fixed({ side: Left, offset: 0.5 }) },
		],
		guides: [{ edge: 0, points: [Geom.point(90, 0), Geom.point(30, 0)] }],
	}
	match Route.layout(input, Route.default_settings) {
		Err(_) => False
		Ok(result) => {
			points = RouteInternals.route_points(result.layout.routes.first() ?? Polyline([]))
			points.fold_with_index(
				True,
				|forward, point, i| match points.get(i + 1) {
					Ok(next) => forward and next.x >= point.x
					Err(_) => forward
				},
			)
		}
	}
}

## Side-only endpoint attachments are flexible ports. Edges sharing one node
## receive stable, distinct positions ordered by their opposite endpoints.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: List.repeat({ width: 20, height: 40 }, 4), edges: [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 0, to: 3 }] },
		positions: [{ x: 0, y: 30 }, { x: 100, y: 0 }, { x: 100, y: 30 }, { x: 100, y: 60 }],
		attachments: [{ edge: 0, endpoint: From, attachment: On(Right) }, { edge: 1, endpoint: From, attachment: On(Right) }, { edge: 2, endpoint: From, attachment: On(Right) }],
	}
	match Route.layout(input, Route.default_settings) {
		Ok(result) => {
			zero = { x: 0, y: 0 }
			a = (result.attachments.get(0) ?? { from: { point: zero, side: Top }, to: { point: zero, side: Top } }).from
			b = (result.attachments.get(1) ?? { from: { point: zero, side: Top }, to: { point: zero, side: Top } }).from
			c = (result.attachments.get(2) ?? { from: { point: zero, side: Top }, to: { point: zero, side: Top } }).from
			a.side == Right and b.side == Right and c.side == Right and a.point.y < b.point.y and b.point.y < c.point.y and b.point.y - a.point.y >= Route.default_settings.edge_gap
		}
		Err(_) => False
	}
}

## Coincident interior channel segments receive stable lanes while route ends
## remain anchored. Horizontal and vertical channel passes use edge_gap.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: List.repeat({ width: 0, height: 0 }, 4), edges: [{ from: 0, to: 1 }, { from: 2, to: 3 }] },
		positions: [{ x: 0, y: 0 }, { x: 50, y: 100 }, { x: 0, y: 10 }, { x: 50, y: 90 }],
		attachments: [
			{ edge: 0, endpoint: From, attachment: Fixed({ side: Right, offset: 0.5 }) },
			{ edge: 0, endpoint: To, attachment: Fixed({ side: Left, offset: 0.5 }) },
			{ edge: 1, endpoint: From, attachment: Fixed({ side: Right, offset: 0.5 }) },
			{ edge: 1, endpoint: To, attachment: Fixed({ side: Left, offset: 0.5 }) },
		],
	}
	routes = [
		Polyline([{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 20 }, { x: 20, y: 20 }, { x: 20, y: 60 }, { x: 40, y: 60 }, { x: 40, y: 100 }, { x: 50, y: 100 }]),
		Polyline([{ x: 0, y: 10 }, { x: 15, y: 10 }, { x: 15, y: 20 }, { x: 20, y: 20 }, { x: 20, y: 60 }, { x: 35, y: 60 }, { x: 35, y: 90 }, { x: 50, y: 90 }]),
	]
	nudged = RouteInternals.nudge_routes(routes, input, Route.default_settings)
	first = RouteInternals.route_points(nudged.get(0) ?? Polyline([]))
	second = RouteInternals.route_points(nudged.get(1) ?? Polyline([]))
	(first.get(3) ?? { x: 0, y: 0 }).x + Route.default_settings.edge_gap == (second.get(3) ?? { x: 0, y: 0 }).x
		and first.first() == Ok({ x: 0, y: 0 })
		and first.last() == Ok({ x: 50, y: 100 })
		and second.first() == Ok({ x: 0, y: 10 })
		and second.last() == Ok({ x: 50, y: 90 })
}

## Every containment boundary receives an implicit Automatic portal. The
## route crosses it once and perpendicularly even without an authored rule.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 10 }, 2), edges: [{ from: 0, to: 1 }] },
		positions: [{ x: 20, y: 30 }, { x: 140, y: 30 }],
		groups: [{ rect: { x: 0, y: 0, width: 60, height: 60 }, parent: Root }],
		memberships: [{ node: 0, group: 0 }],
	}
	match Route.layout(input, Route.default_settings) {
		Ok(result) => match result.group_crossings.first() {
			Ok([crossing]) => crossing.group == 0 and crossing.side == Right and crossing.offset >= 0 and crossing.offset <= 1
			_ => False
		}
		Err(_) => False
	}
}

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

## Parallel edges bound to the same visible ports keep a complete terminal
## escape before their lanes separate. In particular, post-routing lane
## refinement cannot move either route back onto a node boundary.
expect {
	input = {
		..Route.default_input,
		graph: { nodes: [{ width: 160, height: 64 }, { width: 220, height: 88 }], edges: [{ from: 0, to: 1 }, { from: 0, to: 1 }] },
		positions: [{ x: 245, y: 80 }, { x: 180, y: 338 }],
		attachments: [
			{ edge: 0, endpoint: From, attachment: Fixed({ side: Bottom, offset: 0.5 }) },
			{ edge: 0, endpoint: To, attachment: Fixed({ side: Top, offset: 0.5 }) },
			{ edge: 1, endpoint: From, attachment: Fixed({ side: Bottom, offset: 0.5 }) },
			{ edge: 1, endpoint: To, attachment: Fixed({ side: Top, offset: 0.5 }) },
		],
	}
	match Route.layout(input, Route.default_settings) {
		Err(_) => False
		Ok(result) => result.layout.routes.fold_with_index(
			True,
			|ok, route, i| {
				edge = input.graph.edges.get(i) ?? { from: 0, to: 1 }
				a = RouteInternals.terminal(i, From, edge, input)
				b = RouteInternals.terminal(i, To, edge, input)
				RouteInternals.terminal_path_valid(RouteInternals.context(input, Route.default_settings, RouteInternals.node_chains(input)), RouteInternals.route_points(route), edge, a, b) and ok
			},
		)
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
