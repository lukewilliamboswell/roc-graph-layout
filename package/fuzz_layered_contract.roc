app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Layered

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = (byte_at(bytes, 0) % 8).to_u64()
	nodes = List.repeat({}, node_count).map_with_index(
		|_, index| {
			width: (byte_at(bytes, 1 + index * 2) % 48).to_f64(),
			height: (byte_at(bytes, 2 + index * 2) % 48).to_f64(),
		},
	)

	# Edges always point from a lower source index to a higher target index,
	# giving the layer oracle an independently known acyclic input.
	edge_count = if node_count < 2 {
		0
	} else {
		(byte_at(bytes, 17) % 13).to_u64()
	}
	edges = List.repeat({}, edge_count).map_with_index(
		|_, index| {
			from = (byte_at(bytes, 18 + index * 2).to_u64()) % (node_count - 1)
			span = node_count - from - 1
			{ from, to: from + 1 + (byte_at(bytes, 19 + index * 2).to_u64() % span) }
		},
	)
	input = { ..Layered.default_input, graph: { nodes, edges } }
	settings = {
		..Layered.default_settings,
		node_gap: (byte_at(bytes, 45) % 32).to_f64(),
		layer_gap: (byte_at(bytes, 46) % 64).to_f64(),
		route_style: if byte_at(bytes, 47) % 2 == 0 {
			Straight
		} else {
			Curved
		},
	}

	match Layered.prepare(input, settings) {
		Err(_) => crash "bounded valid layered input failed preparation"
		Ok(prepared) => {
			one_call = Layered.layout(input, settings, Layered.default_run)
			result = Layered.layout_prepared(prepared, Layered.default_run)
			aligned = result.layout.positions.len() == node_count
				and result.layout.routes.len() == edges.len()
					and result.layers.len() == node_count
			forward = edges.fold_with_index(
				True,
				|ok, edge, _| {
					from_layer = result.layers.get(edge.from) ?? 0
					to_layer = result.layers.get(edge.to) ?? 0
					ok and from_layer < to_layer
				},
			)
			valid_backward = result.backward_edges.all(|index| index < edges.len())

			if one_call == Ok(result)
				and Layered.layout(input, settings, Layered.default_run) == one_call
					and aligned
						and forward
							and result.backward_edges.is_empty()
								and valid_backward {
				Fuzz.keep
			} else {
				crash "layered layout violated equivalence, determinism, alignment, or DAG layering"
			}
		}
	}
}

target = Fuzz.target_with({
	name: "graph-layout-layered-contract",
	generator: Fuzz.list(Fuzz.u8, 64),
	test,
	show: |input| Str.inspect(input),
})
