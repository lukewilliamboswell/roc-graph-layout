import Flowchart
import FlowGeometry
import FlowLayoutGraph

## Builds the working layout graph from a diagram, the way Mermaid hands a
## flowchart to its layout engine and the engine reads it: one graph for the
## drawing and one inside each subgraph that has members, nodes in Mermaid's
## order, a port at each end of each edge, and, for an edge that crosses
## subgraph borders, one segment per graph it passes through, joined by
## ports on the subgraphs' borders.
FlowLayoutImport :: {}.{

	Direction : [Down, Up, Right, Left]

	Setup : {
		model : FlowLayoutGraph.Model,
		direction : Direction,

		## The layout node of each diagram node and each subgraph.
		node_of : List(U64),
		group_node : List(U64),

		## The nested graph of each subgraph, or `nil` for an empty one.
		group_graph : List(U64),

		## The layout edge of each diagram edge, and whether Mermaid handed it to
		## the engine turned around.
		edge_of : List(U64),
		flipped : List(Bool),

		## The edges each diagram edge was split into at subgraph borders, in
		## no particular order.
		segments : List(List(U64)),
	}

	Item : [GroupItem(U64), NodeItem(U64)]

	nil : U64
	nil = FlowLayoutGraph.nil

	finite : F64 -> F64
	finite = |v| if (F64.is_finite(v) and v > 0) v else 0

	direction_of : Flowchart.Diagram -> Direction
	direction_of = |diagram| diagram.direction

	vertical : Direction -> Bool
	vertical = |d|
		match d {
			Down | Up => True
			_ => False
		}

	## A size in the layout's reading, along and across the flow.
	internal_size : Direction, F64, F64 -> { width : F64, height : F64 }
	internal_size = |d, w, h| if (FlowLayoutImport.vertical(d)) { width: h, height: w } else { width: w, height: h }

	## Spacing at the top level: Mermaid sets a base of 40, which doubles
	## every spacing the engine derives from its base.
	root_spacing : FlowLayoutGraph.Spacing
	root_spacing = {
		node_node: 40,
		node_node_between_layers: 40,
		edge_node: 20,
		edge_node_between_layers: 20,
		edge_edge: 20,
		edge_edge_between_layers: 20,
		edge_label: 4,
		label_label: 0,
		label_node: 10,
		port_port: 20,
		node_self_loop: 20,
		ports_surrounding: 12,
	}

	## Spacing inside subgraphs: a base of 24, with node, edge and
	## edge-to-layer spacing set on their own.
	group_spacing : FlowLayoutGraph.Spacing
	group_spacing = {
		node_node: 50,
		node_node_between_layers: 24,
		edge_node: 12,
		edge_node_between_layers: 30,
		edge_edge: 20,
		edge_edge_between_layers: 12,
		edge_label: 2.4,
		label_label: 0,
		label_node: 6,
		port_port: 12,
		node_self_loop: 12,
		ports_surrounding: 12,
	}

	group_padding : F64
	group_padding = 24

	## Room the engine keeps between a subgraph's title and its members.
	title_gap : F64
	title_gap = 5

	## Padding in the layout's reading, from padding given as drawn.
	internal_padding : Direction, FlowLayoutGraph.Margins -> FlowLayoutGraph.Margins
	internal_padding = |d, p|
		match d {
			Right => p
			Left => { top: p.top, bottom: p.bottom, left: p.right, right: p.left }
			Down => { top: p.left, bottom: p.right, left: p.top, right: p.bottom }
			Up => { top: p.left, bottom: p.right, left: p.bottom, right: p.top }
		}

	## The members of a container in Mermaid's order: subgraphs first, last
	## declared first, then nodes in order.
	children : Flowchart.Diagram, Flowchart.Container -> List(Item)
	children = |diagram, container| {
		var $out = []
		var $g = diagram.groups.len()
		while $g > 0 {
			$g = $g - 1
			if (diagram.groups.get($g) ?? FlowLayoutImport.no_group).container == container {
				$out = $out.append(GroupItem($g))
			}
		}
		for i in 0..<diagram.nodes.len() {
			if (diagram.nodes.get(i) ?? FlowLayoutImport.no_node).container == container {
				$out = $out.append(NodeItem(i))
			}
		}
		$out
	}

	no_group : Flowchart.Group
	no_group = { id: "", title: "", container: Root, direction: Inherit, classes: [] }

	no_node : Flowchart.Node
	no_node = { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }

	no_edge : Flowchart.Edge
	no_edge = { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }

	## Which subgraph each container lies in, by item.
	parent_of : Flowchart.Diagram, Item -> [Root, Group(U64)]
	parent_of = |diagram, item| {
		container = match item {
			GroupItem(g) => (diagram.groups.get(g) ?? FlowLayoutImport.no_group).container
			NodeItem(i) => (diagram.nodes.get(i) ?? FlowLayoutImport.no_node).container
		}
		match container {
			Root => Root
			Group(g) => if (g < diagram.groups.len()) Group(g) else Root
		}
	}

	build : Flowchart.Diagram, FlowGeometry.Sizes -> Setup
	build = |diagram, sizes| {
		direction = FlowLayoutImport.direction_of(diagram)
		group_count = diagram.groups.len()
		root_graph = { ..FlowLayoutGraph.blank_graph, spacing: FlowLayoutImport.root_spacing, padding: { top: 12, right: 12, bottom: 12, left: 12 }, model_order_nodes: True, direction }
		separate = FlowLayoutImport.separate_groups(diagram)
		var $model = { graphs: [root_graph], nodes: [], ports: [], edges: [], loops: [] }
		var $node_of = List.repeat(FlowLayoutImport.nil, diagram.nodes.len())
		var $group_node = List.repeat(FlowLayoutImport.nil, group_count)
		var $group_graph = List.repeat(FlowLayoutImport.nil, group_count)
		# Nodes, breadth first, as the engine imports them.
		var $queue = FlowLayoutImport.children(diagram, Root)
		var $head = 0
		var $order = 0
		while $head < $queue.len() {
			item = $queue.get($head) ?? NodeItem(0)
			$head = $head + 1
			parent_graph = match FlowLayoutImport.parent_of(diagram, item) {
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
			dir = FlowLayoutGraph.graph($model, parent_graph).direction
			match item {
				NodeItem(i) => {
					raw = sizes.nodes.get(i) ?? { width: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
					size = FlowLayoutImport.internal_size(dir, FlowLayoutImport.finite(raw.width), FlowLayoutImport.finite(raw.height))
					(m, n) = FlowLayoutGraph.add_node($model, { ..FlowLayoutGraph.blank_node, graph: parent_graph, origin: DiagramNode(i), width: size.width, height: size.height, model_order })
					$model = m
					$node_of = $node_of.set(i, n) ?? []
				}
				GroupItem(g) => {
					title = sizes.group_titles.get(g) ?? { lines: [], width: 0, height: 0 }
					# Mermaid hands the engine the title's measured box less two
					# pixels of height, and a minimum width of the title plus the
					# subgraph's own padding.
					title_w = FlowLayoutImport.finite(title.width)
					title_h = (FlowLayoutImport.finite(title.height) - 2).max(0)
					members = FlowLayoutImport.children(diagram, Group(g))
					(m, n) = FlowLayoutGraph.add_node($model, { ..FlowLayoutGraph.blank_node, graph: parent_graph, origin: Group(g), model_order })
					$model = m
					$group_node = $group_node.set(g, n) ?? []
					if !members.is_empty() {
						own = separate.get(g) ?? False
						inner_dir = if own {
							match (diagram.groups.get(g) ?? FlowLayoutImport.no_group).direction {
								Set(d) => d
								Inherit => Right
							}
						} else {
							dir
						}
						label_room = if (title_h > 0) title_h + FlowLayoutImport.title_gap else 0
						pad = FlowLayoutImport.group_padding
						padding = FlowLayoutImport.internal_padding(inner_dir, { top: pad + label_room, right: pad, bottom: pad, left: pad })
						min = FlowLayoutImport.internal_size(inner_dir, title_w + 8, 0)
						title_size = FlowLayoutImport.internal_size(inner_dir, title_w, title_h)
						gi = $model.graphs.len()
						$model = { ..$model, graphs: $model.graphs.append({ ..FlowLayoutGraph.blank_graph, parent: n, spacing: FlowLayoutImport.group_spacing, padding, min_width: min.width, min_height: min.height, title_width: title_size.width, title_height: title_size.height, direction: inner_dir, separate: own }) }
						$model = FlowLayoutGraph.set_node($model, n, if (own) { ..FlowLayoutGraph.node($model, n), inner: gi } else { ..FlowLayoutGraph.node($model, n), nested: gi })
						$group_graph = $group_graph.set(g, gi) ?? []
						$queue = $queue.concat(members)
					} else {
						# Mermaid gives an empty subgraph no size, so the engine
						# places it as a point.
						$model = FlowLayoutGraph.set_node($model, n, { ..FlowLayoutGraph.node($model, n), width: 0, height: 0 })
					}
				}
			}
		}
		node_of = $node_of
		group_node = $group_node
		end_node = |end|
			match end {
				Node(i) => node_of.get(i) ?? FlowLayoutImport.nil
				Group(g) => group_node.get(g) ?? FlowLayoutImport.nil
			}
		flipped = FlowLayoutImport.feedback_flags(diagram)
		# The engine reads edges graph by graph, breadth first, each edge in the
		# graph that contains both its ends; that order decides port order and
		# the edges' model order.
		model0 = $model
		ends_of = |e| {
			edge = diagram.edges.get(e) ?? FlowLayoutImport.no_edge
			flip = flipped.get(e) ?? False
			{ from: end_node(if (flip) edge.to else edge.from), to: end_node(if (flip) edge.from else edge.to) }
		}
		rank = |e| {
			ends = ends_of(e)
			c = FlowLayoutImport.container(model0, ends.from, ends.to)
			if c == FlowLayoutImport.nil {
				0
			} else {
				FlowLayoutImport.content(model0, c)
			}
		}
		edge_order = FlowLayoutGraph.sort_by(
			List.repeat(0, diagram.edges.len()).map_with_index(|_, e| e),
			|a, b| {
				ra = rank(a)
				rb = rank(b)
				if (ra < rb) -1 else if (ra > rb) 1 else 0
			},
		)
		# Edges, each with a port at each end.
		var $edge_of = List.repeat(FlowLayoutImport.nil, diagram.edges.len())
		var $edge_order_index = 0
		for e in edge_order {
			edge = diagram.edges.get(e) ?? FlowLayoutImport.no_edge
			ends = ends_of(e)
			from = ends.from
			to = ends.to
			if from != FlowLayoutImport.nil and to != FlowLayoutImport.nil {
				(m1, sp) = FlowLayoutGraph.add_port($model, from, East)
				(m2, tp) = FlowLayoutGraph.add_port(m1, to, West)
				label_dir = FlowLayoutGraph.graph(model0, rank(e)).direction
				labels = match sizes.edge_labels.get(e) ?? None {
					Some(block) if !edge.label.is_empty() => {
						size = FlowLayoutImport.internal_size(label_dir, FlowLayoutImport.finite(block.width) + 4, FlowLayoutImport.finite(block.height) + 4)
						[{ width: size.width, height: size.height, edge: e }]
					}
					_ => []
				}
				(m3, le) = FlowLayoutGraph.add_edge(m2, { ..FlowLayoutGraph.blank_edge, source: sp, target: tp, origin: e, labels, model_order: Some($edge_order_index) })
				$edge_order_index = $edge_order_index + 1
				$model = m3
				$edge_of = $edge_of.set(e, le) ?? $edge_of
			}
		}
		pre = FlowLayoutImport.compound_preprocess($model, direction)
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
	content : FlowLayoutGraph.Model, U64 -> U64
	content = |m, n| {
		node = FlowLayoutGraph.node(m, n)
		if (node.nested != FlowLayoutImport.nil) node.nested else node.inner
	}

	## Which subgraphs Mermaid has laid out on their own: one with a
	## `direction` of its own, or inside one laid out on its own, unless an
	## edge between different parents passes through it or ends at it. Such
	## an edge makes every subgraph from its ends up to their lowest common
	## ancestor, that one included, part of its parent's layout.
	separate_groups : Flowchart.Diagram -> List(Bool)
	separate_groups = |diagram| {
		count = diagram.groups.len()
		group_parent = |g|
			match (diagram.groups.get(g) ?? FlowLayoutImport.no_group).container {
				Group(p) => if (p < count) Some(p) else None
				Root => None
			}
		parent_of_end = |end|
			match end {
				Node(i) =>
					match (diagram.nodes.get(i) ?? FlowLayoutImport.no_node).container {
						Group(p) => if (p < count) Some(p) else None
						Root => None
					}
				Group(g) => group_parent(g)
			}
		# An end and the groups above it, innermost first, the end itself
		# included when it is a group.
		chain = |end| {
			start = match end {
				Node(_) => parent_of_end(end)
				Group(g) => Some(g)
			}
			var $out = []
			var $at = start
			var $guard = 0
			while $guard <= count {
				match $at {
					Some(g) => {
						$out = $out.append(g)
						$at = group_parent(g)
					}
					None => {
						$guard = count
					}
				}
				$guard = $guard + 1
			}
			$out
		}
		var $included = List.repeat(False, count)
		for edge in diagram.edges {
			if parent_of_end(edge.from) != parent_of_end(edge.to) {
				from_chain = chain(edge.from)
				to_chain = chain(edge.to)
				# Mermaid's lowest common ancestor of the two ends: an end that
				# contains the other, else the first shared group.
				lca = match (edge.from, edge.to) {
					(Group(a), _) if to_chain.contains(a) => Some(a)
					(_, Group(b)) if from_chain.contains(b) => Some(b)
					_ =>
						match from_chain.find_first(|g| to_chain.contains(g)) {
							Ok(g) => Some(g)
							Err(_) => None
						}
				}
				for c in [from_chain, to_chain] {
					var $going = True
					for g in c {
						if $going {
							$included = $included.set(g, True) ?? $included
							if Some(g) == lca {
								$going = False
							}
						}
					}
				}
			}
		}
		included = $included
		# Top-down: a subgraph's handling is settled before its members'.
		var $separate = List.repeat(False, count)
		var $done = List.repeat(False, count)
		var $round = 0
		while $round <= count {
			for g in 0..<count {
				if !($done.get(g) ?? True) {
					parent_done = match group_parent(g) {
						Some(p) => $done.get(p) ?? True
						None => True
					}
					if parent_done {
						own_direction = match (diagram.groups.get(g) ?? FlowLayoutImport.no_group).direction {
							Set(_) => True
							Inherit => False
						}
						inherited = match group_parent(g) {
							Some(p) => $separate.get(p) ?? False
							None => False
						}
						value = !(included.get(g) ?? False) and (own_direction or inherited)
						$separate = $separate.set(g, value) ?? $separate
						$done = $done.set(g, True) ?? $done
					}
				}
			}
			$round = $round + 1
		}
		$separate
	}

	## The subgraph node an edge between `s` and `t` belongs to (`nil` for
	## the drawing), as the engine's reader decides it: the common parent of
	## siblings, the end that contains the other, or the lowest common
	## ancestor.
	container : FlowLayoutGraph.Model, U64, U64 -> U64
	container = |m, s, t| {
		parent = |x| FlowLayoutGraph.graph(m, FlowLayoutGraph.node(m, x).graph).parent
		if parent(s) == parent(t) {
			parent(s)
		} else if s == parent(t) {
			s
		} else if t == parent(s) {
			t
		} else if t == s or FlowLayoutGraph.is_descendant(m, t, s) {
			s
		} else {
			chain = |x| {
				var $out = [x]
				var $at = x
				var $steps = 0
				while $at != FlowLayoutImport.nil and $steps <= m.nodes.len() {
					$at = parent($at)
					if $at != FlowLayoutImport.nil {
						$out = $out.append($at)
					}
					$steps = $steps + 1
				}
				$out
			}
			tc = chain(t)
			chain(s).find_first(|a| tc.contains(a)) ?? FlowLayoutImport.nil
		}
	}

	## Edges Mermaid turns around before layout: an edge between members of
	## different subgraphs that closes a cycle among the subgraphs and nodes
	## directly inside their nearest common container, found by a
	## depth-first walk in edge order.
	feedback_flags : Flowchart.Diagram -> List(Bool)
	feedback_flags = |diagram| {
		group_count = diagram.groups.len()
		# Ids: nodes 0.., groups after them; the root is `root`.
		root = diagram.nodes.len() + group_count
		parent = |id|
			if id < diagram.nodes.len() {
				match (diagram.nodes.get(id) ?? FlowLayoutImport.no_node).container {
					Root => root
					Group(g) => if (g < group_count) diagram.nodes.len() + g else root
				}
			} else if id < root {
				match (diagram.groups.get(id - diagram.nodes.len()) ?? FlowLayoutImport.no_group).container {
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
			edge = diagram.edges.get(e) ?? FlowLayoutImport.no_edge
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
		model : FlowLayoutGraph.Model,

		## Segments created for each original edge: (segment edge, graph).
		cross : List({ orig : U64, segment : U64, graph : U64, output : Bool }),

		## Hierarchical port dummy of each subgraph port.
		dummies : List({ port : U64, node : U64 }),
	}

	## Split edges that cross subgraph borders, as the engine's compound graph
	## preprocessor does.
	compound_preprocess : FlowLayoutGraph.Model, Direction -> { model : FlowLayoutGraph.Model, segments : List(List(U64)) }
	compound_preprocess = |model, direction| {
		start = { model, cross: [], dummies: [] }
		walked = FlowLayoutImport.transform_hierarchy_edges(start, 0, FlowLayoutImport.nil, direction)
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
			sorted = FlowLayoutImport.sort_segments($m, segs)
			orig_edge = FlowLayoutGraph.edge($m, orig)
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
				seg = FlowLayoutGraph.edge($m, target.segment)
				$m = FlowLayoutGraph.set_edge($m, target.segment, { ..seg, labels: seg.labels.concat(orig_edge.labels) })
				$m = FlowLayoutGraph.set_edge($m, orig, { ..FlowLayoutGraph.edge($m, orig), labels: [] })
			}
			$m = FlowLayoutGraph.set_target(FlowLayoutGraph.set_source($m, orig, FlowLayoutImport.nil), orig, FlowLayoutImport.nil)
			$segments = $segments.set(orig, sorted.map(|c| c.segment)) ?? $segments
		}
		# Subgraph ports take the sides of their dummies; such subgraphs keep
		# their ports' sides fixed.
		for d in pre.dummies {
			dn = FlowLayoutGraph.node($m, d.node)
			p = FlowLayoutGraph.port($m, d.port)
			$m = FlowLayoutGraph.set_port($m, d.port, { ..p, dummy: d.node, inside_connections: True, side: dn.ext_side })
			owner = FlowLayoutGraph.node($m, p.node)
			$m = FlowLayoutGraph.set_node($m, p.node, { ..owner, port_constraints: FixedSide })
		}
		{ model: $m, segments: $segments }
	}

	## Segments of one edge from its source outwards and back in to its
	## target: by graph depth, outgoing segments deepest first, then
	## incoming segments shallowest first.
	sort_segments : FlowLayoutGraph.Model, List({ orig : U64, segment : U64, graph : U64, output : Bool }) -> List({ orig : U64, segment : U64, graph : U64, output : Bool })
	sort_segments = |m, segs| {
		depth = |g| {
			var $d = 0
			var $at = g
			var $steps = 0
			while $at != 0 and $steps < m.graphs.len() {
				$at = FlowLayoutGraph.node(m, FlowLayoutGraph.graph(m, $at).parent).graph
				$d = $d + 1
				$steps = $steps + 1
			}
			$d
		}
		FlowLayoutGraph.sort_by(
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
		graph_nodes = FlowLayoutGraph.graph($pre.model, g).nodes
		for n in graph_nodes {
			nested = FlowLayoutGraph.node($pre.model, n).nested
			if nested != FlowLayoutImport.nil {
				inner = FlowLayoutImport.transform_hierarchy_edges($pre, nested, n, direction)
				$pre = inner.pre
				$contained = $contained.concat(inner.exported)
				if FlowLayoutGraph.graph($pre.model, nested).external_ports {
					# Ports of the subgraph's own box get a dummy inside it too.
					for p in FlowLayoutGraph.node($pre.model, n).ports {
						if !$pre.dummies.any(|d| d.port == p) {
							port = FlowLayoutGraph.port($pre.model, p)
							(m, dn) = FlowLayoutImport.external_port_dummy($pre.model, nested, port.side, 0 - FlowLayoutGraph.net_flow(port), port.border_offset, direction)
							$pre = { ..$pre, model: m, dummies: $pre.dummies.append({ port: p, node: dn }) }
							$pre = { ..$pre, model: FlowLayoutImport.set_origin_port($pre.model, dn, p) }
							ng = FlowLayoutGraph.graph($pre.model, nested)
							$pre = { ..$pre, model: FlowLayoutGraph.set_graph($pre.model, nested, { ..ng, nodes: ng.nodes.append(dn) }) }
						}
					}
				}
			}
		}
		inner_done = FlowLayoutImport.process_inner($pre, g, parent_node, $contained, direction)
		if parent_node == FlowLayoutImport.nil {
			{ pre: inner_done.pre, exported: inner_done.exported }
		} else {
			outer = FlowLayoutImport.process_outer(inner_done.pre, g, parent_node, direction)
			{ pre: outer.pre, exported: inner_done.exported.concat(outer.exported) }
		}
	}

	set_origin_port : FlowLayoutGraph.Model, U64, U64 -> FlowLayoutGraph.Model
	set_origin_port = |m, dn, p| FlowLayoutGraph.set_node(m, dn, { ..FlowLayoutGraph.node(m, dn), origin: PortDummy(p) })

	process_inner : Pre, U64, U64, List(ExternalPort), Direction -> { pre : Pre, exported : List(ExternalPort) }
	process_inner = |pre0, g, parent_node, contained, direction| {
		var $pre = pre0
		var $created = []
		for ext in contained {
			var $current = None
			for orig in ext.orig_edges {
				m = $pre.model
				oe = FlowLayoutGraph.edge(m, orig)
				if ext.output {
					target_node = FlowLayoutGraph.port(m, oe.target).node
					if FlowLayoutGraph.node(m, target_node).graph == g {
						$pre = FlowLayoutImport.connect(ext.dummy_port, oe.target, orig, g, ext.output, $pre)
					} else if parent_node == FlowLayoutImport.nil or FlowLayoutGraph.is_descendant(m, target_node, parent_node) {
						match contained.find_first(|other| other.dummy_port != ext.dummy_port and other.orig_edges.contains(orig)) {
							Ok(other) => {
								$pre = FlowLayoutImport.connect(ext.dummy_port, other.dummy_port, orig, g, ext.output, $pre)
							}
							Err(_) => {}
						}
					} else {
						r = FlowLayoutImport.introduce_segment($pre, g, parent_node, orig, ext.dummy_port, True, $current, direction)
						$pre = r.pre
						if !$created.any(|c| c.dummy_node == r.ext.dummy_node) {
							$created = $created.append(r.ext)
						}
						if r.ext.exported {
							$current = Some(r.ext)
						}
					}
				} else {
					source_node = FlowLayoutGraph.port(m, oe.source).node
					if FlowLayoutGraph.node(m, source_node).graph == g {
						$pre = FlowLayoutImport.connect(oe.source, ext.dummy_port, orig, g, ext.output, $pre)
					} else if parent_node == FlowLayoutImport.nil or FlowLayoutGraph.is_descendant(m, source_node, parent_node) {
						{}
					} else {
						r = FlowLayoutImport.introduce_segment($pre, g, parent_node, orig, ext.dummy_port, False, $current, direction)
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
		FlowLayoutImport.finish_created($pre, g, $created)
	}

	finish_created : Pre, U64, List(ExternalPort) -> { pre : Pre, exported : List(ExternalPort) }
	finish_created = |pre, g, created| {
		var $m = pre.model
		var $exported = []
		for ext in created {
			graph = FlowLayoutGraph.graph($m, g)
			if !graph.nodes.contains(ext.dummy_node) {
				$m = FlowLayoutGraph.set_graph($m, g, { ..graph, nodes: graph.nodes.append(ext.dummy_node) })
			}
			if ext.exported {
				$exported = $exported.append(ext)
			}
		}
		{ pre: { ..pre, model: $m }, exported: $exported }
	}

	connect : U64, U64, U64, U64, Bool, Pre -> Pre
	connect = |source, target, orig, g, output, pre| {
		oe = FlowLayoutGraph.edge(pre.model, orig)
		(m, e) = FlowLayoutGraph.add_edge(pre.model, { ..oe, source, target, labels: [], bends: [], segment_graph: g })
		{ ..pre, model: m, cross: pre.cross.append({ orig, segment: e, graph: g, output }) }
	}

	process_outer : Pre, U64, U64, Direction -> { pre : Pre, exported : List(ExternalPort) }
	process_outer = |pre0, g, parent_node, direction| {
		var $pre = pre0
		var $created = []
		for child in FlowLayoutGraph.graph($pre.model, g).nodes {
			for p in FlowLayoutGraph.node($pre.model, child).ports {
				var $current_out = None
				for out in FlowLayoutGraph.port($pre.model, p).outgoing {
					if !FlowLayoutGraph.is_descendant($pre.model, FlowLayoutGraph.target_node($pre.model, out), parent_node) {
						r = FlowLayoutImport.introduce_segment($pre, g, parent_node, out, FlowLayoutGraph.edge($pre.model, out).source, True, $current_out, direction)
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
				for inc in FlowLayoutGraph.port($pre.model, p).incoming {
					if !FlowLayoutGraph.is_descendant($pre.model, FlowLayoutGraph.source_node($pre.model, inc), parent_node) {
						r = FlowLayoutImport.introduce_segment($pre, g, parent_node, inc, FlowLayoutGraph.edge($pre.model, inc).target, False, $current_in, direction)
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
		FlowLayoutImport.finish_created($pre, g, $created)
	}

	## One segment of an edge crossing out of (`output`) or into the
	## subgraph `parent_node`, from or to `opposite`, inside graph `g`.
	## Edges leaving through the same port share one hierarchical port.
	introduce_segment : Pre, U64, U64, U64, U64, Bool, [None, Some(ExternalPort)], Direction -> { pre : Pre, ext : ExternalPort }
	introduce_segment = |pre, g, parent_node, orig, opposite, output, current, direction| {
		m = pre.model
		oe = FlowLayoutGraph.edge(m, orig)
		parent_end = if !output and FlowLayoutGraph.port(m, oe.source).node == parent_node {
			oe.source
		} else if output and FlowLayoutGraph.port(m, oe.target).node == parent_node {
			oe.target
		} else {
			FlowLayoutImport.nil
		}
		match current {
			Some(ext) if parent_end == FlowLayoutImport.nil => {
				# Merged into the port already made for this child port.
				merged = { ..ext, orig_edges: ext.orig_edges.append(orig) }
				{ pre: { ..pre, cross: pre.cross.append({ orig, segment: ext.new_edge, graph: g, output }) }, ext: merged }
			}
			_ => {
				side = if parent_end != FlowLayoutImport.nil {
					FlowLayoutGraph.port(m, parent_end).side
				} else if FlowLayoutGraph.node(m, parent_node).port_constraints != FreePorts {
					if (output) East else West
				} else {
					Undefined
				}
				made = if parent_end != FlowLayoutImport.nil {
					match pre.dummies.find_first(|d| d.port == parent_end) {
						Ok(d) => { model: m, node: d.node, port: parent_end, dummies: pre.dummies }
						Err(_) => {
							flow = FlowLayoutImport.compound_net_flow(m, parent_end, parent_node)
							(m1, dn) = FlowLayoutImport.external_port_dummy(m, g, side, flow, FlowLayoutGraph.port(m, parent_end).border_offset, direction)
							m2 = FlowLayoutImport.set_origin_port(m1, dn, parent_end)
							{ model: m2, node: dn, port: parent_end, dummies: pre.dummies.append({ port: parent_end, node: dn }) }
						}
					}
				} else {
					offset = FlowLayoutGraph.graph(m, g).spacing.edge_edge / 2
					(m1, dn) = FlowLayoutImport.external_port_dummy(m, g, side, if (output) 1 else -1, offset, direction)
					# The new port on the subgraph's box.
					(m2, p) = FlowLayoutGraph.add_port(m1, parent_node, if (output) East else West)
					m3 = FlowLayoutGraph.set_port(m2, p, { ..FlowLayoutGraph.port(m2, p), border_offset: offset })
					m4 = FlowLayoutImport.set_origin_port(m3, dn, p)
					{ model: m4, node: dn, port: p, dummies: pre.dummies.append({ port: p, node: dn }) }
				}
				dummy_node_port = (FlowLayoutGraph.node(made.model, made.node).ports.first()) ?? FlowLayoutImport.nil
				seg_source = if (output) opposite else dummy_node_port
				seg_target = if (output) dummy_node_port else opposite
				(m5, e) = FlowLayoutGraph.add_edge(made.model, { ..oe, source: seg_source, target: seg_target, labels: [], bends: [], segment_graph: g })
				m6 = { ..m5, graphs: m5.graphs.set(g, { ..FlowLayoutGraph.graph(m5, g), external_ports: True }) ?? m5.graphs }
				ext = { orig_edges: [orig], new_edge: e, dummy_node: made.node, dummy_port: made.port, output, exported: parent_end == FlowLayoutImport.nil }
				{ pre: { model: m6, dummies: made.dummies, cross: pre.cross.append({ orig, segment: e, graph: g, output }) }, ext }
			}
		}
	}

	## Net flow of a subgraph's port seen from inside: edges to members count
	## as incoming.
	compound_net_flow : FlowLayoutGraph.Model, U64, U64 -> I64
	compound_net_flow = |m, p, owner| {
		port = FlowLayoutGraph.port(m, p)
		var $out = 0
		var $in = 0
		for e in port.outgoing {
			t = FlowLayoutGraph.target_node(m, e)
			if FlowLayoutGraph.is_self_loop(m, e) {
				$out = $out + 1
			} else if FlowLayoutGraph.graph(m, FlowLayoutGraph.node(m, t).graph).parent == owner {
				$in = $in + 1
			} else {
				$out = $out + 1
			}
		}
		for e in port.incoming {
			s = FlowLayoutGraph.source_node(m, e)
			if FlowLayoutGraph.is_self_loop(m, e) {
				$in = $in + 1
			} else if FlowLayoutGraph.graph(m, FlowLayoutGraph.node(m, s).graph).parent == owner {
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
	external_port_dummy : FlowLayoutGraph.Model, U64, FlowLayoutGraph.Side, I64, F64, Direction -> (FlowLayoutGraph.Model, U64)
	external_port_dummy = |m, g, side, flow, border_offset, _direction| {
		final_side = match side {
			Undefined => if (flow >= 0) East else West
			s => s
		}
		constraint = match final_side {
			West => FirstSeparate
			_ => LastSeparate
		}
		(m1, dn) = FlowLayoutGraph.add_loose_node(m, { ..FlowLayoutGraph.blank_node, graph: g, kind: ExternalPort, port_constraints: FixedPos, layer_constraint: constraint, ext_side: final_side, border_offset })
		(m2, _) = FlowLayoutGraph.add_port(m1, dn, if (final_side == West) East else West)
		(m2, dn)
	}
}
