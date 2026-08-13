import Geom

## Placement-independent packing for disconnected components and forests.
Pack :: {}.{

	## Space between packed boxes and the width-to-height shape the packed
	## drawing aims for (1.0 targets a square).
	Settings : { gap : F64, target_aspect : F64 }

	default_settings : Settings
	default_settings = { gap: 24, target_aspect: 1.0 }

	## Arrange component boxes into shelves so the whole drawing approaches
	## `target_aspect` with `gap` empty space between neighbors. Returns each
	## box's center position, index-aligned to the input, plus tight bounds
	## anchored at the origin.
	##
	## Deterministic shelf packing: boxes are sorted by descending larger
	## extent (the larger of width and height), ties broken by ascending
	## input index, then placed left-to-right into shelves; a new shelf
	## opens below the current one when the row's width would exceed the
	## target width, derived from the total box area and `target_aspect`
	## but never narrower than the widest single box. A shelf always
	## accepts at least one box, so zero-size boxes and an empty input are
	## legal and give defined results.
	##
	## This pass is placement-independent and has no build step, so it is
	## total instead of validating: a `gap` below zero behaves as `0`, and
	## a `target_aspect` that is not finite or not above zero behaves as
	## `1`.
	pack : List({ width : F64, height : F64 }),
	Settings -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	pack = |boxes, settings| {
		if boxes.is_empty() {
			{ positions: [], bounds: Geom.empty_bounds }
		} else {
			gap = if F64.is_finite(settings.gap) and settings.gap > 0 {
				settings.gap
			} else {
				0
			}
			aspect = if F64.is_finite(settings.target_aspect) and settings.target_aspect > 0 {
				settings.target_aspect
			} else {
				1
			}

			total_area = boxes.fold(0, |sum, box| sum + box.width * box.height)
			widest = boxes.fold(0, |acc, box| acc.max(box.width))
			target_width = (total_area * aspect).sqrt().max(widest)

			sorted = boxes
				.map_with_index(|box, index| { width: box.width, height: box.height, index })
				.sort_with(
					|a, b| {
						extent_a = a.width.max(a.height)
						extent_b = b.width.max(b.height)
						if extent_a > extent_b {
							LT
						} else if extent_a < extent_b {
							GT
						} else if a.index < b.index {
							LT
						} else {
							GT
						}
					},
				)

			placed = sorted.fold(
				{ placements: [], cursor_x: 0, shelf_y: 0, shelf_height: 0, shelf_count: 0 },
				|state, box| {
					opens_shelf = state.shelf_count > 0 and state.cursor_x + box.width > target_width
					if opens_shelf {
						# shelf arithmetic saturates so extreme-but-finite box
						# sizes keep every placement finite
						shelf_y = Geom.saturate(state.shelf_y + state.shelf_height + gap)

						{
							placements: state.placements.append({ index: box.index, x: 0, y: shelf_y, width: box.width, height: box.height }),
							cursor_x: Geom.saturate(box.width + gap),
							shelf_y,
							shelf_height: box.height,
							shelf_count: 1,
						}
					} else {
						{
							placements: state.placements.append({ index: box.index, x: state.cursor_x, y: state.shelf_y, width: box.width, height: box.height }),
							cursor_x: Geom.saturate(state.cursor_x + box.width + gap),
							shelf_y: state.shelf_y,
							shelf_height: state.shelf_height.max(box.height),
							shelf_count: state.shelf_count + 1,
						}
					}
				},
			)

			first = placed.placements.get(0) ?? { index: 0, x: 0, y: 0, width: 0, height: 0 }
			tight = placed.placements.fold(
				{
					min_x: first.x,
					min_y: first.y,
					max_x: first.x + first.width,
					max_y: first.y + first.height,
				},
				|acc, p| {
					{
						min_x: acc.min_x.min(p.x),
						min_y: acc.min_y.min(p.y),
						max_x: acc.max_x.max(Geom.saturate(p.x + p.width)),
						max_y: acc.max_y.max(Geom.saturate(p.y + p.height)),
					}
				},
			)

			positions = placed.placements.fold(
				List.repeat(Geom.point(0, 0), boxes.len()),
				|acc, p| {
					center = Geom.point(
						Geom.saturate(p.x + p.width / 2 - tight.min_x),
						Geom.saturate(p.y + p.height / 2 - tight.min_y),
					)
					acc.set(p.index, center) ?? acc
				},
			)

			{
				positions,
				bounds: {
					..Geom.empty_bounds,
					width: Geom.saturate(tight.max_x - tight.min_x),
					height: Geom.saturate(tight.max_y - tight.min_y),
				},
			}
		}
	}

	## Naive shelf packer: place component boxes in one left-to-right row.
	row : List({ width : F64, height : F64 }),
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	row = |boxes, gap| {
		packed = boxes.fold(
			{ positions: [], next_x: 0, max_height: 0 },
			|state, box| {
				max_height = if box.height > state.max_height {
					box.height
				} else {
					state.max_height
				}

				{
					positions: state.positions.append(Geom.point(state.next_x, 0)),
					next_x: state.next_x + box.width + gap,
					max_height,
				}
			},
		)
		width = if boxes.is_empty() {
			0
		} else {
			packed.next_x - gap
		}

		{
			positions: packed.positions,
			bounds: { ..Geom.empty_bounds, width, height: packed.max_height },
		}
	}
}

## Four equal squares with a square target pack into two shelves of two,
## with centers index-aligned to the input and square bounds.
expect Pack.pack(
	[{ width: 10, height: 10 }, { width: 10, height: 10 }, { width: 10, height: 10 }, { width: 10, height: 10 }],
	{ gap: 0, target_aspect: 1.0 },
) == {
	positions: [{ x: 5, y: 5 }, { x: 15, y: 5 }, { x: 5, y: 15 }, { x: 15, y: 15 }],
	bounds: { x: 0, y: 0, width: 20, height: 20 },
}

## The tallest box is placed first even when it is not first in the input,
## and the output stays index-aligned: each input box finds its own center
## at its own index.
expect Pack.pack(
	[{ width: 2, height: 2 }, { width: 3, height: 12 }, { width: 2, height: 2 }],
	{ gap: 0, target_aspect: 1.0 },
) == {
	positions: [{ x: 4, y: 1 }, { x: 1.5, y: 6 }, { x: 1, y: 13 }],
	bounds: { x: 0, y: 0, width: 5, height: 14 },
}

## No two packed boxes strictly overlap; touching is allowed.
expect {
	boxes = [
		{ width: 30, height: 10 },
		{ width: 8, height: 22 },
		{ width: 14, height: 14 },
		{ width: 5, height: 5 },
		{ width: 18, height: 4 },
		{ width: 9, height: 9 },
	]
	result = Pack.pack(boxes, { gap: 6, target_aspect: 1.0 })
	result.positions.fold_with_index(
		True,
		|all_ok, a, i| {
			box_a = boxes.get(i) ?? { width: 0, height: 0 }

			all_ok
				and result.positions.fold_with_index(
					True,
					|pair_ok, b, j| {
						box_b = boxes.get(j) ?? { width: 0, height: 0 }
						separated =
							i == j
								or (a.x - b.x).abs() * 2 >= box_a.width + box_b.width
									or (a.y - b.y).abs() * 2 >= box_a.height + box_b.height

						pair_ok and separated
					},
				)
		},
	)
}

## A wide target aspect gives wider-than-tall bounds; a narrow one gives
## taller-than-wide bounds.
expect {
	boxes = List.repeat({ width: 10, height: 10 }, 6)
	wide = Pack.pack(boxes, { gap: 0, target_aspect: 4.0 })
	tall = Pack.pack(boxes, { gap: 0, target_aspect: 0.25 })

	wide.bounds.width > wide.bounds.height and tall.bounds.height > tall.bounds.width
}

## A single box centers at half its size and the bounds equal its size.
expect Pack.pack([{ width: 8, height: 6 }], Pack.default_settings) == {
	positions: [{ x: 4, y: 3 }],
	bounds: { x: 0, y: 0, width: 8, height: 6 },
}

## Empty input packs to no positions and empty bounds.
expect Pack.pack([], Pack.default_settings) == {
	positions: [],
	bounds: { x: 0, y: 0, width: 0, height: 0 },
}

## Zero-size boxes get defined positions and leave the bounds of the real
## boxes undisturbed.
expect Pack.pack(
	[{ width: 0, height: 0 }, { width: 10, height: 10 }, { width: 0, height: 0 }],
	{ gap: 0, target_aspect: 1.0 },
) == {
	positions: [{ x: 10, y: 0 }, { x: 5, y: 5 }, { x: 10, y: 0 }],
	bounds: { x: 0, y: 0, width: 10, height: 10 },
}

## Packing the same input twice gives identical output.
expect {
	boxes = [{ width: 7, height: 3 }, { width: 3, height: 7 }, { width: 5, height: 5 }]

	Pack.pack(boxes, Pack.default_settings) == Pack.pack(boxes, Pack.default_settings)
}

## Defensive settings: a negative gap behaves as zero, and a non-finite
## target aspect behaves as one.
expect {
	boxes = [{ width: 6, height: 4 }, { width: 4, height: 6 }]
	negative_gap = Pack.pack(boxes, { gap: 0 - 5, target_aspect: 1.0 }) == Pack.pack(boxes, { gap: 0, target_aspect: 1.0 })
	infinite_aspect = Pack.pack(boxes, { gap: 2, target_aspect: F64.infinity }) == Pack.pack(boxes, { gap: 2, target_aspect: 1.0 })

	negative_gap and infinite_aspect
}

## Row packing is deterministic and excludes a trailing gap from its bounds.
expect Pack.row([{ width: 4, height: 2 }, { width: 3, height: 5 }], 1) == {
	positions: [{ x: 0, y: 0 }, { x: 5, y: 0 }],
	bounds: { x: 0, y: 0, width: 8, height: 5 },
}
