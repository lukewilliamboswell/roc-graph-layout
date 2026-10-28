import NetworkSimplex

## Layers by network simplex, step for step as the layered solver
## assigns them: a feasible tree grown by depth-first search from the first
## node, cut values computed from the leaves, tree edges exchanged while one
## has a negative cut value (up to an iteration limit), then layers moved
## to less crowded ones where that costs nothing. Ties are broken by node
## and edge order, so the order of `nodes` and of each node's edge lists
## decides between equally good layerings.
LayeredFlowSimplex :: {}.{

	## Node `i` is `i`. Each edge runs from `source` to `target` and wants to
	## span at least `delta` layers; `weight` is the cost per layer spanned.
	Problem : { node_count : U64, edges : List({ source : U64, target : U64, weight : F64, delta : I64 }), iteration_limit : U64, balance : Bool, previous : List(U64) }

	## The layer of each node, from 0, and the order the nodes end up in
	## (which changes when leaves are set aside and put back).
	Solution : { layers : List(I64), order : List(U64) }

	nil : U64
	nil = 18446744073709551615

	big : I64
	big = 2147483647

	solve : Problem -> Solution
	solve = |problem| {
		n = problem.node_count
		if n == 0 {
			{ layers: [], order: [] }
		} else {
			LayeredFlowSimplex.run(problem)
		}
	}

	State : {
		layer : List(I64),
		incoming : List(List(U64)),
		outgoing : List(List(U64)),
		nodes : List(U64),
		tree_node : List(Bool),
		tree_edge : List(Bool),
		tree_edges : List(U64),
		edge_visited : List(Bool),
		edges : List({ source : U64, target : U64, weight : F64, delta : I64 }),

		## The edges of the graph in initialisation order, which can differ from
		## `edges` order: grouped by source in node order.
		edge_list : List(U64),
	}

	connected : State, U64 -> List(U64)
	connected = |s, v| (s.incoming.get(v) ?? []).concat(s.outgoing.get(v) ?? [])

	other : State, U64, U64 -> U64
	other = |s, e, v| {
		edge = s.edges.get(e) ?? { source: 0, target: 0, weight: 0, delta: 0 }
		if (edge.source == v) edge.target else edge.source
	}

	edge_of : State, U64 -> { source : U64, target : U64, weight : F64, delta : I64 }
	edge_of = |s, e| s.edges.get(e) ?? { source: 0, target: 0, weight: 0, delta: 0 }

	lay : State, U64 -> I64
	lay = |s, v| s.layer.get(v) ?? 0

	without : List(U64), U64 -> List(U64)
	without = |list, x|
		match list.find_first_index(|y| y == x) {
			Ok(i) => list.take_first(i).concat(list.drop_first(i + 1))
			Err(_) => list
		}

	run : Problem -> Solution
	run = |problem| {
		n = problem.node_count
		var $incoming = List.repeat([], n)
		var $outgoing = List.repeat([], n)
		for e in 0..<problem.edges.len() {
			edge = problem.edges.get(e) ?? { source: 0, target: 0, weight: 0, delta: 0 }
			if edge.source < n and edge.target < n {
				$outgoing = $outgoing.set(edge.source, ($outgoing.get(edge.source) ?? []).append(e)) ?? []
				$incoming = $incoming.set(edge.target, ($incoming.get(edge.target) ?? []).append(e)) ?? []
			}
		}
		var $s = {
			layer: List.repeat(0, n),
			incoming: $incoming,
			outgoing: $outgoing,
			nodes: List.repeat(0, n).map_with_index(|_, i| i),
			tree_node: List.repeat(False, n),
			tree_edge: List.repeat(False, problem.edges.len()),
			tree_edges: [],
			edge_visited: List.repeat(False, problem.edges.len()),
			edges: problem.edges,
			edge_list: [],
		}
		remove_subtrees = n >= 40
		var $stack = []
		if remove_subtrees {
			# Set leaves aside, repeatedly.
			var $leafs = $s.nodes.keep_if(|v| LayeredFlowSimplex.connected($s, v).len() == 1)
			var $head = 0
			while $head < $leafs.len() {
				v = $leafs.get($head) ?? 0
				$head = $head + 1
				conn = LayeredFlowSimplex.connected($s, v)
				if !conn.is_empty() {
					e = conn.first() ?? 0
					is_out = !($s.outgoing.get(v) ?? []).is_empty()
					o = LayeredFlowSimplex.other($s, e, v)
					$s = if is_out {
						{ ..$s, incoming: $s.incoming.set(o, LayeredFlowSimplex.without($s.incoming.get(o) ?? [], e)) ?? [] }
					} else {
						{ ..$s, outgoing: $s.outgoing.set(o, LayeredFlowSimplex.without($s.outgoing.get(o) ?? [], e)) ?? [] }
					}
					if LayeredFlowSimplex.connected($s, o).len() == 1 {
						$leafs = $leafs.append(o)
					}
					$stack = $stack.append({ node: v, edge: e })
					$s = { ..$s, nodes: LayeredFlowSimplex.without($s.nodes, v) }
				}
			}
		}
		# Initialise: sources, edges grouped by source in node order.
		var $edge_list = []
		var $sources = []
		for v in $s.nodes {
			if ($s.incoming.get(v) ?? []).is_empty() {
				$sources = $sources.append(v)
			}
			$edge_list = $edge_list.concat($s.outgoing.get(v) ?? [])
		}
		$s = { ..$s, edge_list: $edge_list }
		$s = LayeredFlowSimplex.feasible_tree($s, $sources)
		refined = NetworkSimplex.refine(n, problem.edges.map(|e| { from: e.source, to: e.target }), problem.edges.map(|e| e.weight), problem.edges.map(|e| e.delta.to_u64_wrap()), $s.layer, $s.tree_edge, { effort_cap: problem.iteration_limit, cut_tolerance: 1e-10, order: Source({ nodes: $s.nodes, edges: $s.edge_list, tree_edges: $s.tree_edges }) })
		$s = { ..$s, layer: refined }
		if remove_subtrees {
			var $k = $stack.len()
			while $k > 0 {
				$k = $k - 1
				item = $stack.get($k) ?? { node: 0, edge: 0 }
				v = item.node
				e = item.edge
				edge = LayeredFlowSimplex.edge_of($s, e)
				placed = LayeredFlowSimplex.other($s, e, v)
				$s = if edge.target == v {
					{ ..$s, outgoing: $s.outgoing.set(placed, ($s.outgoing.get(placed) ?? []).append(e)) ?? [], layer: $s.layer.set(v, LayeredFlowSimplex.lay($s, placed) + edge.delta) ?? [] }
				} else {
					{ ..$s, incoming: $s.incoming.set(placed, ($s.incoming.get(placed) ?? []).append(e)) ?? [], layer: $s.layer.set(v, LayeredFlowSimplex.lay($s, placed) - edge.delta) ?? [] }
				}
				$s = { ..$s, nodes: $s.nodes.append(v) }
			}
		}
		# Normalise and balance.
		lowest = $s.nodes.fold(LayeredFlowSimplex.big, |m, v| m.min(LayeredFlowSimplex.lay($s, v)))
		highest = $s.nodes.fold(0 - LayeredFlowSimplex.big, |m, v| m.max(LayeredFlowSimplex.lay($s, v)))
		span = (highest - lowest + 1).max(1).to_u64_wrap()
		var $filling = List.repeat(0, span)
		var $layer = $s.layer
		for v in $s.nodes {
			l = ($layer.get(v) ?? 0) - lowest
			$layer = $layer.set(v, l) ?? []
			li = l.to_u64_wrap()
			$filling = $filling.set(li, ($filling.get(li) ?? 0) + 1) ?? $filling
		}
		var $id = 0
		var $prev_done = False
		for count in problem.previous {
			if !$prev_done {
				$filling = $filling.set($id, ($filling.get($id) ?? 0) + count) ?? $filling
				$id = $id + 1
				if $filling.len() == $id {
					$prev_done = True
				}
			}
		}
		if problem.balance {
			for v in $s.nodes {
				ins = ($s.incoming.get(v) ?? []).len()
				outs = ($s.outgoing.get(v) ?? []).len()
				if ins == outs {
					current = $layer.get(v) ?? 0
					# The node may move within its incident edges' slack.
					var $min_in = LayeredFlowSimplex.big
					var $min_out = LayeredFlowSimplex.big
					for e in LayeredFlowSimplex.connected($s, v) {
						edge = LayeredFlowSimplex.edge_of($s, e)
						span_e = ($layer.get(edge.target) ?? 0) - ($layer.get(edge.source) ?? 0)
						if edge.target == v and span_e < $min_in {
							$min_in = span_e
						} else if span_e < $min_out {
							$min_out = span_e
						}
					}
					range_in = if ($min_in == LayeredFlowSimplex.big) -1 else $min_in
					range_out = if ($min_out == LayeredFlowSimplex.big) -1 else $min_out
					var $new = current
					var $i = current - range_in + 1
					while $i < current + range_out {
						if $i >= 0 and ($filling.get($i.to_u64_wrap()) ?? 1000000000) < ($filling.get($new.to_u64_wrap()) ?? 0) {
							$new = $i
						}
						$i = $i + 1
					}
					if ($filling.get($new.to_u64_wrap()) ?? 0) < ($filling.get(current.to_u64_wrap()) ?? 0) {
						$filling = $filling.set(current.to_u64_wrap(), ($filling.get(current.to_u64_wrap()) ?? 0) - 1) ?? $filling
						$filling = $filling.set($new.to_u64_wrap(), ($filling.get($new.to_u64_wrap()) ?? 0) + 1) ?? $filling
						$layer = $layer.set(v, $new) ?? []
					}
				}
			}
		}
		{ layers: $layer, order: $s.nodes }
	}

	feasible_tree : State, List(U64) -> State
	feasible_tree = |s0, sources| {
		var $s = LayeredFlowSimplex.topological_layers(s0, sources)
		if $s.edge_list.is_empty() {
			$s
		} else {
			first = $s.nodes.first() ?? 0
			var $guard = 0
			var $growing = True
			while $growing and $guard <= $s.nodes.len() {
				$s = { ..$s, edge_visited: List.repeat(False, $s.edges.len()) }
				grown = LayeredFlowSimplex.tight_tree_dfs($s, first)
				$s = grown.state
				if grown.count >= $s.nodes.len() {
					$growing = False
				} else {
					e = LayeredFlowSimplex.minimal_slack($s)
					if e == LayeredFlowSimplex.nil {
						$growing = False
					} else {
						edge = LayeredFlowSimplex.edge_of($s, e)
						slack0 = LayeredFlowSimplex.lay($s, edge.target) - LayeredFlowSimplex.lay($s, edge.source) - edge.delta
						slack = if ($s.tree_node.get(edge.target) ?? False) 0 - slack0 else slack0
						var $layer = $s.layer
						for v in $s.nodes {
							if $s.tree_node.get(v) ?? False {
								$layer = $layer.set(v, ($layer.get(v) ?? 0) + slack) ?? []
							}
						}
						$s = { ..$s, layer: $layer }
					}
				}
				$guard = $guard + 1
			}
			$s
		}
	}

	topological_layers : State, List(U64) -> State
	topological_layers = |s, sources| {
		var $incident = List.repeat(0, s.layer.len())
		for v in s.nodes {
			$incident = $incident.set(v, ($incident.get(v) ?? 0) + (s.incoming.get(v) ?? []).len()) ?? []
		}
		var $layer = s.layer
		var $roots = sources
		var $head = 0
		while $head < $roots.len() {
			v = $roots.get($head) ?? 0
			$head = $head + 1
			for e in s.outgoing.get(v) ?? [] {
				edge = LayeredFlowSimplex.edge_of(s, e)
				t = edge.target
				$layer = $layer.set(t, ($layer.get(t) ?? 0).max(($layer.get(v) ?? 0) + edge.delta)) ?? []
				left = ($incident.get(t) ?? 1) - 1
				$incident = $incident.set(t, left) ?? []
				if left == 0 {
					$roots = $roots.append(t)
				}
			}
		}
		{ ..s, layer: $layer }
	}

	## Grow the tree of tight edges from `start`, depth first; returns how
	## many nodes it reaches.
	tight_tree_dfs : State, U64 -> { state : State, count : U64 }
	tight_tree_dfs = |s0, start| {
		var $s = { ..s0, tree_node: s0.tree_node.set(start, True) ?? [] }
		var $count = 1
		var $stack = [{ node: start, edges: LayeredFlowSimplex.connected(s0, start), next: 0 }]
		while !$stack.is_empty() {
			top = $stack.last() ?? { node: 0, edges: [], next: 0 }
			if top.next >= top.edges.len() {
				$stack = $stack.drop_last(1)
			} else {
				$stack = $stack.set($stack.len() - 1, { ..top, next: top.next + 1 }) ?? []
				e = top.edges.get(top.next) ?? 0
				if !($s.edge_visited.get(e) ?? True) {
					$s = { ..$s, edge_visited: $s.edge_visited.set(e, True) ?? [] }
					o = LayeredFlowSimplex.other($s, e, top.node)
					edge = LayeredFlowSimplex.edge_of($s, e)
					descend = if $s.tree_edge.get(e) ?? False {
						True
					} else if !($s.tree_node.get(o) ?? False) and edge.delta == LayeredFlowSimplex.lay($s, edge.target) - LayeredFlowSimplex.lay($s, edge.source) {
						$s = { ..$s, tree_edge: $s.tree_edge.set(e, True) ?? [], tree_edges: $s.tree_edges.append(e) }
						True
					} else {
						False
					}
					if descend {
						$s = { ..$s, tree_node: $s.tree_node.set(o, True) ?? [] }
						$count = $count + 1
						$stack = $stack.append({ node: o, edges: LayeredFlowSimplex.connected($s, o), next: 0 })
					}
				}
			}
		}
		{ state: $s, count: $count }
	}

	minimal_slack : State -> U64
	minimal_slack = |s| {
		var $min = LayeredFlowSimplex.big
		var $best = LayeredFlowSimplex.nil
		for e in s.edge_list {
			edge = LayeredFlowSimplex.edge_of(s, e)
			if (s.tree_node.get(edge.source) ?? False) != (s.tree_node.get(edge.target) ?? False) {
				slack = LayeredFlowSimplex.lay(s, edge.target) - LayeredFlowSimplex.lay(s, edge.source) - edge.delta
				if slack < $min {
					$min = slack
					$best = e
				}
			}
		}
		$best
	}

}

## A chain gets one layer per node.
expect {
	sol = LayeredFlowSimplex.solve({ node_count: 3, edges: [{ source: 0, target: 1, weight: 1, delta: 1 }, { source: 1, target: 2, weight: 1, delta: 1 }], iteration_limit: 100, balance: True, previous: [] })
	sol.layers == [0, 1, 2]
}

## A short edge pulls a node next to its neighbour.
expect {
	edges = [{ source: 0, target: 1, weight: 1, delta: 1 }, { source: 1, target: 2, weight: 1, delta: 1 }, { source: 2, target: 3, weight: 1, delta: 1 }, { source: 4, target: 3, weight: 1, delta: 1 }]
	sol = LayeredFlowSimplex.solve({ node_count: 5, edges, iteration_limit: 100, balance: True, previous: [] })
	sol.layers.get(4) == Ok(2)
}
