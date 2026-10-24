import FlowLayoutGraph

## Self-loops, as Mermaid's layout engine draws them: taken out of the graph
## while it is layered and ordered, then put back on their node's north side
## in the layout's reading (above it in a left-to-right diagram), stacked one
## lane further out each, with the node keeping room for them and their
## labels.
FlowLayoutLoops :: {}.{

	Model : FlowLayoutGraph.Model

	Loop : FlowLayoutGraph.Loop

	nil : U64
	nil = FlowLayoutGraph.nil

	clockwise : FlowLayoutGraph.Side -> FlowLayoutGraph.Side
	clockwise = |side|
		match side {
			North => East
			East => South
			South => West
			West => North
			Undefined => Undefined
		}

	counter_clockwise : FlowLayoutGraph.Side -> FlowLayoutGraph.Side
	counter_clockwise = |side|
		match side {
			North => West
			West => South
			South => East
			East => North
			Undefined => Undefined
		}

	side_slot : FlowLayoutGraph.Side -> U64
	side_slot = |side|
		match side {
			North => 0
			East => 1
			South => 2
			West => 3
			Undefined => 0
		}

	## Take self-loops out of a graph before layering: each becomes a loop of
	## its node, and its ports leave the node.
	hide : Model, U64 -> Model
	hide = |m0, g| {
		var $m = m0
		for n in FlowLayoutGraph.graph(m0, g).nodes {
			node = FlowLayoutGraph.node($m, n)
			if node.kind == Normal {
				for e in FlowLayoutGraph.outgoing($m, n) {
					if FlowLayoutGraph.is_self_loop($m, e) {
						edge = FlowLayoutGraph.edge($m, e)
						label = match edge.labels.first() {
							Ok(l) => Some({ width: l.width, height: l.height })
							Err(_) => None
						}
						ports = [edge.source, edge.target]
						loop = {
							node: n,
							edge: e,
							ports,
							hidden: False,
							label,
							leftmost: FlowLayoutLoops.nil,
							rightmost: FlowLayoutLoops.nil,
							occupied: [],
							slots: [0, 0, 0, 0],
							label_side: Undefined,
							label_alignment: Center,
							label_reference: FlowLayoutLoops.nil,
							label_x: 0,
							label_y: 0,
						}
						before = $m
						only_loops = ports.all(
							|p| {
								port = FlowLayoutGraph.port(before, p)
								port.incoming.concat(port.outgoing).all(|x| FlowLayoutGraph.is_self_loop(before, x))
							},
						)
						m1 = FlowLayoutGraph.set_target(FlowLayoutGraph.set_source($m, e, FlowLayoutLoops.nil), e, FlowLayoutLoops.nil)
						# Ports that had only self-loops leave the node while it is laid out.
						hidden = node.port_constraints == FreePorts and only_loops
						m2 = if hidden {
							nn = FlowLayoutGraph.node(m1, n)
							FlowLayoutGraph.set_node(m1, n, { ..nn, ports: nn.ports.keep_if(|p| !ports.contains(p)) })
						} else {
							m1
						}
						$m = { ..m2, loops: m2.loops.append({ ..loop, hidden }) }
					}
				}
			}
		}
		$m
	}

	loops_of : Model, U64 -> List(U64)
	loops_of = |m, n| FlowLayoutLoops.upto(m.loops.len()).keep_if(|k| (m.loops.get(k) ?? FlowLayoutLoops.blank).node == n)

	blank : Loop
	blank = {
		node: FlowLayoutLoops.nil,
		edge: FlowLayoutLoops.nil,
		ports: [],
		hidden: False,
		label: None,
		leftmost: FlowLayoutLoops.nil,
		rightmost: FlowLayoutLoops.nil,
		occupied: [],
		slots: [0, 0, 0, 0],
		label_side: Undefined,
		label_alignment: Center,
		label_reference: FlowLayoutLoops.nil,
		label_x: 0,
		label_y: 0,
	}

	loop_at : Model, U64 -> Loop
	loop_at = |m, k| m.loops.get(k) ?? FlowLayoutLoops.blank

	set_loop : Model, U64, Loop -> Model
	set_loop = |m, k, l| if (k < m.loops.len()) { ..m, loops: m.loops.set(k, l) ?? [] } else m

	## Nodes of a graph with self-loops, in layer order.
	holders : Model, U64 -> List(U64)
	holders = |m, g| {
		layers = FlowLayoutGraph.graph(m, g).layers
		nodes = layers.fold([], |acc, l| acc.concat(l))
		nodes.keep_if(|n| m.loops.any(|l| l.node == n))
	}

	## Put hidden self-loop ports back on their node's sides after ordering.
	restore : Model, U64 -> Model
	restore = |m0, g| {
		var $m = m0
		for n in FlowLayoutLoops.holders(m0, g) {
			ks = FlowLayoutLoops.loops_of($m, n)
			any_hidden = ks.any(|k| FlowLayoutLoops.loop_at($m, k).hidden)
			if any_hidden {
				# Mermaid asks for loops spread over all sides, but sets that on the
				# drawing, where the engine does not read it for nodes, so every
				# hidden port takes the default, the north side.
				side_choices = [(North, North)]
				for i in 0..<ks.len() {
					k = ks.get(i) ?? 0
					loop = FlowLayoutLoops.loop_at($m, k)
					(first, second) = side_choices.get(i % side_choices.len().max(1)) ?? (North, North)
					half = loop.ports.len() / 2
					for j in 0..<loop.ports.len() {
						if loop.hidden {
							p = loop.ports.get(j) ?? 0
							side = if (j < half) first else second
							$m = FlowLayoutGraph.set_port($m, p, { ..FlowLayoutGraph.port($m, p), side })
						}
					}
				}
				ms = $m
				# Target areas: (side, area) to ports.
				area_index = |side, a| FlowLayoutLoops.side_slot(side) * 3 + a
				sides_of = |loop| loop.ports.fold(
					[],
					|acc, p| {
						side = FlowLayoutGraph.port(ms, p).side
						if (acc.contains(side)) acc else acc.append(side)
					},
				)
				add = |areas, ports, side, a, prepend| {
					on_side = ports.keep_if(|p| FlowLayoutGraph.port(ms, p).side == side)
					idx = area_index(side, a)
					current = areas.get(idx) ?? []
					if (idx < areas.len()) areas.set(idx, if (prepend) on_side.concat(current) else current.concat(on_side)) ?? [] else areas
				}
				var $areas = List.repeat([], 12)
				for k in ks {
					loop = FlowLayoutLoops.loop_at(ms, k)
					sides = sides_of(loop)
					if loop.hidden and sides.len() == 1 {
						side = sides.first() ?? North
						$areas = add($areas, loop.ports.take_first(1), side, 1, True)
						$areas = add($areas, loop.ports.drop_first(1), side, 1, False)
					}
				}
				for k in ks {
					loop = FlowLayoutLoops.loop_at(ms, k)
					sides = sides_of(loop)
					if loop.hidden and sides.len() == 2 {
						sorted = FlowLayoutLoops.sorted_sides(sides)
						$areas = add($areas, loop.ports, sorted.get(0) ?? North, 2, True)
						$areas = add($areas, loop.ports, sorted.get(1) ?? North, 0, False)
					}
				}
				areas = $areas
				area = |side, a| areas.get(area_index(side, a)) ?? []
				old = FlowLayoutGraph.node(ms, n).ports
				old_on = |side| old.keep_if(|p| FlowLayoutGraph.port(ms, p).side == side)
				ports = area(North, 0).concat(area(North, 1)).concat(old_on(North)).concat(area(North, 2))
					.concat(area(East, 0)).concat(area(East, 1)).concat(old_on(East)).concat(area(East, 2))
					.concat(area(South, 0)).concat(area(South, 1)).concat(old_on(South)).concat(area(South, 2))
					.concat(area(West, 0)).concat(old_on(West)).concat(area(West, 1)).concat(area(West, 2))
					.concat(old_on(Undefined))
				node = FlowLayoutGraph.node($m, n)
				$m = FlowLayoutGraph.set_node($m, n, { ..node, ports })
				for k in ks {
					l = FlowLayoutLoops.loop_at($m, k)
					$m = FlowLayoutLoops.set_loop($m, k, { ..l, hidden: False })
				}
			}
		}
		$m
	}

	## Two sides in the engine's order: by side, but west before north.
	sorted_sides : List(FlowLayoutGraph.Side) -> List(FlowLayoutGraph.Side)
	sorted_sides = |sides| {
		sorted = FlowLayoutGraph.sort_by(sides, |a, b| FlowLayoutGraph.side_index(a).to_i64_wrap() - FlowLayoutGraph.side_index(b).to_i64_wrap())
		if (sorted == [North, West]) [West, North] else sorted
	}

	## Route each node's self-loops around it and grow its margins to hold
	## them and their labels.
	route : Model, U64 -> Model
	route = |m0, g| {
		var $m = m0
		spacing = FlowLayoutGraph.graph(m0, g).spacing
		for n in FlowLayoutLoops.holders(m0, g) {
			node = FlowLayoutGraph.node($m, n)
			ks = FlowLayoutLoops.loops_of($m, n)
			port_id = |p| node.ports.find_first_index(|q| q == p) ?? 0
			side_of = |p| FlowLayoutGraph.port(m0, p).side
			# Routes: leftmost and rightmost ports and the sides between.
			for k in ks {
				loop = FlowLayoutLoops.loop_at($m, k)
				ports = FlowLayoutGraph.sort_by(loop.ports, |a, b| port_id(a).to_i64_wrap() - port_id(b).to_i64_wrap())
				sides = ports.fold([], |acc, p| if (acc.contains(side_of(p))) acc else acc.append(side_of(p)))
				lowest = |side| ports.find_first(|p| side_of(p) == side) ?? 0
				highest = |side| ports.find_last(|p| side_of(p) == side) ?? 0
				(left, right) = if sides.len() == 1 {
					s = sides.first() ?? North
					(lowest(s), highest(s))
				} else {
					sorted = FlowLayoutLoops.sorted_sides(sides)
					(lowest(sorted.get(0) ?? North), highest(sorted.get(1) ?? North))
				}
				var $occupied = []
				var $current = side_of(left)
				var $guard = 0
				while $current != side_of(right) and $guard < 4 {
					$occupied = $occupied.append($current)
					$current = FlowLayoutLoops.clockwise($current)
					$guard = $guard + 1
				}
				$occupied = $occupied.append($current)
				$m = FlowLayoutLoops.set_loop($m, k, { ..loop, leftmost: left, rightmost: right, occupied: $occupied })
			}
			# Labels: side and alignment.
			for k in ks {
				loop = FlowLayoutLoops.loop_at($m, k)
				match loop.label {
					Some(size) => {
						one = loop.occupied.len() == 1
						(side, alignment, reference) = if one {
							s = loop.occupied.first() ?? North
							match s {
								East | West => {
									top = if (FlowLayoutGraph.port(m0, loop.rightmost).y < FlowLayoutGraph.port(m0, loop.leftmost).y) loop.rightmost else loop.leftmost
									(s, Top, top)
								}
								_ => (s, Center, FlowLayoutLoops.nil)
							}
						} else {
							ls = side_of(loop.leftmost)
							rs = side_of(loop.rightmost)
							if ls == North {
								(North, AlignLeft, loop.leftmost)
							} else if rs == North {
								(North, AlignRight, loop.rightmost)
							} else if ls == South {
								(South, AlignRight, loop.leftmost)
							} else {
								(South, AlignLeft, loop.rightmost)
							}
						}
						ref_port = FlowLayoutGraph.port(m0, reference)
						(lx, ly) = match alignment {
							Center => ((node.width - size.width) / 2, 0)
							AlignLeft => (ref_port.x + ref_port.anchor_x, 0)
							AlignRight => (ref_port.x + ref_port.anchor_x - size.width, 0)
							Top => (0, ref_port.y + ref_port.anchor_y)
						}
						$m = FlowLayoutLoops.set_loop($m, k, { ..loop, label_side: side, label_alignment: alignment, label_reference: reference, label_x: lx, label_y: ly })
					}
					None => {}
				}
			}
			# Lanes: loops crossing more of another go further out.
			activity = |loop| {
				count = node.ports.len()
				var $active = List.repeat(False, count)
				var $idx = (port_id(loop.leftmost) + count - 1) % count.max(1)
				target = port_id(loop.rightmost)
				var $guard = 0
				var $going = count > 0
				while $going and $guard <= count {
					$idx = ($idx + 1) % count
					$active = $active.set($idx, True) ?? $active
					if $idx == target {
						$going = False
					}
					$guard = $guard + 1
				}
				$active
			}
			loops = ks.map(|k| FlowLayoutLoops.loop_at($m, k))
			activities = loops.map(activity)
			crossings = |upper, lower_index| {
				lower = activities.get(lower_index) ?? []
				upper.ports.count_if(|p| lower.get(port_id(p)) ?? False)
			}
			var $deps = []
			for i in 0..<loops.len() {
				for j in (i + 1)..<loops.len() {
					a = loops.get(i) ?? FlowLayoutLoops.blank
					b = loops.get(j) ?? FlowLayoutLoops.blank
					c1 = crossings(a, j)
					c2 = crossings(b, i)
					if c1 < c2 {
						$deps = $deps.append({ source: i, target: j })
					} else if c2 < c1 {
						$deps = $deps.append({ source: j, target: i })
					} else if c1 != 0 {
						$deps = $deps.append({ source: i, target: j }).append({ source: j, target: i })
					}
				}
			}
			# Raw lanes from the sinks back (cycles, rare for one-edge loops, are
			# left to the longest path's bound).
			count_l = loops.len()
			var $slot = List.repeat(0, count_l)
			deps = $deps
			var $out_w = FlowLayoutLoops.upto(count_l).map(|i| deps.count_if(|d| d.source == i))
			var $queue = FlowLayoutLoops.upto(count_l).keep_if(|i| ($out_w.get(i) ?? 0) == 0)
			var $head = 0
			while $head < $queue.len() {
				i = $queue.get($head) ?? 0
				$head = $head + 1
				for d in deps {
					if d.target == i {
						$slot = $slot.set(d.source, ($slot.get(d.source) ?? 0).max(($slot.get(i) ?? 0) + 1)) ?? $slot
						w = ($out_w.get(d.source) ?? 1) - 1
						$out_w = $out_w.set(d.source, w) ?? $out_w
						if w == 0 {
							$queue = $queue.append(d.source)
						}
					}
				}
			}
			raw = $slot
			# Shift towards the node, side by side.
			var $side_slots = loops.map(|_| [0, 0, 0, 0])
			var $next_free = List.repeat(0, node.ports.len())
			for side in [North, East, South, West] {
				si = FlowLayoutLoops.side_slot(side)
				on_side = FlowLayoutGraph.sort_by(
					FlowLayoutLoops.upto(count_l).keep_if(|i| (loops.get(i) ?? FlowLayoutLoops.blank).occupied.contains(side)),
					|a, b| (raw.get(a) ?? 0).to_i64_wrap() - (raw.get(b) ?? 0).to_i64_wrap(),
				)
				port_ids = FlowLayoutLoops.upto(node.ports.len()).keep_if(|p| FlowLayoutGraph.port(m0, node.ports.get(p) ?? 0).side == side)
				if port_ids.is_empty() {
					for r in 0..<on_side.len() {
						i = on_side.get(r) ?? 0
						slots = $side_slots.get(i) ?? [0, 0, 0, 0]
						$side_slots = $side_slots.set(i, slots.set(si, r) ?? slots) ?? $side_slots
					}
				} else {
					lo = port_ids.first() ?? 0
					hi = port_ids.last() ?? 0
					for i in on_side {
						active = activities.get(i) ?? []
						var $lowest = 0
						for p in lo..=hi {
							if active.get(p) ?? False {
								$lowest = $lowest.max($next_free.get(p) ?? 0)
							}
						}
						slots = $side_slots.get(i) ?? [0, 0, 0, 0]
						$side_slots = $side_slots.set(i, slots.set(si, $lowest) ?? slots) ?? $side_slots
						for p in lo..=hi {
							if active.get(p) ?? False {
								$next_free = $next_free.set(p, $lowest + 1) ?? $next_free
							}
						}
					}
				}
			}
			# Lane positions per side, from the node outwards.
			side_slots = $side_slots
			slot_count = |si| side_slots.fold(0, |acc, s| acc.max((s.get(si) ?? 0) + 1))
			margin = node.margin
			var $positions = []
			for side in [North, East, South, West] {
				si = FlowLayoutLoops.side_slot(side)
				count = if (loops.any(|l| l.occupied.contains(side))) slot_count(si) else 0
				var $label_room = List.repeat(0.0, count)
				if side == North or side == South {
					for i in 0..<count_l {
						l = loops.get(i) ?? FlowLayoutLoops.blank
						match l.label {
							Some(size) => {
								if l.label_side == side {
									s = ($side_slots.get(i) ?? [0, 0, 0, 0]).get(si) ?? 0
									$label_room = $label_room.set(s, ($label_room.get(s) ?? 0).max(size.height)) ?? $label_room
								}
							}
							None => {}
						}
					}
				}
				base = match side {
					North => 0 - margin.top - spacing.node_self_loop
					East => node.width + margin.right + spacing.node_self_loop
					South => node.height + margin.bottom + spacing.node_self_loop
					West => 0 - margin.left - spacing.node_self_loop
					Undefined => 0
				}
				factor = if (side == North or side == West) -1.0 else 1.0
				var $pos = base
				var $list = []
				for s in 0..<count {
					room0 = $label_room.get(s) ?? 0
					room = if (room0 > 0) room0 + spacing.edge_label else 0
					$list = $list.append($pos)
					$pos = $pos + factor * (room + spacing.edge_edge)
				}
				$positions = $positions.append($list)
			}
			positions = $positions
			position = |side, slot| (positions.get(FlowLayoutLoops.side_slot(side)) ?? []).get(slot) ?? 0
			base_vector = |side, slot|
				match side {
					North | South => { x: 0, y: position(side, slot) }
					_ => { x: position(side, slot), y: 0 }
				}
			var $new_margin = margin
			grow = |mg, p| { top: mg.top.max(0 - p.y), right: mg.right.max(p.x - node.width), bottom: mg.bottom.max(p.y - node.height), left: mg.left.max(0 - p.x) }
			for i in 0..<count_l {
				k = ks.get(i) ?? 0
				loop = FlowLayoutLoops.loop_at($m, k)
				slots = $side_slots.get(i) ?? [0, 0, 0, 0]
				slot_of = |side| (slots.get(FlowLayoutLoops.side_slot(side)) ?? 0).to_u64_wrap()
				source = loop.ports.first() ?? 0
				edge = FlowLayoutGraph.edge($m, loop.edge)
				src = edge_source_port(loop, edge)
				tgt = edge_target_port(loop, edge)
				_ = source
				sp = FlowLayoutGraph.port(m0, src)
				tp = FlowLayoutGraph.port(m0, tgt)
				direction_clockwise = if sp.side == tp.side {
					port_id(src) < port_id(tgt)
				} else if FlowLayoutLoops.clockwise(sp.side) == tp.side {
					True
				} else if FlowLayoutLoops.counter_clockwise(sp.side) == tp.side {
					False
				} else {
					loop.occupied.contains(FlowLayoutLoops.clockwise(sp.side))
				}
				outer = |port| {
					b = base_vector(port.side, slot_of(port.side))
					match port.side {
						North | South => { x: b.x + port.x + port.anchor_x, y: b.y }
						_ => { x: b.x, y: b.y + port.y + port.anchor_y }
					}
				}
				var $bends = [outer(sp)]
				if sp.side != tp.side {
					var $cur = sp.side
					var $guard = 0
					while $cur != tp.side and $guard < 4 {
						next = if (direction_clockwise) FlowLayoutLoops.clockwise($cur) else FlowLayoutLoops.counter_clockwise($cur)
						a = base_vector($cur, slot_of($cur))
						b = base_vector(next, slot_of(next))
						$bends = $bends.append({ x: a.x + b.x, y: a.y + b.y })
						$cur = next
						$guard = $guard + 1
					}
				}
				$bends = $bends.append(outer(tp))
				for b in $bends {
					$new_margin = grow($new_margin, b)
				}
				$m = FlowLayoutGraph.set_edge($m, loop.edge, { ..FlowLayoutGraph.edge($m, loop.edge), bends: $bends })
				# Labels beside their lane.
				match loop.label {
					Some(size) => {
						lane = position(loop.label_side, slot_of(loop.label_side))
						(lx, ly) = match loop.label_side {
							North => (loop.label_x, lane - spacing.edge_label - size.height)
							South => (loop.label_x, lane + spacing.edge_label)
							West => (lane - spacing.edge_label - size.width, loop.label_y)
							_ => (lane + spacing.edge_label, loop.label_y)
						}
						$m = FlowLayoutLoops.set_loop($m, k, { ..loop, label_x: lx, label_y: ly, slots: slots.map(|s| s.to_i64_wrap()) })
						$new_margin = grow(grow($new_margin, { x: lx, y: ly }), { x: lx + size.width, y: ly + size.height })
					}
					None => {
						$m = FlowLayoutLoops.set_loop($m, k, { ..loop, slots: slots.map(|s| s.to_i64_wrap()) })
					}
				}
			}
			$m = FlowLayoutGraph.set_node($m, n, { ..FlowLayoutGraph.node($m, n), margin: $new_margin })
		}
		$m
	}

	## Put self-loop edges back, their bends in the graph's coordinates, with
	## their label centres.
	restore_edges : Model, U64, Bool -> Model
	restore_edges = |m0, g, vertical| {
		var $m = m0
		for k in FlowLayoutLoops.upto(m0.loops.len()) {
			loop = FlowLayoutLoops.loop_at($m, k)
			node = FlowLayoutGraph.node($m, loop.node)
			if node.graph == g and loop.ports.len() == 2 {
				edge = FlowLayoutGraph.edge($m, loop.edge)
				src = edge_source_port(loop, edge)
				tgt = edge_target_port(loop, edge)
				m1 = FlowLayoutGraph.set_target(FlowLayoutGraph.set_source($m, loop.edge, src), loop.edge, tgt)
				e1 = FlowLayoutGraph.edge(m1, loop.edge)
				bends = e1.bends.map(|b| { x: b.x + node.x, y: b.y + node.y })
				label_centre = match loop.label {
					Some(size) => {
						# North labels hug the lane in vertical layouts.
						y = if (vertical and loop.label_side == North) loop.label_y else loop.label_y
						{ x: node.x + loop.label_x + size.width / 2, y: node.y + y + size.height / 2 }
					}
					None => { x: 0, y: 0 }
				}
				$m = FlowLayoutGraph.set_edge(m1, loop.edge, { ..e1, bends, label_x: label_centre.x, label_y: label_centre.y })
			}
		}
		$m
	}

	upto : U64 -> List(U64)
	upto = |n| List.repeat(0, n).map_with_index(|_, i| i)
}

## The loop's source port: its first port (ports are kept source first).
edge_source_port : FlowLayoutGraph.Loop, FlowLayoutGraph.Edge -> U64
edge_source_port = |loop, _edge| loop.ports.first() ?? FlowLayoutGraph.nil

edge_target_port : FlowLayoutGraph.Loop, FlowLayoutGraph.Edge -> U64
edge_target_port = |loop, _edge| loop.ports.last() ?? FlowLayoutGraph.nil
