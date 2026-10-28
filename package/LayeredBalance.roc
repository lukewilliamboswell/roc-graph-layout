## Shared Brandes-Kopf decisions. Graph adapters retain their own port,
## conflict and compaction data; median selection and four-pass balancing
## use the same implementation for flat and coordinated flow.
LayeredBalance :: {}.{
	Candidate : { node : U64, position : I64, blocked : Bool }
	select_median : U64, Bool, I64, (U64 -> Candidate) -> [None, Some(Candidate)]
	select_median = |count, increasing, cutoff, candidate| {
		if count == 0 {
			None
		} else {
			low = (count - 1) / 2
			high = count / 2
			indices = if low == high {
				[low]
			} else if increasing {
				[low, high]
			} else {
				[high, low]
			}
			var $chosen = None
			for index in indices {
				if $chosen == None {
					value = candidate(index)
					if !value.blocked and (
						if increasing {
							cutoff < value.position
						} else {
							cutoff > value.position
						}
					) {
						$chosen = Some(value)
					}
				}
			}
			$chosen
		}
	}

	## The four candidates have constant size. Stable insertion preserves the
	## input order of equal values, including signed zero, without a general
	## quicksort or a stateful sorting graph.
	middle_mean : List(F64) -> F64
	middle_mean = |values| {
		var $sorted = values
		for i in 1..<$sorted.len().max(1) {
			var $j = i
			var $moving = True
			while $moving and $j > 0 {
				a = $sorted.get($j - 1) ?? 0
				b = $sorted.get($j) ?? 0
				if a > b {
					$sorted = ($sorted.set($j - 1, b) ?? []).set($j, a) ?? []
					$j = $j - 1
				} else {
					$moving = False
				}
			}
		}
		(($sorted.get(1) ?? 0) + ($sorted.get(2) ?? 0)) / 2
	}
}

expect LayeredBalance.middle_mean([40, 10, 30, 20]) == 25

expect {
	select = |index| { node: index + 4, position: index.to_i64_wrap(), blocked: index == 1 }
	LayeredBalance.select_median(4, True, -1, select) == Some({ node: 6, position: 2, blocked: False })
		and LayeredBalance.select_median(4, False, 4, select) == Some({ node: 6, position: 2, blocked: False })
		and LayeredBalance.select_median(4, True, 2, select) == None
		and LayeredBalance.select_median(0, True, -1, select) == None
}
