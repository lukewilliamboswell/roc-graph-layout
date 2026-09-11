import layout.Constrained
import layout.Compound
import layout.Graph
import layout.Layered
import layout.Tree
import rvn.Rvn

## Pure playground inputs and layout calls, independent of the browser UI.
LayoutDemo := [].{
	Point : { x : F64, y : F64 }

	Rect : { x : F64, y : F64, width : F64, height : F64 }

	Node : { width : F64, height : F64 }

	Edge : { from : U64, to : U64 }

	Route : [Line(Point, Point), Polyline(List(Point)), Curves(List({ from : Point, ctl_a : Point, ctl_b : Point, to : Point }))]

	Doc : { labels : List(Str), graph : { nodes : List(Node), edges : List(Edge) } }

	Mode : [LayeredMode, TreeMode, TreeRadialMode, CircularMode, ForceMode, StressMode, RadialMode, ConstrainedMode, CompoundMode]

	Config : { node_gap : F64, layer_gap : F64, ring_gap : F64, start_angle : F64, iterations : U64, tolerance : F64, repulsion : F64, gravity : F64, sweeps : U64, seed : U32, direction : [Down, Up, Left, Right], clockwise : Bool, exact : Bool }

	Drawing : { labels : List(Str), nodes : List(Node), routes : List(Route), positions : List(Point), bounds : Rect, groups : List(Rect), result : Str }

	Geometry : { positions : List(Point), routes : List(Route), bounds : Rect }

	parse_doc : Str -> Try(Doc, List(Str))
	parse_doc = |draft| {
		parsed : Try(Doc, _)
		parsed = Rvn.parse(draft.to_utf8())
		parsed.map_err(|_| ["The graph data is not valid RVN for labels, nodes, and edges."])
	}

	validate : Doc -> List(Str)
	validate = |doc| {
		problems = if doc.graph.nodes.len() > 1000 ["The playground supports at most 1,000 nodes."] else []
		with_edges = if doc.graph.edges.len() > 5000 problems.append("The playground supports at most 5,000 edges.") else problems
		if doc.labels.len() != doc.graph.nodes.len() with_edges.append("Labels must contain exactly one item per node.") else with_edges
	}

	run_layout : Mode, Str, Config -> Try(Drawing, List(Str))
	run_layout = |mode, draft, config| {
		doc = parse_doc(draft)?
		problems = validate(doc)
		if !problems.is_empty() return Err(problems)
		if config.iterations > 2000 or config.sweeps > 2000 return Err(["The playground limits layouts to 2,000 iterative steps."])
		match mode {
			LayeredMode => run_layered(doc, config)
			TreeMode => run_tree(doc, config, Bool.False)
			TreeRadialMode => run_tree(doc, config, Bool.True)
			CircularMode | ForceMode | StressMode | RadialMode => run_graph(doc, config, mode)
			ConstrainedMode => run_constrained(doc, config)
			CompoundMode => run_compound(doc, config)
		}
	}

	route_settings = { ..Layered.default_settings.routing, obstacle_gap: 8, bend_penalty: 16, shared_path_penalty: 4, edge_gap: 6 }

	make_drawing : Doc, Geometry, List(Rect) -> Drawing
	make_drawing = |doc, layout_, groups| { labels: doc.labels, nodes: doc.graph.nodes, routes: layout_.routes, positions: layout_.positions, bounds: layout_.bounds, groups, result: geometry_str(layout_) }

	layout_error : List(a) -> Try(Drawing, List(Str))
	layout_error = |errors| Err(["Layout rejected the input or settings (${errors.len().to_str()} problem(s))."])

	run_layered : Doc, Config -> Try(Drawing, List(Str))
	run_layered = |doc, config| {
		input_ = { ..Layered.default_input, graph: doc.graph }
		settings = { ..Layered.default_settings, node_gap: config.node_gap, layer_gap: config.layer_gap, routing: route_settings, direction: config.direction, max_sweeps: config.sweeps }
		match Layered.layout(input_, settings, Layered.default_run) {
			Err(errors) => Err(errors.map(Layered.problem_to_str))
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}

	tree_problems : Doc -> List(Str)
	tree_problems = |doc| {
		doc.graph.edges.map_with_index(
			|edge, index| {
				if edge.from >= doc.graph.nodes.len() or edge.to >= doc.graph.nodes.len() {
					["Tree edge ${index.to_str()} refers to a missing node."]
				} else []
			},
		).join()
	}

	## Choose one earlier incoming edge per node. Nodes without one become root
	## children, so any valid playground graph has a deterministic tree reading.
	tree_edges : Doc -> List(Edge)
	tree_edges = |doc| doc.graph.nodes.drop_first(1).map_with_index(
		|_, offset| {
			child = offset + 1
			doc.graph.edges.find_first(|edge| edge.to == child and edge.from < child) ?? { from: 0, to: child }
		},
	)

	## Tree numbers output in depth-first order. Restore the playground's node
	## and edge input order before joining positions to labels and sizes.
	tree_geometry : Doc, Geometry -> Geometry
	tree_geometry = |doc, geometry| {
		hierarchy = tree_edges(doc)
		initial : List(U64)
		initial = [0]
		var $pending = initial
		var $order = initial.drop_first(1)
		for _ in doc.graph.nodes {
			match $pending {
				[node, .. as rest] => {
					$order = $order.append(node)
					$pending = hierarchy.keep_if(|edge| edge.from == node).map(|edge| edge.to).concat(rest)
				}
				[] => crash "Validated tree traversal ended early"
			}
		}
		positions = $order.fold_with_index(
			geometry.positions,
			|points, source_index, tree_index| {
				point = geometry.positions.get(tree_index) ?? crash "Tree omitted a node position"
				points.set(source_index, point) ?? crash "Validated tree node index disappeared"
			},
		)
		inverse = $order.fold_with_index(
			List.repeat(0, $order.len()),
			|indices, source_index, tree_index| {
				indices.set(source_index, tree_index) ?? crash "Validated tree node index disappeared"
			},
		)
		routes = doc.graph.edges.map(
			|edge| {
				parent = hierarchy.find_first(|candidate| candidate.to == edge.to)
				if edge.to != 0 and parent == Ok(edge) {
					child_index = inverse.get(edge.to) ?? crash "Validated tree endpoint disappeared"
					geometry.routes.get(child_index - 1) ?? crash "Tree omitted a parent route"
				} else {
					from = positions.get(edge.from) ?? crash "Validated tree start disappeared"
					to = positions.get(edge.to) ?? crash "Validated tree end disappeared"
					Line(from, to)
				}
			},
		)
		{ ..geometry, positions, routes }
	}

	tree_spec : Doc -> Tree.Spec
	tree_spec = |doc| {
		node_count = doc.graph.nodes.len()
		var $specs = doc.graph.nodes.map(|size| { width: size.width, height: size.height, children: [] })
		for offset in 0..<node_count {
			index = node_count - offset - 1
			base = $specs.get(index) ?? { width: 0, height: 0, children: [] }
			children = tree_edges(doc).keep_oks(|edge| if edge.from == index $specs.get(edge.to).map_err(|_| Skip) else Err(Skip))
			$specs = $specs.set(index, { ..base, children }) ?? []
		}
		$specs.get(0) ?? { width: 0, height: 0, children: [] }
	}

	run_tree : Doc, Config, Bool -> Try(Drawing, List(Str))
	run_tree = |doc, config, radial| {
		problems = tree_problems(doc)
		if !problems.is_empty() return Err(problems)
		if doc.graph.nodes.is_empty() return Ok(make_drawing(doc, { positions: [], routes: [], bounds: { x: 0, y: 0, width: 0, height: 0 } }, []))
		spec = tree_spec(doc)
		if radial {
			settings = { sibling_gap: 12, subtree_gap: 24, ring_gap: config.ring_gap, start_angle: config.start_angle, winding: if config.clockwise Clockwise else CounterClockwise }
			match Tree.layout_radial(spec, settings) {
				Err(errors) => layout_error(errors)
				Ok(result) => Ok(make_drawing(doc, tree_geometry(doc, result.layout), []))
			}
		} else {
			settings = { sibling_gap: 12, subtree_gap: 24, level_gap: config.layer_gap, direction: config.direction }
			match Tree.layout(spec, settings) {
				Err(errors) => layout_error(errors)
				Ok(result) => Ok(make_drawing(doc, tree_geometry(doc, result.layout), []))
			}
		}
	}

	run_graph : Doc, Config, Mode -> Try(Drawing, List(Str))
	run_graph = |doc, config, mode| match mode {
		CircularMode => {
			settings = { node_gap: config.node_gap, start_angle: config.start_angle, winding: if config.clockwise Clockwise else CounterClockwise }
			match Graph.layout_circular(doc.graph, settings) {
				Err(errors) => layout_error(errors)
				Ok(result) => Ok(make_drawing(doc, result.layout, []))
			}
		}
		ForceMode => {
			settings = { node_gap: config.node_gap, repulsion: config.repulsion, gravity: config.gravity, opening_angle: 0.9, max_iterations: config.iterations, tolerance: config.tolerance, pins: [] }
			match Graph.layout_force(doc.graph, settings, { seed: config.seed, hints: [] }) {
				Err(errors) => layout_error(errors)
				Ok(result) => Ok(make_drawing(doc, result.layout, []))
			}
		}
		StressMode => {
			settings = { node_gap: config.node_gap, mode: if config.exact Exact else Pivots(8), max_iterations: config.iterations, tolerance: config.tolerance, pins: [] }
			match Graph.layout_stress(doc.graph, settings, { seed: config.seed, hints: [] }) {
				Err(errors) => layout_error(errors)
				Ok(result) => Ok(make_drawing(doc, result.layout, []))
			}
		}
		RadialMode => {
			settings = { root: Auto, ring_gap: config.ring_gap, node_gap: config.node_gap, start_angle: config.start_angle, winding: if config.clockwise Clockwise else CounterClockwise }
			match Graph.layout_radial(doc.graph, settings) {
				Err(errors) => layout_error(errors)
				Ok(result) => Ok(make_drawing(doc, result.layout, []))
			}
		}
		_ => Err(["Unsupported general graph layout."])
	}

	run_constrained : Doc, Config -> Try(Drawing, List(Str))
	run_constrained = |doc, config| {
		constraints = [Align({ axis: Y, nodes: [0, 1] }), Separate({ axis: X, first: 0, second: 1, gap: 140 }), Align({ axis: Y, nodes: [2, 3] }), Separate({ axis: X, first: 2, second: 3, gap: 140 })]
		settings = { node_gap: config.node_gap, max_iterations: config.iterations, tolerance: config.tolerance, pins: [] }
		match Constrained.layout({ graph: doc.graph, constraints }, settings, { seed: config.seed, hints: [] }) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, []))
		}
	}

	compound_group = |children, algorithm| Group({ children, algorithm, insets: Compound.uniform_insets(24), header: None, min_width: 0, min_height: 0 })

	run_compound : Doc, Config -> Try(Drawing, List(Str))
	run_compound = |doc, config| {
		root = if doc.graph.nodes.len() == 8 {
			edge = compound_group([Node(1), Node(2)], Columns({ gap: config.node_gap }))
			application = compound_group([Node(3), Node(4), Node(7)], Rows({ gap: config.node_gap }))
			data = compound_group([Node(5), Node(6)], Columns({ gap: config.node_gap }))
			compound_group([Node(0), Nested(edge), Nested(application), Nested(data)], Rows({ gap: config.layer_gap }))
		} else {
			compound_group(doc.graph.nodes.map_with_index(|_, index| Node(index)), Rows({ gap: config.node_gap }))
		}
		input_ = { ..Compound.default_input, graph: doc.graph, root, routing: Straight }
		match Compound.layout(input_, { ..Compound.default_run, seed: config.seed }) {
			Err(errors) => layout_error(errors)
			Ok(result) => Ok(make_drawing(doc, result.layout, result.groups.drop_first(1).map(|group| group.rect)))
		}
	}

	geometry_str : Geometry -> Str
	geometry_str = |layout_| {
		positions = Str.join_with(layout_.positions.map(|point| "{ x: ${point.x.to_str()}, y: ${point.y.to_str()} }"), ", ")
		bounds = layout_.bounds
		\\{
		\\    positions: [${positions}],
		\\    bounds: { x: ${bounds.x.to_str()}, y: ${bounds.y.to_str()}, width: ${bounds.width.to_str()}, height: ${bounds.height.to_str()} },
		\\}
	}

}
