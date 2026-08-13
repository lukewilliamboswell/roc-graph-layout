import Geom

## Placement-independent packing for disconnected components and forests.
Pack :: {}.{
	## Naive shelf packer: place component boxes in one left-to-right row.
	##
	## TODO: Sort components deterministically by descending extent then source
	## index, fill shelves toward a configured target aspect ratio, translate
	## each component's complete geometry (nodes, routes, and label anchors), and
	## return component ids plus tight normalized bounds. Add adversarial tests
	## for empty components, equal-size ties, and highly skewed rectangles.
	row : List({ width : F64, height : F64 }), F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	row = |boxes, gap| {
		packed = boxes.fold(
			{ positions: [], next_x: 0, max_height: 0 },
			|state, box| {
				max_height = if box.height > state.max_height { box.height } else { state.max_height }

				{
					positions: state.positions.append(Geom.point(state.next_x, 0)),
					next_x: state.next_x + box.width + gap,
					max_height,
				}
			},
		)
		width = if boxes.is_empty() { 0 } else { packed.next_x - gap }

		{
			positions: packed.positions,
			bounds: { ..Geom.empty_bounds, width, height: packed.max_height },
		}
	}
}

## Row packing is deterministic and excludes a trailing gap from its bounds.
expect Pack.row([{ width: 4, height: 2 }, { width: 3, height: 5 }], 1) == {
	positions: [{ x: 0, y: 0 }, { x: 5, y: 0 }],
	bounds: { x: 0, y: 0, width: 8, height: 5 },
}
