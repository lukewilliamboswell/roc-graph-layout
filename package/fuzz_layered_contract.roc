app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Layered
import Route

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
	# Constraint pairs are selected from nodes with identical structural depth:
	# with the generated forward graph this is always safe when the graph has no
	# edges, while a simple first/last relationship is safe for larger DAGs.
	layer_constraints = if node_count == 0 {
		[]
	} else if edge_count == 0 and node_count > 1 {
		[SameLayer({ first: 0, second: 1 }), FirstLayer(0)]
	} else {
		[FirstLayer(0)]
	}
	order_constraints = if edge_count == 0 and node_count > 1 {
		[{ before: 1, after: 0 }]
	} else {
		[]
	}
	non_ranking_edges = if edge_count > 0 and byte_at(bytes, 48) % 2 == 1 {
		[edge_count - 1]
	} else {
		[]
	}
	boundaries = if node_count > 0 and byte_at(bytes, 49) % 2 == 1 {
		[{ node: 0, outline: Ellipse }]
	} else {
		[]
	}
	edge_labels = if edge_count > 0 {
		label_edge = byte_at(bytes, 50).to_u64() % edge_count
		[
			{ edge: label_edge, width: (byte_at(bytes, 51) % 24).to_f64(), height: (byte_at(bytes, 52) % 12).to_f64(), placement: Center },
			{ edge: label_edge, width: (byte_at(bytes, 53) % 12).to_f64(), height: (byte_at(bytes, 54) % 8).to_f64(), placement: Near(To) },
		]
	} else {
		[]
	}
	input = { ..Layered.default_input, graph: { nodes, edges }, boundaries, edge_labels, layer_constraints, order_constraints, non_ranking_edges }
	settings = {
		..Layered.default_settings,
		node_gap: (byte_at(bytes, 45) % 32).to_f64(),
		layer_gap: (byte_at(bytes, 46) % 64).to_f64(),
		routing: { ..Route.default_settings, bend_penalty: (byte_at(bytes, 47) % 32).to_f64() },
	}

	match Layered.prepare(input, settings) {
		Err(_) => crash "bounded valid layered input failed preparation"
		Ok(prepared) => {
			hints = LayeredInternalsForFuzz.positions(node_count).map_with_index(|point, node| { node, x: point.x, y: point.y })
			run_args = if byte_at(bytes, 55) % 2 == 0 {
				Layered.default_run
			} else {
				{ hints, stability: PreserveOrder }
			}
			one_call = Layered.layout(input, settings, run_args)
			result = Layered.layout_prepared(prepared, run_args)
			aligned = result.layout.positions.len() == node_count
				and result.layout.routes.len() == edges.len()
					and result.layers.len() == node_count
						and result.attachments.len() == edges.len()
							and result.label_anchors.len() == edge_labels.len()
			forward = edges.fold_with_index(
				True,
				|ok, edge, index| {
					from_layer = result.layers.get(edge.from) ?? 0
					to_layer = result.layers.get(edge.to) ?? 0
					ok and (non_ranking_edges.contains(index) or from_layer < to_layer)
				},
			)
			constraints_hold = layer_constraints.all(
				|rule| match rule {
					SameLayer(pair) => (result.layers.get(pair.first) ?? 0) == (result.layers.get(pair.second) ?? 0)
					BeforeLayer(item) => (result.layers.get(item.second) ?? 0) >= (result.layers.get(item.first) ?? 0) + item.minimum_span
					FirstLayer(node) => (result.layers.get(node) ?? 0) == (result.layers.fold(result.layers.first() ?? 0, |lowest, rank| lowest.min(rank)))
					LastLayer(node) => (result.layers.get(node) ?? 0) == result.layers.fold(0, |highest, rank| highest.max(rank))
				},
			)
			order_holds = order_constraints.all(
				|rule| (result.layout.positions.get(rule.before) ?? { x: 0, y: 0 }).x <= (result.layout.positions.get(rule.after) ?? { x: 0, y: 0 }).x,
			)
			valid_backward = result.backward_edges.all(|index| index < edges.len())

			if one_call == Ok(result)
				and Layered.layout(input, settings, run_args) == one_call
					and aligned
						and forward
							and constraints_hold
								and order_holds
									and result.backward_edges.is_empty()
										and valid_backward {
				Fuzz.keep
			} else {
				crash "layered layout violated equivalence, determinism, alignment, or DAG layering"
			}
		}
	}
}

# Deterministic finite previous positions for the solve-only stability input.
LayeredInternalsForFuzz :: {}.{
	positions = |count| List.repeat({}, count).map_with_index(|_, i| { x: (count - i).to_f64(), y: i.to_f64() })
}

target = Fuzz.target_with({
	name: "graph-layout-layered-contract",
	generator: Fuzz.list(Fuzz.u8, 64),
	test,
	show: |input| Str.inspect(input),
})
