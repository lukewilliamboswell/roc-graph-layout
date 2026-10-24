## Internal spatial indices for the router: a uniform grid of cells over the
## drawing, so that a question about one segment or one box reads only the
## cells it covers instead of every obstacle or every earlier route.
##
## `Boxes` is fixed once built and holds obstacles such as node boxes.
## `Segments` holds route segments; routes are added and removed as the
## router places and replaces them. Points outside the grid fall into its
## border cells, so every query is exact wherever the geometry lies: a box
## is registered in every cell its closed extent touches, and a query reads
## every cell its own closed extent touches. A box reached through several
## cells is reported once, from the cell holding the lower corner of its
## overlap with the query.
RouteIndex :: {}.{
	Point : { x : F64, y : F64 }
	Bounds : { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }
	Grid : { min_x : F64, min_y : F64, cell_width : F64, cell_height : F64, columns : U64, rows : U64 }

	## About `target` cells over the closed extent of `boxes`.
	grid_for : List(Bounds), U64 -> Grid
	grid_for = |boxes, target| {
		extent = boxes.fold(
			{ min_x: F64.infinity, min_y: F64.infinity, max_x: 0 - F64.infinity, max_y: 0 - F64.infinity },
			|acc, box| { min_x: acc.min_x.min(box.min_x), min_y: acc.min_y.min(box.min_y), max_x: acc.max_x.max(box.max_x), max_y: acc.max_y.max(box.max_y) },
		)
		usable = F64.is_finite(extent.min_x) and F64.is_finite(extent.min_y) and F64.is_finite(extent.max_x) and F64.is_finite(extent.max_y)
		width = if usable {
			extent.max_x - extent.min_x
		} else {
			0
		}
		height = if usable {
			extent.max_y - extent.min_y
		} else {
			0
		}
		count = target.max(1).min(1_048_576).to_f64()
		# Roughly square cells, at most `count` of them, at most 1024 per side.
		side = if width > 0 and height > 0 and F64.is_finite(width * height) {
			(width * height / count).sqrt()
		} else {
			0
		}
		columns = RouteIndex.cells_along(width, side, count)
		rows = RouteIndex.cells_along(height, side, count)
		{
			min_x: if usable {
				extent.min_x
			} else {
				0
			},
			min_y: if usable {
				extent.min_y
			} else {
				0
			},
			cell_width: if columns > 1 {
				width / columns.to_f64()
			} else {
				1
			},
			cell_height: if rows > 1 {
				height / rows.to_f64()
			} else {
				1
			},
			columns,
			rows,
		}
	}

	cells_along : F64, F64, F64 -> U64
	cells_along = |length, side, count| if !(length > 0) or !F64.is_finite(length) {
		1
	} else if side > 0 and F64.is_finite(side) {
		((length / side).floor_to_u64_try() ?? 1).max(1).min(1024)
	} else {
		(count.floor_to_u64_try() ?? 1).max(1).min(1024)
	}

	## The cell coordinate holding `value`, clamped into the grid. Monotone in
	## `value`, which is what makes clamping safe.
	cell_of : F64, F64, F64, U64 -> U64
	cell_of = |value, origin, size, count| {
		t = (value - origin) / size
		if !(t > 0) {
			0
		} else if t >= count.to_f64() {
			count - 1
		} else {
			(t.floor_to_u64_try() ?? 0).min(count - 1)
		}
	}

	column_of : Grid, F64 -> U64
	column_of = |grid, x| RouteIndex.cell_of(x, grid.min_x, grid.cell_width, grid.columns)

	row_of : Grid, F64 -> U64
	row_of = |grid, y| RouteIndex.cell_of(y, grid.min_y, grid.cell_height, grid.rows)

	overlaps : Bounds, Bounds -> Bool
	overlaps = |a, b| a.min_x <= b.max_x and b.min_x <= a.max_x and a.min_y <= b.max_y and b.min_y <= a.max_y

	## Whether `cell` is where the overlap of `query` and `box` is reported.
	reported_here : Grid, Bounds, Bounds, U64, U64 -> Bool
	reported_here = |grid, query, box, column, row| RouteIndex.column_of(grid, query.min_x.max(box.min_x)) == column and RouteIndex.row_of(grid, query.min_y.max(box.min_y)) == row

	segment_extent : Point, Point -> Bounds
	segment_extent = |a, b| { min_x: a.x.min(b.x), min_y: a.y.min(b.y), max_x: a.x.max(b.x), max_y: a.y.max(b.y) }

	## Whether segment `a`-`b` passes through the open interior of `box`. Only
	## axis-aligned segments (or single points) can.
	segment_hits : Point, Point, Bounds -> Bool
	segment_hits = |a, b, box| if a.x == b.x {
		a.x > box.min_x and a.x < box.max_x and a.y.min(b.y) < box.max_y and a.y.max(b.y) > box.min_y
	} else if a.y == b.y {
		a.y > box.min_y and a.y < box.max_y and a.x.min(b.x) < box.max_x and a.x.max(b.x) > box.min_x
	} else {
		False
	}

	# ---- Fixed boxes ----

	Boxes : { grid : Grid, offsets : List(U64), entries : List(U64), boxes : List(Bounds) }

	boxes : List(Bounds) -> Boxes
	boxes = |items| {
		grid = RouteIndex.grid_for(items, items.len())
		cells = grid.columns * grid.rows
		spans = items.map(|box| { c0: RouteIndex.column_of(grid, box.min_x), c1: RouteIndex.column_of(grid, box.max_x), r0: RouteIndex.row_of(grid, box.min_y), r1: RouteIndex.row_of(grid, box.max_y) })
		var $counts = List.repeat(0, cells)
		for span in spans {
			for row in span.r0..=span.r1 {
				for column in span.c0..=span.c1 {
					cell = row * grid.columns + column
					$counts = $counts.set(cell, ($counts.get(cell) ?? 0) + 1) ?? []
				}
			}
		}
		var $offsets = List.with_capacity(cells + 1)
		var $total = 0
		for cell in 0..<cells {
			$offsets = $offsets.append($total)
			$total = $total + ($counts.get(cell) ?? 0)
		}
		$offsets = $offsets.append($total)
		offsets = $offsets
		var $cursor = offsets
		var $entries = List.repeat(0, $total)
		for index in 0..<spans.len() {
			span = spans.get(index) ?? { c0: 0, c1: 0, r0: 0, r1: 0 }
			for row in span.r0..=span.r1 {
				for column in span.c0..=span.c1 {
					cell = row * grid.columns + column
					slot = $cursor.get(cell) ?? 0
					$entries = $entries.set(slot, index) ?? []
					$cursor = $cursor.set(cell, slot + 1) ?? []
				}
			}
		}
		{ grid, offsets, entries: $entries, boxes: items }
	}

	## Every box whose closed extent meets the closed `query`, each once, in
	## no particular order.
	boxes_meeting : Boxes, Bounds -> List(U64)
	boxes_meeting = |index, query| {
		grid = index.grid
		c0 = RouteIndex.column_of(grid, query.min_x)
		c1 = RouteIndex.column_of(grid, query.max_x)
		r0 = RouteIndex.row_of(grid, query.min_y)
		r1 = RouteIndex.row_of(grid, query.max_y)
		var $found = []
		for row in r0..=r1 {
			for column in c0..=c1 {
				cell = row * grid.columns + column
				for slot in (index.offsets.get(cell) ?? 0)..<(index.offsets.get(cell + 1) ?? 0) {
					id = index.entries.get(slot) ?? 0
					box = index.boxes.get(id) ?? query
					if RouteIndex.overlaps(query, box) and RouteIndex.reported_here(grid, query, box, column, row) {
						$found = $found.append(id)
					}
				}
			}
		}
		$found
	}

	## Whether segment `a`-`b` enters any box `skip` does not exclude.
	## Matches `boxes.any(|box| segment_hits(a, b, box))` over the kept boxes.
	segment_blocked : Boxes, Point, Point, (U64 -> Bool) -> Bool
	segment_blocked = |index, a, b, skip| {
		grid = index.grid
		query = RouteIndex.segment_extent(a, b)
		c0 = RouteIndex.column_of(grid, query.min_x)
		c1 = RouteIndex.column_of(grid, query.max_x)
		r0 = RouteIndex.row_of(grid, query.min_y)
		r1 = RouteIndex.row_of(grid, query.max_y)
		var $hit = False
		var $row = r0
		while !$hit and $row <= r1 {
			var $column = c0
			while !$hit and $column <= c1 {
				cell = $row * grid.columns + $column
				var $slot = index.offsets.get(cell) ?? 0
				end = index.offsets.get(cell + 1) ?? 0
				while !$hit and $slot < end {
					id = index.entries.get($slot) ?? 0
					if !skip(id) and RouteIndex.segment_hits(a, b, index.boxes.get(id) ?? query) {
						$hit = True
					}
					$slot = $slot + 1
				}
				$column = $column + 1
			}
			$row = $row + 1
		}
		$hit
	}

	## Whether `point` lies strictly inside any box `skip` does not exclude.
	point_blocked : Boxes, Point, (U64 -> Bool) -> Bool
	point_blocked = |index, point, skip| {
		grid = index.grid
		cell = RouteIndex.row_of(grid, point.y) * grid.columns + RouteIndex.column_of(grid, point.x)
		var $hit = False
		var $slot = index.offsets.get(cell) ?? 0
		end = index.offsets.get(cell + 1) ?? 0
		while !$hit and $slot < end {
			id = index.entries.get($slot) ?? 0
			box = index.boxes.get(id) ?? { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
			if !skip(id) and point.x > box.min_x and point.x < box.max_x and point.y > box.min_y and point.y < box.max_y {
				$hit = True
			}
			$slot = $slot + 1
		}
		$hit
	}

	# ---- Route segments ----

	## Route segments, each owned by one edge. A segment is registered by its
	## touching box: its extent grown by 0.000001 on every side, the margin
	## within which another segment counts as sharing it. Removing a route
	## marks its segments dead; they stay in the cells and are skipped.
	Segments : {
		grid : Grid,
		heads : List(U64),
		link_segment : List(U64),
		link_next : List(U64),
		touch : List(Bounds),
		starts : List(Point),
		ends : List(Point),
		owners : List(U64),
		positions : List(U64),
		alive : List(Bool),
		routes : List({ first : U64, count : U64 }),
	}

	no_link : U64
	no_link = U64.highest

	## An empty set of segments for `edges` routes over a grid of `grid`.
	segments : Grid, U64 -> Segments
	segments = |grid, edges| {
		grid,
		heads: List.repeat(RouteIndex.no_link, grid.columns * grid.rows),
		link_segment: [],
		link_next: [],
		touch: [],
		starts: [],
		ends: [],
		owners: [],
		positions: [],
		alive: [],
		routes: List.repeat({ first: 0, count: 0 }, edges),
	}

	touch_box : Point, Point -> Bounds
	touch_box = |c, d| { min_x: c.x.min(d.x) - 0.000001, min_y: c.y.min(d.y) - 0.000001, max_x: c.x.max(d.x) + 0.000001, max_y: c.y.max(d.y) + 0.000001 }

	## Add `points` as the route of `edge`, replacing any route it had.
	set_route : Segments, U64, List(Point) -> Segments
	set_route = |index, edge, points| {
		{ grid, heads, link_segment, link_next, touch, starts, ends, owners, positions, alive, routes } = index
		previous = routes.get(edge) ?? { first: 0, count: 0 }
		var $alive = alive
		for k in 0..<previous.count {
			$alive = $alive.set(previous.first + k, False) ?? []
		}
		first = starts.len()
		var $heads = heads
		var $link_segment = link_segment
		var $link_next = link_next
		var $touch = touch
		var $starts = starts
		var $ends = ends
		var $owners = owners
		var $positions = positions
		var $previous_point = Err(NoPoint)
		var $position = 0
		for d in points {
			match $previous_point {
				Ok(c) => {
					id = $starts.len()
					box = RouteIndex.touch_box(c, d)
					$touch = $touch.append(box)
					$starts = $starts.append(c)
					$ends = $ends.append(d)
					$owners = $owners.append(edge)
					$positions = $positions.append($position)
					$alive = $alive.append(True)
					$position = $position + 1
					for row in RouteIndex.row_of(grid, box.min_y)..=RouteIndex.row_of(grid, box.max_y) {
						for column in RouteIndex.column_of(grid, box.min_x)..=RouteIndex.column_of(grid, box.max_x) {
							cell = row * grid.columns + column
							link = $link_segment.len()
							$link_segment = $link_segment.append(id)
							$link_next = $link_next.append($heads.get(cell) ?? RouteIndex.no_link)
							$heads = $heads.set(cell, link) ?? []
						}
					}
				}
				Err(_) => {}
			}
			$previous_point = Ok(d)
		}
		count = $starts.len() - first
		{
			grid,
			heads: $heads,
			link_segment: $link_segment,
			link_next: $link_next,
			touch: $touch,
			starts: $starts,
			ends: $ends,
			owners: $owners,
			positions: $positions,
			alive: $alive,
			routes: routes.set(edge, { first, count }) ?? [],
		}
	}

	## The live segments, other than those of `excluded`, whose touching box
	## meets the closed `query`; each once, as segment ids.
	segments_meeting : Segments, Bounds, U64 -> List(U64)
	segments_meeting = |index, query, excluded| {
		grid = index.grid
		c0 = RouteIndex.column_of(grid, query.min_x)
		c1 = RouteIndex.column_of(grid, query.max_x)
		r0 = RouteIndex.row_of(grid, query.min_y)
		r1 = RouteIndex.row_of(grid, query.max_y)
		var $found = []
		for row in r0..=r1 {
			for column in c0..=c1 {
				var $link = index.heads.get(row * grid.columns + column) ?? RouteIndex.no_link
				while $link != RouteIndex.no_link {
					id = index.link_segment.get($link) ?? 0
					if (index.alive.get(id) ?? False) and (index.owners.get(id) ?? excluded) != excluded {
						box = index.touch.get(id) ?? query
						if RouteIndex.overlaps(query, box) and RouteIndex.reported_here(grid, query, box, column, row) {
							$found = $found.append(id)
						}
					}
					$link = index.link_next.get($link) ?? RouteIndex.no_link
				}
			}
		}
		$found
	}

	## How many live segments of routes other than `excluded` segment `a`-`b`
	## touches. Matches counting `segment_hits(a, b, touch_box(c, d))` over every
	## segment `c`-`d` of every such route.
	touching : Segments, Point, Point, U64 -> U64
	touching = |index, a, b, excluded| {
		if a.x != b.x and a.y != b.y {
			0
		} else {
			RouteIndex.segments_meeting(index, RouteIndex.segment_extent(a, b), excluded).fold(
				0,
				|count, id| if RouteIndex.segment_hits(a, b, index.touch.get(id) ?? RouteIndex.segment_extent(a, b)) {
					count + 1
				} else {
					count
				},
			)
		}
	}

	## The touching box of every live segment of routes other than `excluded`.
	touch_boxes : Segments, U64 -> List(Bounds)
	touch_boxes = |index, excluded| {
		var $boxes = []
		for id in 0..<index.touch.len() {
			if (index.alive.get(id) ?? False) and (index.owners.get(id) ?? excluded) != excluded {
				$boxes = $boxes.append(index.touch.get(id) ?? { min_x: 0, min_y: 0, max_x: 0, max_y: 0 })
			}
		}
		$boxes
	}
}
