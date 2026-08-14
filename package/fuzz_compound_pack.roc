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
	base = group_spec(Compound.default_group)
	children = List.repeat(0, count).map_with_index(|_, i| Nested(Group({ ..base, padding: (byte_at(bytes, 34 + i) % 8).to_f64(), children: [Node(i)] })))
	root = Group({ ..base, children, algorithm: Rows({ gap: (byte_at(bytes, 30) % 20).to_f64() }) })
	edge_count = if count == 0 {
		0
	} else {
		(byte_at(bytes, 31) % 12).to_u64()
	}
	edges = List.repeat({ from: 0, to: 0 }, edge_count).map_with_index(|_, i| { from: byte_at(bytes, 48 + i * 2).to_u64() % count, to: byte_at(bytes, 49 + i * 2).to_u64() % count })
	input = { graph: { nodes, edges }, attachments: [], edge_labels: [], root, routing: Compound.default_routing }
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
					else if layout.layout.routes.len() != edges.len() {
						crash "compound routing lost source alignment"
					}
						else if layout.groups.is_empty() {
							crash "compound layout omitted its root"
						}
							else if !layout.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) {
								crash "compound layout returned non-finite geometry"
							}
								else if !layout.layout.routes.all(
									|route| match route {
										Line(a, b) => F64.is_finite(a.x) and F64.is_finite(a.y) and F64.is_finite(b.x) and F64.is_finite(b.y)
										Polyline(points) => points.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) and points.fold_with_index(
											True,
											|orthogonal, p, i| match points.get(i + 1) {
												Ok(next) => orthogonal and (p.x == next.x or p.y == next.y)
												Err(_) => orthogonal
											},
										)
										Curves(_) => False
									},
								) {
									crash "compound routing returned invalid geometry"
								}
									else if !layout.groups.drop_first(1).all(|child| child.x >= 0 and child.y >= 0 and child.x + child.width <= layout.layout.bounds.width and child.y + child.height <= layout.layout.bounds.height) {
										crash "compound root does not contain its children"
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
