import LayeredFlowImport
import LayeredFlowFixtures
import LayeredFlowGraph
import LayeredFlowLoops
import LayeredFlowSimplex

## The first half of laying out one graph, as the layered solver does
## it: edges closing a cycle are turned around (found depth first), edge
## labels become nodes of their own, nodes get layers by network simplex,
## hierarchical port dummies go to separate first and last layers, edges
## spanning several layers get one dummy node per layer, every port gets a
## side, and nodes and ports are put in the order the diagram declared them.
LayeredFlowLayers :: {}.{

	Model : LayeredFlowGraph.Model

	nil : U64
	nil = LayeredFlowGraph.nil

	## Which optional steps a graph runs, from what it contains.
	Features : { self_loops : Bool, center_labels : Bool, external_ports : Bool, non_free_ports : Bool, model_order : Bool, vertical : Bool }

	features : Model, U64, Bool -> Features
	features = |m, g, vertical| {
		graph = LayeredFlowGraph.graph(m, g)
		nodes = graph.nodes
		edges_of = |n| LayeredFlowGraph.outgoing(m, n)
		{
			self_loops: nodes.any(|n| edges_of(n).any(|e| LayeredFlowGraph.is_self_loop(m, e))),
			center_labels: nodes.any(|n| edges_of(n).any(|e| !LayeredFlowGraph.edge(m, e).labels.is_empty())),
			external_ports: graph.external_ports,
			non_free_ports: nodes.any(|n| LayeredFlowGraph.node(m, n).port_constraints != FreePorts),
			model_order: graph.model_order_nodes,
			vertical,
		}
	}

	## Run every step up to (not including) ordering nodes within layers.
	prepare : Model, U64, Features -> Model
	prepare = |m0, g, f| {
		m1 = LayeredFlowLayers.constraint_reverser(m0, g)
		m2 = LayeredFlowLayers.break_cycles(m1, g)
		m3 = if (f.center_labels) LayeredFlowLayers.insert_label_dummies(m2, g, f.vertical) else m2
		looped = if (f.self_loops) LayeredFlowLoops.hide(m3, g) else m3
		hidden = LayeredFlowLayers.hide_separate(looped, g)
		m4 = LayeredFlowLayers.layer(hidden, g)
		m5 = LayeredFlowLayers.restore_constraints(m4, g)
		m6 = LayeredFlowLayers.split_long_edges(m5, g)
		m7 = LayeredFlowLayers.port_sides(m6, g)
		m8 = if (f.non_free_ports) LayeredFlowLayers.inverted_ports(m7, g) else m7
		m9 = LayeredFlowLayers.sort_port_lists(m8, g)
		if (f.model_order) LayeredFlowLayers.sort_by_model_order(m9, g) else m9
	}

	layer_of : Model, U64 -> U64
	layer_of = |m, n| LayeredFlowGraph.node(m, n).layer

	## Put a node at the end of a layer, taking it out of its old one.
	set_layer : Model, U64, U64 -> Model
	set_layer = |m, n, l| {
		node = LayeredFlowGraph.node(m, n)
		g = node.graph
		graph = LayeredFlowGraph.graph(m, g)
		removed = if node.layer != LayeredFlowLayers.nil {
			graph.layers.set(node.layer, LayeredFlowGraph.without(graph.layers.get(node.layer) ?? [], n)) ?? graph.layers
		} else {
			graph.layers
		}
		added = if l != LayeredFlowLayers.nil {
			removed.set(l, (removed.get(l) ?? []).append(n)) ?? removed
		} else {
			removed
		}
		m1 = LayeredFlowGraph.set_graph(m, g, { ..graph, layers: added })
		LayeredFlowGraph.set_node(m1, n, { ..node, layer: l })
	}

	## Renumber the nodes' layer fields after layers were added or removed.
	renumber : Model, U64 -> Model
	renumber = |m, g| {
		var $m = m
		layers = LayeredFlowGraph.graph(m, g).layers
		for l in 0..<layers.len() {
			for n in layers.get(l) ?? [] {
				$m = LayeredFlowGraph.set_node($m, n, { ..LayeredFlowGraph.node($m, n), layer: l })
			}
		}
		$m
	}

	# ---------------------------------------------------------------- reversal

	constraint_reverser : Model, U64 -> Model
	constraint_reverser = |m0, g| {
		var $m = m0
		nodes = LayeredFlowGraph.graph(m0, g).nodes
		var $remaining = []
		for n in nodes {
			lc = LayeredFlowGraph.node($m, n).layer_constraint
			match lc {
				First | FirstSeparate => {
					$m = LayeredFlowLayers.reverse_edges($m, n, lc, False, True)
				}
				Last | LastSeparate => {
					$m = LayeredFlowLayers.reverse_edges($m, n, lc, True, False)
				}
				Free => {
					$remaining = $remaining.append(n)
				}
			}
		}
		for n in $remaining {
			node = LayeredFlowGraph.node($m, n)
			if node.port_constraints != FreePorts and !node.ports.is_empty() {
				all_reversed = node.ports.all(
					|p| {
						port = LayeredFlowGraph.port($m, p)
						flow = LayeredFlowGraph.net_flow(port)
						inverted = (port.side == East and flow > 0) or (port.side == West and flow < 0)
						inverted
							and port.outgoing.all(
								|e|
									match LayeredFlowGraph.node($m, LayeredFlowGraph.target_node($m, e)).layer_constraint {
										Last | LastSeparate => False
										_ => True
									},
							)
							and port.incoming.all(
								|e|
									match LayeredFlowGraph.node($m, LayeredFlowGraph.source_node($m, e)).layer_constraint {
										First | FirstSeparate => False
										_ => True
									},
							)
					},
				)
				if all_reversed {
					$m = LayeredFlowLayers.reverse_edges($m, n, Free, True, True)
				}
			}
		}
		$m
	}

	## Turn around a node's outgoing (`outs`) and incoming (`ins`) edges where
	## allowed.
	reverse_edges : Model, U64, LayeredFlowGraph.LayerConstraint, Bool, Bool -> Model
	reverse_edges = |m0, n, lc, outs, ins| {
		var $m = m0
		for p in LayeredFlowGraph.node(m0, n).ports {
			if outs {
				for e in LayeredFlowGraph.port($m, p).outgoing {
					edge = LayeredFlowGraph.edge($m, e)
					target = LayeredFlowGraph.node($m, LayeredFlowGraph.port($m, edge.target).node)
					ok = !edge.reversed and !(lc == Last and target.kind == Label) and target.layer_constraint != LastSeparate
					if ok {
						$m = LayeredFlowGraph.reverse($m, e)
					}
				}
			}
			if ins {
				for e in LayeredFlowGraph.port($m, p).incoming {
					edge = LayeredFlowGraph.edge($m, e)
					source = LayeredFlowGraph.node($m, LayeredFlowGraph.port($m, edge.source).node)
					ok = !edge.reversed and !(lc == First and source.kind == Label) and source.layer_constraint != FirstSeparate
					if ok {
						$m = LayeredFlowGraph.reverse($m, e)
					}
				}
			}
		}
		$m
	}

	## Depth-first cycle breaking: walks from nodes without incoming edges, in
	## node order, then from any node not reached, following outgoing edges in
	## port order; an edge to a node on the current walk is turned around.
	break_cycles : Model, U64 -> Model
	break_cycles = |m0, g| {
		nodes = LayeredFlowGraph.graph(m0, g).nodes
		count = nodes.len()
		slot = |n| nodes.find_first_index(|x| x == n) ?? count
		sources = nodes.keep_if(|n| LayeredFlowGraph.incoming(m0, n).is_empty())
		var $visited = List.repeat(False, count)
		var $active = List.repeat(False, count)
		var $reverse = []
		starts = sources.concat(nodes)
		for start in starts {
			if !($visited.get(slot(start)) ?? True) {
				$visited = $visited.set(slot(start), True) ?? []
				$active = $active.set(slot(start), True) ?? []
				var $stack = [{ node: start, edges: LayeredFlowGraph.outgoing(m0, start), next: 0 }]
				while !$stack.is_empty() {
					top = $stack.last() ?? { node: start, edges: [], next: 0 }
					if top.next >= top.edges.len() {
						$active = $active.set(slot(top.node), False) ?? $active
						$stack = $stack.drop_last(1)
					} else {
						$stack = $stack.set($stack.len() - 1, { ..top, next: top.next + 1 }) ?? []
						e = top.edges.get(top.next) ?? 0
						if !LayeredFlowGraph.is_self_loop(m0, e) {
							t = LayeredFlowGraph.target_node(m0, e)
							if $active.get(slot(t)) ?? False {
								$reverse = $reverse.append(e)
							} else if !($visited.get(slot(t)) ?? True) {
								$visited = $visited.set(slot(t), True) ?? $visited
								$active = $active.set(slot(t), True) ?? $active
								$stack = $stack.append({ node: t, edges: LayeredFlowGraph.outgoing(m0, t), next: 0 })
							}
						}
					}
				}
			}
		}
		var $m = m0
		for e in $reverse {
			$m = LayeredFlowGraph.reverse($m, e)
		}
		if $reverse.is_empty() {
			$m
		} else {
			LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), cyclic: True })
		}
	}

	# ---------------------------------------------------------------- labels

	## Split an edge at a new dummy node: the edge now ends at the dummy, and
	## a copy runs from the dummy to the old end. Returns the new edge.
	split_edge : Model, U64, U64 -> (Model, U64)
	split_edge = |m0, e, dummy| {
		edge = LayeredFlowGraph.edge(m0, e)
		old_target = edge.target
		thickness = edge.thickness.max(0)
		port_y = LayeredFlowGraph.floor(thickness)
		d0 = LayeredFlowGraph.node(m0, dummy)
		m1 = LayeredFlowGraph.set_node(m0, dummy, { ..d0, height: thickness })
		(m2, input) = LayeredFlowGraph.add_port(m1, dummy, West)
		m3 = LayeredFlowGraph.set_port(m2, input, { ..LayeredFlowGraph.port(m2, input), y: LayeredFlowGraph.floor(port_y / 2) })
		(m4, output) = LayeredFlowGraph.add_port(m3, dummy, East)
		m5 = LayeredFlowGraph.set_port(m4, output, { ..LayeredFlowGraph.port(m4, output), y: LayeredFlowGraph.floor(port_y / 2) })
		m6 = LayeredFlowGraph.set_target(m5, e, input)
		(m7, new_edge) = LayeredFlowGraph.add_edge(m6, { ..LayeredFlowGraph.edge(m6, e), source: output, target: old_target, labels: [], bends: [] })
		# The dummy remembers which ports the whole edge runs between.
		source_node = LayeredFlowGraph.node(m7, LayeredFlowGraph.port(m7, LayeredFlowGraph.edge(m7, e).source).node)
		target_node = LayeredFlowGraph.node(m7, LayeredFlowGraph.port(m7, old_target).node)
		d = LayeredFlowGraph.node(m7, dummy)
		ends = if source_node.kind == LongEdge {
			{ source: source_node.long_edge_source, target: source_node.long_edge_target, labels: source_node.has_label_dummies }
		} else if source_node.kind == Label {
			{ source: source_node.long_edge_source, target: source_node.long_edge_target, labels: True }
		} else if target_node.kind == Label {
			{ source: target_node.long_edge_source, target: target_node.long_edge_target, labels: True }
		} else {
			{ source: LayeredFlowGraph.edge(m7, e).source, target: old_target, labels: d.has_label_dummies }
		}
		(LayeredFlowGraph.set_node(m7, dummy, { ..d, long_edge_source: ends.source, long_edge_target: ends.target, has_label_dummies: ends.labels }), new_edge)
	}

	## Each labelled edge gets a node in its middle that carries its label.
	insert_label_dummies : Model, U64, Bool -> Model
	insert_label_dummies = |m0, g, vertical| {
		var $m = m0
		var $new = []
		spacing = LayeredFlowGraph.graph(m0, g).spacing
		for n in LayeredFlowGraph.graph(m0, g).nodes {
			for e in LayeredFlowGraph.outgoing($m, n) {
				edge = LayeredFlowGraph.edge($m, e)
				if !LayeredFlowGraph.is_self_loop($m, e) and !edge.labels.is_empty() {
					thickness = edge.thickness.max(0)
					(m1, dummy) = LayeredFlowGraph.add_loose_node($m, { ..LayeredFlowGraph.blank_node, graph: g, kind: Label, origin: EdgeDummy(edge.origin), port_constraints: FixedPos, long_edge_source: edge.source, long_edge_target: edge.target })
					(m2, _) = LayeredFlowLayers.split_edge(m1, e, dummy)
					d = LayeredFlowGraph.node(m2, dummy)
					var $w = d.width
					var $h = d.height
					for label in edge.labels {
						if vertical {
							$w = $w + label.width + spacing.label_label
							$h = $h.max(label.height)
						} else {
							$w = $w.max(label.width)
							$h = $h + label.height + spacing.label_label
						}
					}
					(fw, fh) = if vertical {
						($w - spacing.label_label, $h + spacing.edge_label + thickness)
					} else {
						($w, $h + spacing.edge_label - spacing.label_label + thickness)
					}
					m3 = LayeredFlowGraph.set_node(m2, dummy, { ..d, width: fw, height: fh, labels: edge.labels })
					$m = LayeredFlowGraph.set_edge(m3, e, { ..LayeredFlowGraph.edge(m3, e), labels: [] })
					$new = $new.append(dummy)
				}
			}
		}
		graph = LayeredFlowGraph.graph($m, g)
		LayeredFlowGraph.set_graph($m, g, { ..graph, nodes: graph.nodes.concat($new) })
	}

	# ---------------------------------------------------------------- layering

	## Take nodes in separate first or last layers out of the graph while
	## layering: their edges keep only the end inside the graph.
	hide_separate : Model, U64 -> Model
	hide_separate = |m0, g| {
		graph = LayeredFlowGraph.graph(m0, g)
		var $m = m0
		var $kept = []
		var $hidden = []
		# 0 none, 1 first separate, 2 last separate, 3 both.
		var $connections = []
		for n in graph.nodes {
			node = LayeredFlowGraph.node($m, n)
			match node.layer_constraint {
				FirstSeparate | LastSeparate => {
					$hidden = $hidden.append(n)
					for e in LayeredFlowGraph.connected($m, n) {
						edge = LayeredFlowGraph.edge($m, e)
						outgoing = LayeredFlowGraph.port($m, edge.source).node == n
						opposite_port = if (outgoing) edge.target else edge.source
						$m = if (outgoing) LayeredFlowGraph.set_target($m, e, LayeredFlowLayers.nil) else LayeredFlowGraph.set_source($m, e, LayeredFlowLayers.nil)
						$m = LayeredFlowGraph.set_edge($m, e, { ..LayeredFlowGraph.edge($m, e), original_opposite: opposite_port })
						opposite = LayeredFlowGraph.port($m, opposite_port).node
						on = LayeredFlowGraph.node($m, opposite)
						if on.layer_constraint == Free {
							bit = if (node.layer_constraint == FirstSeparate) 1 else 2
							before = match $connections.find_first(|c| c.node == opposite) {
								Ok(c) => c.value
								Err(_) => 0
							}
							value = before.bitwise_or(bit)
							$connections = $connections.drop_if(|c| c.node == opposite).append({ node: opposite, value })
							if LayeredFlowGraph.connected($m, opposite).is_empty() {
								if value == 1 {
									$m = LayeredFlowGraph.set_node($m, opposite, { ..on, layer_constraint: First })
								} else if value == 2 {
									$m = LayeredFlowGraph.set_node($m, opposite, { ..on, layer_constraint: Last })
								}
							}
						}
					}
				}
				_ => {
					$kept = $kept.append(n)
				}
			}
		}
		LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), nodes: $kept, hidden: $hidden })
	}

	## Layers by network simplex, component by component.
	layer : Model, U64 -> Model
	layer = |m0, g| {
		nodes = LayeredFlowGraph.graph(m0, g).nodes
		if nodes.is_empty() {
			m0
		} else {
			count = nodes.len()
			# Each node's place in the graph's node list, by node index.
			var $slots = List.repeat(count, m0.nodes.len())
			for i in 0..<count {
				n = nodes.get(i) ?? 0
				if n < $slots.len() {
					$slots = $slots.set(n, i) ?? []
				}
			}
			slots = $slots
			slot = |n| slots.get(n) ?? count
			# Connected components, depth first in port order.
			var $visited = List.repeat(False, count)
			var $components = []
			for n in nodes {
				if !($visited.get(slot(n)) ?? True) {
					var $component = []
					$visited = $visited.set(slot(n), True) ?? $visited
					var $stack = [{ node: n, edges: LayeredFlowLayers.port_edges(m0, n), next: 0 }]
					$component = $component.append(n)
					while !$stack.is_empty() {
						top = $stack.last() ?? { node: n, edges: [], next: 0 }
						if top.next >= top.edges.len() {
							$stack = $stack.drop_last(1)
						} else {
							$stack = $stack.set($stack.len() - 1, { ..top, next: top.next + 1 }) ?? []
							pe = top.edges.get(top.next) ?? { port: 0, edge: 0 }
							edge = LayeredFlowGraph.edge(m0, pe.edge)
							opposite_port = if (edge.source == pe.port) edge.target else edge.source
							o = LayeredFlowGraph.port(m0, opposite_port).node
							if !($visited.get(slot(o)) ?? True) {
								$visited = $visited.set(slot(o), True) ?? $visited
								$component = $component.append(o)
								$stack = $stack.append({ node: o, edges: LayeredFlowLayers.port_edges(m0, o), next: 0 })
							}
						}
					}
					$components = if ($components.is_empty()) [$component] else if (($components.first() ?? []).len() < $component.len()) [$component].concat($components) else $components.append($component)
				}
			}
			var $m = m0
			var $previous = []
			iteration_factor = 7 * 4
			# Each node's place in its component, by node index.
			var $component_slots = List.repeat(0, m0.nodes.len())
			for component in $components {
				for i in 0..<component.len() {
					n = component.get(i) ?? 0
					if n < $component_slots.len() {
						$component_slots = $component_slots.set(n, i) ?? []
					}
				}
			}
			component_slots = $component_slots
			cslot = |n| component_slots.get(n) ?? 0
			# Nodes join the end of their layer in the order the solutions
			# list them; the layers are built once at the end.
			var $placed = []
			var $sizes = LayeredFlowGraph.graph(m0, g).layers.map(|l| l.len())
			for component in $components {
				var $edges = []
				for n in component {
					for e in LayeredFlowGraph.outgoing($m, n) {
						if !LayeredFlowGraph.is_self_loop($m, e) {
							$edges = $edges.append({ source: cslot(n), target: cslot(LayeredFlowGraph.target_node($m, e)), weight: 1, delta: 1 })
						}
					}
				}
				limit = iteration_factor * (component.len().to_f64().sqrt().floor_to_u64_try() ?? 0)
				solution = LayeredFlowSimplex.solve({ node_count: component.len(), edges: $edges, iteration_limit: limit, balance: True, previous: $previous })
				for i in solution.order {
					n = component.get(i) ?? 0
					l = (solution.layers.get(i) ?? 0).max(0).to_u64_wrap()
					while $sizes.len() <= l {
						$sizes = $sizes.append(0)
					}
					$sizes = $sizes.set(l, ($sizes.get(l) ?? 0) + 1) ?? []
					$placed = $placed.append({ node: n, layer: l })
					$m = LayeredFlowGraph.set_node($m, n, { ..LayeredFlowGraph.node($m, n), layer: l })
				}
				if $components.len() > 1 {
					$previous = $sizes
				}
			}
			# Bucket by layer, keeping the order within each.
			by_layer = LayeredFlowGraph.sort_by($placed, |a, b| if (a.layer < b.layer) -1 else if (a.layer > b.layer) 1 else 0)
			old = LayeredFlowGraph.graph($m, g).layers
			var $layers = []
			var $k = 0
			for l in 0..<$sizes.len() {
				var $layer = old.get(l) ?? []
				while $k < by_layer.len() and (by_layer.get($k) ?? { node: 0, layer: 0 }).layer == l {
					$layer = $layer.append((by_layer.get($k) ?? { node: 0, layer: 0 }).node)
					$k = $k + 1
				}
				$layers = $layers.append($layer)
			}
			LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), nodes: [], layers: $layers })
		}
	}

	## A node's edges by port: each port's incoming then outgoing edges.
	port_edges : Model, U64 -> List({ port : U64, edge : U64 })
	port_edges = |m, n|
		LayeredFlowGraph.node(m, n).ports.fold(
			[],
			|acc, p| {
				port = LayeredFlowGraph.port(m, p)
				acc.concat(port.incoming.map(|e| { port: p, edge: e })).concat(port.outgoing.map(|e| { port: p, edge: e }))
			},
		)

	## Move first and last nodes to the first and last layers, and put the
	## hidden separate nodes back in layers of their own.
	restore_constraints : Model, U64 -> Model
	restore_constraints = |m0, g| {
		var $m = m0
		layers0 = LayeredFlowGraph.graph(m0, g).layers
		if !layers0.is_empty() {
			last = layers0.len() - 1
			# Two extra layers for labels: index len and len + 1.
			first_label = layers0.len()
			last_label = layers0.len() + 1
			graph = LayeredFlowGraph.graph($m, g)
			$m = LayeredFlowGraph.set_graph($m, g, { ..graph, layers: graph.layers.append([]).append([]) })
			for l in 0..<layers0.len() {
				for n in layers0.get(l) ?? [] {
					match LayeredFlowGraph.node($m, n).layer_constraint {
						First => {
							$m = LayeredFlowLayers.set_layer($m, n, 0)
							for e in LayeredFlowGraph.incoming($m, n) {
								s = LayeredFlowGraph.source_node($m, e)
								if LayeredFlowGraph.node($m, s).kind == Label {
									$m = LayeredFlowLayers.set_layer($m, s, first_label)
								}
							}
						}
						Last => {
							$m = LayeredFlowLayers.set_layer($m, n, last)
							for e in LayeredFlowGraph.outgoing($m, n) {
								t = LayeredFlowGraph.target_node($m, e)
								if LayeredFlowGraph.node($m, t).kind == Label {
									$m = LayeredFlowLayers.set_layer($m, t, last_label)
								}
							}
						}
						_ => {}
					}
				}
			}
			after = LayeredFlowGraph.graph($m, g).layers
			first_extra = after.get(first_label) ?? []
			last_extra = after.get(last_label) ?? []
			main = after.take_first(layers0.len()).keep_if(|l| !l.is_empty())
			ordered = (if (first_extra.is_empty()) [] else [first_extra]).concat(main).concat(if (last_extra.is_empty()) [] else [last_extra])
			$m = LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), layers: ordered })
			$m = LayeredFlowLayers.renumber($m, g)
		}
		hidden = LayeredFlowGraph.graph($m, g).hidden
		if !hidden.is_empty() {
			firsts = hidden.keep_if(|n| LayeredFlowGraph.node($m, n).layer_constraint == FirstSeparate)
			lasts = hidden.keep_if(|n| LayeredFlowGraph.node($m, n).layer_constraint == LastSeparate)
			graph = LayeredFlowGraph.graph($m, g)
			layers = (if (firsts.is_empty()) [] else [firsts]).concat(graph.layers).concat(if (lasts.is_empty()) [] else [lasts])
			$m = LayeredFlowGraph.set_graph($m, g, { ..graph, layers, hidden: [] })
			$m = LayeredFlowLayers.renumber($m, g)
			for n in hidden {
				for e in LayeredFlowGraph.connected($m, n) {
					edge = LayeredFlowGraph.edge($m, e)
					if edge.source == LayeredFlowLayers.nil or edge.target == LayeredFlowLayers.nil {
						$m = if (edge.target == LayeredFlowLayers.nil) LayeredFlowGraph.set_target($m, e, edge.original_opposite) else LayeredFlowGraph.set_source($m, e, edge.original_opposite)
					}
				}
			}
		}
		$m
	}

	## Each edge spanning more than one layer gets a dummy node in each layer
	## between its ends.
	split_long_edges : Model, U64 -> Model
	split_long_edges = |m0, g| {
		layers = LayeredFlowGraph.graph(m0, g).layers
		layer_count = layers.len()
		if layer_count <= 2 {
			m0
		} else {
			var $m = m0
			# Dummies join the end of their layer in the order they are made;
			# the layers are rebuilt once at the end rather than per dummy.
			var $new_layers = []
			var $added = []
			for l in 0..<layer_count {
				current = (layers.get(l) ?? []).concat($added)
				$new_layers = $new_layers.append(current)
				$added = []
				if l + 1 < layer_count {
					for n in current {
						for p in LayeredFlowGraph.node($m, n).ports {
							for e in LayeredFlowGraph.port($m, p).outgoing {
								target_layer = LayeredFlowLayers.layer_of($m, LayeredFlowGraph.target_node($m, e))
								if target_layer != l and target_layer != l + 1 {
									edge = LayeredFlowGraph.edge($m, e)
									(m1, dummy) = LayeredFlowGraph.add_loose_node($m, { ..LayeredFlowGraph.blank_node, graph: g, kind: LongEdge, origin: EdgeDummy(edge.origin), port_constraints: FixedPos, layer: l + 1 })
									(m2, _) = LayeredFlowLayers.split_edge(m1, e, dummy)
									$m = m2
									$added = $added.append(dummy)
								}
							}
						}
					}
				}
			}
			LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), layers: $new_layers })
		}
	}

	# ---------------------------------------------------------------- ports

	## Ports of nodes free to choose take the side their edges flow through.
	port_sides : Model, U64 -> Model
	port_sides = |m0, g| {
		var $m = m0
		for l in LayeredFlowGraph.graph(m0, g).layers {
			for n in l {
				node = LayeredFlowGraph.node($m, n)
				fixed = node.port_constraints != FreePorts
				for p in node.ports {
					port = LayeredFlowGraph.port($m, p)
					if !fixed or port.side == Undefined {
						side = if port.dummy != LayeredFlowLayers.nil {
							LayeredFlowGraph.node($m, port.dummy).ext_side
						} else if LayeredFlowGraph.net_flow(port) < 0 {
							East
						} else {
							West
						}
						$m = LayeredFlowGraph.set_port($m, p, { ..port, side })
					}
				}
				if !fixed {
					$m = LayeredFlowGraph.set_node($m, n, { ..LayeredFlowGraph.node($m, n), port_constraints: FixedSide })
				}
			}
		}
		$m
	}

	## Edges entering a node's east side or leaving its west side get a
	## dummy in the next or previous layer, so every edge runs east.
	inverted_ports : Model, U64 -> Model
	inverted_ports = |m0, g| {
		var $m = m0
		layers = LayeredFlowGraph.graph(m0, g).layers
		var $unassigned = []
		for l in 0..<layers.len() {
			for d in $unassigned {
				$m = LayeredFlowLayers.set_layer($m, d, l - 1)
			}
			$unassigned = []
			for n in layers.get(l) ?? [] {
				node = LayeredFlowGraph.node($m, n)
				if node.kind == Normal and node.port_constraints != FreePorts {
					for p in node.ports {
						port = LayeredFlowGraph.port($m, p)
						if port.side == East and !port.incoming.is_empty() {
							for e in port.incoming {
								if LayeredFlowGraph.source_node($m, e) != n {
									r = LayeredFlowLayers.inverted_dummy($m, g, e, p, True)
									$m = r.model
									$unassigned = $unassigned.append(r.dummy)
								}
							}
						}
					}
					for p in LayeredFlowGraph.node($m, n).ports {
						port = LayeredFlowGraph.port($m, p)
						if port.side == West and !port.outgoing.is_empty() {
							for e in port.outgoing {
								if LayeredFlowGraph.target_node($m, e) != n {
									r = LayeredFlowLayers.inverted_dummy($m, g, e, p, False)
									$m = r.model
									$unassigned = $unassigned.append(r.dummy)
								}
							}
						}
					}
				}
			}
		}
		last = if (layers.is_empty()) LayeredFlowLayers.nil else layers.len() - 1
		for d in $unassigned {
			$m = LayeredFlowLayers.set_layer($m, d, last)
		}
		$m
	}

	inverted_dummy : Model, U64, U64, U64, Bool -> { model : Model, dummy : U64 }
	inverted_dummy = |m0, g, e, odd_port, east| {
		edge = LayeredFlowGraph.edge(m0, e)
		(m1, dummy) = LayeredFlowGraph.add_loose_node(m0, { ..LayeredFlowGraph.blank_node, graph: g, kind: LongEdge, origin: EdgeDummy(edge.origin), port_constraints: FixedPos })
		(m2, input) = LayeredFlowGraph.add_port(m1, dummy, West)
		(m3, output) = LayeredFlowGraph.add_port(m2, dummy, East)
		original_target = edge.target
		m4 = LayeredFlowGraph.set_target(m3, e, input)
		(m5, _) = LayeredFlowGraph.add_edge(m4, { ..LayeredFlowGraph.edge(m4, e), source: output, target: if (east) odd_port else original_target, labels: [], bends: [] })
		source_port = LayeredFlowGraph.edge(m5, e).source
		source_node = LayeredFlowGraph.node(m5, LayeredFlowGraph.port(m5, source_port).node)
		target_port = if (east) odd_port else original_target
		target_node = LayeredFlowGraph.node(m5, LayeredFlowGraph.port(m5, target_port).node)
		d = LayeredFlowGraph.node(m5, dummy)
		m6 = LayeredFlowGraph.set_node(
			m5,
			dummy,
			{
				..d,
				long_edge_source: if (source_node.kind == LongEdge) source_node.long_edge_source else source_port,
				long_edge_target: if (target_node.kind == LongEdge) target_node.long_edge_target else target_port,
			},
		)
		{ model: m6, dummy }
	}

	## Ports in side order (east before west), as the engine sorts them before
	## ordering: nodes with a fixed order also sort each side by position.
	sort_port_lists : Model, U64 -> Model
	sort_port_lists = |m0, g| {
		var $m = m0
		for l in LayeredFlowGraph.graph(m0, g).layers {
			for n in l {
				node = LayeredFlowGraph.node($m, n)
				side_of = |p| LayeredFlowGraph.side_index(LayeredFlowGraph.port($m, p).side).to_i64_wrap()
				by_side = |a, b| side_of(a) - side_of(b)
				sorted = match node.port_constraints {
					FixedOrder | FixedPos =>
						LayeredFlowGraph.sort_by(
							node.ports,
							|a, b| {
								d = by_side(a, b)
								if d != 0 {
									d
								} else {
									pa = LayeredFlowGraph.port($m, a)
									pb = LayeredFlowGraph.port($m, b)
									cmp = |x, y| if (x < y) -1 else if (x > y) 1 else 0
									match pa.side {
										North => cmp(pa.x, pb.x)
										East => cmp(pa.y, pb.y)
										South => cmp(pb.x, pa.x)
										West => cmp(pb.y, pa.y)
										Undefined => 0
									}
								}
							},
						)
					FixedSide => LayeredFlowLayers.reverse_west_and_south(LayeredFlowGraph.sort_by(node.ports, by_side), |p| LayeredFlowGraph.port($m, p).side)
					FreePorts => node.ports
				}
				$m = LayeredFlowGraph.set_node($m, n, { ..node, ports: sorted })
			}
		}
		$m
	}

	## The engine's reversal of the west and south sides, including its quirk
	## of leaving the last port of a run in place.
	reverse_west_and_south : List(U64), (U64 -> LayeredFlowGraph.Side) -> List(U64)
	reverse_west_and_south = |ports, side_of|
		if ports.len() <= 1 {
			ports
		} else {
			south = LayeredFlowLayers.side_range(ports, side_of, South)
			after_south = LayeredFlowLayers.reverse_range(ports, south.low, south.high)
			west = LayeredFlowLayers.side_range(after_south, side_of, West)
			LayeredFlowLayers.reverse_range(after_south, west.low, west.high)
		}

	side_range : List(U64), (U64 -> LayeredFlowGraph.Side), LayeredFlowGraph.Side -> { low : U64, high : U64 }
	side_range = |ports, side_of, side| {
		ord = |p| LayeredFlowGraph.side_index(side_of(p))
		lb = LayeredFlowGraph.side_index(side)
		hb = lb + 1
		var $low = 0
		var $current = ord(ports.first() ?? 0)
		while $low < ports.len() - 1 and $current < lb {
			$low = $low + 1
			$current = ord(ports.get($low) ?? 0)
		}
		var $high = $low
		while $high < ports.len() - 1 and $current < hb {
			$high = $high + 1
			$current = ord(ports.get($low) ?? 0)
		}
		{ low: $low, high: $high }
	}

	reverse_range : List(U64), U64, U64 -> List(U64)
	reverse_range = |ports, low, high|
		if high <= low + 2 {
			ports
		} else {
			n = (high - low) / 2
			var $out = ports
			for i in 0..<n {
				a = $out.get(low + i) ?? 0
				b = $out.get(high - i - 1) ?? 0
				$out = $out.set(low + i, b) ?? $out
				$out = $out.set(high - i - 1, a) ?? $out
			}
			$out
		}

	# ---------------------------------------------------------------- model order

	## The node an edge leaving `p` finally reaches, past dummies.
	long_edge_target_node : Model, U64 -> U64
	long_edge_target_node = |m, p| {
		var $edge = LayeredFlowGraph.port(m, p).outgoing.first() ?? LayeredFlowLayers.nil
		var $result = LayeredFlowLayers.nil
		var $going = $edge != LayeredFlowLayers.nil
		var $steps = 0
		while $going and $steps < m.nodes.len() + 1 {
			n = LayeredFlowGraph.target_node(m, $edge)
			node = LayeredFlowGraph.node(m, n)
			if node.long_edge_target != LayeredFlowLayers.nil {
				$result = LayeredFlowGraph.port(m, node.long_edge_target).node
				$going = False
			} else if node.kind != Normal {
				outs = LayeredFlowGraph.outgoing(m, n)
				if outs.is_empty() {
					$going = False
				} else {
					$edge = outs.first() ?? LayeredFlowLayers.nil
				}
			} else {
				$result = n
				$going = False
			}
			$steps = $steps + 1
		}
		$result
	}

	model_order_of_edge : Model, U64 -> I64
	model_order_of_edge = |m, e|
		match LayeredFlowGraph.edge(m, e).model_order {
			Some(o) => o
			None => 0
		}

	## Orders recorded so far by a model-order comparison of the items of one
	## list, by their index in it: for each item, the items known to come
	## before it (`bigger` holds them, as the engine names it) and after it,
	## closed transitively as the engine closes them, as bit rows. Whether an
	## item has been seen at all also matters to the engine's checks.
	Relations : { words : U64, bigger : List(U64), smaller : List(U64), has_bigger : List(Bool), has_smaller : List(Bool) }

	relations : U64 -> Relations
	relations = |k| {
		words = (k + 63) / 64
		{ words, bigger: List.repeat(0, k * words), smaller: List.repeat(0, k * words), has_bigger: List.repeat(False, k), has_smaller: List.repeat(False, k) }
	}

	bit_set : List(U64), U64, U64, U64 -> Bool
	bit_set = |rows, words, row, x| ((rows.get(row * words + x / 64) ?? 0).shr_zf_wrap((x % 64).to_u8_wrap()).bitwise_and(1)) == 1

	## Add `x` to a row. Rows are sized for every item, so the index is in
	## range.
	bit_add : List(U64), U64, U64, U64 -> List(U64)
	bit_add = |rows, words, row, x| {
		i = row * words + x / 64
		if i < rows.len() {
			rows.set(i, (rows.get(i) ?? 0).bitwise_or((1).shl_wrap((x % 64).to_u8_wrap()))) ?? []
		} else {
			rows
		}
	}

	## Add every item of row `from` to row `to`.
	bit_union : List(U64), U64, U64, U64 -> List(U64)
	bit_union = |rows0, words, to, from| {
		var $rows = rows0
		for w in 0..<words {
			source = $rows.get(from * words + w) ?? 0
			if source != 0 {
				i = to * words + w
				if i < $rows.len() {
					$rows = $rows.set(i, ($rows.get(i) ?? 0).bitwise_or(source)) ?? []
				}
			}
		}
		$rows
	}

	bit_members : List(U64), U64, U64 -> List(U64)
	bit_members = |rows, words, row| {
		var $out = []
		for w in 0..<words {
			var $word = rows.get(row * words + w) ?? 0
			var $b = 0
			while $word != 0 {
				if $word.bitwise_and(1) == 1 {
					$out = $out.append(w * 64 + $b)
				}
				$word = $word.shr_zf_wrap(1)
				$b = $b + 1
			}
		}
		$out
	}

	set_flag : List(Bool), U64 -> List(Bool)
	set_flag = |flags, i| if (i < flags.len()) flags.set(i, True) ?? [] else flags

	## The comparison prologue shared by both comparators: answers from what
	## is already known, registering both items.
	known : Relations, U64, U64 -> (Relations, [Known(I64), Unknown])
	known = |r0, a, b| {
		w = r0.words
		var $r = r0
		var $answer = Unknown
		if !($r.has_bigger.get(a) ?? True) {
			$r = { ..$r, has_bigger: LayeredFlowLayers.set_flag($r.has_bigger, a) }
		} else if LayeredFlowLayers.bit_set($r.bigger, w, a, b) {
			$answer = Known(1)
		}
		if $answer == Unknown {
			if !($r.has_bigger.get(b) ?? True) {
				$r = { ..$r, has_bigger: LayeredFlowLayers.set_flag($r.has_bigger, b) }
			} else if LayeredFlowLayers.bit_set($r.bigger, w, b, a) {
				$answer = Known(-1)
			}
		}
		if $answer == Unknown {
			if !($r.has_smaller.get(a) ?? True) {
				$r = { ..$r, has_smaller: LayeredFlowLayers.set_flag($r.has_smaller, a) }
			} else if LayeredFlowLayers.bit_set($r.smaller, w, a, b) {
				$answer = Known(-1)
			}
		}
		if $answer == Unknown {
			if !($r.has_smaller.get(b) ?? True) {
				$r = { ..$r, has_smaller: LayeredFlowLayers.set_flag($r.has_smaller, b) }
			} else if ($r.has_bigger.get(b) ?? False) and LayeredFlowLayers.bit_set($r.bigger, w, b, a) {
				# The engine checks `bigger` here, not `smaller`.
				$answer = Known(1)
			}
		}
		($r, $answer)
	}

	## Record that `big` comes after `small`, closing transitively.
	record : Relations, U64, U64 -> Relations
	record = |r, big, small| {
		w = r.words
		small_bigger = LayeredFlowLayers.bit_members(r.bigger, w, small)
		big_smaller = LayeredFlowLayers.bit_members(r.smaller, w, big)
		var $bigger = LayeredFlowLayers.bit_add(r.bigger, w, big, small)
		var $smaller = LayeredFlowLayers.bit_add(r.smaller, w, small, big)
		var $has_bigger = LayeredFlowLayers.set_flag(r.has_bigger, big)
		var $has_smaller = LayeredFlowLayers.set_flag(r.has_smaller, small)
		for very_small in small_bigger {
			$bigger = LayeredFlowLayers.bit_add($bigger, w, big, very_small)
			$smaller = LayeredFlowLayers.bit_add($smaller, w, very_small, big)
			$smaller = LayeredFlowLayers.bit_union($smaller, w, very_small, big)
			$has_smaller = LayeredFlowLayers.set_flag($has_smaller, very_small)
		}
		for very_big in big_smaller {
			$smaller = LayeredFlowLayers.bit_add($smaller, w, small, very_big)
			$bigger = LayeredFlowLayers.bit_add($bigger, w, very_big, small)
			$bigger = LayeredFlowLayers.bit_union($bigger, w, very_big, small)
			$has_bigger = LayeredFlowLayers.set_flag($has_bigger, very_big)
		}
		{ words: w, bigger: $bigger, smaller: $smaller, has_bigger: $has_bigger, has_smaller: $has_smaller }
	}

	cmp_i64 : I64, I64 -> I64
	cmp_i64 = |a, b| if (a < b) -1 else if (a > b) 1 else 0

	## Which of two nodes of the previous layer comes first in it.
	Previous : { layer : U64, layer_of : List(U64), position : List(U64) }

	first_in_previous : Previous, U64, U64 -> [First(U64), Neither]
	first_in_previous = |prev, a, b| {
		in_prev = |x| (prev.layer_of.get(x) ?? LayeredFlowLayers.nil) == prev.layer
		pa = prev.position.get(a) ?? 0
		pb = prev.position.get(b) ?? 0
		if in_prev(a) and in_prev(b) {
			First(if (pa <= pb) a else b)
		} else if in_prev(a) {
			First(a)
		} else if in_prev(b) {
			First(b)
		} else {
			Neither
		}
	}

	## Sort each layer's nodes, and each node's ports, by the order the
	## diagram declared them, as the engine does with model order on.
	sort_by_model_order : Model, U64 -> Model
	sort_by_model_order = |m0, g| {
		var $m = m0
		layers = LayeredFlowGraph.graph(m0, g).layers
		# Each node's layer and place in it, and each port's place on its
		# node, kept current as layers and port lists are sorted.
		var $layer_of = List.repeat(LayeredFlowLayers.nil, m0.nodes.len())
		var $position = List.repeat(0, m0.nodes.len())
		var $port_position = List.repeat(0, m0.ports.len())
		for l in 0..<layers.len() {
			members = layers.get(l) ?? []
			for i in 0..<members.len() {
				n = members.get(i) ?? 0
				if n < $layer_of.len() {
					$layer_of = $layer_of.set(n, l) ?? []
					$position = $position.set(n, i) ?? []
				}
				ports = LayeredFlowGraph.node(m0, n).ports
				for j in 0..<ports.len() {
					p = ports.get(j) ?? 0
					if p < $port_position.len() {
						$port_position = $port_position.set(p, j) ?? []
					}
				}
			}
		}
		for l in 0..<layers.len() {
			prev = { layer: if (l == 0) 0 else l - 1, layer_of: $layer_of, position: $position }
			for n in LayeredFlowGraph.graph($m, g).layers.get(l) ?? [] {
				node = LayeredFlowGraph.node($m, n)
				if node.port_constraints != FixedOrder and node.port_constraints != FixedPos {
					# Targets of outgoing ports and the least edge model order to each.
					var $orders = []
					for p in node.ports {
						if !LayeredFlowGraph.port($m, p).outgoing.is_empty() {
							t = LayeredFlowLayers.long_edge_target_node($m, p)
							$m = LayeredFlowGraph.set_port($m, p, { ..LayeredFlowGraph.port($m, p), long_edge_target_node: t })
							if t != LayeredFlowLayers.nil {
								first = LayeredFlowGraph.port($m, p).outgoing.first() ?? 0
								if !LayeredFlowGraph.edge($m, first).reversed {
									value = LayeredFlowLayers.model_order_of_edge($m, first)
									$orders = match $orders.find_first_index(|o| o.node == t) {
										Ok(i) => $orders.set(i, { node: t, order: value.min(($orders.get(i) ?? { node: t, order: value }).order) }) ?? []
										Err(_) => $orders.append({ node: t, order: value })
									}
								}
							}
						}
					}
					orders = $orders
					mm = $m
					items = node.ports
					# The order recorded for each port's target, if any.
					target_order = items.map(
						|p| {
							t = LayeredFlowGraph.port(mm, p).long_edge_target_node
							match orders.find_first(|o| o.node == t) {
								Ok(o) => Some(o.order)
								Err(_) => None
							}
						},
					)
					(sorted, _) = LayeredFlowGraph.merge_sort(LayeredFlowLayers.upto(items.len()), LayeredFlowLayers.relations(items.len()), |r, i, j| LayeredFlowLayers.compare_ports(mm, prev, items, target_order, r, i, j))
					new_ports = sorted.map(|i| items.get(i) ?? 0)
					$m = LayeredFlowGraph.set_node($m, n, { ..LayeredFlowGraph.node($m, n), ports: new_ports })
					for j in 0..<new_ports.len() {
						p = new_ports.get(j) ?? 0
						if p < $port_position.len() {
							$port_position = $port_position.set(p, j) ?? []
						}
					}
				}
			}
			mm = $m
			items = LayeredFlowGraph.graph(mm, g).layers.get(l) ?? []
			port_position = $port_position
			# What each node's comparison needs: its last incoming port fed
			# from another layer, and the model order of its first incoming
			# edge.
			info = items.map(
				|n| {
					node = LayeredFlowGraph.node(mm, n)
					var $sp = LayeredFlowLayers.nil
					for p in node.ports {
						match LayeredFlowGraph.port(mm, p).incoming.first() {
							Ok(e) => {
								s = LayeredFlowGraph.edge(mm, e).source
								if LayeredFlowGraph.node(mm, LayeredFlowGraph.port(mm, s).node).layer != l {
									$sp = s
								}
							}
							Err(_) => {}
						}
					}
					from_edges = match node.ports.find_first(|p| !LayeredFlowGraph.port(mm, p).incoming.is_empty()) {
						Ok(p) =>
							match LayeredFlowGraph.port(mm, p).incoming.first() {
								Ok(e) => LayeredFlowLayers.model_order_of_edge(mm, e)
								Err(_) => 2147483647
							}
						Err(_) => 2147483647
					}
					{ source_port: $sp, from_edges, model_order: node.model_order }
				},
			)
			(sorted_index, _) = LayeredFlowGraph.merge_sort(LayeredFlowLayers.upto(items.len()), LayeredFlowLayers.relations(items.len()), |r, i, j| LayeredFlowLayers.compare_nodes(mm, prev, port_position, info, r, i, j))
			sorted_nodes = sorted_index.map(|i| items.get(i) ?? 0)
			for i in 0..<sorted_nodes.len() {
				n = sorted_nodes.get(i) ?? 0
				if n < $position.len() {
					$position = $position.set(n, i) ?? []
				}
			}
			graph = LayeredFlowGraph.graph($m, g)
			$m = LayeredFlowGraph.set_graph($m, g, { ..graph, layers: graph.layers.set(l, sorted_nodes) ?? graph.layers })
		}
		$m
	}

	upto : U64 -> List(U64)
	upto = |n| List.repeat(0, n).map_with_index(|_, i| i)

	compare_ports : Model, Previous, List(U64), List([None, Some(I64)]), Relations, U64, U64 -> (Relations, I64)
	compare_ports = |m, previous, items, target_order, r0, i1, i2| {
		(r, prior) = LayeredFlowLayers.known(r0, i1, i2)
		match prior {
			Known(v) => (r, v)
			Unknown => {
				a = LayeredFlowGraph.port(m, items.get(i1) ?? 0)
				b = LayeredFlowGraph.port(m, items.get(i2) ?? 0)
				answer = |big_first, value| if (big_first) (LayeredFlowLayers.record(r, i1, i2), value) else (LayeredFlowLayers.record(r, i2, i1), value)
				if a.side != b.side {
					result = LayeredFlowLayers.cmp_i64(LayeredFlowGraph.side_index(a.side).to_i64_wrap(), LayeredFlowGraph.side_index(b.side).to_i64_wrap())
					answer(result != -1, result)
				} else {
					by_incoming = if !a.incoming.is_empty() and !b.incoming.is_empty() {
						ea = a.incoming.first() ?? 0
						eb = b.incoming.first() ?? 0
						na = LayeredFlowGraph.source_node(m, ea)
						nb = LayeredFlowGraph.source_node(m, eb)
						if na == nb {
							oa = LayeredFlowLayers.model_order_of_edge(m, ea)
							ob = LayeredFlowLayers.model_order_of_edge(m, eb)
							Decided(answer(oa > ob, LayeredFlowLayers.cmp_i64(oa, ob)))
						} else {
							match LayeredFlowLayers.first_in_previous(previous, na, nb) {
								First(x) => if (x == na) Decided(answer(True, 1)) else Decided(answer(False, -1))
								Neither => Undecided
							}
						}
					} else {
						Undecided
					}
					match by_incoming {
						Decided(result) => result
						Undecided =>
							if !a.outgoing.is_empty() and !b.outgoing.is_empty() {
								ta = a.long_edge_target_node
								tb = b.long_edge_target_node
								fa = a.outgoing.first() ?? 0
								fb = b.outgoing.first() ?? 0
								ea = LayeredFlowGraph.edge(m, fa)
								# The engine reads p1's edge for both orders.
								base_a = LayeredFlowLayers.model_order_of_edge(m, fa)
								base_b = if (LayeredFlowGraph.edge(m, fb).model_order != None) base_a else 0
								if ta != LayeredFlowLayers.nil and ta == tb {
									eb = LayeredFlowGraph.edge(m, fb)
									if ea.reversed and !eb.reversed {
										answer(True, 1)
									} else if !ea.reversed and eb.reversed {
										answer(False, -1)
									} else {
										answer(base_a > base_b, LayeredFlowLayers.cmp_i64(base_a, base_b))
									}
								} else {
									oa = match target_order.get(i1) ?? None {
										Some(o) => o
										None => base_a
									}
									ob = match target_order.get(i2) ?? None {
										Some(o) => o
										None => base_b
									}
									answer(oa > ob, LayeredFlowLayers.cmp_i64(oa, ob))
								}
							} else if !a.incoming.is_empty() and !b.outgoing.is_empty() {
								answer(True, 1)
							} else if !a.outgoing.is_empty() and !b.incoming.is_empty() {
								answer(False, -1)
							} else {
								match (a.model_order, b.model_order) {
									(Some(oa), Some(ob)) => answer(oa > ob, LayeredFlowLayers.cmp_i64(oa, ob))
									_ => answer(False, -1)
								}
							}
					}
				}
			}
		}
	}

	NodeInfo : { source_port : U64, from_edges : I64, model_order : [None, Some(I64)] }

	compare_nodes : Model, Previous, List(U64), List(NodeInfo), Relations, U64, U64 -> (Relations, I64)
	compare_nodes = |m, previous, port_position, info, r0, i1, i2| {
		(r, prior) = LayeredFlowLayers.known(r0, i1, i2)
		match prior {
			Known(v) => (r, v)
			Unknown => {
				blank = { source_port: LayeredFlowLayers.nil, from_edges: 2147483647, model_order: None }
				a = info.get(i1) ?? blank
				b = info.get(i2) ?? blank
				answer = |big_first, value| if (big_first) (LayeredFlowLayers.record(r, i1, i2), value) else (LayeredFlowLayers.record(r, i2, i1), value)
				both_ordered = a.model_order != None and b.model_order != None
				if !both_ordered {
					sp1 = a.source_port
					sp2 = b.source_port
					by_source = if sp1 != LayeredFlowLayers.nil and sp2 != LayeredFlowLayers.nil {
						s1 = LayeredFlowGraph.port(m, sp1).node
						s2 = LayeredFlowGraph.port(m, sp2).node
						if s1 == s2 {
							# Whichever port comes first on the shared source.
							if (port_position.get(sp1) ?? 0) <= (port_position.get(sp2) ?? 0) {
								Decided(answer(False, -1))
							} else {
								Decided(answer(True, 1))
							}
						} else {
							match LayeredFlowLayers.first_in_previous(previous, s1, s2) {
								First(x) => if (x == s1) Decided(answer(False, -1)) else Decided(answer(True, 1))
								Neither => Undecided
							}
						}
					} else {
						Undecided
					}
					match by_source {
						Decided(result) => result
						Undecided => answer(a.from_edges > b.from_edges, LayeredFlowLayers.cmp_i64(a.from_edges, b.from_edges))
					}
				} else {
					oa = match a.model_order {
						Some(o) => o
						None => 0
					}
					ob = match b.model_order {
						Some(o) => o
						None => 0
					}
					answer(oa > ob, LayeredFlowLayers.cmp_i64(oa, ob))
				}
			}
		}
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

## Test helper: the drawing's graph of `text`, layered.
test_layered : Str -> { setup : LayeredFlowImport.Setup, model : LayeredFlowGraph.Model }
test_layered = |text| {
	setup = test_setup(text)
	m = setup.model
	{ setup, model: LayeredFlowLayers.prepare(m, 0, LayeredFlowLayers.features(m, 0, False)) }
}

## A cycle's back edge is turned around, and an edge spanning two layers is
## split by a dummy in the layer between. Recorded: ELK puts a, b, c at
## x 12, 204, 396 (layers 0, 1, 2) and routes both a --> c and c --> a
## through layer 1, beside b.
expect {
	r = test_layered("flowchart LR\n    a --> b --> c\n    a --> c\n    c --> a\n")
	m = r.model
	layer = |i| LayeredFlowGraph.node(m, r.setup.node_of.get(i) ?? 0).layer
	middle = LayeredFlowGraph.graph(m, 0).layers.get(1) ?? []
	back = LayeredFlowGraph.edge(m, r.setup.edge_of.get(3) ?? 0)
	layer(0) == 0
		and layer(1) == 1
		and layer(2) == 2
		and middle.len() == 3
		and middle.count_if(|n| LayeredFlowGraph.node(m, n).kind == LongEdge) == 2
		and back.reversed
}

## After layering, every edge runs from one layer to the next.
expect {
	r = test_layered("flowchart LR\n    a --> b --> c --> d\n    a --> d\n    d --> b\n    a -->|go| c\n")
	m = r.model
	m.edges.all(
		|e|
			if e.source == LayeredFlowGraph.nil or e.target == LayeredFlowGraph.nil {
				True
			} else {
				s = LayeredFlowGraph.node(m, LayeredFlowGraph.port(m, e.source).node).layer
				t = LayeredFlowGraph.node(m, LayeredFlowGraph.port(m, e.target).node).layer
				t == s + 1
			},
	)
}

## A labelled edge gets a label node in its middle layer.
expect {
	r = test_layered("flowchart LR\n    a -->|go| b\n")
	m = r.model
	layers = LayeredFlowGraph.graph(m, 0).layers
	layers.len() == 3 and (layers.get(1) ?? []).all(|n| LayeredFlowGraph.node(m, n).kind == Label)
}

## The declared order decides a layer's starting order: r's edges to z, y
## and x were declared in that order.
expect {
	r = test_layered("flowchart LR\n    r --> z\n    r --> y\n    r --> x\n    q --> y\n")
	ids = (LayeredFlowGraph.graph(r.model, 0).layers.get(1) ?? []).map(|n| r.setup.node_of.find_first_index(|x| x == n) ?? 99)
	ids == [1, 2, 3]
}
