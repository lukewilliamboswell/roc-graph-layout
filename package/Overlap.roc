## Placement-independent overlap removal.
Overlap :: {}.{
	## Identity scaffold for already-separated placements.
	##
	## TODO: Generate violated separation constraints with an axis sweep, then
	## use the constrained family's block-merge projection solver to find the
	## minimally displaced feasible coordinates. Preserve relative order, honor
	## pins, cap all iterative work, and test idempotence plus heterogeneous box
	## sizes. Until then callers must only use this stub on separated geometry.
	remove : List({ x : F64, y : F64 }) -> List({ x : F64, y : F64 })
	remove = |positions| positions
}

## Overlap scaffold preserves an already-separated placement exactly.
expect Overlap.remove([{ x: 1, y: 2 }, { x: 5, y: 8 }]) == [{ x: 1, y: 2 }, { x: 5, y: 8 }]
