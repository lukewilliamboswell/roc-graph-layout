import Drawing
import FlowTheme
import Theme
import TextMeasure
import font.Font
import layout.Geom
import layout.Layered

## Internal measured compartments and semantic relationship ends. Shared by
## class and entity diagrams; the public readers preserve their own models.
EntityDraw :: {}.{
	Node : { title : Str, sections : List(List(Str)) }
	Cardinality : [ExactlyOne, ZeroOne, OneMany, ZeroMany]
	Mark : [None, Arrow, Triangle, Diamond(Bool), Cardinality(Cardinality)]
	Edge : { from : U64, to : U64, label : Str, from_label : Str, to_label : Str, from_mark : Mark, to_mark : Mark, dashed : Bool }
	Block : { lines : List(Str), width : F64, height : F64, baseline : F64, step : F64 }
	Measured : { title : Block, sections : List(List(Block)), width : F64, height : F64 }

	measure_text : Str, Theme.Options -> Block
	measure_text = |text, theme| {
		measured = TextMeasure.block(text, { font: TextMeasure.inter, size: theme.font_size, line_height: theme.line_height, wrap: Width(theme.max_label_width), align: Start })
		metrics = Font.metrics(TextMeasure.inter)
		scale = theme.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
		# Reserve real font ascent/descent independently of the requested
		# baseline spacing. Very tight lines may overlap within a cell, but
		# they cannot escape that cell or cover the next compartment. The
		# fallback emoji font can extend a quarter-em below the baseline.
		baseline = (metrics.ascent.to_f64() * scale).max(TextMeasure.round(metrics.ascent.to_f64() * scale)).max(theme.font_size * 0.95).max(TextMeasure.round(theme.font_size * 0.95))
		descent = (metrics.descent.to_f64() * scale).max(TextMeasure.round(metrics.descent.to_f64() * scale)).max(theme.font_size * 0.25).max(TextMeasure.round(theme.font_size * 0.25))
		step = theme.font_size * theme.line_height
		height = if measured.lines.is_empty() {
			0
		} else {
			baseline + descent + (measured.lines.len() - 1).to_f64() * step
		}
		{ lines: measured.lines, width: measured.width, height: height.max(measured.height), baseline, step }
	}

	measure : Node, Theme.Options -> Measured
	measure = |node, theme| {
		title = EntityDraw.measure_text(node.title, theme)
		sections = node.sections.map(|section| section.map(|row| EntityDraw.measure_text(row, theme)))
		width = sections.fold(title.width, |w, section| section.fold(w, |v, row| v.max(row.width))) + theme.padding * 2
		title_h = title.height + theme.padding * 2
		height = sections.fold(title_h, |h, section| h + section.fold(0.0, |n, row| n + row.height) + theme.padding * 2)
		{ title, sections, width: width.max(100), height: height.max(40) }
	}

	paint : Drawing.Color, Drawing.Color, F64 -> Drawing.Paint
	paint = |fill, stroke, width| { fill: Fill(fill), stroke: Stroke({ color: stroke, width }) }

	line : Drawing.Point, Drawing.Point, Drawing.Color, F64 -> Drawing.Item
	line = |a, b, color, width| Shape({ path: [MoveTo(a), LineTo(b)], paint: { fill: NoFill, stroke: Stroke({ color, width }) } })

	text : Block, Drawing.Point, Drawing.Align, Theme.Options, Drawing.Color -> List(Drawing.Item)
	text = |block, top, align, theme, color| block.lines.map_with_index(|row, i| Text({ text: row, origin: { x: top.x, y: top.y + block.baseline + i.to_f64() * block.step }, size: theme.font_size, align, color }))

	draw : List(Node), List(Edge), [Down, Up, Left, Right], Theme.Options -> Drawing.Picture
	draw = |nodes, edges, direction, theme| {
		measured = nodes.map(|node| EntityDraw.measure(node, theme))
		sizes = measured.map(|m| { width: m.width, height: m.height })
		graph = { nodes: sizes, edges: edges.map(|e| { from: e.from, to: e.to }) }
		# Label records retain their source edge and role, even for parallel edges.
		var $labels = []
		for e in 0..<edges.len() {
			edge = edges.get(e) ?? { from: 0, to: 0, label: "", from_label: "", to_label: "", from_mark: None, to_mark: None, dashed: False }
			for spec in [(edge.label, Center), (edge.from_label, Near(From)), (edge.to_label, Near(To))] {
				if !spec.0.is_empty() {
					block = EntityDraw.measure_text(spec.0, theme)
					$labels = $labels.append({ edge: e, placement: spec.1, block })
				}
			}
		}
		input = { ..Layered.default_input, graph, edge_labels: $labels.map(|s| { edge: s.edge, placement: s.placement, width: s.block.width + 12, height: s.block.height + 8 }) }
		# Every index is constructed from these exact source lists. Generated
		# sizes/settings are nonnegative and finite after theme validation.
		result = match Layered.layout(input, { ..Layered.default_settings, direction, node_gap: 56, layer_gap: 64 }, Layered.default_run) {
			Ok(r) => r
			Err(_) => crash "internally generated entity geometry failed preparation"
		}
		var $items = []
		match theme.shadow {
			NoShadow => {}
			Shadow(shadow) => {
				channel = |c| ((c.to_f64() * (1 - shadow.opacity)).round_to_i64_try() ?? 0).to_u8_wrap()
				color = { red: channel(theme.background.red), green: channel(theme.background.green), blue: channel(theme.background.blue) }
				if shadow.opacity > 0 {
					for i in 0..<nodes.len() {
						match (measured.get(i), result.layout.positions.get(i)) {
							(Ok(m), Ok(p)) => {
								rect = { x: p.x - m.width / 2 + shadow.dx, y: p.y - m.height / 2 + shadow.dy, width: m.width, height: m.height }
								$items = $items.append(Shape({ path: Drawing.rounded_rectangle(rect, theme.corner_radius), paint: { fill: Fill(color), stroke: NoStroke } }))
							}
							_ => {}
						}
					}
				}
			}
		}
		for i in 0..<edges.len() {
			match (edges.get(i), result.layout.routes.get(i)) {
				(Ok(edge), Ok(route)) => {
					points = EntityDraw.clip_points(EntityDraw.route_points(route), edge, measured, result.layout.positions, theme.corner_radius)
					$items = $items.concat(EntityDraw.route(points, edge.dashed, theme))
					if points.len() >= 2 {
						a = points.first() ?? { x: 0, y: 0 }
						b = points.get(1) ?? a
						z = points.last() ?? a
						y = points.get(points.len() - 2) ?? z
						$items = $items.concat(EntityDraw.mark(a, b, edge.from_mark, theme))
						$items = $items.concat(EntityDraw.mark(z, y, edge.to_mark, theme))
					}
				}
				_ => {}
			}
		}
		for i in 0..<$labels.len() {
			match ($labels.get(i), result.label_anchors.get(i)) {
				(Ok(s), Ok(p)) => {
					h = s.block.height
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x: p.x - s.block.width / 2 - 4, y: p.y - h / 2 - 2, width: s.block.width + 8, height: h + 4 }, 3), paint: { fill: Fill(theme.label_background), stroke: NoStroke } }))
					$items = $items.concat(EntityDraw.text(s.block, { x: p.x, y: p.y - h / 2 }, Center, theme, theme.label_text))
				}
				_ => {}
			}
		}
		for i in 0..<nodes.len() {
			match (measured.get(i), result.layout.positions.get(i)) {
				(Ok(m), Ok(p)) => {
					x = p.x - m.width / 2
					y = p.y - m.height / 2
					title_h = m.title.height + theme.padding * 2
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x, y, width: m.width, height: m.height }, theme.corner_radius), paint: EntityDraw.paint(theme.background, theme.node_stroke, theme.line_width) }))
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x, y, width: m.width, height: title_h }, theme.corner_radius), paint: { fill: Fill(theme.node_fill), stroke: NoStroke } }))
					$items = $items.concat(EntityDraw.text(m.title, { x: p.x, y: y + theme.padding }, Center, theme, theme.node_text))
					var $top = y + title_h
					for section in m.sections {
						$items = $items.append(EntityDraw.line({ x, y: $top }, { x: x + m.width, y: $top }, theme.node_stroke, theme.line_width))
						$top = $top + theme.padding
						for row in section {
							$items = $items.concat(EntityDraw.text(row, { x: x + theme.padding, y: $top }, Start, theme, theme.node_text))
							$top = $top + row.height
						}
						$top = $top + theme.padding
					}
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x, y, width: m.width, height: m.height }, theme.corner_radius), paint: { fill: NoFill, stroke: Stroke({ color: theme.node_stroke, width: theme.line_width }) } }))
				}
				_ => {}
			}
		}
		shadow_margin = match theme.shadow {
			NoShadow => 0
			Shadow(shadow) => shadow.dx.abs().max(shadow.dy.abs())
		}
		margin = theme.padding.max(16) + 18 + shadow_margin
		b = result.layout.bounds
		{ view: { x: b.x - margin, y: b.y - margin, width: b.width + margin * 2, height: b.height + margin * 2 }, items: $items }
	}

	route_points : Geom.Route -> List(Drawing.Point)
	route_points = |route| match route {
		Line(a, b) => [a, b]
		Polyline(ps) => ps
		Curves(parts) => parts.fold([], |out, p| out.concat([p.from, p.to]))
	}

	## The placer routes against the node boxes. Match the two terminal
	## points to the rounded borders actually painted by the table renderer.
	clip_points : List(Drawing.Point), Edge, List(Measured), List(Drawing.Point), F64 -> List(Drawing.Point)
	clip_points = |points, edge, boxes, centers, radius| {
		if points.len() < 2 or radius <= 0 {
			return points
		}
		match (boxes.get(edge.from), centers.get(edge.from), boxes.get(edge.to), centers.get(edge.to)) {
			(Ok(a), Ok(p), Ok(b), Ok(q)) => {
				from_rect = { x: p.x - a.width / 2, y: p.y - a.height / 2, width: a.width, height: a.height }
				to_rect = { x: q.x - b.width / 2, y: q.y - b.height / 2, width: b.width, height: b.height }
				first = points.first() ?? p
				last = points.last() ?? q
				from = FlowTheme.rounded_point(from_rect, radius, first, points.get(1) ?? first)
				to = FlowTheme.rounded_point(to_rect, radius, last, points.get(points.len() - 2) ?? last)
				# len >= 2 proves both endpoint indices are in bounds.
				last_index = points.len() - 1
				(points.set(0, from) ?? []).set(last_index, to) ?? []
			}
			_ => points
		}
	}

	route : List(Drawing.Point), Bool, Theme.Options -> List(Drawing.Item)
	route = |points, dashed, theme| {
		var $out = []
		if points.len() >= 2 {
			for i in 1..<points.len() {
				a = points.get(i - 1) ?? { x: 0, y: 0 }
				b = points.get(i) ?? a
				if !dashed {
					$out = $out.append(EntityDraw.line(a, b, theme.line, theme.line_width))
				}
				else {
					dx = b.x - a.x
					dy = b.y - a.y
					length = (dx * dx + dy * dy).sqrt()
					count = ((length / 8 + 1).to_u64_try() ?? 0).min(4096)
					for j in 0..<count {
						lo = j.to_f64() / count.to_f64()
						hi = (j.to_f64() + 0.5) / count.to_f64()
						$out = $out.append(EntityDraw.line({ x: a.x + dx * lo, y: a.y + dy * lo }, { x: a.x + dx * hi, y: a.y + dy * hi }, theme.line, theme.line_width))
					}
				}
			}
		}
		$out
	}

	mark : Drawing.Point, Drawing.Point, Mark, Theme.Options -> List(Drawing.Item)
	mark = |end, inside, kind, theme| {
		dx = inside.x - end.x
		dy = inside.y - end.y
		length = (dx * dx + dy * dy).sqrt()
		ux = if (length > 0) dx / length else 1
		uy = if (length > 0) dy / length else 0
		at = |along, across| { x: end.x + ux * along - uy * across, y: end.y + uy * along + ux * across }
		stroke_line = |a, b| EntityDraw.line(a, b, theme.line, theme.line_width)
		match kind {
			None => []
			Arrow => [stroke_line(at(10, -5), end), stroke_line(end, at(10, 5))]
			Triangle => [Shape({ path: Drawing.polygon([end, at(14, -7), at(14, 7)]), paint: EntityDraw.paint(theme.background, theme.line, theme.line_width) })]
			Diamond(filled) => [Shape({ path: Drawing.polygon([end, at(9, -5), at(18, 0), at(9, 5)]), paint: EntityDraw.paint(if (filled) theme.line else theme.background, theme.line, theme.line_width) })]
			Cardinality(card) => {
				many = card == ZeroMany or card == OneMany
				zero = card == ZeroMany or card == ZeroOne
				branch = if (many) [stroke_line(at(0, -6), at(13, 0)), stroke_line(at(0, 6), at(13, 0))] else [stroke_line(at(5, -6), at(5, 6))]
				if zero {
					branch.append(Shape({ path: Drawing.ellipse(at(20, 0), 4, 4), paint: EntityDraw.paint(theme.background, theme.line, theme.line_width) }))
				} else {
					branch.append(stroke_line(at(20, -6), at(20, 6)))
				}
			}
		}
	}
}

## Regression: a valid tight line-height is baseline spacing, not the height
## of the first glyph. Zero padding must still contain every compartment.
expect {
	theme = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 300 }
	node = { title: "Title", sections: [["first", "second"]] }
	measured = EntityDraw.measure(node, theme)
	picture = EntityDraw.draw([node], [], Down, theme)
	labels = picture.items.fold(
		[],
		|out, item| match item {
			Text(label) => out.append(label)
			_ => out
		},
	)
	Drawing.is_finite(picture) and measured.height >= 64 * 3 and match labels {
		[title, first, second] => title.origin.y >= 60
			and first.origin.y - title.origin.y >= 64
			and second.origin.y - first.origin.y >= 64
			and second.origin.y + 16 <= measured.height
		_ => False
	}
}

## Regression: wrapped and explicit multiline cells reserve the full glyph
## extents even when successive baselines are much closer than one em.
expect {
	theme = Theme.Options.{ font_size: 64, line_height: 0.01, padding: 0, max_label_width: 90 }
	cell = EntityDraw.measure_text("first line\nsecond line with several words", theme)
	items = EntityDraw.text(cell, { x: 0, y: 0 }, Start, theme, theme.node_text)
	cell.lines.len() > 2 and cell.height >= 64 and items.all(
		|item| match item {
			Text(label) => label.origin.y >= 60 and label.origin.y + 16 <= cell.height
			_ => False
		},
	)
}

## Regression: edge-label reservations use their measured text boxes too.
expect {
	theme = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 90 }
	picture = EntityDraw.draw(
		[{ title: "A", sections: [["field"]] }, { title: "B", sections: [] }],
		[{ from: 0, to: 1, label: "a long\nlabel", from_label: "1", to_label: "many", from_mark: None, to_mark: Arrow, dashed: False }],
		Right,
		theme,
	)
	Drawing.is_finite(picture) and picture.items.all(
		|item| match item {
			Text(label) => label.origin.y - 62 >= picture.view.y
				and label.origin.y + 16 <= picture.view.y + picture.view.height
			_ => True
		},
	)
}

expect {
	theme = Theme.Options.{ font_size: 0.001, line_height: 0.01, padding: 0 }
	cell = EntityDraw.measure_text("a\nb", theme)
	cell.baseline > 0 and cell.height > cell.baseline and cell.step > 0
}

## regression: table connectors meet custom rounded corners, on the same axis.
expect {
	theme = Theme.Options.{}
	box = EntityDraw.measure({ title: "Table", sections: [] }, theme)
	first = { x: box.width / 2 - 1, y: -box.height / 2 }
	last = { x: 200 - box.width / 2, y: 0 }
	points = [first, { x: first.x, y: first.y - 50 }, { x: last.x, y: first.y - 50 }, last]
	edge = { from: 0, to: 1, label: "", from_label: "", to_label: "", from_mark: None, to_mark: None, dashed: False }
	clipped = EntityDraw.clip_points(points, edge, [box, box], [{ x: 0, y: 0 }, { x: 200, y: 0 }], 30)
	match clipped.first() {
		Ok(p) => clipped.len() == points.len() and p.x == first.x and p.y > first.y
			and clipped.last() == Ok(last)
		Err(_) => False
	}
}
