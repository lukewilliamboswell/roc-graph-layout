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
			padding : F64,
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

	## A recursive group. Node references are global node indices. Padding and
	## minimum dimensions apply to every algorithm; algorithm-specific data lives
	## in the selected `Algorithm` variant.
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
		InvalidPadding(U64),
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

	## Index-aligned node and edge geometry plus root-first group rectangles.
	## The root rectangle equals `layout.bounds` and contains every child group,
	## route, and label box.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			routes : List(Geom.Route),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
		},

		## Root-first preorder, so parent containment can be checked in one pass.
		groups : List({ x : F64, y : F64, width : F64, height : F64 }),
		label_anchors : List({ x : F64, y : F64 }),
		attachments : List(Route.EdgeAttachments),
		group_crossings : List(List(Route.GroupCrossing)),
	}

	## An empty row group with 24 units between children and 16 units of padding.
	## Replace its fields by record update when building each recursive group.
	default_group : Compound
	default_group = Group({
		children: [],
		algorithm: Rows({ gap: 24 }),
		padding: 16,
		min_width: 0,
		min_height: 0,
	})

	## Default deterministic orthogonal routing. Replace or record-update it on
	## `Input` when the whole drawing needs different routing.
	default_routing : Routing
	default_routing = Orthogonal(Route.default_settings)

	## Empty graph and group with default orthogonal routing.
	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, attachments: [], edge_labels: [], root: Compound.default_group, routing: Compound.default_routing }

	## Fixed seed and no position hints.
	default_run : RunArgs
	default_run = { seed: 0, hints: [] }

	## Validate the complete recursive input and lay out every group bottom-up.
	## Every global node must occur exactly once. Output positions and routes
	## retain global node and edge order; group rectangles use root preorder.
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
		route_problem = match Route.layout({ graph: input.graph, positions: List.repeat({ x: 0, y: 0 }, node_count), groups: [], memberships: [], attachments: input.attachments, edge_labels: input.edge_labels }, route_settings) {
			Ok(_) => []
			Err(problems) => problems.keep_oks(
				|problem| match problem {
					InvalidNodeWidth(_) | InvalidNodeHeight(_) | PositionCountMismatch | InvalidPosition(_) | InvalidEdgeFrom(_) | InvalidEdgeTo(_) => Err({})
					_ => Ok(RouteProblem(problem))
				},
			)
		}
		[node_problems, edge_problems, walked.problems, membership, route_problem].join()
	}

	check_group : Compound, U64, List({ from : U64, to : U64 }), U64 -> { members : List(U64), problems : List(Problem), next : U64 }
	check_group = |group_value, node_count, edges, group_index| {
		group = match group_value {
			Group(spec) => spec
		}
		settings = [
			if F64.is_finite(group.padding) and group.padding >= 0 {
				[]
			} else {
				[InvalidPadding(group_index)]
			},
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
		route_group_rects = placed.groups.drop_first(1)
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
		memberships = positions.fold_with_index([], |acc, point, node| match CompoundInternals.innermost_group(point, route_group_rects) {
			Some(group) => acc.append({ node, group })
			None => acc
		})
		routed = match input.routing {
			Orthogonal(settings) if !input.graph.nodes.is_empty() =>
				match Route.layout({ graph: input.graph, positions, groups: route_groups, memberships, attachments: input.attachments, edge_labels: input.edge_labels }, settings) {
					Ok(result) => { positions: result.layout.positions, routes: result.layout.routes, bounds: result.layout.bounds, label_anchors: result.label_anchors, attachments: result.attachments, group_crossings: result.group_crossings }
					Err(_) => { positions, routes: straight_routes, bounds: placed.rect, label_anchors: [], attachments: [], group_crossings: List.repeat([], input.graph.edges.len()) }
				}
			_ => { positions, routes: straight_routes, bounds: placed.rect, label_anchors: [], attachments: [], group_crossings: List.repeat([], input.graph.edges.len()) }
		}
		shift = match (positions.first(), routed.positions.first()) {
			(Ok(before), Ok(after)) => { x: after.x - before.x, y: after.y - before.y }
			_ => { x: 0, y: 0 }
		}
		placed_groups = placed.groups.map(|rect| { x: rect.x + shift.x, y: rect.y + shift.y, width: rect.width, height: rect.height })
		stitched_routes = routed.routes
		raw_label_anchors = input.edge_labels.map(|label| CompoundRouting.route_midpoint(stitched_routes.get(label.edge) ?? Polyline([])))
		extent = CompoundRouting.drawing_extent(placed.rect, shift, root_spec.padding, input.graph.nodes, routed.positions, stitched_routes, input.edge_labels, raw_label_anchors)
		normalize = { x: 0 - extent.x, y: 0 - extent.y }
		move_point = |point| { x: Geom.saturate(point.x + normalize.x), y: Geom.saturate(point.y + normalize.y) }
		positions_final = routed.positions.map(move_point)
		routes_final = stitched_routes.map(|route| CompoundRouting.move_route(route, normalize))
		attachments_final = routed.attachments.map(|ends| { from: { ..ends.from, point: move_point(ends.from.point) }, to: { ..ends.to, point: move_point(ends.to.point) } })
		group_crossings_final = routed.group_crossings.map(|crossings| crossings.map(|crossing| { ..crossing, point: move_point(crossing.point) }))
		groups = placed_groups.map_with_index(
			|rect, i| if i == 0 {
				{ x: 0, y: 0, width: extent.width, height: extent.height }
			} else {
				{ x: Geom.saturate(rect.x + normalize.x), y: Geom.saturate(rect.y + normalize.y), width: rect.width, height: rect.height }
			},
		)
		label_anchors = raw_label_anchors.map(move_point)
		{ layout: { positions: positions_final, routes: routes_final, bounds: { x: 0, y: 0, width: extent.width, height: extent.height } }, groups, label_anchors, attachments: attachments_final, group_crossings: group_crossings_final }
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
		groups : List({ x : F64, y : F64, width : F64, height : F64 }),
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
				dx = position.x - item.width / 2 + group.padding
				dy = position.y - item.height / 2 + group.padding
				{
					nodes: item.nodes.map(|p| { node: p.node, x: p.x + dx, y: p.y + dy }),
					groups: item.groups.map(|r| { x: r.x + dx, y: r.y + dy, width: r.width, height: r.height }),
				}
			},
		)
		laid_nodes = laid.map(|item| item.nodes).join()
		laid_groups = laid.map(|item| item.groups).join()
		content_width = items.map_with_index(|item, i| (proxy_positions.get(i) ?? { x: 0, y: 0 }).x + item.width / 2).fold(0, |a, b| a.max(b))
		content_height = items.map_with_index(|item, i| (proxy_positions.get(i) ?? { x: 0, y: 0 }).y + item.height / 2).fold(0, |a, b| a.max(b))
		natural_width = content_width + group.padding * 2
		natural_height = content_height + group.padding * 2
		width = Geom.saturate(natural_width.max(group.min_width))
		height = Geom.saturate(natural_height.max(group.min_height))
		center_dx = (width - natural_width).max(0) / 2
		center_dy = (height - natural_height).max(0) / 2
		centered_nodes = laid_nodes.map(|p| { node: p.node, x: Geom.saturate(p.x + center_dx), y: Geom.saturate(p.y + center_dy) })
		centered_children = laid_groups.map(|r| { x: Geom.saturate(r.x + center_dx), y: Geom.saturate(r.y + center_dy), width: r.width, height: r.height })
		root_rect = { x: 0, y: 0, width, height }
		{ nodes: centered_nodes, groups: List.concat([root_rect], centered_children), rect: root_rect }
	}

	algorithm_positions : Compound.Algorithm, List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), List({ x : F64, y : F64 }), List({ node : U64, x : F64, y : F64 }), List(Constrained.Constraint), U32 -> { positions : List({ x : F64, y : F64 }), valid : Bool }
	algorithm_positions = |algorithm, nodes, edges, hints, pins, constraints, seed| {
		fallback = |vertical| CompoundInternals.linear_positions(nodes, 24, vertical)
		match algorithm {
			Rows(payload) => { positions: CompoundInternals.linear_positions(nodes, payload.gap, False), valid: True }
			Columns(payload) => { positions: CompoundInternals.linear_positions(nodes, payload.gap, True), valid: True }
			LayeredSweep(payload) =>
				match Layered.layout({ graph: { nodes, edges }, edge_weights: payload.edge_weights, min_spans: payload.min_spans, attachments: [], edge_labels: [] }, payload.settings, { hints: hints }) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			LayeredExact(payload) =>
				match Layered.layout_exact({ graph: { nodes, edges }, edge_weights: payload.edge_weights, min_spans: payload.min_spans, attachments: [], edge_labels: [] }, payload.settings) {
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
	groups: [{ x: 0, y: 0, width: 32, height: 32 }],
	label_anchors: [],
	attachments: [],
	group_crossings: [],
})

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
	input = { graph: { nodes: [{ width: 2, height: 2 }, { width: 2, height: 2 }], edges: [] }, attachments: [], edge_labels: [], root: group, routing: Orthogonal(Route.default_settings) }
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
	left = Group({ ..base, padding: 4, children: [Node(0)] })
	middle = Group({ ..base, padding: 20, children: [Node(1)] })
	right = Group({ ..base, padding: 4, children: [Node(2)] })
	root = Group({ ..base, padding: 4, children: [Nested(left), Nested(middle), Nested(right)], algorithm: Rows({ gap: 8 }) })
	input = { graph: { nodes: List.repeat({ width: 10, height: 10 }, 3), edges: [{ from: 0, to: 2 }] }, attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.groups.get(2), result.layout.routes.get(0)) {
			(Ok(rect), Ok(route)) => {
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
	left = Group({ ..base, padding: 4, children: [Node(0)] })
	middle = Group({ ..base, padding: 20, children: [Node(1)] })
	right = Group({ ..base, padding: 4, children: [Node(2)] })
	root = Group({ ..base, padding: 4, children: [Nested(left), Nested(middle), Nested(right)], algorithm: Rows({ gap: 8 }) })
	input = { graph: { nodes: List.repeat({ width: 10, height: 10 }, 3), edges: [{ from: 0, to: 2 }] }, attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match result.groups.first() {
			Ok(outer) => result.groups.drop_first(1).all(|child| child.x >= outer.x and child.y >= outer.y and child.x + child.width <= outer.x + outer.width and child.y + child.height <= outer.y + outer.height) and outer == result.layout.bounds
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
	input = { graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, attachments: [], edge_labels: [], root: constrained, routing: Straight }
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
	child = Group({ ..base, padding: 2, children: [Node(0)] })
	root = Group({ ..base, children: [Nested(child), Node(1)] })
	input = { graph: { nodes: List.repeat({ width: 2, height: 2 }, 2), edges: [{ from: 0, to: 1 }] }, attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.groups.get(1), result.group_crossings.get(0)) {
			(Ok(rect), Ok(crossings)) => crossings.any(|crossing| crossing.group == 0 and (crossing.point.x == rect.x or crossing.point.x == rect.x + rect.width or crossing.point.y == rect.y or crossing.point.y == rect.y + rect.height))
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
	input = { graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, attachments: [], edge_labels: [], root, routing: Straight }
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
	input = { graph: { nodes: List.repeat({ width: 1, height: 1 }, 2), edges: [] }, attachments: [], edge_labels: [], root, routing: Straight }
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
	child = Group({ ..base, padding: 2, children: [Node(1)] })
	root = Group({ ..base, padding: 3, children: [Node(0), Nested(child)] })
	input = { graph: { nodes: [{ width: 4, height: 4 }, { width: 6, height: 2 }], edges: [{ from: 0, to: 1 }] }, attachments: [], edge_labels: [], root, routing: Orthogonal(Route.default_settings) }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => result.layout.positions.len() == 2 and result.layout.routes.len() == 1 and result.groups.len() == 2 and result.groups.get(0) == Ok(result.layout.bounds)
		Err(_) => False
	}
}
