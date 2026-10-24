import RouteSort

## Internal port spreading for the router: where several route ends share a
## node side, a group side or an exact attachment, each needs its place
## among them. Items are grouped by a caller-supplied relation and ranked
## within their group by a caller-supplied order, with one sort of all
## items instead of a scan of every item per item.
RoutePorts :: {}.{

	## For `count` items, each item's rank within its group and the group's
	## size. `group_before` orders groups and `same_group` decides membership;
	## both must agree. `before` orders items within one group and must tell
	## any two distinct members apart.
	ranks : U64, (U64, U64 -> Bool), (U64, U64 -> Bool), (U64, U64 -> Bool) -> List({ rank : U64, count : U64 })
	ranks = |count, group_before, same_group, before| {
		order = RouteSort.by(count, |a, b| group_before(a, b) or (!group_before(b, a) and before(a, b)))
		var $result = List.repeat({ rank: 0, count: 1 }, count)
		var $start = 0
		while $start < count {
			first = order.get($start) ?? 0
			var $end = $start + 1
			while $end < count and same_group(first, order.get($end) ?? 0) {
				$end = $end + 1
			}
			size = $end - $start
			for k in $start..<$end {
				$result = $result.set(order.get(k) ?? 0, { rank: k - $start, count: size }) ?? []
			}
			$start = $end
		}
		$result
	}

	## Lexicographic order on floating keys, treating `a == b` as a tie.
	float_before : F64, F64 -> [Before, Tie, After]
	float_before = |a, b| if a < b {
		Before
	} else if a > b {
		After
	} else {
		Tie
	}
}

expect {
	# Two groups by parity, ranked by descending value within each.
	values = [5, 2, 9, 4, 7]
	group = |i| (values.get(i) ?? 0) % 2
	value = |i| values.get(i) ?? 0
	RoutePorts.ranks(5, |a, b| group(a) < group(b), |a, b| group(a) == group(b), |a, b| value(a) > value(b)) == [{ rank: 2, count: 3 }, { rank: 1, count: 2 }, { rank: 0, count: 3 }, { rank: 0, count: 2 }, { rank: 1, count: 3 }]
}
