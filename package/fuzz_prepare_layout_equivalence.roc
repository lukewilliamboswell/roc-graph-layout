app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import ForceLayout

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = (byte_at(bytes, 0) % 9).to_u64()
	edge_count = (byte_at(bytes, 1) % 17).to_u64()
	nodes = List.repeat({}, node_count).map_with_index(
		|_, index| {
			width: (byte_at(bytes, 2 + index * 2) % 80).to_f64(),
			height: (byte_at(bytes, 3 + index * 2) % 80).to_f64(),
		},
	)
	denominator = node_count.max(1)
	edge_base = 2 + node_count * 2
	edges = List.repeat({}, edge_count).map_with_index(
		|_, index| {
			from: (byte_at(bytes, edge_base + index * 2).to_u64()) % denominator,
			to: (byte_at(bytes, edge_base + index * 2 + 1).to_u64()) % denominator,
		},
	)
	valid_edges = if node_count == 0 {
		[]
	} else {
		edges
	}
	settings = {
		..ForceLayout.force_defaults,
		node_gap: (byte_at(bytes, edge_base + edge_count * 2) % 48).to_f64(),
		max_iterations: (byte_at(bytes, edge_base + edge_count * 2 + 1) % 40).to_u64(),
	}
	args = { ..ForceLayout.force_default_run, seed: byte_at(bytes, edge_base + edge_count * 2 + 2).to_u32() }
	spec = { nodes, edges: valid_edges }

	match ForceLayout.prepare_force(spec, settings) {
		Err(_) => crash "bounded valid force input failed preparation"
		Ok(prepared) => {
			once = ForceLayout.layout_force(spec, settings, args)
			reused = Ok(ForceLayout.run_force(prepared, args))
			if once == reused and once == ForceLayout.layout_force(spec, settings, args) {
				Fuzz.keep
			} else {
				crash "one-call force layout differed from prepared or repeated layout"
			}
		}
	}
}

target = Fuzz.target_with({
	name: "graph-layout-prepare-equivalence",
	generator: Fuzz.list(Fuzz.u8, 96),
	test,
	show: |input| Str.inspect(input),
})
