app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}

import fuzz.Fuzz
import Flowchart
import FlowGeometry
import FlowLayout

## The layout contract on generated diagrams. The input picks statements
## (nodes, labelled and unlabelled edges, self-loops, parallel edges, edges
## to subgraphs, nested and empty subgraphs, directions) and the sizes of
## everything. Every accepted diagram must lay out with results aligned to
## the diagram, finite, identical when repeated, with every edge starting and
## ending on the outline of what it connects and everything inside the
## bounds.
##
## Cost: the same statements repeated in two independent copies must not
## cost more than 24 times the allocations of one copy. The layout package's
## layered ranking grows faster than linearly, so this bounds that growth
## rather than proving linear cost. Layout must free everything it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	outcome = test(bytes)
	match (Flowchart.parse(diagram_text(bytes, 1)), Flowchart.parse(diagram_text(bytes, 2))) {
		(Ok(small), Ok(large)) => {
			small_sizes = sizes_for(small, bytes)
			large_sizes = sizes_for(large, bytes)
			small_cost = Fuzz.measure_allocs!(|{}| FlowLayout.layout(small, small_sizes))
			large_cost = Fuzz.measure_allocs!(|{}| FlowLayout.layout(large, large_sizes))
			Fuzz.expect_no_leaks!(|{}| FlowLayout.layout(large, large_sizes))
			if large_cost.allocations > 24 * small_cost.allocations + 4096 {
				crash "laying out two copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for one"
			}
		}
		_ => {}
	}
	outcome
}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	text = diagram_text(bytes, 1)
	match Flowchart.parse(text) {
		Err(_) => Fuzz.reject
		Ok(diagram) => {
			sizes = sizes_for(diagram, bytes)
			first = FlowLayout.layout(diagram, sizes)
			if first != FlowLayout.layout(diagram, sizes) {
				crash "laying out the same diagram twice gave different results"
			}
			match check(diagram, first) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}
}

byte : List(U8), U64 -> U8
byte = |bytes, i| bytes.get(i % bytes.len().max(1)) ?? 0

## Up to 24 statements, one per input byte after the first, over at most
## eight node names and four subgraphs, repeated `copies` times with ids
## unique to each copy.
diagram_text : List(U8), U64 -> Str
diagram_text = |bytes, copies| {
	direction = match byte(bytes, 0) % 4 {
		0 => "TD"
		1 => "LR"
		2 => "BT"
		_ => "RL"
	}
	var $lines = ["flowchart ${direction}"]
	for copy in 0..<copies {
		$lines = $lines.concat(statements(bytes, "c${copy.to_str()}"))
	}
	Str.join_with($lines, "\n").concat("\n")
}

statements : List(U8), Str -> List(Str)
statements = |bytes, tag| {
	var $lines = []
	var $open = 0.U64
	var $groups = 0.U64
	for i in 1..<bytes.len().min(25) {
		b = byte(bytes, i)
		a = "n${(b % 8).to_str()}${tag}"
		c = "n${((b / 8) % 8).to_str()}${tag}"
		s = "s${((b / 64) % 4).to_str()}${tag}"
		next = match b % 11 {
			0 => ["  ${a} --> ${c}"]
			1 => ["  ${a} -->|go| ${c}"]
			2 => ["  ${a}{{Check}} -.-> ${c}([Done])"]
			3 => ["  ${a} --> ${a}"]
			4 => ["  ${a} --> ${s}"]
			5 => ["  ${s} -->|to| ${c}"]
			6 =>
				if $open < 3 {
					$open = $open + 1
					$groups = $groups + 1
					["  subgraph g${$groups.to_str()}${tag} [Group]"]
				} else {
					["  ${a}"]
				}
			7 =>
				if $open > 0 {
					$open = $open - 1
					["  end"]
				} else {
					["  ${a} ==> ${c}"]
				}
			8 => ["  subgraph ${s} [Title ${s}]", "    direction LR", "    ${a}", "  end"]
			9 => ["  ${a} --- ${c}", "  ${a} --- ${c}"]
			_ => ["  subgraph e${i.to_str()}${tag} [Empty]", "  end", "  ${a} --> e${i.to_str()}${tag}"]
		}
		$lines = $lines.concat(next)
	}
	for _ in 0..<$open {
		$lines = $lines.append("  end")
	}
	$lines
}

## Sizes like measured ones, chosen by the input: nodes 0 to 255 by 0 to
## 127, labels and titles up to 127 by 31, some sizes zero.
sizes_for : Flowchart.Diagram, List(U8) -> FlowGeometry.Sizes
sizes_for = |diagram, bytes| {
	block = |i| { lines: [], width: (byte(bytes, i) % 128).to_f64(), height: (byte(bytes, i + 1) % 32).to_f64() }
	{
		nodes: diagram.nodes.map_with_index(|_, i| { width: byte(bytes, i * 3).to_f64(), height: (byte(bytes, i * 3 + 1) % 128).to_f64(), label: block(i) }),
		edge_labels: diagram.edges.map_with_index(|edge, i| if (edge.label.is_empty()) None else Some(block(i * 5 + 2))),
		group_titles: diagram.groups.map_with_index(|_, i| block(i * 7 + 1)),
	}
}

finite_point : FlowGeometry.Point -> Bool
finite_point = |p| F64.is_finite(p.x) and F64.is_finite(p.y)

finite_rect : FlowGeometry.Rect -> Bool
finite_rect = |r| F64.is_finite(r.x) and F64.is_finite(r.y) and F64.is_finite(r.width) and F64.is_finite(r.height) and r.width >= 0 and r.height >= 0

## Whether a point lies on a rectangle's outline.
on_outline : FlowGeometry.Point, FlowGeometry.Rect -> Bool
on_outline = |p, r| {
	tol = 0.01
	inside_x = p.x >= r.x - tol and p.x <= r.x + r.width + tol
	inside_y = p.y >= r.y - tol and p.y <= r.y + r.height + tol
	on_x = (p.x - r.x).abs() <= tol or (p.x - r.x - r.width).abs() <= tol
	on_y = (p.y - r.y).abs() <= tol or (p.y - r.y - r.height).abs() <= tol
	inside_x and inside_y and (on_x or on_y)
}

within : FlowGeometry.Point, FlowGeometry.Rect -> Bool
within = |p, b| p.x >= b.x - 0.01 and p.y >= b.y - 0.01 and p.x <= b.x + b.width + 0.01 and p.y <= b.y + b.height + 0.01

check : Flowchart.Diagram, FlowGeometry.Geometry -> Try({}, Str)
check = |diagram, g| {
	if g.nodes.len() != diagram.nodes.len() or g.edges.len() != diagram.edges.len() or g.groups.len() != diagram.groups.len() {
		return Err("results are not aligned with the diagram")
	}
	rects = g.nodes.concat(g.groups).append(g.bounds)
	if !rects.all(finite_rect) or !g.edges.all(|e| e.points.all(finite_point)) {
		return Err("a coordinate is not finite")
	}
	end_rect = |end|
		match end {
			Node(i) => g.nodes.get(i) ?? g.bounds
			Group(i) => g.groups.get(i) ?? g.bounds
		}
	for i in 0..<diagram.edges.len() {
		edge = diagram.edges.get(i) ?? { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }
		points = (g.edges.get(i) ?? { points: [], label: None }).points
		if points.len() < 2 {
			return Err("edge ${i.to_str()} has fewer than two points")
		}
		# An edge starts on its node's box, or inside it on a rounder outline
		# with the box crossed next.
		starts_ok = |ps, r| {
			p = ps.first() ?? { x: 0, y: 0 }
			q = ps.get(1) ?? p
			on_outline(p, r) or (within(p, r) and on_outline(q, r))
		}
		if !starts_ok(points, end_rect(edge.from)) or !starts_ok(points.rev(), end_rect(edge.to)) {
			return Err("edge ${i.to_str()} does not start and end on outlines")
		}
		if !points.all(|p| within(p, g.bounds)) {
			return Err("edge ${i.to_str()} leaves the bounds")
		}
	}
	corners = |r| [{ x: r.x, y: r.y }, { x: r.x + r.width, y: r.y + r.height }]
	if !g.nodes.concat(g.groups).all(|r| corners(r).all(|p| within(p, g.bounds))) {
		return Err("a box leaves the bounds")
	}
	Ok({})
}

target = Fuzz.target_with!({
	name: "mermaid-flowchart-layout",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| diagram_text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz".to_utf8()))
	True
}

## fuzz regression: an edge entering the side of a stadium narrower than it
## is tall must still end inside the node, not past its middle.
expect {
	_ = test([1, 196, 2])
	True
}
