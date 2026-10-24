app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import RouteGrid

## The router's grid path search, against a plain Dijkstra search that
## scans every grid state for the next one and every grid point for the
## moves out of it, and rescans every earlier route for every move. Both
## ignore obstacles that hold an end, which no path can avoid. On
## obstacles, earlier routes and penalties drawn from the input (coarse
## coordinates make coincident lines and degenerate boxes common), the A*
## search finds a path exactly when the reference does, its path runs from
## the start to the finish along clear axis-aligned moves, and its cost
## equals the reference's least cost.
##
## The input is also repeated as 1 and 8 side-by-side copies; the larger
## search may allocate at most a little more than 8 times as often per box
## as the smaller one, and must free what it allocates.
Case : { start : RouteGrid.Point, finish : RouteGrid.Point, boxes : List(RouteGrid.Bounds), prior : List(List(RouteGrid.Point)), bend : F64, shared : F64 }

case : List(U8), U64 -> Case
case = |bytes, copies| {
	byte = |i| (bytes.get(i) ?? 0).to_u64()
	coordinate = |i| (byte(i) % 13).to_f64() * 10
	box_count = byte(0) % 9
	width = 140.0
	var $boxes = []
	var $prior = []
	for copy in 0..<copies {
		shift = copy.to_f64() * width
		for k in 0..<box_count {
			x = coordinate(10 + 4 * k) + shift
			y = coordinate(11 + 4 * k)
			w = (byte(12 + 4 * k) % 5).to_f64() * 8
			h = (byte(13 + 4 * k) % 5).to_f64() * 8
			$boxes = $boxes.append({ min_x: x, min_y: y, max_x: x + w, max_y: y + h })
		}
		for r in 0..<(byte(1) % 4) {
			count = 2 + byte(50 + r) % 4
			var $points = []
			var $at = { x: coordinate(60 + 8 * r) + shift, y: coordinate(61 + 8 * r) }
			for k in 0..<count {
				$points = $points.append($at)
				$at = if k % 2 == 0 {
					{ x: coordinate(62 + 8 * r + k) + shift, y: $at.y }
				} else {
					{ x: $at.x, y: coordinate(62 + 8 * r + k) }
				}
			}
			$prior = $prior.append($points)
		}
	}
	span = (copies - 1).to_f64() * width
	penalty = |b| match b % 3 {
		0 => 0
		1 => 4
		_ => 16
	}
	{
		start: { x: coordinate(2), y: coordinate(3) },
		finish: { x: coordinate(4) + span, y: coordinate(5) },
		boxes: $boxes,
		prior: $prior,
		bend: penalty(byte(6)),
		shared: penalty(byte(7)),
	}
}

## The original definition, kept as the oracle.
reference : Case -> List(RouteGrid.Point)
reference = |c| {
	inside = |point, box| point.x > box.min_x and point.x < box.max_x and point.y > box.min_y and point.y < box.max_y
	boxes = c.boxes.keep_if(|box| !inside(c.start, box) and !inside(c.finish, box))
	xs = unique_values([c.start.x, c.finish.x].concat(boxes.fold([], |acc, box| acc.concat([box.min_x, box.max_x]))))
	ys = unique_values([c.start.y, c.finish.y].concat(boxes.fold([], |acc, box| acc.concat([box.min_y, box.max_y]))))
	points = xs.map(|x| ys.map(|y| { x, y })).join().keep_if(|point| RouteGrid.point_blocked(point, boxes) == False)
	start_index = points.find_first_index(|point| point == c.start) ?? 0
	finish_index = points.find_first_index(|point| point == c.finish) ?? start_index
	state_count = points.len() * 2
	start_horizontal = start_index * 2
	start_vertical = start_horizontal + 1
	initial_distances = (List.repeat(F64.infinity, state_count).set(start_horizontal, 0) ?? []).set(start_vertical, 0) ?? []
	searched = grid_walk(points, boxes, finish_index, start_index, c, initial_distances, List.repeat(state_count, state_count), List.repeat(False, state_count), state_count)
	finish_horizontal = finish_index * 2
	finish_vertical = finish_horizontal + 1
	finish_state = if (searched.distances.get(finish_horizontal) ?? F64.infinity) <= (searched.distances.get(finish_vertical) ?? F64.infinity) {
		finish_horizontal
	} else {
		finish_vertical
	}
	if F64.is_finite(searched.distances.get(finish_state) ?? F64.infinity) == False {
		[]
	} else {
		rebuilt = grid_rebuild(points, searched.previous, start_index, finish_state, c.start, c.finish, [], state_count + 1)
		if RouteGrid.path_visible(rebuilt, boxes) {
			rebuilt
		} else {
			[]
		}
	}
}

unique_values = |values| values.fold(
	[],
	|acc, value| if acc.contains(value) {
		acc
	} else {
		acc.append(value)
	},
)

visible = |a, b, boxes| (a.x == b.x or a.y == b.y) and boxes.all(|box| RouteGrid.segment_hits(a, b, box) == False)

shared_count = |a, b, prior| {
	zero : U64
	zero = 0
	prior.fold(
		zero,
		|count, points| points.fold_with_index(
			count,
			|n, c, i| match points.get(i + 1) {
				Ok(d) => if RouteGrid.segment_hits(a, b, { min_x: c.x.min(d.x) - 0.000001, min_y: c.y.min(d.y) - 0.000001, max_x: c.x.max(d.x) + 0.000001, max_y: c.y.max(d.y) + 0.000001 }) {
					n + 1
				} else {
					n
				}
				Err(_) => n
			},
		),
	)
}

grid_walk = |points, boxes, finish_index, start_index, c, distances, previous, visited, fuel| if fuel == 0 {
	{ distances, previous }
} else {
	chosen = distances.fold_with_index(
		{ index: 0, distance: F64.infinity },
		|best, distance, i| if (visited.get(i) ?? True) == False and distance < best.distance {
			{ index: i, distance }
		} else {
			best
		},
	)
	point_index = chosen.index // 2
	if F64.is_finite(chosen.distance) == False or point_index == finish_index {
		{ distances, previous }
	} else {
		from_point = points.get(point_index) ?? { x: 0, y: 0 }
		arrival_axis = chosen.index % 2
		relaxed = points.fold_with_index(
			{ distances, previous },
			|state, point, i| if i == point_index or visible(from_point, point, boxes) == False {
				state
			} else {
				move_axis = if from_point.y == point.y {
					0
				} else {
					1
				}
				next_state = i * 2 + move_axis
				turn = if point_index == start_index or arrival_axis == move_axis {
					0
				} else {
					c.bend
				}
				shared = shared_count(from_point, point, c.prior).to_f64() * c.shared
				candidate = chosen.distance + (point.x - from_point.x).abs() + (point.y - from_point.y).abs() + turn + shared
				if (visited.get(next_state) ?? False) == False and candidate < (state.distances.get(next_state) ?? F64.infinity) {
					{ distances: state.distances.set(next_state, candidate) ?? [], previous: state.previous.set(next_state, chosen.index) ?? [] }
				} else {
					state
				}
			},
		)
		grid_walk(points, boxes, finish_index, start_index, c, relaxed.distances, relaxed.previous, visited.set(chosen.index, True) ?? [], fuel - 1)
	}
}

grid_rebuild = |points, previous, start_index, state_index, start, finish, acc, fuel| if fuel == 0 or state_index // 2 == start_index {
	[start].concat(acc)
} else {
	point = points.get(state_index // 2) ?? finish
	grid_rebuild(points, previous, start_index, previous.get(state_index) ?? (start_index * 2), start, finish, [point].concat(acc), fuel - 1)
}

search : Case -> List(RouteGrid.Point)
search = |c| RouteGrid.shortest(c.start, c.finish, c.boxes, c.bend, c.shared, c.prior)

## A path's cost as the search counts it: every move's length, a bend
## penalty where it turns after the first point, and the shared penalty for
## every earlier segment each move touches.
cost : Case, List(RouteGrid.Point) -> F64
cost = |c, points| {
	touching = |a, b| shared_count(a, b, c.prior).to_f64() * c.shared
	points.fold_with_index(
		0,
		|total, a, i| match points.get(i + 1) {
			Ok(b) => {
				turn = if i == 0 {
					0
				} else {
					p = points.get(i - 1) ?? a
					if (p.y == a.y) == (a.y == b.y) {
						0
					} else {
						c.bend
					}
				}
				total + (b.x - a.x).abs() + (b.y - a.y).abs() + turn + touching(a, b)
			}
			Err(_) => total
		},
	)
}

## Both searches agree: neither finds a path, or both do, the A* path is a
## clear axis-aligned walk from start to finish, and it costs no more than
## the reference's (up to rounding).
agree : Case -> Bool
agree = |c| {
	found = search(c)
	expected = reference(c)
	inside = |point, box| point.x > box.min_x and point.x < box.max_x and point.y > box.min_y and point.y < box.max_y
	kept = c.boxes.keep_if(|box| !inside(c.start, box) and !inside(c.finish, box))
	if expected.is_empty() or found.is_empty() {
		expected.is_empty() and found.is_empty()
	} else {
		ends = found.first() == Ok(c.start) and found.last() == Ok(c.finish)
		expected_cost = cost(c, expected)
		found_cost = cost(c, found)
		ends and RouteGrid.path_visible(found, kept) and (found_cost - expected_cost).abs() <= 0.000001 * expected_cost.abs().max(1)
	}
}

test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	small = case(bytes, 1)
	if !agree(small) {
		crash "the A* search disagrees with the reference search"
	}
	large = case(bytes, 8)
	small_cost = Fuzz.measure_allocs!(|{}| search(small)).allocations
	large_cost = Fuzz.measure_allocs!(|{}| search(large)).allocations
	Fuzz.expect_no_leaks!(|{}| search(large))
	small_size = small.boxes.len() + small.prior.len() + 1
	large_size = large.boxes.len() + large.prior.len() + 1
	if large_cost > small_cost * large_size * 5 // (4 * small_size) + 512 {
		crash "searching ${large_size.to_str()} boxes and routes took ${large_cost.to_str()} allocations, against ${small_cost.to_str()} for ${small_size.to_str()}"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "graph-layout-route-search",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect(case(bytes, 1)),
})

expect {
	# Every byte pattern in a small sweep agrees with the reference.
	List.repeat(0, 64).map_with_index(|_, i| i).all(
		|seed| {
			bytes = List.repeat(0, 96).map_with_index(|_, i| ((i * 37 + seed * 101 + (i * seed) % 17) % 256).to_u8_wrap())
			agree(case(bytes, 1))
		},
	)
}

expect {
	# An obstacle holding the start is ignored; the path still avoids the
	# other one.
	c = { start: { x: 5, y: 5 }, finish: { x: 40, y: 5 }, boxes: [{ min_x: 0, min_y: 0, max_x: 10, max_y: 10 }, { min_x: 20, min_y: 0, max_x: 30, max_y: 20 }], prior: [[{ x: 0, y: 20 }, { x: 40, y: 20 }]], bend: 16, shared: 4 }
	agree(c) and search(c).first() == Ok(c.start) and search(c).last() == Ok(c.finish)
}

expect {
	# A zero-width obstacle still blocks a move that crosses its line.
	c = { start: { x: 0, y: 5 }, finish: { x: 20, y: 5 }, boxes: [{ min_x: 10, min_y: 0, max_x: 10, max_y: 10 }], prior: [], bend: 16, shared: 4 }
	agree(c) and search(c).len() > 2
}
