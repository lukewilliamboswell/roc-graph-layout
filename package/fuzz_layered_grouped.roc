app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Layered

byte = |bytes, index| bytes.get(index) ?? 0

finite = |p| F64.is_finite(p.x) and F64.is_finite(p.y)

## Numeric structural inputs exercise the core without a parser, font or
## renderer: nested ownership, group endpoints, cycles, parallel edges,
## measured labels, zero sizes and every flow direction.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	n = byte(bytes, 0).to_u64() % 9
	count = byte(bytes, 1).to_u64() % 13
	nodes = List.repeat(0, n).map_with_index(|_, i| { width: byte(bytes, i + 2).to_f64(), height: byte(bytes, i + 11).to_f64() })
	direction = match byte(bytes, 20) % 4 {
		0 => Down
		1 => Up
		2 => Left
		_ => Right
	}
	endpoint = |value| if value < n {
		Node(value)
	} else Group(1 + value - n)
	edges = List.repeat(0, count).map_with_index(|_, i| { from: endpoint(byte(bytes, 21 + i * 2).to_u64() % (n + 2)), to: endpoint(byte(bytes, 22 + i * 2).to_u64() % (n + 2)) })
	group = |children, flow| Group({ children, flow, spacing: Inherit, padding: { top: 12, right: 12, bottom: 12, left: 12 }, min_width: 0, min_height: 0 })
	child_flow = if byte(bytes, 53) % 2 == 0 {
		Together
	} else {
		Separate(
			match byte(bytes, 54) % 4 {
				0 => Down
				1 => Up
				2 => Left
				_ => Right
			},
		)
	}
	inner = group(List.repeat(0, n).map_with_index(|_, i| Node(i)).take_first(n / 2), child_flow)
	outer = group([Nested(inner)], Together)
	root = group([Nested(outer)].concat(List.repeat(0, n).map_with_index(|_, i| Node(i)).drop_first(n / 2)), Together)
	input = {
		..Layered.default_grouped_input,
		nodes,
		edges,
		root,
		edge_labels: if count == 0 {
			[]
		} else [{ edge: 0, width: byte(bytes, 50).to_f64(), height: byte(bytes, 51).to_f64() }],
	}
	settings = { ..Layered.default_grouped_settings, direction }
	args = { ..Layered.default_grouped_run, seed: byte(bytes, 52).to_u32() }
	match (Layered.prepare_grouped(input, settings), Layered.layout_grouped(input, settings, args)) {
		(Ok(prepared), Ok(result)) => {
			if result != Layered.layout_grouped_prepared(prepared, args) or Ok(result) != Layered.layout_grouped(input, settings, args) {
				crash "grouped layout is not deterministic or equivalent to preparation"
			}
			if result.nodes.len() != n or result.layers.len() != n or result.layout.positions.len() != n or result.layout.routes.len() != count or result.attachments.len() != count or result.groups.len() != 3 or result.label_anchors.len() != input.edge_labels.len() {
				crash "grouped layout loses source alignment"
			}
			if !result.layout.positions.all(finite) or !result.label_anchors.all(finite) {
				crash "nonfinite grouped positions"
			}
			for box in result.nodes.concat(result.groups) {
				if !finite(box) or !F64.is_finite(box.width) or !F64.is_finite(box.height) or box.width < 0 or box.height < 0 {
					crash "invalid grouped rectangle"
				}
			}
			for route in result.layout.routes {
				match route {
					Polyline(points) => {
						if !points.all(finite) {
							crash "nonfinite grouped route"
						}
					}
					_ => crash "grouped routing must return a polyline"
				}
			}
			Fuzz.keep
		}
		_ => crash "valid structural graph rejected by grouped layout"
	}
}

expect {
	_ = test([])
	_ = test(List.repeat(255, 64))
	_ = test([5, 10, 1, 4, 20, 5, 0, 4, 0, 20, 3, 10, 15, 2, 0, 20, 10, 4, 0, 10, 2])
	True
}

target = Fuzz.target_with({
	name: "graph-layout-layered-grouped",
	generator: Fuzz.list(Fuzz.u8, 64),
	test,
	show: |input| Str.inspect(input),
})
