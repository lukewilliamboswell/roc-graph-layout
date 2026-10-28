import LayeredFlowImport
import LayeredFlowFixtures
import LayeredFlowGraph
import LayeredFlowLayers
import LayeredFlowLoops
import LayeredFlowOrder
import LayeredFlowPlace
import LayeredFlowRandom

## Where layers go along the flow and how edges bend, as the input policy's layout
## engine routes them: each gap between layers gets as many vertical lanes
## as its edges need (ordered so lanes cross as little as possible), the gap
## is as wide as its lanes, and every edge runs out of its port, along its
## lane and into its target. Then dummies are joined back into whole edges,
## labels take their places, reversed edges turn back, and each subgraph's
## box takes the size of its contents.
LayeredFlowRoute :: {}.{

	Model : LayeredFlowGraph.Model

	nil : U64
	nil = LayeredFlowGraph.nil

	tolerance : F64
	tolerance = 0.001

	## Graph height and offset from the extent of its layers.
	layer_sizes : Model, U64 -> { model : Model, widths : List(F64) }
	layer_sizes = |m0, g| {
		graph = LayeredFlowGraph.graph(m0, g)
		var $min = F64.infinity
		var $max = 0 - F64.infinity
		var $found = False
		var $widths = []
		for layer in graph.layers {
			var $w = 0.0
			for n in layer {
				node = LayeredFlowGraph.node(m0, n)
				$w = $w.max(node.width + node.margin.left + node.margin.right)
			}
			$widths = $widths.append($w)
			if !layer.is_empty() {
				$found = True
				first = LayeredFlowGraph.node(m0, layer.first() ?? 0)
				last = LayeredFlowGraph.node(m0, layer.last() ?? 0)
				top = first.y - first.margin.top - (if (first.kind == ExternalPort) graph.spacing.ports_surrounding else 0)
				bottom = last.y + last.height + last.margin.bottom + (if (last.kind == ExternalPort) graph.spacing.ports_surrounding else 0)
				$min = $min.min(top)
				$max = $max.max(bottom)
			}
		}
		(lo, hi) = if ($found) ($min, $max) else (0, 0)
		{ model: LayeredFlowGraph.set_graph(m0, g, { ..graph, height: hi - lo, offset_y: graph.offset_y - lo }), widths: $widths }
	}

	## A node's x within its layer: by its alignment, which with no setting
	## leans towards the side its edges leave from.
	place_horizontally : Model, List(U64), F64, F64 -> Model
	place_horizontally = |m0, layer, width, xoffset| {
		var $max_left = 0.0
		var $max_right = 0.0
		for n in layer {
			node = LayeredFlowGraph.node(m0, n)
			$max_left = $max_left.max(node.margin.left)
			$max_right = $max_right.max(node.margin.right)
		}
		var $m = m0
		for n in layer {
			node = LayeredFlowGraph.node($m, n)
			ins = node.ports.count_if(|p| !LayeredFlowGraph.port($m, p).incoming.is_empty())
			outs = node.ports.count_if(|p| !LayeredFlowGraph.port($m, p).outgoing.is_empty())
			ratio = if (ins + outs == 0) 0.5 else outs.to_f64() / (ins + outs).to_f64()
			var $x = (width - node.width) * ratio
			if ratio > 0.5 {
				$x = $x - $max_right * 2 * (ratio - 0.5)
			} else if ratio < 0.5 {
				$x = $x + $max_left * 2 * (0.5 - ratio)
			}
			if $x < node.margin.left {
				$x = node.margin.left
			}
			if $x > width - node.margin.right - node.width {
				$x = width - node.margin.right - node.width
			}
			$m = LayeredFlowGraph.set_node($m, n, { ..node, x: xoffset + $x })
		}
		$m
	}

	## Absolute position of a port's anchor within its graph.
	anchor : Model, U64 -> { x : F64, y : F64 }
	anchor = |m, p| {
		port = LayeredFlowGraph.port(m, p)
		node = LayeredFlowGraph.node(m, port.node)
		{ x: node.x + port.x + port.anchor_x, y: node.y + port.y + port.anchor_y }
	}

	is_external_east_west : Model, U64 -> Bool
	is_external_east_west = |m, n| {
		node = LayeredFlowGraph.node(m, n)
		node.kind == ExternalPort and (node.ext_side == East or node.ext_side == West)
	}

	## Route every gap of a graph and place its layers along the flow.
	route : Model, U64, List(F64), LayeredFlowRandom.Random -> { model : Model, random : LayeredFlowRandom.Random }
	route = |m0, g, widths, random0| {
		graph = LayeredFlowGraph.graph(m0, g)
		spacing = graph.spacing
		layers = graph.layers
		var $m = m0
		var $random = random0
		var $x = 0.0
		var $i = 0
		var $going = True
		# Ports already in a segment, shared by every gap: each port is in one.
		var $mapped = List.repeat(False, m0.ports.len())
		while $going {
			# Gap between layer i - 1 (left) and layer i (right).
			left = if ($i == 0) None else Some($i - 1)
			right = if ($i < layers.len()) Some($i) else None
			match left {
				Some(l) => {
					$m = LayeredFlowRoute.place_horizontally($m, layers.get(l) ?? [], widths.get(l) ?? 0, $x)
					$x = $x + (widths.get(l) ?? 0)
				}
				None => {}
			}
			start = if (left == None) $x else $x + spacing.edge_node_between_layers
			left_nodes = match left {
				Some(l) => layers.get(l) ?? []
				None => []
			}
			right_nodes = match right {
				Some(r) => layers.get(r) ?? []
				None => []
			}
			r = LayeredFlowRoute.route_gap($m, left_nodes, right_nodes, start, spacing.edge_edge_between_layers, $random, $mapped)
			$m = r.model
			$mapped = r.mapped
			$random = r.random
			slots = r.slots
			left_external = left == None or left_nodes.all(|n| LayeredFlowRoute.is_external_east_west($m, n))
			right_external = right == None or right_nodes.all(|n| LayeredFlowRoute.is_external_east_west($m, n))
			if slots > 0 {
				var $w = (slots - 1).to_f64() * spacing.edge_edge_between_layers
				if left != None {
					$w = $w + spacing.edge_node_between_layers
				}
				if right != None {
					$w = $w + spacing.edge_node_between_layers
				}
				if $w < spacing.node_node_between_layers and !left_external and !right_external {
					$w = spacing.node_node_between_layers
				}
				$x = $x + $w
			} else if !left_external and !right_external {
				$x = $x + spacing.node_node_between_layers
			}
			if right == None {
				$going = False
			}
			$i = $i + 1
		}
		{ model: LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), width: $x }), random: $random }
	}

	Segment : {
		ports : List(U64),
		incoming : List(F64),
		outgoing : List(F64),
		start : F64,
		end : F64,
		split_partner : U64,
		split_by : U64,
	}

	Dependency : { source : U64, target : U64, weight : I64, critical : Bool, alive : Bool }

	Gap : { segs : List(Segment), deps : List(Dependency), critical_threshold : F64, conflict_threshold : F64 }

	no_segment : Segment
	no_segment = { ports: [], incoming: [], outgoing: [], start: 0, end: 0, split_partner: LayeredFlowRoute.nil, split_by: LayeredFlowRoute.nil }

	no_dep : Dependency
	no_dep = { source: 0, target: 0, weight: 0, critical: False, alive: False }

	insert_sorted : List(F64), F64 -> List(F64)
	insert_sorted = |list, value|
		if list.contains(value) {
			list
		} else {
			match list.find_first_index(|x| x > value) {
				Ok(i) => list.take_first(i).append(value).concat(list.drop_first(i))
				Err(_) => list.append(value)
			}
		}

	with_extent : Segment -> Segment
	with_extent = |s| {
		all = s.incoming.concat(s.outgoing)
		{ ..s, start: all.fold(F64.infinity, |a, v| a.min(v)), end: all.fold(0 - F64.infinity, |a, v| a.max(v)) }
	}

	seg : Gap, U64 -> Segment
	seg = |gap, i| gap.segs.get(i) ?? LayeredFlowRoute.no_segment

	outs : Gap, U64 -> List(U64)
	outs = |gap, i| LayeredFlowRoute.upto(gap.deps.len()).keep_if(|k| LayeredFlowRoute.dep_from(gap, k, i))

	ins : Gap, U64 -> List(U64)
	ins = |gap, i| LayeredFlowRoute.upto(gap.deps.len()).keep_if(|k| LayeredFlowRoute.dep_to(gap, k, i))

	## Each segment's live dependencies out and in, as offset tables over
	## dependency indices in increasing order, so a segment's are found
	## without scanning every dependency.
	Adjacency : { out_start : List(U64), out_deps : List(U64), in_start : List(U64), in_deps : List(U64) }

	adjacency : U64, List(Dependency) -> Adjacency
	adjacency = |n, deps| {
		var $out_count = List.repeat(0, n + 1)
		var $in_count = List.repeat(0, n + 1)
		for d in deps {
			if d.alive and d.source < n and d.target < n {
				$out_count = $out_count.set(d.source + 1, ($out_count.get(d.source + 1) ?? 0) + 1) ?? []
				$in_count = $in_count.set(d.target + 1, ($in_count.get(d.target + 1) ?? 0) + 1) ?? []
			}
		}
		# Prefix sums give each segment's start.
		var $out_start = List.repeat(0, n + 1)
		var $in_start = List.repeat(0, n + 1)
		for i in 1..=n {
			$out_start = $out_start.set(i, ($out_start.get(i - 1) ?? 0) + ($out_count.get(i) ?? 0)) ?? []
			$in_start = $in_start.set(i, ($in_start.get(i - 1) ?? 0) + ($in_count.get(i) ?? 0)) ?? []
		}
		out_start = $out_start
		in_start = $in_start
		var $out_fill = out_start
		var $in_fill = in_start
		var $out_deps = List.repeat(0, out_start.last() ?? 0)
		var $in_deps = List.repeat(0, in_start.last() ?? 0)
		for k in 0..<deps.len() {
			d = deps.get(k) ?? LayeredFlowRoute.no_dep
			if d.alive and d.source < n and d.target < n {
				o = $out_fill.get(d.source) ?? 0
				$out_deps = $out_deps.set(o, k) ?? []
				$out_fill = $out_fill.set(d.source, o + 1) ?? []
				i = $in_fill.get(d.target) ?? 0
				$in_deps = $in_deps.set(i, k) ?? []
				$in_fill = $in_fill.set(d.target, i + 1) ?? []
			}
		}
		{ out_start, out_deps: $out_deps, in_start, in_deps: $in_deps }
	}

	adjacent_out : Adjacency, U64 -> List(U64)
	adjacent_out = |a, i| {
		start = a.out_start.get(i) ?? 0
		a.out_deps.sublist({ start, len: (a.out_start.get(i + 1) ?? start) - start })
	}

	adjacent_in : Adjacency, U64 -> List(U64)
	adjacent_in = |a, i| {
		start = a.in_start.get(i) ?? 0
		a.in_deps.sublist({ start, len: (a.in_start.get(i + 1) ?? start) - start })
	}

	dep_from : Gap, U64, U64 -> Bool
	dep_from = |gap, k, i| {
		d = gap.deps.get(k) ?? LayeredFlowRoute.no_dep
		d.alive and d.source == i
	}

	dep_to : Gap, U64, U64 -> Bool
	dep_to = |gap, k, i| {
		d = gap.deps.get(k) ?? LayeredFlowRoute.no_dep
		d.alive and d.target == i
	}

	add_dep : Gap, U64, U64, I64, Bool -> Gap
	add_dep = |gap, source, target, weight, critical| { ..gap, deps: gap.deps.append({ source, target, weight, critical, alive: True }) }

	straight : Segment -> Bool
	straight = |s| (s.start - s.end).abs() < LayeredFlowRoute.tolerance

	count_conflicts : Gap, List(F64), List(F64) -> I64
	count_conflicts = |gap, posis1, posis2|
		if posis1.is_empty() or posis2.is_empty() {
			0
		} else {
			var $i1 = 0
			var $i2 = 0
			var $conflicts = 0
			var $critical = False
			var $more = True
			while $more and !$critical {
				p1 = posis1.get($i1) ?? 0
				p2 = posis2.get($i2) ?? 0
				if p1 > p2 - gap.critical_threshold and p1 < p2 + gap.critical_threshold {
					$critical = True
				} else {
					if p1 > p2 - gap.conflict_threshold and p1 < p2 + gap.conflict_threshold {
						$conflicts = $conflicts + 1
					}
					if p1 <= p2 and $i1 + 1 < posis1.len() {
						$i1 = $i1 + 1
					} else if p2 <= p1 and $i2 + 1 < posis2.len() {
						$i2 = $i2 + 1
					} else {
						$more = False
					}
				}
			}
			if ($critical) -1 else $conflicts
		}

	count_crossings : List(F64), F64, F64 -> I64
	count_crossings = |posis, s, e| {
		var $n = 0
		var $going = True
		for p in posis {
			if $going {
				if p > e {
					$going = False
				} else if p >= s {
					$n = $n + 1
				}
			}
		}
		$n
	}

	## The engine's dependency between two lane segments: which must lie left
	## of the other, weighted by the conflicts and crossings it saves.
	create_dependency : Gap, U64, U64 -> (Gap, I64)
	create_dependency = |gap, i, j| {
		a = LayeredFlowRoute.seg(gap, i)
		b = LayeredFlowRoute.seg(gap, j)
		if LayeredFlowRoute.straight(a) or LayeredFlowRoute.straight(b) {
			(gap, 0)
		} else {
			c1 = LayeredFlowRoute.count_conflicts(gap, a.outgoing, b.incoming)
			c2 = LayeredFlowRoute.count_conflicts(gap, b.outgoing, a.incoming)
			if c1 == -1 or c2 == -1 {
				g1 = if (c1 == -1) LayeredFlowRoute.add_dep(gap, j, i, 1, True) else gap
				g2 = if (c2 == -1) LayeredFlowRoute.add_dep(g1, i, j, 1, True) else g1
				(g2, (if (c1 == -1) 1 else 0) + (if (c2 == -1) 1 else 0))
			} else {
				x1 = LayeredFlowRoute.count_crossings(a.outgoing, b.start, b.end) + LayeredFlowRoute.count_crossings(b.incoming, a.start, a.end)
				x2 = LayeredFlowRoute.count_crossings(b.outgoing, a.start, a.end) + LayeredFlowRoute.count_crossings(a.incoming, b.start, b.end)
				d1 = c1 + 16 * x1
				d2 = c2 + 16 * x2
				if d1 < d2 {
					(LayeredFlowRoute.add_dep(gap, i, j, d2 - d1, False), 0)
				} else if d1 > d2 {
					(LayeredFlowRoute.add_dep(gap, j, i, d1 - d2, False), 0)
				} else if d1 > 0 and d2 > 0 {
					(LayeredFlowRoute.add_dep(LayeredFlowRoute.add_dep(gap, i, j, 0, False), j, i, 0, False), 0)
				} else {
					(gap, 0)
				}
			}
		}
	}

	## The lanes of one gap: returns how many lanes it needs.
	route_gap : Model, List(U64), List(U64), F64, F64, LayeredFlowRandom.Random, List(Bool) -> { model : Model, slots : U64, random : LayeredFlowRandom.Random, mapped : List(Bool) }
	route_gap = |m0, left_nodes, right_nodes, start_pos, edge_spacing, random0, mapped0| {
		# Hyperedge segments: each output port with the ports it connects.
		var $mapped = mapped0
		var $segments = []
		sources = left_nodes.fold([], |acc, n| acc.concat(LayeredFlowGraph.node(m0, n).ports.keep_if(|p| LayeredFlowGraph.port(m0, p).side == East and !LayeredFlowGraph.port(m0, p).outgoing.is_empty())))
		back_ports = right_nodes.fold([], |acc, n| acc.concat(LayeredFlowGraph.node(m0, n).ports.keep_if(|p| LayeredFlowGraph.port(m0, p).side == West and !LayeredFlowGraph.port(m0, p).outgoing.is_empty())))
		for p in sources.concat(back_ports) {
			if !($mapped.get(p) ?? True) {
				var $s = LayeredFlowRoute.no_segment
				var $todo = [p]
				while !$todo.is_empty() {
					q = $todo.last() ?? p
					$todo = $todo.drop_last(1)
					if !($mapped.get(q) ?? True) {
						$mapped = $mapped.set(q, True) ?? []
						port = LayeredFlowGraph.port(m0, q)
						pos = LayeredFlowRoute.anchor(m0, q).y
						$s = if port.side == East {
							{ ..$s, ports: $s.ports.append(q), incoming: LayeredFlowRoute.insert_sorted($s.incoming, pos) }
						} else {
							{ ..$s, ports: $s.ports.append(q), outgoing: LayeredFlowRoute.insert_sorted($s.outgoing, pos) }
						}
						# Connected ports, depth first in edge order.
						others = port.incoming.map(|e| LayeredFlowGraph.edge(m0, e).source).concat(port.outgoing.map(|e| LayeredFlowGraph.edge(m0, e).target))
						$todo = $todo.concat(others.rev())
					}
				}
				$segments = $segments.append(LayeredFlowRoute.with_extent($s))
			}
		}
		segments0 = $segments
		min_diff = |values| {
			sorted = LayeredFlowGraph.sort_by(values, |a, b| if (a < b) -1 else if (a > b) 1 else 0)
			var $best = 1.7976931348623157e308
			var $prev = None
			for v in sorted {
				match $prev {
					Some(pv) if v != pv => {
						$best = $best.min(v - pv)
						$prev = Some(v)
					}
					Some(_) => {}
					None => {
						$prev = Some(v)
					}
				}
			}
			$best
		}
		critical_threshold = 0.2 * min_diff(segments0.fold([], |a, s| a.concat(s.incoming))).min(min_diff(segments0.fold([], |a, s| a.concat(s.outgoing))))
		var $gap = { segs: segments0, deps: [], critical_threshold, conflict_threshold: 0.5 * edge_spacing }
		var $critical_count = 0
		n0 = segments0.len()
		for i in 0..<n0 {
			for j in (i + 1)..<n0 {
				(g1, c) = LayeredFlowRoute.create_dependency($gap, i, j)
				$gap = g1
				$critical_count = $critical_count + c
			}
		}
		var $random = random0
		if $critical_count >= 2 {
			(r1, cycle_deps) = LayeredFlowRoute.detect_cycles($gap, True, $random)
			$random = r1
			$gap = LayeredFlowRoute.split_segments($gap, cycle_deps)
		}
		(r2, to_fix) = LayeredFlowRoute.detect_cycles($gap, False, $random)
		$random = r2
		for k in to_fix {
			d = $gap.deps.get(k) ?? LayeredFlowRoute.no_dep
			$gap = { ..$gap, deps: if (d.weight == 0) $gap.deps.set(k, { ..d, alive: False }) ?? $gap.deps else $gap.deps.set(k, { ..d, source: d.target, target: d.source }) ?? $gap.deps }
		}
		gap = $gap
		slots = LayeredFlowRoute.number(gap.segs, gap.deps.keep_if(|d| d.alive))
		var $rank_count = -1.I64
		var $m = m0
		for i in 0..<gap.segs.len() {
			s = LayeredFlowRoute.seg(gap, i)
			if !LayeredFlowRoute.straight(s) {
				slot = slots.get(i) ?? 0
				$rank_count = $rank_count.max(slot)
				# A split partner draws no bends of its own.
				dummy = s.split_partner != LayeredFlowRoute.nil and s.split_by == LayeredFlowRoute.nil
				if !dummy {
					x = start_pos + slot.to_f64() * edge_spacing
					for p in s.ports {
						source_y = LayeredFlowRoute.anchor($m, p).y
						for e in LayeredFlowGraph.port($m, p).outgoing {
							if !LayeredFlowGraph.is_self_loop($m, e) {
								target_y = LayeredFlowRoute.anchor($m, LayeredFlowGraph.edge($m, e).target).y
								if (source_y - target_y).abs() > LayeredFlowRoute.tolerance {
									edge = LayeredFlowGraph.edge($m, e)
									bends = if s.split_partner != LayeredFlowRoute.nil {
										partner = LayeredFlowRoute.seg(gap, s.split_partner)
										split_y = partner.incoming.first() ?? source_y
										partner_x = start_pos + (slots.get(s.split_partner) ?? 0).to_f64() * edge_spacing
										[{ x, y: source_y }, { x, y: split_y }, { x: partner_x, y: split_y }, { x: partner_x, y: target_y }]
									} else {
										[{ x, y: source_y }, { x, y: target_y }]
									}
									$m = LayeredFlowGraph.set_edge($m, e, { ..edge, bends: edge.bends.concat(bends) })
								}
							}
						}
					}
				}
			}
		}
		{ model: $m, slots: ($rank_count + 1).max(0).to_u64_wrap(), random: $random, mapped: $mapped }
	}

	## Split segments in critical cycles, as the engine's segment splitter
	## does: each where a gap between port positions leaves room, the
	## shorter segments first.
	split_segments : Gap, List(U64) -> Gap
	split_segments = |gap0, cycle_deps| {
		if cycle_deps.is_empty() {
			gap0
		} else {
			threshold = gap0.critical_threshold
			coords = LayeredFlowGraph.sort_by(gap0.segs.fold([], |a, s| a.concat(s.incoming).concat(s.outgoing)), |a, b| if (a < b) -1 else if (a > b) 1 else 0)
			var $free = []
			for i in 1..<coords.len() {
				a = coords.get(i - 1) ?? 0
				b = coords.get(i) ?? 0
				if b - a >= 2 * threshold {
					$free = $free.append({ start: a + threshold, end: b - threshold })
				}
			}
			var $gap = gap0
			var $to_split = []
			for k in cycle_deps {
				d = $gap.deps.get(k) ?? LayeredFlowRoute.no_dep
				if !$to_split.contains(d.source) and !$to_split.contains(d.target) {
					src = LayeredFlowRoute.seg($gap, d.source)
					tgt = LayeredFlowRoute.seg($gap, d.target)
					hyper = |s| s.incoming.len() + s.outgoing.len() > 2
					(split, causing) = if (hyper(src) and !hyper(tgt)) (d.target, d.source) else (d.source, d.target)
					$to_split = $to_split.append(split)
					s = LayeredFlowRoute.seg($gap, split)
					$gap = { ..$gap, segs: $gap.segs.set(split, { ..s, split_by: causing }) ?? $gap.segs }
				}
			}
			ordered = LayeredFlowGraph.sort_by(
				$to_split,
				|a, b| {
					la = LayeredFlowRoute.seg($gap, a)
					lb = LayeredFlowRoute.seg($gap, b)
					da = la.end - la.start
					db = lb.end - lb.start
					if (da < db) -1 else if (da > db) 1 else 0
				},
			)
			for i in ordered {
				s = LayeredFlowRoute.seg($gap, i)
				# Free areas the segment spans.
				var $first = -1
				var $last = -1
				var $stop = False
				for k in 0..<$free.len() {
					if !$stop {
						area = $free.get(k) ?? { start: 0, end: 0 }
						if area.start > s.end {
							$stop = True
						} else if area.end >= s.start {
							if $first < 0 {
								$first = k.to_i64_wrap()
							}
							$last = k.to_i64_wrap()
						}
					}
				}
				var $position = (s.start + s.end) / 2
				if $first >= 0 {
					best = LayeredFlowRoute.best_area($gap, i, $free, $first.to_u64_wrap(), $last.to_u64_wrap())
					area = $free.get(best) ?? { start: 0, end: 0 }
					$position = (area.start + area.end) / 2
					# Use the area: keep what lies a threshold away from its centre.
					centre = (area.start + area.end) / 2
					var $replacement = []
					if (area.end - area.start) / 2 >= threshold {
						if area.start <= centre - threshold {
							$replacement = $replacement.append({ start: area.start, end: centre - threshold })
						}
						if centre + threshold <= area.end {
							$replacement = $replacement.append({ start: centre + threshold, end: area.end })
						}
					}
					$free = $free.take_first(best).concat($replacement).concat($free.drop_first(best + 1))
				}
				# Split: the segment keeps its start; a partner takes its end.
				partner_index = $gap.segs.len()
				partner = LayeredFlowRoute.with_extent({ ..LayeredFlowRoute.no_segment, split_partner: i, outgoing: s.outgoing, incoming: [$position] })
				shortened = LayeredFlowRoute.with_extent({ ..s, outgoing: [$position], split_partner: partner_index })
				$gap = { ..$gap, segs: ($gap.segs.set(i, shortened) ?? $gap.segs).append(partner) }
				# The split segment loses its dependencies.
				$gap = { ..$gap, deps: $gap.deps.map(|d| if (d.alive and (d.source == i or d.target == i)) { ..d, alive: False } else d) }
				causing = shortened.split_by
				$gap = LayeredFlowRoute.add_dep($gap, i, causing, 1, True)
				$gap = LayeredFlowRoute.add_dep($gap, causing, partner_index, 1, True)
				for other in 0..<$gap.segs.len() {
					if other != causing and other != i and other != partner_index {
						(g1, _) = LayeredFlowRoute.create_dependency($gap, other, i)
						(g2, _) = LayeredFlowRoute.create_dependency(g1, other, partner_index)
						$gap = g2
					}
				}
			}
			$gap
		}
	}

	## The free area to split a segment in: fewest crossings, then fewest
	## dependencies, then the largest.
	best_area : Gap, U64, List({ start : F64, end : F64 }), U64, U64 -> U64
	best_area = |gap, i, free, from, to|
		if from >= to {
			from
		} else {
			s = LayeredFlowRoute.seg(gap, i)
			causing = LayeredFlowRoute.seg(gap, s.split_by)
			others = LayeredFlowRoute.ins(gap, i).map(|k| (gap.deps.get(k) ?? LayeredFlowRoute.no_dep).source).concat(LayeredFlowRoute.outs(gap, i).map(|k| (gap.deps.get(k) ?? LayeredFlowRoute.no_dep).target))
			single = |left, right| LayeredFlowRoute.count_crossings(left.outgoing, right.start, right.end) + LayeredFlowRoute.count_crossings(right.incoming, left.start, left.end)
			rate = |area| {
				centre = (area.start + area.end) / 2
				first_part = LayeredFlowRoute.with_extent({ ..LayeredFlowRoute.no_segment, incoming: s.incoming, outgoing: [centre] })
				second_part = LayeredFlowRoute.with_extent({ ..LayeredFlowRoute.no_segment, incoming: [centre], outgoing: s.outgoing })
				var $deps = 0
				var $crossings = 0
				for o in others {
					other = LayeredFlowRoute.seg(gap, o)
					for part in [first_part, second_part] {
						a = single(part, other)
						b = single(other, part)
						if a == b {
							if a > 0 {
								$deps = $deps + 2
								$crossings = $crossings + a
							}
						} else {
							$deps = $deps + 1
							$crossings = $crossings + a.min(b)
						}
					}
				}
				{ deps: $deps + 2, crossings: $crossings + single(first_part, causing) + single(causing, second_part) }
			}
			var $best = from
			var $best_rating = rate(free.get(from) ?? { start: 0, end: 0 })
			for k in (from + 1)..=to {
				area = free.get(k) ?? { start: 0, end: 0 }
				r = rate(area)
				best_now = free.get($best) ?? { start: 0, end: 0 }
				best_area_size = best_now.end - best_now.start
				better = r.crossings < $best_rating.crossings or (r.crossings == $best_rating.crossings and (r.deps < $best_rating.deps or (r.deps == $best_rating.deps and area.end - area.start > best_area_size)))
				if better {
					$best = k
					$best_rating = r
				}
			}
			$best
		}

	## The dependencies to turn around (or drop) to make the lane order acyclic,
	## found by the engine's greedy linear ordering. With `critical_only`, only
	## critical dependencies count.
	detect_cycles : Gap, Bool, LayeredFlowRandom.Random -> (LayeredFlowRandom.Random, List(U64))
	detect_cycles = |gap, critical_only, random0| {
		n = gap.segs.len()
		dep = |k| gap.deps.get(k) ?? LayeredFlowRoute.no_dep
		counts = |k| critical_only == False or dep(k).critical
		adj = LayeredFlowRoute.adjacency(n, gap.deps)
		outs_of = |i| LayeredFlowRoute.adjacent_out(adj, i)
		ins_of = |i| LayeredFlowRoute.adjacent_in(adj, i)
		var $mark = List.repeat(0, n).map_with_index(|_, i| -1 - i.to_i64_wrap())
		crit_in0 = List.repeat(0, n).map_with_index(|_, i| ins_of(i).fold(0, |a, k| if (dep(k).critical) a + dep(k).weight else a))
		crit_out0 = List.repeat(0, n).map_with_index(|_, i| outs_of(i).fold(0, |a, k| if (dep(k).critical) a + dep(k).weight else a))
		in_w0 = if (critical_only) crit_in0 else List.repeat(0, n).map_with_index(|_, i| ins_of(i).fold(0, |a, k| a + dep(k).weight))
		out_w0 = if (critical_only) crit_out0 else List.repeat(0, n).map_with_index(|_, i| outs_of(i).fold(0, |a, k| a + dep(k).weight))
		var $sources = []
		var $sinks = []
		for i in 0..<n {
			if (out_w0.get(i) ?? 0) == 0 {
				$sinks = $sinks.append(i)
			} else if (in_w0.get(i) ?? 0) == 0 {
				$sources = $sources.append(i)
			}
		}
		var $unprocessed = List.repeat(True, n)
		var $remaining = n
		mark_base = n.to_i64_wrap()
		var $next_sink = mark_base - 1
		var $next_source = mark_base + 1
		var $random = random0
		update = |state, node| {
			var $st = state
			for k in outs_of(node) {
				d = dep(k)
				if counts(k) {
					t = d.target
					if ($st.mark.get(t) ?? 0) < 0 and d.weight > 0 {
						iw = ($st.in_w.get(t) ?? 0) - d.weight
						$st = { ..$st, in_w: $st.in_w.set(t, iw) ?? $st.in_w }
						if d.critical {
							$st = { ..$st, crit_in: $st.crit_in.set(t, ($st.crit_in.get(t) ?? 0) - d.weight) ?? $st.crit_in }
						}
						if iw <= 0 and ($st.out_w.get(t) ?? 0) > 0 {
							$st = { ..$st, sources: $st.sources.append(t) }
						}
					}
				}
			}
			for k in ins_of(node) {
				d = dep(k)
				if counts(k) {
					s = d.source
					if ($st.mark.get(s) ?? 0) < 0 and d.weight > 0 {
						ow = ($st.out_w.get(s) ?? 0) - d.weight
						$st = { ..$st, out_w: $st.out_w.set(s, ow) ?? $st.out_w }
						if d.critical {
							$st = { ..$st, crit_out: $st.crit_out.set(s, ($st.crit_out.get(s) ?? 0) - d.weight) ?? $st.crit_out }
						}
						if ow <= 0 and ($st.in_w.get(s) ?? 0) > 0 {
							$st = { ..$st, sinks: $st.sinks.append(s) }
						}
					}
				}
			}
			$st
		}
		var $state = { mark: $mark, in_w: in_w0, out_w: out_w0, crit_in: crit_in0, crit_out: crit_out0, sources: $sources, sinks: $sinks }
		var $guard = 0
		while $remaining > 0 and $guard <= 4 * n + 4 {
			while !$state.sinks.is_empty() {
				s = $state.sinks.first() ?? 0
				$state = { ..$state, sinks: $state.sinks.drop_first(1) }
				if $unprocessed.get(s) ?? False {
					$unprocessed = $unprocessed.set(s, False) ?? $unprocessed
					$remaining = $remaining - 1
				}
				$state = { ..$state, mark: $state.mark.set(s, $next_sink) ?? $state.mark }
				$next_sink = $next_sink - 1
				$state = update($state, s)
			}
			while !$state.sources.is_empty() {
				s = $state.sources.first() ?? 0
				$state = { ..$state, sources: $state.sources.drop_first(1) }
				if $unprocessed.get(s) ?? False {
					$unprocessed = $unprocessed.set(s, False) ?? $unprocessed
					$remaining = $remaining - 1
				}
				$state = { ..$state, mark: $state.mark.set(s, $next_source) ?? $state.mark }
				$next_source = $next_source + 1
				$state = update($state, s)
			}
			# The unprocessed set iterates by mark, as a tree set ordered by
			# marks does.
			candidates = LayeredFlowGraph.sort_by(
				LayeredFlowRoute.upto(n).keep_if(|i| $unprocessed.get(i) ?? False),
				|a, b| {
					ma = $state.mark.get(a) ?? 0
					mb = $state.mark.get(b) ?? 0
					if (ma < mb) -1 else if (ma > mb) 1 else 0
				},
			)
			var $max_flow = -2147483648
			var $max_segments = []
			var $stop = False
			for c in candidates {
				if !$stop {
					if !critical_only and ($state.crit_out.get(c) ?? 0) > 0 and ($state.crit_in.get(c) ?? 0) <= 0 {
						$max_segments = [c]
						$stop = True
					} else {
						flow = ($state.out_w.get(c) ?? 0) - ($state.in_w.get(c) ?? 0)
						if flow >= $max_flow {
							if flow > $max_flow {
								$max_segments = []
								$max_flow = flow
							}
							$max_segments = $max_segments.append(c)
						}
					}
				}
			}
			if !$max_segments.is_empty() {
				(r, pick) = LayeredFlowRandom.next_int($random, $max_segments.len())
				$random = r
				node = $max_segments.get(pick) ?? 0
				if $unprocessed.get(node) ?? False {
					$unprocessed = $unprocessed.set(node, False) ?? $unprocessed
					$remaining = $remaining - 1
				}
				$state = { ..$state, mark: $state.mark.set(node, $next_source) ?? $state.mark }
				$next_source = $next_source + 1
				$state = update($state, node)
			}
			$guard = $guard + 1
		}
		shift_base = n.to_i64_wrap() + 1
		marks = $state.mark.map(|mk| if (mk < mark_base) mk + shift_base else mk)
		var $result = []
		for i in 0..<n {
			for k in outs_of(i) {
				d = dep(k)
				if counts(k) and (marks.get(i) ?? 0) > (marks.get(d.target) ?? 0) {
					$result = $result.append(k)
				}
			}
		}
		($random, $result)
	}

	upto : U64 -> List(U64)
	upto = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Hierarchical port dummies move to the graph's border, and the edges to
	## them run straight out at their ports' height.
	external_ports : Model, U64 -> Model
	external_ports = |m0, g| {
		graph = LayeredFlowGraph.graph(m0, g)
		layers = graph.layers
		var $m = m0
		ends = if (layers.len() > 1) [0, layers.len() - 1] else if (layers.len() == 1) [0] else []
		for l in ends {
			for n in layers.get(l) ?? [] {
				node = LayeredFlowGraph.node($m, n)
				if node.kind == ExternalPort {
					x = match node.ext_side {
						East => graph.width + graph.padding.right - graph.offset_x
						West => 0 - graph.offset_x - graph.padding.left
						_ => node.x
					}
					$m = LayeredFlowGraph.set_node($m, n, { ..node, x })
				}
			}
		}
		for l in ends {
			for n in layers.get(l) ?? [] {
				node = LayeredFlowGraph.node($m, n)
				if node.kind == ExternalPort and (node.ext_side == East or node.ext_side == West) {
					for e in LayeredFlowGraph.connected($m, n) {
						edge = LayeredFlowGraph.edge($m, e)
						if !edge.bends.is_empty() {
							var $bends = edge.bends
							if LayeredFlowGraph.port($m, edge.source).node == n {
								first = $bends.first() ?? { x: 0, y: 0 }
								$bends = $bends.set(0, { ..first, y: LayeredFlowRoute.anchor($m, edge.source).y }) ?? $bends
							}
							if LayeredFlowGraph.port($m, edge.target).node == n {
								last = $bends.last() ?? { x: 0, y: 0 }
								$bends = $bends.set($bends.len() - 1, { ..last, y: LayeredFlowRoute.anchor($m, edge.target).y }) ?? $bends
							}
							$m = LayeredFlowGraph.set_edge($m, e, { ..edge, bends: $bends })
						}
					}
				}
			}
		}
		$m
	}

	## Join an edge that runs through a dummy back into one edge.
	join_at : Model, U64, Bool -> Model
	join_at = |m0, dummy, add_bend| {
		node = LayeredFlowGraph.node(m0, dummy)
		input = node.ports.find_first(|p| LayeredFlowGraph.port(m0, p).side == West) ?? LayeredFlowRoute.nil
		output = node.ports.find_first(|p| LayeredFlowGraph.port(m0, p).side == East) ?? LayeredFlowRoute.nil
		bend = LayeredFlowRoute.anchor(m0, node.ports.first() ?? input)
		var $m = m0
		var $count = LayeredFlowGraph.port(m0, input).incoming.len()
		while $count > 0 {
			$count = $count - 1
			surviving = LayeredFlowGraph.port($m, input).incoming.first() ?? LayeredFlowRoute.nil
			dropped = LayeredFlowGraph.port($m, output).outgoing.first() ?? LayeredFlowRoute.nil
			if surviving != LayeredFlowRoute.nil and dropped != LayeredFlowRoute.nil {
				dropped_edge = LayeredFlowGraph.edge($m, dropped)
				target = dropped_edge.target
				target_port = LayeredFlowGraph.port($m, target)
				index = target_port.incoming.find_first_index(|x| x == dropped) ?? target_port.incoming.len()
				# The surviving edge takes the dropped edge's place at the target.
				m1 = LayeredFlowGraph.set_target($m, surviving, LayeredFlowRoute.nil)
				m2 = LayeredFlowGraph.set_target(LayeredFlowGraph.set_source(m1, dropped, LayeredFlowRoute.nil), dropped, LayeredFlowRoute.nil)
				tp = LayeredFlowGraph.port(m2, target)
				inserted = tp.incoming.take_first(index).append(surviving).concat(tp.incoming.drop_first(index))
				m3 = LayeredFlowGraph.set_port(m2, target, { ..tp, incoming: inserted })
				se = LayeredFlowGraph.edge(m3, surviving)
				bends = (if (add_bend) se.bends.append(bend) else se.bends).concat(dropped_edge.bends)
				$m = LayeredFlowGraph.set_edge(m3, surviving, { ..se, target, bends, labels: se.labels.concat(dropped_edge.labels) })
			}
		}
		$m
	}

	## Long-edge dummies go, leaving a bend at each.
	join_long_edges : Model, U64 -> Model
	join_long_edges = |m0, g| {
		var $m = m0
		# Only the top level asks for bend points where long edges join.
		unnecessary = LayeredFlowGraph.graph(m0, g).parent == LayeredFlowGraph.nil
		layers = LayeredFlowGraph.graph(m0, g).layers
		var $new_layers = []
		for layer in layers {
			for n in layer {
				if LayeredFlowGraph.node($m, n).kind == LongEdge {
					$m = LayeredFlowRoute.join_at($m, n, unnecessary)
				}
			}
			$new_layers = $new_layers.append(layer.keep_if(|n| LayeredFlowGraph.node($m, n).kind != LongEdge))
		}
		LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), layers: $new_layers })
	}

	## Labels take their dummies' places; the dummies go.
	place_labels : Model, U64, Bool, Bool -> Model
	place_labels = |m0, g, vertical, up| {
		var $m = m0
		spacing = LayeredFlowGraph.graph(m0, g).spacing
		layers = LayeredFlowGraph.graph(m0, g).layers
		var $new_layers = []
		for layer in layers {
			for n in layer {
				node = LayeredFlowGraph.node($m, n)
				if node.kind == Label {
					# The edge the dummy was made from.
					origin_edge = LayeredFlowGraph.incoming($m, n).first() ?? LayeredFlowRoute.nil
					labels = if (up) node.labels.rev() else node.labels
					var $x = node.x
					var $y = node.y
					var $placed = []
					for label in labels {
						if vertical {
							$placed = $placed.append({ x: $x, y: $y + (node.height - label.height) / 2, label })
							$x = $x + label.width + spacing.label_label
						} else {
							$placed = $placed.append({ x: node.x + (node.width - label.width) / 2, y: $y, label })
							$y = $y + label.height + spacing.label_label
						}
					}
					first = $placed.first() ?? { x: node.x, y: node.y, label: { width: 0, height: 0, edge: 0 } }
					if origin_edge != LayeredFlowRoute.nil {
						oe = LayeredFlowGraph.edge($m, origin_edge)
						$m = LayeredFlowGraph.set_edge($m, origin_edge, { ..oe, labels: oe.labels.concat(node.labels), label_x: first.x + first.label.width / 2, label_y: first.y + first.label.height / 2 })
					}
					$m = LayeredFlowRoute.join_at($m, n, False)
				}
			}
			$new_layers = $new_layers.append(layer.keep_if(|n| LayeredFlowGraph.node($m, n).kind != Label))
		}
		LayeredFlowGraph.set_graph($m, g, { ..LayeredFlowGraph.graph($m, g), layers: $new_layers })
	}

	## Edges turned around for layering turn back.
	restore_reversed : Model, U64 -> Model
	restore_reversed = |m0, g| {
		var $m = m0
		for layer in LayeredFlowGraph.graph(m0, g).layers {
			for n in layer {
				for p in LayeredFlowGraph.node($m, n).ports {
					for e in LayeredFlowGraph.port($m, p).outgoing {
						if LayeredFlowGraph.edge($m, e).reversed {
							$m = LayeredFlowGraph.reverse($m, e)
						}
					}
				}
			}
		}
		$m
	}

	## The graph's size with its padding, at least its minimum; for a
	## subgraph, its box takes that size and its border ports their places.
	resize : Model, U64 -> Model
	resize = |m0, g| {
		graph = LayeredFlowGraph.graph(m0, g)
		actual_w = graph.width + graph.padding.left + graph.padding.right
		actual_h = graph.height + graph.padding.top + graph.padding.bottom
		is_group = graph.parent != LayeredFlowRoute.nil
		min_w = if (is_group) (if (graph.min_width <= 0) 20 else graph.min_width) else 0
		min_h = if (is_group) (if (graph.min_height <= 0) 20 else graph.min_height) else 0
		new_w = actual_w.max(min_w)
		new_h = actual_h.max(min_h)
		nodes = graph.layers.fold([], |acc, l| acc.concat(l))
		var $m = m0
		# Content stays at the top left; east ports follow a wider box.
		if graph.external_ports and new_w > actual_w {
			for n in nodes {
				node = LayeredFlowGraph.node($m, n)
				if node.kind == ExternalPort and node.ext_side == East {
					$m = LayeredFlowGraph.set_node($m, n, { ..node, x: node.x + new_w - actual_w })
				}
			}
		}
		g1 = LayeredFlowGraph.graph($m, g)
		$m = LayeredFlowGraph.set_graph($m, g, { ..g1, width: new_w - g1.padding.left - g1.padding.right, height: new_h - g1.padding.top - g1.padding.bottom, nodes })
		if !is_group {
			$m
		} else {
			g2 = LayeredFlowGraph.graph($m, g)
			for n in nodes {
				node = LayeredFlowGraph.node($m, n)
				match node.origin {
					PortDummy(p) if node.kind == ExternalPort => {
						port = LayeredFlowGraph.port($m, p)
						cy = node.y + node.height / 2 + g2.padding.top + g2.offset_y
						(px, py, dx) = match node.ext_side {
							East => (g2.width + g2.padding.left + g2.padding.right + node.border_offset, cy - port.height / 2, g2.width + g2.padding.right + node.border_offset - g2.offset_x)
							West => (0 - port.width - node.border_offset, cy - port.height / 2, 0 - (g2.padding.left + node.border_offset + g2.offset_x))
							_ => (port.x, port.y, node.x)
						}
						$m = LayeredFlowGraph.set_port($m, p, { ..port, x: px, y: py, side: node.ext_side })
						$m = LayeredFlowGraph.set_node($m, n, { ..LayeredFlowGraph.node($m, n), x: dx })
					}
					_ => {}
				}
			}
			parent = LayeredFlowGraph.node($m, g2.parent)
			if g2.external_ports {
				$m = LayeredFlowGraph.set_node($m, g2.parent, { ..parent, width: new_w, height: new_h, port_constraints: FixedPos })
				$m
			} else {
				# Ports of a box with no edges inside follow it as it grows; the
				# parent's port placement places them afterwards.
				$m = LayeredFlowGraph.set_node($m, g2.parent, { ..parent, width: new_w, height: new_h })
				$m
			}
		}
	}

	## Every step after node placement, for one graph.
	finish : Model, U64, Bool, Bool, LayeredFlowRandom.Random -> { model : Model, random : LayeredFlowRandom.Random }
	finish = |m0, g, vertical, up, random| {
		sized = LayeredFlowRoute.layer_sizes(m0, g)
		routed = LayeredFlowRoute.route(sized.model, g, sized.widths, random)
		m1 = if (LayeredFlowGraph.graph(routed.model, g).external_ports) LayeredFlowRoute.external_ports(routed.model, g) else routed.model
		m2 = LayeredFlowLoops.restore_edges(LayeredFlowRoute.join_long_edges(m1, g), g, vertical)
		m3 = LayeredFlowRoute.place_labels(m2, g, vertical, up)
		m4 = LayeredFlowRoute.restore_reversed(m3, g)
		{ model: LayeredFlowRoute.resize(m4, g), random: routed.random }
	}

	## Lanes by longest path over the dependencies; segments that only end in
	## the gap's right layer are pulled to the last lane.
	number : List(Segment), List(Dependency) -> List(I64)
	number = |segments, deps| {
		n = segments.len()
		adj = LayeredFlowRoute.adjacency(n, deps.map(|d| { ..d, alive: True }))
		outs_of = |i| LayeredFlowRoute.adjacent_out(adj, i).map(|k| deps.get(k) ?? LayeredFlowRoute.no_dep)
		ins_of = |i| LayeredFlowRoute.adjacent_in(adj, i).map(|k| deps.get(k) ?? LayeredFlowRoute.no_dep)
		var $slot = List.repeat(0, n)
		var $in_w = List.repeat(0, n).map_with_index(|_, i| ins_of(i).len().to_i64_wrap())
		var $out_w = List.repeat(0, n).map_with_index(|_, i| outs_of(i).len().to_i64_wrap())
		var $sources = []
		var $rightward = []
		for i in 0..<n {
			s = segments.get(i) ?? LayeredFlowRoute.no_segment
			if ($in_w.get(i) ?? 0) == 0 {
				$sources = $sources.append(i)
			}
			if ($out_w.get(i) ?? 0) == 0 and s.incoming.is_empty() {
				$rightward = $rightward.append(i)
			}
		}
		var $max_rank = -1
		var $head = 0
		while $head < $sources.len() {
			i = $sources.get($head) ?? 0
			$head = $head + 1
			for d in outs_of(i) {
				t = d.target
				$slot = $slot.set(t, ($slot.get(t) ?? 0).max(($slot.get(i) ?? 0) + 1)) ?? $slot
				$max_rank = $max_rank.max($slot.get(t) ?? 0)
				w = ($in_w.get(t) ?? 0) - 1
				$in_w = $in_w.set(t, w) ?? $in_w
				if w == 0 {
					$sources = $sources.append(t)
				}
			}
		}
		if $max_rank > -1 {
			for i in $rightward {
				$slot = $slot.set(i, $max_rank) ?? $slot
			}
			var $h = 0
			while $h < $rightward.len() {
				i = $rightward.get($h) ?? 0
				$h = $h + 1
				for d in ins_of(i) {
					s = d.source
					source_seg = segments.get(s) ?? LayeredFlowRoute.no_segment
					if source_seg.incoming.is_empty() {
						$slot = $slot.set(s, ($slot.get(s) ?? 0).min(($slot.get(i) ?? 0) - 1)) ?? $slot
						w = ($out_w.get(s) ?? 0) - 1
						$out_w = $out_w.set(s, w) ?? $out_w
						if w == 0 {
							$rightward = $rightward.append(s)
						}
					}
				}
			}
		}
		$slot
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

## Test helper: the drawing's graph of `text` laid out left to right, with
## a function from the graph's coordinates to the drawing's, which is where
## the engine's recorded coordinates are.
test_routed : Str -> { setup : LayeredFlowImport.Setup, model : LayeredFlowGraph.Model, at : { x : F64, y : F64 } -> { x : F64, y : F64 } }
test_routed = |text| {
	setup = test_setup(text)
	m0 = setup.model
	m1 = LayeredFlowLayers.prepare(m0, 0, LayeredFlowLayers.features(m0, 0, False))
	ordered = LayeredFlowOrder.minimize_traced(m1, 0, True, False, [])
	m3 = LayeredFlowPlace.prepare(ordered.model, 0, False)
	m4 = LayeredFlowPlace.brandes_koepf(m3, 0)
	m = LayeredFlowRoute.finish(m4, 0, False, False, ordered.randoms.get(0) ?? LayeredFlowRandom.from_seed(1)).model
	graph = LayeredFlowGraph.graph(m, 0)
	at = |p| { x: p.x + graph.offset_x + graph.padding.left, y: p.y + graph.offset_y + graph.padding.top }
	{ setup, model: m, at }
}

## Two crossing edges between two layers take separate lanes, and b --> c,
## whose ends both sit in a's edge's critical span, is split across two
## lanes. Recorded: ELK bends a --> d at x 204 and b --> c at x 184 then
## 224, crossing over at y 73.
expect {
	r = test_routed("flowchart LR\n    a --> d\n    b --> c\n    a --> c\n    b --> d\n")
	bends = |i| LayeredFlowGraph.edge(r.model, r.setup.edge_of.get(i) ?? 0).bends.map(r.at)
	bends(0) == [{ x: 204, y: 36 }, { x: 204, y: 110 }]
		and bends(1) == [{ x: 184, y: 110 }, { x: 184, y: 73 }, { x: 224, y: 73 }, { x: 224, y: 36 }]
		and bends(2) == []
		and bends(3) == []
}

## Self-loops sit on the node's north side (above it, left to right), each
## a lane further out, the labelled one leaving room for its label.
## Recorded: ELK draws a's loops at y 57 and 37 above a at y 77, from ports
## at x 75.2 and 100.8, and 49.6 and 126.4, with the label at 70.37, 12.
expect {
	r = test_routed("flowchart LR\n    a --> a\n    a -->|retry| a\n    a --> b\n")
	edge = |i| LayeredFlowGraph.edge(r.model, r.setup.edge_of.get(i) ?? 0)
	close = |p, q| (p.x - q.x).abs() < 0.000001 and (p.y - q.y).abs() < 0.000001
	all_close = |ps, qs| ps.len() == qs.len() and List.map2(ps, qs, close).all(|ok| ok)
	inner = edge(0)
	outer = edge(1)
	at = r.at
	label = at({ x: outer.label_x, y: outer.label_y })
	all_close(inner.bends.map(r.at), [{ x: 75.2, y: 57 }, { x: 100.8, y: 57 }])
		and all_close(outer.bends.map(r.at), [{ x: 49.6, y: 37 }, { x: 126.4, y: 37 }])
		and close(label, { x: 70.365234375 + 35.26953125 / 2, y: 12 + 21 / 2 })
}

## Lanes come from the longest path over the dependencies.
expect LayeredFlowRoute.number(
	[LayeredFlowRoute.no_segment, LayeredFlowRoute.no_segment, LayeredFlowRoute.no_segment].map(|s| { ..s, incoming: [0] }),
	[{ source: 0, target: 1, weight: 1, critical: False, alive: True }, { source: 1, target: 2, weight: 1, critical: False, alive: True }],
)
	== [0, 1, 2]

## Oracle regression: multiline-flow reserves a 497.484375px title on the
## internal flow axis. Actual pinned ELK keeps the raw frame 507.484375px
## tall, then Mermaid trims only the painted frame; D stays at y569.484375.
## Dimensions below are the renderer's measured inputs, not output boxes.
expect {
	source = "flowchart TD\nsubgraph services [A long group title that needs to wrap without colliding with the nodes inside]\nA[First service with a particularly long explanatory label]\nB[Second service<br>With an explicit break]\nC[Third service]\nA -->|A long relationship label explaining why this transition happens| B\nA --> C\nB --> A\nend\nC --> D([Completed])\n"
	fixture = LayeredFlowFixtures.get(source)
	diagram = { ..fixture.diagram, groups: fixture.diagram.groups.map(|group| { ..group, min_width: 0, min_height: 507.484375, padding: { top: 44.021484375, right: 24, bottom: 24, left: 24 } }) }
	setup = LayeredFlowImport.build(
		diagram,
		{
			nodes: [
				{ width: 152, height: 71.79999542236328 },
				{ width: 152, height: 71.79999542236328 },
				{ width: 152, height: 41 },
				{ width: 170.2289276123047, height: 41 },
			],
			edge_labels: [Some({ width: 195.5, height: 51.79999923706055 }), None, None, None],
			group_titles: [{ width: 497.484375, height: 15.021484375 }],
		},
	)
	var $m = setup.model
	for g in [1, 0] {
		$m = LayeredFlowLayers.prepare($m, g, LayeredFlowLayers.features($m, g, True))
	}
	ordered = LayeredFlowOrder.minimize_traced($m, 0, True, False, [])
	$m = ordered.model
	for g in [1, 0] {
		prepared = LayeredFlowPlace.prepare($m, g, True)
		positioned = LayeredFlowPlace.brandes_koepf(prepared, g)
		$m = LayeredFlowRoute.finish(positioned, g, True, False, ordered.randoms.get(g) ?? LayeredFlowRandom.from_seed(1)).model
	}
	group = LayeredFlowGraph.node($m, setup.group_node.get(0) ?? 0)
	d = LayeredFlowGraph.node($m, setup.node_of.get(3) ?? 0)
	root = LayeredFlowGraph.graph($m, 0)
	group.width == 507.484375 and group.height == 479 and group.margin.top == 9.2421875 and d.x + root.offset_x + root.padding.left == 569.484375
}
