import FlowLayoutGraph
import FlowLayoutRandom

## The order of nodes within layers, chosen as Mermaid's layout engine
## chooses it: layer sweeps placing each node at the barycenter of its
## neighbours' ports (with a little random jitter to break ties), sweeping
## into subgraphs as it passes them, counting crossings after each sweep and
## keeping the best of several tries. The first two tries start from the
## order the diagram declared; the rest start from a random first layer.
## The random numbers are drawn from the same generator, seeded the same
## way, in the same order, so ties come out as they do in Mermaid.
FlowLayoutOrder :: {}.{

	Model : FlowLayoutGraph.Model

	nil : U64
	nil = FlowLayoutGraph.nil

	Random : FlowLayoutRandom.Random

	Distributor : [NodeRelative, LayerTotal]

	## A saved order: nodes per layer and each node's ports.
	Snapshot : { layers : List(List(U64)), ports : List({ node : U64, ports : List(U64) }) }

	Holder : {
		graph : U64,
		parent : U64,
		bottom_up : Bool,
		children : List(U64),
		external_ports : Bool,
		distributor : Distributor,
		order : List(List(U64)),
		currently_best : [None, Some(Snapshot)],
		best : [None, Some(Snapshot)],
		random : Random,
	}

	State : {
		model : Model,
		holders : List(Holder),

		## Graph index to holder index.
		holder_of : List(U64),
		minimizer_random : Random,
		random_seed : I64,
		changed : List(U64),
		first_try : Bool,
		second_try : Bool,
		model_order : Bool,

		## The graph the run starts from: the drawing, or a subgraph laid out
		## on its own.
		root : U64,

		## Barycenter state per node.
		summed : List(F64),
		degree : List(I64),
		bary : List([None, Some(F64)]),
		visited : List(Bool),

		## Port ranks and barycenters per port (one table per graph in the
		## engine; ports never share graphs, so one table serves).
		port_ranks : List(F64),
		port_bary : List(F64),
		node_pos : List(U64),

		## Positions used by the crossing counter.
		cross_pos : List(I64),

		## A record of each sweep, count and random draw, kept only when
		## tracing, for comparison with the engine.
		tracing : Bool,
		trace : List(Str),
		names : List(Str),
	}

	## Order every graph's layers. Graphs must have been layered.
	minimize : Model, Bool -> Model
	minimize = |m, model_order| FlowLayoutOrder.minimize_traced(m, 0, model_order, False, []).model

	## Like `minimize`, also returning a record of the work when `tracing`.
	## `names` names nodes in the record.
	minimize_traced : Model, U64, Bool, Bool, List(Str) -> { model : Model, trace : List(Str), randoms : List(Random) }
	minimize_traced = |m, root, model_order, tracing, names| {
		root_graph = FlowLayoutGraph.graph(m, root)
		empty = root_graph.layers.all(|l| l.is_empty())
		if empty {
			{ model: m, trace: [], randoms: List.repeat(FlowLayoutRandom.from_seed(1), m.graphs.len()) }
		} else {
			FlowLayoutOrder.run(m, root, model_order, tracing, names)
		}
	}

	note : State, Str -> State
	note = |s, text| if (s.tracing) { ..s, trace: s.trace.append(text) } else s

	run : Model, U64, Bool, Bool, List(Str) -> { model : Model, trace : List(Str), randoms : List(Random) }
	run = |m, root, model_order, tracing, names| {
		port_count = m.ports.len()
		node_count = m.nodes.len()
		root_random = FlowLayoutRandom.from_seed(1)
		(r1, seed) = FlowLayoutRandom.next_long(root_random)
		var $s = {
			model: m,
			holders: [],
			holder_of: List.repeat(FlowLayoutOrder.nil, m.graphs.len()),
			minimizer_random: r1,
			random_seed: seed,
			changed: [],
			first_try: False,
			second_try: False,
			model_order,
			root,
			summed: List.repeat(0, node_count),
			degree: List.repeat(0, node_count),
			bary: List.repeat(None, node_count),
			visited: List.repeat(False, node_count),
			port_ranks: List.repeat(0, port_count),
			port_bary: List.repeat(0, port_count),
			node_pos: List.repeat(0, node_count),
			cross_pos: List.repeat(0, port_count),
			tracing,
			trace: [],
			names,
		}
		# Holders breadth first from the drawing; the drawing's own random
		# generator is the minimizer's.
		var $graphs = [root]
		var $i = 0
		var $sweep_on = []
		while $i < $graphs.len() {
			g = $graphs.get($i) ?? 0
			$i = $i + 1
			order = FlowLayoutGraph.graph($s.model, g).layers
			random0 = if (g == root) $s.minimizer_random else FlowLayoutRandom.from_seed(1)
			(random1, relative) = FlowLayoutRandom.next_bool(random0)
			$s = FlowLayoutOrder.note($s, "rand 1 ${if (relative) "1" else "0"}")
			children = order.fold([], |acc, layer| acc.concat(layer.keep_if(|n| FlowLayoutGraph.node($s.model, n).nested != FlowLayoutOrder.nil).map(|n| FlowLayoutGraph.node($s.model, n).nested)))
			parent = if (g == root) FlowLayoutOrder.nil else FlowLayoutGraph.graph($s.model, g).parent
			holder = {
				graph: g,
				parent,
				bottom_up: g == root or FlowLayoutOrder.bottom_up($s.model, g, order),
				children,
				external_ports: FlowLayoutGraph.graph($s.model, g).external_ports,
				distributor: if (relative) NodeRelative else LayerTotal,
				order,
				currently_best: None,
				best: None,
				random: random1,
			}
			if g == root {
				$s = { ..$s, minimizer_random: random1 }
			}
			$s = { ..$s, holder_of: $s.holder_of.set(g, $s.holders.len()) ?? $s.holder_of, holders: $s.holders.append(holder) }
			$graphs = $graphs.concat(children)
			# Initial node positions are indices within layers.
			for layer in order {
				for k in 0..<layer.len() {
					n = layer.get(k) ?? 0
					$s = { ..$s, node_pos: $s.node_pos.set(n, k) ?? $s.node_pos }
				}
			}
			if holder.bottom_up {
				$sweep_on = [g].concat($sweep_on)
			}
		}
		for g in $sweep_on {
			h = FlowLayoutOrder.holder($s, g)
			if !h.order.is_empty() {
				$s = FlowLayoutOrder.compare_randomized($s, g)
				if h.parent != FlowLayoutOrder.nil {
					$s = FlowLayoutOrder.port_order_on_parent($s, g)
				}
			}
		}
		final = $s
		randoms = List.repeat(0, m.graphs.len()).map_with_index(|_, g| FlowLayoutOrder.graph_random(final, g))
		{ model: FlowLayoutOrder.transfer(final), trace: final.trace, randoms }
	}

	holder : State, U64 -> Holder
	holder = |s, g|
		s.holders.get(s.holder_of.get(g) ?? 0) ?? {
			graph: g,
			parent: FlowLayoutOrder.nil,
			bottom_up: True,
			children: [],
			external_ports: False,
			distributor: LayerTotal,
			order: [],
			currently_best: None,
			best: None,
			random: FlowLayoutRandom.from_seed(1),
		}

	set_holder : State, U64, Holder -> State
	set_holder = |s, g, h| {
		k = s.holder_of.get(g) ?? FlowLayoutOrder.nil
		if (k < s.holders.len()) { ..s, holders: s.holders.set(k, h) ?? [] } else s
	}

	## Whether a subgraph is ordered on its own before its parent (the engine's
	## "bottom up" decision) rather than swept into from the parent.
	bottom_up : Model, U64, List(List(U64)) -> Bool
	bottom_up = |m, g, order| {
		parent = FlowLayoutGraph.graph(m, g).parent
		if parent == FlowLayoutOrder.nil {
			True
		} else {
			pnode = FlowLayoutGraph.node(m, parent)
			east = pnode.ports.count_if(|p| FlowLayoutGraph.port(m, p).side == East)
			west = pnode.ports.count_if(|p| FlowLayoutGraph.port(m, p).side == West)
			if pnode.port_constraints == FixedOrder or pnode.port_constraints == FixedPos or (east < 2 and west < 2) {
				True
			} else {
				# Paths from nodes the engine would place at random versus paths from
				# the subgraph's border.
				var $info = []
				get = |table, n|
					match table.find_first(|x| x.node == n) {
						Ok(x) => x
						Err(_) => { node: n, edges: 0, hier: 0, random: 0 }
					}
				put = |table, x| table.drop_if(|y| y.node == x.node).append(x)
				var $to_random = 0.I64
				var $to_hier = 0
				has_connected = |n, side| FlowLayoutGraph.ports_on(m, n, side).any(|p| FlowLayoutGraph.degree(FlowLayoutGraph.port(m, p)) > 0)
				for layer in order {
					for n in layer {
						node = FlowLayoutGraph.node(m, n)
						var $cur = get($info, n)
						if node.kind == ExternalPort {
							$cur = { ..$cur, hier: 1 }
							origin_side = match node.origin {
								PortDummy(p) => FlowLayoutGraph.port(m, p).side
								_ => Undefined
							}
							if origin_side == East {
								$to_hier = $to_hier + $cur.edges
							}
						} else if !has_connected(n, West) {
							$cur = { ..$cur, random: 1 }
						} else if !has_connected(n, East) {
							$to_random = $to_random + $cur.edges
						}
						$info = put($info, $cur)
						for e in FlowLayoutGraph.outgoing(m, n) {
							$to_random = $to_random + $cur.random
							$to_hier = $to_hier + $cur.hier
							t = FlowLayoutGraph.target_node(m, e)
							ti = get($info, t)
							$info = put($info, { ..ti, hier: ti.hier + $cur.hier, random: ti.random + $cur.random, edges: ti.edges + $cur.edges + 1 })
						}
					}
				}
				all = $to_random + $to_hier
				if all == 0 {
					True
				} else {
					normalized = ($to_random.to_f64() - $to_hier.to_f64()) / all.to_f64()
					normalized >= 0.1.F64
				}
			}
		}
	}

	snapshot : State, U64 -> Snapshot
	snapshot = |s, g| {
		h = FlowLayoutOrder.holder(s, g)
		{
			layers: h.order,
			ports: h.order.fold([], |acc, layer| acc.concat(layer.map(|n| { node: n, ports: FlowLayoutGraph.node(s.model, n).ports }))),
		}
	}

	set_currently_best : State -> State
	set_currently_best = |s0| {
		var $s = s0
		for g in s0.changed {
			snap = FlowLayoutOrder.snapshot($s, g)
			$s = FlowLayoutOrder.set_holder($s, g, { ..FlowLayoutOrder.holder($s, g), currently_best: Some(snap) })
		}
		$s
	}

	save_best : State -> State
	save_best = |s0| {
		var $s = s0
		for g in s0.changed {
			h = FlowLayoutOrder.holder($s, g)
			$s = FlowLayoutOrder.set_holder($s, g, { ..h, best: h.currently_best })
		}
		$s
	}

	mark_changed : State, U64 -> State
	mark_changed = |s, g| if (s.changed.contains(g)) s else { ..s, changed: s.changed.append(g) }

	compare_randomized : State, U64 -> State
	compare_randomized = |s0, g| {
		var $s = { ..s0, minimizer_random: FlowLayoutRandom.from_seed(s0.random_seed), changed: [] }
		# Only the drawing considers the diagram's order.
		$s = if (g == $s.root and $s.model_order) { ..$s, first_try: True } else $s
		var $best = 2147483647
		var $i = 0
		var $done = False
		while $i < 7 and !$done {
			(s1, crossings) = FlowLayoutOrder.minimize_with_counter($s, g)
			$s = s1
			if crossings < $best {
				$best = crossings
				$s = FlowLayoutOrder.save_best($s)
				if $best == 0 {
					$done = True
				}
			}
			$i = $i + 1
		}
		$s
	}

	minimize_with_counter : State, U64 -> (State, I64)
	minimize_with_counter = |s0, g| {
		(r1, forward0) = FlowLayoutRandom.next_bool(s0.minimizer_random)
		var $s = FlowLayoutOrder.note({ ..s0, minimizer_random: r1 }, "rand 1 ${if (forward0) "1" else "0"}")
		(s_init, initial) = FlowLayoutOrder.count_current($s, g)
		$s = s_init
		if initial == 0 and $s.first_try {
			(FlowLayoutOrder.note($s, "try -> 0"), 0)
		} else {
			var $forward = forward0
			# The engine's "first try" and "second try" flags share one key, so
			# only the first try keeps the declared order; the second already
			# starts at random.
			if !$s.first_try or !$s.model_order or g != $s.root {
				$s = FlowLayoutOrder.set_first_layer_order($s, g, $forward)
			} else {
				$forward = True
			}
			$s = FlowLayoutOrder.sweep($s, g, $forward, True)
			$s = { ..$s, first_try: False }
			(s_c, c0) = FlowLayoutOrder.count_current($s, g)
			$s = s_c
			var $crossings = c0
			var $old = $crossings
			var $result = None
			var $guard = 0
			while $result == None and $guard < 1000 {
				$s = FlowLayoutOrder.set_currently_best($s)
				if $crossings == 0 {
					$result = Some(0)
				} else {
					$forward = !$forward
					$old = $crossings
					$s = FlowLayoutOrder.sweep($s, g, $forward, False)
					(s_n, cn) = FlowLayoutOrder.count_current($s, g)
					$s = s_n
					$crossings = cn
					if !($old > $crossings) {
						$result = Some($old)
					}
				}
				$guard = $guard + 1
			}
			value = match $result {
				Some(v) => v
				None => $old
			}
			(FlowLayoutOrder.note($s, "try -> ${value.to_str()}"), value)
		}
	}

	## Crossings in a graph and the subgraphs swept into from it.
	count_current : State, U64 -> (State, I64)
	count_current = |s0, g| {
		h = FlowLayoutOrder.holder(s0, g)
		var $s = s0
		var $total = FlowLayoutOrder.count_all(s0, h.order)
		for c in h.children {
			if !FlowLayoutOrder.holder($s, c).bottom_up {
				(s1, v) = FlowLayoutOrder.count_current($s, c)
				$s = s1
				$total = $total + v
			}
		}
		(FlowLayoutOrder.note($s, "count ${$total.to_str()}"), $total)
	}

	describe_order : State, U64, Bool, Bool -> State
	describe_order = |s, g, forward, first_sweep|
		if !s.tracing {
			s
		} else {
			h = FlowLayoutOrder.holder(s, g)
			graph_name = if (h.parent == FlowLayoutOrder.nil) "root" else s.names.get(h.parent) ?? "?"
			head = "sweep ${graph_name} forward=${if (forward) "true" else "false"} first=${if (first_sweep) "true" else "false"}"
			lines = h.order.map_with_index(|layer, i| "   L${i.to_str()}: ${Str.join_with(layer.map(|n| s.names.get(n) ?? "?"), " ")}")
			{ ..s, trace: s.trace.append(head).concat(lines) }
		}

	# ---------------------------------------------------------------- sweeps

	sweep : State, U64, Bool, Bool -> State
	sweep = |s0, g, forward, first_sweep| {
		var $s = s0
		len = FlowLayoutOrder.holder($s, g).order.len()
		first = if (forward) 0 else len - 1
		$s = FlowLayoutOrder.distribute_while_sweeping($s, g, first, forward)
		$s = FlowLayoutOrder.sweep_in_hierarchical($s, g, first, forward, first_sweep)
		var $i = if (forward) 1 else len.to_i64_wrap() - 2
		while (if (forward) $i < len.to_i64_wrap() else $i >= 0) {
			li = $i.to_u64_wrap()
			randomize_first = first_sweep and !(g == $s.root and $s.model_order and $s.first_try)
			$s = FlowLayoutOrder.minimize_layer($s, g, li, forward, randomize_first)
			$s = FlowLayoutOrder.distribute_while_sweeping($s, g, li, forward)
			$s = FlowLayoutOrder.sweep_in_hierarchical($s, g, li, forward, first_sweep)
			$i = if (forward) $i + 1 else $i - 1
		}
		FlowLayoutOrder.describe_order(FlowLayoutOrder.mark_changed($s, g), g, forward, first_sweep)
	}

	sweep_in_hierarchical : State, U64, U64, Bool, Bool -> State
	sweep_in_hierarchical = |s0, g, l, forward, first_sweep| {
		var $s = s0
		layer = (FlowLayoutOrder.holder($s, g).order.get(l)) ?? []
		for n in layer {
			nested = FlowLayoutGraph.node($s.model, n).nested
			if nested != FlowLayoutOrder.nil and !FlowLayoutOrder.holder($s, nested).bottom_up {
				$s = FlowLayoutOrder.sweep_in_node($s, n, nested, forward, first_sweep)
			}
		}
		$s
	}

	sweep_in_node : State, U64, U64, Bool, Bool -> State
	sweep_in_node = |s0, n, nested, forward, first_sweep| {
		var $s = s0
		h = FlowLayoutOrder.holder($s, nested)
		len = h.order.len()
		if len == 0 {
			$s
		} else {
			start = if (forward) 0 else len - 1
			start_layer = h.order.get(start) ?? []
			first_node = start_layer.first() ?? FlowLayoutOrder.nil
			if FlowLayoutGraph.node($s.model, first_node).kind == ExternalPort {
				side = if (forward) West else East
				sorted = FlowLayoutOrder.dummies_by_port_positions($s.model, n, side)
				$s = FlowLayoutOrder.set_holder($s, nested, { ..h, order: h.order.set(start, sorted) ?? h.order })
			} else {
				$s = FlowLayoutOrder.set_first_layer_order($s, nested, forward)
			}
			$s = FlowLayoutOrder.sweep($s, nested, forward, first_sweep)
			FlowLayoutOrder.ports_by_dummy_positions($s, FlowLayoutOrder.holder($s, nested).order, n, forward)
		}
	}

	## The hierarchical port dummies inside a subgraph, in the order of the
	## subgraph's ports on one side (east and north top down, west and south
	## bottom up).
	dummies_by_port_positions : Model, U64, FlowLayoutGraph.Side -> List(U64)
	dummies_by_port_positions = |m, n, side| {
		on_side = FlowLayoutGraph.ports_on(m, n, side)
		ordered = match side {
			East | North => on_side
			_ => on_side.rev()
		}
		ordered.keep_if(|p| FlowLayoutGraph.port(m, p).inside_connections).map(|p| FlowLayoutGraph.port(m, p).dummy)
	}

	## Order a subgraph's ports on one side like the dummies standing in for
	## them in the subgraph's last (or first) layer.
	ports_by_dummy_positions : State, List(List(U64)), U64, Bool -> State
	ports_by_dummy_positions = |s, order, parent, right_most| {
		end = if (right_most) order.len() - 1 else 0
		last_layer = order.get(end) ?? []
		start = if (right_most) 0 else last_layer.len().to_i64_wrap() - 1
		first = last_layer.get(start.to_u64_wrap()) ?? FlowLayoutOrder.nil
		if FlowLayoutGraph.node(s.model, first).kind != ExternalPort {
			s
		} else {
			pnode = FlowLayoutGraph.node(s.model, parent)
			side = if (right_most) East else West
			var $j = start
			var $ports = pnode.ports
			for i in 0..<pnode.ports.len() {
				p = pnode.ports.get(i) ?? 0
				port = FlowLayoutGraph.port(s.model, p)
				if port.side == side and port.inside_connections {
					d = last_layer.get($j.to_u64_wrap()) ?? FlowLayoutOrder.nil
					origin = match FlowLayoutGraph.node(s.model, d).origin {
						PortDummy(q) => q
						_ => p
					}
					$ports = $ports.set(i, origin) ?? $ports
					$j = if (right_most) $j + 1 else $j - 1
				}
			}
			{ ..s, model: FlowLayoutGraph.set_node(s.model, parent, { ..pnode, ports: $ports }) }
		}
	}

	## After a subgraph is ordered on its own, its parent's box takes the port
	## order its dummies ended up in, on both sides, and keeps it.
	port_order_on_parent : State, U64 -> State
	port_order_on_parent = |s0, g| {
		h = FlowLayoutOrder.holder(s0, g)
		if !h.external_ports {
			s0
		} else {
			match h.best {
				Some(best) => {
					s1 = FlowLayoutOrder.ports_by_dummy_positions(s0, best.layers, h.parent, True)
					s2 = FlowLayoutOrder.ports_by_dummy_positions(s1, best.layers, h.parent, False)
					pnode = FlowLayoutGraph.node(s2.model, h.parent)
					{ ..s2, model: FlowLayoutGraph.set_node(s2.model, h.parent, { ..pnode, port_constraints: FixedOrder }) }
				}
				None => s0
			}
		}
	}

	# ---------------------------------------------------------------- barycenters

	set_first_layer_order : State, U64, Bool -> State
	set_first_layer_order = |s0, g, forward| {
		h = FlowLayoutOrder.holder(s0, g)
		len = h.order.len()
		start = if (forward) 0 else (if (len == 0) 0 else len - 1)
		nodes = h.order.get(start) ?? []
		# Random barycenters, drawn with the graph's own generator.
		var $s = s0
		var $random = FlowLayoutOrder.graph_random(s0, g)
		for n in nodes {
			(r, d) = FlowLayoutRandom.next_double($random)
			$random = r
			$s = FlowLayoutOrder.note($s, "rand 26")
			$s = { ..$s, bary: $s.bary.set(n, Some(d)) ?? $s.bary, summed: $s.summed.set(n, d) ?? $s.summed, degree: $s.degree.set(n, 1) ?? $s.degree }
		}
		$s = FlowLayoutOrder.set_graph_random($s, g, $random)
		sorted = FlowLayoutOrder.sort_by_bary($s, nodes)
		h2 = FlowLayoutOrder.holder($s, g)
		FlowLayoutOrder.set_holder($s, g, { ..h2, order: h2.order.set(start, sorted) ?? h2.order })
	}

	set_graph_random : State, U64, Random -> State
	set_graph_random = |s, g, random| {
		s1 = FlowLayoutOrder.set_holder(s, g, { ..FlowLayoutOrder.holder(s, g), random })
		# The drawing's generator is the minimizer's.
		if (g == s1.root) { ..s1, minimizer_random: random } else s1
	}

	graph_random : State, U64 -> Random
	graph_random = |s, g| if (g == s.root) s.minimizer_random else FlowLayoutOrder.holder(s, g).random

	sort_by_bary : State, List(U64) -> List(U64)
	sort_by_bary = |s, nodes|
		FlowLayoutGraph.sort_by(
			nodes,
			|a, b|
				match (s.bary.get(a) ?? None, s.bary.get(b) ?? None) {
					(Some(x), Some(y)) => if (x < y) -1 else if (x > y) 1 else 0
					(Some(_), None) => -1
					(None, Some(_)) => 1
					(None, None) => 0
				},
		)

	## One layer of a sweep: barycenters from the fixed neighbouring layer.
	minimize_layer : State, U64, U64, Bool, Bool -> State
	minimize_layer = |s0, g, l, forward, first_sweep| {
		h = FlowLayoutOrder.holder(s0, g)
		fixed_index = if (forward) l - 1 else l + 1
		s1 = FlowLayoutOrder.calculate_port_ranks(s0, h.distributor, h.order.get(fixed_index) ?? [], forward)
		nodes = h.order.get(l) ?? []
		first_node = nodes.first() ?? FlowLayoutOrder.nil
		pre_ordered = !first_sweep or FlowLayoutGraph.node(s1.model, first_node).kind == ExternalPort
		s2 = FlowLayoutOrder.calculate_barycenters(s1, g, nodes, forward)
		s3 = FlowLayoutOrder.fill_unknown(s2, g, nodes, pre_ordered)
		sorted = if (nodes.len() > 1) FlowLayoutOrder.sort_by_bary(s3, nodes) else nodes
		h3 = FlowLayoutOrder.holder(s3, g)
		FlowLayoutOrder.set_holder(s3, g, { ..h3, order: h3.order.set(l, sorted) ?? h3.order })
	}

	calculate_barycenters : State, U64, List(U64), Bool -> State
	calculate_barycenters = |s0, g, nodes, forward| {
		var $s = s0
		for n in nodes {
			$s = { ..$s, visited: $s.visited.set(n, False) ?? $s.visited }
		}
		for n in nodes {
			$s = FlowLayoutOrder.calculate_barycenter($s, g, n, forward)
		}
		$s
	}

	## The fixed ports a free port is connected to: sources of its incoming
	## edges sweeping forward, targets of its outgoing edges sweeping back.
	fixed_ports : Model, U64, Bool -> List(U64)
	fixed_ports = |m, p, forward| {
		port = FlowLayoutGraph.port(m, p)
		if forward {
			port.incoming.map(|e| FlowLayoutGraph.edge(m, e).source)
		} else {
			port.outgoing.map(|e| FlowLayoutGraph.edge(m, e).target)
		}
	}

	calculate_barycenter : State, U64, U64, Bool -> State
	calculate_barycenter = |s0, g, n, forward|
		if s0.visited.get(n) ?? True {
			s0
		} else {
			var $s = { ..s0, visited: s0.visited.set(n, True) ?? s0.visited }
			var $degree = 0
			var $summed = 0.0
			layer = FlowLayoutGraph.node($s.model, n).layer
			for p in FlowLayoutGraph.node($s.model, n).ports {
				for fp in FlowLayoutOrder.fixed_ports($s.model, p, forward) {
					fixed_node = FlowLayoutGraph.port($s.model, fp).node
					if FlowLayoutGraph.node($s.model, fixed_node).layer == layer {
						if fixed_node != n {
							$s = FlowLayoutOrder.calculate_barycenter($s, g, fixed_node, forward)
							$degree = $degree + ($s.degree.get(fixed_node) ?? 0)
							$summed = $summed + ($s.summed.get(fixed_node) ?? 0)
						}
					} else {
						$summed = $summed + ($s.port_ranks.get(fp) ?? 0)
						$degree = $degree + 1
					}
				}
			}
			if $degree > 0 {
				(r, f) = FlowLayoutRandom.next_float(FlowLayoutOrder.graph_random($s, g))
				$s = FlowLayoutOrder.set_graph_random($s, g, r)
				$summed = $summed + (f * 0.07000000029802322 - 0.03500000014901161)
				$s = { ..$s, bary: $s.bary.set(n, Some($summed / $degree.to_f64())) ?? $s.bary }
			} else {
				$s = { ..$s, bary: $s.bary.set(n, None) ?? $s.bary }
			}
			{ ..$s, summed: $s.summed.set(n, $summed) ?? $s.summed, degree: $s.degree.set(n, $degree) ?? $s.degree }
		}

	fill_unknown : State, U64, List(U64), Bool -> State
	fill_unknown = |s0, g, nodes, pre_ordered| {
		var $s = s0
		if pre_ordered {
			var $last = -1.0
			for k in 0..<nodes.len() {
				n = nodes.get(k) ?? 0
				value = match $s.bary.get(n) ?? None {
					Some(v) => v
					None => {
						var $next = $last + 1
						var $searching = True
						var $j = k + 1
						while $searching and $j < nodes.len() {
							match $s.bary.get(nodes.get($j) ?? 0) ?? None {
								Some(x) => {
									$next = x
									$searching = False
								}
								None => {}
							}
							$j = $j + 1
						}
						v = ($last + $next) / 2
						$s = { ..$s, bary: $s.bary.set(n, Some(v)) ?? $s.bary, summed: $s.summed.set(n, v) ?? $s.summed, degree: $s.degree.set(n, 1) ?? $s.degree }
						v
					}
				}
				$last = value
			}
			$s
		} else {
			max_bary = nodes.fold(
				0.0,
				|acc, n|
					match $s.bary.get(n) ?? None {
						Some(v) => acc.max(v)
						None => acc
					},
			) + 2
			for n in nodes {
				if ($s.bary.get(n) ?? None) == None {
					(r, f) = FlowLayoutRandom.next_float(FlowLayoutOrder.graph_random($s, g))
					$s = FlowLayoutOrder.set_graph_random($s, g, r)
					v = f * max_bary - 1
					$s = { ..$s, bary: $s.bary.set(n, Some(v)) ?? $s.bary, summed: $s.summed.set(n, v) ?? $s.summed, degree: $s.degree.set(n, 1) ?? $s.degree }
				}
			}
			$s
		}
	}

	# ---------------------------------------------------------------- ports

	## Port ranks of a layer: outgoing ports when sweeping forward, incoming
	## when sweeping back.
	calculate_port_ranks : State, Distributor, List(U64), Bool -> State
	calculate_port_ranks = |s0, distributor, layer, outputs| {
		var $s = s0
		var $consumed = 0.0
		for n in layer {
			ports = FlowLayoutGraph.node($s.model, n).ports
			if outputs {
				outs = ports.keep_if(|p| !FlowLayoutGraph.port($s.model, p).outgoing.is_empty())
				match distributor {
					NodeRelative => {
						incr = 1.0 / (outs.len().to_f64() + 1)
						var $pos = $consumed + incr
						for p in outs {
							$s = { ..$s, port_ranks: $s.port_ranks.set(p, $pos) ?? $s.port_ranks }
							$pos = $pos + incr
						}
						$consumed = $consumed + 1
					}
					LayerTotal => {
						var $pos = 0.0
						for p in outs {
							$pos = $pos + 1
							$s = { ..$s, port_ranks: $s.port_ranks.set(p, $consumed + $pos) ?? $s.port_ranks }
						}
						$consumed = $consumed + $pos
					}
				}
			} else {
				ins = ports.keep_if(|p| !FlowLayoutGraph.port($s.model, p).incoming.is_empty())
				north = ins.count_if(|p| FlowLayoutGraph.port($s.model, p).side == North)
				match distributor {
					NodeRelative => {
						incr = 1.0 / (ins.len().to_f64() + 1)
						var $north_pos = $consumed + north.to_f64() * incr
						var $rest_pos = $consumed + 1 - incr
						for p in ins {
							if FlowLayoutGraph.port($s.model, p).side == North {
								$s = { ..$s, port_ranks: $s.port_ranks.set(p, $north_pos) ?? $s.port_ranks }
								$north_pos = $north_pos - incr
							} else {
								$s = { ..$s, port_ranks: $s.port_ranks.set(p, $rest_pos) ?? $s.port_ranks }
								$rest_pos = $rest_pos - incr
							}
						}
						$consumed = $consumed + 1
					}
					LayerTotal => {
						var $north_pos = $consumed + north.to_f64()
						var $rest_pos = $consumed + ins.len().to_f64()
						for p in ins {
							if FlowLayoutGraph.port($s.model, p).side == North {
								$s = { ..$s, port_ranks: $s.port_ranks.set(p, $north_pos) ?? $s.port_ranks }
								$north_pos = $north_pos - 1
							} else {
								$s = { ..$s, port_ranks: $s.port_ranks.set(p, $rest_pos) ?? $s.port_ranks }
								$rest_pos = $rest_pos - 1
							}
						}
						$consumed = $consumed + ins.len().to_f64()
					}
				}
			}
		}
		$s
	}

	distribute_while_sweeping : State, U64, U64, Bool -> State
	distribute_while_sweeping = |s0, g, l, forward| {
		h = FlowLayoutOrder.holder(s0, g)
		free_layer = h.order.get(l) ?? []
		var $s = s0
		for k in 0..<free_layer.len() {
			n = free_layer.get(k) ?? 0
			$s = { ..$s, node_pos: $s.node_pos.set(n, k) ?? $s.node_pos }
		}
		side = if (forward) West else East
		not_first = if (forward) l != 0 else l + 1 != h.order.len()
		if not_first {
			fixed_layer = h.order.get(if (forward) l - 1 else l + 1) ?? []
			$s = FlowLayoutOrder.calculate_port_ranks($s, h.distributor, fixed_layer, forward)
			for n in free_layer {
				$s = FlowLayoutOrder.distribute_ports($s, n, side)
			}
			$s = FlowLayoutOrder.calculate_port_ranks($s, h.distributor, free_layer, !forward)
			for n in fixed_layer {
				if FlowLayoutGraph.node($s.model, n).nested == FlowLayoutOrder.nil {
					$s = FlowLayoutOrder.distribute_ports($s, n, FlowLayoutGraph.opposed(side))
				}
			}
			$s
		} else {
			for n in free_layer {
				$s = FlowLayoutOrder.distribute_ports($s, n, side)
			}
			$s
		}
	}

	distribute_ports : State, U64, FlowLayoutGraph.Side -> State
	distribute_ports = |s0, n, side| {
		node = FlowLayoutGraph.node(s0.model, n)
		if node.port_constraints == FixedOrder or node.port_constraints == FixedPos {
			s0
		} else {
			s1 = FlowLayoutOrder.port_barycenters(s0, n, FlowLayoutGraph.ports_on(s0.model, n, side))
			s2 = FlowLayoutOrder.port_barycenters(s1, n, FlowLayoutGraph.ports_on(s1.model, n, South))
			s3 = FlowLayoutOrder.port_barycenters(s2, n, FlowLayoutGraph.ports_on(s2.model, n, North))
			FlowLayoutOrder.sort_ports(s3, n)
		}
	}

	port_barycenters : State, U64, List(U64) -> State
	port_barycenters = |s0, n, ports| {
		var $s = s0
		var $min = 0.0
		var $max = 0.0
		var $in_layer = []
		layer = FlowLayoutGraph.node(s0.model, n).layer
		for p in ports {
			port = FlowLayoutGraph.port($s.model, p)
			var $sum = 0.0
			var $is_in_layer = False
			for e in port.outgoing {
				if !$is_in_layer {
					t = FlowLayoutGraph.edge($s.model, e).target
					if FlowLayoutGraph.node($s.model, FlowLayoutGraph.port($s.model, t).node).layer == layer {
						$is_in_layer = True
					} else {
						$sum = $sum + ($s.port_ranks.get(t) ?? 0)
					}
				}
			}
			for e in port.incoming {
				if !$is_in_layer {
					src = FlowLayoutGraph.edge($s.model, e).source
					if FlowLayoutGraph.node($s.model, FlowLayoutGraph.port($s.model, src).node).layer == layer {
						$is_in_layer = True
					} else {
						$sum = $sum - ($s.port_ranks.get(src) ?? 0)
					}
				}
			}
			if $is_in_layer {
				$in_layer = $in_layer.append(p)
			} else {
				deg = FlowLayoutGraph.degree(port)
				if deg > 0 {
					b = $sum / deg.to_f64()
					$s = { ..$s, port_bary: $s.port_bary.set(p, b) ?? $s.port_bary }
					$min = $min.min(b)
					$max = $max.max(b)
				}
			}
		}
		if $in_layer.is_empty() {
			$s
		} else {
			# Ports with edges within the layer go to the end facing their
			# other ends.
			node_index = ($s.node_pos.get(n) ?? 0) + 1
			layer_nodes = FlowLayoutGraph.graph($s.model, FlowLayoutGraph.node($s.model, n).graph).layers.get(layer) ?? []
			layer_size = layer_nodes.len() + 1
			for p in $in_layer {
				port = FlowLayoutGraph.port($s.model, p)
				ends = port.incoming.map(|e| FlowLayoutGraph.edge($s.model, e).source).concat(port.outgoing.map(|e| FlowLayoutGraph.edge($s.model, e).target))
				var $sum = 0
				var $count = 0.U64
				for q in ends {
					qn = FlowLayoutGraph.port($s.model, q).node
					if FlowLayoutGraph.node($s.model, qn).layer == layer {
						$sum = $sum + ($s.node_pos.get(qn) ?? 0) + 1
						$count = $count + 1
					}
				}
				b = if ($count > 0) $sum.to_f64() / $count.to_f64() else 0
				value = match port.side {
					East => if (b < node_index.to_f64()) $min - b else $max + (layer_size.to_f64() - b)
					West => if (b < node_index.to_f64()) $max + b else $min - (layer_size.to_f64() - b)
					_ => $s.port_bary.get(p) ?? 0
				}
				$s = { ..$s, port_bary: $s.port_bary.set(p, value) ?? $s.port_bary }
			}
			$s
		}
	}

	sort_ports : State, U64 -> State
	sort_ports = |s, n| {
		node = FlowLayoutGraph.node(s.model, n)
		sorted = FlowLayoutGraph.sort_by(
			node.ports,
			|a, b| {
				pa = FlowLayoutGraph.port(s.model, a)
				pb = FlowLayoutGraph.port(s.model, b)
				sa = FlowLayoutGraph.side_index(pa.side)
				sb = FlowLayoutGraph.side_index(pb.side)
				if sa != sb {
					if (sa < sb) -1 else 1
				} else {
					ba = s.port_bary.get(a) ?? 0
					bb = s.port_bary.get(b) ?? 0
					if ba == 0 and bb == 0 {
						0
					} else if ba == 0 {
						-1
					} else if bb == 0 {
						1
					} else if ba < bb {
						-1
					} else if ba > bb {
						1
					} else {
						0
					}
				}
			},
		)
		{ ..s, model: FlowLayoutGraph.set_node(s.model, n, { ..node, ports: sorted }) }
	}

	# ---------------------------------------------------------------- crossings

	## All crossings of a graph's current order: between each pair of
	## neighbouring layers, plus edges within the first and last layers.
	count_all : State, List(List(U64)) -> I64
	count_all = |s, order|
		if order.is_empty() {
			0
		} else {
			var $pos = s.cross_pos
			first = order.first() ?? []
			last = order.last() ?? []
			(p1, c1) = FlowLayoutOrder.in_layer_crossings(s.model, $pos, first, West)
			(p2, c2) = FlowLayoutOrder.in_layer_crossings(s.model, p1, last, East)
			$pos = p2
			var $total = c1 + c2
			for l in 0..<(order.len() - 1) {
				(p3, c3) = FlowLayoutOrder.between_layers(s.model, $pos, order.get(l) ?? [], order.get(l + 1) ?? [])
				$pos = p3
				$total = $total + c3
			}
			$total
		}

	## Ports of a node on one side, in the order the counter lists them.
	side_ports : Model, U64, FlowLayoutGraph.Side, Bool -> List(U64)
	side_ports = |m, n, side, top_down| {
		view = FlowLayoutGraph.ports_on(m, n, side)
		if side == East {
			if (top_down) view else view.rev()
		} else if top_down {
			view.rev()
		} else {
			view
		}
	}

	between_layers : Model, List(I64), List(U64), List(U64) -> (List(I64), I64)
	between_layers = |m, pos0, left, right| {
		var $pos = pos0
		var $ports = []
		for n in left {
			for p in FlowLayoutOrder.side_ports(m, n, East, True) {
				$pos = $pos.set(p, $ports.len().to_i64_wrap()) ?? $pos
				$ports = $ports.append(p)
			}
		}
		var $k = right.len()
		while $k > 0 {
			$k = $k - 1
			n = right.get($k) ?? 0
			for p in FlowLayoutOrder.side_ports(m, n, West, False) {
				$pos = $pos.set(p, $ports.len().to_i64_wrap()) ?? $pos
				$ports = $ports.append(p)
			}
		}
		positions = $pos
		(positions, FlowLayoutOrder.count_on_ports(m, positions, $ports))
	}

	## Crossings on a sequence of ports: an edge from a port to a later port
	## crosses every edge already open at a position before its end.
	count_on_ports : Model, List(I64), List(U64) -> I64
	count_on_ports = |m, pos, ports| {
		size = ports.len()
		var $tree = List.repeat(0, size + 1)
		var $per_index = List.repeat(0, size)
		var $crossings = 0
		position_of = |p| pos.get(p) ?? 0
		for p in ports {
			idx = position_of(p).max(0).to_u64_wrap()
			# Remove all open edges ending here.
			count_here = $per_index.get(idx) ?? 0
			if count_here > 0 {
				$per_index = $per_index.set(idx, 0) ?? $per_index
				var $i = idx + 1
				while $i < $tree.len() {
					$tree = $tree.set($i, ($tree.get($i) ?? 0) - count_here) ?? $tree
					$i = $i + $i.bitwise_and($i.bitwise_xor(18446744073709551615).plus_wrap(1))
				}
			}
			port = FlowLayoutGraph.port(m, p)
			var $ends = []
			for e in port.incoming.concat(port.outgoing) {
				edge = FlowLayoutGraph.edge(m, e)
				other = if (edge.source == p) edge.target else edge.source
				end = position_of(other)
				if end > position_of(p) {
					# Rank: open edges ending before `end`.
					var $sum = 0
					var $i = end.to_u64_wrap()
					while $i > 0 {
						$sum = $sum + ($tree.get($i) ?? 0)
						$i = $i - $i.bitwise_and($i.bitwise_xor(18446744073709551615).plus_wrap(1))
					}
					$crossings = $crossings + $sum
					$ends = $ends.append(end)
				}
			}
			# The engine pushes ends on a stack and adds them in reverse; adding
			# is order-independent.
			for end in $ends {
				ei = end.to_u64_wrap()
				if ei < size {
					$per_index = $per_index.set(ei, ($per_index.get(ei) ?? 0) + 1) ?? $per_index
					var $i = ei + 1
					while $i < $tree.len() {
						$tree = $tree.set($i, ($tree.get($i) ?? 0) + 1) ?? $tree
						$i = $i + $i.bitwise_and($i.bitwise_xor(18446744073709551615).plus_wrap(1))
					}
				}
			}
		}
		$crossings
	}

	in_layer_crossings : Model, List(I64), List(U64), FlowLayoutGraph.Side -> (List(I64), I64)
	in_layer_crossings = |m, pos0, nodes, side| {
		var $pos = pos0
		var $ports = []
		for n in nodes {
			for p in FlowLayoutOrder.side_ports(m, n, side, True) {
				$pos = $pos.set(p, $ports.len().to_i64_wrap()) ?? $pos
				$ports = $ports.append(p)
			}
		}
		positions = $pos
		size = $ports.len()
		var $open = List.repeat(0, size)
		var $crossings = 0
		position_of = |p| positions.get(p) ?? 0
		same_layer = |e| FlowLayoutGraph.node(m, FlowLayoutGraph.source_node(m, e)).layer == FlowLayoutGraph.node(m, FlowLayoutGraph.target_node(m, e)).layer
		for p in $ports {
			idx = position_of(p).max(0).to_u64_wrap()
			$open = $open.set(idx, 0) ?? $open
			port = FlowLayoutGraph.port(m, p)
			var $between = 0
			var $ends = []
			for e in port.incoming.concat(port.outgoing) {
				if same_layer(e) {
					edge = FlowLayoutGraph.edge(m, e)
					other = if (edge.source == p) edge.target else edge.source
					end = position_of(other)
					if end > position_of(p) {
						var $sum = 0
						for k in 0..<end.to_u64_wrap() {
							$sum = $sum + ($open.get(k) ?? 0)
						}
						$crossings = $crossings + $sum
						$ends = $ends.append(end)
					}
				} else {
					$between = $between + 1
				}
			}
			open_total = $open.fold(0, |a, x| a + x)
			$crossings = $crossings + open_total * $between
			for end in $ends {
				ei = end.to_u64_wrap()
				$open = $open.set(ei, ($open.get(ei) ?? 0) + 1) ?? $open
			}
		}
		(positions, $crossings)
	}

	# ---------------------------------------------------------------- result

	## Write the best order of each graph back to the graph: layers and port
	## lists; nodes then keep their port order.
	transfer : State -> Model
	transfer = |s| {
		var $m = s.model
		for h in s.holders {
			match h.best {
				Some(best) => {
					graph = FlowLayoutGraph.graph($m, h.graph)
					$m = FlowLayoutGraph.set_graph($m, h.graph, { ..graph, layers: best.layers })
					for entry in best.ports {
						node = FlowLayoutGraph.node($m, entry.node)
						constraints = if (node.port_constraints == FixedOrder or node.port_constraints == FixedPos) node.port_constraints else FixedOrder
						$m = FlowLayoutGraph.set_node($m, entry.node, { ..node, ports: entry.ports, port_constraints: constraints })
					}
				}
				None => {}
			}
		}
		$m
	}
}
