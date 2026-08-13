import Geom

## Internal Barnes-Hut far-field aggregation for force layouts.
##
## Pairwise repulsion is O(n^2) per iteration. A region quadtree over the
## point positions lets distant clusters act as single point masses, with an
## opening-angle parameter bounding the approximation error, restoring
## O((n + m) log n) per iteration.
##
## The tree is a flat, index-addressed structure (the package's performance
## model for hot data): cells live in one list and refer to each other by
## index, never by reference. `U64.highest` is the sentinel index meaning
## "no cell" / "no point" — chosen over an optional tag so a cell stays one
## flat record of scalars plus a fixed four-entry child list.
##
## Invariants, maintained by `build` and relied on by `repulsion_at`:
##
## - Cell 0 is the root; its square covers every inserted point.
## - A cell's `children` list always has exactly four entries, indexed by
##   quadrant (0 = north-west, 1 = north-east, 2 = south-west,
##   3 = south-east). Either all four are real indices (an internal cell)
##   or all four are the sentinel (a leaf).
## - `mass` is the number of points inside the cell's square and
##   `(com_x, com_y)` is their center of mass — exact for a mass-1 leaf,
##   the running mean otherwise.
## - Points are inserted in caller index order, and every structural choice
##   (quadrant selection, child creation order) is a pure function of the
##   input, so identical input builds an identical tree, bit for bit.
## - Splitting stops at a hard depth cap: points that would split deeper
##   (coincident or nearly so) accumulate in one leaf as aggregated mass,
##   so insertion always terminates.
Quadtree :: {}.{

	## Sentinel index meaning "no child cell" or "no resident point".
	no_index : U64
	no_index = U64.highest

	## Hard bound on tree depth. Two points only fail to separate above
	## this depth when they are within 2^-47 of the bounding side apart —
	## effectively coincident — and then they share one aggregated leaf
	## instead of splitting forever.
	depth_cap : U64
	depth_cap = 48

	## One quadtree cell over the square centered at `(center_x, center_y)`
	## with half side length `half`. `mass` counts contained points (as F64,
	## since it scales force contributions), `(com_x, com_y)` is their
	## center of mass, `children` holds the four quadrant cell indices (all
	## sentinel for a leaf), and `point` is the first resident point's input
	## index (sentinel for internal and empty cells).
	Cell : {
		center_x : F64,
		center_y : F64,
		half : F64,
		mass : F64,
		com_x : F64,
		com_y : F64,
		children : List(U64),
		point : U64,
	}

	## A built quadtree: the flat cell store. Empty input builds an empty
	## cell list; otherwise cell 0 is the root.
	Tree : { cells : List(Cell) }

	## A cell containing no points, covering the given square.
	empty_cell : F64, F64, F64 -> Cell
	empty_cell = |cx, cy, half| {
		center_x: cx,
		center_y: cy,
		half,
		mass: 0,
		com_x: 0,
		com_y: 0,
		children: List.repeat(Quadtree.no_index, 4),
		point: Quadtree.no_index,
	}

	## Which quadrant of `cell` the point falls in. Boundary points (exactly
	## on a center line) go east/south — a fixed, deterministic convention.
	quadrant_of : Cell, F64, F64 -> U64
	quadrant_of = |cell, x, y| {
		qx = if x >= cell.center_x {
			1
		} else {
			0
		}
		qy = if y >= cell.center_y {
			2
		} else {
			0
		}
		qx + qy
	}

	## The empty child cell for quadrant `q` of `cell`: half the side,
	## centered in that quarter of the parent square.
	child_cell : Cell, U64 -> Cell
	child_cell = |cell, q| {
		h = cell.half / 2
		cx = if q == 1 or q == 3 {
			cell.center_x + h
		} else {
			cell.center_x - h
		}
		cy = if q >= 2 {
			cell.center_y + h
		} else {
			cell.center_y - h
		}
		Quadtree.empty_cell(cx, cy, h)
	}

	## Fold one more point into a cell's aggregate mass and center of mass.
	absorb : Cell, F64, F64 -> Cell
	absorb = |cell, x, y| {
		new_mass = cell.mass + 1
		{
			..cell,
			mass: new_mass,
			com_x: (cell.com_x * cell.mass + x) / new_mass,
			com_y: (cell.com_y * cell.mass + y) / new_mass,
		}
	}

	## Insert point `point_idx` at `(x, y)` into the cell at `cell_idx`.
	##
	## Recursion is bounded: every self-call either descends one level
	## (depth + 1) or immediately follows a leaf split at the same depth,
	## and depth never exceeds `depth_cap`, where occupied leaves absorb
	## further points instead of splitting.
	insert_at : List(Cell), U64, U64, F64, F64, U64 -> List(Cell)
	insert_at = |cells, cell_idx, point_idx, x, y, depth| {
		# Every update index is established from this store or from the four
		# children just appended to it. The empty fallbacks are unreachable;
		# unlike `?? cells`, they do not retain an alias to the growing store
		# and force `List.set` to copy it on every recursive update.
		cell = cells.get(cell_idx) ?? Quadtree.empty_cell(0, 0, 0)
		first_child = cell.children.get(0) ?? Quadtree.no_index
		if cell.mass == 0 {
			# Empty leaf: the point takes up residence.
			claimed = { ..cell, mass: 1, com_x: x, com_y: y, point: point_idx }
			cells.set(cell_idx, claimed) ?? []
		} else if first_child != Quadtree.no_index {
			# Internal cell: fold the point into the aggregate, descend.
			q = Quadtree.quadrant_of(cell, x, y)
			child_idx = cell.children.get(q) ?? Quadtree.no_index
			updated = cells.set(cell_idx, Quadtree.absorb(cell, x, y)) ?? []
			Quadtree.insert_at(updated, child_idx, point_idx, x, y, depth + 1)
		} else if depth >= Quadtree.depth_cap {
			# Occupied leaf at the depth cap: coincident or near-coincident
			# points aggregate here rather than splitting forever.
			cells.set(cell_idx, Quadtree.absorb(cell, x, y)) ?? []
		} else {
			# Occupied leaf below the cap: split into four children, move
			# the resident point down (a mass-1 leaf's com is that point,
			# exactly), then re-insert the new point into this cell, which
			# is now internal.
			base = cells.len()
			with_children =
				cells
					.append(Quadtree.child_cell(cell, 0))
					.append(Quadtree.child_cell(cell, 1))
					.append(Quadtree.child_cell(cell, 2))
					.append(Quadtree.child_cell(cell, 3))
			child_indices = [base, base + 1, base + 2, base + 3]
			as_internal = { ..cell, children: child_indices, point: Quadtree.no_index }
			old_q = Quadtree.quadrant_of(cell, cell.com_x, cell.com_y)
			old_child_idx = base + old_q
			resident = {
				..Quadtree.child_cell(cell, old_q),
				mass: 1,
				com_x: cell.com_x,
				com_y: cell.com_y,
				point: cell.point,
			}
			split =
				(with_children.set(cell_idx, as_internal) ?? [])
					.set(old_child_idx, resident)
					?? []
			Quadtree.insert_at(split, cell_idx, point_idx, x, y, depth)
		}
	}

	## Build a quadtree over the points, inserted in list order (part of
	## the determinism contract). The root square is the bounding square of
	## the points' extent; a zero-extent input (all points coincident, or a
	## single point) is padded to side length 1 so quadrants are well
	## defined. Empty input builds an empty tree.
	build : List({ x : F64, y : F64 }) -> Tree
	build = |points| {
		if points.is_empty() {
			{ cells: [] }
		} else {
			first = points.get(0) ?? { x: 0, y: 0 }
			seed = { min_x: first.x, max_x: first.x, min_y: first.y, max_y: first.y }
			bounds = points.fold(
				seed,
				|acc, p| {
					min_x: acc.min_x.min(p.x),
					max_x: acc.max_x.max(p.x),
					min_y: acc.min_y.min(p.y),
					max_y: acc.max_y.max(p.y),
				},
			)
			extent = (bounds.max_x - bounds.min_x).max(bounds.max_y - bounds.min_y)
			side = if extent > 0 {
				extent
			} else {
				1
			}
			root = Quadtree.empty_cell(
				(bounds.min_x + bounds.max_x) / 2,
				(bounds.min_y + bounds.max_y) / 2,
				side / 2,
			)
			cells = points.fold_with_index(
				[root],
				|acc, p, i| Quadtree.insert_at(acc, 0, i, p.x, p.y, 0),
			)
			{ cells }
		}
	}

	## The repulsion the subtree at `cell_idx` exerts on `query`: the sum
	## over contained points p of (query - p) / |query - p|^2, approximated
	## by Barnes-Hut. A cell whose side-to-distance ratio is below `theta`
	## acts as one point mass at its center of mass; otherwise its children
	## are visited. Exactly-coincident contributions (distance 0) are
	## skipped — the caller adds seeded jitter — so the result is always
	## finite. Recursion is bounded by the tree depth, itself bounded by
	## `depth_cap`.
	force_from : List(Cell), U64, { x : F64, y : F64 }, F64 -> { x : F64, y : F64 }
	force_from = |cells, cell_idx, query, theta| {
		cell = cells.get(cell_idx) ?? Quadtree.empty_cell(0, 0, 0)
		if cell.mass == 0 {
			{ x: 0, y: 0 }
		} else {
			dx = query.x - cell.com_x
			dy = query.y - cell.com_y
			dist = Geom.hypot(dx, dy)
			first_child = cell.children.get(0) ?? Quadtree.no_index
			is_leaf = first_child == Quadtree.no_index
			# Opening test: side / dist < theta. A cell at distance 0 can
			# never be approximated (and a coincident leaf is skipped).
			if is_leaf or (dist > 0 and cell.half * 2 < theta * dist) {
				if dist == 0 {
					{ x: 0, y: 0 }
				} else {
					scale = cell.mass / (dist * dist)
					{ x: dx * scale, y: dy * scale }
				}
			} else {
				cell.children.fold(
					{ x: 0, y: 0 },
					|acc, child_idx| {
						f = Quadtree.force_from(cells, child_idx, query, theta)
						{ x: acc.x + f.x, y: acc.y + f.y }
					},
				)
			}
		}
	}

	## Approximate the total inverse-distance repulsion of every inserted
	## point on `query` (pointing away from the points), with opening angle
	## `theta`. Theta 0 never approximates — every leaf is visited, giving
	## the exact pairwise sum. Larger theta trades accuracy for speed;
	## values near 1 are typical for force layouts. A query coinciding with
	## an inserted point skips that point's (and its exactly-coincident
	## cellmates') contribution.
	repulsion_at : Tree, { x : F64, y : F64 }, F64 -> { x : F64, y : F64 }
	repulsion_at = |tree, query, theta| {
		if tree.cells.is_empty() {
			{ x: 0, y: 0 }
		} else {
			Quadtree.force_from(tree.cells, 0, query, theta)
		}
	}
}

## Brute-force reference used by the expects below: the exact pairwise sum
## of (query - p) / |query - p|^2, skipping coincident points.
brute_repulsion : List({ x : F64, y : F64 }), { x : F64, y : F64 } -> { x : F64, y : F64 }
brute_repulsion = |points, query|
	points.fold(
		{ x: 0, y: 0 },
		|acc, p| {
			dx = query.x - p.x
			dy = query.y - p.y
			d = Geom.hypot(dx, dy)
			if d == 0 {
				acc
			} else {
				{ x: acc.x + dx / (d * d), y: acc.y + dy / (d * d) }
			}
		},
	)

six_irregular_points : List({ x : F64, y : F64 })
six_irregular_points = [
	{ x: 0.0, y: 0.0 },
	{ x: 3.5, y: 1.25 },
	{ x: 0 - 2.0, y: 4.75 },
	{ x: 1.5, y: 0 - 3.0 },
	{ x: 6.25, y: 5.5 },
	{ x: 0 - 4.5, y: 0 - 1.5 },
]

## Exactness: with theta 0 the walk never approximates, so the tree result
## matches the brute-force pairwise sum at every input point to within
## summation-order rounding.
expect {
	tree = Quadtree.build(six_irregular_points)
	six_irregular_points.fold(
		True,
		|ok, q| {
			approx = Quadtree.repulsion_at(tree, q, 0)
			exact = brute_repulsion(six_irregular_points, q)
			ok and (approx.x - exact.x).abs() < 1e-9 and (approx.y - exact.y).abs() < 1e-9
		},
	)
}

## Symmetry: with two points, the force at each is equal in magnitude and
## opposite in direction.
expect {
	points = [{ x: 0.0, y: 0.0 }, { x: 2.0, y: 1.0 }]
	tree = Quadtree.build(points)
	f0 = Quadtree.repulsion_at(tree, { x: 0.0, y: 0.0 }, 0.5)
	f1 = Quadtree.repulsion_at(tree, { x: 2.0, y: 1.0 }, 0.5)
	(f0.x + f1.x).abs() < 1e-12 and (f0.y + f1.y).abs() < 1e-12 and (Geom.hypot(f0.x, f0.y) - Geom.hypot(f1.x, f1.y)).abs() < 1e-12
}

## Coincident points: two identical points build a finite tree (the depth
## cap stops the split) and querying at their shared position skips the
## self-contribution, returning a finite zero force. A query elsewhere sees
## their aggregated mass and stays finite too.
expect {
	tree = Quadtree.build([{ x: 1.0, y: 1.0 }, { x: 1.0, y: 1.0 }])
	at_self = Quadtree.repulsion_at(tree, { x: 1.0, y: 1.0 }, 0.9)
	away = Quadtree.repulsion_at(tree, { x: 3.0, y: 1.0 }, 0.9)
	at_self == { x: 0, y: 0 }
		and F64.is_finite(away.x)
			and F64.is_finite(away.y)
				and (away.x - 1.0).abs() < 1e-12
					and away.y.abs() < 1e-12
}

## Approximation sanity: on two well-separated clusters, theta 0.9 stays
## within 15% relative error of the brute-force sum.
expect {
	points = [
		{ x: 0.0, y: 0.0 },
		{ x: 1.0, y: 0.2 },
		{ x: 0.3, y: 1.1 },
		{ x: 1.2, y: 1.4 },
		{ x: 0.6, y: 0.5 },
		{ x: 1.6, y: 0.9 },
		{ x: 60.0, y: 58.0 },
		{ x: 61.2, y: 58.5 },
		{ x: 60.4, y: 59.3 },
		{ x: 61.5, y: 60.1 },
		{ x: 60.9, y: 58.9 },
		{ x: 59.8, y: 59.7 },
	]
	tree = Quadtree.build(points)
	q = { x: 0.0, y: 0.0 }
	approx = Quadtree.repulsion_at(tree, q, 0.9)
	exact = brute_repulsion(points, q)
	err = Geom.hypot(approx.x - exact.x, approx.y - exact.y)
	err < 0.15 * Geom.hypot(exact.x, exact.y)
}

## Determinism: building twice from the same input yields identical flat
## cell stores, bit for bit.
expect {
	a = Quadtree.build(six_irregular_points)
	b = Quadtree.build(six_irregular_points)
	a.cells == b.cells
}

## Empty and single-point trees exert no force: nothing to repel, and a
## lone point's self-contribution is skipped.
expect Quadtree.repulsion_at(Quadtree.build([]), { x: 1.0, y: 2.0 }, 0.5) == { x: 0, y: 0 }
expect Quadtree.repulsion_at(Quadtree.build([{ x: 5.0, y: 5.0 }]), { x: 5.0, y: 5.0 }, 0.5) == { x: 0, y: 0 }

## A single-point tree still repels a distinct query point with the exact
## inverse-distance kernel: unit distance gives a unit push away.
expect {
	tree = Quadtree.build([{ x: 5.0, y: 5.0 }])
	f = Quadtree.repulsion_at(tree, { x: 6.0, y: 5.0 }, 0.5)
	(f.x - 1.0).abs() < 1e-12 and f.y.abs() < 1e-12
}
