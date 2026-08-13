app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import StressLayout

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

finite_point = |p| F64.is_finite(p.x) and F64.is_finite(p.y)

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = 1 + (byte_at(bytes, 0) % 7).to_u64()
	edge_count = (byte_at(bytes, 1) % 13).to_u64()
	nodes = List.repeat({}, node_count).map_with_index(
		|_, i| {
			width: (1 + byte_at(bytes, 2 + i * 2) % 40).to_f64(),
			height: (1 + byte_at(bytes, 3 + i * 2) % 40).to_f64(),
		},
	)
	edge_base = 2 + node_count * 2
	random_edges = List.repeat({}, edge_count).map_with_index(
		|_, i| {
			from: byte_at(bytes, edge_base + i * 2).to_u64() % node_count,
			to: byte_at(bytes, edge_base + i * 2 + 1).to_u64() % node_count,
		},
	)
	chain = # non-ZST construction: List.drop_last(List.repeat({}, n), 1) miscompiles to [] in native fuzz builds (compiler bug, repro filed)
	List.repeat(0, node_count - 1).map_with_index(|_, i| { from: i, to: i + 1 })
	edges = chain.concat(random_edges)
	args_base = edge_base + edge_count * 2
	pin = {
		node: byte_at(bytes, args_base).to_u64() % node_count,
		x: byte_at(bytes, args_base + 1).to_f64() - 128,
		y: byte_at(bytes, args_base + 2).to_f64() - 128,
	}
	hints = List.repeat({}, node_count).map_with_index(
		|_, i| {
			x: byte_at(bytes, args_base + 3 + i * 2).to_f64(),
			y: byte_at(bytes, args_base + 4 + i * 2).to_f64(),
		},
	)
	args = { seed: byte_at(bytes, args_base + 3 + node_count * 2).to_u32(), hints }
	spec = { nodes, edges }
	base_settings = { ..StressLayout.stress_defaults, max_iterations: 24, pins: [pin] }
	exact_settings = { ..base_settings, mode: Exact }
	pivot_settings = { ..base_settings, mode: Pivots(1 + byte_at(bytes, args_base + 4 + node_count * 2).to_u64() % node_count) }
	hint_settings = { ..exact_settings, max_iterations: 0 }

	match (StressLayout.prepare_stress(spec, exact_settings), StressLayout.prepare_stress(spec, pivot_settings), StressLayout.prepare_stress(spec, hint_settings)) {
		(Ok(exact), Ok(pivot), Ok(hint_prepared)) => {
			exact_result = StressLayout.run_stress(exact, args)
			repeated = StressLayout.run_stress(exact, args)
			pivot_result = StressLayout.run_stress(pivot, args)
			hinted = StressLayout.place_stress(hint_prepared, args)
			one_call = StressLayout.layout_stress(spec, exact_settings, args)
			pinned = exact_result.layout.positions.get(pin.node) ?? { x: pin.x + 1, y: pin.y + 1 }
			hints_honored = hinted.positions.fold_with_index(
				True,
				|ok, position, i| {
					expected = if i == pin.node {
						{ x: pin.x, y: pin.y }
					} else {
						hints.get(i) ?? position
					}
					ok and position == expected
				},
			)
			aligned = exact_result.layout.positions.len() == node_count
				and exact_result.components.len() == node_count
					and exact_result.layout.routes.len() == edges.len()
						and pivot_result.layout.positions.len() == node_count
							and pivot_result.components == exact_result.components
			finite = exact_result.layout.positions.all(finite_point)
				and pivot_result.layout.positions.all(finite_point)
					and F64.is_finite(exact_result.layout.bounds.x)
						and F64.is_finite(exact_result.layout.bounds.y)
							and F64.is_finite(exact_result.layout.bounds.width)
								and F64.is_finite(exact_result.layout.bounds.height)
			if !aligned {
				crash "stress output lost source alignment or exact/pivot components differ"
			} else if !finite {
				crash "stress layout returned non-finite geometry"
			} else if pinned.x != pin.x or pinned.y != pin.y {
				crash "stress layout moved a pinned node"
			} else if !hints_honored {
				crash "zero-iteration stress placement did not honor full finite hints"
			} else if exact_result != repeated or one_call != Ok(exact_result) {
				crash "stress layout is nondeterministic or differs from prepared layout"
			} else {
				Fuzz.keep
			}
		}
		_ => crash "bounded valid stress input failed preparation"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-stress-contract",
	generator: Fuzz.list(Fuzz.u8, 96),
	test,
	show: |input| Str.inspect(input),
})
