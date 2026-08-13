import Geom

## General-graph layouts for data whose meaning comes from connectivity.
##
## TODO: This family currently exposes only a deterministic row placement as
## the executable baseline for `Force`. Replace it with the multilevel,
## Barnes-Hut force simulation described in `design.md`: validate sizes and
## pins during build, coarsen, seed an initial placement, iteratively apply
## attraction and repulsion, remove residual overlaps, route edges, and report
## convergence. Preserve this baseline as a small-graph oracle and fixture.
Graph :: {}.{
	## Naive `Graph.Force` baseline: place nodes left-to-right with a fixed gap.
	##
	## TODO: Introduce the uniform build/run contract and a `Force` witness.
	## The production implementation needs seeded starts, position hints, pins,
	## an iteration cap, a tolerance, Barnes-Hut repulsion, component packing,
	## and deterministic tie-breaking. Until then this pure O(n) placement gives
	## every valid node one finite, non-overlapping position.
	force : List({ width : F64, height : F64 }), F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	force = |nodes, node_gap| {
		placed = nodes.fold(
			{ positions: [], next_x: 0, max_height: 0 },
			|state, node| {
				center_x = state.next_x + node.width / 2
				max_height = if node.height > state.max_height { node.height } else { state.max_height }

				{
					positions: state.positions.append(Geom.point(center_x, node.height / 2)),
					next_x: state.next_x + node.width + node_gap,
					max_height,
				}
			},
		)

		width = if nodes.is_empty() { 0 } else { placed.next_x - node_gap }

		{
			positions: placed.positions,
			bounds: { ..Geom.empty_bounds, width, height: placed.max_height },
		}
	}

	## Naive `Graph.Stress` scaffold.
	##
	## TODO: Replace delegation to row placement with graph-distance stress
	## majorization. Build should compute exact distances for small graphs or a
	## deterministic pivot approximation for large ones; run should descend
	## until relative stress change reaches tolerance or the iteration cap.
	stress : List({ width : F64, height : F64 }), F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	stress = |nodes, node_gap| Graph.force(nodes, node_gap)

	## Naive `Graph.Circular` scaffold.
	##
	## TODO: Replace delegation with deterministic adjacency-affinity ordering,
	## adjacent-swap crossing reduction, circumference spacing derived from node
	## extents, and projection onto a ring with configured angle and winding.
	circular : List({ width : F64, height : F64 }), F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	circular = |nodes, node_gap| Graph.force(nodes, node_gap)

	## Naive `Graph.Radial` scaffold.
	##
	## TODO: Replace delegation with root validation or deterministic automatic
	## root selection, breadth-first ring assignment, median ordering between
	## adjacent rings, extent-aware radii, and deterministic angular placement.
	radial : List({ width : F64, height : F64 }), F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	radial = |nodes, node_gap| Graph.force(nodes, node_gap)
}

## Force baseline places heterogeneous nodes without overlap.
expect {
	result = Graph.force(
		[
			{ width: 20, height: 10 },
			{ width: 10, height: 30 },
		],
		5,
	)

	result == {
		positions: [{ x: 10, y: 5 }, { x: 30, y: 15 }],
		bounds: { x: 0, y: 0, width: 35, height: 30 },
	}
}

## Force baseline defines the empty graph.
expect Graph.force([], 10) == { positions: [], bounds: Geom.empty_bounds }

## General-graph scaffolds currently share the deterministic baseline.
expect Graph.stress([{ width: 4, height: 2 }], 1) == Graph.circular([{ width: 4, height: 2 }], 1)
