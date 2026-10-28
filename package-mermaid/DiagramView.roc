import Drawing
import Theme

## Shared final framing for every validated Mermaid drawing. Actual painted
## paths, explicit stroke widths and shadows contribute to the view.
DiagramView :: {}.{
	finish : Drawing.Picture, Theme.Options -> Drawing.Picture
	finish = |picture, theme| {
		if picture.items.is_empty() {
			return picture
		}
		# Include actual painted outlines, including CSS width overrides,
		# thick connectors and shadow paths. Cubic curves stay inside their
		# control hull. Reserve the actual miter extent at joins, rather than
		# applying the maximum miter limit even to straight and rounded paths.
		var $left = picture.view.x
		var $top = picture.view.y
		var $right = picture.view.x + picture.view.width
		var $bottom = picture.view.y + picture.view.height
		for item in picture.items {
			match item {
				Text(_) | StyledText(_) => {}
				Shape(shape) => {
					margin = match shape.paint.stroke {
						NoStroke => 0
						Stroke(stroke) => DiagramView.stroke_margin(shape.path, stroke.width)
					}
					for segment in shape.path {
						points = match segment {
							MoveTo(p) | LineTo(p) => [p]
							CubicTo(c) => [c.control_1, c.control_2, c.end]
							Close => []
						}
						for p in points {
							$left = $left.min(p.x - margin)
							$top = $top.min(p.y - margin)
							$right = $right.max(p.x + margin)
							$bottom = $bottom.max(p.y + margin)
						}
					}
				}
			}
		}
		view = { x: $left, y: $top, width: $right - $left, height: $bottom - $top }
		background = Shape({ path: Drawing.rectangle(view), paint: { fill: Fill(theme.background), stroke: NoStroke } })
		# Replace our existing background when finishing an already finished
		# picture. This makes family and automatic APIs share identical output.
		items = match picture.items.first() {
			Ok(Shape(first)) => if first.path == Drawing.rectangle(picture.view) and first.paint == { fill: Fill(theme.background), stroke: NoStroke } {
				picture.items.drop_first(1)
			} else {
				picture.items
			}
			_ => picture.items
		}
		{ view, items: [background].concat(items) }
	}

	# Unit directions use scaling before squaring, so even large finite
	# coordinates do not overflow while computing a join.
	direction : Drawing.Point, Drawing.Point -> [None, Some(Drawing.Point)]
	direction = |a, b| {
		dx = b.x - a.x
		dy = b.y - a.y
		scale = dx.abs().max(dy.abs())
		if scale == 0 {
			return None
		}
		x = dx / scale
		y = dy / scale
		length = F64.sqrt(x * x + y * y)
		Some({ x: x / length, y: y / length })
	}
	join_margin : [None, Some(Drawing.Point)], [None, Some(Drawing.Point)], F64 -> F64
	join_margin = |incoming, outgoing, width| match (incoming, outgoing) {
		(Some(a), Some(b)) => {
			denominator = 1 + a.x * b.x + a.y * b.y
			half = width / 2
			if denominator <= 0 {
				return half
			}
			# SVG's default join is a miter. Above its limit it becomes a bevel,
			# whose extent fits the half-width envelope.
			mx = -(a.y + b.y) * half / denominator
			my = (a.x + b.x) * half / denominator
			limit = width * 4
			magnitude = mx.abs().max(my.abs())
			if !F64.is_finite(magnitude) or magnitude > limit {
				half
			} else {
				half.max(magnitude)
			}
		}
		_ => width / 2
	}
	stroke_margin : List(Drawing.Segment), F64 -> F64
	stroke_margin = |path, width| {
		var $margin = width / 2
		var $at = { x: 0, y: 0 }
		var $first = $at
		var $incoming = None
		var $first_direction = None
		for segment in path {
			match segment {
				MoveTo(p) => {
					$at = p
					$first = p
					$incoming = None
					$first_direction = None
				}
				LineTo(p) => {
					segment_direction = DiagramView.direction($at, p)
					$margin = $margin.max(DiagramView.join_margin($incoming, segment_direction, width))
					if $first_direction == None {
						$first_direction = segment_direction
					}
					if segment_direction != None {
						$incoming = segment_direction
					}
					$at = p
				}
				CubicTo(c) => {
					start_direction = match DiagramView.direction($at, c.control_1) {
						Some(d) => Some(d)
						None => match DiagramView.direction($at, c.control_2) {
							Some(d) => Some(d)
							None => DiagramView.direction($at, c.end)
						}
					}
					end_direction = match DiagramView.direction(c.control_2, c.end) {
						Some(d) => Some(d)
						None => match DiagramView.direction(c.control_1, c.end) {
							Some(d) => Some(d)
							None => DiagramView.direction($at, c.end)
						}
					}
					$margin = $margin.max(DiagramView.join_margin($incoming, start_direction, width))
					if $first_direction == None {
						$first_direction = start_direction
					}
					if end_direction != None {
						$incoming = end_direction
					}
					$at = c.end
				}
				Close => {
					closing = DiagramView.direction($at, $first)
					if closing != None {
						$margin = $margin.max(DiagramView.join_margin($incoming, closing, width)).max(DiagramView.join_margin(closing, $first_direction, width))
					} else {
						$margin = $margin.max(DiagramView.join_margin($incoming, $first_direction, width))
					}
					$at = $first
					$incoming = None
					$first_direction = None
				}
			}
		}
		$margin
	}

}

expect {
	theme = Theme.Options.{}
	raw = { view: { x: 0, y: 0, width: 10, height: 10 }, items: [Shape({ path: Drawing.rectangle({ x: -20, y: -10, width: 5, height: 8 }), paint: { fill: Fill(Drawing.white), stroke: Stroke({ color: Drawing.black, width: 100 }) } })] }
	finished = DiagramView.finish(raw, theme)
	finished.view.x <= -70 and finished.view.y <= -60
		and DiagramView.finish(finished, theme) == finished
		and Drawing.is_finite(finished)
}

expect DiagramView.stroke_margin(Drawing.rectangle({ x: 0, y: 0, width: 20, height: 10 }), 2) == 1
expect DiagramView.stroke_margin(Drawing.rounded_rectangle({ x: 0, y: 0, width: 20, height: 10 }, 4), 2) == 1
expect {
	theme = Theme.Options.{}
	shadow = Shape({ path: Drawing.rectangle({ x: 16, y: 16, width: 100, height: 40 }), paint: { fill: Fill(Drawing.black), stroke: Stroke({ color: Drawing.black, width: 2 }) } })
	picture = { view: { x: 4, y: 4, width: 120, height: 60 }, items: [shadow] }
	DiagramView.finish(picture, theme).view == picture.view
}
