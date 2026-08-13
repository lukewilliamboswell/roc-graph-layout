## Internal per-axis projection of separation constraints — the shared
## machinery behind overlap removal ("no overlaps, minimal movement, relative
## order preserved") and the constrained family's projection step.
##
## Given one scalar coordinate per variable (a single axis of a placement)
## and rules of the form `position[right] - position[left] >= gap`, `project`
## finds feasible positions minimizing the total weighted squared movement
## away from the desired ones.
##
## The method is incremental block merging: every variable starts as its own
## rigid block whose optimal position is its desired value. A violated
## constraint between two blocks fuses them into one rigid block whose
## members keep fixed internal offsets satisfying the merging constraint
## exactly; the block sits at the weighted average of its members' desired
## positions minus those offsets, which is precisely the position minimizing
## the members' weighted squared movement. Blocks are tracked with an
## explicit membership list — each variable stores its block's label (a
## representative variable index) and its offset inside that block — rather
## than a parent forest: a merge relabels and shifts the absorbed block's
## members in one linear scan, keeping every state list flat,
## index-addressed, and deterministic.
Solver :: {}.{

	## A separation rule between two variables addressed by index:
	## `position[right] - position[left] >= gap` must hold in the result.
	Constraint : { left : U64, right : U64, gap : F64 }

	## Flat solver state. Indexed by variable: `block_of[i]` names variable
	## `i`'s block by a representative variable index, `offset[i]` is `i`'s
	## fixed position inside that block, and `desired[i]` keeps the input
	## position so never-merged variables reproduce it bit-exactly. Indexed
	## by block label: `size` counts members, `weight_sum` totals member
	## weights, and `desired_sum` totals weighted `desired - offset`, so a
	## block's reference position is `desired_sum / weight_sum`.
	State : {
		block_of : List(U64),
		offset : List(F64),
		desired : List(F64),
		size : List(U64),
		weight_sum : List(F64),
		desired_sum : List(F64),
	}

	## Current position of variable `i`: its block's reference position plus
	## its own offset. A variable still alone in its block returns its
	## desired position exactly, with no division, so already-feasible input
	## passes through unchanged.
	position_of : State, U64 -> F64
	position_of = |state, i| {
		block = state.block_of.get(i) ?? 0
		if (state.size.get(block) ?? 1) == 1 {
			state.desired.get(i) ?? 0
		} else {
			weight = state.weight_sum.get(block) ?? 1
			reference = (state.desired_sum.get(block) ?? 0) / weight
			reference + (state.offset.get(i) ?? 0)
		}
	}

	## Fuse the two blocks joined by a violated constraint. The right side's
	## block is shifted so the constraint holds exactly
	## (`offset[right] - offset[left] == gap`), its members relabel to the
	## left side's block in one linear scan, and its weight and desired sums
	## fold into the survivor — the merged block's reference position is
	## then the weighted average minimizing its members' squared movement.
	merge_blocks : State, U64, U64, F64, List(Constraint) -> State
	merge_blocks = |state, left, right, gap, constraints| {
		keep = state.block_of.get(left) ?? 0
		gone = state.block_of.get(right) ?? 0
		# The shift must respect EVERY forward constraint crossing the two
		# blocks, not only the triggering one: in a clique of separations
		# over coincident points, satisfying just the trigger would land a
		# member short of a sibling constraint that then becomes intra-block
		# and unfixable. The max over crossing constraints places the merged
		# offsets so all of them hold (a larger shift only widens forward
		# separations).
		trigger_delta = (state.offset.get(left) ?? 0) + gap - (state.offset.get(right) ?? 0)
		count = state.block_of.len()
		delta = constraints.fold(
			trigger_delta,
			|best, k|
				if k.left >= count or k.right >= count {
					best
				} else if (state.block_of.get(k.left) ?? 0) == keep and (state.block_of.get(k.right) ?? 0) == gone {
					best.max((state.offset.get(k.left) ?? 0) + k.gap - (state.offset.get(k.right) ?? 0))
				} else {
					best
				},
		)
		gone_size = state.size.get(gone) ?? 0
		gone_weight = state.weight_sum.get(gone) ?? 0
		gone_desired = state.desired_sum.get(gone) ?? 0
		moved = state.block_of.fold_with_index(
			{ block_of: state.block_of, offset: state.offset },
			|acc, block, i| if block == gone {
				{
					block_of: acc.block_of.set(i, keep) ?? acc.block_of,
					offset: acc.offset.set(i, (acc.offset.get(i) ?? 0) + delta) ?? acc.offset,
				}
			} else {
				acc
			},
		)
		{
			block_of: moved.block_of,
			offset: moved.offset,
			desired: state.desired,
			size: state.size.set(keep, (state.size.get(keep) ?? 0) + gone_size) ?? state.size,
			weight_sum: state.weight_sum.set(keep, (state.weight_sum.get(keep) ?? 0) + gone_weight) ?? state.weight_sum,
			desired_sum: state.desired_sum.set(keep, (state.desired_sum.get(keep) ?? 0) + gone_desired - delta * gone_weight) ?? state.desired_sum,
		}
	}

	## One sweep over the ordered constraints, merging the blocks of every
	## violated constraint whose endpoints sit in different blocks. Skips
	## out-of-range indices, self-pairs, and same-block pairs (a block is
	## rigid; see `project` for what that implies), and reports whether any
	## merge happened so the caller can re-check to a fixed point.
	sweep : State, List(Constraint) -> { state : State, merged : Bool }
	sweep = |initial, constraints| {
		constraints.fold(
			{ state: initial, merged: False },
			|acc, c| {
				count = acc.state.block_of.len()
				if c.left >= count or c.right >= count or c.left == c.right {
					acc
				} else if (acc.state.block_of.get(c.left) ?? 0) == (acc.state.block_of.get(c.right) ?? 0) {
					acc
				} else {
					left_pos = Solver.position_of(acc.state, c.left)
					right_pos = Solver.position_of(acc.state, c.right)
					if right_pos - left_pos < c.gap {
						{ state: Solver.merge_blocks(acc.state, c.left, c.right, c.gap, constraints), merged: True }
					} else {
						acc
					}
				}
			},
		)
	}

	## Sweep repeatedly until a sweep merges nothing — a merge can newly
	## violate a constraint checked earlier, so one pass is not enough. The
	## countdown makes termination structural; every recursing sweep merged
	## at least once and merging reduces the block count, so at most one
	## sweep per variable ever recurses and the caller's cap is generous.
	solve : State, List(Constraint), U64 -> State
	solve = |state, constraints, rounds_left| {
		if rounds_left == 0 {
			state
		} else {
			swept = Solver.sweep(state, constraints)
			if swept.merged {
				Solver.solve(swept.state, constraints, rounds_left - 1)
			} else {
				swept.state
			}
		}
	}

	## Minimal weighted-squared-movement feasible positions: among position
	## lists satisfying every constraint, minimize
	## `sum(weight[i] * (result[i] - position[i])^2)` — each variable moves
	## as little as its weight allows, and variables no constraint forces
	## keep their desired positions bit-exactly. Weights must be > 0
	## (callers validate); out-of-range constraint indices and self-pairs
	## are skipped, keeping the function total.
	##
	## Constraints are processed in a deterministic order — by the left
	## variable's desired position, then left index, then right index, then
	## wider gap first — and re-checked after merges until a full pass
	## changes nothing, capped at `constraints * variables + 1` rounds so
	## termination is structural (block count actually bounds the merging
	## rounds by the variable count).
	##
	## Assumes the constraint graph is a DAG in left-to-right position order,
	## which is what an axis sweep over a placement generates; the result is
	## then the exact minimizer. Cyclic or redundant transitive inputs (a
	## direct gap wider than the chain it spans) still terminate under the
	## cap and return a best-effort result: every constraint whose endpoints
	## ended in different blocks holds, but a constraint between members of
	## an already-rigid block may remain violated, because blocks never
	## split.
	project : List({ position : F64, weight : F64 }), List(Constraint) -> List(F64)
	project = |variables, constraints| {
		count = variables.len()
		desired = variables.map(|v| v.position)
		constraint_order = |a, b| {
			a_key = desired.get(a.left) ?? 0
			b_key = desired.get(b.left) ?? 0
			if a_key < b_key {
				LT
			} else if a_key > b_key {
				GT
			} else if a.left < b.left {
				LT
			} else if a.left > b.left {
				GT
			} else if a.right < b.right {
				LT
			} else if a.right > b.right {
				GT
			} else if a.gap > b.gap {
				LT
			} else if a.gap < b.gap {
				GT
			} else {
				EQ
			}
		}
		already_ordered = constraints.fold_with_index(
			True,
			|ordered, constraint, index|
				ordered
					and if index == 0 {
						True
					} else {
						constraint_order(constraints.get(index - 1) ?? constraint, constraint) != GT
					},
		)
		ordered = if already_ordered {
			constraints
		} else {
			constraints.sort_with(constraint_order)
		}
		initial = {
			block_of: List.repeat(0, count).map_with_index(|_, i| i),
			offset: List.repeat(0.0, count),
			desired: desired,
			size: List.repeat(1, count),
			weight_sum: variables.map(|v| v.weight),
			desired_sum: variables.map(|v| v.position * v.weight),
		}
		cap = ordered.len() * count + 1
		final = Solver.solve(initial, ordered, cap)
		final.block_of.map_with_index(|_, i| Solver.position_of(final, i))
	}
}

## Already-feasible input passes through unchanged — no variable moves.
expect Solver.project(
	[{ position: 0, weight: 1 }, { position: 20, weight: 1 }],
	[{ left: 0, right: 1, gap: 10 }],
) == [0, 20]

## Two equal-weight variables both at 0 needing a gap of 10 split the
## movement equally: -5 and +5.
expect Solver.project(
	[{ position: 0, weight: 1 }, { position: 0, weight: 1 }],
	[{ left: 0, right: 1, gap: 10 }],
) == [0 - 5, 5]

## Unequal weights share movement inversely: weight 3 and weight 1, both at
## 0 with gap 8, minimize 3a^2 + b^2 under b - a = 8 at a = -2, b = 6 — the
## heavy variable moves 2, the light one 6, and the weighted average holds.
expect Solver.project(
	[{ position: 0, weight: 3 }, { position: 0, weight: 1 }],
	[{ left: 0, right: 1, gap: 8 }],
) == [0 - 2, 6]

## A chain of three at 0 with two gaps of 10 spreads symmetrically about
## the middle variable: -10, 0, +10.
expect Solver.project(
	[{ position: 0, weight: 1 }, { position: 0, weight: 1 }, { position: 0, weight: 1 }],
	[{ left: 0, right: 1, gap: 10 }, { left: 1, right: 2, gap: 10 }],
) == [0 - 10, 0, 10]

## A merge can newly violate an earlier constraint: with desired 0, 100, 1,
## constraint (0,1) starts satisfied, but merging 1 with 2 pulls 1 down to
## (100 + 1 - 10) / 2 = 45.5. Both constraints hold in the optimum
## 0, 45.5, 55.5 — and (0,1) survives because 45.5 - 0 >= 10.
expect Solver.project(
	[{ position: 0, weight: 1 }, { position: 100, weight: 1 }, { position: 1, weight: 1 }],
	[{ left: 0, right: 1, gap: 10 }, { left: 1, right: 2, gap: 10 }],
) == [0, 45.5, 55.5]

## Order preservation property: after projection every constraint holds,
## so each left variable sits strictly below its right one.
expect {
	constraints = [
		{ left: 0, right: 1, gap: 2 },
		{ left: 1, right: 2, gap: 2 },
		{ left: 0, right: 3, gap: 1 },
	]
	result = Solver.project(
		[
			{ position: 5, weight: 1 },
			{ position: 3, weight: 2 },
			{ position: 4, weight: 1 },
			{ position: 3.5, weight: 1 },
		],
		constraints,
	)
	constraints.fold(
		True,
		|ok, c| {
			left_pos = result.get(c.left) ?? 0
			right_pos = result.get(c.right) ?? 0
			ok and right_pos - left_pos >= c.gap and left_pos < right_pos
		},
	)
}

## Determinism: identical input produces identical output, bit for bit.
expect {
	variables = [{ position: 9, weight: 2 }, { position: 1, weight: 1 }, { position: 4, weight: 3 }]
	constraints = [{ left: 0, right: 1, gap: 3 }, { left: 1, right: 2, gap: 3 }]
	Solver.project(variables, constraints) == Solver.project(variables, constraints)
}

## Constraints already in canonical order take the fast path, while the same
## constraints in another order are sorted and produce the identical result.
expect {
	variables = [{ position: 0, weight: 1 }, { position: 0, weight: 1 }, { position: 0, weight: 1 }]
	ordered = [
		{ left: 0, right: 1, gap: 4 },
		{ left: 0, right: 2, gap: 8 },
		{ left: 1, right: 2, gap: 4 },
	]
	shuffled = [ordered.get(2)?, ordered.get(0)?, ordered.get(1)?]
	Solver.project(variables, ordered) == Solver.project(variables, shuffled)
}

## Empty variables are defined: constraints referencing nothing are skipped
## and the result is empty.
expect Solver.project([], [{ left: 0, right: 1, gap: 5 }]) == []

## Empty constraints move nothing.
expect Solver.project([{ position: 7, weight: 2 }], []) == [7]

## Out-of-range constraint indices are skipped defensively, leaving valid
## variables untouched.
expect Solver.project(
	[{ position: 1, weight: 1 }, { position: 2, weight: 1 }],
	[{ left: 0, right: 9, gap: 4 }],
) == [1, 2]
