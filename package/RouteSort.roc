## Internal deterministic sorting for the router. A bottom-up merge sort
## whose cost is `n log n` for every input order, including sorted,
## reverse-sorted and equal-key inputs.
RouteSort :: {}.{

	## The positions `0..<count` ordered by `less`; positions that neither
	## precedes keep their own order.
	by : U64, (U64, U64 -> Bool) -> List(U64)
	by = |count, less| {
		# Two buffers, written in place and swapped after every pass.
		var $a = List.repeat(0, count).map_with_index(|_, i| i)
		var $b = List.repeat(0, count)
		var $width = 1
		while $width < count {
			var $lo = 0
			while $lo < count {
				mid = ($lo + $width).min(count)
				hi = ($lo + 2 * $width).min(count)
				var $i = $lo
				var $j = mid
				var $k = $lo
				while $i < mid or $j < hi {
					take_left = if $j >= hi {
						True
					} else if $i >= mid {
						False
					} else {
						!less($a.get($j) ?? 0, $a.get($i) ?? 0)
					}
					if take_left {
						$b = $b.set($k, $a.get($i) ?? 0) ?? []
						$i = $i + 1
					} else {
						$b = $b.set($k, $a.get($j) ?? 0) ?? []
						$j = $j + 1
					}
					$k = $k + 1
				}
				$lo = hi
			}
			merged = $b
			$b = $a
			$a = merged
			$width = $width * 2
		}
		$a
	}

	## The positions of `keys` in ascending order of key.
	by_value : List(F64) -> List(U64)
	by_value = |keys| RouteSort.by(keys.len(), |a, b| (keys.get(a) ?? 0) < (keys.get(b) ?? 0))
}

expect RouteSort.by_value([3, 1, 2, 1]) == [1, 3, 2, 0]

expect RouteSort.by_value([]) == []

expect RouteSort.by(5, |a, b| a > b) == [4, 3, 2, 1, 0]
