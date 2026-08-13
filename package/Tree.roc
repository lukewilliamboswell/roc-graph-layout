import Geom
import Trig

## Bottom-up placement result for one subtree, in a local frame where this
## subtree's own root sits at spread-axis offset 0. `contour_left`/
## `contour_right` give, for each depth below this root (index 0 = this
## root's own row, index 1 = its children's row, ...), the extreme
## spread-axis edge reached at that depth — the machinery `layout_subtree`
## merges siblings against.
Placed := {
	width : F64,
	height : F64,
	contour_left : List(F64),
	contour_right : List(F64),
	children : List({ offset : F64, placed : Placed }),
}

## Pure helpers behind `Tree.Tidy`: depth-first validation, bottom-up
## contour-merge placement, and the downward pass that turns local offsets
## into absolute, direction-mapped positions.
TreeInternals :: {}.{

	## The axis that varies within one level: width for a top-to-bottom or
	## bottom-to-top tree, height for a left-to-right or right-to-left one.
	spread_extent : [Down, Up, Left, Right], F64, F64 -> F64
	spread_extent = |direction, width, height|
		match direction {
			Down => width
			Up => width
			Left => height
			Right => height
		}

	## The axis a tree grows along: height for Down/Up, width for Left/Right.
	level_extent : [Down, Up, Left, Right], F64, F64 -> F64
	level_extent = |direction, width, height|
		match direction {
			Down => height
			Up => height
			Left => width
			Right => width
		}

	extend_dims : List({ width : F64, height : F64 }), U64, F64, F64 -> List({ width : F64, height : F64 })
	extend_dims = |list, depth, w, h|
		if depth < list.len() {
			cur = list.get(depth) ?? { width: 0, height: 0 }
			nw = if w > cur.width {
				w
			} else {
				cur.width
			}
			nh = if h > cur.height {
				h
			} else {
				cur.height
			}
			list.set(depth, { width: nw, height: nh }) ?? list
		} else {
			list.append({ width: w, height: h })
		}

	## Depth-first (pre-order) validation and per-depth extent scan in one
	## pass. `own_index` is this node's index in that same order, the index
	## every other output list aligns to.
	analyze_node : Tree.Spec,
	U64,
	{ next_index : U64, problems : List(Tree.Problem), depth_extents : List({ width : F64, height : F64 }) } -> {
		next_index : U64,
		problems : List(Tree.Problem),
		depth_extents : List({ width : F64, height : F64 }),
		own_index : U64,
	}
	analyze_node = |spec, depth, acc| {
		own_index = acc.next_index
		w_ok = F64.is_finite(spec.width) and spec.width >= 0
		h_ok = F64.is_finite(spec.height) and spec.height >= 0
		p1 = if w_ok {
			acc.problems
		} else {
			acc.problems.append(InvalidWidth(own_index))
		}
		p2 = if h_ok {
			p1
		} else {
			p1.append(InvalidHeight(own_index))
		}
		de = TreeInternals.extend_dims(acc.depth_extents, depth, spec.width, spec.height)
		started = { next_index: own_index + 1, problems: p2, depth_extents: de }

		finished = spec.children.fold(
			started,
			|state, child| {
				result = TreeInternals.analyze_node(child, depth + 1, state)
				{ next_index: result.next_index, problems: result.problems, depth_extents: result.depth_extents }
			},
		)

		{ next_index: finished.next_index, problems: finished.problems, depth_extents: finished.depth_extents, own_index }
	}

	validate_settings : Tree.Settings -> List(Tree.Problem)
	validate_settings = |settings| {
		p1 = if F64.is_finite(settings.sibling_gap) and settings.sibling_gap >= 0 {
			[]
		} else {
			[InvalidSiblingGap]
		}
		p2 = if F64.is_finite(settings.subtree_gap) and settings.subtree_gap >= 0 {
			p1
		} else {
			p1.append(InvalidSubtreeGap)
		}
		if F64.is_finite(settings.level_gap) and settings.level_gap >= 0 {
			p2
		} else {
			p2.append(InvalidLevelGap)
		}
	}

	extend_max : List(F64), U64, F64 -> List(F64)
	extend_max = |list, index, value|
		if index < list.len() {
			cur = list.get(index) ?? value
			if value > cur {
				list.set(index, value) ?? list
			} else {
				list
			}
		} else {
			list.append(value)
		}

	extend_min : List(F64), U64, F64 -> List(F64)
	extend_min = |list, index, value|
		if index < list.len() {
			cur = list.get(index) ?? value
			if value < cur {
				list.set(index, value) ?? list
			} else {
				list
			}
		} else {
			list.append(value)
		}

	## Siblings (the two subtree roots themselves, relative depth 0) keep
	## `sibling_gap`; deeper, non-sibling descendants keep `subtree_gap`.
	gap_for : F64, F64, U64 -> F64
	gap_for = |sibling_gap, subtree_gap, relative_depth| if relative_depth == 0 {
		sibling_gap
	} else {
		subtree_gap
	}

	## The smallest offset that keeps a new child's contour clear of every
	## previously placed child's contour, at every depth the two overlap.
	candidate_offset : List(F64), List(F64), F64, F64 -> F64
	candidate_offset = |accumulated_right, child_contour_left, sibling_gap, subtree_gap|
		child_contour_left.fold_with_index(
			0,
			|acc, left_edge, rel_depth| {
				right_edge = accumulated_right.get(rel_depth) ?? (0 - 1.0e15)
				needed = right_edge + TreeInternals.gap_for(sibling_gap, subtree_gap, rel_depth) - left_edge
				if needed > acc {
					needed
				} else {
					acc
				}
			},
		)

	## Bottom-up tidy placement: lay out each child independently, merge
	## them left to right by contour (deferring the shift into each child's
	## small offset rather than moving its whole subtree), center this node
	## over the merged span, then re-anchor everything to local offset 0.
	layout_subtree : Tree.Spec, [Down, Up, Left, Right], F64, F64 -> Placed
	layout_subtree = |spec, direction, sibling_gap, subtree_gap| {
		half = TreeInternals.spread_extent(direction, spec.width, spec.height) / 2

		placed_children = spec.children.map(|child| TreeInternals.layout_subtree(child, direction, sibling_gap, subtree_gap))

		merged = placed_children.fold(
			{ placed_offsets: [], accumulated_right: [] },
			|state, child| {
				offset = if state.placed_offsets.is_empty() {
					0
				} else {
					TreeInternals.candidate_offset(state.accumulated_right, child.contour_left, sibling_gap, subtree_gap)
				}

				new_accumulated = child.contour_right.fold_with_index(
					state.accumulated_right,
					|acc, right_edge, rel_depth| TreeInternals.extend_max(acc, rel_depth, offset + right_edge),
				)

				{
					placed_offsets: state.placed_offsets.append({ offset, placed: child }),
					accumulated_right: new_accumulated,
				}
			},
		)

		accumulated_left = merged.placed_offsets.fold(
			[],
			|acc, entry|
				entry.placed.contour_left.fold_with_index(
					acc,
					|inner, left_edge, rel_depth| TreeInternals.extend_min(inner, rel_depth, entry.offset + left_edge),
				),
		)

		center = if accumulated_left.is_empty() {
			0
		} else {
			l = accumulated_left.get(0) ?? 0
			r = merged.accumulated_right.get(0) ?? 0
			(l + r) / 2
		}

		shifted_children = merged.placed_offsets.map(|entry| { offset: entry.offset - center, placed: entry.placed })

		contour_left = [0 - half].concat(accumulated_left.map(|v| v - center))
		contour_right = [half].concat(merged.accumulated_right.map(|v| v - center))

		{ width: spec.width, height: spec.height, contour_left, contour_right, children: shifted_children }
	}

	## Cumulative level-axis start per depth: depth 0 starts at 0, each next
	## depth starts after the previous depth's tallest node plus `level_gap`.
	level_starts : List({ width : F64, height : F64 }), [Down, Up, Left, Right], F64 -> List(F64)
	level_starts = |depth_extents, direction, level_gap|
		depth_extents.fold(
			{ starts: [], cursor: 0 },
			|state, entry| {
				extent = TreeInternals.level_extent(direction, entry.width, entry.height)
				{ starts: state.starts.append(state.cursor), cursor: state.cursor + extent + level_gap }
			},
		).starts

	## The far edge of the last depth along the level axis — the tree's
	## total extent in that direction, with no trailing gap.
	level_total : List({ width : F64, height : F64 }), [Down, Up, Left, Right], F64 -> F64
	level_total = |depth_extents, direction, level_gap|
		if depth_extents.is_empty() {
			0
		} else {
			starts = TreeInternals.level_starts(depth_extents, direction, level_gap)
			last_index = depth_extents.len() - 1
			start = starts.get(last_index) ?? 0
			entry = depth_extents.get(last_index) ?? { width: 0, height: 0 }
			start + TreeInternals.level_extent(direction, entry.width, entry.height)
		}

	spread_bounds : Placed -> { min : F64, max : F64 }
	spread_bounds = |placed| {
		seed_l = placed.contour_left.get(0) ?? 0
		seed_r = placed.contour_right.get(0) ?? 0
		min_v = placed.contour_left.fold(
			seed_l,
			|acc, v| if v < acc {
				v
			} else {
				acc
			},
		)
		max_v = placed.contour_right.fold(
			seed_r,
			|acc, v| if v > acc {
				v
			} else {
				acc
			},
		)
		{ min: min_v, max: max_v }
	}

	## Maps a (spread, level) pair to (x, y) for the configured direction,
	## keeping every axis within `[0, extent]` — `Up`/`Left` mirror the
	## level axis rather than producing negative coordinates.
	to_xy : [Down, Up, Left, Right], F64, F64, F64 -> { x : F64, y : F64 }
	to_xy = |direction, spread, level, total_level|
		match direction {
			Down => { x: spread, y: level }
			Up => { x: spread, y: total_level - level }
			Right => { x: level, y: spread }
			Left => { x: total_level - level, y: spread }
		}

	## Downward pass: turns each child's small relative offset into an
	## absolute position, in the same depth-first order `analyze_node` used,
	## and emits one `Line` route per non-root node from its parent, with
	## both endpoints clipped to the node boxes they attach to.
	flatten_node : Placed,
	U64,
	F64,
	{ x : F64, y : F64 },
	List(F64),
	F64,
	[Down, Up, Left, Right],
	{
		positions : List({ x : F64, y : F64 }),
		depths : List(U64),
		routes : List(Geom.Route),
	} -> {
		positions : List({ x : F64, y : F64 }),
		depths : List(U64),
		routes : List(Geom.Route),
	}
	flatten_node = |placed, depth, abs_spread, own_point, lvl_starts, lvl_total, direction, acc0|
		placed.children.fold(
			acc0,
			|acc, entry| {
				child_abs = abs_spread + entry.offset
				child_level_start = lvl_starts.get(depth + 1) ?? 0
				child_level_c = child_level_start + TreeInternals.level_extent(direction, entry.placed.width, entry.placed.height) / 2
				child_point = TreeInternals.to_xy(direction, child_abs, child_level_c, lvl_total)
				route = Line(
					Geom.clip_to_node(own_point, { width: placed.width, height: placed.height }, child_point),
					Geom.clip_to_node(child_point, { width: entry.placed.width, height: entry.placed.height }, own_point),
				)
				with_child = {
					positions: acc.positions.append(child_point),
					depths: acc.depths.append(depth + 1),
					routes: acc.routes.append(route),
				}
				TreeInternals.flatten_node(entry.placed, depth + 1, child_abs, child_point, lvl_starts, lvl_total, direction, with_child)
			},
		)

	validate_radial_settings : Tree.RadialSettings -> List(Tree.Problem)
	validate_radial_settings = |settings| {
		p1 = if F64.is_finite(settings.sibling_gap) and settings.sibling_gap >= 0 {
			[]
		} else {
			[InvalidSiblingGap]
		}
		p2 = if F64.is_finite(settings.subtree_gap) and settings.subtree_gap >= 0 {
			p1
		} else {
			p1.append(InvalidSubtreeGap)
		}
		p3 = if F64.is_finite(settings.ring_gap) and settings.ring_gap >= 0 {
			p2
		} else {
			p2.append(InvalidRingGap)
		}
		if F64.is_finite(settings.start_angle) {
			p3
		} else {
			p3.append(InvalidStartAngle)
		}
	}

	## Center-line radius per depth: the root's ring is radius 0, and each
	## deeper ring clears the previous depth by both rings' half extents
	## plus `ring_gap`. A ring's extent is its largest node diagonal — a
	## box's footprint along the radial direction depends on where it sits
	## on the ring, and the diagonal bounds it at every angle, so
	## consecutive rings never overlap however wide or flat their nodes are.
	ring_radii : List({ width : F64, height : F64 }), F64 -> List(F64)
	ring_radii = |depth_extents, ring_gap| {
		extents = depth_extents.map(|entry| Geom.hypot(entry.width, entry.height))
		starts = extents.fold(
			{ starts: [], cursor: 0.0 },
			|state, extent| { starts: state.starts.append(state.cursor), cursor: state.cursor + extent + ring_gap },
		).starts
		center_0 = (extents.get(0) ?? 0) / 2
		extents.map_with_index(
			|extent, depth| (starts.get(depth) ?? 0) + extent / 2 - center_0,
		)
	}

	## Maps a spread-axis coordinate to a point on the depth's ring. The
	## whole spread span plus one closing `subtree_gap` covers one full turn,
	## so the first and last subtrees keep the same clearance as neighbors.
	radial_point : F64, F64, F64, F64, F64 -> { x : F64, y : F64 }
	radial_point = |spread, spread_wrap, radius, start_angle, dir_sign| {
		angle = start_angle + dir_sign * Trig.tau * (spread / spread_wrap)
		{ x: radius * Trig.cos(angle), y: radius * Trig.sin(angle) }
	}

	## Downward pass for the radial projection: turns each child's relative
	## spread offset into a point on its depth's ring, in the same
	## depth-first order `analyze_node` used, emitting one `Line` route per
	## non-root node (endpoints clipped to the node boxes they attach to)
	## and accumulating the tight box over node extents.
	flatten_radial : Placed,
	U64,
	F64,
	{ x : F64, y : F64 },
	List(F64),
	{ spread_wrap : F64, start_angle : F64, dir_sign : F64 },
	{
		positions : List({ x : F64, y : F64 }),
		depths : List(U64),
		routes : List(Geom.Route),
		min_x : F64,
		min_y : F64,
		max_x : F64,
		max_y : F64,
	} -> {
		positions : List({ x : F64, y : F64 }),
		depths : List(U64),
		routes : List(Geom.Route),
		min_x : F64,
		min_y : F64,
		max_x : F64,
		max_y : F64,
	}
	flatten_radial = |placed, depth, abs_spread, own_point, radii, projection, acc0|
		placed.children.fold(
			acc0,
			|acc, entry| {
				child_abs = abs_spread + entry.offset
				radius = radii.get(depth + 1) ?? 0
				child_point = TreeInternals.radial_point(child_abs, projection.spread_wrap, radius, projection.start_angle, projection.dir_sign)
				half_w = entry.placed.width / 2
				half_h = entry.placed.height / 2
				route = Line(
					Geom.clip_to_node(own_point, { width: placed.width, height: placed.height }, child_point),
					Geom.clip_to_node(child_point, { width: entry.placed.width, height: entry.placed.height }, own_point),
				)
				with_child = {
					positions: acc.positions.append(child_point),
					depths: acc.depths.append(depth + 1),
					routes: acc.routes.append(route),
					min_x: acc.min_x.min(child_point.x - half_w),
					min_y: acc.min_y.min(child_point.y - half_h),
					max_x: acc.max_x.max(child_point.x + half_w),
					max_y: acc.max_y.max(child_point.y + half_h),
				}
				TreeInternals.flatten_radial(entry.placed, depth + 1, child_abs, child_point, radii, projection, with_child)
			},
		)

	## Combines a computed placement with the per-depth extents into the
	## radial reading of the family's public `Result`: the root at the
	## center, each depth on its own ring, normalized to origin bounds.
	assemble_radial : Placed, List({ width : F64, height : F64 }), Tree.RadialSettings -> Tree.Result
	assemble_radial = |root_placed, depth_extents, settings| {
		radii = TreeInternals.ring_radii(depth_extents, settings.ring_gap)
		bounds = TreeInternals.spread_bounds(root_placed)
		span = bounds.max - bounds.min
		wrap = span + settings.subtree_gap
		spread_wrap = if wrap > 0 {
			wrap
		} else {
			1
		}
		dir_sign = match settings.winding {
			Clockwise => 1.0
			CounterClockwise => 0 - 1.0
		}
		projection = { spread_wrap, start_angle: settings.start_angle, dir_sign }

		root_point = { x: 0, y: 0 }
		seeded = {
			positions: [root_point],
			depths: [0],
			routes: [],
			min_x: 0 - root_placed.width / 2,
			min_y: 0 - root_placed.height / 2,
			max_x: root_placed.width / 2,
			max_y: root_placed.height / 2,
		}
		flat = TreeInternals.flatten_radial(root_placed, 0, 0 - bounds.min, root_point, radii, projection, seeded)

		dx = 0 - flat.min_x
		dy = 0 - flat.min_y
		shift = |p| { x: p.x + dx, y: p.y + dy }

		{
			layout: {
				positions: flat.positions.map(shift),
				bounds: { ..Geom.empty_bounds, width: flat.max_x - flat.min_x, height: flat.max_y - flat.min_y },
				routes: flat.routes.map(
					|route| match route {
						Line(from, to) => Line(shift(from), shift(to))
						Polyline(points) => Polyline(points.map(shift))
						Curves(segments) => Curves(segments.map(|seg| { from: shift(seg.from), ctl_a: shift(seg.ctl_a), ctl_b: shift(seg.ctl_b), to: shift(seg.to) }))
					},
				),
			},
			depths: flat.depths,
		}
	}

	## Combines a computed placement with the per-depth extents already
	## gathered by `analyze_node` into the family's public `Result`.
	assemble : Placed, List({ width : F64, height : F64 }), Tree.Settings -> Tree.Result
	assemble = |root_placed, depth_extents, settings| {
		lvl_starts = TreeInternals.level_starts(depth_extents, settings.direction, settings.level_gap)
		lvl_total = TreeInternals.level_total(depth_extents, settings.direction, settings.level_gap)
		bounds = TreeInternals.spread_bounds(root_placed)
		root_abs = 0 - bounds.min
		root_level_c = (lvl_starts.get(0) ?? 0) + TreeInternals.level_extent(settings.direction, root_placed.width, root_placed.height) / 2
		root_point = TreeInternals.to_xy(settings.direction, root_abs, root_level_c, lvl_total)

		seeded = { positions: [root_point], depths: [0], routes: [] }
		flattened = TreeInternals.flatten_node(root_placed, 0, root_abs, root_point, lvl_starts, lvl_total, settings.direction, seeded)

		spread_total = bounds.max - bounds.min
		wh = match settings.direction {
			Down => { width: spread_total, height: lvl_total }
			Up => { width: spread_total, height: lvl_total }
			Left => { width: lvl_total, height: spread_total }
			Right => { width: lvl_total, height: spread_total }
		}

		{
			layout: {
				positions: flattened.positions,
				bounds: { ..Geom.empty_bounds, width: wh.width, height: wh.height },
				routes: flattened.routes,
			},
			depths: flattened.depths,
		}
	}
}

## A validated and precomputed tidy tree layout.
##
## `Tidy` has no per-run arguments — the placement criteria determine the
## drawing uniquely — so `build` computes the complete result once, and
## `run` only returns it.
Prepared := { result : Tree.Result }.{
	build : Tree.Spec, Tree.Settings -> [Ok(Prepared), Err(List(Tree.Problem))]
	build = |spec, settings| {
		analyzed = TreeInternals.analyze_node(spec, 0, { next_index: 0, problems: [], depth_extents: [] })
		problems = analyzed.problems.concat(TreeInternals.validate_settings(settings))

		if !problems.is_empty() {
			Err(problems)
		} else {
			root_placed = TreeInternals.layout_subtree(spec, settings.direction, settings.sibling_gap, settings.subtree_gap)
			computed = TreeInternals.assemble(root_placed, analyzed.depth_extents, settings)
			prepared : Prepared
			prepared = { result: computed }
			Ok(prepared)
		}
	}

	run : Prepared -> Tree.Result
	run = |prepared| prepared.result

	layout : Tree.Spec, Tree.Settings -> [Ok(Tree.Result), Err(List(Tree.Problem))]
	layout = |spec, settings|
		match Prepared.build(spec, settings) {
			Ok(prepared) => Ok(prepared.run())
			Err(problems) => Err(problems)
		}
}

## A validated and precomputed radial tree layout.
##
## Like `Tidy`, the radial reading has no per-run arguments — the placement
## criteria determine the drawing uniquely — so `build` computes the
## complete result once, and `run` only returns it.
RadialPrepared := { result : Tree.Result }.{
	build : Tree.Spec, Tree.RadialSettings -> [Ok(RadialPrepared), Err(List(Tree.Problem))]
	build = |spec, settings| {
		analyzed = TreeInternals.analyze_node(spec, 0, { next_index: 0, problems: [], depth_extents: [] })
		problems = analyzed.problems.concat(TreeInternals.validate_radial_settings(settings))

		if !problems.is_empty() {
			Err(problems)
		} else {
			root_placed = TreeInternals.layout_subtree(spec, Down, settings.sibling_gap, settings.subtree_gap)
			computed = TreeInternals.assemble_radial(root_placed, analyzed.depth_extents, settings)
			prepared : RadialPrepared
			prepared = { result: computed }
			Ok(prepared)
		}
	}

	run : RadialPrepared -> Tree.Result
	run = |prepared| prepared.result

	layout : Tree.Spec, Tree.RadialSettings -> [Ok(Tree.Result), Err(List(Tree.Problem))]
	layout = |spec, settings|
		match RadialPrepared.build(spec, settings) {
			Ok(prepared) => Ok(prepared.run())
			Err(problems) => Err(problems)
		}
}

## Tree layouts for input already known to be a hierarchy. Two readings of
## the same input: the level-by-level one (the default `layout`), and the
## radial one (`layout_radial`), which puts the root at the center and each
## generation on its own ring. A caller with a hierarchy provides it
## directly as a `Spec`, the root node of the tree; every other node is a
## descendant.
##
## `layout` is the usual entry point. For repeated layouts of unchanged
## input, call `prepare` once and pass the result to `layout_prepared`.
Tree := [].{

	## A hierarchy given as one: the spec is its own root node, and every
	## value of this type is a tree by construction — there is no separate
	## "is it a tree" check. Nodes are numbered in depth-first order (this
	## root is 0), and every other output list aligns to that order.
	Spec := { width : F64, height : F64, children : List(Spec) }

	## Tidy input for the current exemplar: the root of the hierarchy.
	Input : Spec

	## Space between adjacent siblings, between adjacent subtrees that do
	## not share a parent, and between levels; the axis the tree grows
	## along.
	Settings : { sibling_gap : F64, subtree_gap : F64, level_gap : F64, direction : [Down, Up, Left, Right] }

	## Spacing for the radial reading. `sibling_gap` and `subtree_gap` keep
	## the same meaning as in `Settings` and set each node's share of its
	## ring; `ring_gap` separates consecutive rings; `start_angle` (radians)
	## is where the first subtree begins, with `Clockwise` or
	## `CounterClockwise` deciding which way around the rings siblings
	## follow.
	RadialSettings : {
		sibling_gap : F64,
		subtree_gap : F64,
		ring_gap : F64,
		start_angle : F64,
		winding : [Clockwise, CounterClockwise],
	}

	## Invalid sizes or settings found while checking input, indexed by
	## each node's depth-first position.
	Problem : [
		InvalidWidth(U64),
		InvalidHeight(U64),
		InvalidSiblingGap,
		InvalidSubtreeGap,
		InvalidLevelGap,
		InvalidRingGap,
		InvalidStartAngle,
	]

	## Geometry plus each node's depth, both in depth-first order.
	## `positions` are node centers; route endpoints lie on the connected
	## nodes' bounding rectangles (a zero-size node's endpoint is its
	## center), so an arrowhead drawn at a route's end lands on the box.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		depths : List(U64),
	}

	## A single node with no children. Replace by record update.
	default_input : Input
	default_input = { width: 0, height: 0, children: [] }

	## Settings that produce a readable top-to-bottom tree in common cases.
	default_settings : Settings
	default_settings = { sibling_gap: 12, subtree_gap: 24, level_gap: 60, direction: Down }

	## Radial settings that produce a readable drawing in common cases: the
	## first subtree starts at twelve o'clock and siblings follow clockwise.
	default_radial_settings : RadialSettings
	default_radial_settings = { sibling_gap: 12, subtree_gap: 24, ring_gap: 60, start_angle: 0 - Trig.tau / 4, winding: Clockwise }

	## Check the input and settings, then cache the layout it determines.
	prepare : Input, Settings -> [Ok(Prepared), Err(List(Problem))]
	prepare = |input, settings| Prepared.build(input, settings)

	## Return the previously computed layout. This operation cannot fail.
	layout_prepared : Prepared -> Result
	layout_prepared = |prepared| prepared.run()

	## Check and lay out input in one call. This is the usual entry point.
	layout : Input, Settings -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings| Prepared.layout(input, settings)

	## Check the input and radial settings, then cache the layout they
	## determine.
	prepare_radial : Input, RadialSettings -> [Ok(RadialPrepared), Err(List(Problem))]
	prepare_radial = |input, settings| RadialPrepared.build(input, settings)

	## Return the previously computed radial layout. This operation cannot
	## fail.
	layout_radial_prepared : RadialPrepared -> Result
	layout_radial_prepared = |prepared| prepared.run()

	## Check and lay out input in one call, read radially: the root at the
	## center, each generation on its own ring, subtrees in nested wedges in
	## sibling order.
	layout_radial : Input, RadialSettings -> [Ok(Result), Err(List(Problem))]
	layout_radial = |input, settings| RadialPrepared.layout(input, settings)
}

## Two children of different widths: siblings clear each other by exactly
## `sibling_gap`, the parent centers over their combined span, and each
## route runs boundary to boundary — clipped out of the parent's box and
## into the child's — rather than center to center.
expect {
	spec = {
		width: 10,
		height: 4,
		children: [
			{ width: 20, height: 4, children: [] },
			{ width: 10, height: 4, children: [] },
		],
	}
	settings = { sibling_gap: 2, subtree_gap: 6, level_gap: 4, direction: Down }

	Tree.layout(spec, settings) == Ok({
		layout: {
			positions: [{ x: 16, y: 2 }, { x: 10, y: 10 }, { x: 27, y: 10 }],
			bounds: { x: 0, y: 0, width: 32, height: 12 },
			routes: [
				Line({ x: 14.5, y: 4 }, { x: 11.5, y: 8 }),
				Line({ x: 18.75, y: 4 }, { x: 24.25, y: 8 }),
			],
		},
		depths: [0, 1, 1],
	})
}

## In a `Down` tree a route leaves through the parent's bottom edge and
## arrives on the child's top edge: the start's `y` is exactly the parent
## center plus half the parent height, and the end's `y` is exactly the
## child center minus half the child height.
expect {
	spec = { width: 10, height: 8, children: [{ width: 8, height: 4, children: [] }] }
	settings = { ..Tree.default_settings, level_gap: 10 }

	match Tree.layout(spec, settings) {
		Err(_) => False
		Ok(result) => {
			parent = result.layout.positions.get(0) ?? Geom.point(0, 0)
			child = result.layout.positions.get(1) ?? Geom.point(0, 0)
			route = result.layout.routes.get(0) ?? Polyline([])
			match route {
				Line(from, to) => from.y == parent.y + 8.0 / 2 and to.y == child.y - 4.0 / 2
				_ => False
			}
		}
	}
}

## A zero-size node has no boundary to clip to: its route endpoint is its
## center exactly.
expect {
	spec = { width: 10, height: 4, children: [{ width: 0, height: 0, children: [] }] }

	match Tree.layout(spec, Tree.default_settings) {
		Err(_) => False
		Ok(result) => {
			child = result.layout.positions.get(1) ?? Geom.point(0, 0)
			route = result.layout.routes.get(0) ?? Polyline([])
			match route {
				Line(_, to) => to == child
				_ => False
			}
		}
	}
}

## A single node with no children sits at the origin, centered on itself —
## the degenerate case the empty `default_input` reduces to.
expect Tree.layout(Tree.default_input, Tree.default_settings) == Ok({
	layout: { positions: [{ x: 0, y: 0 }], bounds: Geom.empty_bounds, routes: [] },
	depths: [0],
})

## Zero-size nodes are legal waypoints: a leaf with no extent still gets a
## defined position and does not disturb its sibling's spacing.
expect {
	spec = {
		width: 0,
		height: 0,
		children: [
			{ width: 0, height: 0, children: [] },
			{ width: 4, height: 4, children: [] },
		],
	}
	settings = { ..Tree.default_settings, sibling_gap: 2, level_gap: 10 }

	match Tree.layout(spec, settings) {
		Err(_) => False
		Ok(result) => result.layout.positions.len() == 3 and result.depths == [0, 1, 1]
	}
}

## `build` reports every independent problem it finds, indexed by each
## node's depth-first position, not only the first one.
expect {
	spec = {
		width: -1,
		height: 3,
		children: [{ width: 5, height: -2, children: [] }],
	}
	settings = { ..Tree.default_settings, sibling_gap: -4 }

	Tree.prepare(spec, settings) == Err([InvalidWidth(0), InvalidHeight(1), InvalidSiblingGap])
}

## The one-shot API is exactly build followed by run.
expect {
	spec = { width: 8, height: 4, children: [{ width: 6, height: 4, children: [] }] }
	match Tree.prepare(spec, Tree.default_settings) {
		Err(_) => False
		Ok(prepared) => Tree.layout(spec, Tree.default_settings) == Ok(prepared.run())
	}
}

## Identical input and settings produce identical output.
expect {
	spec = {
		width: 12,
		height: 6,
		children: [
			{ width: 8, height: 6, children: [{ width: 6, height: 4, children: [] }] },
			{ width: 8, height: 6, children: [] },
		],
	}
	Tree.layout(spec, Tree.default_settings) == Tree.layout(spec, Tree.default_settings)
}

## A single node reads the same radially as it does tidily: it sits at the
## origin, centered on itself.
expect Tree.layout_radial(Tree.default_input, Tree.default_radial_settings) == Ok({
	layout: { positions: [{ x: 0, y: 0 }], bounds: Geom.empty_bounds, routes: [] },
	depths: [0],
})

## Every child sits on the first ring: all depth-1 nodes are the same
## distance from the root, and that distance is the root's half-diagonal
## plus `ring_gap` plus the child's half-diagonal — the diagonal bounds a
## box's radial footprint at every angle it can sit at.
expect {
	child = { width: 10, height: 8, children: [] }
	spec = { width: 10, height: 8, children: [child, child, child, child] }
	settings = { ..Tree.default_radial_settings, ring_gap: 20 }

	match Tree.layout_radial(spec, settings) {
		Err(_) => False
		Ok(result) => {
			root = result.layout.positions.get(0) ?? Geom.point(0, 0)
			expected_radius = Geom.hypot(10, 8) / 2 + 20 + Geom.hypot(10, 8) / 2
			result.layout.positions.drop_first(1).all(
				|p| {
					radius = ((p.x - root.x) * (p.x - root.x) + (p.y - root.y) * (p.y - root.y)).sqrt()
					(radius - expected_radius).abs() < 1e-9
				},
			)
		}
	}
}

## Wide, flat nodes do not overlap between rings: a child seated to the
## root's side sits far enough out that the two boxes clear each other,
## which height-based rings would fail (10 + gap apart for 100-wide boxes).
expect {
	spec = {
		width: 100,
		height: 10,
		children: [{ width: 100, height: 10, children: [] }],
	}
	settings = { ..Tree.default_radial_settings, ring_gap: 20, start_angle: 0 }

	match Tree.layout_radial(spec, settings) {
		Err(_) => False
		Ok(result) => {
			root = result.layout.positions.get(0) ?? Geom.point(0, 0)
			child = result.layout.positions.get(1) ?? Geom.point(0, 0)
			dx = (child.x - root.x).abs()
			dy = (child.y - root.y).abs()
			separated = dx >= 100 or dy >= 10
			separated
		}
	}
}

## Routes connect each node to its parent, in the same depth-first order as
## the tidy reading, and depths match between the two readings.
expect {
	spec = {
		width: 10,
		height: 6,
		children: [
			{ width: 8, height: 6, children: [{ width: 6, height: 4, children: [] }] },
			{ width: 8, height: 6, children: [] },
		],
	}

	match (Tree.layout(spec, Tree.default_settings), Tree.layout_radial(spec, Tree.default_radial_settings)) {
		(Ok(tidy), Ok(radial)) =>
			radial.depths == tidy.depths
				and radial.layout.routes.len() == tidy.layout.routes.len()
					and radial.layout.positions.len() == tidy.layout.positions.len()

		_ => False
	}
}

## Winding mirrors the drawing: reversing it flips positions across the
## vertical axis through the root while preserving every ring radius.
expect {
	spec = {
		width: 10,
		height: 6,
		children: [
			{ width: 8, height: 6, children: [] },
			{ width: 8, height: 6, children: [] },
			{ width: 12, height: 6, children: [] },
		],
	}
	cw = Tree.layout_radial(spec, Tree.default_radial_settings)
	ccw = Tree.layout_radial(spec, { ..Tree.default_radial_settings, winding: CounterClockwise })

	match (cw, ccw) {
		(Ok(a), Ok(b)) => {
			root_a = a.layout.positions.get(0) ?? Geom.point(0, 0)
			root_b = b.layout.positions.get(0) ?? Geom.point(0, 0)
			a.layout.positions.map2(
				b.layout.positions,
				|pa, pb| ((pa.x - root_a.x) + (pb.x - root_b.x)).abs() < 1e-9 and ((pa.y - root_a.y) - (pb.y - root_b.y)).abs() < 1e-9,
			).all(|ok| ok)
		}

		_ => False
	}
}

## Radial `build` reports every independent problem it finds, across both
## the input and the radial settings.
expect {
	spec = {
		width: -1,
		height: 3,
		children: [],
	}
	settings = { ..Tree.default_radial_settings, ring_gap: -5, start_angle: F64.infinity }

	Tree.prepare_radial(spec, settings) == Err([InvalidWidth(0), InvalidRingGap, InvalidStartAngle])
}

## The one-shot radial API is exactly build followed by run.
expect {
	spec = { width: 8, height: 4, children: [{ width: 6, height: 4, children: [] }] }
	match Tree.prepare_radial(spec, Tree.default_radial_settings) {
		Err(_) => False
		Ok(prepared) => Tree.layout_radial(spec, Tree.default_radial_settings) == Ok(prepared.run())
	}
}

## Identical input and radial settings produce identical output.
expect {
	spec = {
		width: 12,
		height: 6,
		children: [
			{ width: 8, height: 6, children: [{ width: 6, height: 4, children: [] }] },
			{ width: 8, height: 6, children: [] },
		],
	}
	Tree.layout_radial(spec, Tree.default_radial_settings) == Tree.layout_radial(spec, Tree.default_radial_settings)
}

## Identical subtrees produce identical, translated drawings: both children
## below are the same shape, so their own widths (span of their subtree)
## match even though their absolute positions differ.
expect {
	twin = { width: 6, height: 4, children: [{ width: 4, height: 4, children: [] }] }
	spec = { width: 10, height: 4, children: [twin, twin] }

	match Tree.layout(spec, Tree.default_settings) {
		Err(_) => False
		Ok(result) => {
			left_width = (result.layout.positions.get(2) ?? Geom.point(0, 0)).x - (result.layout.positions.get(1) ?? Geom.point(0, 0)).x
			right_width = (result.layout.positions.get(4) ?? Geom.point(0, 0)).x - (result.layout.positions.get(3) ?? Geom.point(0, 0)).x
			left_width == right_width
		}
	}
}
