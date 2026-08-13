import Geom
import Layered
import Graph
import Tree
import Constrained
import Route

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
			gap : F64,
			routing : [Straight, Orthogonal],
			pins : List({ node : U64, x : F64, y : F64 }),
			bands : List({ axis : [X, Y], nodes : List(U64), low : F64, high : F64 }),
		},
	),
].{

	## A layout family selected for one group. The selector is deliberately
	## semantic: implementation-specific helper phases do not appear here.
	Algorithm : [
		Rows,
		Columns,
		LayeredSweep({ settings : Layered.Settings, edge_weights : List({ edge : U64, weight : F64 }), min_spans : List({ edge : U64, span : U64 }) }),
		LayeredExact({ settings : Layered.ExactSettings, edge_weights : List({ edge : U64, weight : F64 }), min_spans : List({ edge : U64, span : U64 }) }),
		GraphCircular(Graph.CircularSettings),
		GraphForce({ settings : { node_gap : F64, repulsion : F64, gravity : F64, opening_angle : F64, max_iterations : U64, tolerance : F64 } }),
		GraphStress({ settings : { node_gap : F64, mode : [Exact, Pivots(U64)], max_iterations : U64, tolerance : F64 } }),
		GraphRadial({ root : [Auto, Node(U64)], ring_gap : F64, node_gap : F64, start_angle : F64, winding : [Clockwise, CounterClockwise] }),
		TreeTidy(Tree.Settings),
		TreeRadial(Tree.RadialSettings),
		ConstrainedStress({ settings : { node_gap : F64, max_iterations : U64, tolerance : F64 }, constraints : List(Constrained.Constraint) }),
	]

	## Routing at one containment level. Straight joins centers through group
	## boundaries; Orthogonal uses deterministic axis-aligned portal segments.
	Routing : [Straight, Orthogonal]

	## A recursive group. Node references are global node indices. Pins and
	## bands use coordinates local to this group; an ancestor may translate the
	## completed group without changing those local relationships.
	GroupSpec : Compound

	Input : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
		ports : List(Route.Port),
		port_bindings : List(Route.PortBinding),
		edge_labels : List(Route.EdgeLabel),
		root : Compound,
	}

	## The seed selects deterministic variants for force/stress groups. Hints
	## are global-node aligned; a full finite list seeds child proxy placement.
	RunArgs : { seed : U32, hints : List({ x : F64, y : F64 }) }

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
		MissingBandNode(U64, U64),
		InvalidBand(U64, U64),
		InvalidGroupAlgorithm(U64),
		InvalidTreeTopology(U64),
		InvalidRouteMetadata,
		UnsupportedBands(U64),
		UnsupportedLayeredMetadata(U64),
	]

	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			routes : List(Geom.Route),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
		},

		## Root-first preorder, so parent containment can be checked in one pass.
		groups : List({ x : F64, y : F64, width : F64, height : F64 }),
		label_anchors : List({ x : F64, y : F64 }),
		port_order_violations : List({ node : U64, before_edge : U64, after_edge : U64 }),
	}

	default_group : Compound
	default_group = Group({
		children: [],
		algorithm: Rows,
		padding: 16,
		min_width: 0,
		min_height: 0,
		gap: 24,
		routing: Orthogonal,
		pins: [],
		bands: [],
	})

	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, ports: [], port_bindings: [], edge_labels: [], root: Compound.default_group }

	default_run : RunArgs
	default_run = { seed: 0, hints: [] }

	## Validate the complete recursive input and lay out every group bottom-up.
	## Every global node must occur exactly once. Output positions and routes
	## retain global node and edge order; group rectangles use root preorder.
	layout : Input, RunArgs -> [Ok(Result), Err(List(Problem))]
	layout = |input, args| {
		problems = Compound.problems(input)
		if problems.is_empty() {
			Ok(Compound.place(input, args))
		} else {
			Err(problems)
		}
	}

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
		has_metadata = !input.ports.is_empty() or !input.port_bindings.is_empty() or !input.edge_labels.is_empty()
		walked = Compound.check_group(input.root, node_count, input.graph.edges, has_metadata, 0)
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
		route_problem = match Route.prepare({ graph: input.graph, positions: List.repeat({ x: 0, y: 0 }, node_count), ports: input.ports, port_bindings: input.port_bindings, edge_labels: input.edge_labels }, Route.default_settings) {
			Ok(_) => []
			Err(_) => [InvalidRouteMetadata]
		}
		[node_problems, edge_problems, walked.problems, membership, route_problem].join()
	}

	check_group : Compound, U64, List({ from : U64, to : U64 }), Bool, U64 -> { members : List(U64), problems : List(Problem), next : U64 }
	check_group = |group_value, node_count, edges, has_metadata, group_index| {
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
			if F64.is_finite(group.gap) and group.gap >= 0 {
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
						checked = Compound.check_group(nested, node_count, edges, has_metadata, state.next)
						{ members: List.concat(state.members, checked.members), problems: List.concat(state.problems, checked.problems), next: checked.next }
					}
				},
		)
		pin_problems = group.pins.map_with_index(
			|pin, i|
				if pin.node >= node_count or !children_checked.members.contains(pin.node) {
					[MissingPin(group_index, i)]
				} else if !F64.is_finite(pin.x) or !F64.is_finite(pin.y) {
					[InvalidPin(group_index, i)]
				} else {
					[]
				},
		).join()
		band_problems = group.bands.map_with_index(
			|band, i| {
				invalid = if F64.is_finite(band.low) and F64.is_finite(band.high) and band.low <= band.high {
					[]
				} else {
					[InvalidBand(group_index, i)]
				}
				missing = band.nodes.map(
					|node| if node < node_count and children_checked.members.contains(node) {
						[]
					} else {
						[MissingBandNode(group_index, i)]
					},
				).join()
				List.concat(invalid, missing)
			},
		).join()
		partitions = group.children.map(|child| Compound.members_of(child))
		local_edges = edges.keep_oks(
			|edge| match (Compound.owner_members(partitions, edge.from), Compound.owner_members(partitions, edge.to)) {
				(Some(from), Some(to)) if from != to => Ok({ from, to })
				_ => Err({})
			},
		)
		tree_problem = match group.algorithm {
			TreeTidy(_) | TreeRadial(_) if !Compound.is_tree(partitions.len(), local_edges) => [InvalidTreeTopology(group_index)]
			_ => []
		}
		band_support_problem = match group.algorithm {
			ConstrainedStress(_) => []
			_ if !group.bands.is_empty() => [UnsupportedBands(group_index)]
			_ => []
		}
		metadata_problem = match group.algorithm {
			LayeredSweep(_) | LayeredExact(_) if has_metadata => [UnsupportedLayeredMetadata(group_index)]
			_ => []
		}
		local_bands = group.bands.map(
			|band| {
				axis: band.axis,
				nodes: band.nodes.keep_oks(
					|node| match Compound.owner_members(partitions, node) {
						Some(owner) => Ok(owner)
						None => Err({})
					},
				),
				low: band.low,
				high: band.high,
			},
		)
		algorithm_check = Compound.algorithm_positions(group.algorithm, List.repeat({ width: 0, height: 0 }, partitions.len()), local_edges, group, [], [], local_bands, 0)
		algorithm_problem = if algorithm_check.valid {
			[]
		} else {
			[InvalidGroupAlgorithm(group_index)]
		}
		{ members: children_checked.members, problems: [children_checked.problems, pin_problems, band_problems, tree_problem, band_support_problem, metadata_problem, algorithm_problem].join(), next: children_checked.next }
	}

	place : Input, RunArgs -> Result
	place = |input, args| {
		placed = Compound.place_group(input.root, input.graph.nodes, input.graph.edges, args.hints, args.seed, 0)
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
		straight_routes = input.graph.edges.map(
			|edge| {
				from = positions.get(edge.from) ?? { x: 0, y: 0 }
				to = positions.get(edge.to) ?? { x: 0, y: 0 }
				if root_spec.routing == Orthogonal and from.x != to.x and from.y != to.y {
					Polyline([from, { x: to.x, y: from.y }, to])
				} else {
					Line(from, to)
				}
			},
		)
		routed = if root_spec.routing == Orthogonal and !input.graph.nodes.is_empty() {
			match Route.orthogonal({ graph: input.graph, positions, ports: input.ports, port_bindings: input.port_bindings, edge_labels: input.edge_labels }, Route.default_settings) {
				Ok(result) => { positions: result.layout.positions, routes: result.layout.routes, bounds: result.layout.bounds, label_anchors: result.label_anchors }
				Err(_) => { positions, routes: straight_routes, bounds: placed.rect, label_anchors: [] }
			}
		} else {
			{ positions, routes: straight_routes, bounds: placed.rect, label_anchors: [] }
		}
		shift = match (positions.first(), routed.positions.first()) {
			(Ok(before), Ok(after)) => { x: after.x - before.x, y: after.y - before.y }
			_ => { x: 0, y: 0 }
		}
		groups = placed.groups.map_with_index(
			|rect, i| if i == 0 {
				routed.bounds
			} else { x: rect.x + shift.x, y: rect.y + shift.y, width: rect.width, height: rect.height },
		)
		stitched_routes = routed.routes.map(|route| Compound.stitch_route(route, groups.drop_first(1)))
		violations = Compound.port_violations(input.graph.edges, input.ports, input.port_bindings, routed.positions)
		{ layout: { positions: routed.positions, routes: stitched_routes, bounds: routed.bounds }, groups, label_anchors: routed.label_anchors, port_order_violations: violations }
	}

	port_violations : List({ from : U64, to : U64 }), List(Route.Port), List(Route.PortBinding), List({ x : F64, y : F64 }) -> List({ node : U64, before_edge : U64, after_edge : U64 })
	port_violations = |edges, ports, bindings, positions| bindings.fold_with_index(
		[],
		|acc, before, i| bindings.fold_with_index(
			acc,
			|inner, after, j| {
				before_port = ports.get(before.port)
				after_port = ports.get(after.port)
				before_edge = edges.get(before.edge)
				after_edge = edges.get(after.edge)
				match (before_port, after_port, before_edge, after_edge) {
					(Ok(bp), Ok(ap), Ok(be), Ok(ae)) if i < j and bp.node == ap.node and before.endpoint == after.endpoint => {
						before_other = positions.get(
							if before.endpoint == From {
								be.to
							} else {
								be.from
							},
						) ?? { x: 0, y: 0 }
						after_other = positions.get(
							if after.endpoint == From {
								ae.to
							} else {
								ae.from
							},
						) ?? { x: 0, y: 0 }
						geometric_reversed = match bp.side {
							Top | Bottom => before_other.x > after_other.x
							Left | Right => before_other.y > after_other.y
						}
						if before.port < after.port and geometric_reversed {
							inner.append({ node: bp.node, before_edge: before.edge, after_edge: after.edge })
						} else {
							inner
						}
					}
					_ => inner
				}
			},
		),
	)

	stitch_route : Geom.Route, List({ x : F64, y : F64, width : F64, height : F64 }) -> Geom.Route
	stitch_route = |route, groups| {
		points = match route {
			Line(a, b) => [a, b]
			Polyline(ps) => ps
			Curves(segments) => segments.fold([], |acc, segment| acc.concat([segment.from, segment.to]))
		}
		match (points.first(), points.last()) {
			(Ok(from), Ok(to)) => {
				portals = groups.keep_oks(
					|rect| {
						from_inside = Compound.inside_rect(from, rect)
						to_inside = Compound.inside_rect(to, rect)
						if from_inside == to_inside {
							Err({})
						} else {
							Ok(
								Compound.boundary_portal(
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
						ad = Compound.distance_sq(from, a)
						bd = Compound.distance_sq(from, b)
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
					orthogonal = waypoints.fold_with_index(
						[],
						|acc, point, i| match waypoints.get(i + 1) {
							Ok(next) if point.x != next.x and point.y != next.y => acc.concat([point, { x: next.x, y: point.y }])
							_ => acc.append(point)
						},
					)
					Polyline(orthogonal)
				}
			}
			_ => route
		}
	}

	inside_rect : { x : F64, y : F64 }, { x : F64, y : F64, width : F64, height : F64 } -> Bool
	inside_rect = |point, rect| point.x >= rect.x and point.x <= rect.x + rect.width and point.y >= rect.y and point.y <= rect.y + rect.height

	distance_sq : { x : F64, y : F64 }, { x : F64, y : F64 } -> F64
	distance_sq = |a, b| (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)

	boundary_portal : { x : F64, y : F64 }, { x : F64, y : F64 }, { x : F64, y : F64, width : F64, height : F64 } -> { x : F64, y : F64 }
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
						child_placed = Compound.place_group(nested, sizes, edges, hints, seed, depth + 1)
						{ nodes: child_placed.nodes, groups: child_placed.groups, members: child_placed.nodes.map(|p| p.node), width: child_placed.rect.width, height: child_placed.rect.height }
					}
				},
		)
		local_edges = edges.keep_oks(
			|edge| {
				from = Compound.owner_index(items, edge.from)
				to = Compound.owner_index(items, edge.to)
				match (from, to) {
					(Some(a), Some(b)) if a != b => Ok({ from: a, to: b })
					_ => Err({})
				}
			},
		)
		proxy_nodes = items.map(|item| { width: item.width, height: item.height })
		local_hints = items.map(|item| Compound.member_hint(item.members, hints))
		local_pins = group.pins.keep_oks(
			|pin| match Compound.owner_index(items, pin.node) {
				Some(node) => Ok({ node, x: pin.x, y: pin.y })
				None => Err({})
			},
		)
		local_bands = group.bands.map(
			|band| {
				axis: band.axis,
				nodes: band.nodes.keep_oks(
					|node| match Compound.owner_index(items, node) {
						Some(owner) => Ok(owner)
						None => Err({})
					},
				),
				low: band.low,
				high: band.high,
			},
		)
		usable_hints = if hints.len() == sizes.len() and local_hints.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) {
			local_hints
		} else {
			[]
		}
		proxy_positions = Compound.algorithm_positions(group.algorithm, proxy_nodes, local_edges, group, usable_hints, local_pins, local_bands, seed).positions
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

	algorithm_positions : Compound.Algorithm, List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), { gap : F64, .. }, List({ x : F64, y : F64 }), List({ node : U64, x : F64, y : F64 }), List({ axis : [X, Y], nodes : List(U64), low : F64, high : F64 }), U32 -> { positions : List({ x : F64, y : F64 }), valid : Bool }
	algorithm_positions = |algorithm, nodes, edges, group, hints, pins, bands, seed| {
		fallback = |vertical| Compound.linear_positions(nodes, group.gap, vertical)
		match algorithm {
			Rows => { positions: fallback(False), valid: True }
			Columns => { positions: fallback(True), valid: True }
			LayeredSweep(payload) =>
				match Layered.layout({ graph: { nodes, edges }, edge_weights: payload.edge_weights, min_spans: payload.min_spans, ports: [], port_bindings: [], edge_labels: [] }, payload.settings, { hints: hints }) {
					Ok(result) => { positions: result.layout.positions, valid: True }
					Err(_) => { positions: fallback(False), valid: False }
				}
			LayeredExact(payload) =>
				match Layered.layout_exact({ graph: { nodes, edges }, edge_weights: payload.edge_weights, min_spans: payload.min_spans, ports: [], port_bindings: [], edge_labels: [] }, payload.settings) {
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
				if !Compound.is_tree(nodes.len(), edges) {
					{ positions: fallback(False), valid: False }
				} else {
					root = Compound.tree_root(nodes.len(), edges)
					match Tree.layout(Compound.tree_from(root, nodes, edges), settings) {
						Ok(result) => { positions: Compound.unorder_tree(result.layout.positions, Compound.tree_preorder(root, edges), nodes.len()), valid: True }
						Err(_) => { positions: fallback(False), valid: False }
					}
				}
			}
			TreeRadial(settings) => {
				if !Compound.is_tree(nodes.len(), edges) {
					{ positions: fallback(False), valid: False }
				} else {
					root = Compound.tree_root(nodes.len(), edges)
					match Tree.layout_radial(Compound.tree_from(root, nodes, edges), settings) {
						Ok(result) => { positions: Compound.unorder_tree(result.layout.positions, Compound.tree_preorder(root, edges), nodes.len()), valid: True }
						Err(_) => { positions: fallback(False), valid: False }
					}
				}
			}
			ConstrainedStress(payload) => {
				settings = { node_gap: payload.settings.node_gap, max_iterations: payload.settings.max_iterations, tolerance: payload.settings.tolerance, pins }
				constraints = List.concat(payload.constraints, bands.map(|band| Inside(band)))
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
		Nested(Group(spec)) => spec.children.map(|nested| Compound.members_of(nested)).join()
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
		{ width: size.width, height: size.height, children: edges.keep_if(|edge| edge.from == node).map(|edge| Compound.tree_from(edge.to, nodes, edges)) }
	}

	tree_preorder : U64, List({ from : U64, to : U64 }) -> List(U64)
	tree_preorder = |node, edges| [node].concat(edges.keep_if(|edge| edge.from == node).map(|edge| Compound.tree_preorder(edge.to, edges)).join())

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
	port_order_violations: [],
})

## Membership is exact: missing and duplicate nodes are both reported.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	group = Group({ ..base, children: [Node(0), Node(0)] })
	input = { graph: { nodes: [{ width: 2, height: 2 }, { width: 2, height: 2 }], edges: [] }, ports: [], port_bindings: [], edge_labels: [], root: group }
	match Compound.layout(input, Compound.default_run) {
		Err(problems) => problems.contains(DuplicateMember(0)) and problems.contains(MissingMember(1))
		Ok(_) => False
	}
}

## Bands are never ignored: unsupported families reject them, while
## constrained stress consumes them as local Inside rules.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	band = { axis: X, nodes: [0], low: 0, high: 10 }
	rows = Group({ ..base, children: [Node(0)], bands: [band] })
	constrained = Group({ ..base, children: [Node(0)], bands: [band], algorithm: ConstrainedStress({ settings: { node_gap: 1, max_iterations: 10, tolerance: 0.001 }, constraints: [] }) })
	input = { graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, ports: [], port_bindings: [], edge_labels: [], root: rows }
	match (Compound.layout(input, Compound.default_run), Compound.layout({ ..input, root: constrained }, Compound.default_run)) {
		(Err(problems), Ok(_)) => problems.contains(UnsupportedBands(0))
		_ => False
	}
}

## Cross-boundary routes contain a deterministic point on the nested box.
expect {
	base = match Compound.default_group {
		Group(spec) => spec
	}
	child = Group({ ..base, padding: 2, children: [Node(0)] })
	root = Group({ ..base, children: [Nested(child), Node(1)] })
	input = { graph: { nodes: List.repeat({ width: 2, height: 2 }, 2), edges: [{ from: 0, to: 1 }] }, ports: [], port_bindings: [], edge_labels: [], root }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => match (result.groups.get(1), result.layout.routes.get(0)) {
			(Ok(rect), Ok(Polyline(points))) => points.any(|point| point.x == rect.x or point.x == rect.x + rect.width or point.y == rect.y or point.y == rect.y + rect.height)
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
	root = Group({ ..base, children: [Node(0), Node(1), Node(2)], routing: Straight })
	input = {
		graph: { nodes: List.repeat({ width: 2, height: 2 }, 3), edges: [{ from: 0, to: 2 }, { from: 0, to: 1 }] },
		ports: [{ node: 0, side: Top, offset: 0 }, { node: 0, side: Top, offset: 1 }],
		port_bindings: [{ edge: 0, endpoint: From, port: 0 }, { edge: 1, endpoint: From, port: 1 }],
		edge_labels: [],
		root,
	}
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => result.port_order_violations == [{ node: 0, before_edge: 0, after_edge: 1 }]
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
	input = { graph: { nodes: [{ width: 1, height: 1 }], edges: [] }, ports: [], port_bindings: [], edge_labels: [], root }
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
	input = { graph: { nodes: List.repeat({ width: 1, height: 1 }, 2), edges: [] }, ports: [], port_bindings: [], edge_labels: [], root }
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
	input = { graph: { nodes: [{ width: 4, height: 4 }, { width: 6, height: 2 }], edges: [{ from: 0, to: 1 }] }, ports: [], port_bindings: [], edge_labels: [], root }
	match Compound.layout(input, Compound.default_run) {
		Ok(result) => result.layout.positions.len() == 2 and result.layout.routes.len() == 1 and result.groups.len() == 2 and result.groups.get(0) == Ok(result.layout.bounds)
		Err(_) => False
	}
}
