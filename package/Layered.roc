import Geom

## Layered layouts for directed graphs read as flow.
##
## TODO: Replace the temporary caller-supplied layer numbers with a shared
## graph plus sparse flow attributes. Build must validate endpoints, break
## cycles deterministically, report reversed edges, and compute ranks. The
## result must eventually include clipped routes, ranks, reversal metadata,
## label anchors, and tight bounds.
Layered :: {}.{
	## Naive `Layered.Sweep`: trust caller-supplied layers and preserve order.
	##
	## TODO: Implement the full bounded Sugiyama-style pipeline: cycle handling,
	## exact tight-tree ranking, virtual chains, alternating median sweeps,
	## adjacent-swap polishing, balanced coordinates, and shared routing. Each
	## phase should be a pure helper with direct tests and deterministic ties.
	sweep : List({ width : F64, height : F64, layer : F64 }), F64, F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	sweep = |nodes, node_gap, layer_gap| {
		placed = nodes.fold(
			{ positions: [], next_x: 0, max_right: 0, max_bottom: 0 },
			|state, node| {
				center_x = state.next_x + node.width / 2
				center_y = node.layer * layer_gap + node.height / 2
				right = center_x + node.width / 2
				bottom = center_y + node.height / 2

				{
					positions: state.positions.append(Geom.point(center_x, center_y)),
					next_x: state.next_x + node.width + node_gap,
					max_right: if right > state.max_right { right } else { state.max_right },
					max_bottom: if bottom > state.max_bottom { bottom } else { state.max_bottom },
				}
			},
		)

		{
			positions: placed.positions,
			bounds: { ..Geom.empty_bounds, width: placed.max_right, height: placed.max_bottom },
		}
	}

	## Naive `Layered.Exact` scaffold.
	##
	## TODO: Add a deliberately capped exact search over layer orders and
	## coordinate choices for small graphs. Reuse Sweep's cycle handling,
	## ranking, virtual-node representation, coordinate assignment, and routing;
	## expose the cap so exponential work is always explicit and bounded.
	exact : List({ width : F64, height : F64, layer : F64 }), F64, F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	exact = |nodes, node_gap, layer_gap| Layered.sweep(nodes, node_gap, layer_gap)
}

## Sweep baseline places nodes on their supplied layers.
expect Layered.sweep([{ width: 10, height: 6, layer: 2 }], 4, 20) == {
	positions: [{ x: 5, y: 43 }],
	bounds: { x: 0, y: 0, width: 10, height: 46 },
}
