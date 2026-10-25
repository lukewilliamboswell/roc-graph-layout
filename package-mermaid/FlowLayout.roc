import Flowchart
import FlowGeometry
import FlowLayoutAdjust
import FlowLayoutElk

## Where every part of a flowchart goes, given how much room each part
## needs. The arrangement follows Mermaid's default flowchart layout: nodes
## sit in layers along the flow, in the order that crosses fewest edges
## (ties broken as Mermaid breaks them), a subgraph is a box around its
## members with edges crossing its border where they leave their nodes, a
## label sits on its edge in the middle layer the edge passes, and edges run
## as right-angled lines from outline to outline.
##
## Every diagram has a layout, including an empty one; results are
## index-aligned with the diagram and identical for identical input. All
## coordinates are finite.
FlowLayout :: {}.{

	## Lay out a diagram. `sizes` is index-aligned with the diagram; a missing
	## or unusable size counts as zero.
	layout : Flowchart.Diagram, FlowGeometry.Sizes -> FlowGeometry.Geometry
	layout = |diagram, sizes| {
		raw = FlowLayoutElk.layout_raw(diagram, sizes)
		adjusted = FlowLayoutAdjust.adjust(diagram, sizes, raw)
		# A label's background reaches 2 past its text on every side.
		label_sizes = diagram.edges.map_with_index(
			|edge, e|
				match sizes.edge_labels.get(e) ?? None {
					Some(block) => if (edge.label.is_empty()) None else Some({ width: FlowLayout.finite_size(block.width) + 4, height: FlowLayout.finite_size(block.height) + 4 })
					None => None
				},
		)
		title_sizes = diagram.groups.map_with_index(
			|_, g| {
				block = sizes.group_titles.get(g) ?? { lines: [], width: 0, height: 0 }
				{ width: FlowLayout.finite_size(block.width), height: FlowLayout.finite_size(block.height) }
			},
		)
		# Mermaid draws a diamond half a pixel right of the box the engine
		# placed (edges keep to the engine's box).
		nodes = adjusted.nodes.map_with_index(
			|r, i|
				match diagram.nodes.get(i) {
					Ok(node) => if (node.shape == Diamond) { ..r, x: r.x + 0.5 } else r
					Err(_) => r
				},
		)
		FlowLayout.normalise({ nodes, edges: adjusted.edges, groups: adjusted.groups, bounds: { x: 0, y: 0, width: 0, height: 0 } }, label_sizes, title_sizes)
	}

	## Where content starts and how far the drawing's bounds reach past it.
	content_origin : F64
	content_origin = 12

	bounds_margin : F64
	bounds_margin = 8

	Size : { width : F64, height : F64 }

	Point : FlowGeometry.Point

	Rect : FlowGeometry.Rect

	finite_size : F64 -> F64
	finite_size = |value| if (F64.is_finite(value) and value > 0) value else 0

	## The bounds Mermaid gives the drawing: what is drawn (boxes, edges and
	## label backgrounds) plus a margin. A subgraph with no height draws no
	## box, only its title, so only the title counts. Positions stay where the
	## layout put them, content starting at the engine's padding.
	normalise : FlowGeometry.Geometry, List([None, Some(Size)]), List(Size) -> FlowGeometry.Geometry
	normalise = |geometry, label_sizes, title_sizes| {
		var $min_x = F64.infinity
		var $min_y = F64.infinity
		var $max_x = 0 - F64.infinity
		var $max_y = 0 - F64.infinity
		titles = geometry.groups.map_with_index(
			|r, g|
				if r.height > 0 and r.width > 0 {
					r
				} else {
					title = title_sizes.get(g) ?? { width: 0, height: 0 }
					{ x: r.x + r.width / 2 - title.width / 2, y: r.y, width: title.width, height: title.height }
				},
		)
		for r in geometry.nodes.concat(titles) {
			$min_x = $min_x.min(r.x)
			$min_y = $min_y.min(r.y)
			$max_x = $max_x.max(r.x + r.width)
			$max_y = $max_y.max(r.y + r.height)
		}
		for i in 0..<geometry.edges.len() {
			edge = geometry.edges.get(i) ?? { points: [], label: None }
			for p in edge.points {
				$min_x = $min_x.min(p.x)
				$min_y = $min_y.min(p.y)
				$max_x = $max_x.max(p.x)
				$max_y = $max_y.max(p.y)
			}
			match (edge.label, label_sizes.get(i) ?? None) {
				(Some(p), Some(size)) => {
					$min_x = $min_x.min(p.x - size.width / 2)
					$min_y = $min_y.min(p.y - size.height / 2)
					$max_x = $max_x.max(p.x + size.width / 2)
					$max_y = $max_y.max(p.y + size.height / 2)
				}
				_ => {}
			}
		}
		origin = FlowLayout.content_origin
		margin = FlowLayout.bounds_margin
		fix = |v| if (F64.is_finite(v)) v else 0
		fix_point = |p| { x: fix(p.x), y: fix(p.y) }
		fix_rect = |r| { x: fix(r.x), y: fix(r.y), width: fix(r.width), height: fix(r.height) }
		fixed = {
			nodes: geometry.nodes.map(fix_rect),
			groups: geometry.groups.map(fix_rect),
			edges: geometry.edges.map(
				|edge| {
					points: edge.points.map(fix_point),
					label: match edge.label {
						Some(p) => Some(fix_point(p))
						None => None
					},
				},
			),
			bounds: geometry.bounds,
		}
		if !F64.is_finite($min_x) or !F64.is_finite($min_y) or !F64.is_finite($max_x) or !F64.is_finite($max_y) {
			{ ..fixed, bounds: { x: origin - margin, y: origin - margin, width: margin * 2, height: margin * 2 } }
		} else {
			{ ..fixed, bounds: { x: $min_x - margin, y: $min_y - margin, width: fix($max_x - $min_x + margin * 2), height: fix($max_y - $min_y + margin * 2) } }
		}
	}

}

## Lays out `text` with every node 152 by 41, labels 30 by 17 and titles
## 40 by 17, as Mermaid measures common short labels.
test_layout : Str -> [Some(FlowGeometry.Geometry), None]
test_layout = |text|
	match Flowchart.parse(text) {
		Ok(diagram) => {
			box = { width: 152, height: 41, label: { lines: [], width: 0, height: 0 } }
			block = { lines: [], width: 30, height: 17 }
			sizes = {
				nodes: List.repeat(box, diagram.nodes.len()),
				edge_labels: diagram.edges.map(|e| if (e.label.is_empty()) None else Some(block)),
				group_titles: List.repeat({ lines: [], width: 40, height: 17 }, diagram.groups.len()),
			}
			Some(FlowLayout.layout(diagram, sizes))
		}
		Err(_) => None
	}

## A chain reads down the page 40 apart, inside bounds with Mermaid's margin.
expect
	match test_layout("flowchart TD\n  A --> B --> C\n") {
		Some(g) =>
			g.nodes == [{ x: 12, y: 12, width: 152, height: 41 }, { x: 12, y: 93, width: 152, height: 41 }, { x: 12, y: 174, width: 152, height: 41 }]
				and g.bounds == { x: 4, y: 4, width: 168, height: 219 }
				and g.edges.map(|e| e.points) == [[{ x: 88, y: 53 }, { x: 88, y: 93 }], [{ x: 88, y: 134 }, { x: 88, y: 174 }]]
		None => False
	}

## An empty diagram has empty bounds at Mermaid's origin.
expect
	match test_layout("flowchart LR\n") {
		Some(g) => g.nodes == [] and g.bounds == { x: 4, y: 4, width: 16, height: 16 }
		None => False
	}

## Cycles, self-loops, parallel edges, edges to subgraphs and empty and
## nested subgraphs all lay out, aligned with the diagram.
expect {
	text = "flowchart LR\n  a --> a\n  a --> b --> a\n  a --> b\n  subgraph s [S]\n    subgraph t [T]\n      c\n    end\n    subgraph e [E]\n    end\n  end\n  b -->|x| s\n  s --> c\n  c --> e\n"
	match test_layout(text) {
		Some(g) => g.nodes.len() == 3 and g.groups.len() == 3 and g.edges.len() == 7 and g.edges.all(|e| e.points.len() >= 2)
		None => False
	}
}

## A self-loop leaves and re-enters its node on one side, in a lane 20
## away from it.
expect
	match test_layout("flowchart LR\n  A --> A\n") {
		Some(g) =>
			match (g.edges, g.nodes) {
				([edge], [node]) => {
					points = edge.points
					points.len() == 4 and points.all(|p| p.y <= node.y + 0.001) and points.any(|p| (p.y - (node.y - 20)).abs() < 0.001)
				}
				_ => False
			}
		None => False
	}

## A subgraph with its own direction reads its own way: across the page
## inside a diagram that reads down it.
expect
	match test_layout("flowchart TD\n  subgraph s [S]\n    direction LR\n    a --> b\n  end\n  c --> s\n") {
		Some(g) =>
			match g.nodes {
				[a, b, c] => (a.y - b.y).abs() < 0.001 and b.x > a.x + a.width and c.y + c.height < a.y
				_ => False
			}
		None => False
	}

## An empty subgraph is as wide as its title, centred where its edge meets
## it.
expect
	match test_layout("flowchart TD\n  a --> e\n  subgraph e [E]\n  end\n") {
		Some(g) =>
			match (g.groups, g.edges) {
				([frame], [edge]) => {
					end = edge.points.last() ?? { x: 0, y: 0 }
					frame.width == 48 and (frame.x + frame.width / 2 - end.x).abs() < 0.001
				}
				_ => False
			}
		None => False
	}

## A label sits on its edge.
expect
	match test_layout("flowchart TD\n  A -->|yes| B\n") {
		Some(g) =>
			match g.edges {
				[edge] => edge.label != None and edge.points.len() >= 2
				_ => False
			}
		None => False
	}

## Layout is deterministic.
expect test_layout("flowchart TD\n  A --> B & C & D\n  B --> E\n  C --> E\n  E --> A\n") == test_layout("flowchart TD\n  A --> B & C & D\n  B --> E\n  C --> E\n  E --> A\n")

## The bounds cover a label's background, 2 past its text, then Mermaid's
## margin of 8. Recorded: in review-bt Mermaid's view box starts at x 4 with
## the leftmost label's background at x 12.
expect {
	geometry = {
		nodes: [{ x: 60, y: 30, width: 152, height: 41 }],
		edges: [{ points: [{ x: 60, y: 50 }, { x: 40, y: 50 }], label: Some({ x: 29, y: 22.5 }) }],
		groups: [],
		bounds: { x: 0, y: 0, width: 0, height: 0 },
	}
	g = FlowLayout.normalise(geometry, [Some({ width: 34, height: 21 })], [])
	g.bounds == { x: 4, y: 4, width: 216, height: 75 } and g.nodes == geometry.nodes
}

## A subgraph with no height draws only its title, so only the title
## counts. Recorded: in groups-empty Mermaid's view box starts at x 5.40625,
## 8 before the title of an empty subgraph whose box starts at 9.40625.
expect {
	geometry = {
		nodes: [{ x: 110, y: 282, width: 152, height: 41 }],
		edges: [],
		groups: [{ x: 9.40625, y: 287.5, width: 53.1875, height: 0 }],
		bounds: { x: 0, y: 0, width: 0, height: 0 },
	}
	g = FlowLayout.normalise(geometry, [], [{ width: 45.1875, height: 17 }])
	g.bounds.x == 5.40625
}

## Diamonds are drawn half a pixel right of the engine's box, and the
## bounds follow. Recorded: in fan-labels-lr Mermaid's diamond starts at
## x 12.5 and its view box at x 4.5.
expect
	match test_layout("flowchart LR\n  a{Router} --> b\n") {
		Some(g) => (g.nodes.first() ?? { x: 0, y: 0, width: 0, height: 0 }).x == 12.5 and g.bounds.x == 4.5
		None => False
	}

## A drawing that reads upwards is mirrored within its box, as the engine
## mirrors it: coordinates start at the padding, the last node on top.
expect
	match test_layout("flowchart BT\n  A --> B\n") {
		Some(g) => g.nodes == [{ x: 12, y: 93, width: 152, height: 41 }, { x: 12, y: 12, width: 152, height: 41 }] and g.bounds == { x: 4, y: 4, width: 168, height: 138 }
		None => False
	}
