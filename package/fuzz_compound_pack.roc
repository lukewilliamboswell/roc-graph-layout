app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Compound

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

group_spec = |Group(spec)| spec

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	count = (byte_at(bytes, 0) % 12).to_u64()
	nodes = List.repeat({ width: 0, height: 0 }, count).map_with_index(
		|_, i| {
			width: (byte_at(bytes, i * 2 + 1) % 50).to_f64(),
			height: (byte_at(bytes, i * 2 + 2) % 50).to_f64(),
		},
	)
	children = List.repeat(0, count).map_with_index(|_, i| Node(i))
	base = group_spec(Compound.default_group)
	root = Group({ ..base, children, gap: (byte_at(bytes, 30) % 20).to_f64() })
	input = { graph: { nodes, edges: [] }, ports: [], port_bindings: [], edge_labels: [], root }
	result = Compound.layout(input, Compound.default_run)
	repeated = Compound.layout(input, Compound.default_run)
	match result {
		Err(_) => crash "valid compound input was rejected"
		Ok(layout) =>
			if result != repeated {
				crash "compound layout is nondeterministic"
			}
				else if layout.layout.positions.len() != count {
					crash "compound layout lost source alignment"
				}
					else if layout.groups.is_empty() {
						crash "compound layout omitted its root"
					}
						else if !layout.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) {
							crash "compound layout returned non-finite geometry"
						}
							else {
								Fuzz.keep
							}
		}
}

target = Fuzz.target_with({
	name: "graph-layout-compound",
	generator: Fuzz.list(Fuzz.u8, 32),
	test,
	show: |input| Str.inspect(input),
})
