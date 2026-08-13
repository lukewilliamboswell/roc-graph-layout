## Geometry shared by every layout family: the output vocabulary (points,
## rectangles, routes) and the small helpers each family uses to build it.
Geom :: {}.{

	## A position in the caller's units. `x` grows right, `y` grows down.
	Point : { x : F64, y : F64 }

	## An axis-aligned box: top-left corner plus full extents.
	Rect : { x : F64, y : F64, width : F64, height : F64 }

	## The one shape every edge route takes, in every family: a straight
	## line, a chain of straight segments, or a chain of cubic curve
	## segments. The union is closed by design — these three forms express
	## every planar curve a renderer can draw, so new algorithms never force
	## consumers to handle new route forms.
	Route : [
		Line({ x : F64, y : F64 }, { x : F64, y : F64 }),
		Polyline(List({ x : F64, y : F64 })),
		Curves(
			List(
				{
					from : { x : F64, y : F64 },
					ctl_a : { x : F64, y : F64 },
					ctl_b : { x : F64, y : F64 },
					to : { x : F64, y : F64 },
				},
			),
		),
	]

	point : F64, F64 -> Point
	point = |x, y| { x, y }

	## A finite copy of a derived value: infinities saturate at the largest
	## finite magnitude of their sign, and NaN — which derived arithmetic on
	## finite inputs can only reach through an unguarded infinity — falls
	## back to 0. Layout arithmetic applies this at its output seams so
	## finite accepted input always produces finite geometry, however
	## extreme.
	saturate : F64 -> F64
	saturate = |value|
		if F64.is_finite(value) {
			value
		} else if F64.is_nan(value) {
			0
		} else if value > 0 {
			F64.highest
		} else {
			F64.lowest
		}

	## The length of the vector `(x, y)`, computed by scaling before
	## squaring so finite inputs give a finite result even near the `F64`
	## maximum, where squaring directly would overflow to infinity. When the
	## true length itself exceeds the largest finite `F64` (both components
	## near the maximum), the result saturates at `F64.highest` — finite
	## input never produces a non-finite length.
	hypot : F64, F64 -> F64
	hypot = |x, y| {
		ax = x.abs()
		ay = y.abs()
		m = ax.max(ay)
		if m == 0 {
			0
		} else {
			rx = ax / m
			ry = ay / m
			length = m * (rx * rx + ry * ry).sqrt()
			if F64.is_finite(length) {
				length
			} else {
				F64.highest
			}
		}
	}

	empty_bounds : Rect
	empty_bounds = { x: 0, y: 0, width: 0, height: 0 }

	## Where the segment from a node's center toward `toward` crosses the
	## node's rectangular boundary — the attachment point a route endpoint
	## should use, so arrowheads land on the box rather than inside it.
	##
	## Defined for every input: a zero-size node clips to its own center, as
	## does a `toward` equal to the center. The result always lies on the
	## node's boundary (or at its center), whatever the distance to `toward`.
	clip_to_node : { x : F64, y : F64 }, { width : F64, height : F64 }, { x : F64, y : F64 } -> Point
	clip_to_node = |center, size, toward| {
		dx = toward.x - center.x
		dy = toward.y - center.y

		sx = if dx == 0 {
			F64.infinity
		} else {
			(size.width / 2) / dx.abs()
		}
		sy = if dy == 0 {
			F64.infinity
		} else {
			(size.height / 2) / dy.abs()
		}
		s = sx.min(sy)

		if F64.is_finite(s) {
			{ x: center.x + dx * s, y: center.y + dy * s }
		} else {
			center
		}
	}
}

## The empty bounding box starts at the origin.
expect Geom.empty_bounds == { x: 0, y: 0, width: 0, height: 0 }

## Hypot matches the exact 3-4-5 triangle and defines the zero vector.
expect Geom.hypot(3, 4) == 5
expect Geom.hypot(0, 0) == 0
expect Geom.hypot(0 - 3, 4) == 5

## Hypot stays finite where naive squaring would overflow to infinity.
expect {
	huge = Geom.hypot(1.0e300, 1.0e300)
	F64.is_finite(huge) and huge > 1.0e300
}

## Hypot saturates at the largest finite value when the true length itself
## would overflow: finite input never produces a non-finite length.
expect Geom.hypot(1.7e308, 1.7e308) == F64.highest

## Saturation passes finite values through and pins each infinity at the
## largest finite magnitude of its sign.
expect Geom.saturate(12.5) == 12.5
expect Geom.saturate(F64.infinity) == F64.highest
expect Geom.saturate(0 - F64.infinity) == F64.lowest
expect Geom.saturate(F64.nan) == 0

## Clipping toward a point straight to the right exits the right edge.
expect Geom.clip_to_node({ x: 10, y: 10 }, { width: 8, height: 6 }, { x: 30, y: 10 }) == { x: 14, y: 10 }

## Clipping toward a point below exits the bottom edge, even when the
## horizontal distance is larger than the vertical one.
expect Geom.clip_to_node({ x: 0, y: 0 }, { width: 20, height: 4 }, { x: 6, y: 6 }) == { x: 2, y: 2 }

## A diagonal that leaves through a corner clips to that corner.
expect Geom.clip_to_node({ x: 0, y: 0 }, { width: 10, height: 10 }, { x: 8, y: 8 }) == { x: 5, y: 5 }

## A zero-size node clips to its own center; so does a target equal to the
## center.
expect Geom.clip_to_node({ x: 3, y: 4 }, { width: 0, height: 0 }, { x: 9, y: 9 }) == { x: 3, y: 4 }
expect Geom.clip_to_node({ x: 3, y: 4 }, { width: 10, height: 10 }, { x: 3, y: 4 }) == { x: 3, y: 4 }
