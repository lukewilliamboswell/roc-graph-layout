app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Constrained

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

axis_value = |positions, node, axis| {
	p = positions.get(node) ?? { x: 0, y: 0 }
	match axis {
		X => p.x
		Y => p.y
	}
}

violated = |positions, constraint|
	match constraint {
		Separate(rule) => axis_value(positions, rule.second, rule.axis) - axis_value(positions, rule.first, rule.axis) < rule.gap - 1e-9
		Align(rule) => {
			values = rule.nodes.map(|node| axis_value(positions, node, rule.axis))
			first = values.get(0) ?? 0
			values.any(|value| (value - first).abs() > 1e-9)
		}
		Inside(rule) => rule.nodes.any(
			|node| {
				value = axis_value(positions, node, rule.axis)
				value < rule.low - 1e-9 or value > rule.high + 1e-9
			},
		)
	}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	count = 2 + (byte_at(bytes, 0) % 5).to_u64()
	gap = 1 + (byte_at(bytes, 1) % 30).to_f64()
	nodes = List.repeat({ width: 10, height: 10 }, count)
	edges = # non-ZST construction: List.drop_last(List.repeat({}, n), 1) miscompiles to [] in native fuzz builds (compiler bug, repro filed)
	List.repeat(0, count - 1).map_with_index(|_, i| { from: i, to: i + 1 })
	chain = # non-ZST construction: List.drop_last(List.repeat({}, n), 1) miscompiles to [] in native fuzz builds (compiler bug, repro filed)
	List.repeat(0, count - 1).map_with_index(|_, i| Separate({ axis: X, first: i, second: i + 1, gap }))
	members = List.repeat(0, count).map_with_index(|_, i| i)
	feasible = [Inside({ axis: X, nodes: [0], low: 0, high: 0 }), Align({ axis: Y, nodes: members })].concat(chain)
	infeasible = if byte_at(bytes, 2) % 2 == 0 {
		[Separate({ axis: X, first: 0, second: 1, gap }), Separate({ axis: X, first: 1, second: 0, gap })]
	} else {
		[Align({ axis: X, nodes: [0, 1] }), Separate({ axis: X, first: 0, second: 1, gap })]
	}
	settings = { ..Constrained.default_settings, max_iterations: 32 }
	args = { ..Constrained.default_run, seed: byte_at(bytes, 3).to_u32() }

	match Constrained.prepare({ graph: { nodes, edges }, constraints: infeasible }, settings) {
		Ok(_) => crash "deliberately infeasible constraints prepared successfully"
		Err(problems) if problems.is_empty() => crash "infeasible constraints returned no validation problem"
		Err(_) => {}
	}

	input = { graph: { nodes, edges }, constraints: feasible }
	match Constrained.prepare(input, settings) {
		Err(_) => crash "bounded feasible constraints failed preparation"
		Ok(prepared) => {
			result = Constrained.layout_prepared(prepared, args)
			expected = feasible.fold_with_index(
				[],
				|acc, rule, i| if violated(result.layout.positions, rule) {
					acc.append(i)
				} else {
					acc
				},
			)
			if result.unsatisfied != expected {
				crash "constrained unsatisfied indices disagree with independent rule checks"
			} else if Constrained.layout(input, settings, args) != Ok(result) {
				crash "constrained one-call layout differs from prepared layout"
			} else {
				Fuzz.keep
			}
		}
	}
}

target = Fuzz.target_with({
	name: "graph-layout-constrained-validation",
	generator: Fuzz.list(Fuzz.u8, 32),
	test,
	show: |input| Str.inspect(input),
})
