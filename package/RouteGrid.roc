import RouteSort

## Internal orthogonal path search for the router: the cheapest route between
## two points over the grid formed by every obstacle edge line, where a move
## runs along one grid line to any point it can see, costs its length, a
## bend penalty when it turns, and a penalty for every earlier route segment
## it touches.
##
## The grid is never materialized. Grid lines are kept in their order of
## first appearance, which fixes each point's place in the deterministic
## tie-break; their sorted order drives the walks along a line. Each line
## carries the obstacles and earlier segments that cut across it, so one
## expanded point costs the obstacles and segments on its own two lines
## plus the points it can see, and a priority queue picks the next point.
RouteGrid :: {}.{
	Point : { x : F64, y : F64 }
	Bounds : { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }

	## The positions `0..<n`.
	indices : U64 -> List(U64)
	indices = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## The distinct values in order of first appearance, comparing with `==`.
	unique_values : List(F64) -> List(F64)
	unique_values = |values| {
		order = RouteSort.by_value(values)
		var $keep = List.repeat(False, values.len())
		var $previous = 0.0
		var $first = True
		for index in order {
			value = values.get(index) ?? 0
			if $first or value != $previous {
				# Equal keys keep input order, so this is the first appearance.
				$keep = $keep.set(index, True) ?? []
			}
			$previous = value
			$first = False
		}
		keep = $keep
		values.fold_with_index(
			[],
			|acc, value, i| if keep.get(i) ?? False {
				acc.append(value)
			} else {
				acc
			},
		)
	}

	## The first position whose value is greater than `value`.
	first_above : List(F64), F64 -> U64
	first_above = |sorted, value| {
		var $lo = 0
		var $hi = sorted.len()
		while $lo < $hi {
			mid = ($lo + $hi) // 2
			if (sorted.get(mid) ?? 0) > value {
				$hi = mid
			} else {
				$lo = mid + 1
			}
		}
		$lo
	}

	## The first position whose value is at least `value`.
	first_at_least : List(F64), F64 -> U64
	first_at_least = |sorted, value| {
		var $lo = 0
		var $hi = sorted.len()
		while $lo < $hi {
			mid = ($lo + $hi) // 2
			if (sorted.get(mid) ?? 0) >= value {
				$hi = mid
			} else {
				$lo = mid + 1
			}
		}
		$lo
	}

	## For every grid line (a sorted coordinate), the intervals that strictly
	## contain it, listed in `order`. `offsets` has one more entry than there
	## are lines; line `k`'s interval indices are `entries[offsets[k]..offsets[k + 1]]`.
	crossing_lines : List(F64), List({ lo : F64, hi : F64 }), List(U64) -> { offsets : List(U64), entries : List(U64) }
	crossing_lines = |sorted, intervals, order| {
		lines = sorted.len()
		ranges = intervals.map(|interval| { from: RouteGrid.first_above(sorted, interval.lo), to: RouteGrid.first_at_least(sorted, interval.hi) })
		var $counts = List.repeat(0, lines + 1)
		for range in ranges {
			if range.from < range.to {
				for line in range.from..<range.to {
					$counts = $counts.set(line, ($counts.get(line) ?? 0) + 1) ?? []
				}
			}
		}
		var $offsets = List.with_capacity(lines + 1)
		var $total = 0
		for line in 0..<(lines + 1) {
			$offsets = $offsets.append($total)
			$total = $total + ($counts.get(line) ?? 0)
		}
		offsets = $offsets
		var $cursor = offsets
		var $entries = List.repeat(0, $total)
		for index in order {
			range = ranges.get(index) ?? { from: 0, to: 0 }
			if range.from < range.to {
				for line in range.from..<range.to {
					slot = $cursor.get(line) ?? 0
					$entries = $entries.set(slot, index) ?? []
					$cursor = $cursor.set(line, slot + 1) ?? []
				}
			}
		}
		{ offsets, entries: $entries }
	}

	point_blocked : Point, List(Bounds) -> Bool
	point_blocked = |point, boxes| boxes.any(|box| point.x > box.min_x and point.x < box.max_x and point.y > box.min_y and point.y < box.max_y)

	segment_hits : Point, Point, Bounds -> Bool
	segment_hits = |a, b, box| if a.x == b.x {
		a.x > box.min_x and a.x < box.max_x and a.y.min(b.y) < box.max_y and a.y.max(b.y) > box.min_y
	} else if a.y == b.y {
		a.y > box.min_y and a.y < box.max_y and a.x.min(b.x) < box.max_x and a.x.max(b.x) > box.min_x
	} else {
		False
	}

	path_visible : List(Point), List(Bounds) -> Bool
	path_visible = |points, boxes| points.fold_with_index(
		True,
		|clear, a, i| match points.get(i + 1) {
			Ok(b) => clear and (a.x == b.x or a.y == b.y) and boxes.all(|box| RouteGrid.segment_hits(a, b, box) == False)
			Err(_) => clear
		},
	)

	## The thin box around every segment of every earlier route; touching it
	## counts as sharing that segment.
	segment_boxes : List(List(Point)) -> List(Bounds)
	segment_boxes = |routes| {
		var $boxes = []
		for points in routes {
			var $previous = Err(NoPoint)
			for d in points {
				match $previous {
					Ok(c) => {
						$boxes = $boxes.append({ min_x: c.x.min(d.x) - 0.000001, min_y: c.y.min(d.y) - 0.000001, max_x: c.x.max(d.x) + 0.000001, max_y: c.y.max(d.y) + 0.000001 })
					}
					Err(_) => {}
				}
				$previous = Ok(d)
			}
		}
		$boxes
	}

	## Binary-heap entry order: lower cost first, then lower state.
	heap_less : List(F64), List(U64), U64, U64 -> Bool
	heap_less = |costs, states, a, b| {
		ca = costs.get(a) ?? 0
		cb = costs.get(b) ?? 0
		ca < cb or (ca == cb and (states.get(a) ?? 0) < (states.get(b) ?? 0))
	}

	## The cheapest path from `start` to `finish`, or an empty list when the
	## finish cannot be reached. A path starts at `start`; its later points are
	## grid points, and it ends on `finish` when that point is clear.
	shortest : Point, Point, List(Bounds), F64, F64, List(List(Point)) -> List(Point)
	shortest = |start, finish, boxes, bend_penalty, shared_penalty, prior| RouteGrid.shortest_touching(start, finish, boxes, bend_penalty, shared_penalty, RouteGrid.segment_boxes(prior))

	## `shortest`, given the touching box of every earlier segment directly
	## (in any order) instead of the earlier routes.
	shortest_touching : Point, Point, List(Bounds), F64, F64, List(Bounds) -> List(Point)
	shortest_touching = |start, finish, boxes, bend_penalty, shared_penalty, shared| {
		xs = RouteGrid.unique_values(boxes.fold([start.x, finish.x], |acc, box| acc.append(box.min_x).append(box.max_x)))
		ys = RouteGrid.unique_values(boxes.fold([start.y, finish.y], |acc, box| acc.append(box.min_y).append(box.max_y)))
		nx = xs.len()
		ny = ys.len()
		x_order = RouteSort.by_value(xs)
		y_order = RouteSort.by_value(ys)
		sorted_x = x_order.map(|i| xs.get(i) ?? 0)
		sorted_y = y_order.map(|i| ys.get(i) ?? 0)
		x_rank = x_order.fold_with_index(List.repeat(0, nx), |acc, xi, rank| acc.set(xi, rank) ?? [])
		y_rank = y_order.fold_with_index(List.repeat(0, ny), |acc, yi, rank| acc.set(yi, rank) ?? [])
		every_box = RouteGrid.indices(boxes.len())
		rows = RouteGrid.crossing_lines(sorted_y, boxes.map(|box| { lo: box.min_y, hi: box.max_y }), every_box)
		columns = RouteGrid.crossing_lines(sorted_x, boxes.map(|box| { lo: box.min_x, hi: box.max_x }), every_box)
		shared_y = shared.map(|box| { lo: box.min_y, hi: box.max_y })
		shared_x = shared.map(|box| { lo: box.min_x, hi: box.max_x })
		rows_by_min = RouteGrid.crossing_lines(sorted_y, shared_y, RouteSort.by_value(shared.map(|box| box.min_x)))
		rows_by_max = RouteGrid.crossing_lines(sorted_y, shared_y, RouteSort.by_value(shared.map(|box| 0 - box.max_x)))
		columns_by_min = RouteGrid.crossing_lines(sorted_x, shared_x, RouteSort.by_value(shared.map(|box| box.min_y)))
		columns_by_max = RouteGrid.crossing_lines(sorted_x, shared_x, RouteSort.by_value(shared.map(|box| 0 - box.max_y)))
		# A grid point's key orders points as the search's deterministic tie-break.
		start_clear = !RouteGrid.point_blocked(start, boxes)
		start_key = if start_clear {
			Ok(0)
		} else {
			var $found = False
			var $key = 0
			var $xi = 0
			while $xi < nx and !$found {
				var $yi = 0
				while $yi < ny and !$found {
					if !RouteGrid.point_blocked({ x: xs.get($xi) ?? 0, y: ys.get($yi) ?? 0 }, boxes) {
						$found = True
						$key = $xi * ny + $yi
					}
					$yi = $yi + 1
				}
				$xi = $xi + 1
			}
			if $found {
				Ok($key)
			} else {
				Err(NoClearPoint)
			}
		}
		match start_key {
			Err(_) => []
			Ok(origin) => {
				finish_key = if RouteGrid.point_blocked(finish, boxes) {
					origin
				} else {
					fx = if finish.x == start.x {
						0
					} else {
						1
					}
					fy = if finish.y == start.y {
						0
					} else {
						1
					}
					fx * ny + fy
				}
				# Only reached states are stored: a state's slot is found through an
				# open-addressing table keyed by state, and cost, predecessor and
				# visited flag live in slot-indexed lists.
				state_count = nx * ny * 2
				unset = state_count
				empty = U64.highest
				var $table = List.repeat(empty, 64)
				var $table_slot = List.repeat(0, 64)
				var $slot_state = [origin * 2, origin * 2 + 1]
				var $cost = [0.0, 0.0]
				var $previous = [unset, unset]
				var $visited = [False, False]
				first_at = RouteGrid.table_find($table, origin * 2)
				$table = $table.set(first_at, origin * 2) ?? []
				$table_slot = $table_slot.set(first_at, 0) ?? []
				second_at = RouteGrid.table_find($table, origin * 2 + 1)
				$table = $table.set(second_at, origin * 2 + 1) ?? []
				$table_slot = $table_slot.set(second_at, 1) ?? []
				var $heap_cost = [0.0, 0.0]
				var $heap_state = [origin * 2, origin * 2 + 1]
				var $heap_slot = [0, 1]
				var $moves = []
				var $searching = True
				while $searching {
					if $heap_state.is_empty() {
						$searching = False
					} else {
						popped_cost = $heap_cost.get(0) ?? 0
						popped = $heap_state.get(0) ?? 0
						popped_slot = $heap_slot.get(0) ?? 0
						last = $heap_state.len() - 1
						$heap_cost = ($heap_cost.set(0, $heap_cost.get(last) ?? 0) ?? []).drop_last(1)
						$heap_state = ($heap_state.set(0, $heap_state.get(last) ?? 0) ?? []).drop_last(1)
						$heap_slot = ($heap_slot.set(0, $heap_slot.get(last) ?? 0) ?? []).drop_last(1)
						var $at = 0
						var $sifting = True
						while $sifting {
							left = 2 * $at + 1
							right = left + 1
							size = $heap_state.len()
							smallest_left = if left < size and RouteGrid.heap_less($heap_cost, $heap_state, left, $at) {
								left
							} else {
								$at
							}
							smallest = if right < size and RouteGrid.heap_less($heap_cost, $heap_state, right, smallest_left) {
								right
							} else {
								smallest_left
							}
							if smallest == $at {
								$sifting = False
							} else {
								$heap_cost = $heap_cost.swap($at, smallest) ?? []
								$heap_state = $heap_state.swap($at, smallest) ?? []
								$heap_slot = $heap_slot.swap($at, smallest) ?? []
								$at = smallest
							}
						}
						stale = ($visited.get(popped_slot) ?? True) or popped_cost != ($cost.get(popped_slot) ?? F64.infinity)
						key = popped // 2
						if stale {
							{}
						} else if key == finish_key {
							$searching = False
						} else {
							arrival_axis = popped % 2
							xi = key // ny
							yi = key % ny
							px = xs.get(xi) ?? 0
							py = ys.get(yi) ?? 0
							rx = x_rank.get(xi) ?? 0
							ry = y_rank.get(yi) ?? 0
							at_start = key == origin
							nothing = { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
							$moves = $moves.clear()
							# Moves along the row: everything visible left and right.
							row_turn = if at_start or arrival_axis == 0 {
								0
							} else {
								bend_penalty
							}
							var $right_limit = F64.infinity
							var $left_limit = 0 - F64.infinity
							for slot in (rows.offsets.get(ry) ?? 0)..<(rows.offsets.get(ry + 1) ?? 0) {
								box = boxes.get(rows.entries.get(slot) ?? 0) ?? nothing
								if box.max_x > px and box.min_x < $right_limit {
									$right_limit = box.min_x
								}
								if box.min_x < px and box.max_x > $left_limit {
									$left_limit = box.max_x
								}
							}
							row_end = rows_by_min.offsets.get(ry + 1) ?? 0
							var $pointer = rows_by_min.offsets.get(ry) ?? 0
							var $touching = 0.U64
							var $b = rx + 1
							while $b < nx and (sorted_x.get($b) ?? 0) <= $right_limit {
								qx = sorted_x.get($b) ?? 0
								while $pointer < row_end and (shared.get(rows_by_min.entries.get($pointer) ?? 0) ?? nothing).min_x < qx {
									if (shared.get(rows_by_min.entries.get($pointer) ?? 0) ?? nothing).max_x > px {
										$touching = $touching + 1
									}
									$pointer = $pointer + 1
								}
								candidate = popped_cost + (qx - px).abs() + (py - py).abs() + row_turn + $touching.to_f64() * shared_penalty
								$moves = $moves.append({ state: ((x_order.get($b) ?? 0) * ny + yi) * 2, candidate })
								$b = $b + 1
							}
							row_back_end = rows_by_max.offsets.get(ry + 1) ?? 0
							$pointer = rows_by_max.offsets.get(ry) ?? 0
							$touching = 0
							$b = rx
							while $b > 0 and (sorted_x.get($b - 1) ?? 0) >= $left_limit {
								qx = sorted_x.get($b - 1) ?? 0
								while $pointer < row_back_end and (shared.get(rows_by_max.entries.get($pointer) ?? 0) ?? nothing).max_x > qx {
									if (shared.get(rows_by_max.entries.get($pointer) ?? 0) ?? nothing).min_x < px {
										$touching = $touching + 1
									}
									$pointer = $pointer + 1
								}
								candidate = popped_cost + (qx - px).abs() + (py - py).abs() + row_turn + $touching.to_f64() * shared_penalty
								$moves = $moves.append({ state: ((x_order.get($b - 1) ?? 0) * ny + yi) * 2, candidate })
								$b = $b - 1
							}
							# Moves along the column: everything visible up and down.
							column_turn = if at_start or arrival_axis == 1 {
								0
							} else {
								bend_penalty
							}
							var $down_limit = F64.infinity
							var $up_limit = 0 - F64.infinity
							for slot in (columns.offsets.get(rx) ?? 0)..<(columns.offsets.get(rx + 1) ?? 0) {
								box = boxes.get(columns.entries.get(slot) ?? 0) ?? nothing
								if box.max_y > py and box.min_y < $down_limit {
									$down_limit = box.min_y
								}
								if box.min_y < py and box.max_y > $up_limit {
									$up_limit = box.max_y
								}
							}
							column_end = columns_by_min.offsets.get(rx + 1) ?? 0
							$pointer = columns_by_min.offsets.get(rx) ?? 0
							$touching = 0
							var $c = ry + 1
							while $c < ny and (sorted_y.get($c) ?? 0) <= $down_limit {
								qy = sorted_y.get($c) ?? 0
								while $pointer < column_end and (shared.get(columns_by_min.entries.get($pointer) ?? 0) ?? nothing).min_y < qy {
									if (shared.get(columns_by_min.entries.get($pointer) ?? 0) ?? nothing).max_y > py {
										$touching = $touching + 1
									}
									$pointer = $pointer + 1
								}
								candidate = popped_cost + (px - px).abs() + (qy - py).abs() + column_turn + $touching.to_f64() * shared_penalty
								$moves = $moves.append({ state: (xi * ny + (y_order.get($c) ?? 0)) * 2 + 1, candidate })
								$c = $c + 1
							}
							column_back_end = columns_by_max.offsets.get(rx + 1) ?? 0
							$pointer = columns_by_max.offsets.get(rx) ?? 0
							$touching = 0
							$c = ry
							while $c > 0 and (sorted_y.get($c - 1) ?? 0) >= $up_limit {
								qy = sorted_y.get($c - 1) ?? 0
								while $pointer < column_back_end and (shared.get(columns_by_max.entries.get($pointer) ?? 0) ?? nothing).max_y > qy {
									if (shared.get(columns_by_max.entries.get($pointer) ?? 0) ?? nothing).min_y < py {
										$touching = $touching + 1
									}
									$pointer = $pointer + 1
								}
								candidate = popped_cost + (px - px).abs() + (qy - py).abs() + column_turn + $touching.to_f64() * shared_penalty
								$moves = $moves.append({ state: (xi * ny + (y_order.get($c - 1) ?? 0)) * 2 + 1, candidate })
								$c = $c - 1
							}
							# Every move reaches a distinct state, so their order does not matter.
							for move in $moves {
								found_at = RouteGrid.table_find($table, move.state)
								known = ($table.get(found_at) ?? empty) == move.state
								slot = if known {
									$table_slot.get(found_at) ?? 0
								} else {
									$slot_state.len()
								}
								improves = if known {
									!($visited.get(slot) ?? True) and move.candidate < ($cost.get(slot) ?? F64.infinity)
								} else {
									move.candidate < F64.infinity
								}
								if improves {
									if known {
										$cost = $cost.set(slot, move.candidate) ?? []
										$previous = $previous.set(slot, popped) ?? []
									} else {
										$table = $table.set(found_at, move.state) ?? []
										$table_slot = $table_slot.set(found_at, slot) ?? []
										$slot_state = $slot_state.append(move.state)
										$cost = $cost.append(move.candidate)
										$previous = $previous.append(popped)
										$visited = $visited.append(False)
										if $slot_state.len() * 2 > $table.len() {
											# Keep the table at most half full.
											capacity = $table.len() * 2
											var $grown = List.repeat(empty, capacity)
											var $grown_slot = List.repeat(0, capacity)
											for index in 0..<$slot_state.len() {
												state = $slot_state.get(index) ?? 0
												at = RouteGrid.table_find($grown, state)
												$grown = $grown.set(at, state) ?? []
												$grown_slot = $grown_slot.set(at, index) ?? []
											}
											$table = $grown
											$table_slot = $grown_slot
										}
									}
									$heap_cost = $heap_cost.append(move.candidate)
									$heap_state = $heap_state.append(move.state)
									$heap_slot = $heap_slot.append(slot)
									var $child = $heap_state.len() - 1
									var $rising = True
									while $rising and $child > 0 {
										parent = ($child - 1) // 2
										if RouteGrid.heap_less($heap_cost, $heap_state, $child, parent) {
											$heap_cost = $heap_cost.swap($child, parent) ?? []
											$heap_state = $heap_state.swap($child, parent) ?? []
											$heap_slot = $heap_slot.swap($child, parent) ?? []
											$child = parent
										} else {
											$rising = False
										}
									}
								}
							}
							$visited = $visited.set(popped_slot, True) ?? []
						}
					}
				}
				table = $table
				table_slot = $table_slot
				cost = $cost
				previous = $previous
				cost_of = |state| {
					at = RouteGrid.table_find(table, state)
					if (table.get(at) ?? empty) == state {
						cost.get(table_slot.get(at) ?? 0) ?? F64.infinity
					} else {
						F64.infinity
					}
				}
				previous_of = |state| {
					at = RouteGrid.table_find(table, state)
					if (table.get(at) ?? empty) == state {
						previous.get(table_slot.get(at) ?? 0) ?? unset
					} else {
						unset
					}
				}
				finish_horizontal = finish_key * 2
				finish_vertical = finish_horizontal + 1
				finish_state = if cost_of(finish_horizontal) <= cost_of(finish_vertical) {
					finish_horizontal
				} else {
					finish_vertical
				}
				if F64.is_finite(cost_of(finish_state)) == False {
					[]
				} else {
					# Walk back to the origin; an unrecorded step stands for the finish.
					var $reversed = []
					var $state = finish_state
					var $fuel = state_count + 1
					while $fuel > 0 and $state // 2 != origin {
						if $state == unset {
							$reversed = $reversed.append(finish)
							$state = origin * 2
						} else {
							k = $state // 2
							$reversed = $reversed.append({ x: xs.get(k // ny) ?? 0, y: ys.get(k % ny) ?? 0 })
							$state = previous_of($state)
						}
						$fuel = $fuel - 1
					}
					rebuilt = [start].concat($reversed.rev())
					if RouteGrid.path_visible(rebuilt, boxes) {
						rebuilt
					} else {
						[]
					}
				}
			}
		}
	}

	## The table position holding `state`, or the empty position where it
	## belongs. The table is a power of two in size and never full.
	table_find : List(U64), U64 -> U64
	table_find = |table, state| {
		mask = table.len() - 1
		var $at = state.times_wrap(11400714819323198485).shr_zf_wrap(29).bitwise_and(mask)
		var $looking = True
		while $looking {
			here = table.get($at) ?? U64.highest
			if here == state or here == U64.highest {
				$looking = False
			} else {
				$at = ($at + 1).bitwise_and(mask)
			}
		}
		$at
	}
}
