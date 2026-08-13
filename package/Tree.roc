import Geom

## Tree layouts for input already known to be a hierarchy.
##
## TODO: Replace the temporary flat `{ depth, width, height }` input with a
## recursive `{ width, height, children }` tree spec. Build should validate
## finite, non-negative sizes once and number nodes in depth-first order. Both
## algorithms should return routes, depths, tight bounds, and the common layout
## record through the same build/run contract as every other family.
Tree :: {}.{

	## Naive `Tree.Tidy`: preserve input order and put each depth on a level.
	##
	## TODO: Implement linear-time tidy placement for arbitrary arity and
	## heterogeneous sizes. Combine child subtrees bottom-up using contours,
	## defer subtree shifts, center parents, honor sibling/subtree/level gaps,
	## support all four directions, and prove non-overlap with focused expects.
	tidy : List({ width : F64, height : F64, depth : F64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	tidy = |nodes, sibling_gap, level_gap| {
		placed = nodes.fold(
			{ positions: [], next_x: 0, max_right: 0, max_bottom: 0 },
			|state, node| {
				center_x = state.next_x + node.width / 2
				center_y = node.depth * level_gap + node.height / 2
				right = center_x + node.width / 2
				bottom = center_y + node.height / 2

				{
					positions: state.positions.append(Geom.point(center_x, center_y)),
					next_x: state.next_x + node.width + sibling_gap,
					max_right: if right > state.max_right {
						right
					} else {
						state.max_right
					},
					max_bottom: if bottom > state.max_bottom {
						bottom
					} else {
						state.max_bottom
					},
				}
			},
		)

		{
			positions: placed.positions,
			bounds: { ..Geom.empty_bounds, width: placed.max_right, height: placed.max_bottom },
		}
	}

	## Naive `Tree.Radial` scaffold.
	##
	## TODO: Reuse the finished tidy engine, map depth to extent-aware ring
	## radius and horizontal subtree extent to angular extent, then honor start
	## angle and winding while preserving wedges and sibling order.
	radial : List({ width : F64, height : F64, depth : F64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	radial = |nodes, sibling_gap, level_gap| Tree.tidy(nodes, sibling_gap, level_gap)
}

## Tidy baseline assigns depth to vertical levels and input order horizontally.
expect {
	result = Tree.tidy(
		[
			{ width: 10, height: 10, depth: 0 },
			{ width: 6, height: 4, depth: 1 },
		],
		2,
		20,
	)

	result == {
		positions: [{ x: 5, y: 5 }, { x: 15, y: 22 }],
		bounds: { x: 0, y: 0, width: 18, height: 24 },
	}
}
