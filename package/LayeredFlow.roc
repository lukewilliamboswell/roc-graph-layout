import RouteGrid
import LayeredFlowFixtures
import LayeredFlowInput
import Geom
import LayeredFlowGraph
import LayeredFlowImport
import LayeredFlowLayers
import LayeredFlowOrder
import LayeredFlowPlace
import LayeredFlowRandom
import LayeredFlowRoute

## Internal coordinated layered solver. Construction, ranking, ordering,
## placement and routing are pure phases over a numeric port graph.
LayeredFlow :: {}.{

	## Graphs from the innermost out, as the engine processes them: a
	## breadth-first list from the drawing, reversed. A subgraph laid out on
	## its own comes before the graph that holds it.
	bottom_up : LayeredFlowGraph.Model -> List(U64)
	bottom_up = |m| {
		var $order = [0]
		# A node can be listed both unlayered and in a layer; each graph is
		# taken once.
		var $seen = List.repeat(False, m.graphs.len()).set(0, True) ?? []
		var $i = 0
		while $i < $order.len() {
			g = $order.get($i) ?? 0
			$i = $i + 1
			graph = LayeredFlowGraph.graph(m, g)
			for n in graph.nodes.concat(graph.layers.fold([], |acc, l| acc.concat(l))) {
				node = LayeredFlowGraph.node(m, n)
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
	run_root : LayeredFlowGraph.Model, U64 -> U64
	run_root = |m, g0| {
		var $g = g0
		var $guard = 0
		while $guard <= m.graphs.len() {
			graph = LayeredFlowGraph.graph(m, $g)
			if graph.separate or graph.parent == LayeredFlowGraph.nil {
				$guard = m.graphs.len() + 1
			} else {
				$g = LayeredFlowGraph.node(m, graph.parent).graph
				$guard = $guard + 1
			}
		}
		$g
	}

	vertical : LayeredFlowGraph.Direction -> Bool
	vertical = |d|
		match d {
			Down | Up => True
			_ => False
		}

	## Import, layer and order every graph.
	ordered : LayeredFlowInput.Input, LayeredFlowInput.Sizes -> { setup : LayeredFlowImport.Setup, model : LayeredFlowGraph.Model }
	ordered = |diagram, sizes| {
		r = LayeredFlow.ordered_traced(diagram, sizes, False)
		{ setup: r.setup, model: r.model }
	}

	ordered_traced : LayeredFlowInput.Input, LayeredFlowInput.Sizes, Bool -> { setup : LayeredFlowImport.Setup, model : LayeredFlowGraph.Model, trace : List(Str), randoms : List(LayeredFlowRandom.Random) }
	ordered_traced = |diagram, sizes, tracing| {
		setup = LayeredFlowImport.build(diagram, sizes)
		layered = LayeredFlow.layered(setup.model)
		names = if (tracing) List.repeat("", layered.nodes.len()) else []
		r = LayeredFlow.order(layered, tracing, names)
		{ setup, model: r.model, trace: r.trace, randoms: r.randoms }
	}

	## Layer every graph, innermost first.
	layered : LayeredFlowGraph.Model -> LayeredFlowGraph.Model
	layered = |m0| {
		var $m = m0
		for g in LayeredFlow.bottom_up(m0) {
			features = LayeredFlowLayers.features($m, g, LayeredFlow.vertical(LayeredFlowGraph.graph($m, g).direction))
			$m = LayeredFlowLayers.prepare($m, g, features)
		}
		$m
	}

	## Order the layers of every graph, with each graph's random numbers for
	## the phases after.
	order : LayeredFlowGraph.Model, Bool, List(Str) -> { model : LayeredFlowGraph.Model, trace : List(Str), randoms : List(LayeredFlowRandom.Random) }
	order = |m0, tracing, names| LayeredFlow.order_seeded(m0, tracing, names, 1)

	order_seeded : LayeredFlowGraph.Model, Bool, List(Str), I64 -> { model : LayeredFlowGraph.Model, trace : List(Str), randoms : List(LayeredFlowRandom.Random) }
	order_seeded = |m0, tracing, names, seed| {
		var $m = m0
		graphs = LayeredFlow.bottom_up(m0)
		# One run per graph laid out on its own, innermost first, each with its
		# own random numbers; only the drawing considers declaration order.
		var $trace = []
		var $randoms = List.repeat(LayeredFlowRandom.from_seed(seed), $m.graphs.len())
		for root in graphs {
			if root == 0 or LayeredFlowGraph.graph($m, root).separate {
				r = LayeredFlowOrder.minimize_seeded($m, root, root == 0, tracing, names, seed)
				$m = r.model
				$trace = $trace.concat(r.trace)
				before = $m
				for g in 0..<$randoms.len() {
					if LayeredFlow.run_root(before, g) == root {
						$randoms = $randoms.set(g, r.randoms.get(g) ?? LayeredFlowRandom.from_seed(seed)) ?? []
					}
				}
			}
		}
		{ model: $m, trace: $trace, randoms: $randoms }
	}

	Point : Geom.Point

	Rect : Geom.Rect

	## The engine's result in the diagram's direction, before caller-specific adjustments to
	## it: node and subgraph boxes, and each edge from its source port to its
	## target port with the centre of its label.
	Raw : { nodes : List(Rect), groups : List(Rect), edges : List({ points : List(Point), label : [None, Some(Point)] }) }

	## Lay out a diagram with the engine's phases.
	layout_raw : LayeredFlowInput.Input, LayeredFlowInput.Sizes -> Raw
	layout_raw = |diagram, sizes| {
		r = LayeredFlow.ordered_traced(diagram, sizes, False)
		LayeredFlow.export(diagram, r.setup, LayeredFlow.placed(r.model, r.randoms))
	}

	## Place every graph's nodes, route its edges and size it, innermost
	## first.
	placed : LayeredFlowGraph.Model, List(LayeredFlowRandom.Random) -> LayeredFlowGraph.Model
	placed = |m0, randoms| LayeredFlow.placed_with_margins(m0, randoms, |model, _| model)

	placed_with_margins : LayeredFlowGraph.Model, List(LayeredFlowRandom.Random), (LayeredFlowGraph.Model, U64 -> LayeredFlowGraph.Model) -> LayeredFlowGraph.Model
	placed_with_margins = |m0, randoms, apply| {
		var $m = m0
		for g in LayeredFlow.bottom_up(m0) {
			direction = LayeredFlowGraph.graph($m, g).direction
			is_vertical = LayeredFlow.vertical(direction)
			$m = LayeredFlowPlace.prepare_with_margins($m, g, is_vertical, apply)
			$m = LayeredFlowPlace.brandes_koepf($m, g)
			fin = LayeredFlowRoute.finish($m, g, is_vertical, direction == Up, randoms.get(g) ?? crash "random states are graph aligned")
			$m = fin.model
			# A subgraph laid out on its own is a box of fixed size to its
			# parent, which may read the other way round.
			graph = LayeredFlowGraph.graph($m, g)
			if graph.separate {
				box = LayeredFlowGraph.node($m, graph.parent)
				outer = LayeredFlowGraph.graph($m, box.graph).direction
				if LayeredFlow.vertical(outer) != is_vertical {
					$m = LayeredFlowGraph.set_node($m, graph.parent, { ..box, width: box.height, height: box.width })
				}
			}
		}
		$m
	}

	## Positions of every graph's content origin, in the reading of the graph
	## it is laid out with, from that graph's top left.
	origins : LayeredFlowGraph.Model -> List(Point)
	origins = |m| {
		var $origins = List.repeat({ x: 0, y: 0 }, m.graphs.len())
		for g in LayeredFlow.bottom_up(m).rev() {
			graph = LayeredFlowGraph.graph(m, g)
			base = if graph.parent == LayeredFlowGraph.nil or graph.separate {
				{ x: 0, y: 0 }
			} else {
				parent = LayeredFlowGraph.node(m, graph.parent)
				po = $origins.get(parent.graph) ?? { x: 0, y: 0 }
				{ x: po.x + parent.x, y: po.y + parent.y }
			}
			$origins = $origins.set(g, { x: base.x + graph.offset_x + graph.padding.left, y: base.y + graph.offset_y + graph.padding.top }) ?? $origins
		}
		$origins
	}

	## A point read in a direction, as drawn.
	turn_point : LayeredFlowGraph.Direction, Point -> Point
	turn_point = |direction, p|
		match direction {
			Right => p
			Left => { x: 0 - p.x, y: p.y }
			Down => { x: p.y, y: p.x }
			Up => { x: p.y, y: 0 - p.x }
		}

	turn_rect : LayeredFlowGraph.Direction, Rect -> Rect
	turn_rect = |direction, r|
		match direction {
			Right => r
			Left => { x: 0 - (r.x + r.width), y: r.y, width: r.width, height: r.height }
			Down => { x: r.y, y: r.x, width: r.height, height: r.width }
			Up => { x: r.y, y: 0 - (r.x + r.width), width: r.height, height: r.width }
		}

	## How each graph's coordinates become the drawing's: its run's direction,
	## then a shift that puts a subgraph laid out on its own at its box.
	Placement : { direction : LayeredFlowGraph.Direction, dx : F64, dy : F64 }

	placements : LayeredFlowGraph.Model, List(Point) -> List(Placement)
	placements = |m, bases| {
		var $out = List.repeat({ direction: Right, dx: 0, dy: 0 }, m.graphs.len())
		for g in LayeredFlow.bottom_up(m).rev() {
			graph = LayeredFlowGraph.graph(m, g)
			value = if g == 0 or graph.parent == LayeredFlowGraph.nil {
				# The engine mirrors a drawing that reads right to left or
				# upwards within its own box, so coordinates stay positive.
				own = LayeredFlow.turn_rect(graph.direction, { x: 0, y: 0, width: graph.width + graph.padding.left + graph.padding.right, height: graph.height + graph.padding.top + graph.padding.bottom })
				{ direction: graph.direction, dx: 0 - own.x, dy: 0 - own.y }
			} else if graph.separate {
				box = LayeredFlowGraph.node(m, graph.parent)
				outer = $out.get(box.graph) ?? { direction: Right, dx: 0, dy: 0 }
				outer_origin = bases.get(box.graph) ?? { x: 0, y: 0 }
				drawn = LayeredFlow.place_rect(outer, { x: outer_origin.x + box.x, y: outer_origin.y + box.y, width: box.width, height: box.height })
				own = LayeredFlow.turn_rect(graph.direction, { x: 0, y: 0, width: graph.width + graph.padding.left + graph.padding.right, height: graph.height + graph.padding.top + graph.padding.bottom })
				{ direction: graph.direction, dx: drawn.x - own.x, dy: drawn.y - own.y }
			} else {
				$out.get(LayeredFlowGraph.node(m, graph.parent).graph) ?? { direction: graph.direction, dx: 0, dy: 0 }
			}
			$out = $out.set(g, value) ?? []
		}
		$out
	}

	place_point : Placement, Point -> Point
	place_point = |pl, p| {
		t = LayeredFlow.turn_point(pl.direction, p)
		{ x: t.x + pl.dx, y: t.y + pl.dy }
	}

	place_rect : Placement, Rect -> Rect
	place_rect = |pl, r| {
		t = LayeredFlow.turn_rect(pl.direction, r)
		{ ..t, x: t.x + pl.dx, y: t.y + pl.dy }
	}

	export : LayeredFlowInput.Input, LayeredFlowImport.Setup, LayeredFlowGraph.Model -> Raw
	export = |diagram, setup, m| {
		bases = LayeredFlow.origins(m)
		places = LayeredFlow.placements(m, bases)
		place_of = |g| places.get(g) ?? { direction: Right, dx: 0, dy: 0 }
		abs_rect = |n| {
			node = LayeredFlowGraph.node(m, n)
			o = bases.get(node.graph) ?? { x: 0, y: 0 }
			LayeredFlow.place_rect(place_of(node.graph), { x: o.x + node.x, y: o.y + node.y, width: node.width, height: node.height })
		}
		anchor = |p| {
			port = LayeredFlowGraph.port(m, p)
			node = LayeredFlowGraph.node(m, port.node)
			o = bases.get(node.graph) ?? { x: 0, y: 0 }
			{ x: o.x + node.x + port.x + port.anchor_x, y: o.y + node.y + port.y + port.anchor_y }
		}
		graph_of_edge = |e| LayeredFlowGraph.node(m, LayeredFlowGraph.port(m, LayeredFlowGraph.edge(m, e).source).node).graph
		edge_origin = |e| bases.get(graph_of_edge(e)) ?? { x: 0, y: 0 }
		node_rects = diagram.nodes.map_with_index(|_, i| abs_rect(setup.node_of.get(i) ?? LayeredFlowGraph.nil))
		edges = diagram.edges.map_with_index(
			|_, i| {
				segments0 = setup.segments.get(setup.edge_of.get(i) ?? LayeredFlowGraph.nil) ?? []
				single = setup.edge_of.get(i) ?? LayeredFlowGraph.nil
				segments = if (segments0.is_empty()) (if (single == LayeredFlowGraph.nil) [] else [single]) else segments0
				if segments.is_empty() {
					{ points: [], label: None }
				} else {
					var $bends = []
					var $last = None
					var $label = None
					for s in segments {
						edge = LayeredFlowGraph.edge(m, s)
						pl = place_of(graph_of_edge(s))
						o = edge_origin(s)
						seg_bends = edge.bends.map(|b| { x: o.x + b.x, y: o.y + b.y })
						source_point = anchor(edge.source)
						target_point = anchor(edge.target)
						match $last {
							Some(last) => {
								if last.placement == pl {
									# Preserve the original local comparison in a shared
									# frame, including its floating-point threshold.
									next = seg_bends.first() ?? target_point
									if (last.raw.x - next.x).abs() > 0.001 or (last.raw.y - next.y).abs() > 0.001 {
										$bends = $bends.append(LayeredFlow.place_point(pl, source_point))
									}
								} else {
									# Independent child layouts have their own direction
									# and origin. Join their actual world-space ports with
									# the router's shared obstacle-aware path search.
									next = LayeredFlow.place_point(pl, source_point)
									connector = LayeredFlow.connect_frames(last.target, next, node_rects)
									$bends = $bends.concat(connector)
								}
							}
							None => {}
						}
						$bends = $bends.concat(seg_bends.map(|p| LayeredFlow.place_point(pl, p)))
						$last = Some({ raw: seg_bends.last() ?? source_point, target: LayeredFlow.place_point(pl, target_point), placement: pl })
						if !edge.labels.is_empty() and $label == None {
							$label = Some(LayeredFlow.place_point(pl, { x: o.x + edge.label_x, y: o.y + edge.label_y }))
						}
					}
					first = LayeredFlowGraph.edge(m, segments.first() ?? 0)
					last_edge = LayeredFlowGraph.edge(m, segments.last() ?? 0)
					first_place = place_of(graph_of_edge(segments.first() ?? 0))
					last_place = place_of(graph_of_edge(segments.last() ?? 0))
					points = [LayeredFlow.place_point(first_place, anchor(first.source))].concat($bends).append(LayeredFlow.place_point(last_place, anchor(last_edge.target)))
					flipped = setup.flipped.get(i) ?? False
					{
						points: if (flipped) points.rev() else points,
						label: $label,
					}
				}
			},
		)
		{
			nodes: node_rects,
			groups: diagram.groups.map_with_index(|_, g| abs_rect(setup.group_node.get(g) ?? LayeredFlowGraph.nil)),
			edges,
		}
	}

	connect_frames : Point, Point, List(Rect) -> List(Point)
	connect_frames = |a, b, nodes| {
		point = |p| { x: Geom.saturate(p.x), y: Geom.saturate(p.y) }
		start = point(a)
		finish = point(b)
		boxes = nodes.map(|r| { min_x: Geom.saturate(r.x), min_y: Geom.saturate(r.y), max_x: Geom.saturate(r.x + r.width), max_y: Geom.saturate(r.y + r.height) })
		path = RouteGrid.shortest(start, finish, boxes, 0, 0, [])
		if path.is_empty() {
			# Overlapping or numerically saturated geometry can prevent a clear
			# route. Retain a finite orthogonal connection in those cases.
			[start, { x: start.x, y: finish.y }, finish]
		} else {
			path
		}
	}

}

## Test helper: the engine's result for `text` with every node 152 by 41
## and titles 10 by 17, as Mermaid measured the recorded runs below.
test_raw : Str -> LayeredFlow.Raw
test_raw = |text| {
	fixture = LayeredFlowFixtures.get(text)
	LayeredFlow.layout_raw(fixture.diagram, fixture.sizes)
}

## Every phase together. Recorded: ELK places a, b, c, d, e at (12, 93),
## (204, 12), (204, 93), (204, 174), (396, 93) and bends a --> b at x 184.
expect {
	raw = test_raw("flowchart LR\n    a --> b\n    a --> c\n    a --> d\n    b --> e\n    c --> e\n    d --> e\n")
	raw.nodes.map(|r| (r.x, r.y)) == [(12, 93), (204, 12), (204, 93), (204, 174), (396, 93)]
		and (raw.edges.first() ?? { points: [], label: None }).points == [{ x: 164, y: 108.25 }, { x: 184, y: 108.25 }, { x: 184, y: 32.5 }, { x: 204, y: 32.5 }]
}

## A subgraph laid out on its own reads its own way inside a diagram that
## reads the other way, and is a box of fixed size to it. Recorded: ELK
## puts s at (12, 12) sized 376 by 109 with a, b at (36, 56) and
## (212, 56), and t at (164, 161) sized 212 by 174 with c, d at (200, 205)
## and (200, 270), and e at (200, 385).
expect {
	raw = test_raw("flowchart TD\n    subgraph s [S]\n        direction LR\n        a --> b\n    end\n    subgraph t [T]\n        direction LR\n        c --> d\n    end\n    s --> t\n    d --> e\n")
	raw.nodes.map(|r| (r.x, r.y)) == [(36, 56), (212, 56), (200, 205), (200, 270), (200, 385)]
		and raw.groups == [{ x: 12, y: 12, width: 376, height: 109 }, { x: 164, y: 161, width: 212, height: 174 }]
}

## Every nested graph is processed exactly once, innermost first.
expect {
	fixture = LayeredFlowFixtures.get("flowchart TD\n    subgraph g [G]\n        subgraph h [H]\n            direction LR\n            a\n        end\n        subgraph k [K]\n            b\n        end\n    end\n    b --> c\n")
	order = LayeredFlow.bottom_up(LayeredFlow.ordered(fixture.diagram, fixture.sizes).model)
	order.len() == 4 and order.last() == Ok(0) and order.all(|g| order.count_if(|x| x == g) == 1)
}

## Absent geometric reservations preserve the complete default model bits.
expect {
	fixture = LayeredFlowFixtures.get("flowchart LR\na --> b\nb --> a\na --> b\na --> a\nsubgraph g [Group]\nc --> d\nend\nisolated")
	ordered = LayeredFlow.ordered_traced(fixture.diagram, fixture.sizes, False)
	LayeredFlow.placed(ordered.model, ordered.randoms) == LayeredFlow.placed_with_margins(ordered.model, ordered.randoms, |model, _| model)
}
