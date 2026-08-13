app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Graph
import RadialLayout

byte_at : List(U8), U64 -> U8
byte_at = |bytes, index| bytes.get(index) ?? 0

unique_seats : List(U64) -> Bool
unique_seats = |seats|
	seats.fold_with_index(
		True,
		|ok, seat, index|
			ok and seats.fold_with_index(True, |inner, other, other_index| inner and (index == other_index or seat != other)),
	)

test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	node_count = (byte_at(bytes, 0) % 9).to_u64()
	nodes = List.repeat({}, node_count).map_with_index(
		|_, index| {
			width: (byte_at(bytes, 1 + index * 2) % 40).to_f64(),
			height: (byte_at(bytes, 2 + index * 2) % 40).to_f64(),
		},
	)
	# Alternate between a binary tree (known BFS depths) and two stars. The
	# latter checks deterministic component labels and automatic roots outside
	# the component containing the explicit root.
	disconnected = node_count > 4 and byte_at(bytes, 27) % 2 == 1
	edges = if node_count < 2 {
		[]
	} else if disconnected {
		List.repeat({}, node_count - 2).map_with_index(
			|_, index|
				if index < 3 {
					{ from: 0, to: index + 1 }
				} else {
					{ from: 4, to: index + 2 }
				},
		)
	} else {
		List.repeat({}, node_count - 1).map_with_index(|_, index| { from: index / 2, to: index + 1 })
	}
	spec = { nodes, edges }
	circular_settings = {
		..Graph.default_circular_settings,
		node_gap: (byte_at(bytes, 20) % 32).to_f64(),
		start_angle: (byte_at(bytes, 21).to_f64() - 128) / 16,
		winding: if byte_at(bytes, 22) % 2 == 0 {
			Clockwise
		} else {
			CounterClockwise
		},
	}
	radial_settings = {
		..RadialLayout.radial_defaults,
		root: if node_count == 0 {
			Auto
		} else {
			Node(0)
		},
		ring_gap: (byte_at(bytes, 23) % 48).to_f64(),
		node_gap: (byte_at(bytes, 24) % 32).to_f64(),
		start_angle: (byte_at(bytes, 25).to_f64() - 128) / 16,
		winding: if byte_at(bytes, 26) % 2 == 0 {
			Clockwise
		} else {
			CounterClockwise
		},
	}
	expected_rings = if disconnected {
		List.repeat(1, node_count).map_with_index(
			|_, index| if index == 0 or index == 4 {
				0
			} else {
				1
			},
		)
	} else {
		[0, 1, 1, 2, 2, 2, 2, 3].take_first(node_count)
	}
	expected_components = if disconnected {
		List.repeat(0, node_count).map_with_index(
			|_, index| if index < 4 {
				0
			} else {
				1
			},
		)
	} else {
		List.repeat(0, node_count)
	}

	match (Graph.prepare_circular(spec, circular_settings), RadialLayout.prepare_radial(spec, radial_settings)) {
		(Ok(circular_prepared), Ok(radial_prepared)) => {
			circular = Graph.layout_circular_prepared(circular_prepared)
			radial = RadialLayout.run_radial(radial_prepared)
			circular_ok = Graph.layout_circular(spec, circular_settings) == Ok(circular)
				and Graph.layout_circular(spec, circular_settings) == Graph.layout_circular(spec, circular_settings)
					and circular.layout.positions.len() == node_count
						and circular.layout.routes.len() == edges.len()
							and circular.order.len() == node_count
								and circular.order.all(|seat| seat < node_count)
									and unique_seats(circular.order)
			radial_ok = RadialLayout.layout_radial(spec, radial_settings) == Ok(radial)
				and RadialLayout.layout_radial(spec, radial_settings) == RadialLayout.layout_radial(spec, radial_settings)
					and radial.layout.positions.len() == node_count
						and radial.layout.routes.len() == edges.len()
							and radial.rings == expected_rings
								and radial.components == expected_components

			if circular_ok and radial_ok {
				Fuzz.keep
			} else {
				crash "circular or radial layout violated structural contract"
			}
		}
		_ => crash "bounded valid circular or radial input failed preparation"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-circular-radial-contract",
	generator: Fuzz.list(Fuzz.u8, 40),
	test,
	show: |input| Str.inspect(input),
})
