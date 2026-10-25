app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Layered
import Route

## The contract of straight routing and of both layer orderings: for any
## graph (cycles, self-loops, parallel edges, labels), layout succeeds; one
## call equals preparing then laying out; results are deterministic and
## index-aligned; every coordinate is finite; each edge has one layer point
## per layer strictly between its ends; straight routes pass through exactly
## those points; and routing never moves nodes or layer points.
byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

finite = |p| F64.is_finite(p.x) and F64.is_finite(p.y)

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = (byte_at(bytes, 0) % 10).to_u64()
	nodes = List.repeat(0, node_count).map_with_index(|_, i| { width: (byte_at(bytes, 1 + i) % 40).to_f64(), height: (byte_at(bytes, 11 + i) % 30).to_f64() })
	edge_count = if node_count == 0 {
		0
	} else {
		(byte_at(bytes, 21) % 16).to_u64()
	}
	edges = List.repeat(0, edge_count).map_with_index(|_, i| { from: byte_at(bytes, 22 + 2 * i).to_u64() % node_count.max(1), to: byte_at(bytes, 23 + 2 * i).to_u64() % node_count.max(1) })
	labels = if edge_count == 0 {
		[]
	} else {
		[
			{ edge: byte_at(bytes, 54).to_u64() % edge_count, width: (byte_at(bytes, 55) % 30).to_f64(), height: (byte_at(bytes, 56) % 12).to_f64(), placement: Center },
			{ edge: byte_at(bytes, 57).to_u64() % edge_count, width: 6, height: 4, placement: Near(From) },
		]
	}
	direction = match byte_at(bytes, 58) % 4 {
		0 => Down
		1 => Up
		2 => Left
		_ => Right
	}
	ordering = if byte_at(bytes, 59) % 2 == 0 {
		Median
	} else {
		Average
	}
	input = { ..Layered.default_input, graph: { nodes, edges }, edge_labels: labels }
	straight = { ..Layered.default_settings, node_gap: (byte_at(bytes, 60) % 30).to_f64(), layer_gap: (byte_at(bytes, 61) % 50).to_f64(), direction, ordering, routing: Straight }
	orthogonal = { ..straight, routing: Orthogonal({ ..Route.default_settings, max_sweeps: 0 }) }
	match (Layered.layout(input, straight, Layered.default_run), Layered.prepare(input, straight), Layered.layout(input, orthogonal, Layered.default_run)) {
		(Ok(result), Ok(prepared), Ok(routed)) => {
			aligned = result.layout.positions.len() == node_count and result.layout.routes.len() == edge_count and result.layer_points.len() == edge_count and result.layers.len() == node_count and result.label_anchors.len() == labels.len() and result.attachments.is_empty()
			points_hold = edges.fold_with_index(
				True,
				|ok, edge, i| {
					points = result.layer_points.get(i) ?? []
					reversed = result.backward_edges.contains(i)
					low = if reversed {
						result.layers.get(edge.to) ?? 0
					} else {
						result.layers.get(edge.from) ?? 0
					}
					high = if reversed {
						result.layers.get(edge.from) ?? 0
					} else {
						result.layers.get(edge.to) ?? 0
					}
					expected = if high > low {
						high - low - 1
					} else {
						0
					}
					through = match result.layout.routes.get(i) {
						Ok(Polyline(route)) => route.drop_first(1).drop_last(1) == points
						Ok(Line(_, _)) => points.is_empty()
						_ => False
					}
					ok and points.len() == expected and points.all(finite) and through
				},
			)
			all_finite = result.layout.positions.all(finite) and result.label_anchors.all(finite) and F64.is_finite(result.layout.bounds.width) and F64.is_finite(result.layout.bounds.height)
			if !aligned {
				crash "straight layout lost index alignment"
			} else if !points_hold {
				crash "layer points disagree with layers or straight routes"
			} else if !all_finite {
				crash "straight layout produced a non-finite coordinate"
			} else if Layered.layout_prepared(prepared, Layered.default_run) != result {
				crash "one-call layout differs from prepare then layout"
			} else if Layered.layout(input, straight, Layered.default_run) != Ok(result) {
				crash "straight layout is not deterministic"
			} else if routed.layout.positions != result.layout.positions or routed.layer_points != result.layer_points or routed.layers != result.layers {
				crash "orthogonal routing moved nodes or layer points"
			} else {
				Fuzz.keep
			}
		}
		_ => crash "valid layered input was rejected"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-layered-routing",
	generator: Fuzz.list(Fuzz.u8, 64),
	test,
	show: |input| Str.inspect(input),
})

## A small cyclic graph with a self-loop, a parallel edge and labels keeps
## the contract.
expect {
	_ = test([5, 20, 10, 0, 30, 8, 10, 12, 0, 0, 0, 10, 10, 10, 10, 10, 0, 0, 0, 0, 0, 7, 0, 1, 1, 2, 2, 0, 0, 3, 3, 3, 1, 4, 0, 4, 0, 4])
	True
}

## The empty input and an edgeless graph keep the contract.
expect {
	_ = test([])
	_ = test([3])
	True
}
