import Flowchart
import FlowLayoutGraph
import FlowLayoutImport
import FlowLayoutLayers
import FlowLayoutLoops
import FlowLayoutOrder

## Where nodes go across the flow, as Mermaid's layout engine places them:
## ports spread along their nodes' sides, each label moved to the middle
## layer its edge spans, then Brandes and Köpf's method: four alignments of
## nodes into blocks along straight edges (up or down, left or right),
## each compacted, then balanced by taking the mean of the two middle
## positions of each node.
FlowLayoutPlace :: {}.{

	Model : FlowLayoutGraph.Model

	nil : U64
	nil = FlowLayoutGraph.nil

	## Spacing of a node's ports from the ends of its side, and the extra
	## room the engine's port cell takes past the node's border.
	ports_surrounding : F64
	ports_surrounding = 12

	label_port_vertical : FlowLayoutGraph.Spacing -> F64
	label_port_vertical = |spacing| spacing.port_port / 10

	## Place ports, set margins, place labels: everything before Brandes and
	## Köpf.
	prepare : Model, U64, Bool -> Model
	prepare = |m0, g, vertical| FlowLayoutPlace.prepare_with_margins(m0, g, vertical, |model, _| model)

	prepare_with_margins : Model, U64, Bool, (Model, U64 -> Model) -> Model
	prepare_with_margins = |m0, g, vertical, apply| {
		m1 = FlowLayoutPlace.place_ports(FlowLayoutLoops.restore(m0, g), g)
		m2 = FlowLayoutLoops.route(apply(FlowLayoutPlace.margins(m1, g), g), g)
		m3 = FlowLayoutPlace.switch_label_dummies(m2, g)
		m4 = FlowLayoutPlace.inline_labels(m3, g)
		_ = vertical
		m4
	}

	# ---------------------------------------------------------------- ports

	## Spread the ports of each ordinary node along its east and west sides:
	## one port in the middle, several evenly between the side's ends.
	place_ports : Model, U64 -> Model
	place_ports = |m0, g| {
		var $m = m0
		spacing = FlowLayoutGraph.graph(m0, g).spacing
		extend = spacing.port_port / 10
		for layer in FlowLayoutGraph.graph(m0, g).layers {
			for n in layer {
				node = FlowLayoutGraph.node($m, n)
				if node.kind == Normal and node.port_constraints != FixedPos {
					for side in [East, West] {
						on_side = node.ports.keep_if(|p| FlowLayoutGraph.port($m, p).side == side)
						# West ports are placed from the bottom of the list.
						ordered = if (side == West) on_side.rev() else on_side
						count = ordered.len()
						rect_y = 0 - extend
						rect_h = node.height + 2 * extend
						available = rect_h - 2 * FlowLayoutPlace.ports_surrounding
						x = if (side == East) node.width else 0
						for k in 0..<count {
							p = ordered.get(k) ?? 0
							# A lone port sits in the middle, or just inside the surrounding
							# margin when the side is too short for it.
							y = if count == 1 and available < 0 {
								rect_y + FlowLayoutPlace.ports_surrounding
							} else if count == 1 {
								node.height / 2
							} else {
								rect_y + FlowLayoutPlace.ports_surrounding + (k + 1).to_f64() * available / (count + 1).to_f64()
							}
							$m = FlowLayoutGraph.set_port($m, p, { ..FlowLayoutGraph.port($m, p), x, y: FlowLayoutPlace.keep_on(node, y, node.height) })
						}
					}
					# North and south ports (self-loops only), clockwise.
					for side in [North, South] {
						on_side = node.ports.keep_if(|p| FlowLayoutGraph.port($m, p).side == side)
						ordered = if (side == South) on_side.rev() else on_side
						count = ordered.len()
						available = node.width - 2 * FlowLayoutPlace.ports_surrounding
						y = if (side == South) node.height else 0
						for k in 0..<count {
							p = ordered.get(k) ?? 0
							x = if (count == 1 and available < 0) FlowLayoutPlace.ports_surrounding else FlowLayoutPlace.ports_surrounding + (k + 1).to_f64() * available / (count + 1).to_f64()
							$m = FlowLayoutGraph.set_port($m, p, { ..FlowLayoutGraph.port($m, p), x: FlowLayoutPlace.keep_on(node, x, node.width), y })
						}
					}
				}
			}
		}
		$m
	}

	## The engine lets ports on a side too short for them run past its
	## ends; a diagram node's ports are kept on the side instead, so every
	## edge meets its node. Only sides shorter than the ports' margins differ.
	keep_on : FlowLayoutGraph.Node, F64, F64 -> F64
	keep_on = |node, value, length|
		match node.origin {
			DiagramNode(_) => value.max(0).min(length)
			_ => value
		}

	## How far ports reach out of each node.
	margins : Model, U64 -> Model
	margins = |m0, g| {
		var $m = m0
		for layer in FlowLayoutGraph.graph(m0, g).layers {
			for n in layer {
				node = FlowLayoutGraph.node($m, n)
				var $left = 0.0
				var $right = 0.0
				var $top = 0.0
				var $bottom = 0.0
				for p in node.ports {
					port = FlowLayoutGraph.port($m, p)
					$left = $left.max(0 - port.x)
					$right = $right.max(port.x + port.width - node.width)
					$top = $top.max(0 - port.y)
					$bottom = $bottom.max(port.y + port.height - node.height)
				}
				# A title is centred across its physical container. ELK's
				# internal title minimum can enlarge the flow axis instead, so
				# its ink may overhang the other axis. Reserve those margins
				# before node placement, just as for ports outside a node.
				inside = if node.nested != FlowLayoutGraph.nil {
					node.nested
				} else {
					node.inner
				}
				if inside != FlowLayoutGraph.nil {
					inner = FlowLayoutGraph.graph($m, inside)
					label_width = match inner.direction {
						Down | Up => inner.title_height
						_ => inner.title_width
					}
					vertical = match FlowLayoutGraph.graph($m, g).direction {
						Down | Up => True
						_ => False
					}
					box_width = if vertical {
						node.height
					} else {
						node.width
					}
					overhang = ((label_width - box_width) / 2).max(0)
					if vertical {
						$top = $top.max(overhang)
						$bottom = $bottom.max(overhang)
					} else {
						$left = $left.max(overhang)
						$right = $right.max(overhang)
					}
				}
				$m = FlowLayoutGraph.set_node($m, n, { ..node, margin: { top: $top, right: $right, bottom: $bottom, left: $left } })
			}
		}
		$m
	}

	# ---------------------------------------------------------------- labels

	## Move each label to the middle layer of the long edge it sits on,
	## swapping places with the long-edge dummy there.
	switch_label_dummies : Model, U64 -> Model
	switch_label_dummies = |m0, g| {
		var $m = m0
		labels = FlowLayoutGraph.graph(m0, g).layers.fold([], |acc, l| acc.concat(l.keep_if(|n| FlowLayoutGraph.node(m0, n).kind == Label)))
		for label in labels {
			# Long-edge dummies before and after the label.
			var $left = []
			var $cur = label
			var $going = True
			var $steps = 0
			while $going and $steps < $m.nodes.len() {
				ins = FlowLayoutGraph.incoming($m, $cur)
				match ins.first() {
					Ok(e) => {
						s = FlowLayoutGraph.source_node($m, e)
						if FlowLayoutGraph.node($m, s).kind == LongEdge {
							$left = [s].concat($left)
							$cur = s
						} else {
							$going = False
						}
					}
					Err(_) => {
						$going = False
					}
				}
				$steps = $steps + 1
			}
			var $right = []
			$cur = label
			$going = True
			$steps = 0
			while $going and $steps < $m.nodes.len() {
				outs = FlowLayoutGraph.outgoing($m, $cur)
				match outs.first() {
					Ok(e) => {
						t = FlowLayoutGraph.target_node($m, e)
						if FlowLayoutGraph.node($m, t).kind == LongEdge {
							$right = $right.append(t)
							$cur = t
						} else {
							$going = False
						}
					}
					Err(_) => {
						$going = False
					}
				}
				$steps = $steps + 1
			}
			total = $left.len() + 1 + $right.len()
			target = (total - 1) / 2
			if target != $left.len() {
				other = if (target < $left.len()) $left.get(target) ?? label else $right.get(target - $left.len() - 1) ?? label
				$m = FlowLayoutPlace.swap_nodes($m, g, label, other)
			}
		}
		$m
	}

	## Swap two dummies' places in their layers, reconnecting their edges.
	swap_nodes : Model, U64, U64, U64 -> Model
	swap_nodes = |m0, g, a, b| {
		na = FlowLayoutGraph.node(m0, a)
		nb = FlowLayoutGraph.node(m0, b)
		layers = FlowLayoutGraph.graph(m0, g).layers
		la = layers.get(na.layer) ?? []
		lb = layers.get(nb.layer) ?? []
		ia = la.find_first_index(|x| x == a) ?? 0
		ib = lb.find_first_index(|x| x == b) ?? 0
		layers1 = layers.set(na.layer, la.set(ia, b) ?? la) ?? layers
		lb1 = layers1.get(nb.layer) ?? []
		layers2 = layers1.set(nb.layer, lb1.set(ib, a) ?? lb1) ?? layers1
		m1 = FlowLayoutGraph.set_graph(m0, g, { ..FlowLayoutGraph.graph(m0, g), layers: layers2 })
		m2 = FlowLayoutGraph.set_node(FlowLayoutGraph.set_node(m1, a, { ..na, layer: nb.layer }), b, { ..nb, layer: na.layer })
		in_port = |m, n| (FlowLayoutGraph.node(m, n).ports.find_first(|p| !FlowLayoutGraph.port(m, p).incoming.is_empty())) ?? FlowLayoutPlace.nil
		out_port = |m, n| (FlowLayoutGraph.node(m, n).ports.find_first(|p| !FlowLayoutGraph.port(m, p).outgoing.is_empty())) ?? FlowLayoutPlace.nil
		ia_port = in_port(m2, a)
		oa_port = out_port(m2, a)
		ib_port = in_port(m2, b)
		ob_port = out_port(m2, b)
		in_a = FlowLayoutGraph.port(m2, ia_port).incoming
		out_a = FlowLayoutGraph.port(m2, oa_port).outgoing
		in_b = FlowLayoutGraph.port(m2, ib_port).incoming
		out_b = FlowLayoutGraph.port(m2, ob_port).outgoing
		var $m = m2
		for e in in_b {
			$m = FlowLayoutGraph.set_target($m, e, ia_port)
		}
		for e in out_b {
			$m = FlowLayoutGraph.set_source($m, e, oa_port)
		}
		for e in in_a {
			$m = FlowLayoutGraph.set_target($m, e, ib_port)
		}
		for e in out_a {
			$m = FlowLayoutGraph.set_source($m, e, ob_port)
		}
		$m
	}

	## Labels sit inline on their edges: the dummy loses the room kept for a
	## label beside the edge, and its ports move to its middle.
	inline_labels : Model, U64 -> Model
	inline_labels = |m0, g| {
		var $m = m0
		spacing = FlowLayoutGraph.graph(m0, g).spacing
		for layer in FlowLayoutGraph.graph(m0, g).layers {
			for n in layer {
				node = FlowLayoutGraph.node($m, n)
				if node.kind == Label {
					thickness = 1.0
					port_y = FlowLayoutPlace.ceil(node.height - spacing.edge_label - thickness) / 2
					$m = FlowLayoutGraph.set_node($m, n, { ..node, height: node.height - spacing.edge_label - thickness })
					for p in node.ports {
						$m = FlowLayoutGraph.set_port($m, p, { ..FlowLayoutGraph.port($m, p), y: port_y })
					}
				}
			}
		}
		$m
	}

	ceil : F64 -> F64
	ceil = |v| 0 - FlowLayoutGraph.floor(0 - v)

	# ---------------------------------------------------------------- Brandes & Köpf

	## Spacing between two neighbours in a layer, by their kinds.
	vertical_spacing : FlowLayoutGraph.Spacing, FlowLayoutGraph.Kind, FlowLayoutGraph.Kind -> F64
	vertical_spacing = |s, a, b| {
		rank = |k|
			match k {
				Normal => 0
				LongEdge => 1
				ExternalPort => 2
				Label => 3
			}
		lo = rank(a).min(rank(b))
		hi = rank(a).max(rank(b))
		match (lo, hi) {
			(0, 0) => s.node_node
			(0, 1) => s.edge_node
			(0, 2) => s.edge_node
			(0, 3) => s.node_node
			(1, 1) => s.edge_edge
			(1, 2) => s.edge_edge
			(1, 3) => s.edge_node
			(2, 2) => s.port_port
			(2, 3) => FlowLayoutPlace.label_port_vertical(s)
			_ => s.edge_edge
		}
	}

	Layout : {
		root : List(U64),
		align : List(U64),
		inner : List(F64),
		block_size : List(F64),
		sink : List(U64),
		shift : List(F64),
		y : List(F64),
		placed : List(Bool),
		down : Bool,
		right : Bool,
		su : List(Bool),
		od : List(Bool),
	}

	Info : {
		## Per node (global index): layer, index in layer.
		layer : List(U64),
		index : List(U64),
		left : List(List({ node : U64, edge : U64 })),
		right : List(List({ node : U64, edge : U64 })),
		layers : List(List(U64)),
		marked : List(Bool),
	}

	neighbours : Model, U64, List(U64), Bool -> List({ node : U64, edge : U64 })
	neighbours = |m, n, index, left| {
		layer = FlowLayoutGraph.node(m, n).layer
		edges = if (left) FlowLayoutGraph.incoming(m, n) else FlowLayoutGraph.outgoing(m, n)
		pairs = edges.keep_if(
			|e| {
				other = if (left) FlowLayoutGraph.source_node(m, e) else FlowLayoutGraph.target_node(m, e)
				!FlowLayoutGraph.is_self_loop(m, e) and FlowLayoutGraph.node(m, other).layer != layer
			},
		).map(|e| { node: if (left) FlowLayoutGraph.source_node(m, e) else FlowLayoutGraph.target_node(m, e), edge: e })
		FlowLayoutGraph.sort_by(
			pairs,
			|a, b| {
				ia = index.get(a.node) ?? 0
				ib = index.get(b.node) ?? 0
				if (ia < ib) -1 else if (ia > ib) 1 else 0
			},
		)
	}

	info : Model, U64 -> Info
	info = |m, g| {
		layers = FlowLayoutGraph.graph(m, g).layers
		var $layer = List.repeat(0, m.nodes.len())
		var $index = List.repeat(0, m.nodes.len())
		for l in 0..<layers.len() {
			layer = layers.get(l) ?? []
			for k in 0..<layer.len() {
				n = layer.get(k) ?? 0
				$layer = $layer.set(n, l) ?? $layer
				$index = $index.set(n, k) ?? $index
			}
		}
		index = $index
		var $left = List.repeat([], m.nodes.len())
		var $right = List.repeat([], m.nodes.len())
		for layer in layers {
			for n in layer {
				$left = $left.set(n, FlowLayoutPlace.neighbours(m, n, index, True)) ?? $left
				$right = $right.set(n, FlowLayoutPlace.neighbours(m, n, index, False)) ?? $right
			}
		}
		base = { layer: $layer, index, left: $left, right: $right, layers, marked: List.repeat(False, m.edges.len()) }
		{ ..base, marked: FlowLayoutPlace.mark_conflicts(m, base) }
	}

	## Inner segments: between two long-edge dummies in neighbouring layers.
	incident_to_inner : Model, Info, U64, U64, U64 -> Bool
	incident_to_inner = |m, ni, n, layer1, layer2|
		if FlowLayoutGraph.node(m, n).kind == LongEdge {
			FlowLayoutGraph.incoming(m, n).any(
				|e| {
					s = FlowLayoutGraph.source_node(m, e)
					FlowLayoutGraph.node(m, s).kind == LongEdge and (ni.layer.get(s) ?? 0) == layer2 and (ni.layer.get(n) ?? 0) == layer1
				},
			)
		} else {
			False
		}

	## Mark edges crossing an inner segment (type 1 conflicts).
	mark_conflicts : Model, Info -> List(Bool)
	mark_conflicts = |m, ni| {
		count = ni.layers.len()
		var $marked = List.repeat(False, m.edges.len())
		if count >= 3 {
			for i in 1..<(count - 1) {
				# The engine walks layer i + 1 by the size of layer i + 1 while
				# reading nodes of layer i + 1.
				layer = ni.layers.get(i + 1) ?? []
				size_i = (ni.layers.get(i) ?? []).len()
				var $k0 = 0
				var $l = 0
				for l1 in 0..<layer.len() {
					v = layer.get(l1) ?? 0
					inner = FlowLayoutPlace.incident_to_inner(m, ni, v, i + 1, i)
					if l1 == layer.len() - 1 or inner {
						k1 = if inner {
							first = (ni.left.get(v) ?? []).first() ?? { node: 0, edge: 0 }
							ni.index.get(first.node) ?? 0
						} else {
							size_i - 1
						}
						while $l <= l1 {
							vl = layer.get($l) ?? 0
							if !FlowLayoutPlace.incident_to_inner(m, ni, vl, i + 1, i) {
								for u in ni.left.get(vl) ?? [] {
									k = ni.index.get(u.node) ?? 0
									if k < $k0 or k > k1 {
										$marked = $marked.set(u.edge, True) ?? $marked
									}
								}
							}
							$l = $l + 1
						}
						$k0 = k1
					}
				}
			}
		}
		$marked
	}

	## Port offset of an edge's ports, for blocks.
	port_y : Model, U64 -> F64
	port_y = |m, p| {
		port = FlowLayoutGraph.port(m, p)
		port.y + port.anchor_y
	}

	## The edge connecting two nodes, as the engine finds it.
	edge_between : Model, U64, U64 -> U64
	edge_between = |m, a, b|
		match FlowLayoutGraph.connected(m, a).find_first(|e| FlowLayoutGraph.target_node(m, e) == b or FlowLayoutGraph.source_node(m, e) == b) {
			Ok(e) => e
			Err(_) => FlowLayoutPlace.nil
		}

	new_layout : U64, Bool, Bool -> Layout
	new_layout = |size, down, right| {
		root: List.repeat(0, size).map_with_index(|_, i| i),
		align: List.repeat(0, size).map_with_index(|_, i| i),
		inner: List.repeat(0, size),
		block_size: List.repeat(0, size),
		sink: List.repeat(0, size).map_with_index(|_, i| i),
		shift: List.repeat(0, size),
		y: List.repeat(0, size),
		placed: List.repeat(False, size),
		down,
		right,
		su: List.repeat(False, size),
		od: List.repeat(True, size),
	}

	vertical_alignment : Model, Info, Layout -> Layout
	vertical_alignment = |m, ni, bal0| {
		var $bal = bal0
		layers = if (bal0.right) ni.layers else ni.layers.rev()
		for layer in layers {
			nodes = if (bal0.down) layer else layer.rev()
			var $r = if (bal0.down) -1 else 2147483647
			for v in nodes {
				neighbors = if (bal0.right) ni.left.get(v) ?? [] else ni.right.get(v) ?? []
				d = neighbors.len()
				if d > 0 {
					low = (d + 1) / 2 - 1
					high = d / 2
					span = if (low == high) [low] else [low, high]
					ms = if (bal0.down) span else span.rev()
					for mi in ms {
						if ($bal.align.get(v) ?? v) == v {
							pair = neighbors.get(mi) ?? { node: 0, edge: 0 }
							u = pair.node
							ui = (ni.index.get(u) ?? 0).to_i64_wrap()
							ok = !(ni.marked.get(pair.edge) ?? False) and (if (bal0.down) $r < ui else $r > ui)
							if ok {
								root_u = $bal.root.get(u) ?? u
								$bal = { ..$bal, align: $bal.align.set(u, v) ?? $bal.align }
								$bal = { ..$bal, root: $bal.root.set(v, root_u) ?? $bal.root }
								$bal = { ..$bal, align: $bal.align.set(v, root_u) ?? $bal.align }
								od_root = $bal.od.get(root_u) ?? True
								$bal = { ..$bal, od: $bal.od.set(root_u, od_root and FlowLayoutGraph.node(m, v).kind == LongEdge) ?? $bal.od }
								$r = ui
							}
						}
					}
				}
			}
		}
		$bal
	}

	inside_block_shift : Model, Info, Layout -> Layout
	inside_block_shift = |m, ni, bal0| {
		var $bal = bal0
		# Roots in layer order, as the engine's blocks map keeps them.
		var $roots = []
		for layer in ni.layers {
			for n in layer {
				r = $bal.root.get(n) ?? n
				if !$roots.contains(r) {
					$roots = $roots.append(r)
				}
			}
		}
		for root in $roots {
			rn = FlowLayoutGraph.node(m, root)
			var $above = rn.margin.top
			var $below = rn.height + rn.margin.bottom
			$bal = { ..$bal, inner: $bal.inner.set(root, 0) ?? $bal.inner }
			var $current = root
			var $guard = 0
			while ($bal.align.get($current) ?? root) != root and $guard < m.nodes.len() {
				next = $bal.align.get($current) ?? root
				e = FlowLayoutPlace.edge_between(m, $current, next)
				edge = FlowLayoutGraph.edge(m, e)
				diff = if $bal.right {
					FlowLayoutPlace.port_y(m, edge.source) - FlowLayoutPlace.port_y(m, edge.target)
				} else {
					FlowLayoutPlace.port_y(m, edge.target) - FlowLayoutPlace.port_y(m, edge.source)
				}
				next_shift = ($bal.inner.get($current) ?? 0) + diff
				$bal = { ..$bal, inner: $bal.inner.set(next, next_shift) ?? $bal.inner }
				nn = FlowLayoutGraph.node(m, next)
				$above = $above.max(nn.margin.top - next_shift)
				$below = $below.max(next_shift + nn.height + nn.margin.bottom)
				$current = next
				$guard = $guard + 1
			}
			$current = root
			var $going = True
			$guard = 0
			while $going and $guard <= m.nodes.len() {
				$bal = { ..$bal, inner: $bal.inner.set($current, ($bal.inner.get($current) ?? 0) + $above) ?? $bal.inner }
				$current = $bal.align.get($current) ?? root
				if $current == root {
					$going = False
				}
				$guard = $guard + 1
			}
			$bal = { ..$bal, block_size: $bal.block_size.set(root, $above + $below) ?? $bal.block_size }
		}
		$bal
	}

	Compaction : {
		bal : Layout,

		## Class graph: per sink node, outgoing (target, separation) and indegree.
		classes : List({ node : U64, out : List({ target : U64, sep : F64 }), indegree : U64, shift : [None, Some(F64)] }),
		finished : List(Bool),
		queue : List({ free : U64, is_root : Bool }),
	}

	class_index : Compaction, U64 -> (Compaction, U64)
	class_index = |c, sink|
		match c.classes.find_first_index(|x| x.node == sink) {
			Ok(i) => (c, i)
			Err(_) => ({ ..c, classes: c.classes.append({ node: sink, out: [], indegree: 0, shift: None }) }, c.classes.len())
		}

	horizontal_compaction : Model, U64, Info, Layout -> Layout
	horizontal_compaction = |m, g, ni, bal0| {
		size = m.nodes.len()
		inf = if (bal0.down) F64.infinity else 0 - F64.infinity
		bal1 = { ..bal0, sink: List.repeat(0, size).map_with_index(|_, i| i), shift: List.repeat(inf, size), placed: List.repeat(False, size), y: List.repeat(0, size) }
		layers = if (bal0.right) ni.layers else ni.layers.rev()
		var $c = { bal: bal1, classes: [], finished: List.repeat(False, size), queue: [] }
		for layer in layers {
			nodes = if (bal0.down) layer else layer.rev()
			for v in nodes {
				if ($c.bal.root.get(v) ?? v) == v {
					$c = FlowLayoutPlace.place_block(m, g, ni, $c, v)
				}
			}
		}
		# Place classes.
		var $classes = $c.classes
		var $queue = []
		for k in 0..<$classes.len() {
			if (($classes.get(k) ?? { node: 0, out: [], indegree: 0, shift: None }).indegree) == 0 {
				$queue = $queue.append(k)
			}
		}
		var $head = 0
		while $head < $queue.len() {
			k = $queue.get($head) ?? 0
			$head = $head + 1
			cls = $classes.get(k) ?? { node: 0, out: [], indegree: 0, shift: None }
			shift = match cls.shift {
				Some(s) => s
				None => 0
			}
			$classes = $classes.set(k, { ..cls, shift: Some(shift) }) ?? $classes
			for e in cls.out {
				t = $classes.get(e.target) ?? cls
				new_shift = match t.shift {
					None => shift + e.sep
					Some(old) => if (bal0.down) old.min(shift + e.sep) else old.max(shift + e.sep)
				}
				left = t.indegree - 1
				$classes = $classes.set(e.target, { ..t, shift: Some(new_shift), indegree: left }) ?? $classes
				if left == 0 {
					$queue = $queue.append(e.target)
				}
			}
		}
		var $bal = $c.bal
		for cls in $classes {
			match cls.shift {
				Some(s) => {
					$bal = { ..$bal, shift: $bal.shift.set(cls.node, s) ?? $bal.shift }
				}
				None => {}
			}
		}
		for layer in layers {
			for v in layer {
				r = $bal.root.get(v) ?? v
				base = $bal.y.get(r) ?? 0
				value = if v == r {
					sink_shift = $bal.shift.get($bal.sink.get(v) ?? v) ?? inf
					if ((bal0.down and sink_shift < F64.infinity) or (!bal0.down and sink_shift > 0 - F64.infinity)) base + sink_shift else base
				} else {
					base
				}
				$bal = { ..$bal, y: $bal.y.set(v, value) ?? $bal.y }
			}
		}
		FlowLayoutPlace.post_process(m, ni, { ..$c, bal: $bal })
	}

	place_block : Model, U64, Info, Compaction, U64 -> Compaction
	place_block = |m, g, ni, c0, root|
		if c0.bal.placed.get(root) ?? True {
			c0
		} else {
			spacing_of = FlowLayoutGraph.graph(m, g).spacing
			var $c = { ..c0, bal: { ..c0.bal, placed: c0.bal.placed.set(root, True) ?? c0.bal.placed, y: c0.bal.y.set(root, 0) ?? c0.bal.y } }
			var $initial = True
			var $current = root
			down = c0.bal.down
			var $thresh = if (down) 0 - F64.infinity else F64.infinity
			var $going = True
			var $guard = 0
			while $going and $guard <= m.nodes.len() {
				index = ni.index.get($current) ?? 0
				layer = ni.layers.get(ni.layer.get($current) ?? 0) ?? []
				has_neighbor = if (down) index > 0 else index + 1 < layer.len()
				if has_neighbor {
					neighbor = layer.get(if (down) index - 1 else index + 1) ?? 0
					neighbor_root = $c.bal.root.get(neighbor) ?? neighbor
					$c = FlowLayoutPlace.place_block(m, g, ni, $c, neighbor_root)
					(c1, t) = FlowLayoutPlace.threshold(m, $c, $thresh, root, $current)
					$c = c1
					$thresh = t
					if ($c.bal.sink.get(root) ?? root) == root {
						$c = { ..$c, bal: { ..$c.bal, sink: $c.bal.sink.set(root, $c.bal.sink.get(neighbor_root) ?? neighbor_root) ?? $c.bal.sink } }
					}
					bal = $c.bal
					cur = FlowLayoutGraph.node(m, $current)
					nb = FlowLayoutGraph.node(m, neighbor)
					y_of = |x| bal.y.get(x) ?? 0
					inner_of = |x| bal.inner.get(x) ?? 0
					if (bal.sink.get(root) ?? root) == (bal.sink.get(neighbor_root) ?? neighbor_root) {
						spacing = FlowLayoutPlace.vertical_spacing(spacing_of, cur.kind, nb.kind)
						current_pos = y_of(root)
						new_value = if down {
							pos = y_of(neighbor_root) + inner_of(neighbor) + nb.height + nb.margin.bottom + spacing + cur.margin.top - inner_of($current)
							if ($initial) pos.max($thresh) else current_pos.max(pos.max($thresh))
						} else {
							pos = y_of(neighbor_root) + inner_of(neighbor) - nb.margin.top - spacing - cur.margin.bottom - cur.height - inner_of($current)
							if ($initial) pos.min($thresh) else current_pos.min(pos.min($thresh))
						}
						$initial = False
						$c = { ..$c, bal: { ..bal, y: bal.y.set(root, new_value) ?? bal.y } }
					} else {
						spacing = spacing_of.node_node
						required = if down {
							y_of(root) + inner_of($current) - cur.margin.top - y_of(neighbor_root) - inner_of(neighbor) - nb.height - nb.margin.bottom - spacing
						} else {
							y_of(root) + inner_of($current) + cur.height + cur.margin.bottom + spacing - (y_of(neighbor_root) + inner_of(neighbor) - nb.margin.top)
						}
						(c2, si) = FlowLayoutPlace.class_index($c, bal.sink.get(root) ?? root)
						(c3, ti) = FlowLayoutPlace.class_index(c2, bal.sink.get(neighbor_root) ?? neighbor_root)
						source_cls = c3.classes.get(si) ?? { node: 0, out: [], indegree: 0, shift: None }
						c4 = { ..c3, classes: c3.classes.set(si, { ..source_cls, out: source_cls.out.append({ target: ti, sep: required }) }) ?? c3.classes }
						target_cls = c4.classes.get(ti) ?? source_cls
						$c = { ..c4, classes: c4.classes.set(ti, { ..target_cls, indegree: target_cls.indegree + 1 }) ?? c4.classes }
					}
				} else {
					(c1, t) = FlowLayoutPlace.threshold(m, $c, $thresh, root, $current)
					$c = c1
					$thresh = t
				}
				$current = $c.bal.align.get($current) ?? root
				if $current == root {
					$going = False
				}
				$guard = $guard + 1
			}
			{ ..$c, finished: $c.finished.set(root, True) ?? $c.finished }
		}

	## The simple threshold strategy: a block's first and last node look for
	## an edge to an already placed block and straighten it if they can.
	threshold : Model, Compaction, F64, U64, U64 -> (Compaction, F64)
	threshold = |m, c, old, root, current| {
		is_root = root == current
		is_last = (c.bal.align.get(current) ?? root) == root
		if !(is_root or is_last) {
			(c, old)
		} else {
			var $c = c
			var $t = old
			if is_root {
				(c1, b) = FlowLayoutPlace.bound(m, $c, root, True)
				$c = c1
				$t = b
			}
			if !F64.is_finite($t) and is_last {
				(c2, b2) = FlowLayoutPlace.bound(m, $c, current, False)
				$c = c2
				$t = b2
			}
			($c, $t)
		}
	}

	## Pick the edge a block end straightens: returns (has edges, edge).
	pick_edge : Model, Compaction, U64, Bool -> { has_edges : Bool, edge : U64 }
	pick_edge = |m, c, free, is_root| {
		edges = if is_root {
			if (c.bal.right) FlowLayoutGraph.incoming(m, free) else FlowLayoutGraph.outgoing(m, free)
		} else if !c.bal.right {
			FlowLayoutGraph.incoming(m, free)
		} else {
			FlowLayoutGraph.outgoing(m, free)
		}
		free_root = c.bal.root.get(free) ?? free
		only_dummies = c.bal.od.get(free_root) ?? True
		var $has = False
		var $found = FlowLayoutPlace.nil
		for e in edges {
			if $found == FlowLayoutPlace.nil {
				in_layer = FlowLayoutGraph.node(m, FlowLayoutGraph.source_node(m, e)).layer == FlowLayoutGraph.node(m, FlowLayoutGraph.target_node(m, e)).layer
				if (only_dummies or !in_layer) and !(c.bal.su.get(free_root) ?? False) {
					$has = True
					other = if (FlowLayoutGraph.source_node(m, e) == free) FlowLayoutGraph.target_node(m, e) else FlowLayoutGraph.source_node(m, e)
					if c.finished.get(c.bal.root.get(other) ?? other) ?? False {
						$found = e
					}
				}
			}
		}
		{ has_edges: $has or $found != FlowLayoutPlace.nil, edge: $found }
	}

	bound : Model, Compaction, U64, Bool -> (Compaction, F64)
	bound = |m, c, block_node, is_root| {
		invalid = if (c.bal.down) 0 - F64.infinity else F64.infinity
		pick = FlowLayoutPlace.pick_edge(m, c, block_node, is_root)
		if pick.edge == FlowLayoutPlace.nil and pick.has_edges {
			({ ..c, queue: c.queue.append({ free: block_node, is_root }) }, invalid)
		} else if pick.edge != FlowLayoutPlace.nil {
			edge = FlowLayoutGraph.edge(m, pick.edge)
			left = edge.source
			right = edge.target
			(root_port, other_port) = if is_root {
				if (c.bal.right) (right, left) else (left, right)
			} else if !c.bal.right {
				(right, left)
			} else {
				(left, right)
			}
			bal = c.bal
			other_node = FlowLayoutGraph.port(m, other_port).node
			root_node = FlowLayoutGraph.port(m, root_port).node
			t = (bal.y.get(bal.root.get(other_node) ?? other_node) ?? 0)
				+ (bal.inner.get(other_node) ?? 0)
				+ FlowLayoutPlace.port_y(m, other_port)
				- (bal.inner.get(root_node) ?? 0)
				- FlowLayoutPlace.port_y(m, root_port)
			ln = FlowLayoutGraph.port(m, left).node
			rn = FlowLayoutGraph.port(m, right).node
			su1 = bal.su.set(bal.root.get(ln) ?? ln, True) ?? bal.su
			su2 = su1.set(bal.root.get(rn) ?? rn, True) ?? su1
			({ ..c, bal: { ..bal, su: su2 } }, t)
		} else {
			(c, invalid)
		}
	}

	post_process : Model, Info, Compaction -> Layout
	post_process = |m, ni, c0| {
		var $c = c0
		var $stack = []
		var $head = 0
		while $head < $c.queue.len() {
			pp = $c.queue.get($head) ?? { free: 0, is_root: False }
			$head = $head + 1
			pick = FlowLayoutPlace.pick_edge(m, $c, pp.free, pp.is_root)
			if pick.edge != FlowLayoutPlace.nil {
				free_root = $c.bal.root.get(pp.free) ?? pp.free
				only_dummies = $c.bal.od.get(free_root) ?? True
				in_layer = FlowLayoutGraph.node(m, FlowLayoutGraph.source_node(m, pick.edge)).layer == FlowLayoutGraph.node(m, FlowLayoutGraph.target_node(m, pick.edge)).layer
				if only_dummies or !in_layer {
					(bal, moved) = FlowLayoutPlace.straighten(m, ni, $c.bal, pp.free, pick.edge)
					$c = { ..$c, bal }
					if !moved {
						$stack = $stack.append({ free: pp.free, edge: pick.edge })
					}
				}
			}
		}
		var $k = $stack.len()
		while $k > 0 {
			$k = $k - 1
			item = $stack.get($k) ?? { free: 0, edge: 0 }
			(bal, _) = FlowLayoutPlace.straighten(m, ni, $c.bal, item.free, item.edge)
			$c = { ..$c, bal }
		}
		$c.bal
	}

	straighten : Model, Info, Layout, U64, U64 -> (Layout, Bool)
	straighten = |m, ni, bal, free, e| {
		edge = FlowLayoutGraph.edge(m, e)
		free_is_source = FlowLayoutGraph.port(m, edge.source).node == free
		fix = if (free_is_source) edge.target else edge.source
		block = if (free_is_source) edge.source else edge.target
		pos = |p| {
			n = FlowLayoutGraph.port(m, p).node
			(bal.y.get(n) ?? 0) + (bal.inner.get(n) ?? 0) + FlowLayoutPlace.port_y(m, p)
		}
		delta = pos(block) - pos(fix)
		block_node = FlowLayoutGraph.port(m, block).node
		if delta > 0 and delta < 1.7976931348623157e308 {
			available = FlowLayoutPlace.space_above(m, ni, bal, block_node, delta)
			(FlowLayoutPlace.shift_block(bal, block_node, 0 - available), available > 0)
		} else if delta < 0 and 0 - delta < 1.7976931348623157e308 {
			available = FlowLayoutPlace.space_below(m, ni, bal, block_node, 0 - delta)
			(FlowLayoutPlace.shift_block(bal, block_node, available), available > 0)
		} else {
			(bal, False)
		}
	}

	shift_block : Layout, U64, F64 -> Layout
	shift_block = |bal, start, delta| {
		var $y = bal.y
		var $current = start
		var $going = True
		var $guard = 0
		while $going and $guard <= bal.y.len() {
			$y = $y.set($current, ($y.get($current) ?? 0) + delta) ?? $y
			$current = bal.align.get($current) ?? start
			if $current == start {
				$going = False
			}
			$guard = $guard + 1
		}
		{ ..bal, y: $y }
	}

	min_y : Model, Layout, U64 -> F64
	min_y = |m, bal, n| (bal.y.get(bal.root.get(n) ?? n) ?? 0) + (bal.inner.get(n) ?? 0) - FlowLayoutGraph.node(m, n).margin.top

	max_y : Model, Layout, U64 -> F64
	max_y = |m, bal, n| {
		node = FlowLayoutGraph.node(m, n)
		(bal.y.get(bal.root.get(n) ?? n) ?? 0) + (bal.inner.get(n) ?? 0) + node.height + node.margin.bottom
	}

	space_above : Model, Info, Layout, U64, F64 -> F64
	space_above = |m, ni, bal, block_root, delta| {
		var $available = delta
		var $current = block_root
		var $going = True
		var $guard = 0
		while $going and $guard <= m.nodes.len() {
			$current = bal.align.get($current) ?? block_root
			index = ni.index.get($current) ?? 0
			if index > 0 {
				layer = ni.layers.get(ni.layer.get($current) ?? 0) ?? []
				neighbor = layer.get(index - 1) ?? 0
				spacing = FlowLayoutPlace.vertical_spacing(FlowLayoutGraph.graph(m, FlowLayoutGraph.node(m, $current).graph).spacing, FlowLayoutGraph.node(m, $current).kind, FlowLayoutGraph.node(m, neighbor).kind)
				$available = $available.min(FlowLayoutPlace.min_y(m, bal, $current) - (FlowLayoutPlace.max_y(m, bal, neighbor) + spacing))
			}
			if $current == block_root {
				$going = False
			}
			$guard = $guard + 1
		}
		$available
	}

	space_below : Model, Info, Layout, U64, F64 -> F64
	space_below = |m, ni, bal, block_root, delta| {
		var $available = delta
		var $current = block_root
		var $going = True
		var $guard = 0
		while $going and $guard <= m.nodes.len() {
			$current = bal.align.get($current) ?? block_root
			index = ni.index.get($current) ?? 0
			layer = ni.layers.get(ni.layer.get($current) ?? 0) ?? []
			if index + 1 < layer.len() {
				neighbor = layer.get(index + 1) ?? 0
				spacing = FlowLayoutPlace.vertical_spacing(FlowLayoutGraph.graph(m, FlowLayoutGraph.node(m, $current).graph).spacing, FlowLayoutGraph.node(m, $current).kind, FlowLayoutGraph.node(m, neighbor).kind)
				$available = $available.min(FlowLayoutPlace.min_y(m, bal, neighbor) - (FlowLayoutPlace.max_y(m, bal, $current) + spacing))
			}
			if $current == block_root {
				$going = False
			}
			$guard = $guard + 1
		}
		$available
	}

	layout_size : Info, Layout -> F64
	layout_size = |ni, bal| {
		var $min = F64.infinity
		var $max = 0 - F64.infinity
		for layer in ni.layers {
			for n in layer {
				y = bal.y.get(n) ?? 0
				$min = $min.min(y)
				$max = $max.max(y + (bal.block_size.get(bal.root.get(n) ?? n) ?? 0))
			}
		}
		$max - $min
	}

	feasible : Model, Info, List(F64) -> Bool
	feasible = |m, ni, ys| {
		var $ok = True
		for layer in ni.layers {
			var $pos = 0 - F64.infinity
			for n in layer {
				if $ok {
					node = FlowLayoutGraph.node(m, n)
					y = ys.get(n) ?? 0
					top = y - node.margin.top
					bottom = y + node.height + node.margin.bottom
					if top > $pos and bottom > $pos {
						$pos = y + node.height + node.margin.bottom
					} else {
						$ok = False
					}
				}
			}
		}
		$ok
	}

	## Brandes and Köpf on one graph: sets each node's `y`.
	brandes_koepf : Model, U64 -> Model
	brandes_koepf = |m0, g| {
		ni = FlowLayoutPlace.info(m0, g)
		size = m0.nodes.len()
		kinds = [{ down: True, right: True }, { down: False, right: True }, { down: True, right: False }, { down: False, right: False }]
		aligned = kinds.map(
			|k| {
				bal = FlowLayoutPlace.vertical_alignment(m0, ni, FlowLayoutPlace.new_layout(size, k.down, k.right))
				FlowLayoutPlace.inside_block_shift(m0, ni, bal)
			},
		)
		layouts = aligned.map(|bal| FlowLayoutPlace.horizontal_compaction(m0, g, ni, bal))
		# Positions per layout: block position plus inner shift.
		positions = layouts.map(|bal| List.repeat(0, size).map_with_index(|_, n| (bal.y.get(n) ?? 0) + (bal.inner.get(n) ?? 0)))
		widths = layouts.map(|bal| FlowLayoutPlace.layout_size(ni, bal))
		var $min_layout = 0
		for i in 0..<widths.len() {
			if (widths.get($min_layout) ?? 0) > (widths.get(i) ?? 0) {
				$min_layout = i
			}
		}
		all_nodes = ni.layers.fold([], |acc, l| acc.concat(l))
		extent = |ys| {
			var $lo = 2147483647.0
			var $hi = -2147483648.0
			for n in all_nodes {
				y = ys.get(n) ?? 0
				$lo = $lo.min(y)
				$hi = $hi.max(y + FlowLayoutGraph.node(m0, n).height)
			}
			{ lo: $lo, hi: $hi }
		}
		extents = positions.map(extent)
		base = extents.get($min_layout) ?? { lo: 0, hi: 0 }
		shifts = extents.map_with_index(|e, i| if ((kinds.get(i) ?? { down: True, right: True }).down) base.lo - e.lo else base.hi - e.hi)
		var $balanced = List.repeat(0, size)
		for n in all_nodes {
			values = positions.map_with_index(|ys, i| (ys.get(n) ?? 0) + (shifts.get(i) ?? 0))
			sorted = FlowLayoutGraph.sort_by(values, |a, b| if (a < b) -1 else if (a > b) 1 else 0)
			$balanced = $balanced.set(n, ((sorted.get(1) ?? 0) + (sorted.get(2) ?? 0)) / 2) ?? $balanced
		}
		chosen = if FlowLayoutPlace.feasible(m0, ni, $balanced) {
			$balanced
		} else {
			# The narrowest feasible alignment, else the first.
			var $best = None
			for i in 0..<positions.len() {
				ys = positions.get(i) ?? []
				if FlowLayoutPlace.feasible(m0, ni, ys) {
					w = widths.get(i) ?? 0
					$best = match $best {
						None => Some({ ys, w })
						Some(b) => if (b.w > w) Some({ ys, w }) else Some(b)
					}
				}
			}
			match $best {
				Some(b) => b.ys
				None => positions.first() ?? []
			}
		}
		var $m = m0
		for n in all_nodes {
			$m = FlowLayoutGraph.set_node($m, n, { ..FlowLayoutGraph.node($m, n), y: chosen.get(n) ?? 0 })
		}
		$m
	}
}

## Test helper: a diagram's working graph with every node 152 by 41, edge
## labels 31.27 by 17 and titles 10 by 17, as Mermaid measured the recorded
## runs these tests take their expected values from.
test_setup : Str -> FlowLayoutImport.Setup
test_setup = |text| {
	diagram = match Flowchart.parse(text) {
		Ok(d) => d
		Err(_) => { direction: Right, nodes: [], edges: [], groups: [], classes: [] }
	}
	box = { width: 152, height: 41, label: { lines: [], width: 0, height: 0 } }
	sizes = {
		nodes: List.repeat(box, diagram.nodes.len()),
		edge_labels: diagram.edges.map(|e| if (e.label.is_empty()) None else Some({ lines: [], width: 31.26953125, height: 17 })),
		group_titles: List.repeat({ lines: [], width: 10, height: 17 }, diagram.groups.len()),
	}
	FlowLayoutImport.build(diagram, sizes)
}

## Test helper: the drawing's graph of `text`, layered, ordered and with
## nodes placed across the flow.
test_placed : Str -> { setup : FlowLayoutImport.Setup, model : FlowLayoutGraph.Model }
test_placed = |text| {
	setup = test_setup(text)
	m0 = setup.model
	m1 = FlowLayoutLayers.prepare(m0, 0, FlowLayoutLayers.features(m0, 0, False))
	m2 = FlowLayoutOrder.minimize(m1, True)
	m3 = FlowLayoutPlace.prepare(m2, 0, False)
	{ setup, model: FlowLayoutPlace.brandes_koepf(m3, 0) }
}

## Balanced placement of a diamond: the fan's middle node lines up with both
## ends, the others 81 either side. Recorded: ELK places a, b, c, d, e at
## y 93, 12, 93, 174, 93.
expect {
	r = test_placed("flowchart LR\n    a --> b\n    a --> c\n    a --> d\n    b --> e\n    c --> e\n    d --> e\n")
	y = |i| FlowLayoutGraph.node(r.model, r.setup.node_of.get(i) ?? 0).y
	y(1) - y(0) == -81 and y(2) == y(0) and y(3) - y(0) == 81 and y(4) == y(0)
}

## Ports spread evenly along a side between its margins. Recorded: ELK
## puts a's two ports 17 and 24 below its top (a node 41 high).
expect {
	r = test_placed("flowchart LR\n    a --> d\n    b --> c\n    a --> c\n    b --> d\n")
	m = r.model
	a = FlowLayoutGraph.node(m, r.setup.node_of.get(0) ?? 0)
	ys = a.ports.map(|p| FlowLayoutGraph.port(m, p).y)
	FlowLayoutGraph.sort_by(ys, |p, q| if (p < q) -1 else if (p > q) 1 else 0) == [17, 24]
}

## A lone port on a side too short for the ports' margins sits just inside
## the margin rather than in the middle. Recorded: ELK puts the port of an
## empty subgraph (a box of no size) 10 along its side.
expect {
	r = test_placed("flowchart TD\n    a --> e\n    subgraph e [E]\n    end\n")
	m = r.model
	e = FlowLayoutGraph.node(m, r.setup.group_node.get(0) ?? 0)
	e.ports.map(|p| FlowLayoutGraph.port(m, p).y) == [10]
}

## Oracle regression: multiline-flow's 497.484375px title overhangs the
## actual 479px ELK container by 9.2421875px on each side. Those margins
## belong to placement, before balancing and root bounds are computed.
expect
	[Down, Up, Right, Left].all(
		|direction| {
			vertical = match direction {
				Down | Up => True
				_ => False
			}
			node = {
				..FlowLayoutGraph.blank_node,
				nested: 1,
				width: if vertical {
					507.484375
				} else {
					479
				},
				height: if vertical {
					479
				} else {
					507.484375
				},
			}
			outer = { ..FlowLayoutGraph.blank_graph, direction, layers: [[0]], nodes: [0] }
			inner = { ..FlowLayoutGraph.blank_graph, direction: Down, parent: 0, title_width: 15.021484375, title_height: 497.484375 }
			m = { graphs: [outer, inner], nodes: [node], ports: [], edges: [], loops: [] }
			margin = FlowLayoutGraph.node(FlowLayoutPlace.margins(m, 0), 0).margin
			if vertical {
				margin == { top: 9.2421875, bottom: 9.2421875, left: 0, right: 0 }
			} else {
				margin == { top: 0, bottom: 0, left: 9.2421875, right: 9.2421875 }
			}
		},
	)

## An unpainted note-group title has no width and reserves no ink margin.
expect {
	node = { ..FlowLayoutGraph.blank_node, nested: 1, width: 100, height: 100 }
	outer = { ..FlowLayoutGraph.blank_graph, direction: Down, layers: [[0]], nodes: [0] }
	inner = { ..FlowLayoutGraph.blank_graph, direction: Down, parent: 0, title_width: 20, title_height: 0 }
	m = { graphs: [outer, inner], nodes: [node], ports: [], edges: [], loops: [] }
	FlowLayoutGraph.node(FlowLayoutPlace.margins(m, 0), 0).margin == FlowLayoutGraph.no_box
}
