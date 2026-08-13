app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Constrained

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = 2 + (byte_at(bytes, 0) % 6).to_u64()
	gap = 1 + (byte_at(bytes, 1) % 40).to_f64()
	nodes = List.repeat({}, node_count).map_with_index(
		|_, index| {
			width: (1 + byte_at(bytes, 2 + index * 2) % 40).to_f64(),
			height: (1 + byte_at(bytes, 3 + index * 2) % 40).to_f64(),
		},
	)
	edges = # non-ZST construction: List.drop_last(List.repeat({}, n), 1) miscompiles to [] in native fuzz builds (compiler bug, repro filed)
	List.repeat(0, node_count - 1).map_with_index(|_, i| { from: i, to: i + 1 })
	members = List.repeat(0, node_count).map_with_index(|_, i| i)
	constraints = [
		Inside({ axis: X, nodes: [0], low: 0, high: 0 }),
		Align({ axis: Y, nodes: members }),
	].concat(
		# non-ZST construction: List.drop_last(List.repeat({}, n), 1) miscompiles to [] in native fuzz builds (compiler bug, repro filed)
	List.repeat(0, node_count - 1).map_with_index(
			|_, i| Separate({ axis: X, first: i, second: i + 1, gap }),
		),
	)
	input = { graph: { nodes, edges }, constraints }
	settings = { ..Constrained.default_settings, max_iterations: 40 }
	args = { ..Constrained.default_run, seed: byte_at(bytes, 2 + node_count * 2).to_u32() }

	match Constrained.layout(input, settings, args) {
		Err(_) => crash "bounded feasible constraints failed preparation"
		Ok(result) => {
			first = result.layout.positions.get(0) ?? { x: 1, y: 1 }
			finite = result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
			aligned = result.layout.positions.all(|p| (p.y - first.y).abs() <= 1e-7)
			separated = result.layout.positions.fold_with_index(
				True,
				|ok, p, i|
					if i == 0 {
						ok
					} else {
						previous = result.layout.positions.get(i - 1) ?? p
						ok and p.x - previous.x >= gap - 1e-7
					},
			)
			if !finite {
				crash "constrained layout returned non-finite geometry"
			} else if first.x.abs() > 1e-7 {
				crash "constrained layout moved a node outside its generated band"
			} else if !aligned {
				crash "constrained layout violated a generated alignment"
			} else if !separated {
				crash "constrained layout violated a generated separation"
			} else if !result.unsatisfied.is_empty() {
				crash "constrained layout reported a satisfied generated rule as unsatisfied"
			} else {
				Fuzz.keep
			}
		}
	}
}

target = Fuzz.target_with({
	name: "graph-layout-constrained-rules",
	generator: Fuzz.list(Fuzz.u8, 64),
	test,
	show: |input| Str.inspect(input),
})
