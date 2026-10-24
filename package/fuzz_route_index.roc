app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import RouteIndex

## The router's spatial indices answer exactly what a scan of every box or
## every route segment would. Boxes (coarse coordinates, so shared edges,
## zero-size boxes and boxes far outside the others are common) and routes
## come from the input; routes are then replaced and removed. For segments
## from the input:
##
## - `segment_blocked` agrees with testing every kept box;
## - `point_blocked` agrees with testing every kept box;
## - `boxes_meeting` and `segments_meeting` report each meeting box or
##   live segment once, and nothing else;
## - `touching` agrees with counting over every segment of every other route.
##
## The input is also repeated as 1 and 8 side-by-side copies. Building both
## indices and asking every question of the copies may allocate at most a
## little more than 8 times as often as for one copy, and frees everything.
Shape : { boxes : List(RouteIndex.Bounds), routes : List(List(RouteIndex.Point)), queries : List({ a : RouteIndex.Point, b : RouteIndex.Point }) }

shape : List(U8), U64 -> Shape
shape = |bytes, copies| {
	byte = |i| (bytes.get(i) ?? 0).to_u64()
	coordinate = |i| (byte(i) % 17).to_f64() * 10 - 30
	box_count = byte(0) % 12
	route_count = byte(1) % 6
	query_count = 1 + byte(2) % 8
	var $boxes = []
	var $routes = []
	var $queries = []
	for copy in 0..<copies {
		shift = copy.to_f64() * 200
		for k in 0..<box_count {
			x = coordinate(10 + 4 * k) + shift
			y = coordinate(11 + 4 * k)
			w = (byte(12 + 4 * k) % 4).to_f64() * 10
			h = (byte(13 + 4 * k) % 4).to_f64() * 10
			$boxes = $boxes.append({ min_x: x, min_y: y, max_x: x + w, max_y: y + h })
		}
		for r in 0..<route_count {
			count = 1 + byte(60 + r) % 5
			var $points = []
			var $at = { x: coordinate(70 + 8 * r) + shift, y: coordinate(71 + 8 * r) }
			for k in 0..<count {
				$points = $points.append($at)
				$at = if k % 2 == byte(66 + r) % 2 {
					{ x: coordinate(72 + 8 * r + k) + shift, y: $at.y }
				} else {
					{ x: $at.x, y: coordinate(72 + 8 * r + k) }
				}
			}
			$routes = $routes.append($points)
		}
		for q in 0..<query_count {
			a = { x: coordinate(120 + 4 * q) + shift, y: coordinate(121 + 4 * q) }
			b = if byte(122 + 4 * q) % 2 == 0 {
				{ x: coordinate(123 + 4 * q) + shift, y: a.y }
			} else {
				{ x: a.x, y: coordinate(123 + 4 * q) }
			}
			$queries = $queries.append({ a, b })
		}
	}
	{ boxes: $boxes, routes: $routes, queries: $queries }
}

hits = |a, b, box| RouteIndex.segment_hits(a, b, box)

## The routes after replacing every third one by its successor and removing
## every fifth, as the router does when it improves routes.
edited : Shape -> RouteIndex.Segments
edited = |s| {
	grid = RouteIndex.grid_for(s.boxes, s.boxes.len() + s.routes.len())
	first = s.routes.fold_with_index(RouteIndex.segments(grid, s.routes.len()), |acc, points, edge| RouteIndex.set_route(acc, edge, points))
	s.routes.fold_with_index(
		first,
		|acc, _, edge| if edge % 5 == 4 {
			RouteIndex.set_route(acc, edge, [])
		} else if edge % 3 == 2 {
			RouteIndex.set_route(acc, edge, s.routes.get((edge + 1) % s.routes.len()) ?? [])
		} else {
			acc
		},
	)
}

## The same routes as plain point lists.
edited_routes : Shape -> List(List(RouteIndex.Point))
edited_routes = |s| s.routes.map_with_index(
	|points, edge| if edge % 5 == 4 {
		[]
	} else if edge % 3 == 2 {
		s.routes.get((edge + 1) % s.routes.len()) ?? []
	} else {
		points
	},
)

segments_of = |points| points.map_with_index(|c, i| { c, d: points.get(i + 1) ?? c, last: i + 1 >= points.len() }).keep_if(|item| !item.last)

sorted = |ids| ids.sort_with(
	|x, y| if x < y {
		Before
	} else if x > y {
		After
	} else {
		Same
	},
)

check : Shape -> Bool
check = |s| {
	index = RouteIndex.boxes(s.boxes)
	skip_odd = |id| id % 2 == 1
	routes = edited_routes(s)
	segments = edited(s)
	s.queries.all(
		|query| {
			a = query.a
			b = query.b
			kept = s.boxes.map_with_index(|box, id| { box, id }).keep_if(|item| !skip_odd(item.id))
			blocked = RouteIndex.segment_blocked(index, a, b, skip_odd) == kept.any(|item| hits(a, b, item.box))
			point = RouteIndex.point_blocked(index, a, skip_odd) == kept.any(|item| a.x > item.box.min_x and a.x < item.box.max_x and a.y > item.box.min_y and a.y < item.box.max_y)
			extent = RouteIndex.segment_extent(a, b)
			meeting = sorted(RouteIndex.boxes_meeting(index, extent)) == s.boxes.map_with_index(|box, id| { box, id }).keep_if(|item| RouteIndex.overlaps(extent, item.box)).map(|item| item.id)
			excluded = 1
			expected_touch = routes.fold_with_index(
				0,
				|count, points, edge| if edge == excluded {
					count
				} else {
					segments_of(points).fold(
						count,
						|n, seg| if hits(a, b, RouteIndex.touch_box(seg.c, seg.d)) {
							n + 1
						} else {
							n
						},
					)
				},
			)
			touch = RouteIndex.touching(segments, a, b, excluded) == expected_touch
			live = segments_meeting_expected(routes, extent, excluded)
			found = RouteIndex.segments_meeting(segments, extent, excluded).map(|id| { owner: segments.owners.get(id) ?? 0, position: segments.positions.get(id) ?? 0 })
			listed = found.len() == live.len() and live.all(|item| found.contains(item))
			blocked and point and meeting and touch and listed
		},
	)
}

segments_meeting_expected = |routes, extent, excluded| routes.fold_with_index(
	[],
	|acc, points, edge| if edge == excluded {
		acc
	} else {
		segments_of(points).fold_with_index(
			acc,
			|inner, seg, position| if RouteIndex.overlaps(extent, RouteIndex.touch_box(seg.c, seg.d)) {
				inner.append({ owner: edge, position })
			} else {
				inner
			},
		)
	},
)

## Building both indices and asking every question once.
work : Shape -> U64
work = |s| {
	index = RouteIndex.boxes(s.boxes)
	segments = edited(s)
	s.queries.fold(
		0,
		|acc, query| {
			blocked = if RouteIndex.segment_blocked(index, query.a, query.b, |_| False) {
				1
			} else {
				0
			}
			acc + blocked + RouteIndex.boxes_meeting(index, RouteIndex.segment_extent(query.a, query.b)).len() + RouteIndex.touching(segments, query.a, query.b, 0)
		},
	)
}

test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	small = shape(bytes, 1)
	if !check(small) {
		crash "a spatial index disagrees with a full scan"
	}
	large = shape(bytes, 8)
	small_cost = Fuzz.measure_allocs!(|{}| work(small)).allocations
	large_cost = Fuzz.measure_allocs!(|{}| work(large)).allocations
	Fuzz.expect_no_leaks!(|{}| work(large))
	if large_cost > small_cost * 10 + 512 {
		crash "8 copies took ${large_cost.to_str()} allocations, against ${small_cost.to_str()} for one"
	}
	Fuzz.keep
}

target = Fuzz.target_with!({
	name: "graph-layout-route-index",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect(shape(bytes, 1)),
})

expect {
	List.repeat(0, 96).map_with_index(|_, i| i).all(
		|seed| {
			bytes = List.repeat(0, 160).map_with_index(|_, i| ((i * 53 + seed * 97 + (i * seed) % 23) % 256).to_u8_wrap())
			check(shape(bytes, 1)) and check(shape(bytes, 3))
		},
	)
}
