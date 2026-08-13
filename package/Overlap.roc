import Solver

## Placement-independent overlap removal: move node centers as little as
## possible so no two node boxes overlap, keeping the shape of the placement
## intact.
Overlap :: {}.{

	## Minimally move node centers so no two boxes overlap and every pair
	## clears the given gap, preserving each pair's relative order on the
	## axis that separates them. Positions and sizes are index-aligned and
	## the result follows input order; a position without a matching size is
	## treated as a zero-size point, which only counts as overlapping when
	## it sits strictly inside another gap-expanded box, so waypoints on a
	## box edge stay put. A non-finite or negative gap behaves as 0 — this
	## pass has no build step, so it stays total instead of validating.
	##
	## Two projection passes give a guaranteed-clean result in bounded work:
	##
	## 1. Every pair overlapping on both axes whose horizontal resolving
	##    movement is no larger than its vertical one gets a horizontal
	##    separation requirement (the node with the smaller x stays left;
	##    coordinate ties keep the smaller index left), and one per-axis
	##    projection satisfies all of them exactly with the least total
	##    movement.
	## 2. Every pair still too close horizontally — whether or not it
	##    currently overlaps — gets a vertical separation requirement (the
	##    node with the smaller y stays above, ties by index), and a second
	##    projection satisfies those exactly. Requirements that already hold
	##    move nothing.
	##
	## After the second pass every pair is either clear horizontally (the
	## vertical pass never changes x) or was given a vertical requirement
	## the projection satisfied — so no overlapping pair can remain, dense
	## pileups included. Overlaps of at most 1e-9 units count as resolved so
	## floating-point round-off never generates work.
	##
	## Deterministic: pairs are scanned in index order and identical input
	## produces identical output, bit for bit — already-separated input is
	## returned exactly unchanged. The pair scans are quadratic in the node
	## count, which suits the placement sizes this pass serves.
	remove : List({ x : F64, y : F64 }), List({ width : F64, height : F64 }), F64 -> List({ x : F64, y : F64 })
	remove = |positions, sizes, gap| {
		safe_gap = if F64.is_finite(gap) and gap > 0 {
			gap
		} else {
			0.0
		}
		tolerance = 0.000000001
		size_at = |i| sizes.get(i) ?? { width: 0.0, height: 0.0 }
		need_between = |i, j| {
			size_a = size_at(i)
			size_b = size_at(j)
			{
				x: (size_a.width + size_b.width) / 2 + safe_gap,
				y: (size_a.height + size_b.height) / 2 + safe_gap,
			}
		}

		# Pass 1: horizontal requirements for pairs overlapping on both axes
		# where x needs the smaller movement (ties go to x).
		x_rules = positions.fold_with_index(
			[],
			|outer, a, i| positions.fold_with_index(
				outer,
				|acc, b, j| if j <= i {
					acc
				} else {
					need = need_between(i, j)
					overlap_x = need.x - (b.x - a.x).abs()
					overlap_y = need.y - (b.y - a.y).abs()
					if overlap_x > tolerance and overlap_y > tolerance and overlap_x <= overlap_y {
						if a.x < b.x or (a.x == b.x and i < j) {
							acc.append({ left: i, right: j, gap: need.x })
						} else {
							acc.append({ left: j, right: i, gap: need.x })
						}
					} else {
						acc
					}
				},
			),
		)
		with_x = if x_rules.is_empty() {
			positions
		} else {
			solved = Solver.project(
				positions.map(|p| { position: p.x, weight: 1.0 }),
				x_rules,
			)
			positions.map_with_index(|p, i| { ..p, x: solved.get(i) ?? p.x })
		}

		# Pass 2: vertical requirements for every pair still too close
		# horizontally — already-satisfied ones move nothing, so clean
		# placements pass through bit-exact.
		y_rules = with_x.fold_with_index(
			[],
			|outer, a, i| with_x.fold_with_index(
				outer,
				|acc, b, j| if j <= i {
					acc
				} else {
					need = need_between(i, j)
					if (b.x - a.x).abs() < need.x - tolerance {
						if a.y < b.y or (a.y == b.y and i < j) {
							acc.append({ left: i, right: j, gap: need.y })
						} else {
							acc.append({ left: j, right: i, gap: need.y })
						}
					} else {
						acc
					}
				},
			),
		)
		if y_rules.is_empty() {
			with_x
		} else {
			solved = Solver.project(
				with_x.map(|p| { position: p.y, weight: 1.0 }),
				y_rules,
			)
			with_x.map_with_index(|p, i| { ..p, y: solved.get(i) ?? p.y })
		}
	}
}

## Two overlapping equal squares separate along x to exactly touching plus
## the gap, splitting the movement symmetrically: centers 4 apart with
## 10-wide boxes and gap 2 need 12, so each moves 4 and order is preserved.
expect Overlap.remove(
	[{ x: 0, y: 0 }, { x: 4, y: 0 }],
	[{ width: 10, height: 10 }, { width: 10, height: 10 }],
	2,
) == [{ x: 0 - 4, y: 0 }, { x: 8, y: 0 }]

## Already-separated input is returned exactly unchanged, bit for bit.
expect Overlap.remove(
	[{ x: 0, y: 0 }, { x: 100, y: 0.5 }, { x: 3, y: 40 }],
	[{ width: 10, height: 10 }, { width: 10, height: 10 }, { width: 10, height: 10 }],
	2,
) == [{ x: 0, y: 0 }, { x: 100, y: 0.5 }, { x: 3, y: 40 }]

## A zero-size waypoint exactly on a box's gap-expanded edge is touching,
## not overlapping, so nothing moves.
expect Overlap.remove(
	[{ x: 0, y: 0 }, { x: 5, y: 0 }],
	[{ width: 10, height: 10 }, { width: 0, height: 0 }],
	0,
) == [{ x: 0, y: 0 }, { x: 5, y: 0 }]

## A vertically-overlapping pair separates on y when y needs the smaller
## movement, leaving x untouched.
expect Overlap.remove(
	[{ x: 0, y: 0 }, { x: 2, y: 8 }],
	[{ width: 10, height: 10 }, { width: 10, height: 10 }],
	0,
) == [{ x: 0, y: 0 - 1 }, { x: 2, y: 9 }]

## A three-node pileup at one point resolves with no remaining overlaps and
## deterministic order by index, and the result is stable across calls.
expect {
	positions = [{ x: 0, y: 0 }, { x: 0, y: 0 }, { x: 0, y: 0 }]
	sizes = [{ width: 8, height: 8 }, { width: 8, height: 8 }, { width: 8, height: 8 }]
	result = Overlap.remove(positions, sizes, 0)
	separated = result.fold_with_index(
		True,
		|ok_outer, a, i| result.fold_with_index(
			ok_outer,
			|ok, b, j| if j <= i {
				ok
			} else {
				clear_x = (b.x - a.x).abs() >= 8 - 0.000000001
				clear_y = (b.y - a.y).abs() >= 8 - 0.000000001
				ok and (clear_x or clear_y)
			},
		),
	)
	x0 = (result.get(0) ?? { x: 0, y: 0 }).x
	x1 = (result.get(1) ?? { x: 0, y: 0 }).x
	x2 = (result.get(2) ?? { x: 0, y: 0 }).x
	separated and x0 < x1 and x1 < x2 and result == Overlap.remove(positions, sizes, 0)
}

## Heterogeneous sizes: a big box overlapped by two small ones resolves with
## no remaining overlaps, deterministically.
expect {
	positions = [{ x: 0, y: 0 }, { x: 8, y: 1 }, { x: 1, y: 8 }]
	sizes = [{ width: 20, height: 20 }, { width: 4, height: 4 }, { width: 4, height: 4 }]
	result = Overlap.remove(positions, sizes, 0)
	separated = result.fold_with_index(
		True,
		|ok_outer, a, i| result.fold_with_index(
			ok_outer,
			|ok, b, j| if j <= i {
				ok
			} else {
				size_a = sizes.get(i) ?? { width: 0.0, height: 0.0 }
				size_b = sizes.get(j) ?? { width: 0.0, height: 0.0 }
				need_x = (size_a.width + size_b.width) / 2
				need_y = (size_a.height + size_b.height) / 2
				clear_x = (b.x - a.x).abs() >= need_x - 0.000000001
				clear_y = (b.y - a.y).abs() >= need_y - 0.000000001
				ok and (clear_x or clear_y)
			},
		),
	)
	separated and result == Overlap.remove(positions, sizes, 0)
}

## Idempotence: removing overlaps from an already-cleaned placement changes
## nothing.
expect {
	positions = [{ x: 0, y: 0 }, { x: 3, y: 1 }, { x: 10, y: 10 }, { x: 11, y: 12 }, { x: 6, y: 0.5 }]
	sizes = List.repeat({ width: 6, height: 4 }, 5)
	once = Overlap.remove(positions, sizes, 1)
	Overlap.remove(once, sizes, 1) == once
}

## Relative order is preserved: for every initially-overlapping pair, the
## node with the smaller coordinate on the pair's separating axis (the axis
## needing less movement) keeps the smaller coordinate afterward, and every
## pair ends clear of the gap within 1e-9.
expect {
	positions = [{ x: 0, y: 0 }, { x: 3, y: 1 }, { x: 10, y: 10 }, { x: 11, y: 12 }, { x: 6, y: 0.5 }]
	sizes = List.repeat({ width: 6, height: 4 }, 5)
	result = Overlap.remove(positions, sizes, 1)
	check = positions.fold_with_index(
		True,
		|ok_outer, a, i| positions.fold_with_index(
			ok_outer,
			|ok, b, j| if j <= i {
				ok
			} else {
				need_x = 7.0
				need_y = 5.0
				overlap_x = need_x - (b.x - a.x).abs()
				overlap_y = need_y - (b.y - a.y).abs()
				out_a = result.get(i) ?? { x: 0, y: 0 }
				out_b = result.get(j) ?? { x: 0, y: 0 }
				clear = (out_b.x - out_a.x).abs() >= need_x - 0.000000001
					or (out_b.y - out_a.y).abs() >= need_y - 0.000000001
				order = if overlap_x > 0 and overlap_y > 0 {
					if overlap_x <= overlap_y {
						if a.x <= b.x {
							out_a.x < out_b.x
						} else {
							out_b.x < out_a.x
						}
					} else {
						if a.y <= b.y {
							out_a.y < out_b.y
						} else {
							out_b.y < out_a.y
						}
					}
				} else {
					True
				}
				ok and clear and order
			},
		),
	)
	check
}

## The gap parameter is respected: boxes clear each other by the full gap.
expect Overlap.remove(
	[{ x: 0, y: 0 }, { x: 4, y: 0 }],
	[{ width: 10, height: 10 }, { width: 10, height: 10 }],
	3,
) == [{ x: 0 - 4.5, y: 0 }, { x: 8.5, y: 0 }]

## A negative, infinite, or NaN gap behaves as a gap of 0.
expect {
	positions = [{ x: 0, y: 0 }, { x: 4, y: 0 }]
	sizes = [{ width: 10, height: 10 }, { width: 10, height: 10 }]
	base = Overlap.remove(positions, sizes, 0)
	huge = 10000000000.0
	h2 = huge * huge
	h4 = h2 * h2
	h8 = h4 * h4
	h16 = h8 * h8
	inf = h16 * h16
	nan = inf - inf
	Overlap.remove(positions, sizes, 0 - 5) == base
		and Overlap.remove(positions, sizes, inf) == base
			and Overlap.remove(positions, sizes, nan) == base
}

## Empty input gives an empty result.
expect Overlap.remove([], [], 5) == []

## A position without a matching size is a zero-size point: strictly inside
## another box it still gets pushed clear, with spacing measured from its
## point extent.
expect Overlap.remove(
	[{ x: 0, y: 0 }, { x: 1, y: 0 }],
	[{ width: 10, height: 10 }],
	0,
) == [{ x: 0 - 2, y: 0 }, { x: 3, y: 0 }]

## fuzz regression: a dense coincident pileup beside a thin box — five
## zero-size points stacked at one spot, a sixth beside them, and a
## zero-width height-11 box, all needing a gap of 7 — must come back with
## every pair clear on at least one axis. The former bounded-rounds scheme
## exhausted its cap on this input and returned coincident points.
expect {
	positions = [
		{ x: 5, y: 0 - 1.0 },
		{ x: 0 - 19.0, y: 0 - 20.0 },
		{ x: 0 - 20.0, y: 0 - 20.0 },
		{ x: 0 - 20.0, y: 0 - 20.0 },
		{ x: 0 - 20.0, y: 0 - 20.0 },
		{ x: 0 - 20.0, y: 0 - 20.0 },
		{ x: 0 - 20.0, y: 0 - 20.0 },
	]
	sizes = [
		{ width: 0, height: 11 },
		{ width: 0, height: 0 },
		{ width: 0, height: 0 },
		{ width: 0, height: 0 },
		{ width: 0, height: 0 },
		{ width: 0, height: 0 },
		{ width: 0, height: 0 },
	]
	result = Overlap.remove(positions, sizes, 7)
	result.fold_with_index(
		True,
		|ok_outer, a, i| result.fold_with_index(
			ok_outer,
			|ok, b, j| if j <= i {
				ok
			} else {
				size_a = sizes.get(i) ?? { width: 0.0, height: 0.0 }
				size_b = sizes.get(j) ?? { width: 0.0, height: 0.0 }
				clear_x = (b.x - a.x).abs() >= (size_a.width + size_b.width) / 2 + 7 - 0.000000001
				clear_y = (b.y - a.y).abs() >= (size_a.height + size_b.height) / 2 + 7 - 0.000000001
				ok and (clear_x or clear_y)
			},
		),
	)
		and Overlap.remove(result, sizes, 7) == result
}
