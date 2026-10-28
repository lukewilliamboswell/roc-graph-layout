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
		# control hull. Four stroke widths conservatively cover SVG's default
		# miter limit at sharp joins; ordinary widths fit existing margins.
		var $left = picture.view.x
		var $top = picture.view.y
		var $right = picture.view.x + picture.view.width
		var $bottom = picture.view.y + picture.view.height
		for item in picture.items {
			match item {
				Text(_) => {}
				Shape(shape) => {
					margin = match shape.paint.stroke {
						NoStroke => 0
						Stroke(stroke) => stroke.width * 4
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
}

expect {
	theme = Theme.Options.{}
	raw = { view: { x: 0, y: 0, width: 10, height: 10 }, items: [Shape({ path: Drawing.rectangle({ x: -20, y: -10, width: 5, height: 8 }), paint: { fill: Fill(Drawing.white), stroke: Stroke({ color: Drawing.black, width: 100 }) } })] }
	finished = DiagramView.finish(raw, theme)
	finished.view.x <= -70 and finished.view.y <= -60
		and DiagramView.finish(finished, theme) == finished
		and Drawing.is_finite(finished)
}
