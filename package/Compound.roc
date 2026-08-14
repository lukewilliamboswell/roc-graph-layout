import Geom
import Layered
import Graph
import Tree
import Constrained
import Route
import CompoundRouting

## Recursive composition of layout groups. A group owns nodes directly or
## owns completed child groups; child boxes are laid out before their parent.
Compound := [
	Group(
		{
			children : List([Node(U64), Nested(Compound)]),
			algorithm : Compound.Algorithm,
			insets : Compound.Insets,
			header : Compound.Header,
			min_width : F64,
			min_height : F64,
		},
	),
].{

	## A layout family selected for one group. Rows and Columns expose only the
	## gap between adjacent completed children. Other variants reuse their
	## family's settings. Force, stress, and constrained pins identify global
	## nodes and use coordinates local to this group. Constrained rules likewise
	## identify global nodes; the group applies each rule to the direct child
	## containing that node. Put a rule in the lowest group that owns all of its
	## referenced nodes.
	Algorithm : [
		Rows({ gap : F64 }),
		Columns({ gap : F64 }),
		LayeredSweep({ settings : Layered.Settings, edge_weights : List({ edge : U64, weight : F64 }), min_spans : List({ edge : U64, span : U64 }) }),
		LayeredExact({ settings : Layered.ExactSettings, edge_weights : List({ edge : U64, weight : F64 }), min_spans : List({ edge : U64, span : U64 }) }),
		GraphCircular(Graph.CircularSettings),
		GraphForce({ settings : { node_gap : F64, repulsion : F64, gravity : F64, opening_angle : F64, max_iterations : U64, tolerance : F64 }, pins : List({ node : U64, x : F64, y : F64 }) }),
		GraphStress({ settings : { node_gap : F64, mode : [Exact, Pivots(U64)], max_iterations : U64, tolerance : F64 }, pins : List({ node : U64, x : F64, y : F64 }) }),
		GraphRadial({ root : [Auto, Node(U64)], ring_gap : F64, node_gap : F64, start_angle : F64, winding : [Clockwise, CounterClockwise] }),
		TreeTidy(Tree.Settings),
		TreeRadial(Tree.RadialSettings),
		ConstrainedStress({ settings : { node_gap : F64, max_iterations : U64, tolerance : F64 }, constraints : List(Constrained.Constraint), pins : List({ node : U64, x : F64, y : F64 }) }),
	]

	## Routing for the complete drawing. Straight connects node boundaries
	## directly. Orthogonal accepts the same visible spacing and path preferences
	## as `Route.layout` and additionally respects group boundaries.
	Routing : [Straight, Orthogonal(Route.Settings)]

	## Empty space reserved between a group's outer boundary and its contents.
	## Use `uniform_insets` for ordinary boxes, or change individual sides when
	## a diagram needs asymmetric space.
	Insets : { top : F64, right : F64, bottom : F64, left : F64 }

	## An optional geometric band reserved at the top of a group. Orthogonal
	## routes avoid this rectangle, so callers can safely draw a measured title
	## or other header content there. The top inset separates the bottom of this
	## band from the group's children.
	Header : [None, Reserve({ height : F64 })]

	## A recursive group. Node references are global node indices. Insets, header,
	## and minimum dimensions apply to every algorithm; algorithm-specific data
	## lives in the selected `Algorithm` variant.
	GroupSpec : Compound

	## The complete graph, recursive ownership tree, routing choice, and optional
	## edge attachment/label data. Every graph node must occur exactly once in
	## `root`. Routing applies after every group has placed its children.
	Input : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
		attachments : List(Route.AttachmentRule),
		group_attachments : List(Route.GroupAttachmentRule),
		edge_labels : List(Route.EdgeLabel),
		root : Compound,
		routing : Routing,
	}

	## The seed selects deterministic variants for force/stress groups. Hints
	## are global-node aligned; a full finite list seeds child proxy placement.
	RunArgs : { seed : U32, hints : List({ x : F64, y : F64 }) }

	## All independently detectable input, group, algorithm, constraint, and
	## routing problems. Group indices use root-first preorder; pin and
	## constraint indices refer to their algorithm payload lists.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		MissingMember(U64),
		DuplicateMember(U64),
		MissingGroupNode(U64, U64),
		InvalidInset(U64, Route.Side),
		InvalidHeaderHeight(U64),
		InvalidRootGroupAttachment(U64),
		InvalidGroupAttachmentEdge(U64),
		InvalidGroupAttachmentGroup(U64),
		InvalidGroupAttachmentOffset(U64),
		DuplicateGroupAttachment(U64),
		GroupAttachmentNotBoundary(U64),
		HeaderAttachmentConflict(U64, U64),
		InvalidMinimumWidth(U64),
		InvalidMinimumHeight(U64),
		InvalidGap(U64),
		MissingPin(U64, U64),
		InvalidPin(U64, U64),
		MissingConstraintNode(U64, U64, U64),
		InvalidGroupAlgorithm(U64),
		InvalidTreeTopology(U64),
		RouteProblem(Route.Problem),
	]

	## The outer rectangle, child-content rectangle, and optional reserved header
	## for one group. Group geometry is returned in root-first preorder.
	GroupGeometry : { rect : Geom.Rect, content : Geom.Rect, header : [None, Some(Geom.Rect)] }

	## Index-aligned node and edge geometry plus root-first group geometry. The
	## root outer rectangle equals `layout.bounds` and contains every child group,
	## route, and label box; its content rectangle excludes its insets and header.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			routes : List(Geom.Route),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
		},

		## Root-first preorder, so parent containment can be checked in one pass.
		groups : List(GroupGeometry),
		label_anchors : List({ x : F64, y : F64 }),
		attachments : List(Route.EdgeAttachments),
		group_crossings : List(List(Route.GroupCrossing)),
	}

	## Build equal insets on all four sides.
	uniform_insets : F64 -> Insets
	uniform_insets = |amount| { top: amount, right: amount, bottom: amount, left: amount }

	## Sixteen layout units on every side.
	default_insets : Insets
	default_insets = Compound.uniform_insets(16)

	## An empty row group with 24 units between children, 16-unit insets, and no
	## reserved header.
	## Replace its fields by record update when building each recursive group.
	default_group : Compound
	default_group = Group({
		children: [],
		algorithm: Rows({ gap: 24 }),
		insets: Compound.default_insets,
		header: None,
		min_width: 0,
		min_height: 0,
	})

	## Default deterministic orthogonal routing. Replace or record-update it on
	## `Input` when the whole drawing needs different routing.
	default_routing : Routing
	default_routing = Orthogonal(Route.default_settings)

	## Empty graph and group with default orthogonal routing.
	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, attachments: [], group_attachments: [], edge_labels: [], root: Compound.default_group, routing: Compound.default_routing }

	## Fixed seed and no position hints.
	default_run : RunArgs
	default_run = { seed: 0, hints: [] }

	## Validate the complete recursive input and lay out every group bottom-up.
	## Every global node must occur exactly once. Output positions and routes
	## retain global node and edge order; group geometry uses root preorder.
	layout : Input, RunArgs -> [Ok(Result), Err(List(Problem))]
	layout = |input, args| {
		problems = CompoundInternals.problems(input)
		if problems.is_empty() {
			Ok(CompoundInternals.place(input, args))
		} else {
			Err(problems)
		}
	}
}

CompoundInternals :: {}.{
	problems : Input -> List(Problem)
	problems = |input| {
		node_count = input.graph.nodes.len()
		node_problems = input.graph.nodes.map_with_index(
			|node, i| {
				width_problem = if F64.is_finite(node.width) and node.width >= 0 {
					[]
				} else {
					[InvalidNodeWidth(i)]
				}
				height_problem = if F64.is_finite(node.height) and node.height >= 0 {
					[]
				} else {
					[InvalidNodeHeight(i)]
				}
				List.concat(width_problem, height_problem)
			},
		).join()
		edge_problems = input.graph.edges.map_with_index(
			|edge, i| {
				start = if edge.from < node_count {
					[]
				} else {
					[MissingEdgeStart(i, edge.from)]
				}
				end = if edge.to < node_count {
					[]
				} else {
					[MissingEdgeEnd(i, edge.to)]
				}
				List.concat(start, end)
			},
		).join()
		walked = CompoundInternals.check_group(input.root, node_count, input.graph.edges, 0)
		root_attachment_problems = input.group_attachments.fold_with_index(
			[],
			|acc, rule, i| if rule.group == 0 {
				acc.append(InvalidRootGroupAttachment(i))
			} else {
				acc
			},
		)
		infos = CompoundInternals.group_infos(input.root, 0).infos
		group_attachment_problems = input.group_attachments.fold_with_index(
			[],
			|acc, rule, i| {
				edge_valid = rule.edge < input.graph.edges.len()
				group_valid = rule.group < infos.len()
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
				c = match rule.attachment {
					Fixed(payload) if !F64.is_finite(payload.offset) or payload.offset < 0 or payload.offset > 1 => b.append(InvalidGroupAttachmentOffset(i))
					_ => b
				}
				d = if input.group_attachments.fold_with_index(False, |found, other, j| found or (j < i and other.edge == rule.edge and other.group == rule.group)) {
					c.append(DuplicateGroupAttachment(i))
				} else {
					c
				}
				if edge_valid and group_valid and rule.group > 0 {
					edge = input.graph.edges.get(rule.edge) ?? { from: 0, to: 0 }
					members = (infos.get(rule.group) ?? { index: 0, members: [], header: False, top_inset: 0 }).members
					if members.contains(edge.from) != members.contains(edge.to) {
						d
					} else {
						d.append(GroupAttachmentNotBoundary(i))
					}
				} else {
					d
				}
			},
		)
		membership = List.repeat(0, node_count).map_with_index(
			|_, node| {
				count = walked.members.fold(
					0,
					|n, member| if member == node {
						n + 1
					} else {
						n
					},
				)
				if count == 0 {
					[MissingMember(node)]
				} else if count > 1 {
					[DuplicateMember(node)]
				} else {
					[]
				}
			},
		).join()
		route_settings = match input.routing {
			Straight => Route.default_settings
			Orthogonal(settings) => settings
		}
		header_attachment_problems = match input.routing {
			Straight => []
			Orthogonal(settings) => CompoundInternals.group_infos(input.root, 0).infos.fold(
				[],
				|acc, info| if info.header and info.top_inset < settings.obstacle_gap {
					input.attachments.fold_with_index(
						acc,
						|found, rule, i| {
							node = match input.graph.edges.get(rule.edge) {
								Ok(edge) => match rule.endpoint {
									From => edge.from
									To => edge.to
								}
								Err(_) => node_count
							}
							top = match rule.attachment {
								On(Top) | Fixed({ side: Top, .. }) => True
								_ => False
							}
							if top and info.members.contains(node) {
								found.append(HeaderAttachmentConflict(i, info.index))
							} else {
								found
							}
						},
					)
				} else {
					acc
				},
			)
		}
		route_problem = match Route.layout({ graph: input.graph, positions: List.repeat({ x: 0, y: 0 }, node_count), groups: [], memberships: [], attachments: input.attachments, boundaries: [], group_attachments: [], edge_labels: input.edge_labels }, route_settings) {
			Ok(_) => []
			Err(problems) => problems.keep_oks(
				|problem| match problem {
					InvalidNodeWidth(_) | InvalidNodeHeight(_) | PositionCountMismatch | InvalidPosition(_) | InvalidEdgeFrom(_) | InvalidEdgeTo(_) => Err({})
					_ => Ok(RouteProblem(problem))
				},
			)
		}
		[node_problems, edge_problems, walked.problems, membership, root_attachment_problems, group_attachment_problems, header_attachment_problems, route_problem].join()
	}

	check_group : Compound, U64, List({ from : U64, to : U64 }), U64 -> { members : List(U64), problems : List(Problem), next : U64 }
	check_group = |group_value, node_count, edges, group_index| {
		group = match group_value {
			Group(spec) => spec
		}
		inset_problem = |amount, side| if F64.is_finite(amount) and amount >= 0 {
			[]
		} else {
			[InvalidInset(group_index, side)]
		}
		header_problems = match group.header {
			None => []
			Reserve({ height }) if F64.is_finite(height) and height >= 0 => []
			Reserve(_) => [InvalidHeaderHeight(group_index)]
		}
		settings = [
			inset_problem(group.insets.top, Top),
			inset_problem(group.insets.right, Right),
			inset_problem(group.insets.bottom, Bottom),
			inset_problem(group.insets.left, Left),
			header_problems,
			if F64.is_finite(group.min_width) and group.min_width >= 0 {
				[]
			} else {
				[InvalidMinimumWidth(group_index)]
			},
			if F64.is_finite(group.min_height) and group.min_height >= 0 {
				[]
			} else {
				[InvalidMinimumHeight(group_index)]
			},
			if match group.algorithm {
				Rows(payload) | Columns(payload) => F64.is_finite(payload.gap) and payload.gap >= 0
				_ => True
			} {
				[]
			} else {
				[InvalidGap(group_index)]
			},
		].join()
		initial = { members: [], problems: settings, next: group_index + 1 }
		children_checked = group.children.fold(
			initial,
			|state, child|
				match child {
					Node(node) => {
						missing = if node < node_count {
							[]
						} else {
							[MissingGroupNode(group_index, node)]
						}
						{ members: state.members.append(node), problems: List.concat(state.problems, missing), next: state.next }
					}
					Nested(nested) => {
						checked = CompoundInternals.check_group(nested, node_count, edges, state.next)
						{ members: List.concat(state.members, checked.members), problems: List.concat(state.problems, checked.problems), next: checked.next }
					}
				},
		)
		pins = match group.algorithm {
			GraphForce(payload) => payload.pins
			GraphStress(payload) => payload.pins
			ConstrainedStress(payload) => payload.pins
			_ => []
		}
		constraints = match group.algorithm {
			ConstrainedStress(payload) => payload.constraints
			_ => []
		}
		pin_problems = pins.map_with_index(
			|pin, i|
				if pin.node >= node_count or !children_checked.members.contains(pin.node) {
					[MissingPin(group_index, i)]
				} else if !F64.is_finite(pin.x) or !F64.is_finite(pin.y) {
					[InvalidPin(group_index, i)]
				} else {
					[]
				},
		).join()
		constraint_problems = constraints.map_with_index(
			|constraint, i| {
				CompoundInternals.constraint_nodes(constraint).map(
					|node| if node < node_count and children_checked.members.contains(node) {
						[]
					} else {
						[MissingConstraintNode(group_index, i, node)]
					},
				).join()
			},
		).join()
		partitions = group.children.map(|child| CompoundInternals.members_of(child))
		local_edges = edges.keep_oks(
			|edge| match (CompoundInternals.owner_members(partitions, edge.from), CompoundInternals.owner_members(partitions, edge.to)) {
				(Some(from), Some(to)) if from != to => Ok({ from, to })
				_ => Err({})
			},
		)
		tree_problem = match group.algorithm {
			TreeTidy(_) | TreeRadial(_) if !CompoundInternals.is_tree(partitions.len(), local_edges) => [InvalidTreeTopology(group_index)]
			_ => []
		}
		local_constraints = constraints.keep_oks(|constraint| CompoundInternals.local_constraint(constraint, partitions))
		algorithm_check = CompoundInternals.algorithm_positions(group.algorithm, List.repeat({ width: 0, height: 0 }, partitions.len()), local_edges, [], [], local_constraints, 0)
		algorithm_problem = if algorithm_check.valid {
			[]
		} else {
			[InvalidGroupAlgorithm(group_index)]
		}
		{ members: children_checked.members, problems: [children_checked.problems, pin_problems, constraint_problems, tree_problem, algorithm_problem].join(), next: children_checked.next }
	}

	group_infos = |group_value, group_index| {
		group = match group_value {
			Group(spec) => spec
		}
		children = group.children.fold(
			{ infos: [], next: group_index + 1 },
			|state, child| match child {
				Node(_) => state
				Nested(nested) => {
					nested_infos = CompoundInternals.group_infos(nested, state.next)
					{ infos: state.infos.concat(nested_infos.infos), next: nested_infos.next }
				}
			},
		)
		info = {
			index: group_index,
			members: CompoundInternals.members_of(Nested(group_value)),
			header: match group.header {
				None => False
				Reserve(_) => True
			},
			top_inset: group.insets.top,
		}
		{ infos: [info].concat(children.infos), next: children.next }
	}

	place : Input, RunArgs -> Result
	place = |input, args| {
		placed = CompoundInternals.place_group(input.root, input.graph.nodes, input.graph.edges, args.hints, args.seed, 0)
		root_spec = match input.root {
			Group(spec) => spec
		}
		positions = List.repeat({ x: 0, y: 0 }, input.graph.nodes.len()).map_with_index(
			|_, node| {
				found = placed.nodes.find_first(|item| item.node == node)
				match found {
					Ok(item) => { x: Geom.saturate(item.x), y: Geom.saturate(item.y) }
					Err(_) => { x: 0, y: 0 }
				}
			},
		)
		straight_routes = input.graph.edges.map_with_index(|edge, edge_index| CompoundRouting.straight_route(edge_index, edge, input.graph.nodes, positions, input.attachments))
		route_group_rects = placed.groups.drop_first(1).map(|geometry| geometry.rect)
		route_groups = route_group_rects.map_with_index(
			|rect, i| {
				parent = route_group_rects.fold_with_index(
					Root,
					|best, candidate, j| if j < i and CompoundInternals.rect_contains(candidate, rect) {
						Parent(j)
					} else {
						best
					},
				)
				{ rect, parent }
			},
		)
		memberships = positions.fold_with_index(
			[],
			|acc, point, node| match CompoundInternals.innermost_group(point, route_group_rects) {
				Some(group) => acc.append({ node, group })
				None => acc
			},
		)
		route_gap = match input.routing {
			Straight => 0
			Orthogonal(settings) => settings.obstacle_gap
		}
		header_obstacles = placed.groups.keep_oks(
			|geometry| match geometry.header {
				Some(rect) => Ok({ x: rect.x + route_gap.min(rect.width / 2), y: rect.y + route_gap.min(rect.height / 2), width: (rect.width - route_gap * 2).max(0), height: (rect.height - route_gap * 2).max(0) })
				None => Err({})
			},
		)
		route_nodes = input.graph.nodes.concat(header_obstacles.map(|rect| { width: rect.width, height: rect.height }))
		route_positions = positions.concat(header_obstacles.map(|rect| { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 }))
		route_graph = { nodes: route_nodes, edges: input.graph.edges }
		route_group_attachments = input.group_attachments.keep_oks(
			|rule| if rule.group == 0 {
				Err({})
			} else {
				Ok({ ..rule, group: rule.group - 1 })
			},
		)
		routed = match input.routing {
			Orthogonal(settings) if !input.graph.nodes.is_empty() =>
				match Route.layout({ graph: route_graph, positions: route_positions, groups: route_groups, memberships, attachments: input.attachments, boundaries: [], group_attachments: route_group_attachments, edge_labels: input.edge_labels }, settings) {
					Ok(result) => { positions: result.layout.positions.drop_last(header_obstacles.len()), routes: result.layout.routes, bounds: result.layout.bounds, label_anchors: result.label_anchors, attachments: result.attachments, group_crossings: result.group_crossings }
					Err(_) => { positions, routes: straight_routes, bounds: placed.rect, label_anchors: [], attachments: [], group_crossings: List.repeat([], input.graph.edges.len()) }
				}
			_ => { positions, routes: straight_routes, bounds: placed.rect, label_anchors: input.edge_labels.map(|label| CompoundRouting.route_anchor(straight_routes.get(label.edge) ?? Polyline([]), label.placement)), attachments: [], group_crossings: List.repeat([], input.graph.edges.len()) }
		}
		shift = match (positions.first(), routed.positions.first()) {
			(Ok(before), Ok(after)) => { x: after.x - before.x, y: after.y - before.y }
			_ => { x: 0, y: 0 }
		}
		placed_groups = placed.groups.map(|geometry| CompoundInternals.move_group_geometry(geometry, shift))
		stitched_routes = routed.routes
		raw_label_anchors = routed.label_anchors
		header_height = match root_spec.header {
			None => 0
			Reserve(payload) => payload.height
		}
		root_content = match placed.groups.first() {
			Ok(geometry) => geometry.content
			Err(_) => placed.rect
		}
		extent = CompoundRouting.drawing_extent(root_content, shift, input.graph.nodes, routed.positions, stitched_routes, input.edge_labels, raw_label_anchors)
		normalize = { x: root_spec.insets.left - extent.x, y: root_spec.insets.top + header_height - extent.y }
		root_width = Geom.saturate(extent.width + root_spec.insets.left + root_spec.insets.right)
		root_height = Geom.saturate(extent.height + root_spec.insets.top + header_height + root_spec.insets.bottom)
		move_point = |point| { x: Geom.saturate(point.x + normalize.x), y: Geom.saturate(point.y + normalize.y) }
		positions_final = routed.positions.map(move_point)
		routes_final = stitched_routes.map(|route| CompoundRouting.move_route(route, normalize))
		attachments_final = routed.attachments.map(|ends| { from: { ..ends.from, point: move_point(ends.from.point) }, to: { ..ends.to, point: move_point(ends.to.point) } })
		group_crossings_final = routed.group_crossings.map(|crossings| crossings.map(|crossing| { ..crossing, point: move_point(crossing.point) }))
		groups = placed_groups.map_with_index(
			|geometry, i| if i == 0 {
				{
					rect: { x: 0, y: 0, width: root_width, height: root_height },
					content: { x: root_spec.insets.left, y: root_spec.insets.top + header_height, width: extent.width, height: extent.height },
					header: match root_spec.header {
						None => None
						Reserve(_) => Some({ x: 0, y: 0, width: root_width, height: header_height })
					},
				}
			} else {
				CompoundInternals.move_group_geometry(geometry, normalize)
			},
		)
		label_anchors = raw_label_anchors.map(move_point)
		{ layout: { positions: positions_final, routes: routes_final, bounds: { x: 0, y: 0, width: root_width, height: root_height } }, groups, label_anchors, attachments: attachments_final, group_crossings: group_crossings_final }
	}

	rect_contains = |outer, inner| inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.width <= outer.x + outer.width and inner.y + inner.height <= outer.y + outer.height

	innermost_group = |point, rects| rects.fold_with_index(
		None,
		|best, rect, i| if point.x >= rect.x and point.x <= rect.x + rect.width and point.y >= rect.y and point.y <= rect.y + rect.height {
			Some(i)
		} else {
			best
		},
	)

	place_group : Compound,
	List({ width : F64, height : F64 }),
	List({ from : U64, to : U64 }),
	List({ x : F64, y : F64 }),
	U32,
	U64 -> {
		nodes : List({ node : U64, x : F64, y : F64 }),
		groups : List(Compound.GroupGeometry),
		rect : { x : F64, y : F64, width : F64, height : F64 },
	}
	place_group = |group_value, sizes, edges, hints, seed, depth| {
		group = match group_value {
			Group(spec) => spec
		}
		items = group.children.map(
			|child|
				match child {
					Node(node) => {
						size = sizes.get(node) ?? { width: 0, height: 0 }
						{ nodes: [{ node, x: size.width / 2, y: size.height / 2 }], groups: [], members: [node], width: size.width, height: size.height }
					}
					Nested(nested) => {
						child_placed = CompoundInternals.place_group(nested, sizes, edges, hints, seed, depth + 1)
						{ nodes: child_placed.nodes, groups: child_placed.groups, members: child_placed.nodes.map(|p| p.node), width: child_placed.rect.width, height: child_placed.rect.height }
					}
				},
		)
		local_edges = edges.keep_oks(
			|edge| {
				from = CompoundInternals.owner_index(items, edge.from)
				to = CompoundInternals.owner_index(items, edge.to)
				match (from, to) {
					(Some(a), Some(b)) if a != b => Ok({ from: a, to: b })
					_ => Err({})
				}
			},
		)
		proxy_nodes = items.map(|item| { width: item.width, height: item.height })
		local_hints = items.map(|item| CompoundInternals.member_hint(item.members, hints))
		pins = match group.algorithm {
			GraphForce(payload) => payload.pins
			GraphStress(payload) => payload.pins
			ConstrainedStress(payload) => payload.pins
			_ => []
		}
		constraints = match group.algorithm {
			ConstrainedStress(payload) => payload.constraints
			_ => []
		}
		local_pins = pins.keep_oks(
			|pin| match CompoundInternals.owner_index(items, pin.node) {
				Some(node) => Ok({ node, x: pin.x, y: pin.y })
				None => Err({})
			},
		)
		partitions = items.map(|item| item.members)
		local_constraints = constraints.keep_oks(|constraint| CompoundInternals.local_constraint(constraint, partitions))
		usable_hints = if hints.len() == sizes.len() and local_hints.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) {
			local_hints
		} else {
			[]
		}
		proxy_positions = CompoundInternals.algorithm_positions(group.algorithm, proxy_nodes, local_edges, usable_hints, local_pins, local_constraints, seed).positions
		laid = items.map_with_index(
			|item, i| {
				position = proxy_positions.get(i) ?? { x: item.width / 2, y: item.height / 2 }
				header_height = match group.header {
					None => 0
					Reserve(payload) => payload.height
				}
				dx = position.x - item.width / 2 + group.insets.left
				dy = position.y - item.height / 2 + group.insets.top + header_height
				{
					nodes: item.nodes.map(|p| { node: p.node, x: p.x + dx, y: p.y + dy }),
					groups: item.groups.map(|geometry| CompoundInternals.move_group_geometry(geometry, { x: dx, y: dy })),
				}
			},
		)
		laid_nodes = laid.map(|item| item.nodes).join()
		laid_groups = laid.map(|item| item.groups).join()
		content_width = items.map_with_index(|item, i| (proxy_positions.get(i) ?? { x: 0, y: 0 }).x + item.width / 2).fold(0, |a, b| a.max(b))
		content_height = items.map_with_index(|item, i| (proxy_positions.get(i) ?? { x: 0, y: 0 }).y + item.height / 2).fold(0, |a, b| a.max(b))
		header_height = match group.header {
			None => 0
			Reserve(payload) => payload.height
		}
		natural_width = content_width + group.insets.left + group.insets.right
		natural_height = content_height + group.insets.top + header_height + group.insets.bottom
		width = Geom.saturate(natural_width.max(group.min_width))
		height = Geom.saturate(natural_height.max(group.min_height))
		center_dx = (width - natural_width).max(0) / 2
		center_dy = (height - natural_height).max(0) / 2
		centered_nodes = laid_nodes.map(|p| { node: p.node, x: Geom.saturate(p.x + center_dx), y: Geom.saturate(p.y + center_dy) })
		centered_children = laid_groups.map(|geometry| CompoundInternals.move_group_geometry(geometry, { x: center_dx, y: center_dy }))
		root_rect = { x: 0, y: 0, width, height }
		content = { x: group.insets.left, y: group.insets.top + header_height, width: Geom.saturate(width - group.insets.left - group.insets.right), height: Geom.saturate(height - group.insets.top - header_height - group.insets.bottom) }
		header = match group.header {
			None => None
			Reserve(_) => Some({ x: 0, y: 0, width, height: header_height })
		}
		root_geometry = { rect: root_rect, content, header }
		{ nodes: centered_nodes, groups: List.concat([root_geometry], centered_children), rect: root_rect }
	}

	move_group_geometry = |geometry, delta| {
		move_rect = |rect| { x: Geom.saturate(rect.x + delta.x), y: Geom.saturate(rect.y + delta.y), width: rect.width, height: rect.height }
		{
			rect: move_rect(geometry.rect),
			content: move_rect(geometry.content),
			header: match geometry.header {
				None => None
				Some(rect) => Some(move_rect(rect))
			},
		}
	}

	algorithm_positions : Compound.Algorithm, List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), List({ x : F64, y : F64 }), List({ node : U64, x : F64, y : F64 }), List(Constrained.Constraint), U32 -> { positions : List({ x : F64, y : F64 }), valid : Bool }
	algorithm_positions = |algorithm, nodes, edges, hints, pins, constraints, seed| {
		fallback = |vertical| CompoundInternals.linear_positions(nodes, 24, vertical)
		match algorithm {
			Rows(payload) => { positions: CompoundInternals.linear_positions(nodes, payload.gap, False), valid: True }
			Columns(payload) => { positions: CompoundInternals.linear_positions(nodes, payload.gap, True), valid: True }
			LayeredSweep(payload) =>
				match Layered.layout({ ..Layered.default_input, graph: { nodes, edges }, edge_weights: payload.edge_weights, min_spans: payload.min_spans }, payload.settings, { ..Layered.default_run, hints }) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			LayeredExact(payload) =>
				match Layered.layout_exact({ ..Layered.default_input, graph: { nodes, edges }, edge_weights: payload.edge_weights, min_spans: payload.min_spans }, payload.settings) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			GraphCircular(settings) =>
				match Graph.layout_circular({ nodes, edges }, settings) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			GraphForce(payload) => {
				settings = { node_gap: payload.settings.node_gap, repulsion: payload.settings.repulsion, gravity: payload.settings.gravity, opening_angle: payload.settings.opening_angle, max_iterations: payload.settings.max_iterations, tolerance: payload.settings.tolerance, pins }
				match Graph.layout_force({ nodes, edges }, settings, { seed, hints }) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			}
			GraphStress(payload) => {
				settings = { node_gap: payload.settings.node_gap, mode: payload.settings.mode, max_iterations: payload.settings.max_iterations, tolerance: payload.settings.tolerance, pins }
				match Graph.layout_stress({ nodes, edges }, settings, { seed, hints }) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			}
			GraphRadial(settings) =>
				match Graph.layout_radial({ nodes, edges }, settings) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			TreeTidy(settings) => {
				if !CompoundInternals.is_tree(nodes.len(), edges) {
					{ positions: fallback(False), valid: False }
				} else {
					root = CompoundInternals.tree_root(nodes.len(), edges)
					match Tree.layout(CompoundInternals.tree_from(root, nodes, edges), settings) {
						Ok(result) => { positions: CompoundInternals.unorder_tree(result.layout.positions, CompoundInternals.tree_preorder(root, edges), nodes.len()), valid: True }
						Err(_) => { positions: fallback(False), valid: False }
					}
				}
			}
			TreeRadial(settings) => {
				if !CompoundInternals.is_tree(nodes.len(), edges) {
					{ positions: fallback(False), valid: False }
				} else {
					root = CompoundInternals.tree_root(nodes.len(), edges)
					match Tree.layout_radial(CompoundInternals.tree_from(root, nodes, edges), settings) {
						Ok(result) => { positions: CompoundInternals.unorder_tree(result.layout.positions, CompoundInternals.tree_preorder(root, edges), nodes.len()), valid: True }
						Err(_) => { positions: fallback(False), valid: False }
					}
				}
			}
			ConstrainedStress(payload) => {
				settings = { node_gap: payload.settings.node_gap, max_iterations: payload.settings.max_iterations, tolerance: payload.settings.tolerance, pins }
				match Constrained.layout({ graph: { nodes, edges }, constraints }, settings, { seed, hints }) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			}
		}
	}

	linear_positions : List({ width : F64, height : F64 }), F64, Bool -> List({ x : F64, y : F64 })
	linear_positions = |nodes, gap, vertical| nodes.fold(
		{ cursor: 0, positions: [] },
		|state, node| {
			position = if vertical {
				{ x: node.width / 2, y: state.cursor + node.height / 2 }
			} else {
				{ x: state.cursor + node.width / 2, y: node.height / 2 }
			}
			next = state.cursor + (
				if vertical {
					node.height
				} else {
					node.width
				}
			) + gap
			{ cursor: next, positions: state.positions.append(position) }
		},
	).positions

	members_of : [Node(U64), Nested(Compound)] -> List(U64)
	members_of = |child| match child {
		Node(node) => [node]
		Nested(Group(spec)) => spec.children.map(|nested| CompoundInternals.members_of(nested)).join()
	}

	constraint_nodes : Constrained.Constraint -> List(U64)
	constraint_nodes = |constraint| match constraint {
		Separate(payload) => [payload.first, payload.second]
		Align(payload) => payload.nodes
		Inside(payload) => payload.nodes
	}

	local_constraint : Constrained.Constraint, List(List(U64)) -> [Ok(Constrained.Constraint), Err({})]
	local_constraint = |constraint, partitions| match constraint {
		Separate(payload) => match (CompoundInternals.owner_members(partitions, payload.first), CompoundInternals.owner_members(partitions, payload.second)) {
			(Some(first), Some(second)) => Ok(Separate({ ..payload, first, second }))
			_ => Err({})
		}
		Align(payload) => {
			nodes = payload.nodes.keep_oks(
				|node| match CompoundInternals.owner_members(partitions, node) {
					Some(owner) => Ok(owner)
					None => Err({})
				},
			)
			if nodes.len() == payload.nodes.len() {
				Ok(Align({ nodes, axis: payload.axis }))
			} else {
				Err({})
			}
		}
		Inside(payload) => {
			nodes = payload.nodes.keep_oks(
				|node| match CompoundInternals.owner_members(partitions, node) {
					Some(owner) => Ok(owner)
					None => Err({})
				},
			)
			if nodes.len() == payload.nodes.len() {
				Ok(Inside({ ..payload, nodes }))
			} else {
				Err({})
			}
		}
	}

	owner_members : List(List(U64)), U64 -> [Some(U64), None]
	owner_members = |partitions, node| match partitions.map(|members| members.contains(node)).find_first_index(|yes| yes) {
		Ok(i) => Some(i)
		Err(_) => None
	}

	is_tree : U64, List({ from : U64, to : U64 }) -> Bool
	is_tree = |count, edges| {
		if count == 0 {
			False
		} else {
			indegrees = List.repeat(0, count).map_with_index(
				|_, node| edges.fold(
					0,
					|n, edge| if edge.to == node {
						n + 1
					} else {
						n
					},
				),
			)
			indegrees.keep_if(|n| n == 0).len() == 1 and indegrees.keep_if(|n| n == 1).len() == count - 1 and edges.len() == count - 1
		}
	}

	tree_root : U64, List({ from : U64, to : U64 }) -> U64
	tree_root = |count, edges| List.repeat(0, count).map_with_index(|_, node| node).find_first(|node| !edges.any(|edge| edge.to == node)) ?? 0

	tree_from : U64, List({ width : F64, height : F64 }), List({ from : U64, to : U64 }) -> Tree.Spec
	tree_from = |node, nodes, edges| {
		size = nodes.get(node) ?? { width: 0, height: 0 }
		{ width: size.width, height: size.height, children: edges.keep_if(|edge| edge.from == node).map(|edge| CompoundInternals.tree_from(edge.to, nodes, edges)) }
	}

	tree_preorder : U64, List({ from : U64, to : U64 }) -> List(U64)
	tree_preorder = |node, edges| [node].concat(edges.keep_if(|edge| edge.from == node).map(|edge| CompoundInternals.tree_preorder(edge.to, edges)).join())

	unorder_tree : List({ x : F64, y : F64 }), List(U64), U64 -> List({ x : F64, y : F64 })
	unorder_tree = |positions, order, count| List.repeat({ x: 0, y: 0 }, count).map_with_index(
		|_, node| match order.find_first_index(|candidate| candidate == node) {
			Ok(i) => positions.get(i) ?? { x: 0, y: 0 }
			Err(_) => { x: 0, y: 0 }
		},
	)

	owner_index : List({ members : List(U64), .. }), U64 -> [Some(U64), None]
	owner_index = |items, node| match items.map(|item| item.members.contains(node)).find_first_index(|yes| yes) {
		Ok(i) => Some(i)
		Err(_) => None
	}

	member_hint : List(U64), List({ x : F64, y : F64 }) -> { x : F64, y : F64 }
	member_hint = |members, hints| {
		points = members.keep_oks(|node| hints.get(node))
		if points.is_empty() {
			{ x: 0, y: 0 }
		} else {
			count = points.len().to_f64()
			{ x: points.map(|p| p.x).sum() / count, y: points.map(|p| p.y).sum() / count }
		}
	}
}

## Empty recursive input is total.
expect Compound.layout(Compound.default_input, Compound.default_run) == Ok({
	layout: { positions: [], routes: [], bounds: { x: 0, y: 0, width: 32, height: 32 } },
	groups: [{ rect: { x: 0, y: 0, width: 32, height: 32 }, content: { x: 16, y: 16, width: 0, height: 0 }, header: None }],
	label_anchors: [],
	attachments: [],
	group_crossings: [],
})

## Insets and header height are independent geometric inputs, so all invalid
## sides are reported together instead of silently repaired.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, insets: { top: 0 - 1.0, right: F64.infinity, bottom: 3, left: 0 - 2.0 }, header: Reserve({ height: 0 - 4.0 }) })
	match Compound.layout({ ..Compound.default_input, root }, Compound.default_run) {
		Err(problems) => problems.contains(InvalidInset(0, Top)) and problems.contains(InvalidInset(0, Right)) and problems.contains(InvalidInset(0, Left)) and problems.contains(InvalidHeaderHeight(0))
		Ok(_) => False
	}
}

## Straight routing honors each label's semantic position along its edge.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0), Node(1)], algorithm: Rows({ gap: 80 }) })
	input = { ..Compound.default_input, graph: { nodes: List.repeat({ width: 10, height: 10 }, 2), edges: [{ from: 0, to: 1 }] }, root, routing: Straight, edge_labels: [{ edge: 0, width: 0, height: 0, placement: Near(From) }, { edge: 0, width: 0, height: 0, placement: Near(To) }] }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.label_anchors.get(0), result.label_anchors.get(1)) {
			(Ok(a), Ok(b)) => a.x < b.x
			_ => False
		}
		Err(_) => False
	}
}

## Route growth rebuilds the root's content and header from the final bounds.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0)], insets: { top: 3, right: 5, bottom: 7, left: 11 }, header: Reserve({ height: 13 }) })
	input = { ..Compound.default_input, graph: { nodes: [{ width: 10, height: 10 }], edges: [{ from: 0, to: 0 }] }, root }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match result.groups.first() {
			Ok(geometry) => geometry.rect == result.layout.bounds and geometry.content == { x: 11, y: 16, width: geometry.rect.width - 16, height: geometry.rect.height - 23 } and geometry.header == Some({ x: 0, y: 0, width: geometry.rect.width, height: 13 })
			Err(_) => False
		}
		Err(_) => False
	}
}

## A fixed top departure cannot silently cross a reserved header when the
## configured top inset is smaller than the router's clearance.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0), Node(1)], header: Reserve({ height: 12 }), insets: { ..Compound.default_insets, top: 0 } })
	input = { ..Compound.default_input, graph: { nodes: List.repeat({ width: 10, height: 10 }, 2), edges: [{ from: 0, to: 1 }] }, root, attachments: [{ edge: 0, endpoint: From, attachment: On(Top) }] }
	match Compound.layout(input, Compound.default_run) {
		Err(problems) => problems.contains(HeaderAttachmentConflict(0, 0))
		Ok(_) => False
	}
}

## Asymmetric insets, a reserved header, and minimum dimensions all remain
## visible in the returned group geometry, including for an empty group.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, insets: { top: 2, right: 7, bottom: 11, left: 5 }, header: Reserve({ height: 13 }), min_width: 40, min_height: 50 })
	match Compound.layout({ ..Compound.default_input, root }, Compound.default_run) {
		Ok(result) => match result.groups.first() {
			Ok(geometry) => geometry.rect == { x: 0, y: 0, width: 40, height: 50 } and geometry.content == { x: 5, y: 15, width: 28, height: 24 } and geometry.header == Some({ x: 0, y: 0, width: 40, height: 13 })
			Err(_) => False
		}
		Err(_) => False
	}
}

## Routing settings are validated through the shared Route vocabulary instead
## of being collapsed into one opaque metadata problem.
expect {
	input = { ..Compound.default_input, routing: Orthogonal({ ..Route.default_settings, obstacle_gap: 0 - 1.0 }) }
	Compound.layout(input, Compound.default_run) == Err([RouteProblem(InvalidObstacleGap)])
}

## Row and column spacing belongs to the algorithms that consume it.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, algorithm: Rows({ gap: 0 - 1.0 }) })
	match Compound.layout({ ..Compound.default_input, root }, Compound.default_run) {
		Err(problems) => problems.contains(InvalidGap(0))
		Ok(_) => False
	}
}

## Membership is exact: missing and duplicate nodes are both reported.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	group = Group({ ..base, children: [Node(0), Node(0)] })
	input = { graph: { nodes: [{ width: 2, height: 2 }, { width: 2, height: 2 }], edges: [] }, attachments: [], group_attachments: [], edge_labels: [], root: group, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Err(problems) => problems.contains(DuplicateMember(0)) and problems.contains(MissingMember(1))
		Ok(_) => False
	}
}

## Constraint references use global node identities and report the exact
## group, constraint, and missing node.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0)], algorithm: ConstrainedStress({ settings: { node_gap: 1, max_iterations: 10, tolerance: 0.001 }, constraints: [Align({ axis: X, nodes: [0, 1] })], pins: [] }) })
	input = { ..Compound.default_input, graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, root, routing: Straight }
	match Compound.layout(input, Compound.default_run) {
		Err(problems) => problems.contains(MissingConstraintNode(0, 0, 1))
		Ok(_) => False
	}
}

## A sibling group that is not part of an edge's containment path is an
## obstacle. The final route may touch its boundary but does not enter it.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	left = Group({ ..base, insets: Compound.uniform_insets(4), children: [Node(0)] })
	middle = Group({ ..base, insets: Compound.uniform_insets(20), children: [Node(1)] })
	right = Group({ ..base, insets: Compound.uniform_insets(4), children: [Node(2)] })
	root = Group({ ..base, insets: Compound.uniform_insets(4), children: [Nested(left), Nested(middle), Nested(right)], algorithm: Rows({ gap: 8 }) })
	input = { graph: { nodes: List.repeat({ width: 10, height: 10 }, 3), edges: [{ from: 0, to: 2 }] }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.groups.get(2), result.layout.routes.get(0)) {
			(Ok(geometry), Ok(route)) => {
				rect = geometry.rect
				box = { min_x: rect.x, min_y: rect.y, max_x: rect.x + rect.width, max_y: rect.y + rect.height }
				points = CompoundRouting.route_points(route)
				points.fold_with_index(
					True,
					|clear, point, i| match points.get(i + 1) {
						Ok(next) => clear and !CompoundRouting.segment_hits_box(point, next, box)
						Err(_) => clear
					},
				)
			}
			_ => False
		}
		Err(_) => False
	}
}

## Route growth expands the root without moving a child outside it, and every
## output uses the same normalized coordinate system.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	left = Group({ ..base, insets: Compound.uniform_insets(4), children: [Node(0)] })
	middle = Group({ ..base, insets: Compound.uniform_insets(20), children: [Node(1)] })
	right = Group({ ..base, insets: Compound.uniform_insets(4), children: [Node(2)] })
	root = Group({ ..base, insets: Compound.uniform_insets(4), children: [Nested(left), Nested(middle), Nested(right)], algorithm: Rows({ gap: 8 }) })
	input = { graph: { nodes: List.repeat({ width: 10, height: 10 }, 3), edges: [{ from: 0, to: 2 }] }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match result.groups.first() {
			Ok(outer) => result.groups.drop_first(1).all(|child| child.rect.x >= outer.rect.x and child.rect.y >= outer.rect.y and child.rect.x + child.rect.width <= outer.rect.x + outer.rect.width and child.rect.y + child.rect.height <= outer.rect.y + outer.rect.height) and outer.rect == result.layout.bounds
			Err(_) => False
		}
		Err(_) => False
	}
}

## Domain constraints exist only on constrained stress. Their node references
## use global identities and are projected onto this group's direct children.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	band = Inside({ axis: X, nodes: [0], low: 0, high: 10 })
	constrained = Group({ ..base, children: [Node(0)], algorithm: ConstrainedStress({ settings: { node_gap: 1, max_iterations: 10, tolerance: 0.001 }, constraints: [band], pins: [] }) })
	input = { graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, attachments: [], group_attachments: [], edge_labels: [], root: constrained, routing: Straight }
	match Compound.layout(input, Compound.default_run) {
		Ok(_) => True
		Err(_) => False
	}
}

## Cross-boundary routes report deterministic crossings on the nested box.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	child = Group({ ..base, insets: Compound.uniform_insets(2), children: [Node(0)] })
	root = Group({ ..base, children: [Nested(child), Node(1)] })
	input = { graph: { nodes: List.repeat({ width: 2, height: 2 }, 2), edges: [{ from: 0, to: 1 }] }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.groups.get(1), result.group_crossings.get(0)) {
			(Ok(geometry), Ok(crossings)) => {
				rect = geometry.rect
				crossings.any(|crossing| crossing.group == 0 and (crossing.point.x == rect.x or crossing.point.x == rect.x + rect.width or crossing.point.y == rect.y or crossing.point.y == rect.y + rect.height))
			}
			_ => False
		}
		Err(_) => False
	}
}

## Compound group attachments use root-first group indices and constrain the
## selected crossing without exposing the router's root-excluded indexing.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	child = Group({ ..base, children: [Node(0)] })
	root = Group({ ..base, children: [Nested(child), Node(1)], algorithm: Rows({ gap: 40 }) })
	input = { ..Compound.default_input, graph: { nodes: List.repeat({ width: 10, height: 10 }, 2), edges: [{ from: 0, to: 1 }] }, root, group_attachments: [{ edge: 0, group: 1, attachment: Fixed({ side: Right, offset: 0.25 }) }] }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.groups.get(1), result.group_crossings.first()) {
			(Ok(geometry), Ok(crossings)) => crossings.any(|crossing| crossing.group == 0 and crossing.side == Right and crossing.point.y == geometry.rect.y + geometry.rect.height * 0.25)
			_ => False
		}
		Err(_) => False
	}
}

## Port-order violations retain global node and edge identities.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0), Node(1), Node(2)] })
	input = {
		graph: { nodes: List.repeat({ width: 2, height: 2 }, 3), edges: [{ from: 0, to: 2 }, { from: 0, to: 1 }] },
		attachments: [{ edge: 0, endpoint: From, attachment: Fixed({ side: Top, offset: 0 }) }, { edge: 1, endpoint: From, attachment: Fixed({ side: Top, offset: 1 }) }],
		group_attachments: [],
		edge_labels: [],
		root,
		routing: Straight,
	}
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => {
			from = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			first_uses_port = match result.layout.routes.get(0) {
				Ok(Line(start, _)) => start == { x: from.x - 1, y: from.y - 1 }
				_ => False
			}
			first_uses_port
		}
		Err(_) => False
	}
}

## A selected family is part of the contract: invalid family settings are
## rejected rather than quietly replaced by row packing.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0)], algorithm: GraphCircular({ ..Graph.default_circular_settings, node_gap: -1 }) })
	input = { graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Straight }
	match Compound.layout(input, Compound.default_run) {
		Err(problems) => problems.contains(InvalidGroupAlgorithm(0))
		Ok(_) => False
	}
}

## Tree families require the projected direct-child graph to be exactly one
## rooted tree; arbitrary graphs are not reinterpreted as fabricated trees.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	root = Group({ ..base, children: [Node(0), Node(1)], algorithm: TreeTidy(Tree.default_settings) })
	input = { graph: { nodes: List.repeat({ width: 1, height: 1 }, 2), edges: [] }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Straight }
	match Compound.layout(input, Compound.default_run) {
		Err(problems) => problems.contains(InvalidTreeTopology(0))
		Ok(_) => False
	}
}

## Nested groups are returned root-first and all global result lists align.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	child = Group({ ..base, insets: Compound.uniform_insets(2), children: [Node(1)] })
	root = Group({ ..base, insets: Compound.uniform_insets(3), children: [Node(0), Nested(child)] })
	input = { graph: { nodes: [{ width: 4, height: 4 }, { width: 6, height: 2 }], edges: [{ from: 0, to: 1 }] }, attachments: [], group_attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => result.layout.positions.len() == 2 and result.layout.routes.len() == 1 and result.groups.len() == 2 and match result.groups.get(0) {
			Ok(geometry) => geometry.rect == result.layout.bounds
			Err(_) => False
		}
		Err(_) => False
	}
}
