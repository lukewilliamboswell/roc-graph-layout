app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Graph
import RadialLayout

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

finite_layout = |layout| {
	b = layout.bounds
	layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
		and F64.is_finite(b.x)
			and F64.is_finite(b.y)
				and F64.is_finite(b.width)
					and F64.is_finite(b.height)
}

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	n = (byte_at(bytes, 0) % 9).to_u64()
	m = (byte_at(bytes, 1) % 17).to_u64()
	nodes = List.repeat({}, n).map_with_index(
		|_, i| {
			width: (byte_at(bytes, 2 + i * 2) % 65).to_f64(),
			height: (byte_at(bytes, 3 + i * 2) % 65).to_f64(),
		},
	)
	denom = n.max(1)
	edge_start = 2 + n * 2
	edges0 = List.repeat({}, m).map_with_index(
		|_, i| {
			from: byte_at(bytes, edge_start + i * 2).to_u64() % denom,
			to: byte_at(bytes, edge_start + i * 2 + 1).to_u64() % denom,
		},
	)
	edges = if n == 0 {
		[]
	} else {
		edges0
	}
	spec = { nodes, edges }
	seed = byte_at(bytes, edge_start + m * 2).to_u32()

	force = Graph.layout_force(spec, { ..Graph.default_force_settings, max_iterations: 24 }, { ..Graph.default_force_run, seed })
	stress = Graph.layout_stress(spec, { ..Graph.default_stress_settings, max_iterations: 24 }, { ..Graph.default_stress_run, seed })
	circular = Graph.layout_circular(spec, Graph.default_circular_settings)
	radial = RadialLayout.layout_radial(spec, RadialLayout.radial_defaults)

	force_ok = match force {
		Err(_) => False
		Ok(result) =>
			finite_layout(result.layout)
				and result.layout.positions.len() == n
					and result.layout.routes.len() == edges.len()
						and result.components.len() == n
		}
	stress_ok = match stress {
		Err(_) => False
		Ok(result) =>
			finite_layout(result.layout)
				and result.layout.positions.len() == n
					and result.layout.routes.len() == edges.len()
						and result.components.len() == n
		}
	circular_ok = match circular {
		Err(_) => False
		Ok(result) =>
			finite_layout(result.layout)
				and result.layout.positions.len() == n
					and result.layout.routes.len() == edges.len()
		}
	radial_ok = match radial {
		Err(_) => False
		Ok(result) =>
			finite_layout(result.layout)
				and result.layout.positions.len() == n
					and result.layout.routes.len() == edges.len()
						and result.rings.len() == n
							and result.components.len() == n
		}
	deterministic = force == Graph.layout_force(spec, { ..Graph.default_force_settings, max_iterations: 24 }, { ..Graph.default_force_run, seed })
		and stress == Graph.layout_stress(spec, { ..Graph.default_stress_settings, max_iterations: 24 }, { ..Graph.default_stress_run, seed })
			and circular == Graph.layout_circular(spec, Graph.default_circular_settings)
				and radial == RadialLayout.layout_radial(spec, RadialLayout.radial_defaults)

	if force_ok and stress_ok and circular_ok and radial_ok and deterministic {
		Fuzz.keep
	} else {
		crash "a general-graph layout violated the shared finite/aligned/deterministic contract"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-cross-family-contract",
	generator: Fuzz.list(Fuzz.u8, 96),
	test,
	show: |input| Str.inspect(input),
})
