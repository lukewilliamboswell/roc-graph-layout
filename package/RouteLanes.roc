import RouteSort

## Internal lane separation for the router. Movable route segments that lie
## on the same line and overlap are spread into evenly spaced lanes, in
## order of edge and then of segment along the route.
##
## A segment's lanes are decided only by the segments it overlaps itself:
## with `k` such segments (itself included) and `r` of them earlier in
## order, it moves by `(r - (k - 1) / 2) * gap`. Counting is done per line
## with sorted ends and Fenwick trees, so many segments on one line cost
## `n log n` rather than every pair.
RouteLanes :: {}.{
	Segment : { edge : U64, index : U64, horizontal : Bool, coord : F64, low : F64, high : F64, movable : Bool }

	## The first position in ascending `sorted` whose value is at least `value`.
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

	## The first position in ascending `sorted` whose value is above `value`.
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

	## How many entries a Fenwick tree holds in its first `count` places.
	prefix : List(U64), U64 -> U64
	prefix = |tree, count| {
		var $sum = 0
		var $at = count
		while $at > 0 {
			$sum = $sum + (tree.get($at - 1) ?? 0)
			$at = $at.bitwise_and($at - 1)
		}
		$sum
	}

	## The lane coordinate of every segment, index-aligned with `segments`,
	## which must be listed in order of edge and then of segment index.
	lanes : List(Segment), F64 -> List(F64)
	lanes = |segments, gap| {
		nothing = { edge: 0, index: 0, horizontal: True, coord: 0, low: 0, high: 0, movable: False }
		movable = List.repeat(0, segments.len()).map_with_index(|_, i| i).keep_if(|i| (segments.get(i) ?? nothing).movable)
		# Lines: movable segments sorted by direction and coordinate.
		order = RouteSort.by(
			movable.len(),
			|a, b| {
				sa = segments.get(movable.get(a) ?? 0) ?? nothing
				sb = segments.get(movable.get(b) ?? 0) ?? nothing
				(!sa.horizontal and sb.horizontal) or (sa.horizontal == sb.horizontal and sa.coord < sb.coord)
			},
		).map(|k| movable.get(k) ?? 0)
		var $result = segments.map(|segment| segment.coord)
		var $start = 0
		while $start < order.len() {
			first = segments.get(order.get($start) ?? 0) ?? nothing
			var $end = $start + 1
			while $end < order.len() and (segments.get(order.get($end) ?? 0) ?? nothing).horizontal == first.horizontal and (segments.get(order.get($end) ?? 0) ?? nothing).coord == first.coord {
				$end = $end + 1
			}
			# One line, in segment order (sorting kept equal lines in input order).
			line = order.sublist({ start: $start, len: $end - $start })
			lows_order = RouteSort.by_value(line.map(|id| (segments.get(id) ?? nothing).low))
			highs_order = RouteSort.by_value(line.map(|id| (segments.get(id) ?? nothing).high))
			lows = lows_order.map(|k| (segments.get(line.get(k) ?? 0) ?? nothing).low)
			highs = highs_order.map(|k| (segments.get(line.get(k) ?? 0) ?? nothing).high)
			low_place = lows_order.fold_with_index(List.repeat(0, line.len()), |acc, k, place| acc.set(k, place) ?? [])
			high_place = highs_order.fold_with_index(List.repeat(0, line.len()), |acc, k, place| acc.set(k, place) ?? [])
			var $low_tree = List.repeat(0, line.len())
			var $high_tree = List.repeat(0, line.len())
			for k in 0..<line.len() {
				id = line.get(k) ?? 0
				s = segments.get(id) ?? nothing
				# Segments overlapping `s`: those starting before it ends, less
				# those ending where it starts or earlier.
				reach = RouteLanes.first_at_least(lows, s.high)
				behind = RouteLanes.first_above(highs, s.low)
				count = reach - behind
				rank = RouteLanes.prefix($low_tree, reach) - RouteLanes.prefix($high_tree, behind)
				if count > 1 {
					$result = $result.set(id, s.coord + (rank.to_f64() - (count - 1).to_f64() / 2) * gap) ?? []
				}
				var $at = (low_place.get(k) ?? 0) + 1
				while $at <= line.len() {
					$low_tree = $low_tree.set($at - 1, ($low_tree.get($at - 1) ?? 0) + 1) ?? []
					$at = $at + ($at - $at.bitwise_and($at - 1))
				}
				$at = (high_place.get(k) ?? 0) + 1
				while $at <= line.len() {
					$high_tree = $high_tree.set($at - 1, ($high_tree.get($at - 1) ?? 0) + 1) ?? []
					$at = $at + ($at - $at.bitwise_and($at - 1))
				}
			}
			$start = $end
		}
		$result
	}
}
