app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Graph
import Geom

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

finite_route : Geom.Route -> Bool
finite_route = |route|
	match route {
		Line(from, to) =>
			F64.is_finite(from.x) and F64.is_finite(from.y) and F64.is_finite(to.x) and F64.is_finite(to.y)
		Polyline(points) => points.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
		Curves(segments) =>
			segments.all(
				|s|
					F64.is_finite(s.from.x)
						and F64.is_finite(s.from.y)
							and F64.is_finite(s.ctl_a.x)
								and F64.is_finite(s.ctl_a.y)
									and F64.is_finite(s.ctl_b.x)
										and F64.is_finite(s.ctl_b.y)
											and F64.is_finite(s.to.x)
												and F64.is_finite(s.to.y),
			)
		}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = (byte_at(bytes, 0) % 9).to_u64()
	edge_count = (byte_at(bytes, 1) % 17).to_u64()

	nodes = List.repeat({}, node_count).map_with_index(
		|_, index| {
			raw_width = (byte_at(bytes, 2 + index * 2) % 80).to_f64()
			raw_height = (byte_at(bytes, 3 + index * 2) % 80).to_f64()
			{
				width: if byte_at(bytes, 2 + index * 2) % 17 == 0 {
					0 - raw_width
				} else {
					raw_width
				},
				height: if byte_at(bytes, 3 + index * 2) % 19 == 0 {
					0 - raw_height
				} else {
					raw_height
				},
			}
		},
	)
	edge_base = 2 + node_count * 2
	edges = List.repeat({}, edge_count).map_with_index(
		|_, index| {
			from: (byte_at(bytes, edge_base + index * 2) % 12).to_u64(),
			to: (byte_at(bytes, edge_base + index * 2 + 1) % 12).to_u64(),
		},
	)

	settings = {
		..Graph.default_force_settings,
		node_gap: (byte_at(bytes, edge_base + edge_count * 2) % 48).to_f64(),
		max_iterations: (byte_at(bytes, edge_base + edge_count * 2 + 1) % 40).to_u64(),
	}

	match Graph.layout_force({ nodes, edges }, settings, Graph.default_force_run) {
		Err(_) => Fuzz.keep
		Ok(result) => {
			b = result.layout.bounds
			finite = result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
				and result.layout.routes.all(finite_route)
					and F64.is_finite(b.x)
						and F64.is_finite(b.y)
							and F64.is_finite(b.width)
								and F64.is_finite(b.height)
			aligned = result.layout.positions.len() == nodes.len()
				and result.layout.routes.len() == edges.len()
					and result.components.len() == nodes.len()
			if finite and aligned {
				Fuzz.keep
			} else {
				crash "force layout violated totality or index alignment"
			}
		}
	}
}

target = Fuzz.target_with({
	name: "graph-layout-validation-totality",
	generator: Fuzz.list(Fuzz.u8, 96),
	test,
	show: |input| Str.inspect(input),
})
