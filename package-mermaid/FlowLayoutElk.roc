import Flowchart
import FlowGeometry
import FlowLayoutGraph
import FlowLayoutImport
import FlowLayoutLayers
import FlowLayoutOrder
import FlowLayoutPlace
import FlowLayoutRandom
import FlowLayoutRoute

## Lays out a flowchart the way Mermaid 12's default layout engine (ELK's
## layered algorithm, configured as Mermaid configures it) does, phase by
## phase: see the `FlowLayout*` modules for each phase.
FlowLayoutElk :: {}.{

	## Graphs from the innermost out, as the engine processes them: a
	## breadth-first list from the drawing, reversed. A subgraph laid out on
	## its own comes before the graph that holds it.
	bottom_up : FlowLayoutGraph.Model -> List(U64)
	bottom_up = |m| {
		var $order = [0]
		# A node can be listed both unlayered and in a layer; each graph is
		# taken once.
		var $seen = List.repeat(False, m.graphs.len()).set(0, True) ?? []
		var $i = 0
		while $i < $order.len() {
			g = $order.get($i) ?? 0
			$i = $i + 1
			graph = FlowLayoutGraph.graph(m, g)
			for n in graph.nodes.concat(graph.layers.fold([], |acc, l| acc.concat(l))) {
				node = FlowLayoutGraph.node(m, n)
				for inside in [node.nested, node.inner] {
					if inside < $seen.len() and !($seen.get(inside) ?? True) {
						$seen = $seen.set(inside, True) ?? []
						$order = $order.append(inside)
					}
				}
			}
		}
		$order.rev()
	}

	## The graph each graph is laid out with: itself for the drawing and for
	## a subgraph laid out on its own, else its parent's.
	run_root : FlowLayoutGraph.Model, U64 -> U64
	run_root = |m, g0| {
		var $g = g0
		var $guard = 0
		while $guard <= m.graphs.len() {
			graph = FlowLayoutGraph.graph(m, $g)
			if graph.separate or graph.parent == FlowLayoutGraph.nil {
				$guard = m.graphs.len() + 1
			} else {
				$g = FlowLayoutGraph.node(m, graph.parent).graph
				$guard = $guard + 1
			}
		}
		$g
	}

	vertical : FlowLayoutGraph.Direction -> Bool
	vertical = |d|
		match d {
			Down | Up => True
			_ => False
		}

	## Import, layer and order every graph.
	ordered : Flowchart.Diagram, FlowGeometry.Sizes -> { setup : FlowLayoutImport.Setup, model : FlowLayoutGraph.Model }
	ordered = |diagram, sizes| {
		r = FlowLayoutElk.ordered_traced(diagram, sizes, False)
		{ setup: r.setup, model: r.model }
	}

	ordered_traced : Flowchart.Diagram, FlowGeometry.Sizes, Bool -> { setup : FlowLayoutImport.Setup, model : FlowLayoutGraph.Model, trace : List(Str), randoms : List(FlowLayoutRandom.Random) }
	ordered_traced = |diagram, sizes, tracing| {
		setup = FlowLayoutImport.build(diagram, sizes)
		layered = FlowLayoutElk.layered(setup.model)
		names = if (tracing) FlowLayoutElk.node_names(diagram, layered) else []
		r = FlowLayoutElk.order(layered, tracing, names)
		{ setup, model: r.model, trace: r.trace, randoms: r.randoms }
	}

	## Layer every graph, innermost first.
	layered : FlowLayoutGraph.Model -> FlowLayoutGraph.Model
	layered = |m0| {
		var $m = m0
		for g in FlowLayoutElk.bottom_up(m0) {
			features = FlowLayoutLayers.features($m, g, FlowLayoutElk.vertical(FlowLayoutGraph.graph($m, g).direction))
			$m = FlowLayoutLayers.prepare($m, g, features)
		}
		$m
	}

	## Order the layers of every graph, with each graph's random numbers for
	## the phases after.
	order : FlowLayoutGraph.Model, Bool, List(Str) -> { model : FlowLayoutGraph.Model, trace : List(Str), randoms : List(FlowLayoutRandom.Random) }
	order = |m0, tracing, names| {
		var $m = m0
		graphs = FlowLayoutElk.bottom_up(m0)
		# One run per graph laid out on its own, innermost first, each with its
		# own random numbers; only the drawing considers declaration order.
		var $trace = []
		var $randoms = List.repeat(FlowLayoutRandom.from_seed(1), $m.graphs.len())
		for root in graphs {
			if root == 0 or FlowLayoutGraph.graph($m, root).separate {
				r = FlowLayoutOrder.minimize_traced($m, root, root == 0, tracing, names)
				$m = r.model
				$trace = $trace.concat(r.trace)
				before = $m
				for g in 0..<$randoms.len() {
					if FlowLayoutElk.run_root(before, g) == root {
						$randoms = $randoms.set(g, r.randoms.get(g) ?? FlowLayoutRandom.from_seed(1)) ?? []
					}
				}
			}
		}
		{ model: $m, trace: $trace, randoms: $randoms }
	}

	Point : FlowGeometry.Point

	Rect : FlowGeometry.Rect

	## The engine's result in the diagram's direction, before Mermaid adjusts
	## it: node and subgraph boxes, and each edge from its source port to its
	## target port with the centre of its label.
	Raw : { nodes : List(Rect), groups : List(Rect), edges : List({ points : List(Point), label : [None, Some(Point)] }) }

	## Lay out a diagram with the engine's phases.
	layout_raw : Flowchart.Diagram, FlowGeometry.Sizes -> Raw
	layout_raw = |diagram, sizes| {
		r = FlowLayoutElk.ordered_traced(diagram, sizes, False)
		FlowLayoutElk.export(diagram, r.setup, FlowLayoutElk.placed(r.model, r.randoms))
	}

	## Place every graph's nodes, route its edges and size it, innermost
	## first.
	placed : FlowLayoutGraph.Model, List(FlowLayoutRandom.Random) -> FlowLayoutGraph.Model
	placed = |m0, randoms| {
		var $m = m0
		for g in FlowLayoutElk.bottom_up(m0) {
			direction = FlowLayoutGraph.graph($m, g).direction
			is_vertical = FlowLayoutElk.vertical(direction)
			$m = FlowLayoutPlace.prepare($m, g, is_vertical)
			$m = FlowLayoutPlace.brandes_koepf($m, g)
			fin = FlowLayoutRoute.finish($m, g, is_vertical, direction == Up, randoms.get(g) ?? FlowLayoutRandom.from_seed(1))
			$m = fin.model
			# A subgraph laid out on its own is a box of fixed size to its
			# parent, which may read the other way round.
			graph = FlowLayoutGraph.graph($m, g)
			if graph.separate {
				box = FlowLayoutGraph.node($m, graph.parent)
				outer = FlowLayoutGraph.graph($m, box.graph).direction
				if FlowLayoutElk.vertical(outer) != is_vertical {
					$m = FlowLayoutGraph.set_node($m, graph.parent, { ..box, width: box.height, height: box.width })
				}
			}
		}
		$m
	}

	## Positions of every graph's content origin, in the reading of the graph
	## it is laid out with, from that graph's top left.
	origins : FlowLayoutGraph.Model -> List(Point)
	origins = |m| {
		var $origins = List.repeat({ x: 0, y: 0 }, m.graphs.len())
		for g in FlowLayoutElk.bottom_up(m).rev() {
			graph = FlowLayoutGraph.graph(m, g)
			base = if graph.parent == FlowLayoutGraph.nil or graph.separate {
				{ x: 0, y: 0 }
			} else {
				parent = FlowLayoutGraph.node(m, graph.parent)
				po = $origins.get(parent.graph) ?? { x: 0, y: 0 }
				{ x: po.x + parent.x, y: po.y + parent.y }
			}
			$origins = $origins.set(g, { x: base.x + graph.offset_x + graph.padding.left, y: base.y + graph.offset_y + graph.padding.top }) ?? $origins
		}
		$origins
	}

	## A point read in a direction, as drawn.
	turn_point : FlowLayoutGraph.Direction, Point -> Point
	turn_point = |direction, p|
		match direction {
			Right => p
			Left => { x: 0 - p.x, y: p.y }
			Down => { x: p.y, y: p.x }
			Up => { x: p.y, y: 0 - p.x }
		}

	turn_rect : FlowLayoutGraph.Direction, Rect -> Rect
	turn_rect = |direction, r|
		match direction {
			Right => r
			Left => { x: 0 - (r.x + r.width), y: r.y, width: r.width, height: r.height }
			Down => { x: r.y, y: r.x, width: r.height, height: r.width }
			Up => { x: r.y, y: 0 - (r.x + r.width), width: r.height, height: r.width }
		}

	## How each graph's coordinates become the drawing's: its run's direction,
	## then a shift that puts a subgraph laid out on its own at its box.
	Placement : { direction : FlowLayoutGraph.Direction, dx : F64, dy : F64 }

	placements : FlowLayoutGraph.Model, List(Point) -> List(Placement)
	placements = |m, bases| {
		var $out = List.repeat({ direction: Right, dx: 0, dy: 0 }, m.graphs.len())
		for g in FlowLayoutElk.bottom_up(m).rev() {
			graph = FlowLayoutGraph.graph(m, g)
			value = if g == 0 or graph.parent == FlowLayoutGraph.nil {
				{ direction: graph.direction, dx: 0, dy: 0 }
			} else if graph.separate {
				box = FlowLayoutGraph.node(m, graph.parent)
				outer = $out.get(box.graph) ?? { direction: Right, dx: 0, dy: 0 }
				outer_origin = bases.get(box.graph) ?? { x: 0, y: 0 }
				drawn = FlowLayoutElk.place_rect(outer, { x: outer_origin.x + box.x, y: outer_origin.y + box.y, width: box.width, height: box.height })
				own = FlowLayoutElk.turn_rect(graph.direction, { x: 0, y: 0, width: graph.width + graph.padding.left + graph.padding.right, height: graph.height + graph.padding.top + graph.padding.bottom })
				{ direction: graph.direction, dx: drawn.x - own.x, dy: drawn.y - own.y }
			} else {
				$out.get(FlowLayoutGraph.node(m, graph.parent).graph) ?? { direction: graph.direction, dx: 0, dy: 0 }
			}
			$out = $out.set(g, value) ?? []
		}
		$out
	}

	place_point : Placement, Point -> Point
	place_point = |pl, p| {
		t = FlowLayoutElk.turn_point(pl.direction, p)
		{ x: t.x + pl.dx, y: t.y + pl.dy }
	}

	place_rect : Placement, Rect -> Rect
	place_rect = |pl, r| {
		t = FlowLayoutElk.turn_rect(pl.direction, r)
		{ ..t, x: t.x + pl.dx, y: t.y + pl.dy }
	}

	export : Flowchart.Diagram, FlowLayoutImport.Setup, FlowLayoutGraph.Model -> Raw
	export = |diagram, setup, m| {
		bases = FlowLayoutElk.origins(m)
		places = FlowLayoutElk.placements(m, bases)
		place_of = |g| places.get(g) ?? { direction: Right, dx: 0, dy: 0 }
		abs_rect = |n| {
			node = FlowLayoutGraph.node(m, n)
			o = bases.get(node.graph) ?? { x: 0, y: 0 }
			FlowLayoutElk.place_rect(place_of(node.graph), { x: o.x + node.x, y: o.y + node.y, width: node.width, height: node.height })
		}
		anchor = |p| {
			port = FlowLayoutGraph.port(m, p)
			node = FlowLayoutGraph.node(m, port.node)
			o = bases.get(node.graph) ?? { x: 0, y: 0 }
			{ x: o.x + node.x + port.x + port.anchor_x, y: o.y + node.y + port.y + port.anchor_y }
		}
		graph_of_edge = |e| FlowLayoutGraph.node(m, FlowLayoutGraph.port(m, FlowLayoutGraph.edge(m, e).source).node).graph
		edge_origin = |e| bases.get(graph_of_edge(e)) ?? { x: 0, y: 0 }
		edges = diagram.edges.map_with_index(
			|_, i| {
				segments0 = setup.segments.get(setup.edge_of.get(i) ?? FlowLayoutGraph.nil) ?? []
				single = setup.edge_of.get(i) ?? FlowLayoutGraph.nil
				segments = if (segments0.is_empty()) (if (single == FlowLayoutGraph.nil) [] else [single]) else segments0
				if segments.is_empty() {
					{ points: [], label: None }
				} else {
					# Every segment of an edge is laid out in the same run.
					pl = place_of(graph_of_edge(segments.first() ?? 0))
					var $bends = []
					var $last = None
					var $label = None
					for s in segments {
						edge = FlowLayoutGraph.edge(m, s)
						o = edge_origin(s)
						seg_bends = edge.bends.map(|b| { x: o.x + b.x, y: o.y + b.y })
						source_point = anchor(edge.source)
						target_point = anchor(edge.target)
						match $last {
							Some(last) => {
								next = seg_bends.first() ?? target_point
								if (last.x - next.x).abs() > 0.001 or (last.y - next.y).abs() > 0.001 {
									$bends = $bends.append(source_point)
								}
							}
							None => {}
						}
						$bends = $bends.concat(seg_bends)
						$last = Some(seg_bends.last() ?? source_point)
						if !edge.labels.is_empty() and $label == None {
							$label = Some({ x: o.x + edge.label_x, y: o.y + edge.label_y })
						}
					}
					first = FlowLayoutGraph.edge(m, segments.first() ?? 0)
					last_edge = FlowLayoutGraph.edge(m, segments.last() ?? 0)
					points = [anchor(first.source)].concat($bends).append(anchor(last_edge.target)).map(|p| FlowLayoutElk.place_point(pl, p))
					flipped = setup.flipped.get(i) ?? False
					{
						points: if (flipped) points.rev() else points,
						label: match $label {
							Some(p) => Some(FlowLayoutElk.place_point(pl, p))
							None => None
						},
					}
				}
			},
		)
		{
			nodes: diagram.nodes.map_with_index(|_, i| abs_rect(setup.node_of.get(i) ?? FlowLayoutGraph.nil)),
			groups: diagram.groups.map_with_index(|_, g| abs_rect(setup.group_node.get(g) ?? FlowLayoutGraph.nil)),
			edges,
		}
	}

	## The layers of every graph as text, for comparison with the engine.
	describe : Flowchart.Diagram, FlowLayoutGraph.Model -> Str
	describe = |diagram, m| {
		names = FlowLayoutElk.node_names(diagram, m)
		name = |n| names.get(n) ?? "?"
		graph_name = |g|
			if g == 0 {
				"root"
			} else {
				name(FlowLayoutGraph.graph(m, g).parent)
			}
		var $lines = []
		for g in FlowLayoutElk.bottom_up(m) {
			$lines = $lines.append("graph ${graph_name(g)}")
			layers = FlowLayoutGraph.graph(m, g).layers
			for l in 0..<layers.len() {
				$lines = $lines.append("  L${l.to_str()}: ${Str.join_with((layers.get(l) ?? []).map(name), " ")}")
			}
		}
		Str.join_with($lines, "\n")
	}

	## A name for every node, as the comparison tools name them.
	node_names : Flowchart.Diagram, FlowLayoutGraph.Model -> List(Str)
	node_names = |diagram, m| {
		plain = |n|
			match FlowLayoutGraph.node(m, n).origin {
				DiagramNode(i) => (diagram.nodes.get(i) ?? { id: "?", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }).id
				Group(g) => (diagram.groups.get(g) ?? { id: "?", title: "", container: Root, direction: Inherit, classes: [] }).id
				_ => "?"
			}
		# The real node reached following first edges backwards or forwards.
		walk = |n, backwards| {
			var $cur = n
			var $result = "?"
			var $going = True
			var $steps = 0
			while $going and $steps < 1000 {
				edges = if (backwards) FlowLayoutGraph.incoming(m, $cur) else FlowLayoutGraph.outgoing(m, $cur)
				match edges.first() {
					Err(_) => {
						$result = "-"
						$going = False
					}
					Ok(e) => {
						next = if (backwards) FlowLayoutGraph.source_node(m, e) else FlowLayoutGraph.target_node(m, e)
						match FlowLayoutGraph.node(m, next).kind {
							Normal => {
								$result = plain(next)
								$going = False
							}
							ExternalPort => {
								$result = "EXT"
								$going = False
							}
							_ => {
								$cur = next
							}
						}
					}
				}
				$steps = $steps + 1
			}
			$result
		}
		name = |n| {
			node = FlowLayoutGraph.node(m, n)
			ends = "(${walk(n, True)}>${walk(n, False)})"
			match node.kind {
				Normal => plain(n)
				LongEdge => "LONG_EDGE${ends}"
				Label => "LABEL${ends}"
				ExternalPort => "EXT${ends}"
			}
		}
		List.repeat(0, m.nodes.len()).map_with_index(|_, n| name(n))
	}
}
