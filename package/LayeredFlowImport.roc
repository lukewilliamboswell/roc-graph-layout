import LayeredFlowFixtures
import LayeredFlowInput
import LayeredFlowGraph

## Internal construction of a port graph from validated structural input.
## Hierarchical edges are segmented at group borders; coordinates are kept
## in flow-relative axes until the result is exported.
LayeredFlowImport :: {}.{

	Direction : [Down, Up, Right, Left]

	Setup : {
		model : LayeredFlowGraph.Model,
		direction : Direction,

		## The layout node of each diagram node and each subgraph.
		node_of : List(U64),
		group_node : List(U64),

		## The nested graph of each subgraph, or `nil` for an empty one.
		group_graph : List(U64),

		## The layout edge of each source edge, and whether construction handed it to
		## the engine turned around.
		edge_of : List(U64),
		flipped : List(Bool),

		## The edges each diagram edge was split into at subgraph borders, in
		## no particular order.
		segments : List(List(U64)),
	}

	Item : [GroupItem(U64), NodeItem(U64)]

	nil : U64
	nil = LayeredFlowGraph.nil

	finite : F64 -> F64
	finite = |v| if (F64.is_finite(v) and v > 0) v else 0

	direction_of : LayeredFlowInput.Input -> Direction
	direction_of = |diagram| diagram.direction

	vertical : Direction -> Bool
	vertical = |d|
		match d {
			Down | Up => True
			_ => False
		}

	## A size in the layout's reading, along and across the flow.
	internal_size : Direction, F64, F64 -> { width : F64, height : F64 }
	internal_size = |d, w, h| if (LayeredFlowImport.vertical(d)) { width: h, height: w } else { width: w, height: h }

	## Padding in the layout's reading, from padding given as drawn.
	internal_padding : Direction, LayeredFlowGraph.Margins -> LayeredFlowGraph.Margins
	internal_padding = |d, p|
		match d {
			Right => p
			Left => { top: p.top, bottom: p.bottom, left: p.right, right: p.left }
			Down => { top: p.left, bottom: p.right, left: p.top, right: p.bottom }
			Up => { top: p.left, bottom: p.right, left: p.bottom, right: p.top }
		}

	## Default registration of a container: groups first, last
	## declared first, then nodes in order.
	children : LayeredFlowInput.Input, LayeredFlowInput.Container -> List(Item)
	children = |diagram, container| {
		var $out = []
		var $g = diagram.groups.len()
		while $g > 0 {
			$g = $g - 1
			if (diagram.groups.get($g) ?? LayeredFlowImport.no_group).container == container {
				$out = $out.append(GroupItem($g))
			}
		}
		for i in 0..<diagram.nodes.len() {
			if (diagram.nodes.get(i) ?? LayeredFlowImport.no_node).container == container {
				$out = $out.append(NodeItem(i))
			}
		}
		$out
	}

	registered_children : LayeredFlowInput.Input, LayeredFlowInput.Container, List(Item) -> List(Item)
	registered_children = |diagram, container, registration| {
		if registration.is_empty() {
			return LayeredFlowImport.children(diagram, container)
		}
		registration.keep_if(
			|item| {
				parent = match item {
					NodeItem(i) => (diagram.nodes.get(i) ?? crash "validated node registration").container
					GroupItem(i) => (diagram.groups.get(i) ?? crash "validated group registration").container
				}
				parent == container
			},
		)
	}

	no_group : LayeredFlowInput.Group
	no_group = LayeredFlowInput.default_group

	no_node : LayeredFlowInput.Node
	no_node = { container: Root }

	no_edge : LayeredFlowInput.Edge
	no_edge = { from: Node(0), to: Node(0) }

	## Which subgraph each container lies in, by item.
	parent_of : LayeredFlowInput.Input, Item -> [Root, Group(U64)]
	parent_of = |diagram, item| {
		container = match item {
			GroupItem(g) => (diagram.groups.get(g) ?? LayeredFlowImport.no_group).container
			NodeItem(i) => (diagram.nodes.get(i) ?? LayeredFlowImport.no_node).container
		}
		match container {
			Root => Root
			Group(g) => if (g < diagram.groups.len()) Group(g) else Root
		}
	}

	build : LayeredFlowInput.Input, LayeredFlowInput.Sizes -> Setup
	build = |diagram, sizes| LayeredFlowImport.build_registered(diagram, sizes, [])

	## Internal adapters may retain a different source registration order.
	## A nonempty registration contains every node/group exactly once, with
	## validated indices. Empty retains the flowchart DB's established order.
	build_registered : LayeredFlowInput.Input, LayeredFlowInput.Sizes, List(Item) -> Setup
	build_registered = |diagram, sizes, registration| {
		direction = LayeredFlowImport.direction_of(diagram)
		group_count = diagram.groups.len()
		root_graph = { ..LayeredFlowGraph.blank_graph, spacing: diagram.spacing, padding: diagram.padding, model_order_nodes: True, direction }
		separate = diagram.groups.map(|group| group.separate)
		var $model = { graphs: [root_graph], nodes: [], ports: [], edges: [], loops: [] }
		var $node_of = List.repeat(LayeredFlowImport.nil, diagram.nodes.len())
		var $group_node = List.repeat(LayeredFlowImport.nil, group_count)
		var $group_graph = List.repeat(LayeredFlowImport.nil, group_count)
		# Nodes, breadth first, as the engine imports them.
		var $queue = LayeredFlowImport.registered_children(diagram, Root, registration)
		var $head = 0
		var $order = 0
		while $head < $queue.len() {
			item = $queue.get($head) ?? NodeItem(0)
			$head = $head + 1
			parent_graph = match LayeredFlowImport.parent_of(diagram, item) {
				Root => 0
				Group(g) => $group_graph.get(g) ?? 0
			}
			model_order = if parent_graph == 0 {
				o = $order
				$order = $order + 1
				Some(o)
			} else {
				None
			}
			# Each graph reads in its own direction: the drawing's, or a
			# subgraph laid out on its own reads its own way.
			dir = LayeredFlowGraph.graph($model, parent_graph).direction
			match item {
				NodeItem(i) => {
					raw = sizes.nodes.get(i) ?? { width: 0, height: 0 }
					size = LayeredFlowImport.internal_size(dir, LayeredFlowImport.finite(raw.width), LayeredFlowImport.finite(raw.height))
					(m, n) = LayeredFlowGraph.add_node($model, { ..LayeredFlowGraph.blank_node, graph: parent_graph, origin: DiagramNode(i), width: size.width, height: size.height, model_order })
					$model = m
					$node_of = $node_of.set(i, n) ?? []
				}
				GroupItem(g) => {
					title = sizes.group_titles.get(g) ?? { width: 0, height: 0 }
					options = diagram.groups.get(g) ?? LayeredFlowInput.default_group
					# Label dimensions are measured geometric reservations.
					title_w = LayeredFlowImport.finite(title.width)
					title_h = LayeredFlowImport.finite(title.height)
					members = LayeredFlowImport.registered_children(diagram, Group(g), registration)
					(m, n) = LayeredFlowGraph.add_node($model, { ..LayeredFlowGraph.blank_node, graph: parent_graph, origin: Group(g), model_order })
					$model = m
					$group_node = $group_node.set(g, n) ?? []
					if !members.is_empty() {
						own = separate.get(g) ?? False
						inner_dir = if own {
							match (diagram.groups.get(g) ?? LayeredFlowImport.no_group).direction {
								Set(d) => d
								Inherit => Right
							}
						} else {
							dir
						}
						padding = LayeredFlowImport.internal_padding(inner_dir, options.padding)
						min = LayeredFlowImport.internal_size(inner_dir, options.min_width, options.min_height)
						title_size = LayeredFlowImport.internal_size(inner_dir, title_w, title_h)
						gi = $model.graphs.len()
						$model = { ..$model, graphs: $model.graphs.append({ ..LayeredFlowGraph.blank_graph, parent: n, spacing: options.spacing, padding, min_width: min.width, min_height: min.height, title_width: title_size.width, title_height: title_size.height, direction: inner_dir, separate: own }) }
						$model = LayeredFlowGraph.set_node($model, n, if (own) { ..LayeredFlowGraph.node($model, n), inner: gi } else { ..LayeredFlowGraph.node($model, n), nested: gi })
						$group_graph = $group_graph.set(g, gi) ?? []
						$queue = $queue.concat(members)
					} else {
						# Empty groups still reserve their authored minimum size.
						empty_size = LayeredFlowImport.internal_size(dir, options.min_width.max(title_w), options.min_height.max(title_h))
						$model = LayeredFlowGraph.set_node($model, n, { ..LayeredFlowGraph.node($model, n), width: empty_size.width, height: empty_size.height })
					}
				}
			}
		}
		node_of = $node_of
		group_node = $group_node
		end_node = |end|
			match end {
				Node(i) => node_of.get(i) ?? LayeredFlowImport.nil
				Group(g) => group_node.get(g) ?? LayeredFlowImport.nil
			}
		flipped = LayeredFlowImport.feedback_flags(diagram)
		# The engine reads edges graph by graph, breadth first, each edge in the
		# graph that contains both its ends; that order decides port order and
		# the edges' model order.
		model0 = $model
		ends_of = |e| {
			edge = diagram.edges.get(e) ?? LayeredFlowImport.no_edge
			flip = flipped.get(e) ?? False
			{ from: end_node(if (flip) edge.to else edge.from), to: end_node(if (flip) edge.from else edge.to) }
		}
		rank = |e| {
			ends = ends_of(e)
			c = LayeredFlowImport.container(model0, ends.from, ends.to)
			if c == LayeredFlowImport.nil {
				0
			} else {
				LayeredFlowImport.content(model0, c)
			}
		}
		edge_order = LayeredFlowGraph.sort_by(
			List.repeat(0, diagram.edges.len()).map_with_index(|_, e| e),
			|a, b| {
				ra = rank(a)
				rb = rank(b)
				if (ra < rb) -1 else if (ra > rb) 1 else 0
			},
		)
		# Edges, each with a port at each end.
		var $edge_of = List.repeat(LayeredFlowImport.nil, diagram.edges.len())
		var $edge_order_index = 0
		for e in edge_order {
			ends = ends_of(e)
			from = ends.from
			to = ends.to
			if from != LayeredFlowImport.nil and to != LayeredFlowImport.nil {
				(m1, sp) = LayeredFlowGraph.add_port($model, from, East)
				(m2, tp) = LayeredFlowGraph.add_port(m1, to, West)
				label_dir = LayeredFlowGraph.graph(model0, rank(e)).direction
				labels = match sizes.edge_labels.get(e) ?? None {
					Some(block) => {
						size = LayeredFlowImport.internal_size(label_dir, LayeredFlowImport.finite(block.width), LayeredFlowImport.finite(block.height))
						[{ width: size.width, height: size.height, edge: e }]
					}
					_ => []
				}
				(m3, le) = LayeredFlowGraph.add_edge(m2, { ..LayeredFlowGraph.blank_edge, source: sp, target: tp, origin: e, labels, model_order: Some($edge_order_index) })
				$edge_order_index = $edge_order_index + 1
				$model = m3
				$edge_of = $edge_of.set(e, le) ?? $edge_of
			}
		}
		pre = LayeredFlowImport.compound_preprocess($model, direction)
		{
			model: pre.model,
			direction,
			node_of,
			group_node,
			group_graph: $group_graph,
			edge_of: $edge_of,
			flipped,
			segments: pre.segments,
		}
	}

	## The graph inside a subgraph node, whether laid out with its parent or
	## on its own.
	content : LayeredFlowGraph.Model, U64 -> U64
	content = |m, n| {
		node = LayeredFlowGraph.node(m, n)
		if (node.nested != LayeredFlowImport.nil) node.nested else node.inner
	}

	## The subgraph node an edge between `s` and `t` belongs to (`nil` for
	## the drawing), as the engine's reader decides it: the common parent of
	## siblings, the end that contains the other, or the lowest common
	## ancestor.
	container : LayeredFlowGraph.Model, U64, U64 -> U64
	container = |m, s, t| {
		parent = |x| LayeredFlowGraph.graph(m, LayeredFlowGraph.node(m, x).graph).parent
		if parent(s) == parent(t) {
			parent(s)
		} else if s == parent(t) {
			s
		} else if t == parent(s) {
			t
		} else if t == s or LayeredFlowGraph.is_descendant(m, t, s) {
			s
		} else {
			chain = |x| {
				var $out = [x]
				var $at = x
				var $steps = 0
				while $at != LayeredFlowImport.nil and $steps <= m.nodes.len() {
					$at = parent($at)
					if $at != LayeredFlowImport.nil {
						$out = $out.append($at)
					}
					$steps = $steps + 1
				}
				$out
			}
			tc = chain(t)
			chain(s).find_first(|a| tc.contains(a)) ?? LayeredFlowImport.nil
		}
	}

	## Edges turned around before layout: an edge between members of
	## different subgraphs that closes a cycle among the subgraphs and nodes
	## directly inside their nearest common container, found by a
	## depth-first walk in edge order.
	feedback_flags : LayeredFlowInput.Input -> List(Bool)
	feedback_flags = |diagram| {
		group_count = diagram.groups.len()
		# Ids: nodes 0.., groups after them; the root is `root`.
		root = diagram.nodes.len() + group_count
		parent = |id|
			if id < diagram.nodes.len() {
				match (diagram.nodes.get(id) ?? LayeredFlowImport.no_node).container {
					Root => root
					Group(g) => if (g < group_count) diagram.nodes.len() + g else root
				}
			} else if id < root {
				match (diagram.groups.get(id - diagram.nodes.len()) ?? LayeredFlowImport.no_group).container {
					Root => root
					Group(g) => if (g < group_count) diagram.nodes.len() + g else root
				}
			} else {
				root
			}
		chain = |id| {
			var $out = [id]
			var $at = id
			var $steps = 0
			while $at != root and $steps <= root {
				$at = parent($at)
				$out = $out.append($at)
				$steps = $steps + 1
			}
			$out
		}
		end_id = |end|
			match end {
				Node(i) => i
				Group(g) => diagram.nodes.len() + g
			}
		var $levels = []
		for e in 0..<diagram.edges.len() {
			edge = diagram.edges.get(e) ?? LayeredFlowImport.no_edge
			s = end_id(edge.from)
			t = end_id(edge.to)
			if s != t {
				sc = chain(s)
				tc = chain(t)
				ancestor = sc.find_first(|a| tc.contains(a)) ?? root
				if ancestor != s and ancestor != t {
					child_on_path = |c|
						match c.find_first_index(|a| a == ancestor) {
							Ok(k) if k > 0 => c.get(k - 1) ?? s
							_ => c.first() ?? s
						}
					from = child_on_path(sc)
					to = child_on_path(tc)
					$levels = $levels.append({ ancestor, index: e, from, to, collapsed: from != s or to != t })
				}
			}
		}
		levels = $levels
		var $flags = List.repeat(False, diagram.edges.len())
		var $ancestors = []
		for l in levels {
			if !$ancestors.contains(l.ancestor) {
				$ancestors = $ancestors.append(l.ancestor)
			}
		}
		for ancestor in $ancestors {
			level = levels.keep_if(|l| l.ancestor == ancestor)
			var $nodes = []
			for l in level {
				if !$nodes.contains(l.from) {
					$nodes = $nodes.append(l.from)
				}
				if !$nodes.contains(l.to) {
					$nodes = $nodes.append(l.to)
				}
			}
			nodes = $nodes
			slot = |id| nodes.find_first_index(|x| x == id) ?? 0
			successors = nodes.map(|n| level.keep_if(|l| l.from == n))
			in_degree = nodes.map(|n| level.count_if(|l| l.to == n))
			roots = nodes.keep_if(|n| (in_degree.get(slot(n)) ?? 0) == 0).concat(nodes)
			# 0 unseen, 1 on the walk, 2 finished.
			var $state = List.repeat(0, nodes.len())
			for start in roots {
				if ($state.get(slot(start)) ?? 2) == 0 {
					$state = $state.set(slot(start), 1) ?? []
					var $stack = [{ node: start, next: 0 }]
					while !$stack.is_empty() {
						top = $stack.last() ?? { node: start, next: 0 }
						out = successors.get(slot(top.node)) ?? []
						if top.next >= out.len() {
							$state = $state.set(slot(top.node), 2) ?? []
							$stack = $stack.drop_last(1)
						} else {
							$stack = $stack.set($stack.len() - 1, { node: top.node, next: top.next + 1 }) ?? []
							l = out.get(top.next) ?? { ancestor: 0, index: 0, from: 0, to: 0, collapsed: False }
							seen = $state.get(slot(l.to)) ?? 2
							if seen == 1 {
								$flags = $flags.set(l.index, l.collapsed) ?? []
							} else if seen == 0 {
								$state = $state.set(slot(l.to), 1) ?? []
								$stack = $stack.append({ node: l.to, next: 0 })
							}
						}
					}
				}
			}
		}
		$flags
	}

	ExternalPort : {
		orig_edges : List(U64),
		new_edge : U64,
		dummy_node : U64,
		dummy_port : U64,
		output : Bool,
		exported : Bool,
	}

	Pre : {
		model : LayeredFlowGraph.Model,

		## Segments created for each original edge: (segment edge, graph).
		cross : List({ orig : U64, segment : U64, graph : U64, output : Bool }),

		## Hierarchical port dummy of each subgraph port.
		dummies : List({ port : U64, node : U64 }),
	}

	## Split edges that cross subgraph borders, as the engine's compound graph
	## preprocessor does.
	compound_preprocess : LayeredFlowGraph.Model, Direction -> { model : LayeredFlowGraph.Model, segments : List(List(U64)) }
	compound_preprocess = |model, direction| {
		start = { model, cross: [], dummies: [] }
		walked = LayeredFlowImport.transform_hierarchy_edges(start, 0, LayeredFlowImport.nil, direction)
		pre = walked.pre
		# Labels go to the shallowest segment; original edges are removed.
		var $m = pre.model
		var $origs = []
		for c in pre.cross {
			if !$origs.contains(c.orig) {
				$origs = $origs.append(c.orig)
			}
		}
		var $segments = List.repeat([], $m.edges.len())
		for orig in $origs {
			segs = pre.cross.keep_if(|c| c.orig == orig)
			sorted = LayeredFlowImport.sort_segments($m, segs)
			orig_edge = LayeredFlowGraph.edge($m, orig)
			if !orig_edge.labels.is_empty() {
				var $target_index = 0
				var $found = False
				for k in 0..<sorted.len() {
					if !$found {
						c = sorted.get(k) ?? { orig, segment: orig, graph: 0, output: True }
						if !c.output {
							$target_index = if (k == 0) 0 else k - 1
							$found = True
						} else if k == sorted.len() - 1 {
							$target_index = k
						}
					}
				}
				target = sorted.get($target_index) ?? { orig, segment: orig, graph: 0, output: True }
				seg = LayeredFlowGraph.edge($m, target.segment)
				$m = LayeredFlowGraph.set_edge($m, target.segment, { ..seg, labels: seg.labels.concat(orig_edge.labels) })
				$m = LayeredFlowGraph.set_edge($m, orig, { ..LayeredFlowGraph.edge($m, orig), labels: [] })
			}
			$m = LayeredFlowGraph.set_target(LayeredFlowGraph.set_source($m, orig, LayeredFlowImport.nil), orig, LayeredFlowImport.nil)
			$segments = $segments.set(orig, sorted.map(|c| c.segment)) ?? $segments
		}
		# Subgraph ports take the sides of their dummies; such subgraphs keep
		# their ports' sides fixed.
		for d in pre.dummies {
			dn = LayeredFlowGraph.node($m, d.node)
			p = LayeredFlowGraph.port($m, d.port)
			$m = LayeredFlowGraph.set_port($m, d.port, { ..p, dummy: d.node, inside_connections: True, side: dn.ext_side })
			owner = LayeredFlowGraph.node($m, p.node)
			$m = LayeredFlowGraph.set_node($m, p.node, { ..owner, port_constraints: FixedSide })
		}
		{ model: $m, segments: $segments }
	}

	## Segments of one edge from its source outwards and back in to its
	## target: by graph depth, outgoing segments deepest first, then
	## incoming segments shallowest first.
	sort_segments : LayeredFlowGraph.Model, List({ orig : U64, segment : U64, graph : U64, output : Bool }) -> List({ orig : U64, segment : U64, graph : U64, output : Bool })
	sort_segments = |m, segs| {
		depth = |g| {
			var $d = 0
			var $at = g
			var $steps = 0
			while $at != 0 and $steps < m.graphs.len() {
				$at = LayeredFlowGraph.node(m, LayeredFlowGraph.graph(m, $at).parent).graph
				$d = $d + 1
				$steps = $steps + 1
			}
			$d
		}
		LayeredFlowGraph.sort_by(
			segs,
			|a, b| {
				da = depth(a.graph).to_i64_wrap()
				db = depth(b.graph).to_i64_wrap()
				ka = if (a.output) 0 - da else da
				kb = if (b.output) 0 - db else db
				if a.output != b.output {
					if (a.output) -1 else 1
				} else if ka < kb {
					-1
				} else if ka > kb {
					1
				} else {
					0
				}
			},
		)
	}

	## Depth first over subgraphs: returns the hierarchical ports a graph
	## exports to its parent.
	transform_hierarchy_edges : Pre, U64, U64, Direction -> { pre : Pre, exported : List(ExternalPort) }
	transform_hierarchy_edges = |pre0, g, parent_node, direction| {
		var $pre = pre0
		var $contained = []
		graph_nodes = LayeredFlowGraph.graph($pre.model, g).nodes
		for n in graph_nodes {
			nested = LayeredFlowGraph.node($pre.model, n).nested
			if nested != LayeredFlowImport.nil {
				inner = LayeredFlowImport.transform_hierarchy_edges($pre, nested, n, direction)
				$pre = inner.pre
				$contained = $contained.concat(inner.exported)
				if LayeredFlowGraph.graph($pre.model, nested).external_ports {
					# Ports of the subgraph's own box get a dummy inside it too.
					for p in LayeredFlowGraph.node($pre.model, n).ports {
						if !$pre.dummies.any(|d| d.port == p) {
							port = LayeredFlowGraph.port($pre.model, p)
							(m, dn) = LayeredFlowImport.external_port_dummy($pre.model, nested, port.side, 0 - LayeredFlowGraph.net_flow(port), port.border_offset, direction)
							$pre = { ..$pre, model: m, dummies: $pre.dummies.append({ port: p, node: dn }) }
							$pre = { ..$pre, model: LayeredFlowImport.set_origin_port($pre.model, dn, p) }
							ng = LayeredFlowGraph.graph($pre.model, nested)
							$pre = { ..$pre, model: LayeredFlowGraph.set_graph($pre.model, nested, { ..ng, nodes: ng.nodes.append(dn) }) }
						}
					}
				}
			}
		}
		inner_done = LayeredFlowImport.process_inner($pre, g, parent_node, $contained, direction)
		if parent_node == LayeredFlowImport.nil {
			{ pre: inner_done.pre, exported: inner_done.exported }
		} else {
			outer = LayeredFlowImport.process_outer(inner_done.pre, g, parent_node, direction)
			{ pre: outer.pre, exported: inner_done.exported.concat(outer.exported) }
		}
	}

	set_origin_port : LayeredFlowGraph.Model, U64, U64 -> LayeredFlowGraph.Model
	set_origin_port = |m, dn, p| LayeredFlowGraph.set_node(m, dn, { ..LayeredFlowGraph.node(m, dn), origin: PortDummy(p) })

	process_inner : Pre, U64, U64, List(ExternalPort), Direction -> { pre : Pre, exported : List(ExternalPort) }
	process_inner = |pre0, g, parent_node, contained, direction| {
		var $pre = pre0
		var $created = []
		for ext in contained {
			var $current = None
			for orig in ext.orig_edges {
				m = $pre.model
				oe = LayeredFlowGraph.edge(m, orig)
				if ext.output {
					target_node = LayeredFlowGraph.port(m, oe.target).node
					if LayeredFlowGraph.node(m, target_node).graph == g {
						$pre = LayeredFlowImport.connect(ext.dummy_port, oe.target, orig, g, ext.output, $pre)
					} else if parent_node == LayeredFlowImport.nil or LayeredFlowGraph.is_descendant(m, target_node, parent_node) {
						match contained.find_first(|other| other.dummy_port != ext.dummy_port and other.orig_edges.contains(orig)) {
							Ok(other) => {
								$pre = LayeredFlowImport.connect(ext.dummy_port, other.dummy_port, orig, g, ext.output, $pre)
							}
							Err(_) => {}
						}
					} else {
						r = LayeredFlowImport.introduce_segment($pre, g, parent_node, orig, ext.dummy_port, True, $current, direction)
						$pre = r.pre
						if !$created.any(|c| c.dummy_node == r.ext.dummy_node) {
							$created = $created.append(r.ext)
						}
						if r.ext.exported {
							$current = Some(r.ext)
						}
					}
				} else {
					source_node = LayeredFlowGraph.port(m, oe.source).node
					if LayeredFlowGraph.node(m, source_node).graph == g {
						$pre = LayeredFlowImport.connect(oe.source, ext.dummy_port, orig, g, ext.output, $pre)
					} else if parent_node == LayeredFlowImport.nil or LayeredFlowGraph.is_descendant(m, source_node, parent_node) {
						{}
					} else {
						r = LayeredFlowImport.introduce_segment($pre, g, parent_node, orig, ext.dummy_port, False, $current, direction)
						$pre = r.pre
						if !$created.any(|c| c.dummy_node == r.ext.dummy_node) {
							$created = $created.append(r.ext)
						}
						if r.ext.exported {
							$current = Some(r.ext)
						}
					}
				}
			}
		}
		LayeredFlowImport.finish_created($pre, g, $created)
	}

	finish_created : Pre, U64, List(ExternalPort) -> { pre : Pre, exported : List(ExternalPort) }
	finish_created = |pre, g, created| {
		var $m = pre.model
		var $exported = []
		for ext in created {
			graph = LayeredFlowGraph.graph($m, g)
			if !graph.nodes.contains(ext.dummy_node) {
				$m = LayeredFlowGraph.set_graph($m, g, { ..graph, nodes: graph.nodes.append(ext.dummy_node) })
			}
			if ext.exported {
				$exported = $exported.append(ext)
			}
		}
		{ pre: { ..pre, model: $m }, exported: $exported }
	}

	connect : U64, U64, U64, U64, Bool, Pre -> Pre
	connect = |source, target, orig, g, output, pre| {
		oe = LayeredFlowGraph.edge(pre.model, orig)
		(m, e) = LayeredFlowGraph.add_edge(pre.model, { ..oe, source, target, labels: [], bends: [], segment_graph: g })
		{ ..pre, model: m, cross: pre.cross.append({ orig, segment: e, graph: g, output }) }
	}

	process_outer : Pre, U64, U64, Direction -> { pre : Pre, exported : List(ExternalPort) }
	process_outer = |pre0, g, parent_node, direction| {
		var $pre = pre0
		var $created = []
		for child in LayeredFlowGraph.graph($pre.model, g).nodes {
			for p in LayeredFlowGraph.node($pre.model, child).ports {
				var $current_out = None
				for out in LayeredFlowGraph.port($pre.model, p).outgoing {
					if !LayeredFlowGraph.is_descendant($pre.model, LayeredFlowGraph.target_node($pre.model, out), parent_node) {
						r = LayeredFlowImport.introduce_segment($pre, g, parent_node, out, LayeredFlowGraph.edge($pre.model, out).source, True, $current_out, direction)
						$pre = r.pre
						if !$created.any(|c| c.dummy_node == r.ext.dummy_node) {
							$created = $created.append(r.ext)
						}
						if r.ext.exported {
							$current_out = Some(r.ext)
						}
					}
				}
				var $current_in = None
				for inc in LayeredFlowGraph.port($pre.model, p).incoming {
					if !LayeredFlowGraph.is_descendant($pre.model, LayeredFlowGraph.source_node($pre.model, inc), parent_node) {
						r = LayeredFlowImport.introduce_segment($pre, g, parent_node, inc, LayeredFlowGraph.edge($pre.model, inc).target, False, $current_in, direction)
						$pre = r.pre
						if !$created.any(|c| c.dummy_node == r.ext.dummy_node) {
							$created = $created.append(r.ext)
						}
						if r.ext.exported {
							$current_in = Some(r.ext)
						}
					}
				}
			}
		}
		LayeredFlowImport.finish_created($pre, g, $created)
	}

	## One segment of an edge crossing out of (`output`) or into the
	## subgraph `parent_node`, from or to `opposite`, inside graph `g`.
	## Edges leaving through the same port share one hierarchical port.
	introduce_segment : Pre, U64, U64, U64, U64, Bool, [None, Some(ExternalPort)], Direction -> { pre : Pre, ext : ExternalPort }
	introduce_segment = |pre, g, parent_node, orig, opposite, output, current, direction| {
		m = pre.model
		oe = LayeredFlowGraph.edge(m, orig)
		parent_end = if !output and LayeredFlowGraph.port(m, oe.source).node == parent_node {
			oe.source
		} else if output and LayeredFlowGraph.port(m, oe.target).node == parent_node {
			oe.target
		} else {
			LayeredFlowImport.nil
		}
		match current {
			Some(ext) if parent_end == LayeredFlowImport.nil => {
				# Merged into the port already made for this child port.
				merged = { ..ext, orig_edges: ext.orig_edges.append(orig) }
				{ pre: { ..pre, cross: pre.cross.append({ orig, segment: ext.new_edge, graph: g, output }) }, ext: merged }
			}
			_ => {
				side = if parent_end != LayeredFlowImport.nil {
					LayeredFlowGraph.port(m, parent_end).side
				} else if LayeredFlowGraph.node(m, parent_node).port_constraints != FreePorts {
					if (output) East else West
				} else {
					Undefined
				}
				made = if parent_end != LayeredFlowImport.nil {
					match pre.dummies.find_first(|d| d.port == parent_end) {
						Ok(d) => { model: m, node: d.node, port: parent_end, dummies: pre.dummies }
						Err(_) => {
							flow = LayeredFlowImport.compound_net_flow(m, parent_end, parent_node)
							(m1, dn) = LayeredFlowImport.external_port_dummy(m, g, side, flow, LayeredFlowGraph.port(m, parent_end).border_offset, direction)
							m2 = LayeredFlowImport.set_origin_port(m1, dn, parent_end)
							{ model: m2, node: dn, port: parent_end, dummies: pre.dummies.append({ port: parent_end, node: dn }) }
						}
					}
				} else {
					offset = LayeredFlowGraph.graph(m, g).spacing.edge_edge / 2
					(m1, dn) = LayeredFlowImport.external_port_dummy(m, g, side, if (output) 1 else -1, offset, direction)
					# The new port on the subgraph's box.
					(m2, p) = LayeredFlowGraph.add_port(m1, parent_node, if (output) East else West)
					m3 = LayeredFlowGraph.set_port(m2, p, { ..LayeredFlowGraph.port(m2, p), border_offset: offset })
					m4 = LayeredFlowImport.set_origin_port(m3, dn, p)
					{ model: m4, node: dn, port: p, dummies: pre.dummies.append({ port: p, node: dn }) }
				}
				dummy_node_port = (LayeredFlowGraph.node(made.model, made.node).ports.first()) ?? LayeredFlowImport.nil
				seg_source = if (output) opposite else dummy_node_port
				seg_target = if (output) dummy_node_port else opposite
				(m5, e) = LayeredFlowGraph.add_edge(made.model, { ..oe, source: seg_source, target: seg_target, labels: [], bends: [], segment_graph: g })
				m6 = { ..m5, graphs: m5.graphs.set(g, { ..LayeredFlowGraph.graph(m5, g), external_ports: True }) ?? m5.graphs }
				ext = { orig_edges: [orig], new_edge: e, dummy_node: made.node, dummy_port: made.port, output, exported: parent_end == LayeredFlowImport.nil }
				{ pre: { model: m6, dummies: made.dummies, cross: pre.cross.append({ orig, segment: e, graph: g, output }) }, ext }
			}
		}
	}

	## Net flow of a subgraph's port seen from inside: edges to members count
	## as incoming.
	compound_net_flow : LayeredFlowGraph.Model, U64, U64 -> I64
	compound_net_flow = |m, p, owner| {
		port = LayeredFlowGraph.port(m, p)
		var $out = 0
		var $in = 0
		for e in port.outgoing {
			t = LayeredFlowGraph.target_node(m, e)
			if LayeredFlowGraph.is_self_loop(m, e) {
				$out = $out + 1
			} else if LayeredFlowGraph.graph(m, LayeredFlowGraph.node(m, t).graph).parent == owner {
				$in = $in + 1
			} else {
				$out = $out + 1
			}
		}
		for e in port.incoming {
			s = LayeredFlowGraph.source_node(m, e)
			if LayeredFlowGraph.is_self_loop(m, e) {
				$in = $in + 1
			} else if LayeredFlowGraph.graph(m, LayeredFlowGraph.node(m, s).graph).parent == owner {
				$out = $out + 1
			} else {
				$in = $in + 1
			}
		}
		$out - $in
	}

	## A hierarchical port dummy in graph `g`, as the engine makes one: in the
	## first or last layer of its own, with one port facing into the graph.
	## Sides here are already in the layout's reading.
	external_port_dummy : LayeredFlowGraph.Model, U64, LayeredFlowGraph.Side, I64, F64, Direction -> (LayeredFlowGraph.Model, U64)
	external_port_dummy = |m, g, side, flow, border_offset, _direction| {
		final_side = match side {
			Undefined => if (flow >= 0) East else West
			s => s
		}
		constraint = match final_side {
			West => FirstSeparate
			_ => LastSeparate
		}
		(m1, dn) = LayeredFlowGraph.add_loose_node(m, { ..LayeredFlowGraph.blank_node, graph: g, kind: ExternalPort, port_constraints: FixedPos, layer_constraint: constraint, ext_side: final_side, border_offset })
		(m2, _) = LayeredFlowGraph.add_port(m1, dn, if (final_side == West) East else West)
		(m2, dn)
	}
}

## Test helper: a diagram's working graph with every node 152 by 41, edge
## labels 31.27 by 17 and titles 10 by 17, as Mermaid measured the recorded
## runs these tests take their expected values from.
test_setup : Str -> LayeredFlowImport.Setup
test_setup = |text| {
	fixture = LayeredFlowFixtures.get(text)
	LayeredFlowImport.build_registered(fixture.diagram, fixture.sizes, fixture.registration)
}

## A subgraph with its own direction and no edge crossing its border is laid
## out on its own, reading its own way; one an edge leaves is laid out with
## the drawing. Recorded: Mermaid gives `s` SEPARATE_CHILDREN with direction
## RIGHT and `t` (left by `d --> e`) INCLUDE_CHILDREN.
expect {
	setup = test_setup("flowchart TD\n    subgraph s [S]\n        direction LR\n        a --> b\n    end\n    subgraph t [T]\n        direction LR\n        c --> d\n    end\n    s --> t\n    d --> e\n")
	m = setup.model
	s = LayeredFlowGraph.graph(m, setup.group_graph.get(0) ?? 0)
	t = LayeredFlowGraph.graph(m, setup.group_graph.get(1) ?? 0)
	s.separate and s.direction == Right and !t.separate and t.direction == Down
}

## Each node lies in its container's graph, in Mermaid's order: subgraphs
## last declared first, then nodes.
expect {
	setup = test_setup("flowchart LR\n    a --> b\n    subgraph g [G]\n        c\n    end\n    subgraph h [H]\n        d\n    end\n")
	m = setup.model
	root = LayeredFlowGraph.graph(m, 0).nodes
	root == [setup.group_node.get(1) ?? 0, setup.group_node.get(0) ?? 0, setup.node_of.get(0) ?? 0, setup.node_of.get(1) ?? 0]
		and LayeredFlowGraph.node(m, setup.node_of.get(2) ?? 0).graph == (setup.group_graph.get(0) ?? 0)
}

## An empty subgraph has no graph and no size.
expect {
	setup = test_setup("flowchart TD\n    a --> e\n    subgraph e [E]\n    end\n")
	node = LayeredFlowGraph.node(setup.model, setup.group_node.get(0) ?? 0)
	setup.group_graph == [LayeredFlowGraph.nil] and node.width == 0 and node.height == 0
}

## Physical minimum sizes are projected into the internal flow axis in all directions.
expect ["TD", "BT", "LR", "RL"].all(
	|direction| {
		fixture = LayeredFlowFixtures.get("flowchart ${direction}\nsubgraph s [Long title]\nA --> B\nend\nB --> D\n")
		vertical = fixture.diagram.direction == Down or fixture.diagram.direction == Up
		diagram = {
			..fixture.diagram,
			groups: fixture.diagram.groups.map(
				|group| {
					..group,
					min_width: if vertical {
						0
					} else {
						1010
					},
					min_height: if vertical {
						1010
					} else {
						0
					},
				},
			),
		}
		setup = LayeredFlowImport.build_registered(diagram, fixture.sizes, fixture.registration)
		group = LayeredFlowGraph.graph(setup.model, setup.group_graph.get(0) ?? 0)
		group.min_width == 1010 and group.min_height == 0 and !group.separate
	},
)
