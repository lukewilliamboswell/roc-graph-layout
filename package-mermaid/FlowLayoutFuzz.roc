import Flowchart
import FlowGeometry

## Flowcharts generated from fuzz bytes for the layout's phase targets
## (`fuzz_flowchart_layout_*.roc`): the same statements written once or
## several times over with ids unique to each copy, so a target can compare
## the cost of one copy against several. Statements cover chains, labelled
## and parallel edges, self-loops, edges to subgraphs, nested, empty and
## directed subgraphs, and long edges back up the flow.
FlowLayoutFuzz :: {}.{

	byte : List(U8), U64 -> U8
	byte = |bytes, i| bytes.get(i % bytes.len().max(1)) ?? 0

	## Up to 24 statements for a single copy, or 8 per copy when there are
	## several (keeping many copies within Mermaid's 500 edges), one per
	## input byte after the first, over at most eight node names and four
	## subgraphs per copy.
	text : List(U8), U64 -> Str
	text = |bytes, copies| {
		direction = match FlowLayoutFuzz.byte(bytes, 0) % 4 {
			0 => "TD"
			1 => "LR"
			2 => "BT"
			_ => "RL"
		}
		var $lines = ["flowchart ${direction}"]
		for copy in 0..<copies {
			$lines = $lines.concat(FlowLayoutFuzz.statements(bytes, "c${copy.to_str()}", FlowLayoutFuzz.limit(copies)))
		}
		Str.join_with($lines, "\n").concat("\n")
	}

	limit : U64 -> U64
	limit = |copies| if (copies <= 1) 25 else 9

	statements : List(U8), Str, U64 -> List(Str)
	statements = |bytes, tag, end| {
		var $lines = []
		var $open = 0.U64
		var $groups = 0.U64
		for i in 1..<bytes.len().min(end) {
			b = FlowLayoutFuzz.byte(bytes, i)
			a = "n${(b % 8).to_str()}${tag}"
			c = "n${((b / 8) % 8).to_str()}${tag}"
			s = "s${((b / 64) % 4).to_str()}${tag}"
			next = match b % 12 {
				0 => ["  ${a} --> ${c}"]
				1 => ["  ${a} -->|go| ${c}"]
				2 => ["  ${a}{{Check}} -.-> ${c}([Done])"]
				3 => ["  ${a} --> ${a}", "  ${a} -->|again| ${a}"]
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
				8 => ["  subgraph ${s} [Title ${s}]", "    direction LR", "    ${a} --> ${c}", "  end"]
				9 => ["  ${a} --- ${c}", "  ${a} --- ${c}"]
				10 => ["  ${a} --> ${c} --> ${a}"]
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
	## 127, labels and titles up to 127 by 31, some sizes zero. Copies get
	## the same sizes.
	sizes : Flowchart.Diagram, List(U8), U64 -> FlowGeometry.Sizes
	sizes = |diagram, bytes, copies| {
		per_copy = |count| (count / copies.max(1)).max(1)
		node_count = per_copy(diagram.nodes.len())
		edge_count = per_copy(diagram.edges.len())
		group_count = per_copy(diagram.groups.len())
		block = |i| { lines: [], width: (FlowLayoutFuzz.byte(bytes, i) % 128).to_f64(), height: (FlowLayoutFuzz.byte(bytes, i + 1) % 32).to_f64() }
		{
			nodes: diagram.nodes.map_with_index(
				|_, i0| {
					i = i0 % node_count
					{ width: FlowLayoutFuzz.byte(bytes, i * 3).to_f64(), height: (FlowLayoutFuzz.byte(bytes, i * 3 + 1) % 128).to_f64(), label: block(i) }
				},
			),
			edge_labels: diagram.edges.map_with_index(|edge, i0| if (edge.label.is_empty()) None else Some(block((i0 % edge_count) * 5 + 2))),
			group_titles: diagram.groups.map_with_index(|_, i0| block((i0 % group_count) * 7 + 1)),
		}
	}

	## The diagram and sizes for `copies` copies, when the parser accepts it.
	diagram : List(U8), U64 -> [Some({ diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes }), None]
	diagram = |bytes, copies|
		match Flowchart.parse(FlowLayoutFuzz.text(bytes, copies)) {
			Ok(d) => Some({ diagram: d, sizes: FlowLayoutFuzz.sizes(d, bytes, copies) })
			Err(_) => None
		}

	## Like `text`, but most statements give a node one to three self-loops,
	## some labelled, beside ordinary edges.
	loops_text : List(U8), U64 -> Str
	loops_text = |bytes, copies| {
		direction = match FlowLayoutFuzz.byte(bytes, 0) % 4 {
			0 => "TD"
			1 => "LR"
			2 => "BT"
			_ => "RL"
		}
		var $lines = ["flowchart ${direction}"]
		for copy in 0..<copies {
			tag = "c${copy.to_str()}"
			for i in 1..<bytes.len().min(FlowLayoutFuzz.limit(copies)) {
				b = FlowLayoutFuzz.byte(bytes, i)
				a = "n${(b % 8).to_str()}${tag}"
				c = "n${((b / 8) % 8).to_str()}${tag}"
				loops = (b / 64).to_u64() % 3 + 1
				for k in 0..<loops {
					$lines = $lines.append(if (k == 1) "  ${a} -->|retry| ${a}" else "  ${a} --> ${a}")
				}
				if b % 3 == 0 {
					$lines = $lines.append("  ${a} --> ${c}")
				}
			}
		}
		Str.join_with($lines, "\n").concat("\n")
	}

	loops_diagram : List(U8), U64 -> [Some({ diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes }), None]
	loops_diagram = |bytes, copies|
		match Flowchart.parse(FlowLayoutFuzz.loops_text(bytes, copies)) {
			Ok(d) => Some({ diagram: d, sizes: FlowLayoutFuzz.sizes(d, bytes, copies) })
			Err(_) => None
		}

	## The cost comparison sets `base_copies` copies against `copies`: one
	## copy alone can be too small to need work that two already do (a
	## crossing to remove, say), which would look like growth that is not
	## there, and so can the number of sweeps a search needs while a diagram
	## is still small. Linear work costs four times as much in four times as
	## many copies; the bound leaves twice that.
	base_copies : U64
	base_copies = 8

	copies : U64
	copies = 32

	allowed_growth : U64
	allowed_growth = 8

	## Whether `large` allocations stay within the bound of `small`'s.
	within_bound : U64, U64 -> Bool
	within_bound = |small, large| large <= FlowLayoutFuzz.allowed_growth * small + 8192
}
