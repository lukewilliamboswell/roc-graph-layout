import Drawing

## Edge lines as Mermaid 12 draws them in its default look: the route's
## bends rounded with a 5 pixel radius, a small semicircular hop where a
## horizontal run crosses a vertical one, the ends pulled back to make room
## for arrowheads, dotted lines as 2 pixel dashes, and arrowheads, circles
## and crosses at the ends.
FlowDrawEdge :: {}.{

	Point : Drawing.Point

	## One piece of a drawn edge, in drawing order.
	Piece : [
		Line({ from : Point, to : Point }),
		Quad({ from : Point, control : Point, to : Point }),
		Cubic({ from : Point, control_1 : Point, control_2 : Point, to : Point }),
	]

	End : [None, Arrow, Circle, Cross]

	## A hop over another edge: on the route's segment at `segment`, at
	## fraction `t` of its length, centred on `point`.
	Hop : { segment : U64, t : F64, point : Point }

	## Radius of rounded bends.
	bend_radius : F64
	bend_radius = 5

	## Radius of a hop.
	hop_radius : F64
	hop_radius = 6

	## How far the line's end point is pulled back along the route for an
	## end: Mermaid moves the route's end point itself only for arrows.
	pull_back : End -> F64
	pull_back = |end|
		match end {
			Arrow => 4
			_ => 0
		}

	## How much of the line next to an end is left undrawn, measured along
	## the line, so the line does not show under or past the end's mark.
	hidden : End -> F64
	hidden = |end|
		match end {
			None => 0
			Arrow => 4
			Circle => 12.5
			Cross => 12.5
		}

	## The route with its first and last points moved along their segments
	## by `pull_back`. A zero-length end segment moves along +x, as Mermaid's
	## angle of a zero vector is zero.
	shift_ends : List(Point), End, End -> List(Point)
	shift_ends = |points, start, end| {
		n = points.len()
		if n < 2 {
			points
		} else {
			first = points.get(0) ?? { x: 0, y: 0 }
			second = points.get(1) ?? first
			last = points.get(n - 1) ?? first
			before = points.get(n - 2) ?? last
			s = FlowDrawEdge.pull_back(start)
			e = FlowDrawEdge.pull_back(end)
			var $out = points
			if s > 0 {
				u = FlowDrawEdge.direction(first, second)
				$out = $out.set(0, { x: first.x + u.x * s, y: first.y + u.y * s }) ?? []
			}
			if e > 0 {
				u = FlowDrawEdge.direction(before, last)
				$out = $out.set(n - 1, { x: last.x - u.x * e, y: last.y - u.y * e }) ?? []
			}
			$out
		}
	}

	## Unit vector from `a` to `b`, or +x when they coincide.
	direction : Point, Point -> Point
	direction = |a, b| {
		dx = b.x - a.x
		dy = b.y - a.y
		len = (dx * dx + dy * dy).sqrt()
		if (len > 0 and F64.is_finite(len)) { x: dx / len, y: dy / len } else { x: 1, y: 0 }
	}

	## The rounded bend at `curr` between the segments from `prev` and to
	## `next`: where it leaves the first segment, where it joins the second,
	## and how far both are from the bend. `Err` when either segment is
	## empty or the route goes straight on or doubles back.
	bend : Point, Point, Point -> Try({ start : Point, end : Point, cut : F64 }, [Straight])
	bend = |prev, curr, next| {
		dx1 = curr.x - prev.x
		dy1 = curr.y - prev.y
		dx2 = next.x - curr.x
		dy2 = next.y - curr.y
		len1 = (dx1 * dx1 + dy1 * dy1).sqrt()
		len2 = (dx2 * dx2 + dy2 * dy2).sqrt()
		if !(len1 >= 1.0e-5) or !(len2 >= 1.0e-5) or !F64.is_finite(len1) or !F64.is_finite(len2) {
			Err(Straight)
		} else {
			nx1 = dx1 / len1
			ny1 = dy1 / len1
			nx2 = dx2 / len2
			ny2 = dy2 / len2
			dot = (nx1 * nx2 + ny1 * ny2).max(-1).min(1)
			# The angle between the directions is acos(dot); Mermaid skips
			# angles within 1e-5 of 0 or pi, where 1 - |dot| < 5e-11.
			if 1 - dot.abs() < 5.0e-11 {
				Err(Straight)
			} else {
				half_sine = ((1 - dot) / 2).sqrt()
				cut = (FlowDrawEdge.bend_radius / half_sine).min(len1 / 2).min(len2 / 2)
				Ok({ start: { x: curr.x - nx1 * cut, y: curr.y - ny1 * cut }, end: { x: curr.x + nx2 * cut, y: curr.y + ny2 * cut }, cut })
			}
		}
	}

	## The pieces Mermaid draws for a route (already pulled back at its
	## ends): straight runs, a quadratic curve at each bend, and a hop at
	## each crossing it gives way at.
	pieces : List(Point), List(Hop) -> List(Piece)
	pieces = |points, hops| {
		n = points.len()
		if n < 2 {
			[]
		} else {
			var $out = List.with_capacity(n * 2)
			var $cur = points.get(0) ?? { x: 0, y: 0 }
			for i in 0..<(n - 1) {
				a = points.get(i) ?? $cur
				b = points.get(i + 1) ?? a
				seg_len = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).sqrt()
				ux = if (seg_len > 0) (b.x - a.x) / seg_len else 0
				uy = if (seg_len > 0) (b.y - a.y) / seg_len else 0
				consumed = if i > 0 {
					match FlowDrawEdge.bend(points.get(i - 1) ?? a, a, b) {
						Ok(c) => c.cut
						Err(_) => 0
					}
				} else {
					0
				}
				upcoming = if i + 2 < n {
					FlowDrawEdge.bend(a, b, points.get(i + 2) ?? b)
				} else {
					Err(Straight)
				}
				stop = match upcoming {
					Ok(c) => seg_len - c.cut
					Err(_) => seg_len
				}
				horizontal = (b.x - a.x).abs() >= (b.y - a.y).abs()
				bump = if (horizontal) { x: 0, y: -1 } else { x: 1, y: 0 }
				for jump in FlowDrawEdge.fit_hops(hops.keep_if(|h| h.segment == i), seg_len, consumed, stop) {
					r = jump.r
					pre = { x: jump.point.x - ux * r, y: jump.point.y - uy * r }
					post = { x: jump.point.x + ux * r, y: jump.point.y + uy * r }
					apex = { x: jump.point.x + bump.x * r, y: jump.point.y + bump.y * r }
					$out = $out.append(Line({ from: $cur, to: pre }))
					$out = $out.append(FlowDrawEdge.quarter_piece(pre, { x: pre.x + bump.x * r, y: pre.y + bump.y * r }, apex))
					$out = $out.append(FlowDrawEdge.quarter_piece(apex, { x: post.x + bump.x * r, y: post.y + bump.y * r }, post))
					$cur = post
				}
				match upcoming {
					Ok(c) => {
						$out = $out.append(Line({ from: $cur, to: c.start }))
						$out = $out.append(Quad({ from: c.start, control: b, to: c.end }))
						$cur = c.end
					}
					Err(_) => {
						$out = $out.append(Line({ from: $cur, to: b }))
						$cur = b
					}
				}
			}
			$out
		}
	}

	quarter_piece : Point, Point, Point -> Piece
	quarter_piece = |from, corner, to|
		match Drawing.quarter(from, corner, to) {
			CubicTo(c) => Cubic({ from, control_1: c.control_1, control_2: c.control_2, to: c.end })
			_ => Line({ from, to })
		}

	## The hops on one segment that have room: each shrinks to stay 2 pixels
	## clear of the bends at either end and of its neighbours, and a hop
	## shrunk below 60% of its radius is left out.
	fit_hops : List(Hop), F64, F64, F64 -> List({ point : Point, r : F64 })
	fit_hops = |hops, seg_len, consumed, stop| {
		smallest = FlowDrawEdge.hop_radius * 0.6
		sorted = hops.sort_with(|a, b| if (a.t < b.t) Before else if (a.t > b.t) After else Same)
		var $kept = []
		for h in sorted {
			d = h.t * seg_len
			room = (d - consumed).min(stop - d) - 2
			r = FlowDrawEdge.hop_radius.min(room)
			if r >= smallest {
				$kept = $kept.append({ point: h.point, d, r })
			}
		}
		var $k = 0
		while $k + 1 < $kept.len() {
			a = $kept.get($k) ?? { point: { x: 0, y: 0 }, d: 0, r: 0 }
			b = $kept.get($k + 1) ?? a
			gap = b.d - a.d
			if a.r + b.r > gap {
				half = gap / 2
				$kept = $kept.set($k, { ..a, r: a.r.min(half) }) ?? []
				$kept = $kept.set($k + 1, { ..b, r: b.r.min(half) }) ?? []
			}
			$k = $k + 1
		}
		$kept.keep_if(|j| j.r >= smallest).map(|j| { point: j.point, r: j.r })
	}

	## For each route, the crossings where it hops over another route. Two
	## segments cross when they meet away from both their ends; when one is
	## horizontal and the other vertical, the horizontal one hops, otherwise
	## the later route does. Crossings inside a rounded bend of either route
	## are not hopped.
	hops : List(List(Point)) -> List(List(Hop))
	hops = |routes| {
		boxes = routes.map(FlowDrawEdge.extent)
		var $result = routes.map(|_| [])
		for i in 0..<routes.len() {
			a_points = routes.get(i) ?? []
			a_box = boxes.get(i) ?? FlowDrawEdge.empty_extent
			for j in (i + 1)..<routes.len() {
				b_box = boxes.get(j) ?? FlowDrawEdge.empty_extent
				if FlowDrawEdge.overlaps(a_box, b_box) {
					b_points = routes.get(j) ?? []
					for si in 0..<(a_points.len().max(1) - 1) {
						a1 = a_points.get(si) ?? { x: 0, y: 0 }
						a2 = a_points.get(si + 1) ?? a1
						for sj in 0..<(b_points.len().max(1) - 1) {
							b1 = b_points.get(sj) ?? { x: 0, y: 0 }
							b2 = b_points.get(sj + 1) ?? b1
							match FlowDrawEdge.cross(a1, a2, b1, b2) {
								Err(_) => {}
								Ok(hit) =>
									if !FlowDrawEdge.in_bend(a_points, si, hit.ta) and !FlowDrawEdge.in_bend(b_points, sj, hit.tb) {
										a_horizontal = (a2.x - a1.x).abs() >= (a2.y - a1.y).abs()
										b_horizontal = (b2.x - b1.x).abs() >= (b2.y - b1.y).abs()
										if a_horizontal != b_horizontal and a_horizontal {
											list = $result.get(i) ?? []
											$result = $result.set(i, list.append({ segment: si, t: hit.ta, point: hit.point })) ?? []
										} else {
											list = $result.get(j) ?? []
											$result = $result.set(j, list.append({ segment: sj, t: hit.tb, point: hit.point })) ?? []
										}
									}
							}
						}
					}
				}
			}
		}
		$result
	}

	Extent : { min_x : F64, min_y : F64, max_x : F64, max_y : F64 }

	empty_extent : Extent
	empty_extent = { min_x: 0, min_y: 0, max_x: -1, max_y: -1 }

	extent : List(Point) -> Extent
	extent = |points|
		match points.first() {
			Err(_) => FlowDrawEdge.empty_extent
			Ok(p) =>
				points.fold(
					{ min_x: p.x, min_y: p.y, max_x: p.x, max_y: p.y },
					|e, q| { min_x: e.min_x.min(q.x), min_y: e.min_y.min(q.y), max_x: e.max_x.max(q.x), max_y: e.max_y.max(q.y) },
				)
		}

	overlaps : Extent, Extent -> Bool
	overlaps = |a, b| a.min_x <= b.max_x and b.min_x <= a.max_x and a.min_y <= b.max_y and b.min_y <= a.max_y

	## Where two segments cross, strictly inside both.
	cross : Point, Point, Point, Point -> Try({ point : Point, ta : F64, tb : F64 }, [Apart])
	cross = |a1, a2, b1, b2| {
		dxa = a2.x - a1.x
		dya = a2.y - a1.y
		dxb = b2.x - b1.x
		dyb = b2.y - b1.y
		denom = dxa * dyb - dya * dxb
		if denom == 0 or !F64.is_finite(denom) {
			Err(Apart)
		} else {
			dx = b1.x - a1.x
			dy = b1.y - a1.y
			ta = (dx * dyb - dy * dxb) / denom
			tb = (dx * dya - dy * dxa) / denom
			eps = 1.0e-6
			if ta > eps and ta < 1 - eps and tb > eps and tb < 1 - eps {
				Ok({ point: { x: a1.x + ta * dxa, y: a1.y + ta * dya }, ta, tb })
			} else {
				Err(Apart)
			}
		}
	}

	## Whether fraction `t` of segment `index` lies where the drawn line has
	## left the route to round a bend.
	in_bend : List(Point), U64, F64 -> Bool
	in_bend = |points, index, t| {
		a = points.get(index) ?? { x: 0, y: 0 }
		b = points.get(index + 1) ?? a
		seg_len = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).sqrt()
		d = t * seg_len
		entering = if index > 0 {
			match FlowDrawEdge.bend(points.get(index - 1) ?? a, a, b) {
				Ok(c) => d < c.cut
				Err(_) => False
			}
		} else {
			False
		}
		leaving = if index + 2 < points.len() {
			match FlowDrawEdge.bend(a, b, points.get(index + 2) ?? b) {
				Ok(c) => seg_len - d < c.cut
				Err(_) => False
			}
		} else {
			False
		}
		entering or leaving
	}

	## Straight lines approximating a curved piece, as points after its
	## start.
	flatten : Piece -> List(Point)
	flatten = |piece| {
		steps : U64
		steps = 16
		match piece {
			Line(l) => [l.to]
			Quad(q) => {
				var $out = List.with_capacity(steps)
				for k in 1..<(steps + 1) {
					t = k.to_f64() / steps.to_f64()
					u = 1 - t
					$out = $out.append({ x: u * u * q.from.x + 2 * u * t * q.control.x + t * t * q.to.x, y: u * u * q.from.y + 2 * u * t * q.control.y + t * t * q.to.y })
				}
				$out
			}
			Cubic(c) => {
				var $out = List.with_capacity(steps)
				for k in 1..<(steps + 1) {
					t = k.to_f64() / steps.to_f64()
					u = 1 - t
					a = u * u * u
					b = 3 * u * u * t
					d = 3 * u * t * t
					e = t * t * t
					$out = $out.append({ x: a * c.from.x + b * c.control_1.x + d * c.control_2.x + e * c.to.x, y: a * c.from.y + b * c.control_1.y + d * c.control_2.y + e * c.to.y })
				}
				$out
			}
		}
	}

	start_of : Piece -> Point
	start_of = |piece|
		match piece {
			Line(l) => l.from
			Quad(q) => q.from
			Cubic(c) => c.from
		}

	end_of : Piece -> Point
	end_of = |piece|
		match piece {
			Line(l) => l.to
			Quad(q) => q.to
			Cubic(c) => c.to
		}

	distance : Point, Point -> F64
	distance = |a, b| ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).sqrt()

	## Length of a piece; curves are measured along their flattening.
	length : Piece -> F64
	length = |piece|
		match piece {
			Line(l) => FlowDrawEdge.distance(l.from, l.to)
			_ => {
				var $at = FlowDrawEdge.start_of(piece)
				var $sum = 0.0
				for p in FlowDrawEdge.flatten(piece) {
					$sum = $sum + FlowDrawEdge.distance($at, p)
					$at = p
				}
				$sum
			}
		}

	## The stretches of a line of length `total` that a stroke dash list
	## draws, as SVG does: entries alternate drawn and skipped lengths and
	## repeat (an odd-length list repeats twice over). A list with a
	## negative entry or no positive total draws the whole line.
	dashes : F64, List(F64) -> List({ from : F64, to : F64 })
	dashes = |total, pattern| {
		list = if (pattern.len() % 2 == 1) pattern.concat(pattern) else pattern
		sum = list.fold(0.0, |acc, v| acc + v)
		if list.is_empty() or list.any(|v| v < 0 or !F64.is_finite(v)) or !(sum > 0) {
			[{ from: 0, to: total }]
		} else {
			var $out = []
			var $pos = 0.0
			var $index = 0
			# Each step advances by an entry; a full cycle advances by `sum`.
			limit = list.len() * (((total / sum).max(0).min(100000) + 2).floor_to_u64_try() ?? 0)
			while $pos < total and $index < limit {
				len = list.get($index % list.len()) ?? 0
				if $index % 2 == 0 and len > 0 {
					$out = $out.append({ from: $pos, to: ($pos + len).min(total) })
				}
				$pos = $pos + len
				$index = $index + 1
			}
			$out
		}
	}

	## The path that draws only the given stretches of the pieces, each
	## stretch a separate part of the path. Pieces wholly inside a stretch
	## keep their curves; pieces cut by a stretch's ends are followed along
	## their flattening.
	trace : List(Piece), List({ from : F64, to : F64 }) -> List(Drawing.Segment)
	trace = |all, stretches| {
		lengths = all.map(FlowDrawEdge.length)
		var $out = []
		for stretch in stretches {
			if stretch.to > stretch.from {
				var $pos = 0.0
				var $started = False
				for index in 0..<all.len() {
					piece = all.get(index) ?? Line({ from: { x: 0, y: 0 }, to: { x: 0, y: 0 } })
					len = lengths.get(index) ?? 0
					s = $pos
					e = $pos + len
					if e >= stretch.from and s <= stretch.to and !(len == 0 and $started) {
						if s >= stretch.from and e <= stretch.to {
							if !$started {
								$out = $out.append(MoveTo(FlowDrawEdge.start_of(piece)))
								$started = True
							}
							$out = $out.append(FlowDrawEdge.segment_of(piece))
						} else {
							# Follow the flattening between the stretch's ends.
							var $at = FlowDrawEdge.start_of(piece)
							var $at_pos = s
							for p in FlowDrawEdge.flatten(piece) {
								step = FlowDrawEdge.distance($at, p)
								next_pos = $at_pos + step
								lo = $at_pos.max(stretch.from)
								hi = next_pos.min(stretch.to)
								if hi >= lo and (step > 0 or !$started) {
									from = FlowDrawEdge.lerp($at, p, if (step > 0) (lo - $at_pos) / step else 0)
									to = FlowDrawEdge.lerp($at, p, if (step > 0) (hi - $at_pos) / step else 0)
									if !$started {
										$out = $out.append(MoveTo(from))
										$started = True
									}
									$out = $out.append(LineTo(to))
								}
								$at = p
								$at_pos = next_pos
							}
						}
					}
					$pos = e
				}
			}
		}
		$out
	}

	lerp : Point, Point, F64 -> Point
	lerp = |a, b, t| { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t }

	segment_of : Piece -> Drawing.Segment
	segment_of = |piece|
		match piece {
			Line(l) => LineTo(l.to)
			Quad(q) =>
				CubicTo({
					control_1: { x: q.from.x + 2 / 3 * (q.control.x - q.from.x), y: q.from.y + 2 / 3 * (q.control.y - q.from.y) },
					control_2: { x: q.to.x + 2 / 3 * (q.control.x - q.to.x), y: q.to.y + 2 / 3 * (q.control.y - q.to.y) },
					end: q.to,
				})
			Cubic(c) => CubicTo({ control_1: c.control_1, control_2: c.control_2, end: c.to })
		}

	## The direction a piece leaves its start in, if it has one.
	start_tangent : Piece -> Try(Point, [Flat])
	start_tangent = |piece| {
		candidates = match piece {
			Line(l) => [{ a: l.from, b: l.to }]
			Quad(q) => [{ a: q.from, b: q.control }, { a: q.from, b: q.to }]
			Cubic(c) => [{ a: c.from, b: c.control_1 }, { a: c.from, b: c.control_2 }, { a: c.from, b: c.to }]
		}
		FlowDrawEdge.first_direction(candidates)
	}

	## The direction a piece arrives at its end in, if it has one.
	end_tangent : Piece -> Try(Point, [Flat])
	end_tangent = |piece| {
		candidates = match piece {
			Line(l) => [{ a: l.from, b: l.to }]
			Quad(q) => [{ a: q.control, b: q.to }, { a: q.from, b: q.to }]
			Cubic(c) => [{ a: c.control_2, b: c.to }, { a: c.control_1, b: c.to }, { a: c.from, b: c.to }]
		}
		FlowDrawEdge.first_direction(candidates)
	}

	first_direction : List({ a : Point, b : Point }) -> Try(Point, [Flat])
	first_direction = |candidates|
		match candidates.find_first(|c| FlowDrawEdge.distance(c.a, c.b) > 1.0e-9) {
			Ok(c) => Ok(FlowDrawEdge.direction(c.a, c.b))
			Err(_) => Err(Flat)
		}

	## Where the drawn edge starts and ends and the directions it runs in
	## there, skipping empty pieces as SVG markers do.
	ends : List(Piece) -> Try({ start : Point, start_dir : Point, end : Point, end_dir : Point }, [Empty])
	ends = |all|
		match (all.first(), all.last()) {
			(Ok(first), Ok(last)) => {
				forward = all.find_first(|p| FlowDrawEdge.start_tangent(p).is_ok())
				backward = all.find_last(|p| FlowDrawEdge.end_tangent(p).is_ok())
				start_dir = match forward {
					Ok(p) => FlowDrawEdge.start_tangent(p) ?? { x: 1, y: 0 }
					Err(_) => { x: 1, y: 0 }
				}
				end_dir = match backward {
					Ok(p) => FlowDrawEdge.end_tangent(p) ?? { x: 1, y: 0 }
					Err(_) => { x: 1, y: 0 }
				}
				Ok({ start: FlowDrawEdge.start_of(first), start_dir, end: FlowDrawEdge.end_of(last), end_dir })
			}
			_ => Err(Empty)
		}

	## The parts of a path inside a box, as separate straight pieces;
	## curves are followed along their flattening.
	clip : List(Drawing.Segment), Drawing.Rect -> List(Drawing.Segment)
	clip = |path, box| {
		var $out = []
		var $at = { x: 0, y: 0 }
		var $start = { x: 0, y: 0 }
		for segment in path {
			stops = match segment {
				MoveTo(p) => {
					$at = p
					$start = p
					[]
				}
				LineTo(p) => [p]
				CubicTo(c) => FlowDrawEdge.flatten(Cubic({ from: $at, control_1: c.control_1, control_2: c.control_2, to: c.end }))
				Close => [$start]
			}
			for p in stops {
				match FlowDrawEdge.clip_line($at, p, box) {
					Ok(part) => {
						$out = $out.append(MoveTo(part.from)).append(LineTo(part.to))
					}
					Err(_) => {}
				}
				$at = p
			}
		}
		$out
	}

	## The part of a straight line inside a box (Liang and Barsky).
	clip_line : Point, Point, Drawing.Rect -> Try({ from : Point, to : Point }, [Outside])
	clip_line = |a, b, box| {
		dx = b.x - a.x
		dy = b.y - a.y
		checks = [
			(0 - dx, a.x - box.x),
			(dx, box.x + box.width - a.x),
			(0 - dy, a.y - box.y),
			(dy, box.y + box.height - a.y),
		]
		var $lo = 0.0
		var $hi = 1.0
		var $inside = True
		for (p, q) in checks {
			if p == 0 {
				if q < 0 {
					$inside = False
				}
			} else {
				r = q / p
				if p < 0 {
					$lo = $lo.max(r)
				} else {
					$hi = $hi.min(r)
				}
			}
		}
		if $inside and $lo < $hi and F64.is_finite($lo) and F64.is_finite($hi) {
			Ok({ from: FlowDrawEdge.lerp(a, b, $lo), to: FlowDrawEdge.lerp(a, b, $hi) })
		} else {
			Err(Outside)
		}
	}

	## The mark at one end of an edge, placed at `at` on a line running in
	## direction `dir` (the direction of travel from start to end).
	## Coordinates follow Mermaid's margin markers: `along` runs with the
	## line, `across` to its left in screen terms.
	Mark : [Filled(List(Drawing.Segment)), Stroked({ path : List(Drawing.Segment), width : F64 }), Disc(List(Drawing.Segment))]

	mark : End, [Start, Finish], Point, Point -> List(Mark)
	mark = |end, which, at, dir| {
		place = |along, across| { x: at.x + dir.x * along - dir.y * across, y: at.y + dir.y * along + dir.x * across }
		match (end, which) {
			(None, _) => []
			(Arrow, Finish) => {
				s = 10.5 / 11.5
				[Filled(Drawing.polygon([place(-11.5 * s, -7 * s), place(0, 0), place(-11.5 * s, 7 * s)]))]
			}
			(Arrow, Start) => [Filled(Drawing.polygon([place(-1, 0), place(10.5, 7), place(10.5, -7)]))]
			(Circle, Finish) => [Disc(Drawing.ellipse(place(-10.15, 0), 7, 7))]
			(Circle, Start) => [Disc(Drawing.ellipse(place(9.8, 0), 7, 7))]
			(Cross, Finish) => {
				path = [MoveTo(place(-13.36, -5.2)), LineTo(place(-2.96, 5.2)), MoveTo(place(-13.36, 5.2)), LineTo(place(-2.96, -5.2))]
				[Stroked({ path, width: 2 })]
			}
			(Cross, Start) => {
				path = [MoveTo(place(3.6, -5.2)), LineTo(place(14, 5.2)), MoveTo(place(3.6, 5.2)), LineTo(place(14, -5.2))]
				[Stroked({ path, width: 2 })]
			}
		}
	}
}

expect FlowDrawEdge.shift_ends([{ x: 0, y: 0 }, { x: 0, y: 10 }], None, Arrow) == [{ x: 0, y: 0 }, { x: 0, y: 6 }]
expect FlowDrawEdge.shift_ends([{ x: 3, y: 3 }, { x: 3, y: 3 }], Arrow, None) == [{ x: 7, y: 3 }, { x: 3, y: 3 }]

## A right-angle bend is cut 5 / sin(45 degrees) from the corner.
expect
	match FlowDrawEdge.bend({ x: 0, y: 0 }, { x: 0, y: 40 }, { x: 40, y: 40 }) {
		Ok(c) => (c.cut - 7.0710678118654755).abs() < 1.0e-12
		Err(_) => False
	}

expect FlowDrawEdge.pieces([{ x: 0, y: 0 }, { x: 10, y: 0 }], []) == [Line({ from: { x: 0, y: 0 }, to: { x: 10, y: 0 } })]
expect FlowDrawEdge.pieces([{ x: 0, y: 0 }, { x: 0, y: 40 }, { x: 40, y: 40 }], []).len() == 3

expect FlowDrawEdge.dashes(10, [0, 4, 2, 4]) == [{ from: 4, to: 6 }]
expect FlowDrawEdge.dashes(10, [0, 0]) == [{ from: 0, to: 10 }]
expect FlowDrawEdge.dashes(10, [2, -1]) == [{ from: 0, to: 10 }]
expect FlowDrawEdge.dashes(5, [2]) == [{ from: 0, to: 2 }, { from: 4, to: 5 }]

## A horizontal run crossing a vertical one hops over it.
expect {
	found = FlowDrawEdge.hops([[{ x: 50, y: 0 }, { x: 50, y: 100 }], [{ x: 0, y: 50 }, { x: 100, y: 50 }]])
	found == [[], [{ segment: 0, t: 0.5, point: { x: 50, y: 50 } }]]
}

## Edges that only touch at an end do not hop.
expect FlowDrawEdge.hops([[{ x: 0, y: 0 }, { x: 10, y: 0 }], [{ x: 10, y: 0 }, { x: 10, y: 10 }]]) == [[], []]

expect {
	path = FlowDrawEdge.trace([Line({ from: { x: 0, y: 0 }, to: { x: 10, y: 0 } })], [{ from: 2, to: 4 }, { from: 6, to: 8 }])
	path == [MoveTo({ x: 2, y: 0 }), LineTo({ x: 4, y: 0 }), MoveTo({ x: 6, y: 0 }), LineTo({ x: 8, y: 0 })]
}

expect FlowDrawEdge.clip_line({ x: -5, y: 5 }, { x: 15, y: 5 }, { x: 0, y: 0, width: 10, height: 10 }) == Ok({ from: { x: 0, y: 5 }, to: { x: 10, y: 5 } })
expect FlowDrawEdge.clip_line({ x: -5, y: 20 }, { x: 15, y: 20 }, { x: 0, y: 0, width: 10, height: 10 }) == Err(Outside)
