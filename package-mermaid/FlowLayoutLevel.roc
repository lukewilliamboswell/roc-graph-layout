import layout.Layered
import layout.Route

## One level of a flowchart layout: the members of the drawing or of one
## subgraph, each already a box, and the edges between them. Everything here
## runs in a downward reading: layers go down the page and members of a layer
## go left to right. The caller turns the result to the level's direction.
##
## The steps follow Mermaid's layout engine: edges that close a cycle are
## found by a depth-first walk in source order and drawn against the flow;
## members get layers; an edge spanning several layers passes through one
## point per layer, its label sitting in the middle layer; members are
## ordered and placed with the layout package's layered layout; then each
## gap between layers gets as many horizontal lanes as its edges need, and
## every edge runs straight down, across in its lane, and down again.
FlowLayoutLevel :: {}.{

	Size : { width : F64, height : F64 }

	Point : { x : F64, y : F64 }

	## Distances between neighbours in a layer (`node_node` between members,
	## `edge_edge` between edges passing through a layer), between layers
	## (`node_layers` between members, `edge_node_layers` between a member and
	## the first lane), and between lanes (`edge_edge`). `loop_depth` is how
	## far a self-loop reaches out from its member.
	Spacing : { node_node : F64, node_layers : F64, edge_node_layers : F64, edge_edge : F64, loop_depth : F64 }

	Edge : { from : U64, to : U64, label : [None, Some(Size)] }

	Loop : { item : U64, label : [None, Some(Size)] }

	## A connection to something outside the level: an edge leaving
	## (`outgoing`) or entering member `item` through the level's bottom or
	## top edge.
	##
	## `key`, when known, is where across the flow the edge meets the
	## outside, in this level's coordinates; ports leave a member in that order.
	Port : { item : U64, outgoing : Bool, key : [None, Some(F64)] }

	Input : { sizes : List(Size), edges : List(Edge), loops : List(Loop), ports : List(Port), spacing : Spacing }

	## Member centres, one route and label centre per edge, one route and
	## label centre per loop, all inside a box from (0, 0) to `size`.
	Result : {
		centers : List(Point),
		routes : List(List(Point)),
		labels : List([None, Some(Point)]),
		loop_routes : List(List(Point)),
		loop_labels : List([None, Some(Point)]),

		## One route per port, from the member's outline to the level's edge.
		port_routes : List(List(Point)),
		size : Size,
	}

	## Space kept between a self-loop and its label.
	loop_label_gap : F64
	loop_label_gap = 4

	## Extra room between a label and the layers beside it.
	label_gap : F64
	label_gap = 2

	## How far ports stay from the ends of a side.
	port_inset : F64
	port_inset = 10

	## The layout package settings for both layered passes. Routing there is
	## unused, so it does no improvement sweeps.
	layered_settings : F64 -> Layered.Settings
	layered_settings = |gap| { ..Layered.default_settings, node_gap: gap, layer_gap: gap, direction: Down, routing: Orthogonal({ ..Route.default_settings, max_sweeps: 0 }) }

	## Edges to draw against the flow: the edges a depth-first walk finds
	## closing a cycle. Walks start at members with no incoming edge, in
	## order, then at any member not yet reached; edges are followed in
	## source order.
	feedback : U64, List({ from : U64, to : U64 }) -> List(Bool)
	feedback = |count, edges| {
		usable = |e| e.from < count and e.to < count and e.from != e.to
		# Outgoing edges grouped by member, in source order.
		var $degree = List.repeat(0, count + 1)
		var $incoming = List.repeat(0, count)
		for e in edges {
			if usable(e) {
				$degree = $degree.set(e.from + 1, ($degree.get(e.from + 1) ?? 0) + 1) ?? []
				$incoming = $incoming.set(e.to, ($incoming.get(e.to) ?? 0) + 1) ?? []
			}
		}
		var $offsets = []
		var $total = 0
		for d in $degree {
			$total = $total + d
			$offsets = $offsets.append($total)
		}
		offsets = $offsets
		var $fill = offsets
		var $out = List.repeat(0, edges.len())
		for i in 0..<edges.len() {
			e = edges.get(i) ?? { from: 0, to: 0 }
			if usable(e) {
				at = $fill.get(e.from) ?? 0
				$out = $out.set(at, i) ?? []
				$fill = $fill.set(e.from, at + 1) ?? []
			}
		}
		out = $out
		incoming = $incoming
		starts = FlowLayoutLevel.upto(count).keep_if(|v| (incoming.get(v) ?? 0) == 0).concat(FlowLayoutLevel.upto(count))
		# 0 unvisited, 1 on the walk, 2 finished.
		var $state = List.repeat(0, count)
		var $reversed = List.repeat(False, edges.len())
		for start in starts {
			if ($state.get(start) ?? 2) == 0 {
				$state = $state.set(start, 1) ?? []
				var $stack = [{ node: start, next: offsets.get(start) ?? 0 }]
				while !$stack.is_empty() {
					top = $stack.last() ?? { node: 0, next: 0 }
					finish = offsets.get(top.node + 1) ?? 0
					if top.next >= finish {
						$state = $state.set(top.node, 2) ?? []
						$stack = $stack.drop_last(1)
					} else {
						$stack = $stack.set($stack.len() - 1, { node: top.node, next: top.next + 1 }) ?? []
						i = out.get(top.next) ?? 0
						target = (edges.get(i) ?? { from: 0, to: 0 }).to
						seen = $state.get(target) ?? 2
						if seen == 1 {
							$reversed = $reversed.set(i, True) ?? []
						} else if seen == 0 {
							$state = $state.set(target, 1) ?? []
							$stack = $stack.append({ node: target, next: offsets.get(target) ?? 0 })
						}
					}
				}
			}
		}
		$reversed
	}

	Kind : [Member, Label, Dummy]

	solve : Input -> Result
	solve = |input| {
		count = input.sizes.len()
		spacing = input.spacing
		sizes = input.sizes.map(|s| { width: FlowLayoutLevel.finite(s.width), height: FlowLayoutLevel.finite(s.height) })
		valid = |e| e.from < count and e.to < count and e.from != e.to
		reversed = FlowLayoutLevel.feedback(count, input.edges.map(|e| { from: e.from, to: e.to }))

		# Room on the left of each member for its self-loops.
		var $loop_counts = List.repeat(0.U64, count)
		var $loop_label_width = List.repeat(0, count)
		for l in input.loops {
			if l.item < count {
				$loop_counts = $loop_counts.set(l.item, ($loop_counts.get(l.item) ?? 0) + 1) ?? []
				match l.label {
					Some(size) => {
						$loop_label_width = $loop_label_width.set(l.item, ($loop_label_width.get(l.item) ?? 0).max(FlowLayoutLevel.finite(size.width))) ?? []
					}
					None => {}
				}
			}
		}
		loop_counts = $loop_counts
		loop_label_width = $loop_label_width
		margins = FlowLayoutLevel.upto(count).map(
			|i|
				if (loop_counts.get(i) ?? 0) == 0 {
					0
				} else {
					label = loop_label_width.get(i) ?? 0
					spacing.loop_depth + (if (label > 0) FlowLayoutLevel.loop_label_gap + label else 0)
				},
		)

		# First pass: layers for members and label nodes.
		var $label_of = List.repeat(None, input.edges.len())
		var $label_sizes = []
		var $first_edges = []
		for i in 0..<input.edges.len() {
			e = input.edges.get(i) ?? { from: 0, to: 0, label: None }
			if valid(e) {
				back = reversed.get(i) ?? False
				a = if (back) e.to else e.from
				b = if (back) e.from else e.to
				match e.label {
					Some(size) => {
						l = count + $label_sizes.len()
						$label_sizes = $label_sizes.append({ width: FlowLayoutLevel.finite(size.width), height: FlowLayoutLevel.finite(size.height) })
						$label_of = $label_of.set(i, Some(l)) ?? []
						$first_edges = $first_edges.append({ from: a, to: l }).append({ from: l, to: b })
					}
					None => {
						$first_edges = $first_edges.append({ from: a, to: b })
					}
				}
			}
		}
		label_sizes = $label_sizes
		label_of = $label_of
		port_base = count + label_sizes.len()
		first_nodes = sizes.map_with_index(|s, i| { width: s.width + (margins.get(i) ?? 0), height: s.height }).concat(label_sizes)
		first_ranks = match Layered.layout({ ..Layered.default_input, graph: { nodes: first_nodes, edges: $first_edges } }, FlowLayoutLevel.layered_settings(spacing.node_node), Layered.default_run) {
			Ok(result) => result.layers
			Err(_) => List.repeat(0, first_nodes.len())
		}
		rank = |v| first_ranks.get(v) ?? 0

		# Chains: each edge as one node per layer, its label in the middle.
		base = port_base
		last_rank = first_ranks.fold(0, |m, r| m.max(r))
		var $dummy_count = 0
		var $chains = []
		for i in 0..<input.edges.len() {
			e = input.edges.get(i) ?? { from: 0, to: 0, label: None }
			if !valid(e) {
				$chains = $chains.append([])
			} else {
				back = reversed.get(i) ?? False
				a = if (back) e.to else e.from
				b = if (back) e.from else e.to
				low = rank(a)
				high = rank(b)
				span = if (high > low) high - low else 1
				label_layer = match label_of.get(i) ?? None {
					Some(_) => Some(low + (span / 2).max(1))
					None => None
				}
				var $chain = [a]
				for step in 1..<span {
					layer = low + step
					match (label_layer, label_of.get(i) ?? None) {
						(Some(at), Some(l)) if at == layer => {
							$chain = $chain.append(l)
						}
						_ => {
							$chain = $chain.append(base + $dummy_count)
							$dummy_count = $dummy_count + 1
						}
					}
				}
				# A label with no layer left for it still sits on its edge.
				chain_with_label = match label_of.get(i) ?? None {
					Some(l) if !$chain.contains(l) => $chain.append(l)
					_ => $chain
				}
				$chains = $chains.append(chain_with_label.append(b))
			}
		}
		# A port reaches the last layer (or the first, coming in) through one
		# point per layer; a member already there connects straight out.
		for p in input.ports {
			if p.item >= count {
				$chains = $chains.append([])
			} else {
				r = rank(p.item)
				steps = if (p.outgoing) last_rank - r else r
				var $chain = [p.item]
				for _ in 0..<steps {
					$chain = $chain.append(base + $dummy_count)
					$dummy_count = $dummy_count + 1
				}
				$chains = $chains.append(if (p.outgoing) $chain else $chain.rev())
			}
		}
		chains = $chains
		dummy_count = $dummy_count
		total = base + dummy_count
		kind = |v| if (v < count) Member else if (v < port_base) Label else Dummy

		# Second pass: order and place every node, edges passing as points.
		inflate = ((spacing.node_node - spacing.edge_edge) / 2).max(0)
		second_nodes = first_nodes.map_with_index(|s, i| if (i < count) { width: s.width + inflate * 2, height: s.height } else s).concat(List.repeat({ width: 0, height: 0 }, dummy_count))
		var $unit = []
		var $weights = []
		for chain in chains {
			for k in 0..<(chain.len().max(1) - 1) {
				u = chain.get(k) ?? 0
				v = chain.get(k + 1) ?? 0
				if kind(u) != Member or kind(v) != Member {
					$weights = $weights.append({ edge: $unit.len(), weight: 8 })
				}
				$unit = $unit.append({ from: u, to: v })
			}
		}
		unit = $unit
		second = Layered.layout({ ..Layered.default_input, graph: { nodes: second_nodes, edges: unit }, edge_weights: $weights }, FlowLayoutLevel.layered_settings(spacing.edge_edge), Layered.default_run)
		placed = match second {
			Ok(result) => { xs: result.layout.positions.map(|p| p.x), layers: result.layers }
			Err(_) => { xs: second_nodes.map_with_index(|_, i| i.to_f64() * 10), layers: List.repeat(0, total) }
		}
		layer_of = |v| placed.layers.get(v) ?? 0
		# Centre of each node's layout box; members sit right of their margin.
		box_x = |v| placed.xs.get(v) ?? 0
		center_x = |v| box_x(v) + (margins.get(v) ?? 0) / 2
		size_of = |v|
			if v < count {
				sizes.get(v) ?? { width: 0, height: 0 }
			} else if v < port_base {
				label_sizes.get(v - count) ?? { width: 0, height: 0 }
			} else {
				{ width: 0, height: 0 }
			}
		layer_count = placed.layers.fold(0, |m, l| m.max(l + 1))
		var $heights = List.repeat(0, layer_count)
		var $has_member = List.repeat(False, layer_count)
		var $has_label = List.repeat(False, layer_count)
		for v in 0..<total {
			l = layer_of(v)
			$heights = $heights.set(l, ($heights.get(l) ?? 0).max(size_of(v).height)) ?? []
			if kind(v) != Dummy {
				$has_member = $has_member.set(l, True) ?? []
			}
			if kind(v) == Label {
				$has_label = $has_label.set(l, True) ?? []
			}
		}
		heights = $heights
		has_member = $has_member
		has_label = $has_label

		# Where the content will start across the flow, to compare positions
		# with ports' keys.
		leftmost = FlowLayoutLevel.upto(base).fold(F64.infinity, |m, v| m.min(center_x(v) - size_of(v).width / 2 - (margins.get(v) ?? 0)))
		shift = if (F64.is_finite(leftmost)) 0 - leftmost else 0
		# Ports: a member's edges leave its bottom and enter its top, spread
		# evenly and ordered by where their other ends are.
		var $out_ports = List.repeat(0, unit.len())
		var $in_ports = List.repeat(0, unit.len())
		var $outgoing = List.repeat([], total)
		var $incoming = List.repeat([], total)
		for k in 0..<unit.len() {
			e = unit.get(k) ?? { from: 0, to: 0 }
			$outgoing = $outgoing.set(e.from, ($outgoing.get(e.from) ?? []).append(k)) ?? []
			$incoming = $incoming.set(e.to, ($incoming.get(e.to) ?? []).append(k)) ?? []
		}
		# Ports of members already in the first or last layer leave straight.
		var $straight_out = List.repeat([], total)
		var $straight_in = List.repeat([], total)
		for j in 0..<input.ports.len() {
			p = input.ports.get(j) ?? { item: 0, outgoing: True, key: None }
			if p.item < count and (chains.get(input.edges.len() + j) ?? []).len() == 1 {
				if p.outgoing {
					$straight_out = $straight_out.set(p.item, ($straight_out.get(p.item) ?? []).append(j)) ?? []
				} else {
					$straight_in = $straight_in.set(p.item, ($straight_in.get(p.item) ?? []).append(j)) ?? []
				}
			}
		}
		var $straight_x = List.repeat(0, input.ports.len())
		for v in 0..<total {
			for side in [Out, In] {
				ks = match side {
					Out => $outgoing.get(v) ?? []
					In => $incoming.get(v) ?? []
				}
				extras = match side {
					Out => $straight_out.get(v) ?? []
					In => $straight_in.get(v) ?? []
				}
				other = |k| {
					e = unit.get(k) ?? { from: 0, to: 0 }
					match side {
						Out => e.to
						In => e.from
					}
				}
				# Edges inside the level and ports to the outside, in one order.
				entries = ks.map(|k| { at: center_x(other(k)) + shift, unit: Some(k), port: 0 }).concat(
					extras.map(
						|j|
							match (input.ports.get(j) ?? { item: 0, outgoing: True, key: None }).key {
								Some(at) => { at, unit: None, port: j }
								None => { at: F64.infinity, unit: None, port: j }
							},
					),
				)
				sorted = entries.map_with_index(|e, i| { e, i }).sort_with(
					|p, q| if (p.e.at < q.e.at) Before else if (p.e.at > q.e.at) After else if (p.i < q.i) Before else if (p.i > q.i) After else Same,
				)
				w = size_of(v).width
				n = sorted.len()
				step = if (kind(v) == Member and w > FlowLayoutLevel.port_inset * 2) (w - FlowLayoutLevel.port_inset * 2) / (n + 1).to_f64() else 0
				left = center_x(v) - w / 2
				for j in 0..<n {
					entry = (sorted.get(j) ?? { e: { at: 0, unit: None, port: 0 }, i: 0 }).e
					x = if (step > 0) left + FlowLayoutLevel.port_inset + step * (j + 1).to_f64() else center_x(v)
					match (entry.unit, side) {
						(Some(k), Out) => {
							$out_ports = $out_ports.set(k, x) ?? []
						}
						(Some(k), In) => {
							$in_ports = $in_ports.set(k, x) ?? []
						}
						(None, _) => {
							$straight_x = $straight_x.set(entry.port, x) ?? []
						}
					}
				}
			}
		}
		straight_x = $straight_x
		out_ports = $out_ports
		in_ports = $in_ports

		# Lanes: every gap routes its bending edges in as few lanes as keep
		# crossings down.
		var $gap_segments = List.repeat([], layer_count)
		for k in 0..<unit.len() {
			e = unit.get(k) ?? { from: 0, to: 0 }
			x1 = out_ports.get(k) ?? 0
			x2 = in_ports.get(k) ?? 0
			if (x1 - x2).abs() > 0.01 {
				g = layer_of(e.from)
				$gap_segments = $gap_segments.set(g, ($gap_segments.get(g) ?? []).append({ edge: k, x1, x2 })) ?? []
			}
		}
		var $slots = List.repeat(0, unit.len())
		var $lane_counts = List.repeat(0, layer_count)
		for g in 0..<layer_count {
			segments = $gap_segments.get(g) ?? []
			assigned = FlowLayoutLevel.assign_lanes(segments.map(|s| { x1: s.x1, x2: s.x2 }))
			for j in 0..<segments.len() {
				s = segments.get(j) ?? { edge: 0, x1: 0, x2: 0 }
				$slots = $slots.set(s.edge, assigned.slots.get(j) ?? 0) ?? []
			}
			$lane_counts = $lane_counts.set(g, assigned.count) ?? []
		}
		slots = $slots
		lane_counts = $lane_counts

		# Layer positions down the page.
		var $tops = []
		var $y = 0
		for l in 0..<layer_count {
			$tops = $tops.append($y)
			lanes = lane_counts.get(l) ?? 0
			label_room = if ((has_label.get(l) ?? False) or (has_label.get(l + 1) ?? False)) FlowLayoutLevel.label_gap else 0
			gap_base = (if ((has_member.get(l) ?? False) and (has_member.get(l + 1) ?? False)) spacing.node_layers else spacing.edge_node_layers) + label_room
			routed = if (lanes > 0) spacing.edge_node_layers * 2 + (lanes - 1).to_f64() * spacing.edge_edge else 0
			$y = $y + (heights.get(l) ?? 0) + gap_base.max(routed)
		}
		tops = $tops
		center_y = |v| {
			l = layer_of(v)
			(tops.get(l) ?? 0) + (heights.get(l) ?? 0) / 2
		}
		top_of = |v|
			match kind(v) {
				Dummy => tops.get(layer_of(v)) ?? 0
				_ => center_y(v) - size_of(v).height / 2
			}
		bottom_of = |v|
			match kind(v) {
				Dummy => {
					l = layer_of(v)
					(tops.get(l) ?? 0) + (heights.get(l) ?? 0)
				}
				_ => center_y(v) + size_of(v).height / 2
			}
		lane_y = |k| {
			e = unit.get(k) ?? { from: 0, to: 0 }
			l = layer_of(e.from)
			(tops.get(l) ?? 0) + (heights.get(l) ?? 0) + spacing.edge_node_layers + (slots.get(k) ?? 0).to_f64() * spacing.edge_edge
		}

		# Routes.
		var $routes = []
		var $unit_at = 0
		for i in 0..<chains.len() {
			chain = chains.get(i) ?? []
			var $points = []
			for j in 0..<(chain.len().max(1) - 1) {
				k = $unit_at
				$unit_at = $unit_at + 1
				e = unit.get(k) ?? { from: 0, to: 0 }
				x1 = out_ports.get(k) ?? 0
				x2 = in_ports.get(k) ?? 0
				start = { x: x1, y: bottom_of(e.from) }
				end = { x: x2, y: top_of(e.to) }
				_ = j
				$points = if (x1 - x2).abs() > 0.01 {
					ly = lane_y(k)
					$points.append(start).append({ x: x1, y: ly }).append({ x: x2, y: ly }).append(end)
				} else {
					$points.append(start).append(end)
				}
			}
			simple = FlowLayoutLevel.simplify($points)
			$routes = $routes.append(if (reversed.get(i) ?? False) simple.rev() else simple)
		}
		routes = $routes.take_first(input.edges.len())
		# Port routes run from the member to the level's edge.
		content_bottom = match layer_count {
			0 => 0
			n => (tops.get(n - 1) ?? 0) + (heights.get(n - 1) ?? 0)
		}
		port_routes = $routes.drop_first(input.edges.len()).map_with_index(
			|r, j| {
				p = input.ports.get(j) ?? { item: 0, outgoing: True, key: None }
				straight = (chains.get(input.edges.len() + j) ?? []).len() == 1
				if p.item >= count {
					[]
				} else if straight {
					x = straight_x.get(j) ?? center_x(p.item)
					if (p.outgoing) [{ x, y: bottom_of(p.item) }, { x, y: content_bottom }] else [{ x, y: top_of(p.item) }, { x, y: 0 }]
				} else if p.outgoing {
					match r.last() {
						Ok(end) => FlowLayoutLevel.simplify(r.append({ x: end.x, y: content_bottom }))
						Err(_) => r
					}
				} else {
					match r.first() {
						Ok(start) => FlowLayoutLevel.simplify([{ x: start.x, y: 0 }].concat(r)).rev()
						Err(_) => r
					}
				}
			},
		)
		labels = input.edges.map_with_index(
			|_, i|
				match label_of.get(i) ?? None {
					Some(l) => Some({ x: center_x(l), y: center_y(l) })
					None => None
				},
		)

		# Self-loops leave and re-enter a member's left side.
		var $loop_seen = List.repeat(0.U64, count)
		var $loop_routes = []
		var $loop_labels = []
		for l in input.loops {
			if l.item >= count {
				$loop_routes = $loop_routes.append([])
				$loop_labels = $loop_labels.append(None)
			} else {
				v = l.item
				size = size_of(v)
				n = (loop_counts.get(v) ?? 1) * 2
				j = $loop_seen.get(v) ?? 0
				$loop_seen = $loop_seen.set(v, j + 1) ?? []
				inset = 12
				step = if (size.height > inset * 2) (size.height - inset * 2) / (n + 1).to_f64() else 0
				top = center_y(v) - size.height / 2
				y1 = if (step > 0) top + inset + step * (j * 2 + 1).to_f64() else center_y(v)
				y2 = if (step > 0) top + inset + step * (j * 2 + 2).to_f64() else center_y(v)
				left = center_x(v) - size.width / 2
				out = left - spacing.loop_depth
				$loop_routes = $loop_routes.append([{ x: left, y: y1 }, { x: out, y: y1 }, { x: out, y: y2 }, { x: left, y: y2 }])
				$loop_labels = $loop_labels.append(
					match l.label {
						Some(label) => Some({ x: out - FlowLayoutLevel.loop_label_gap - FlowLayoutLevel.finite(label.width) / 2, y: center_y(v) })
						None => None
					},
				)
			}
		}
		loop_routes = $loop_routes
		loop_labels = $loop_labels

		# Move everything into a box starting at the origin.
		var $min_x = F64.infinity
		var $min_y = F64.infinity
		var $max_x = 0 - F64.infinity
		var $max_y = 0 - F64.infinity
		for v in 0..<base {
			s = size_of(v)
			left = center_x(v) - s.width / 2 - (margins.get(v) ?? 0)
			$min_x = $min_x.min(left)
			$max_x = $max_x.max(center_x(v) + s.width / 2)
			$min_y = $min_y.min(center_y(v) - s.height / 2)
			$max_y = $max_y.max(center_y(v) + s.height / 2)
		}
		for route in routes.concat(loop_routes).concat(port_routes) {
			for p in route {
				$min_x = $min_x.min(p.x)
				$max_x = $max_x.max(p.x)
				$min_y = $min_y.min(p.y)
				$max_y = $max_y.max(p.y)
			}
		}
		if !F64.is_finite($min_x) or !F64.is_finite($min_y) or !F64.is_finite($max_x) or !F64.is_finite($max_y) {
			{ centers: List.repeat({ x: 0, y: 0 }, count), routes: input.edges.map(|_| []), labels: input.edges.map(|_| None), loop_routes: input.loops.map(|_| []), loop_labels: input.loops.map(|_| None), port_routes: input.ports.map(|_| []), size: { width: 0, height: 0 } }
		} else {
			dx = 0 - $min_x
			dy = 0 - $min_y
			move = |p| { x: FlowLayoutLevel.finite_signed(p.x + dx), y: FlowLayoutLevel.finite_signed(p.y + dy) }
			move_label = |label|
				match label {
					Some(p) => Some(move(p))
					None => None
				}
			{
				centers: FlowLayoutLevel.upto(count).map(|v| move({ x: center_x(v), y: center_y(v) })),
				routes: routes.map(|r| r.map(move)),
				labels: labels.map(move_label),
				loop_routes: loop_routes.map(|r| r.map(move)),
				loop_labels: loop_labels.map(move_label),
				port_routes: port_routes.map(|r| r.map(move)),
				size: { width: FlowLayoutLevel.finite($max_x - $min_x), height: FlowLayoutLevel.finite($max_y - $min_y) },
			}
		}
	}

	## Lanes for the bending edges of one gap. Each edge comes down at `x1`,
	## runs across in its lane and goes on down at `x2`. Of two overlapping
	## edges the one that crosses less when higher gets the higher lane;
	## edges that do not overlap may share a lane.
	assign_lanes : List({ x1 : F64, x2 : F64 }) -> { slots : List(U64), count : U64 }
	assign_lanes = |segments| {
		n = segments.len()
		seg = |i| segments.get(i) ?? { x1: 0, x2: 0 }
		low = |s| s.x1.min(s.x2)
		high = |s| s.x1.max(s.x2)
		within = |x, s| x > low(s) and x < high(s)
		overlap = |a, b| low(a).max(low(b)) < high(a).min(high(b)) + 1
		# above[i] lists the segments that must sit above segment i.
		var $above = List.repeat([], n)
		var $pending = List.repeat(0, n)
		for i in 0..<n {
			for j in (i + 1)..<n {
				a = seg(i)
				b = seg(j)
				if overlap(a, b) {
					a_first = (if (within(a.x2, b)) 1 else 0) + (if (within(b.x1, a)) 1 else 0)
					b_first = (if (within(b.x2, a)) 1 else 0) + (if (within(a.x1, b)) 1 else 0)
					if a_first < b_first {
						$above = $above.set(j, ($above.get(j) ?? []).append(i)) ?? []
						$pending = $pending.set(j, ($pending.get(j) ?? 0) + 1) ?? []
					} else if b_first < a_first {
						$above = $above.set(i, ($above.get(i) ?? []).append(j)) ?? []
						$pending = $pending.set(i, ($pending.get(i) ?? 0) + 1) ?? []
					}
				}
			}
		}
		above = $above
		# Topological order; a cycle is broken at the segment waiting on the
		# fewest others.
		var $done = List.repeat(False, n)
		var $order = []
		var $waiting = $pending
		for _ in 0..<n {
			var $pick = n
			var $fewest = n + 1
			for i in 0..<n {
				if !($done.get(i) ?? True) {
					w = $waiting.get(i) ?? 0
					if w < $fewest {
						$fewest = w
						$pick = i
					}
				}
			}
			if $pick < n {
				$done = $done.set($pick, True) ?? []
				$order = $order.append($pick)
				for j in 0..<n {
					if (above.get(j) ?? []).contains($pick) {
						$waiting = $waiting.set(j, ($waiting.get(j) ?? 1) - 1) ?? []
					}
				}
			}
		}
		var $slots = List.repeat(0, n)
		var $placed = List.repeat(False, n)
		var $count = 0
		for i in $order {
			s = seg(i)
			var $lowest = 0
			for p in above.get(i) ?? [] {
				if $placed.get(p) ?? False {
					$lowest = $lowest.max(($slots.get(p) ?? 0) + 1)
				}
			}
			var $slot = $lowest
			var $searching = True
			while $searching {
				taken = FlowLayoutLevel.upto(n).any(|j| ($placed.get(j) ?? False) and ($slots.get(j) ?? 0) == $slot and overlap(seg(j), s))
				if taken {
					$slot = $slot + 1
				} else {
					$searching = False
				}
			}
			$slots = $slots.set(i, $slot) ?? []
			$placed = $placed.set(i, True) ?? []
			$count = $count.max($slot + 1)
		}
		{ slots: $slots, count: $count }
	}

	## Remove repeated points and points in the middle of a straight run.
	simplify : List(Point) -> List(Point)
	simplify = |points| {
		var $out = []
		for p in points {
			n = $out.len()
			last = $out.last() ?? { x: F64.nan, y: F64.nan }
			if n > 0 and last.x == p.x and last.y == p.y {
				{}
			} else if n >= 2 {
				a = $out.get(n - 2) ?? p
				if (a.x == last.x and last.x == p.x) or (a.y == last.y and last.y == p.y) {
					$out = $out.set(n - 1, p) ?? []
				} else {
					$out = $out.append(p)
				}
			} else {
				$out = $out.append(p)
			}
		}
		$out
	}

	upto : U64 -> List(U64)
	upto = |n| List.repeat(0, n).map_with_index(|_, i| i)

	finite : F64 -> F64
	finite = |value| if (F64.is_finite(value) and value > 0) value else 0

	finite_signed : F64 -> F64
	finite_signed = |value| if (F64.is_finite(value)) value else 0
}

## Edges and ports to the outside leave a member from distinct points, and
## every edge ends where its target is.
expect {
	box = { width: 144, height: 81 }
	result = FlowLayoutLevel.solve({
		sizes: [box, box, box, box],
		edges: [{ from: 0, to: 1, label: None }, { from: 0, to: 2, label: None }],
		loops: [],
		ports: [{ item: 0, outgoing: False, key: None }, { item: 0, outgoing: False, key: None }, { item: 3, outgoing: False, key: None }, { item: 0, outgoing: True, key: None }, { item: 0, outgoing: True, key: None }],
		spacing: { node_node: 50, node_layers: 24, edge_node_layers: 30, edge_edge: 20, loop_depth: 12 },
	})
	ends_at = |route, v| {
		c = result.centers.get(v) ?? { x: -1, y: -1 }
		match route.last() {
			Ok(p) => p.x >= c.x - 72 and p.x <= c.x + 72 and p.y == c.y - 40.5
			Err(_) => False
		}
	}
	starts = result.routes.map(|r| r.first()).concat(result.port_routes.drop_first(3).map(|r| r.first()))
	ends_at(result.routes.get(0) ?? [], 1) and ends_at(result.routes.get(1) ?? [], 2) and starts.len() == 4 and starts.all(|p| starts.count_if(|q| q == p) == 1)
}
