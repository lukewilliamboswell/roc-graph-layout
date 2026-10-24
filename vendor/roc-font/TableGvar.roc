import TableVar
import TableGlyfPoints

## Glyph variations (`gvar`): how each glyph's points move between masters,
## and glyph extents (ink boxes) at any location of a variable font.
##
## Internal. Reading checks the header against `fvar` and `maxp`, the
## shared tuples, the glyph data offsets (ascending and inside the table)
## and every glyph's variation data: tuple headers, shared and private
## point numbers (each naming a point of the glyph, counting its four
## phantom points), and packed deltas, all inside their data. It then
## checks the work any glyph can cost with its tuples applied
## (`TableGlyfPoints.check_work`). After a successful read every query here
## is total.
##
## Numbers follow HarfBuzz 14.6.0 bit for bit. HarfBuzz computes a tuple's
## scalar in double precision (`TupleVariationHeader::calculate_scalar`)
## and converts it to `float`; moves points by `delta * scalar` in single
## precision; infers deltas of untouched points in single precision
## (`infer_delta`); transforms composite components in single precision;
## and rounds the box's edges half up. This module evaluates the same
## operations in the same order on bit patterns: binary64 in `U64` for the
## scalar, binary32 in `U32` (through `TableVar`) for the rest, with integer
## arithmetic only. Every value stays finite: coordinates and deltas are
## bounded by the formats, and scalars lie in [0, 1].
TableGvar := {
	bytes : List(U8),
	axis_count : U64,
	shared_count : U64,
	shared_at : U64,
	data_at : U64,
	long_offsets : Bool,
	# 0 for a font without gvar: no glyph varies.
	glyph_count : U64,
}.{

	Problem : TableGlyfPoints.Problem

	## What a location needs, computed once: the normalised coordinates
	## (F2Dot14), whether any is not zero, and the single-precision scalar
	## of every shared tuple used without an intermediate region.
	Location : { coords : List(I64), nonzero : Bool, shared : List(U32) }

	Extents : TableGlyfPoints.Extents

	## No glyph variations: points stay where `glyf` puts them.
	absent : TableGvar
	absent = { bytes: [], axis_count: 0, shared_count: 0, shared_at: 0, data_at: 0, long_offsets: False, glyph_count: 0 }

	# ------------------------------------------------------------ reading

	## Read `gvar` for a font with `axis_count` axes and the outlines
	## `glyf`. Every independent problem is reported.
	read : List(U8), U64, TableGlyfPoints -> Try(TableGvar, List(Problem))
	read = |bytes, axis_count, glyf| {
		bad = |at, reason| Err([{ table: "gvar", offset: at, reason }])
		size = bytes.len()
		glyph_count = TableGlyfPoints.glyph_total(glyf)
		if size < 20 {
			return bad(0, Truncated)
		}
		if TableVar.u16(bytes, 0) != 1 {
			return bad(0, UnsupportedVersion)
		}
		if TableVar.u16(bytes, 4) != axis_count {
			return bad(4, AxisCountMismatch)
		}
		if TableVar.u16(bytes, 12) != glyph_count {
			return bad(12, GlyphCountMismatch)
		}
		shared_count = TableVar.u16(bytes, 6)
		shared_at = TableVar.u32(bytes, 8)
		long_offsets = TableVar.u16(bytes, 14).bitwise_and(1) != 0
		data_at = TableVar.u32(bytes, 16)
		entry = if (long_offsets) 4 else 2
		if !TableVar.fits(shared_at, 2 * axis_count * shared_count, size) {
			return bad(8, Truncated)
		}
		if !TableVar.fits(20, entry * (glyph_count + 1), size) {
			return bad(20, Truncated)
		}
		gvar = { bytes, axis_count, shared_count, shared_at, data_at, long_offsets, glyph_count }
		var $problems = []
		var $tuples = List.with_capacity(glyph_count)
		for g in 0..<glyph_count {
			start = TableGvar.offset(gvar, g)
			end = TableGvar.offset(gvar, g + 1)
			at = 20 + entry * (g + 1)
			if end < start {
				$problems = $problems.append({ table: "gvar", offset: at, reason: OffsetOrder })
				$tuples = $tuples.append(0)
			} else if !TableVar.fits(data_at, end, size) {
				$problems = $problems.append({ table: "gvar", offset: at, reason: Truncated })
				$tuples = $tuples.append(0)
			} else if end == start {
				$tuples = $tuples.append(0)
			} else if end - start < 4 {
				$problems = $problems.append({ table: "gvar", offset: data_at + start, reason: TooShort })
				$tuples = $tuples.append(0)
			} else {
				points = TableGlyfPoints.point_count(glyf, g) + 4
				match TableGvar.check_glyph(gvar, data_at + start, data_at + end, points) {
					Ok(n) => {
						$tuples = $tuples.append(n)
					}
					Err((offset, reason)) => {
						$problems = $problems.append({ table: "gvar", offset, reason })
						$tuples = $tuples.append(0)
					}
				}
			}
		}
		if !$problems.is_empty() {
			return Err($problems)
		}
		TableGlyfPoints.check_work(glyf, $tuples)?
		Ok(gvar)
	}

	# The offset of glyph g's variation data from the start of the data.
	offset : TableGvar, U64 -> U64
	offset = |gvar, g| if (gvar.long_offsets) TableVar.u32(gvar.bytes, 20 + 4 * g) else 2 * TableVar.u16(gvar.bytes, 20 + 2 * g)

	# The size of the tuple variation header at `at`.
	header_size : TableGvar, U64 -> U64
	header_size = |gvar, at| {
		index = TableVar.u16(gvar.bytes, at + 2)
		tuples = (if (index.bitwise_and(0x8000) != 0) 1 else 0) + (if (index.bitwise_and(0x4000) != 0) 2 else 0)
		4 + 2 * gvar.axis_count * tuples
	}

	# Check one glyph's variation data in bytes[start, end) for a glyph of
	# `points` points (phantom points included), giving its tuple count.
	check_glyph : TableGvar, U64, U64, U64 -> Try(U64, (U64, TableGlyfPoints.Reason))
	check_glyph = |gvar, start, end, points| {
		bytes = gvar.bytes
		field = TableVar.u16(bytes, start)
		count = field.bitwise_and(0x0FFF)
		if field == 0 {
			return Ok(0)
		}
		serial = start + TableVar.u16(bytes, start + 2)
		if serial > end {
			return Err((start + 2, Truncated))
		}
		data_start =
			if field.bitwise_and(0x8000) != 0 {
				match TableGvar.check_points(bytes, serial, end, points) {
					Ok(next) => next
					Err(e) => return Err(e)
				}
			} else {
				serial
			}
		var $header = start + 4
		var $data = data_start
		for _t in 0..<count {
			if !TableVar.fits($header, 4, end) or !TableVar.fits($header, TableGvar.header_size(gvar, $header), end) {
				return Err(($header, Truncated))
			}
			index = TableVar.u16(bytes, $header + 2)
			if index.bitwise_and(0x8000) == 0 and index.bitwise_and(0x0FFF) >= gvar.shared_count {
				return Err(($header + 2, TupleIndex))
			}
			data_size = TableVar.u16(bytes, $header)
			if !TableVar.fits($data, data_size, end) {
				return Err(($header, Truncated))
			}
			tuple_end = $data + data_size
			deltas_at =
				if index.bitwise_and(0x2000) != 0 {
					match TableGvar.check_points(bytes, $data, tuple_end, points) {
						Ok(next) => next
						Err(e) => return Err(e)
					}
				} else {
					$data
				}
			# A private point list of no points, like no list, means all.
			named = if (index.bitwise_and(0x2000) != 0) TableGvar.point_total(bytes, $data) else if (field.bitwise_and(0x8000) != 0) TableGvar.point_total(bytes, serial) else 0
			n = if (named == 0) points else named
			match TableGvar.check_values(bytes, deltas_at, tuple_end, n) {
				Ok(next) =>
					match TableGvar.check_values(bytes, next, tuple_end, n) {
						Ok(_) => {}
						Err(e) => return Err(e)
					}
				Err(e) => return Err(e)
			}
			$header = $header + TableGvar.header_size(gvar, $header)
			$data = tuple_end
		}
		Ok(count)
	}

	# The number of points a packed point list at `at` names (0 for all).
	point_total : List(U8), U64 -> U64
	point_total = |bytes, at| {
		first = TableVar.u8(bytes, at)
		if (first.bitwise_and(0x80) != 0) first.bitwise_and(0x7F) * 256 + TableVar.u8(bytes, at + 1) else first
	}

	# Check packed point numbers in bytes[at, end), each below `points`,
	# giving the offset after them.
	check_points : List(U8), U64, U64, U64 -> Try(U64, (U64, TableGlyfPoints.Reason))
	check_points = |bytes, at, end, points| {
		if at >= end {
			return Err((at, Truncated))
		}
		first = TableVar.u8(bytes, at)
		if first.bitwise_and(0x80) != 0 and at + 1 >= end {
			return Err((at, Truncated))
		}
		count = TableGvar.point_total(bytes, at)
		var $p = if (first.bitwise_and(0x80) != 0) at + 2 else at + 1
		var $i = 0
		var $n = 0
		# Every run names at least one point, so the count bounds the walk.
		while $i < count {
			if $p >= end {
				return Err(($p, Truncated))
			}
			control = TableVar.u8(bytes, $p)
			run = control.bitwise_and(0x7F) + 1
			if $i + run > count {
				return Err(($p, RunCount))
			}
			words = control.bitwise_and(0x80) != 0
			width = if (words) 2 else 1
			if !TableVar.fits($p + 1, width * run, end) {
				return Err(($p, Truncated))
			}
			for k in 0..<run {
				$n = $n + (if (words) TableVar.u16(bytes, $p + 1 + 2 * k) else TableVar.u8(bytes, $p + 1 + k))
				if $n >= points {
					return Err(($p + 1 + width * k, PointIndex))
				}
			}
			$p = $p + 1 + width * run
			$i = $i + run
		}
		Ok($p)
	}

	# Check `count` packed deltas in bytes[at, end), giving the offset after.
	check_values : List(U8), U64, U64, U64 -> Try(U64, (U64, TableGlyfPoints.Reason))
	check_values = |bytes, at, end, count| {
		var $p = at
		var $i = 0
		# Every run holds at least one value, so the count bounds the walk.
		while $i < count {
			if $p >= end {
				return Err(($p, Truncated))
			}
			control = TableVar.u8(bytes, $p)
			run = control.bitwise_and(0x3F) + 1
			if $i + run > count {
				return Err(($p, RunCount))
			}
			width = TableGvar.value_width(control)
			if !TableVar.fits($p + 1, width * run, end) {
				return Err(($p, Truncated))
			}
			$p = $p + 1 + width * run
			$i = $i + run
		}
		Ok($p)
	}

	value_width : U64 -> U64
	value_width = |control| {
		size = control.bitwise_and(0xC0)
		if (size == 0x80) 0 else if (size == 0x40) 2 else if (size == 0xC0) 4 else 1
	}

	# ------------------------------------------------------------ decoding

	# The point numbers of a validated packed list at `at` (empty for all)
	# and the offset after it.
	points_at : List(U8), U64 -> { points : List(U64), next : U64 }
	points_at = |bytes, at| {
		first = TableVar.u8(bytes, at)
		count = TableGvar.point_total(bytes, at)
		var $p = if (first.bitwise_and(0x80) != 0) at + 2 else at + 1
		var $out = List.with_capacity(count)
		var $n = 0
		while $out.len() < count {
			control = TableVar.u8(bytes, $p)
			run = control.bitwise_and(0x7F) + 1
			words = control.bitwise_and(0x80) != 0
			for k in 0..<run {
				$n = $n + (if (words) TableVar.u16(bytes, $p + 1 + 2 * k) else TableVar.u8(bytes, $p + 1 + k))
				$out = $out.append($n)
			}
			$p = $p + 1 + (if (words) 2 else 1) * run
		}
		{ points: $out, next: $p }
	}

	# `count` validated packed deltas at `at`, and the offset after them.
	values_at : List(U8), U64, U64 -> { values : List(I64), next : U64 }
	values_at = |bytes, at, count| {
		var $p = at
		var $out = List.with_capacity(count)
		while $out.len() < count {
			control = TableVar.u8(bytes, $p)
			run = control.bitwise_and(0x3F) + 1
			width = TableGvar.value_width(control)
			for k in 0..<run {
				v =
					if width == 0 {
						0
					} else if width == 1 {
						TableVar.i8(bytes, $p + 1 + k)
					} else if width == 2 {
						TableVar.i16(bytes, $p + 1 + 2 * k)
					} else {
						TableVar.i32(bytes, $p + 1 + 4 * k)
					}
				$out = $out.append(v)
			}
			$p = $p + 1 + width * run
		}
		{ values: $out, next: $p }
	}

	# ------------------------------------------------------------ locations

	## The state of a location given normalised coordinates (F2Dot14, one
	## per axis, as `TableVar.coords_for` gives them).
	location : TableGvar, List(I16) -> Location
	location = |gvar, coords| {
		c = coords.map(|v| v.to_i64())
		nonzero = c.any(|v| v != 0)
		var $shared = List.with_capacity(gvar.shared_count)
		if nonzero {
			for k in 0..<gvar.shared_count {
				$shared = $shared.append(TableGvar.tuple_scalar(gvar, c, gvar.shared_at + 2 * gvar.axis_count * k, Absent))
			}
		}
		{ coords: c, nonzero, shared: $shared }
	}

	## A tuple's scalar as HarfBuzz computes it: in double precision, axis
	## by axis, then converted to single precision. `peak_at` is the peak
	## tuple's offset; `Intermediate(at)` the start tuple's, the end tuple
	## following it. The order of the tests is HarfBuzz's: an axis whose
	## peak is 0 is skipped; a coordinate of 0 makes the scalar 0; a
	## malformed intermediate region (start after peak, peak after end, or
	## a range across zero) leaves the axis out.
	tuple_scalar : TableGvar, List(I64), U64, [Intermediate(U64), Absent] -> U32
	tuple_scalar = |gvar, coords, peak_at, region| {
		bytes = gvar.bytes
		axes = gvar.axis_count
		var $s = TableGvar.f64_one
		var $a = 0
		while $a < axes {
			peak = TableVar.i16(bytes, peak_at + 2 * $a)
			v = coords.get($a) ?? 0
			if peak != 0 and v != peak {
				if v == 0 {
					return 0
				}
				match region {
					Intermediate(at) => {
						start = TableVar.i16(bytes, at + 2 * $a)
						end = TableVar.i16(bytes, at + 2 * (axes + $a))
						if start > peak or peak > end or (start < 0 and end > 0) {
							{}
						} else if v < start or v > end {
							return 0
						} else if v < peak {
							if peak != start {
								$s = TableGvar.f64_mul($s, TableGvar.f64_ratio(v - start, peak - start))
							}
						} else if peak != end {
							$s = TableGvar.f64_mul($s, TableGvar.f64_ratio(end - v, end - peak))
						}
					}
					Absent => {
						if v < peak.min(0) or v > peak.max(0) {
							return 0
						}
						$s = TableGvar.f64_mul($s, TableGvar.f64_ratio(v, peak))
					}
				}
			}
			$a = $a + 1
		}
		TableGvar.f64_to_f32($s)
	}

	# ------------------------------------------------------------ applying deltas

	## Move one glyph's points (phantom points included, last) by its
	## variations at a location, exactly as HarfBuzz's
	## `apply_deltas_to_points`. `ends` marks contour end points; untouched
	## points of a contour take deltas inferred from their touched
	## neighbours. A glyph without variation data keeps its points.
	apply : TableGvar, Location, U64, List(U32), List(U32), List(Bool) -> { xs : List(U32), ys : List(U32) }
	apply = |gvar, loc, g, xs_in, ys_in, ends| {
		if g >= gvar.glyph_count or !loc.nonzero {
			return { xs: xs_in, ys: ys_in }
		}
		bytes = gvar.bytes
		start = gvar.data_at + TableGvar.offset(gvar, g)
		if TableGvar.offset(gvar, g + 1) == TableGvar.offset(gvar, g) {
			return { xs: xs_in, ys: ys_in }
		}
		field = TableVar.u16(bytes, start)
		tuple_count = field.bitwise_and(0x0FFF)
		if tuple_count == 0 {
			return { xs: xs_in, ys: ys_in }
		}
		count = xs_in.len()
		serial = start + TableVar.u16(bytes, start + 2)
		shared_points =
			if field.bitwise_and(0x8000) != 0 {
				TableGvar.points_at(bytes, serial)
			} else {
				{ points: [], next: serial }
			}
		# The scalar, flags and data offset of every tuple.
		var $scalars = List.with_capacity(tuple_count)
		var $indexes = List.with_capacity(tuple_count)
		var $datas = List.with_capacity(tuple_count)
		var $header = start + 4
		var $data = shared_points.next
		for _t in 0..<tuple_count {
			index = TableVar.u16(bytes, $header + 2)
			region = if (index.bitwise_and(0x4000) != 0) Intermediate($header + 4 + (if (index.bitwise_and(0x8000) != 0) 2 * gvar.axis_count else 0)) else Absent
			scalar =
				if index.bitwise_and(0x8000) != 0 {
					TableGvar.tuple_scalar(gvar, loc.coords, $header + 4, region)
				} else if index.bitwise_and(0x4000) != 0 {
					TableGvar.tuple_scalar(gvar, loc.coords, gvar.shared_at + 2 * gvar.axis_count * index.bitwise_and(0x0FFF), region)
				} else {
					loc.shared.get(index.bitwise_and(0x0FFF)) ?? 0
				}
			$scalars = $scalars.append(scalar)
			$indexes = $indexes.append(index)
			$datas = $datas.append($data)
			$data = $data + TableVar.u16(bytes, $header)
			$header = $header + TableGvar.header_size(gvar, $header)
		}
		# HarfBuzz looks for private point numbers from the first tuple that
		# applies onwards, and takes a faster path without them.
		var $first = tuple_count
		var $t = 0
		while $t < tuple_count {
			if TableGvar.f32_zero($scalars.get($t) ?? 0) {
				$t = $t + 1
			} else {
				$first = $t
				$t = tuple_count
			}
		}
		var $any_private = False
		for k in $first..<tuple_count {
			if ($indexes.get(k) ?? 0).bitwise_and(0x2000) != 0 {
				$any_private = True
			}
		}
		var $xs = xs_in
		var $ys = ys_in
		var $dx = List.repeat(0.U32, count)
		var $dy = List.repeat(0.U32, count)
		var $touched = List.repeat(False, count)
		var $orig_x = []
		var $orig_y = []
		var $have_orig = False
		var $flush = False
		for k in $first..<tuple_count {
			scalar = $scalars.get(k) ?? 0
			index = $indexes.get(k) ?? 0
			if !TableGvar.f32_zero(scalar) {
				at = $datas.get(k) ?? 0
				private = index.bitwise_and(0x2000) != 0
				listed = if (private) TableGvar.points_at(bytes, at) else shared_points
				deltas_at = if (private) listed.next else at
				all = listed.points.is_empty()
				n = if (all) count else listed.points.len()
				xd = TableGvar.values_at(bytes, deltas_at, n)
				yd = TableGvar.values_at(bytes, xd.next, n)
				if all and !$any_private {
					for i in 0..<count {
						# i is below the point count, which is the length of every list here.
						$xs = $xs.set(i, TableGvar.move_by($xs.get(i) ?? 0, xd.values.get(i) ?? 0, scalar)) ?? []
					}
					for i in 0..<count {
						$ys = $ys.set(i, TableGvar.move_by($ys.get(i) ?? 0, yd.values.get(i) ?? 0, scalar)) ?? []
					}
				} else {
					if !all {
						if !$have_orig {
							$orig_x = $xs
							$orig_y = $ys
							$have_orig = True
						}
						if $flush {
							for i in 0..<count {
								$xs = $xs.set(i, TableGvar.shifted($xs.get(i) ?? 0, $dx.get(i) ?? 0)) ?? []
								$ys = $ys.set(i, TableGvar.shifted($ys.get(i) ?? 0, $dy.get(i) ?? 0)) ?? []
							}
						}
						$dx = List.repeat(0.U32, count)
						$dy = List.repeat(0.U32, count)
						$touched = List.repeat(False, count)
					}
					for i in 0..<n {
						# Point numbers were checked below the point count.
						p = if (all) i else listed.points.get(i) ?? 0
						if !all {
							$touched = $touched.set(p, True) ?? []
						}
						$dx = $dx.set(p, TableGvar.move_by($dx.get(p) ?? 0, xd.values.get(i) ?? 0, scalar)) ?? []
						$dy = $dy.set(p, TableGvar.move_by($dy.get(p) ?? 0, yd.values.get(i) ?? 0, scalar)) ?? []
					}
					if !all {
						inferred = TableGvar.infer($orig_x, $orig_y, $dx, $dy, $touched, ends)
						$dx = inferred.dx
						$dy = inferred.dy
					}
					$flush = True
				}
			}
		}
		if $flush {
			for i in 0..<count {
				$xs = $xs.set(i, TableGvar.shifted($xs.get(i) ?? 0, $dx.get(i) ?? 0)) ?? []
				$ys = $ys.set(i, TableGvar.shifted($ys.get(i) ?? 0, $dy.get(i) ?? 0)) ?? []
			}
		}
		{ xs: $xs, ys: $ys }
	}

	f32_zero : U32 -> Bool
	f32_zero = |x| x.bitwise_and(0x7FFFFFFF) == 0

	# HarfBuzz's `v += delta * scalar` in single precision. A zero delta is
	# skipped: adding its zero product leaves the value equal (it can only
	# turn -0 into +0, which no later comparison or rounding tells apart).
	move_by : U32, I64, U32 -> U32
	move_by = |v, delta, scalar| if (delta == 0) v else TableVar.f32_add(v, TableVar.f32_mul(TableVar.f32_from_int(delta), scalar))

	# v + d in single precision, skipping a zero d as `move_by` does.
	shifted : U32, U32 -> U32
	shifted = |v, d| if (TableGvar.f32_zero(d)) v else TableVar.f32_add(v, d)

	# Inferred deltas for untouched points, contour by contour: each takes
	# HarfBuzz's `infer_delta` from the touched points before and after it
	# around the contour. A contour with no touched point, or no untouched
	# one, is left alone; points after the last contour end (the phantom
	# points) are never inferred.
	infer : List(U32), List(U32), List(U32), List(U32), List(Bool), List(Bool) -> { dx : List(U32), dy : List(U32) }
	infer = |ox, oy, dx_in, dy_in, touched, ends| {
		count = ends.len()
		var $dx = dx_in
		var $dy = dy_in
		var $start = 0
		var $end = 0
		while $end < count {
			if !(ends.get($end) ?? False) {
				$end = $end + 1
			} else {
				len = $end - $start + 1
				var $refs = 0
				var $first = count
				for i in $start..=$end {
					if touched.get(i) ?? False {
						$refs = $refs + 1
						if $first == count {
							$first = i
						}
					}
				}
				if $refs > 0 and $refs < len {
					# Walk once around the contour from the first touched point.
					var $prev = $first
					for step in 1..=len {
						q = $start + ($first - $start + step) % len
						if touched.get(q) ?? False {
							# Fill the gap strictly between prev and q. Touched
							# deltas do not change while the gap is filled.
							pxv = ox.get($prev) ?? 0
							nxv = ox.get(q) ?? 0
							pyv = oy.get($prev) ?? 0
							nyv = oy.get(q) ?? 0
							pxd = $dx.get($prev) ?? 0
							nxd = $dx.get(q) ?? 0
							pyd = $dy.get($prev) ?? 0
							nyd = $dy.get(q) ?? 0
							var $j = $start + ($prev - $start + 1) % len
							while $j != q {
								# j lies in the contour, below the point count.
								$dx = $dx.set($j, TableGvar.infer_delta(ox.get($j) ?? 0, pxv, nxv, pxd, nxd)) ?? []
								$dy = $dy.set($j, TableGvar.infer_delta(oy.get($j) ?? 0, pyv, nyv, pyd, nyd)) ?? []
								$j = $start + ($j - $start + 1) % len
							}
							$prev = q
						}
					}
				}
				$start = $end + 1
				$end = $end + 1
			}
		}
		{ dx: $dx, dy: $dy }
	}

	# HarfBuzz's `infer_delta` for one coordinate, in single precision: the
	# untouched point's original coordinate `t`, and the original
	# coordinates and deltas of the touched points before and after it.
	infer_delta : U32, U32, U32, U32, U32 -> U32
	infer_delta = |t, pv, nv, pd, nd|
		if TableVar.f32_eq(pv, nv) {
			if (TableVar.f32_eq(pd, nd)) pd else 0
		} else if !TableVar.f32_lt(TableVar.f32_min(pv, nv), t) {
			if (TableVar.f32_lt(pv, nv)) pd else nd
		} else if !TableVar.f32_lt(t, TableVar.f32_max(pv, nv)) {
			if (TableVar.f32_lt(nv, pv)) pd else nd
		} else {
			r = TableVar.f32_div(TableVar.f32_sub(t, pv), TableVar.f32_sub(nv, pv))
			TableVar.f32_add(pd, TableVar.f32_mul(r, TableVar.f32_sub(nd, pd)))
		}

	# ------------------------------------------------------------ extents

	## A glyph's extents at a location, exactly as HarfBuzz's
	## `hb_font_get_glyph_extents` in font units. At the default location
	## (every coordinate 0) they come from the glyph header
	## (`TableGlyfPoints.extents_default`); elsewhere from the points with
	## variations applied, composite components placed, the whole glyph
	## shifted so its left phantom point is at 0, and each edge of the box
	## rounded half up. A glyph past the font has none.
	extents : TableGlyfPoints, TableGvar, Location, U64 -> Extents
	extents = |glyf, gvar, loc, g| {
		none = { x_bearing: 0, y_bearing: 0, width: 0, height: 0 }
		if g >= TableGlyfPoints.glyph_total(glyf) {
			return none
		}
		if !loc.nonzero {
			return TableGlyfPoints.extents_default(glyf, g)
		}
		points = TableGvar.points(glyf, gvar, loc, g)
		xs = points.xs
		ys = points.ys
		n = xs.len() - 4
		shift = xs.get(n) ?? 0
		var $min_x = 0x7F7FFFFF
		var $max_x = 0xFF7FFFFF
		var $min_y = 0x7F7FFFFF
		var $max_y = 0xFF7FFFFF
		for i in 0..<n {
			x0 = xs.get(i) ?? 0
			x = if (TableGvar.f32_zero(shift)) x0 else TableVar.f32_sub(x0, shift)
			y = ys.get(i) ?? 0
			$min_x = TableVar.f32_min($min_x, x)
			$max_x = TableVar.f32_max($max_x, x)
			$min_y = TableVar.f32_min($min_y, y)
			$max_y = TableVar.f32_max($max_y, y)
		}
		if !TableVar.f32_lt($min_x, $max_x) or !TableVar.f32_lt($min_y, $max_y) {
			return none
		}
		left = TableVar.f32_round_half_up($min_x)
		top = TableVar.f32_round_half_up($max_y)
		{
			x_bearing: left,
			y_bearing: top,
			width: TableVar.f32_round_half_up($max_x) - left,
			height: TableVar.f32_round_half_up($min_y) - top,
		}
	}

	## A glyph's points at a location, before the final shift: every
	## contour point of the glyph and its components, then its four phantom
	## points, as single-precision bit patterns. This follows HarfBuzz's
	## `Glyph::get_points` step for step, with an explicit stack of
	## composite glyphs instead of recursion; reading bounded the depth and
	## the size.
	points : TableGlyfPoints, TableGvar, Location, U64 -> { xs : List(U32), ys : List(U32) }
	points = |glyf, gvar, loc, root| {
		# HarfBuzz's all_points (contour points so far, and the phantom
		# points of the glyph just finished) and comp_points (each composite
		# on the stack: its component offsets, then its phantom points).
		var $all_x = []
		var $all_y = []
		var $comp_x = []
		var $comp_y = []
		# The composite stack: glyph, base in comp_points, next record,
		# component index, and all_points' length before the component.
		var $f_glyph = []
		var $f_base = []
		var $f_record = []
		var $f_index = []
		var $f_before = []
		var $next = root
		# 0: start glyph `next`; 1: next component of the top composite;
		# 2: a glyph finished.
		var $mode = 0
		var $steps = 0
		# Each glyph visit takes at most one start, one finish and one step
		# per component (plus one); reading bounded the visits.
		step_limit = 4 * TableGlyfPoints.visit_limit + 4
		while $steps < step_limit {
			$steps = $steps + 1
			if $mode == 0 {
				g = $next
				kind = TableGlyfPoints.kind(glyf, g)
				phantom_x = TableGlyfPoints.phantom_xs(glyf, g)
				if kind == 1 {
					p = TableGlyfPoints.simple_points(glyf, g)
					moved = TableGvar.apply(gvar, loc, g, p.xs.concat(phantom_x), p.ys.concat([0, 0, 0, 0]), p.ends.concat([False, False, False, False]))
					$all_x = $all_x.concat(moved.xs)
					$all_y = $all_y.concat(moved.ys)
					$mode = 2
				} else if kind == 0 {
					moved = TableGvar.apply(gvar, loc, g, phantom_x, [0, 0, 0, 0], [False, False, False, False])
					$all_x = $all_x.concat(moved.xs)
					$all_y = $all_y.concat(moved.ys)
					$mode = 2
				} else {
					n = TableGlyfPoints.point_count(glyf, g)
					var $ox = List.with_capacity(n + 4)
					var $oy = List.with_capacity(n + 4)
					var $at = TableGlyfPoints.first_component(glyf, g)
					for _k in 0..<n {
						c = TableGlyfPoints.component(glyf.glyf, $at)
						$ox = $ox.append(TableVar.f32_from_int(c.dx))
						$oy = $oy.append(TableVar.f32_from_int(c.dy))
						$at = c.next
					}
					moved = TableGvar.apply(gvar, loc, g, $ox.concat(phantom_x), $oy.concat([0, 0, 0, 0]), List.repeat(True, n).concat([False, False, False, False]))
					$f_glyph = $f_glyph.append(g)
					$f_base = $f_base.append($comp_x.len())
					$f_record = $f_record.append(TableGlyfPoints.first_component(glyf, g))
					$f_index = $f_index.append(0)
					$f_before = $f_before.append(0)
					$comp_x = $comp_x.concat(moved.xs)
					$comp_y = $comp_y.concat(moved.ys)
					$mode = 1
				}
			} else if $mode == 1 {
				top = $f_glyph.len() - 1
				g = $f_glyph.get(top) ?? 0
				n = TableGlyfPoints.point_count(glyf, g)
				index = $f_index.get(top) ?? 0
				if index < n {
					c = TableGlyfPoints.component(glyf.glyf, $f_record.get(top) ?? 0)
					$f_before = $f_before.set(top, $all_x.len()) ?? []
					$next = c.glyph
					$mode = 0
				} else {
					base = $f_base.get(top) ?? 0
					$all_x = $all_x.concat($comp_x.sublist({ start: base + n, len: 4 }))
					$all_y = $all_y.concat($comp_y.sublist({ start: base + n, len: 4 }))
					$comp_x = $comp_x.take_first(base)
					$comp_y = $comp_y.take_first(base)
					$f_glyph = $f_glyph.drop_last(1)
					$f_base = $f_base.drop_last(1)
					$f_record = $f_record.drop_last(1)
					$f_index = $f_index.drop_last(1)
					$f_before = $f_before.drop_last(1)
					$mode = 2
				}
			} else if $f_glyph.is_empty() {
				$steps = step_limit
			} else {
				top = $f_glyph.len() - 1
				g = $f_glyph.get(top) ?? 0
				n = TableGlyfPoints.point_count(glyf, g)
				index = $f_index.get(top) ?? 0
				base = $f_base.get(top) ?? 0
				before = $f_before.get(top) ?? 0
				c = TableGlyfPoints.component(glyf.glyf, $f_record.get(top) ?? 0)
				total = $all_x.len()
				# The component's points (its phantom points last) are
				# all_points[before, total).
				if c.use_my_metrics {
					for i in 0..<4 {
						$comp_x = $comp_x.set(base + n + i, $all_x.get(total - 4 + i) ?? 0) ?? []
						$comp_y = $comp_y.set(base + n + i, $all_y.get(total - 4 + i) ?? 0) ?? []
					}
				}
				tx = $comp_x.get(base + index) ?? 0
				ty = $comp_y.get(base + index) ?? 0
				m = c.matrix
				m0 = m.get(0) ?? 0
				m1 = m.get(1) ?? 0
				m2 = m.get(2) ?? 0
				m3 = m.get(3) ?? 0
				for i in before..<total {
					x0 = $all_x.get(i) ?? 0
					y0 = $all_y.get(i) ?? 0
					# Scaled offsets translate before transforming.
					x1 = if (c.scaled_offsets and !TableGvar.f32_zero(tx)) TableVar.f32_add(x0, tx) else x0
					y1 = if (c.scaled_offsets and !TableGvar.f32_zero(ty)) TableVar.f32_add(y0, ty) else y0
					x2 = if (c.identity) x1 else TableVar.f32_add(TableVar.f32_mul(x1, m0), TableVar.f32_mul(y1, m2))
					y2 = if (c.identity) y1 else TableVar.f32_add(TableVar.f32_mul(x1, m1), TableVar.f32_mul(y1, m3))
					x3 = if (!c.scaled_offsets and !TableGvar.f32_zero(tx)) TableVar.f32_add(x2, tx) else x2
					y3 = if (!c.scaled_offsets and !TableGvar.f32_zero(ty)) TableVar.f32_add(y2, ty) else y2
					# i is below all_points' length.
					$all_x = $all_x.set(i, x3) ?? []
					$all_y = $all_y.set(i, y3) ?? []
				}
				if c.anchored {
					# Reading checked p1 against the points before this
					# component and p2 against its own points.
					ax = TableVar.f32_sub($all_x.get(c.p1) ?? 0, $all_x.get(before + c.p2) ?? 0)
					ay = TableVar.f32_sub($all_y.get(c.p1) ?? 0, $all_y.get(before + c.p2) ?? 0)
					for i in before..<total {
						if !TableGvar.f32_zero(ax) {
							$all_x = $all_x.set(i, TableVar.f32_add($all_x.get(i) ?? 0, ax)) ?? []
						}
						if !TableGvar.f32_zero(ay) {
							$all_y = $all_y.set(i, TableVar.f32_add($all_y.get(i) ?? 0, ay)) ?? []
						}
					}
				}
				$all_x = $all_x.drop_last(4)
				$all_y = $all_y.drop_last(4)
				$f_index = $f_index.set(top, index + 1) ?? []
				$f_record = $f_record.set(top, c.next) ?? []
				$mode = 1
			}
		}
		{ xs: $all_x, ys: $all_y }
	}

	# ------------------------------------------------------------ double precision

	# IEEE 754 binary64 on bit patterns, rounding to nearest with ties to
	# even, with subnormals. Only the operations HarfBuzz's tuple scalar
	# needs: the quotient of two integers, a product, and the conversion to
	# single precision. A value unpacks to sig * 2^exp.

	f64_one : U64
	f64_one = 0x3FF0000000000000

	f64_negative : U64 -> Bool
	f64_negative = |x| x.bitwise_and(0x8000000000000000) != 0

	f64_sig : U64 -> U128
	f64_sig = |x| {
		field = x.shr_zf_wrap(52).bitwise_and(0x7FF)
		fraction = x.bitwise_and(0xFFFFFFFFFFFFF).to_u128()
		if (field == 0) fraction else fraction.bitwise_or(0x10000000000000)
	}

	f64_exp : U64 -> I64
	f64_exp = |x| {
		field = x.shr_zf_wrap(52).bitwise_and(0x7FF).to_i64_wrap()
		if (field == 0) -1074 else field - 1075
	}

	# Round sig * 2^exp to the nearest binary64 value. The lowest bit of sig
	# may stand for a nonzero remainder below it (a sticky bit) when sig has
	# at least two bits below the rounding position; the widening to 64
	# bits guarantees that for the 53-bit format.
	f64_pack : Bool, U128, I64 -> U64
	f64_pack = |negative, sig_in, exp_in| {
		sign = if (negative) 0x8000000000000000 else 0
		if sig_in == 0 {
			return sign
		}
		n_in = TableVar.bit_length(sig_in)
		widen = if (n_in < 64) 64 - n_in else 0
		sig = sig_in.shl_wrap(widen.to_u8_wrap())
		exp = exp_in - widen
		n = n_in + widen
		top = exp + n - 1
		drop = if (top >= -1022) n - 53 else -1074 - exp
		if drop > n {
			return sign
		}
		kept = if (drop >= 128) 0 else sig.shr_zf_wrap(drop.to_u8_wrap())
		rest = sig - kept.shl_wrap(drop.to_u8_wrap())
		half = (1).shl_wrap((drop - 1).to_u8_wrap())
		rounded = if (rest > half or (rest == half and kept.bitwise_and(1) == 1)) kept + 1 else kept
		if top >= -1022 {
			carry = rounded == 0x20000000000000
			m = if (carry) 0x10000000000000 else rounded
			e = if (carry) top + 1 else top
			if e > 1023 {
				sign.bitwise_or(0x7FF0000000000000)
			} else {
				sign.bitwise_or((e + 1023).to_u64_wrap().shl_wrap(52)).bitwise_or((m - 0x10000000000000).to_u64_wrap())
			}
		} else {
			sign.bitwise_or(rounded.to_u64_wrap())
		}
	}

	## The binary64 value nearest num / den, for den not zero and both of
	## magnitude below 2^32: C's `(double) num / den`.
	f64_ratio : I64, I64 -> U64
	f64_ratio = |num, den| {
		negative = (num < 0) != (den < 0)
		mag = (if (num < 0) 0 - num else num).to_u128_wrap()
		d = (if (den < 0) 0 - den else den).to_u128_wrap()
		if mag == 0 or d == 0 {
			return 0
		}
		shift = 100 - TableVar.bit_length(mag)
		scaled = mag.shl_wrap(shift.to_u8_wrap())
		q = scaled // d
		r = scaled - q * d
		sticky = if (r != 0) 1 else 0
		TableGvar.f64_pack(negative, q * 2 + sticky, 0 - shift - 1)
	}

	f64_mul : U64, U64 -> U64
	f64_mul = |a, b| {
		negative = TableGvar.f64_negative(a) != TableGvar.f64_negative(b)
		sa = TableGvar.f64_sig(a)
		sb = TableGvar.f64_sig(b)
		if sa == 0 or sb == 0 {
			if (negative) 0x8000000000000000 else 0
		} else {
			TableGvar.f64_pack(negative, sa * sb, TableGvar.f64_exp(a) + TableGvar.f64_exp(b))
		}
	}

	## C's `(float) x`, rounding to nearest with ties to even.
	f64_to_f32 : U64 -> U32
	f64_to_f32 = |x| TableVar.f32_pack(TableGvar.f64_negative(x), TableGvar.f64_sig(x), TableGvar.f64_exp(x))
}
