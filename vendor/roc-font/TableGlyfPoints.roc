import TableVar

## TrueType outline points (`glyf`, located through `loca`, with the side
## bearings and advances of `hmtx`): the points of simple glyphs (flags,
## coordinates, contour end points), the component records of composite
## glyphs (glyph, offset or anchor points, scale or 2x2 transform), the four
## phantom points, and glyph extents at the default location.
##
## Internal. Reading checks every glyph once: `loca` ascending and inside
## `glyf`; every simple glyph's end points strictly increasing, its
## instructions, flags (with no repeat running past the last point) and
## coordinates inside the glyph; every component record inside its glyph
## and naming an existing glyph; no composite cycle; and the work any glyph
## can cost bounded (nesting depth, expanded components and points, and the
## work of applying variations, at HarfBuzz's limits). After a successful
## read every query here is total. `TableGvar` applies variations to the
## points this module decodes.
TableGlyfPoints := {
	glyf : List(U8),
	hmtx : List(U8),
	# numberOfHMetrics, at least 1 after reading.
	long_metrics : U64,
	# Glyph g's bytes are starts[g] up to starts[g + 1] in glyf.
	starts : List(U64),
	# Per glyph: 0 empty, 1 simple, 2 composite.
	kinds : List(U8),
	# Per glyph: points of a simple glyph, components of a composite, else 0.
	counts : List(U64),
	# Composite glyphs, each after every composite it uses.
	order : List(U64),
}.{

	## What was wrong, where. `offset` is from the start of `table`.
	Problem : { table : Str, offset : U64, reason : Reason }

	Reason : [
		Truncated,
		OffsetOrder,
		TooShort,
		ContourOrder,
		FlagRepeat,
		GlyphIndex,
		Cycle,
		TooDeep,
		TooManyComponents,
		TooManyPoints,
		TooMuchWork,
		AnchorPoint,
		UnsupportedVersion,
		AxisCountMismatch,
		GlyphCountMismatch,
		TupleIndex,
		PointIndex,
		RunCount,
	]

	## A glyph's ink box in font units, as HarfBuzz reports it: `x_bearing`
	## is the left edge, `y_bearing` the top edge, `width` is positive and
	## `height` negative (downwards). An empty glyph is all zero.
	Extents : { x_bearing : I64, y_bearing : I64, width : I64, height : I64 }

	## A component record of a composite glyph. `dx`, `dy` is the offset (0
	## for a component placed by anchor points `p1`, `p2`); `matrix` holds
	## the scale or 2x2 transform as single-precision bit patterns, in
	## HarfBuzz's order (xx, xy, yx, yy). `next` is the next record's offset.
	Component : {
		glyph : U64,
		dx : I64,
		dy : I64,
		anchored : Bool,
		p1 : U64,
		p2 : U64,
		matrix : List(U32),
		identity : Bool,
		scaled_offsets : Bool,
		use_my_metrics : Bool,
		more : Bool,
		next : U64,
	}

	# ------------------------------------------------------------ limits

	## HarfBuzz's limits for one glyph (`hb-limits.hh`): composite nesting
	## (`HB_MAX_NESTING_LEVEL`), glyphs visited (`HB_MAX_GRAPH_EDGE_COUNT`),
	## points (`HB_GLYF_MAX_POINTS`) and work units (`HB_BUDGET_GLYPH`).
	## A font where some glyph could exceed one is rejected, so HarfBuzz
	## never gives up on a glyph this module accepts.
	depth_limit : U64
	depth_limit = 64

	visit_limit : U64
	visit_limit = 16385

	point_limit : U64
	point_limit = 200000

	work_limit : U64
	work_limit = 16777216

	# Large enough that no sum below overflows, small enough to exceed every
	# limit.
	saturated : U64
	saturated = 0x10000000000

	sat : U64 -> U64
	sat = |v| v.min(TableGlyfPoints.saturated)

	# ------------------------------------------------------------ reading

	## Read `glyf` through `loca` (`long_offsets` from `head`), for
	## `glyph_count` glyphs (from `maxp`), with `hmtx` and its
	## `numberOfHMetrics`. Every independent problem is reported.
	read : List(U8), List(U8), Bool, U64, List(U8), U64 -> Try(TableGlyfPoints, List(Problem))
	read = |glyf, loca, long_offsets, glyph_count, hmtx, long_metrics| {
		var $problems = []
		short_count = glyph_count - long_metrics.min(glyph_count)
		if long_metrics == 0 or !TableVar.fits(0, 4 * long_metrics + 2 * short_count, hmtx.len()) {
			$problems = $problems.append({ table: "hmtx", offset: 0, reason: Truncated })
		}
		size = if (long_offsets) 4 else 2
		if !TableVar.fits(0, size * (glyph_count + 1), loca.len()) {
			return Err($problems.append({ table: "loca", offset: 0, reason: Truncated }))
		}
		offset = |g| if (long_offsets) TableVar.u32(loca, 4 * g) else 2 * TableVar.u16(loca, 2 * g)
		var $starts = List.with_capacity(glyph_count + 1)
		var $kinds = List.with_capacity(glyph_count)
		var $counts = List.with_capacity(glyph_count)
		$starts = $starts.append(offset(0))
		for g in 0..<glyph_count {
			start = offset(g)
			end = offset(g + 1)
			$starts = $starts.append(end)
			if end < start {
				$problems = $problems.append({ table: "loca", offset: size * (g + 1), reason: OffsetOrder })
				$kinds = $kinds.append(0)
				$counts = $counts.append(0)
			} else if end > glyf.len() {
				$problems = $problems.append({ table: "loca", offset: size * (g + 1), reason: Truncated })
				$kinds = $kinds.append(0)
				$counts = $counts.append(0)
			} else if end == start {
				$kinds = $kinds.append(0)
				$counts = $counts.append(0)
			} else if end - start < 10 {
				$problems = $problems.append({ table: "glyf", offset: start, reason: TooShort })
				$kinds = $kinds.append(0)
				$counts = $counts.append(0)
			} else {
				contours = TableVar.i16(glyf, start)
				if contours == 0 {
					$kinds = $kinds.append(0)
					$counts = $counts.append(0)
				} else if contours > 0 {
					match TableGlyfPoints.simple_layout(glyf, start, end, contours.to_u64_wrap()) {
						Ok(layout) => {
							$kinds = $kinds.append(1)
							$counts = $counts.append(layout.points)
						}
						Err((at, reason)) => {
							$problems = $problems.append({ table: "glyf", offset: at, reason })
							$kinds = $kinds.append(0)
							$counts = $counts.append(0)
						}
					}
				} else {
					match TableGlyfPoints.composite_count(glyf, start, end, glyph_count) {
						Ok(n) => {
							$kinds = $kinds.append(2)
							$counts = $counts.append(n)
						}
						Err((at, reason)) => {
							$problems = $problems.append({ table: "glyf", offset: at, reason })
							$kinds = $kinds.append(0)
							$counts = $counts.append(0)
						}
					}
				}
			}
		}
		if !$problems.is_empty() {
			return Err($problems)
		}
		order = TableGlyfPoints.composite_order(glyf, $starts, $kinds)?
		points = { glyf, hmtx, long_metrics, starts: $starts, kinds: $kinds, counts: $counts, order }
		TableGlyfPoints.check_work(points, [])?
		Ok(points)
	}

	# The layout of a simple glyph of `contours` contours in glyf[start, end):
	# its point count and where its flags and coordinates start.
	simple_layout : List(U8), U64, U64, U64 -> Try({ points : U64, flags_at : U64, xs_at : U64, ys_at : U64 }, (U64, Reason))
	simple_layout = |glyf, start, end, contours| {
		ends_at = start + 10
		if !TableVar.fits(ends_at, 2 * contours + 2, end) {
			return Err((ends_at, Truncated))
		}
		var $previous = 0
		for c in 0..<contours {
			e = TableVar.u16(glyf, ends_at + 2 * c)
			if c > 0 and e <= $previous {
				return Err((ends_at + 2 * c, ContourOrder))
			}
			$previous = e
		}
		points = $previous + 1
		instructions = TableVar.u16(glyf, ends_at + 2 * contours)
		flags_at = ends_at + 2 * contours + 2 + instructions
		# Each point needs at least a flag byte, so the point count bounds
		# the walk.
		var $at = flags_at
		var $i = 0
		var $x_bytes = 0
		var $y_bytes = 0
		while $i < points {
			if $at >= end {
				return Err(($at, Truncated))
			}
			flag = TableVar.u8(glyf, $at)
			repeat =
				if flag.bitwise_and(0x08) != 0 {
					if $at + 1 >= end {
						return Err(($at, Truncated))
					}
					TableVar.u8(glyf, $at + 1)
				} else {
					0
				}
			if $i + 1 + repeat > points {
				return Err(($at, FlagRepeat))
			}
			n = 1 + repeat
			x_size = if (flag.bitwise_and(0x02) != 0) 1 else if (flag.bitwise_and(0x10) != 0) 0 else 2
			y_size = if (flag.bitwise_and(0x04) != 0) 1 else if (flag.bitwise_and(0x20) != 0) 0 else 2
			$x_bytes = $x_bytes + n * x_size
			$y_bytes = $y_bytes + n * y_size
			$at = $at + (if (repeat > 0 or flag.bitwise_and(0x08) != 0) 2 else 1)
			$i = $i + n
		}
		if !TableVar.fits($at, $x_bytes + $y_bytes, end) {
			return Err(($at, Truncated))
		}
		Ok({ points, flags_at, xs_at: $at, ys_at: $at + $x_bytes })
	}

	# The size of the component record at `at`.
	record_size : List(U8), U64 -> U64
	record_size = |glyf, at| {
		flags = TableVar.u16(glyf, at)
		args = if (flags.bitwise_and(0x0001) != 0) 4 else 2
		scale = if (flags.bitwise_and(0x0008) != 0) 2 else if (flags.bitwise_and(0x0040) != 0) 4 else if (flags.bitwise_and(0x0080) != 0) 8 else 0
		4 + args + scale
	}

	# The component count of a composite glyph in glyf[start, end), each
	# record inside the glyph and naming a glyph below `glyph_count`.
	composite_count : List(U8), U64, U64, U64 -> Try(U64, (U64, Reason))
	composite_count = |glyf, start, end, glyph_count| {
		# Every record is at least 6 bytes, so the glyph size bounds the walk.
		var $at = start + 10
		var $n = 0
		var $more = True
		while $more {
			if !TableVar.fits($at, 4, end) or !TableVar.fits($at, TableGlyfPoints.record_size(glyf, $at), end) {
				return Err(($at, Truncated))
			}
			if TableVar.u16(glyf, $at + 2) >= glyph_count {
				return Err(($at + 2, GlyphIndex))
			}
			$n = $n + 1
			$more = TableVar.u16(glyf, $at).bitwise_and(0x0020) != 0
			$at = $at + TableGlyfPoints.record_size(glyf, $at)
		}
		Ok($n)
	}

	# Composite glyphs ordered so that each follows every composite it uses,
	# by a depth-first walk with an explicit stack. A cycle is a problem.
	composite_order : List(U8), List(U64), List(U8) -> Try(List(U64), List(Problem))
	composite_order = |glyf, starts, kinds| {
		count = kinds.len()
		done = 0xFFFFFFFFFFFFFFFF
		# 0 unvisited, 1 on the stack, 2 finished.
		var $state = List.repeat(0.U8, count)
		var $order = []
		var $problems = []
		for root in 0..<count {
			if (kinds.get(root) ?? 0) == 2 and ($state.get(root) ?? 0) == 0 {
				var $nodes = [root]
				var $records = [(starts.get(root) ?? 0) + 10]
				$state = $state.set(root, 1) ?? []
				# Each glyph enters the stack once and each record is read
				# once, so the walk is bounded by the records of the font.
				while !$nodes.is_empty() {
					top = $nodes.len() - 1
					g = $nodes.get(top) ?? 0
					at = $records.get(top) ?? done
					if at == done {
						$nodes = $nodes.drop_last(1)
						$records = $records.drop_last(1)
						$state = $state.set(g, 2) ?? []
						$order = $order.append(g)
					} else {
						flags = TableVar.u16(glyf, at)
						next = if (flags.bitwise_and(0x0020) != 0) at + TableGlyfPoints.record_size(glyf, at) else done
						$records = $records.set(top, next) ?? []
						child = TableVar.u16(glyf, at + 2)
						if (kinds.get(child) ?? 0) == 2 {
							s = $state.get(child) ?? 0
							if s == 1 {
								$problems = $problems.append({ table: "glyf", offset: at + 2, reason: Cycle })
							} else if s == 0 {
								$state = $state.set(child, 1) ?? []
								$nodes = $nodes.append(child)
								$records = $records.append((starts.get(child) ?? 0) + 10)
							}
						}
					}
				}
			}
		}
		if ($problems.is_empty()) Ok($order) else Err($problems)
	}

	## Check the work every glyph can cost against HarfBuzz's limits, given
	## the tuple variation count of each glyph (`[]` without variations), and
	## that anchor points name existing points: `p1` a point of the
	## components before, `p2` a point of the component placed.
	##
	## The work is HarfBuzz's budget, counted as if every tuple applies: 16
	## per glyph visited, a simple glyph's points, the points of every
	## component at each level that transforms them, a tuple's points per
	## tuple, and the final point count.
	check_work : TableGlyfPoints, List(U64) -> Try({}, List(Problem))
	check_work = |t, tuples| {
		count = t.kinds.len()
		var $points = List.with_capacity(count)
		var $visits = List.with_capacity(count)
		var $depth = List.with_capacity(count)
		var $work = List.with_capacity(count)
		for g in 0..<count {
			kind = t.kinds.get(g) ?? 0
			n = t.counts.get(g) ?? 0
			own = if (kind == 1) n else 0
			tuple_work = (tuples.get(g) ?? 0) * (n + 4)
			$points = $points.append(own)
			$visits = $visits.append(1)
			$depth = $depth.append(0)
			$work = $work.append(16 + own + tuple_work)
		}
		var $problems = []
		for g in t.order {
			var $at = (t.starts.get(g) ?? 0) + 10
			var $sum_points = 0
			var $sum_visits = 1
			var $max_depth = 0
			var $sum_work = $work.get(g) ?? 0
			for _k in 0..<(t.counts.get(g) ?? 0) {
				c = TableGlyfPoints.component(t.glyf, $at)
				child_points = $points.get(c.glyph) ?? 0
				if c.anchored and (c.p1 >= $sum_points or c.p2 >= child_points) {
					$problems = $problems.append({ table: "glyf", offset: $at + 4, reason: AnchorPoint })
				}
				$sum_points = TableGlyfPoints.sat($sum_points + child_points)
				$sum_visits = TableGlyfPoints.sat($sum_visits + ($visits.get(c.glyph) ?? 0))
				$max_depth = $max_depth.max(($depth.get(c.glyph) ?? 0) + 1)
				$sum_work = TableGlyfPoints.sat($sum_work + ($work.get(c.glyph) ?? 0) + child_points + 4)
				$at = c.next
			}
			# `order` holds glyph indices below the glyph count.
			$points = $points.set(g, $sum_points) ?? []
			$visits = $visits.set(g, $sum_visits) ?? []
			$depth = $depth.set(g, $max_depth) ?? []
			$work = $work.set(g, $sum_work) ?? []
			at = t.starts.get(g) ?? 0
			if $max_depth > TableGlyfPoints.depth_limit {
				$problems = $problems.append({ table: "glyf", offset: at, reason: TooDeep })
			} else if $sum_visits > TableGlyfPoints.visit_limit {
				$problems = $problems.append({ table: "glyf", offset: at, reason: TooManyComponents })
			} else if $sum_points > TableGlyfPoints.point_limit {
				$problems = $problems.append({ table: "glyf", offset: at, reason: TooManyPoints })
			}
		}
		for g in 0..<count {
			if ($work.get(g) ?? 0) + ($points.get(g) ?? 0) + 4 > TableGlyfPoints.work_limit {
				$problems = $problems.append({ table: "glyf", offset: t.starts.get(g) ?? 0, reason: TooMuchWork })
			}
		}
		if ($problems.is_empty()) Ok({}) else Err($problems)
	}

	# ------------------------------------------------------------ queries

	glyph_total : TableGlyfPoints -> U64
	glyph_total = |t| t.kinds.len()

	## 0 for an empty glyph (or one past the font), 1 simple, 2 composite.
	kind : TableGlyfPoints, U64 -> U8
	kind = |t, g| t.kinds.get(g) ?? 0

	## The points a glyph's variation data addresses, before its four
	## phantom points: a simple glyph's points, or a composite's components.
	point_count : TableGlyfPoints, U64 -> U64
	point_count = |t, g| t.counts.get(g) ?? 0

	## The offset of a composite glyph's first component record.
	first_component : TableGlyfPoints, U64 -> U64
	first_component = |t, g| (t.starts.get(g) ?? 0) + 10

	## The left side bearing in `hmtx`.
	side_bearing : TableGlyfPoints, U64 -> I64
	side_bearing = |t, g|
		if g < t.long_metrics {
			TableVar.i16(t.hmtx, 4 * g + 2)
		} else {
			TableVar.i16(t.hmtx, 4 * t.long_metrics + 2 * (g - t.long_metrics))
		}

	## The advance in `hmtx` (a glyph past the long metrics takes the last
	## one, as the format defines).
	advance : TableGlyfPoints, U64 -> I64
	advance = |t, g| TableVar.u16(t.hmtx, 4 * g.min(t.long_metrics - 1)).to_i64_wrap()

	# The glyph header's xMin, or 0 for a glyph without a header.
	x_min : TableGlyfPoints, U64 -> I64
	x_min = |t, g| {
		start = t.starts.get(g) ?? 0
		if ((t.starts.get(g + 1) ?? 0) - start >= 10) TableVar.i16(t.glyf, start + 2) else 0
	}

	## The four phantom points' x coordinates (left, right, top, bottom) as
	## HarfBuzz places them before variations: the left one at xMin minus
	## the side bearing, the right one an advance further. The vertical
	## phantom points are carried at 0: nothing measured here reads them.
	phantom_xs : TableGlyfPoints, U64 -> List(U32)
	phantom_xs = |t, g| {
		left = TableGlyfPoints.x_min(t, g) - TableGlyfPoints.side_bearing(t, g)
		[TableVar.f32_from_int(left), TableVar.f32_from_int(left + TableGlyfPoints.advance(t, g)), 0, 0]
	}

	## A simple glyph's points as single-precision bit patterns, with the
	## contour end markers. Empty for any other glyph.
	simple_points : TableGlyfPoints, U64 -> { xs : List(U32), ys : List(U32), ends : List(Bool) }
	simple_points = |t, g| {
		glyf = t.glyf
		start = t.starts.get(g) ?? 0
		end = t.starts.get(g + 1) ?? 0
		if (t.kinds.get(g) ?? 0) != 1 {
			return { xs: [], ys: [], ends: [] }
		}
		contours = TableVar.u16(glyf, start)
		match TableGlyfPoints.simple_layout(glyf, start, end, contours) {
			Err(_) => { xs: [], ys: [], ends: [] }
			Ok(layout) => {
				n = layout.points
				var $flags = List.with_capacity(n)
				var $at = layout.flags_at
				while $flags.len() < n {
					flag = TableVar.u8(glyf, $at).to_u8_wrap()
					$flags = $flags.append(flag)
					if flag.bitwise_and(0x08) != 0 {
						repeat = TableVar.u8(glyf, $at + 1)
						for _r in 0..<repeat {
							$flags = $flags.append(flag)
						}
						$at = $at + 2
					} else {
						$at = $at + 1
					}
				}
				var $ends = List.repeat(False, n)
				for c in 0..<contours {
					# Validated: end points are below the point count.
					$ends = $ends.set(TableVar.u16(glyf, start + 10 + 2 * c), True) ?? []
				}
				var $xs = List.with_capacity(n)
				var $ys = List.with_capacity(n)
				var $x_at = layout.xs_at
				var $y_at = layout.ys_at
				var $x = 0
				var $y = 0
				for flag in $flags {
					if flag.bitwise_and(0x02) != 0 {
						d = TableVar.u8(glyf, $x_at).to_i64_wrap()
						$x = if (flag.bitwise_and(0x10) != 0) $x + d else $x - d
						$x_at = $x_at + 1
					} else if flag.bitwise_and(0x10) == 0 {
						$x = $x + TableVar.i16(glyf, $x_at)
						$x_at = $x_at + 2
					}
					if flag.bitwise_and(0x04) != 0 {
						d = TableVar.u8(glyf, $y_at).to_i64_wrap()
						$y = if (flag.bitwise_and(0x20) != 0) $y + d else $y - d
						$y_at = $y_at + 1
					} else if flag.bitwise_and(0x20) == 0 {
						$y = $y + TableVar.i16(glyf, $y_at)
						$y_at = $y_at + 2
					}
					$xs = $xs.append(TableVar.f32_from_int($x))
					$ys = $ys.append(TableVar.f32_from_int($y))
				}
				{ xs: $xs, ys: $ys, ends: $ends }
			}
		}
	}

	## The component record at `at` in `glyf`.
	component : List(U8), U64 -> Component
	component = |glyf, at| {
		flags = TableVar.u16(glyf, at)
		words = flags.bitwise_and(0x0001) != 0
		anchored = flags.bitwise_and(0x0002) == 0
		a1 = if (words) TableVar.i16(glyf, at + 4) else TableVar.i8(glyf, at + 4)
		a2 = if (words) TableVar.i16(glyf, at + 6) else TableVar.i8(glyf, at + 5)
		u1 = if (words) TableVar.u16(glyf, at + 4) else TableVar.u8(glyf, at + 4)
		u2 = if (words) TableVar.u16(glyf, at + 6) else TableVar.u8(glyf, at + 5)
		scale_at = at + (if (words) 8 else 6)
		f2 = |k| TableVar.f32_from_ratio(TableVar.i16(glyf, scale_at + 2 * k).to_i128(), 16384)
		one = TableVar.f32_one
		matrix =
			if flags.bitwise_and(0x0008) != 0 {
				[f2(0), 0, 0, f2(0)]
			} else if flags.bitwise_and(0x0040) != 0 {
				[f2(0), 0, 0, f2(1)]
			} else if flags.bitwise_and(0x0080) != 0 {
				[f2(0), f2(1), f2(2), f2(3)]
			} else {
				[one, 0, 0, one]
			}
		identity = TableVar.f32_eq(matrix.get(0) ?? 0, one) and TableVar.f32_eq(matrix.get(1) ?? 0, 0) and TableVar.f32_eq(matrix.get(2) ?? 0, 0) and TableVar.f32_eq(matrix.get(3) ?? 0, one)
		{
			glyph: TableVar.u16(glyf, at + 2),
			dx: if (anchored) 0 else a1,
			dy: if (anchored) 0 else a2,
			anchored,
			p1: u1,
			p2: u2,
			matrix,
			identity,
			scaled_offsets: flags.bitwise_and(0x1800) == 0x0800,
			use_my_metrics: flags.bitwise_and(0x0200) != 0,
			more: flags.bitwise_and(0x0020) != 0,
			next: at + TableGlyfPoints.record_size(glyf, at),
		}
	}

	## A glyph's extents at the default location, as HarfBuzz reports them
	## without variations: from the glyph header's box, with the left edge
	## taken from the `hmtx` side bearing. An empty glyph, or one past the
	## font, has none.
	extents_default : TableGlyfPoints, U64 -> Extents
	extents_default = |t, g| {
		if (t.kinds.get(g) ?? 0) == 0 {
			return { x_bearing: 0, y_bearing: 0, width: 0, height: 0 }
		}
		start = t.starts.get(g) ?? 0
		x0 = TableVar.i16(t.glyf, start + 2)
		y0 = TableVar.i16(t.glyf, start + 4)
		x1 = TableVar.i16(t.glyf, start + 6)
		y1 = TableVar.i16(t.glyf, start + 8)
		{
			x_bearing: TableGlyfPoints.side_bearing(t, g),
			y_bearing: y0.max(y1),
			width: x0.max(x1) - x0.min(x1),
			height: y0.min(y1) - y0.max(y1),
		}
	}
}
