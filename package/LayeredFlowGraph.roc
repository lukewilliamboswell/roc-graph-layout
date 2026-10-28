## The working graph of the flowchart layout: nodes with ports, edges between
## ports, and one graph per level of nesting (the drawing and each subgraph
## that has members). Every phase of the layout reads and rewrites this
## graph.
##
## Everything here is in the layout's internal reading, where layers run
## left to right: a node's `x` and `width` are along the flow, `y` and
## `height` across it. Outgoing edges leave a node's east side and incoming
## edges enter its west side. The caller turns the result to the diagram's
## direction at the end.
##
## Nodes, ports and edges are kept in flat lists and refer to each other by
## index. `nil` stands for "no node", "no port" or "no edge".
LayeredFlowGraph :: {}.{

	nil : U64
	nil = 18446744073709551615

	Side : [Undefined, North, East, South, West]

	Kind : [Normal, LongEdge, ExternalPort, Label]

	LayerConstraint : [Free, First, FirstSeparate, Last, LastSeparate]

	InLayer : [Middle, Top, Bottom]

	PortConstraints : [FreePorts, FixedSide, FixedOrder, FixedPos]

	## Where a node came from: a diagram node, a subgraph (by index into the
	## diagram's groups), the edge a dummy stands in for, or the port a
	## hierarchical port dummy stands in for.
	Origin : [DiagramNode(U64), Group(U64), EdgeDummy(U64), PortDummy(U64), Synthetic]

	Margins : { top : F64, right : F64, bottom : F64, left : F64 }

	Node : {
		graph : U64,
		kind : Kind,
		origin : Origin,
		nested : U64,

		## For a subgraph laid out on its own: its graph, which the node's
		## layout treats as a box of fixed size.
		inner : U64,
		x : F64,
		y : F64,
		width : F64,
		height : F64,
		ports : List(U64),
		layer : U64,
		layer_constraint : LayerConstraint,
		in_layer : InLayer,
		port_constraints : PortConstraints,
		model_order : [None, Some(I64)],

		## For a hierarchical port dummy: which side of the subgraph its port
		## is on, and how far outside the subgraph's border the port sits.
		ext_side : Side,
		border_offset : F64,
		margin : Margins,

		## For a dummy standing in for (part of) an edge: the ports the whole
		## edge runs between, and whether it carries a label dummy.
		long_edge_source : U64,
		long_edge_target : U64,
		has_label_dummies : Bool,

		## For a label dummy: the labels it carries, as edge label sizes.
		labels : List({ width : F64, height : F64, edge : U64 }),

		## Model order of the targets of this node's outgoing ports, cached as
		## the model-order port comparison computes it.
		label_side_up : Bool,
		id : U64,
	}

	Port : {
		node : U64,
		side : Side,
		x : F64,
		y : F64,
		width : F64,
		height : F64,
		anchor_x : F64,
		anchor_y : F64,
		incoming : List(U64),
		outgoing : List(U64),

		## For a port of a subgraph's box: the hierarchical port dummy inside
		## the subgraph that stands in for it.
		dummy : U64,
		inside_connections : Bool,
		border_offset : F64,
		model_order : [None, Some(I64)],
		long_edge_target_node : U64,
		id : U64,
	}

	Edge : {
		source : U64,
		target : U64,
		reversed : Bool,

		## The diagram edge this edge (or segment of it) belongs to.
		origin : U64,

		## Centre labels still on this edge, before label dummies take them.
		labels : List({ width : F64, height : F64, edge : U64 }),
		bends : List({ x : F64, y : F64 }),
		model_order : [None, Some(I64)],
		thickness : F64,

		## The port on the other side of a node hidden for layering.
		original_opposite : U64,

		## For a segment of an edge crossing subgraph borders: the graph the
		## segment belongs to.
		segment_graph : U64,
		label_x : F64,
		label_y : F64,
	}

	Spacing : {
		node_node : F64,
		node_node_between_layers : F64,
		edge_node : F64,
		edge_node_between_layers : F64,
		edge_edge : F64,
		edge_edge_between_layers : F64,
		edge_label : F64,
		label_label : F64,
		port_port : F64,
		node_self_loop : F64,
		ports_surrounding : F64,
	}

	Graph : {
		## The subgraph node this graph is the inside of, or `nil` for the
		## drawing itself.
		parent : U64,
		nodes : List(U64),
		layers : List(List(U64)),
		spacing : Spacing,
		padding : Margins,
		width : F64,
		height : F64,
		offset_x : F64,
		offset_y : F64,
		external_ports : Bool,
		cyclic : Bool,

		## Hidden nodes taken out for layering (first and last separate layers).
		hidden : List(U64),

		## Minimum size of the subgraph's box, along and across the flow.
		min_width : F64,
		min_height : F64,

		## The subgraph's title, along and across the flow, or zero.
		title_width : F64,
		title_height : F64,
		model_order_nodes : Bool,

		## The way the graph's layout reads, and whether it is laid out on its
		## own (a subgraph with its own direction) rather than with its parent.
		direction : Direction,
		separate : Bool,
	}

	Direction : [Down, Up, Right, Left]

	## A self-loop, laid out around its node rather than through layers: its
	## edge, its source and target ports, the sides it runs along and the
	## lane it takes on each, and its label.
	Loop : {
		node : U64,
		edge : U64,
		ports : List(U64),
		hidden : Bool,
		label : [None, Some({ width : F64, height : F64 })],
		leftmost : U64,
		rightmost : U64,
		occupied : List(Side),

		## Lane per side: north, east, south, west.
		slots : List(I64),
		label_side : Side,
		label_alignment : [Center, AlignLeft, AlignRight, Top],
		label_reference : U64,
		label_x : F64,
		label_y : F64,
	}

	Model : { graphs : List(Graph), nodes : List(Node), ports : List(Port), edges : List(Edge), loops : List(Loop) }

	no_box : Margins
	no_box = { top: 0, right: 0, bottom: 0, left: 0 }

	blank_node : Node
	blank_node = {
		graph: 0,
		kind: Normal,
		origin: Synthetic,
		nested: LayeredFlowGraph.nil,
		inner: LayeredFlowGraph.nil,
		x: 0,
		y: 0,
		width: 0,
		height: 0,
		ports: [],
		layer: LayeredFlowGraph.nil,
		layer_constraint: Free,
		in_layer: Middle,
		port_constraints: FreePorts,
		model_order: None,
		ext_side: Undefined,
		border_offset: 0,
		margin: LayeredFlowGraph.no_box,
		long_edge_source: LayeredFlowGraph.nil,
		long_edge_target: LayeredFlowGraph.nil,
		has_label_dummies: False,
		labels: [],
		label_side_up: False,
		id: 0,
	}

	blank_port : Port
	blank_port = {
		node: LayeredFlowGraph.nil,
		side: Undefined,
		x: 0,
		y: 0,
		width: 0,
		height: 0,
		anchor_x: 0,
		anchor_y: 0,
		incoming: [],
		outgoing: [],
		dummy: LayeredFlowGraph.nil,
		inside_connections: False,
		border_offset: 0,
		model_order: None,
		long_edge_target_node: LayeredFlowGraph.nil,
		id: 0,
	}

	blank_edge : Edge
	blank_edge = {
		source: LayeredFlowGraph.nil,
		target: LayeredFlowGraph.nil,
		reversed: False,
		origin: LayeredFlowGraph.nil,
		labels: [],
		bends: [],
		model_order: None,
		thickness: 1,
		original_opposite: LayeredFlowGraph.nil,
		segment_graph: LayeredFlowGraph.nil,
		label_x: 0,
		label_y: 0,
	}

	node : Model, U64 -> Node
	node = |m, n| m.nodes.get(n) ?? LayeredFlowGraph.blank_node

	port : Model, U64 -> Port
	port = |m, p| m.ports.get(p) ?? LayeredFlowGraph.blank_port

	edge : Model, U64 -> Edge
	edge = |m, e| m.edges.get(e) ?? LayeredFlowGraph.blank_edge

	graph : Model, U64 -> Graph
	graph = |m, g| m.graphs.get(g) ?? LayeredFlowGraph.blank_graph

	blank_spacing : Spacing
	blank_spacing = {
		node_node: 20,
		node_node_between_layers: 20,
		edge_node: 10,
		edge_node_between_layers: 10,
		edge_edge: 10,
		edge_edge_between_layers: 10,
		edge_label: 2,
		label_label: 0,
		port_port: 10,
		node_self_loop: 10,
		ports_surrounding: 0,
	}

	blank_graph : Graph
	blank_graph = {
		parent: LayeredFlowGraph.nil,
		nodes: [],
		layers: [],
		spacing: LayeredFlowGraph.blank_spacing,
		padding: LayeredFlowGraph.no_box,
		width: 0,
		height: 0,
		offset_x: 0,
		offset_y: 0,
		external_ports: False,
		cyclic: False,
		hidden: [],
		min_width: 0,
		min_height: 0,
		title_width: 0,
		title_height: 0,
		model_order_nodes: False,
		direction: Right,
		separate: False,
	}

	set_node : Model, U64, Node -> Model
	set_node = |m, n, value| if (n < m.nodes.len()) { ..m, nodes: m.nodes.set(n, value) ?? [] } else m

	set_port : Model, U64, Port -> Model
	set_port = |m, p, value| if (p < m.ports.len()) { ..m, ports: m.ports.set(p, value) ?? [] } else m

	set_edge : Model, U64, Edge -> Model
	set_edge = |m, e, value| if (e < m.edges.len()) { ..m, edges: m.edges.set(e, value) ?? [] } else m

	set_graph : Model, U64, Graph -> Model
	set_graph = |m, g, value| if (g < m.graphs.len()) { ..m, graphs: m.graphs.set(g, value) ?? [] } else m

	## Add a node to a graph's list of unlayered nodes.
	add_node : Model, Node -> (Model, U64)
	add_node = |m, value| {
		n = m.nodes.len()
		g = LayeredFlowGraph.graph(m, value.graph)
		# Clear the graph's list in the model first, so `g` holds the only
		# reference and the append below need not copy it.
		cleared = LayeredFlowGraph.set_graph(m, value.graph, { ..g, nodes: [] })
		with_node = { ..cleared, nodes: cleared.nodes.append(value) }
		(LayeredFlowGraph.set_graph(with_node, value.graph, { ..g, nodes: g.nodes.append(n) }), n)
	}

	## Add a node that is not (yet) in any of its graph's lists.
	add_loose_node : Model, Node -> (Model, U64)
	add_loose_node = |m, value| {
		# The index is read before the append so the list is not kept alive
		# past it, which would make the append copy it.
		n = m.nodes.len()
		({ ..m, nodes: m.nodes.append(value) }, n)
	}

	## Add a port at the end of a node's ports.
	add_port : Model, U64, Side -> (Model, U64)
	add_port = |m, n, side| {
		p = m.ports.len()
		owner = LayeredFlowGraph.node(m, n)
		cleared = LayeredFlowGraph.set_node(m, n, { ..owner, ports: [] })
		with_port = { ..cleared, ports: cleared.ports.append({ ..LayeredFlowGraph.blank_port, node: n, side }) }
		(LayeredFlowGraph.set_node(with_port, n, { ..owner, ports: owner.ports.append(p) }), p)
	}

	## Add an edge from one port to another.
	add_edge : Model, Edge -> (Model, U64)
	add_edge = |m, value| {
		e = m.edges.len()
		with_edge = { ..m, edges: m.edges.append({ ..value, source: LayeredFlowGraph.nil, target: LayeredFlowGraph.nil }) }
		(LayeredFlowGraph.set_target(LayeredFlowGraph.set_source(with_edge, e, value.source), e, value.target), e)
	}

	without : List(U64), U64 -> List(U64)
	without = |list, x|
		match list.find_first_index(|y| y == x) {
			Ok(i) => list.take_first(i).concat(list.drop_first(i + 1))
			Err(_) => list
		}

	## Move an edge's start to another port (or to `nil`), as `setSource`
	## does: it leaves the old port's outgoing list and joins the end of the
	## new one's.
	set_source : Model, U64, U64 -> Model
	set_source = |m, e, p| {
		value = LayeredFlowGraph.edge(m, e)
		detached = if value.source == LayeredFlowGraph.nil {
			m
		} else {
			old = LayeredFlowGraph.port(m, value.source)
			LayeredFlowGraph.set_port(m, value.source, { ..old, outgoing: LayeredFlowGraph.without(old.outgoing, e) })
		}
		attached = if p == LayeredFlowGraph.nil {
			detached
		} else {
			new = LayeredFlowGraph.port(detached, p)
			cleared = LayeredFlowGraph.set_port(detached, p, { ..new, outgoing: [] })
			LayeredFlowGraph.set_port(cleared, p, { ..new, outgoing: new.outgoing.append(e) })
		}
		LayeredFlowGraph.set_edge(attached, e, { ..LayeredFlowGraph.edge(attached, e), source: p })
	}

	set_target : Model, U64, U64 -> Model
	set_target = |m, e, p| {
		value = LayeredFlowGraph.edge(m, e)
		detached = if value.target == LayeredFlowGraph.nil {
			m
		} else {
			old = LayeredFlowGraph.port(m, value.target)
			LayeredFlowGraph.set_port(m, value.target, { ..old, incoming: LayeredFlowGraph.without(old.incoming, e) })
		}
		attached = if p == LayeredFlowGraph.nil {
			detached
		} else {
			new = LayeredFlowGraph.port(detached, p)
			cleared = LayeredFlowGraph.set_port(detached, p, { ..new, incoming: [] })
			LayeredFlowGraph.set_port(cleared, p, { ..new, incoming: new.incoming.append(e) })
		}
		LayeredFlowGraph.set_edge(attached, e, { ..LayeredFlowGraph.edge(attached, e), target: p })
	}

	## Turn an edge around, as `LEdge.reverse` does: its source becomes its
	## target and the other way round, and it is marked reversed.
	reverse : Model, U64 -> Model
	reverse = |m, e| {
		value = LayeredFlowGraph.edge(m, e)
		old_source = value.source
		old_target = value.target
		cleared = LayeredFlowGraph.set_target(LayeredFlowGraph.set_source(m, e, LayeredFlowGraph.nil), e, LayeredFlowGraph.nil)
		moved = LayeredFlowGraph.set_target(LayeredFlowGraph.set_source(cleared, e, old_target), e, old_source)
		after = LayeredFlowGraph.edge(moved, e)
		LayeredFlowGraph.set_edge(moved, e, { ..after, reversed: !after.reversed, bends: after.bends.rev() })
	}

	## The node at the other end of an edge, or the edge's source or target node.
	source_node : Model, U64 -> U64
	source_node = |m, e| LayeredFlowGraph.port(m, LayeredFlowGraph.edge(m, e).source).node

	target_node : Model, U64 -> U64
	target_node = |m, e| LayeredFlowGraph.port(m, LayeredFlowGraph.edge(m, e).target).node

	## A node's outgoing edges, port by port, as `getOutgoingEdges` iterates them.
	outgoing : Model, U64 -> List(U64)
	outgoing = |m, n| LayeredFlowGraph.node(m, n).ports.fold([], |acc, p| acc.concat(LayeredFlowGraph.port(m, p).outgoing))

	incoming : Model, U64 -> List(U64)
	incoming = |m, n| LayeredFlowGraph.node(m, n).ports.fold([], |acc, p| acc.concat(LayeredFlowGraph.port(m, p).incoming))

	## A node's edges, port by port, incoming before outgoing at each port.
	connected : Model, U64 -> List(U64)
	connected = |m, n|
		LayeredFlowGraph.node(m, n).ports.fold(
			[],
			|acc, p| {
				value = LayeredFlowGraph.port(m, p)
				acc.concat(value.incoming).concat(value.outgoing)
			},
		)

	is_self_loop : Model, U64 -> Bool
	is_self_loop = |m, e| {
		value = LayeredFlowGraph.edge(m, e)
		value.source != LayeredFlowGraph.nil and value.target != LayeredFlowGraph.nil and LayeredFlowGraph.port(m, value.source).node == LayeredFlowGraph.port(m, value.target).node
	}

	## A node's ports on one side, in port order.
	ports_on : Model, U64, Side -> List(U64)
	ports_on = |m, n, side| LayeredFlowGraph.node(m, n).ports.keep_if(|p| LayeredFlowGraph.port(m, p).side == side)

	floor : F64 -> F64
	floor = |value| value.div_floor_by(1.0)

	## A port's net flow as the engine counts it: incoming less outgoing.
	net_flow : Port -> I64
	net_flow = |p| p.incoming.len().to_i64_wrap() - p.outgoing.len().to_i64_wrap()

	degree : Port -> U64
	degree = |p| p.incoming.len() + p.outgoing.len()

	side_index : Side -> U64
	side_index = |side|
		match side {
			Undefined => 0
			North => 1
			East => 2
			South => 3
			West => 4
		}

	opposed : Side -> Side
	opposed = |side|
		match side {
			North => South
			South => North
			East => West
			West => East
			Undefined => Undefined
		}

	## Whether `child` lies (at any depth) inside the subgraph node `parent`.
	is_descendant : Model, U64, U64 -> Bool
	is_descendant = |m, child, parent| {
		var $current = LayeredFlowGraph.graph(m, LayeredFlowGraph.node(m, child).graph).parent
		var $found = False
		var $steps = 0
		while $current != LayeredFlowGraph.nil and !$found and $steps < m.nodes.len() + 1 {
			if $current == parent {
				$found = True
			} else {
				$current = LayeredFlowGraph.graph(m, LayeredFlowGraph.node(m, $current).graph).parent
			}
			$steps = $steps + 1
		}
		$found
	}

	## Sort with the layered solver's merge sort: insertion sort below
	## seven items, halves merged after checking whether they are already in
	## order. The comparison may carry state, which the sort threads through
	## in the order the engine makes comparisons, so a comparison that
	## remembers earlier answers gives the same order it does there.
	merge_sort : List(a), s, (s, a, a -> (s, I64)) -> (List(a), s)
	merge_sort = |items, state, compare| {
		n = items.len()
		if n < 2 {
			(items, state)
		} else {
			LayeredFlowGraph.merge_sort_range(items, items, 0, n, 0, state, compare)
		}
	}

	## Sort `array[low..high)` using `temp` (offset by `ofs`) as the source
	## of the merge, as the engine's `mergeSort` does. Returns the sorted
	## array; `temp` is a scratch copy.
	merge_sort_range : List(a), List(a), U64, U64, I64, s, (s, a, a -> (s, I64)) -> (List(a), s)
	merge_sort_range = |temp, array, low, high, ofs, state, compare| {
		res = LayeredFlowGraph.merge_sort_go(temp, array, low, high, ofs, state, compare)
		(res.array, res.state)
	}

	merge_sort_go : List(a), List(a), U64, U64, I64, s, (s, a, a -> (s, I64)) -> { array : List(a), temp : List(a), state : s }
	merge_sort_go = |temp, array, low, high, ofs, state, compare| {
		length = high - low
		if length < 7 {
			var $a = array
			var $s = state
			var $i = low + 1
			while $i < high {
				var $j = $i
				var $going = True
				while $going and $j > low {
					x = $a.get($j - 1) ?? (crash "merge sort index")
					y = $a.get($j) ?? (crash "merge sort index")
					(s2, c) = compare($s, x, y)
					$s = s2
					if c > 0 {
						$a = $a.set($j, x) ?? []
						$a = $a.set($j - 1, y) ?? []
						$j = $j - 1
					} else {
						$going = False
					}
				}
				$i = $i + 1
			}
			{ array: $a, temp, state: $s }
		} else {
			temp_low = (low.to_i64_wrap() + ofs).to_u64_wrap()
			temp_high = (high.to_i64_wrap() + ofs).to_u64_wrap()
			temp_mid = temp_low + (temp_high - temp_low).shr_zf_wrap(1)
			first = LayeredFlowGraph.merge_sort_go(array, temp, temp_low, temp_mid, 0 - ofs, state, compare)
			second = LayeredFlowGraph.merge_sort_go(first.temp, first.array, temp_mid, temp_high, 0 - ofs, first.state, compare)
			# `second.array` is the sorted temp; `second.temp` is the array.
			sorted_temp = second.array
			var $out = second.temp
			x = sorted_temp.get(temp_mid - 1) ?? (crash "merge sort index")
			y = sorted_temp.get(temp_mid) ?? (crash "merge sort index")
			(s3, c) = compare(second.state, x, y)
			if c <= 0 {
				var $k = low
				var $t = temp_low
				while $k < high {
					$out = $out.set($k, sorted_temp.get($t) ?? (crash "merge sort index")) ?? []
					$k = $k + 1
					$t = $t + 1
				}
				{ array: $out, temp: sorted_temp, state: s3 }
			} else {
				var $s = s3
				var $src_low = temp_low
				var $top = temp_mid
				var $dest = low
				while $dest < high {
					take_low = if $top >= temp_high {
						True
					} else if $src_low < temp_mid {
						a = sorted_temp.get($src_low) ?? (crash "merge sort index")
						b = sorted_temp.get($top) ?? (crash "merge sort index")
						(s4, c2) = compare($s, a, b)
						$s = s4
						c2 <= 0
					} else {
						False
					}
					if take_low {
						$out = $out.set($dest, sorted_temp.get($src_low) ?? (crash "merge sort index")) ?? []
						$src_low = $src_low + 1
					} else {
						$out = $out.set($dest, sorted_temp.get($top) ?? (crash "merge sort index")) ?? []
						$top = $top + 1
					}
					$dest = $dest + 1
				}
				{ array: $out, temp: sorted_temp, state: $s }
			}
		}
	}

	## Stateless sort with the engine's merge sort.
	sort_by : List(a), (a, a -> I64) -> List(a)
	sort_by = |items, compare| {
		(sorted, _) = LayeredFlowGraph.merge_sort(items, {}, |s, a, b| (s, compare(a, b)))
		sorted
	}
}

expect LayeredFlowGraph.sort_by([5, 3, 9, 1, 7, 2, 8, 6, 4, 0, 11, 10], |a, b| if (a < b) (0 - 1) else if (a > b) 1 else 0) == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

## Sorting is stable.
expect {
	items = [{ k: 2, v: 0 }, { k: 1, v: 1 }, { k: 2, v: 2 }, { k: 1, v: 3 }, { k: 0, v: 4 }, { k: 2, v: 5 }, { k: 1, v: 6 }, { k: 0, v: 7 }, { k: 2, v: 8 }]
	sorted = LayeredFlowGraph.sort_by(items, |a, b| if (a.k < b.k) (0 - 1) else if (a.k > b.k) 1 else 0)
	sorted.map(|x| x.v) == [4, 7, 1, 3, 6, 0, 2, 5, 8]
}
