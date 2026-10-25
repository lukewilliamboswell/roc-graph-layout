## A picture made of outlines and lines of text, ready to hand to a renderer:
## SVG for the web, or a PDF page. It uses the small vocabulary every vector
## renderer shares, so turning it into another format is a direct
## translation:
##
## - A shape is a path of straight lines and cubic curves, filled with one
##   colour, outlined with one colour at one width, or both. Circles, arcs
##   and rounded corners are already cubic curves, and dotted lines are
##   already separate short dashes.
## - A label is one line of text, set in the picture's single typeface at a
##   size and colour, placed by a point on its baseline and aligned to it at
##   its start, centre or end.
##
## Units are CSS pixels, with x to the right and y down. Items are listed in
## painting order: later items cover earlier ones.
Drawing :: {}.{

	Point : { x : F64, y : F64 }

	## A box by its top-left corner.
	Rect : { x : F64, y : F64, width : F64, height : F64 }

	## An sRGB colour.
	Color : { red : U8, green : U8, blue : U8 }

	## One step of a path. `MoveTo` starts a new piece of the path without
	## drawing; `Close` draws back to where the current piece started.
	Segment : [
		MoveTo(Point),
		LineTo(Point),
		CubicTo({ control_1 : Point, control_2 : Point, end : Point }),
		Close,
	]

	## How a path is painted. A path with neither fill nor stroke draws
	## nothing and is left out of pictures.
	Paint : {
		fill : [NoFill, Fill(Color)],
		stroke : [NoStroke, Stroke({ color : Color, width : F64 })],
	}

	## Where a label's origin sits along its line: at its start, centre or
	## end.
	Align : [Start, Center, End]

	## One line of text. `origin` is on the baseline.
	Label : { text : Str, origin : Point, size : F64, align : Align, color : Color }

	Item : [
		Shape({ path : List(Segment), paint : Paint }),
		Text(Label),
	]

	## The visible area and everything painted in it.
	Picture : { view : Rect, items : List(Item) }

	## Opaque black.
	black : Color
	black = { red: 0, green: 0, blue: 0 }

	## Opaque white.
	white : Color
	white = { red: 255, green: 255, blue: 255 }

	## A colour from `0xRRGGBB`.
	rgb : U32 -> Color
	rgb = |value| {
		red: value.shr_zf_wrap(16).bitwise_and(255).to_u8_wrap(),
		green: value.shr_zf_wrap(8).bitwise_and(255).to_u8_wrap(),
		blue: value.bitwise_and(255).to_u8_wrap(),
	}

	## The closed outline of a rectangle, clockwise from its top-left corner.
	rectangle : Rect -> List(Segment)
	rectangle = |r| [
		MoveTo({ x: r.x, y: r.y }),
		LineTo({ x: r.x + r.width, y: r.y }),
		LineTo({ x: r.x + r.width, y: r.y + r.height }),
		LineTo({ x: r.x, y: r.y + r.height }),
		Close,
	]

	## The closed outline through these points, or nothing for no points.
	polygon : List(Point) -> List(Segment)
	polygon = |points|
		match points.first() {
			Err(_) => []
			Ok(first) => {
				var $path = List.with_capacity(points.len() + 1)
				$path = $path.append(MoveTo(first))
				for point in points.drop_first(1) {
					$path = $path.append(LineTo(point))
				}
				$path.append(Close)
			}
		}

	## The closed outline of an ellipse with these radii, as four cubic
	## curves starting at its rightmost point. A circle has equal radii.
	ellipse : Point, F64, F64 -> List(Segment)
	ellipse = |c, rx, ry| {
		kx = rx * DrawingInternals.kappa
		ky = ry * DrawingInternals.kappa
		[
			MoveTo({ x: c.x + rx, y: c.y }),
			CubicTo({ control_1: { x: c.x + rx, y: c.y + ky }, control_2: { x: c.x + kx, y: c.y + ry }, end: { x: c.x, y: c.y + ry } }),
			CubicTo({ control_1: { x: c.x - kx, y: c.y + ry }, control_2: { x: c.x - rx, y: c.y + ky }, end: { x: c.x - rx, y: c.y } }),
			CubicTo({ control_1: { x: c.x - rx, y: c.y - ky }, control_2: { x: c.x - kx, y: c.y - ry }, end: { x: c.x, y: c.y - ry } }),
			CubicTo({ control_1: { x: c.x + kx, y: c.y - ry }, control_2: { x: c.x + rx, y: c.y - ky }, end: { x: c.x + rx, y: c.y } }),
			Close,
		]
	}

	## The closed outline of a rectangle whose corners are quarter circles of
	## this radius, limited to half the shorter side.
	rounded_rectangle : Rect, F64 -> List(Segment)
	rounded_rectangle = |r, radius| {
		limit = r.width.min(r.height) / 2
		rad = radius.min(limit).max(0)
		if rad <= 0 {
			Drawing.rectangle(r)
		} else {
			k = rad * (1 - DrawingInternals.kappa)
			left = r.x
			right = r.x + r.width
			top = r.y
			bottom = r.y + r.height
			[
				MoveTo({ x: left + rad, y: top }),
				LineTo({ x: right - rad, y: top }),
				CubicTo({ control_1: { x: right - k, y: top }, control_2: { x: right, y: top + k }, end: { x: right, y: top + rad } }),
				LineTo({ x: right, y: bottom - rad }),
				CubicTo({ control_1: { x: right, y: bottom - k }, control_2: { x: right - k, y: bottom }, end: { x: right - rad, y: bottom } }),
				LineTo({ x: left + rad, y: bottom }),
				CubicTo({ control_1: { x: left + k, y: bottom }, control_2: { x: left, y: bottom - k }, end: { x: left, y: bottom - rad } }),
				LineTo({ x: left, y: top + rad }),
				CubicTo({ control_1: { x: left, y: top + k }, control_2: { x: left + k, y: top }, end: { x: left + rad, y: top } }),
				Close,
			]
		}
	}

	## A quarter of an ellipse from `from` to `to` as one cubic curve, where
	## `corner` is the corner of the ellipse's bounding box between them.
	quarter : Point, Point, Point -> Segment
	quarter = |from, corner, to|
		CubicTo({
			control_1: { x: from.x + (corner.x - from.x) * DrawingInternals.kappa, y: from.y + (corner.y - from.y) * DrawingInternals.kappa },
			control_2: { x: to.x + (corner.x - to.x) * DrawingInternals.kappa, y: to.y + (corner.y - to.y) * DrawingInternals.kappa },
			end: to,
		})

	## Moves every coordinate of a path by an offset.
	translate : List(Segment), Point -> List(Segment)
	translate = |path, d| {
		at = |p| { x: p.x + d.x, y: p.y + d.y }
		path.map(
			|segment|
				match segment {
					MoveTo(p) => MoveTo(at(p))
					LineTo(p) => LineTo(at(p))
					CubicTo(c) => CubicTo({ control_1: at(c.control_1), control_2: at(c.control_2), end: at(c.end) })
					Close => Close
				},
		)
	}

	## Every coordinate in a picture is finite.
	is_finite : Picture -> Bool
	is_finite = |picture| {
		ok = |p| F64.is_finite(p.x) and F64.is_finite(p.y)
		rect = picture.view
		F64.is_finite(rect.x)
			and F64.is_finite(rect.y)
			and F64.is_finite(rect.width)
			and F64.is_finite(rect.height)
			and picture.items.all(
				|item|
					match item {
						Text(label) => ok(label.origin) and F64.is_finite(label.size)
						Shape(shape) => {
							width_ok = match shape.paint.stroke {
								NoStroke => True
								Stroke(s) => F64.is_finite(s.width)
							}
							width_ok
								and shape.path.all(
									|segment|
										match segment {
											MoveTo(p) => ok(p)
											LineTo(p) => ok(p)
											CubicTo(c) => ok(c.control_1) and ok(c.control_2) and ok(c.end)
											Close => True
										},
								)
						}
					},
			)
	}
}

# Internal constants; only `Drawing` is visible to importers.
DrawingInternals :: {}.{
	# The control-point distance, as a fraction of the radius, of the cubic
	# curve closest to a quarter circle.
	kappa : F64
	kappa = 0.5522847498307936
}

expect Drawing.rgb(0x28253D) == { red: 0x28, green: 0x25, blue: 0x3D }
expect Drawing.polygon([]) == []
expect Drawing.ellipse({ x: 0, y: 0 }, 1, 1).len() == 6
expect Drawing.rounded_rectangle({ x: 0, y: 0, width: 10, height: 10 }, 0) == Drawing.rectangle({ x: 0, y: 0, width: 10, height: 10 })
