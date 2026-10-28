import LayeredFlowInput
import LayeredFlowGraph

## Structural numeric generators for the core solver's phase contracts.
## Independent component copies exercise cost growth without any parser,
## drawing, text measurement or font dependency.
LayeredFlowFuzz :: {}.{
	byte : List(U8), U64 -> U8
	byte = |bytes, i| bytes.get(i % bytes.len().max(1)) ?? 0
	base_copies : U64
	base_copies = 8
	copies : U64
	copies = 32
	allowed_growth : U64
	allowed_growth = 8
	within_bound : U64, U64 -> Bool
	within_bound = |small, large| large <= LayeredFlowFuzz.allowed_growth * small + 8192
	text : List(U8), U64 -> Str
	text = |bytes, count| Str.inspect((bytes, count))
	loops_text : List(U8), U64 -> Str
	loops_text = LayeredFlowFuzz.text
	Diagram : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes }
	diagram : List(U8), U64 -> [Some(Diagram), None]
	diagram = |bytes, count| LayeredFlowFuzz.generate(bytes, count, False)
	loops_diagram : List(U8), U64 -> [Some(Diagram), None]
	loops_diagram = |bytes, count| LayeredFlowFuzz.generate(bytes, count, True)
	generate : List(U8), U64, Bool -> [Some(Diagram), None]
	generate = |bytes, count, loops| {
		n = 1 + LayeredFlowFuzz.byte(bytes, 0).to_u64() % 8
		e = LayeredFlowFuzz.byte(bytes, 1).to_u64() % 16
		direction = match LayeredFlowFuzz.byte(bytes, 2) % 4 {
			0 => Down
			1 => Up
			2 => Left
			_ => Right
		}
		nodes = List.repeat(0, n * count).map_with_index(
			|_, i| {
				container: if i % 2 == 0 {
					Root
				} else {
					Group(2 * (i / n) + 1)
				},
			},
		)
		groups = List.repeat(0, count * 2).map_with_index(
			|_, g| {
				..LayeredFlowInput.default_group,
				container: if g % 2 == 0 {
					Root
				} else {
					Group(g - 1)
				},
				padding: { top: 12, right: 12, bottom: 12, left: 12 },
			},
		)
		edges = List.repeat(0, count * e).map_with_index(
			|_, i| {
				component = i / e.max(1)
				from = n * component + LayeredFlowFuzz.byte(bytes, 3 + 2 * (i % e.max(1))).to_u64() % n
				to = if loops and i % 3 != 0 {
					from
				} else {
					n * component + LayeredFlowFuzz.byte(bytes, 4 + 2 * (i % e.max(1))).to_u64() % n
				}
				{ from: Node(from), to: Node(to) }
			},
		)
		sizes = {
			nodes: List.repeat(0, n * count).map_with_index(|_, i| { width: LayeredFlowFuzz.byte(bytes, 5 + i % n).to_f64(), height: LayeredFlowFuzz.byte(bytes, 13 + i % n).to_f64() }),
			edge_labels: List.repeat(0, count * e).map_with_index(
				|_, i| if i % 3 == 0 {
					Some({ width: LayeredFlowFuzz.byte(bytes, 21 + i % e.max(1)).to_f64(), height: 17 })
				} else {
					None
				},
			),
			group_titles: List.repeat({ width: 0, height: 0 }, count * 2),
		}
		Some({ diagram: { direction, nodes, groups, edges, spacing: LayeredFlowGraph.blank_spacing, padding: LayeredFlowGraph.no_box }, sizes })
	}
}
