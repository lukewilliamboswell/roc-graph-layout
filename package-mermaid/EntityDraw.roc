import Drawing
import ClassMember
import FlowTheme
import Theme
import TextMeasure
import font.Font
import layout.Geom
import Flowchart
import FlowGeometry
import FlowLayout
import EntityLayout
import OracleJson

## Internal measured compartments and semantic relationship ends. Shared by
## class and entity diagrams; the public readers preserve their own models.
EntityDraw :: {}.{
	Node : { kind : [ClassBox, EntityBox], title : Str, annotations : List(Str), sections : List(List(Str)), table : List(List(Str)) }
	Cardinality : [ExactlyOne, ZeroOne, OneMany, ZeroMany]
	Mark : [None, Arrow, Triangle, Diamond(Bool), Cardinality(Cardinality)]
	Edge : { from : U64, to : U64, label : Str, from_label : Str, to_label : Str, from_mark : Mark, to_mark : Mark, dashed : Bool }
	Block : { lines : List(Str), width : F64, height : F64, baseline : F64, step : F64, font_size : F64 }
	Measured : { title : Block, annotations : List(Block), sections : List(List(Block)), table : List(List(Block)), column_widths : List(F64), row_heights : List(F64), title_height : F64, width : F64, height : F64 }

	radius : Theme.Options -> F64
	radius = |theme| match theme.corners {
		Rounded => theme.corner_radius
		FamilyDefault | Square => 0
	}

	measure_text : Str, Theme.Options -> Block
	measure_text = |text, theme| EntityDraw.measure_text_at(text, theme, theme.font_size)

	measure_text_at : Str, Theme.Options, F64 -> Block
	measure_text_at = |text, theme, font_size| {
		measured = TextMeasure.block(
			text,
			{
				font: TextMeasure.inter,
				size: font_size,
				line_height: theme.line_height,
				wrap: (
					match theme.wrapping {
						Wrap => Width(theme.max_label_width)
						FamilyDefault | NoWrap => NoWrap
					}
				),
				align: Start,
			},
		)
		metrics = Font.metrics(TextMeasure.inter)
		scale = font_size / Font.units_per_em(TextMeasure.inter).to_f64()
		# Reserve real font ascent/descent independently of the requested
		# baseline spacing. Very tight lines may overlap within a cell, but
		# they cannot escape that cell or cover the next compartment. The
		# fallback emoji font can extend a quarter-em below the baseline.
		baseline = (metrics.ascent.to_f64() * scale).max(TextMeasure.round(metrics.ascent.to_f64() * scale)).max(font_size * 0.95).max(TextMeasure.round(font_size * 0.95))
		descent = if (font_size >= 1) TextMeasure.round(metrics.descent.to_f64() * scale) else metrics.descent.to_f64() * scale
		step = font_size * theme.line_height
		height = if measured.lines.is_empty() {
			0
		} else {
			baseline + descent + (measured.lines.len() - 1).to_f64() * step
		}
		{ lines: measured.lines, width: measured.width, height: height.max(measured.height), baseline, step, font_size }
	}

	measure : Node, Theme.Options -> Measured
	measure = |node, theme| {
		title = EntityDraw.measure_text(node.title, theme)
		annotations = node.annotations.map(|label| EntityDraw.measure_text(label, theme))
		sections = node.sections.map(|section| section.map(|row| EntityDraw.measure_text(if (node.kind == ClassBox) ClassMember.parse(row, row.contains("(")).text else row, theme)))
		table = node.table.map(|row| row.map(|cell| EntityDraw.measure_text(cell, theme)))
		if node.kind == EntityBox {
			if table.is_empty() {
				padding = theme.padding * 24 / 150 / 15
				height = title.height + padding * 3
				{ title, annotations, sections: [], table, column_widths: [], row_heights: [], title_height: height, width: (title.width + padding * 2).max(100), height }
			} else {
				padding = theme.padding * 24 / 155 / 15
				text_padding = theme.padding * 18.75 / 15
				count = (table.first() ?? []).len()
				widths = List.repeat(0.0, count).map_with_index(|_, column| table.fold(0.0, |width, row| width.max((row.get(column) ?? { lines: [], width: 0, height: 0, baseline: 0, step: 0, font_size: 0 }).width)) + padding)
				content_width = widths.fold(0.0, |sum, width| sum + width)
				extra = (title.width + padding * 2 - content_width).max(0)
				column_widths = widths.map(|width| width + extra / count.to_f64())
				row_heights = table.map(|row| row.fold(0.0, |height, cell| height.max(cell.height)) + text_padding)
				title_height = title.height + text_padding
				{ title, annotations, sections: [], table, column_widths, row_heights, title_height, width: content_width + extra, height: row_heights.fold(title_height, |sum, height| sum + height) }
			}
		} else {
			title_width = annotations.fold(title.width, |current_width, annotation| current_width.max(annotation.width))
			member_width = sections.fold(0.0, |width, section| section.fold(width, |value, row| value.max(row.width)))
			width = title_width.max(member_width + title_width / 2) + theme.padding * 24 / 15
			title_height = annotations.fold(title.height, |height, annotation| height + annotation.height) + theme.padding * 24 / 15
			height = sections.fold(title_height, |h, section| h + section.fold(0.0, |n, row| n + row.height) + (if (section.is_empty()) 0 else (section.len() - 1).to_f64() * theme.font_size * 3 / 14) + theme.padding * 12 / 15 * (if (node.sections.all(List.is_empty)) 1.5 else 2))
			{ title, annotations, sections, table: [], column_widths: [], row_heights: [], title_height, width: width.max(1), height: height.max(1) }
		}
	}

	paint : Drawing.Color, Drawing.Color, F64 -> Drawing.Paint
	paint = |fill, stroke, width| { fill: Fill(fill), stroke: Stroke({ color: stroke, width }) }

	line : Drawing.Point, Drawing.Point, Drawing.Color, F64 -> Drawing.Item
	line = |a, b, color, width| Shape({ path: [MoveTo(a), LineTo(b)], paint: { fill: NoFill, stroke: Stroke({ color, width }) } })

	text : Block, Drawing.Point, Drawing.Align, Theme.Options, Drawing.Color -> List(Drawing.Item)
	text = |block, top, align, _theme, color| block.lines.map_with_index(|row, i| Text({ text: row, origin: { x: top.x, y: top.y + block.baseline + i.to_f64() * block.step }, size: block.font_size, align, color }))

	style_items : List(Drawing.Item), Bool, Bool, Bool -> List(Drawing.Item)
	style_items = |items, italic, underline, bold| if !italic and !underline and !bold {
		items
	} else {
		items.map(
			|item| match item {
				Text(label) => StyledText({ label, italic, underline, bold })
				_ => item
			},
		)
	}

	LabelSpec : { edge : U64, placement : [Center, Near([From, To])], block : Block }
	Placed : { layout : { positions : List(Drawing.Point), bounds : Drawing.Rect, routes : List(Geom.Route) }, label_anchors : List(Drawing.Point) }
	Arrangement : { measured : List(Measured), labels : List(LabelSpec), result : Placed }

	arrange : List(Node), List(Edge), [Down, Up, Left, Right], Theme.Options -> Arrangement
	arrange = |nodes, edges, direction, theme| EntityDraw.arrange_sized(nodes, edges, direction, theme, [], [])

	arrange_sized : List(Node), List(Edge), [Down, Up, Left, Right], Theme.Options, List(Str), List(OracleJson.Size) -> Arrangement
	arrange_sized = |nodes, edges, direction, theme, ids, overrides| {
		measured = nodes.map_with_index(
			|node, i| {
				native = EntityDraw.measure(node, theme)
				id = ids.get(i) ?? i.to_str()
				size = overrides.find_first(|candidate| candidate.kind == "node" and candidate.id == id)
				match size {
					Ok(value) => { ..native, width: value.width, height: value.height }
					Err(_) => native
				}
			},
		)
		var $labels = []
		for e in 0..<edges.len() {
			edge = edges.get(e) ?? { from: 0, to: 0, label: "", from_label: "", to_label: "", from_mark: None, to_mark: None, dashed: False }
			for spec in [(edge.label, Center), (edge.from_label, Near(From)), (edge.to_label, Near(To))] {
				if !spec.0.is_empty() {
					font_size = match spec.1 {
						Center => theme.font_size
						Near(_) => theme.font_size * 11 / 14
					}
					native = EntityDraw.measure_text_at(spec.0, theme, font_size)
					role = match spec.1 {
						Center => "label"
						Near(From) => "from-label"
						Near(To) => "to-label"
					}
					id = "${e.to_str()}-${role}"
					size = overrides.find_first(|value| (value.kind == "label" or value.kind == "edge-label") and value.id == id)
					block = match size {
						Ok(value) => { ..native, width: value.width, height: value.height }
						Err(_) => native
					}
					$labels = $labels.append({ edge: e, placement: spec.1, block })
				}
			}
		}
		diagram : Flowchart.Diagram
		diagram = {
			direction,
			nodes: nodes.map_with_index(|node, i| { id: ids.get(i) ?? i.to_str(), label: node.title, shape: Rectangle, container: Root, classes: [], styles: [] }),
			edges: edges.map_with_index(|edge, i| { id: i.to_str(), from: Node(edge.from), to: Node(edge.to), label: edge.label, line: if (edge.dashed) Dotted else Solid, start: None, end: None, length: 1, classes: [], styles: [] }),
			groups: [],
			classes: [],
		}
		sizes : FlowGeometry.Sizes
		sizes = {
			nodes: measured.map(|m| { width: m.width, height: m.height, label: { lines: m.title.lines, width: m.title.width, height: m.title.height } }),
			edge_labels: edges.map_with_index(
				|edge, i| {
					if edge.label.is_empty() {
						None
					} else {
						match $labels.find_first(|spec| spec.edge == i and spec.placement == Center) {
							Ok(spec) => Some({ lines: spec.block.lines, width: spec.block.width, height: spec.block.height })
							Err(_) => None
						}
					}
				},
			),
			group_titles: [],
		}
		raw_geometry = FlowLayout.layout(diagram, sizes)
		vertical = direction == Down or direction == Up
		terminals = $labels.fold(
			[],
			|out, spec| match spec.placement {
				Center => out
				Near(endpoint) => {
					edge = edges.get(spec.edge) ?? { from: 0, to: 0, label: "", from_label: "", to_label: "", from_mark: None, to_mark: None, dashed: False }
					route = raw_geometry.edges.get(spec.edge) ?? { points: [], label: None }
					points = if (endpoint == From) route.points else route.points.rev()
					point = points.first() ?? { x: 0, y: 0 }
					next = points.get(1) ?? point
					marker = if (endpoint == From) edge.from_mark else edge.to_mark
					pad = if (marker == None) 0 else 12
					extent = (if (vertical) spec.block.height else spec.block.width) + pad + 4
					out.append({ node: if (endpoint == From) edge.from else edge.to, point, next, extent })
				}
			},
		)
		spaced = EntityLayout.reserve(raw_geometry, terminals, vertical)
		label_sizes = sizes.edge_labels.map(
			|label| match label {
				None => None
				Some(block) => Some({ width: block.width + 4, height: block.height + 4 })
			},
		)
		geometry = FlowLayout.normalise(spaced, label_sizes, [])
		label_anchors = $labels.map(
			|spec| {
				route = geometry.edges.get(spec.edge) ?? { points: [], label: None }
				edge = edges.get(spec.edge) ?? { from: 0, to: 0, label: "", from_label: "", to_label: "", from_mark: None, to_mark: None, dashed: False }
				match spec.placement {
					Center => match route.label {
						Some(point) => point
						None => route.points.first() ?? { x: 0, y: 0 }
					}
					Near(endpoint) => EntityDraw.terminal_label(route.points, endpoint, spec.block, if (endpoint == From) edge.from_mark else edge.to_mark)
				}
			},
		)
		result = { layout: { positions: geometry.nodes.map(|r| { x: r.x + r.width / 2, y: r.y + r.height / 2 }), bounds: geometry.bounds, routes: geometry.edges.map(|edge| Polyline(edge.points)) }, label_anchors }
		{ measured, labels: $labels, result }
	}

	terminal_label : List(Drawing.Point), [From, To], Block, Mark -> Drawing.Point
	terminal_label = |raw_points, endpoint, _block, mark| {
		points = if (endpoint == From) raw_points else raw_points.rev()
		first = points.first() ?? { x: 0, y: 0 }
		next = points.get(1) ?? { x: first.x + 1, y: first.y }
		dx = next.x - first.x
		dy = next.y - first.y
		length = (dx * dx + dy * dy).sqrt()
		ux = if (length > 0) dx / length else 1
		uy = if (length > 0) dy / length else 0
		marker = if (mark == None) 0 else 10
		along = (25.0 + marker) / 2
		side = 10.0 + marker * 0.5
		# Source multiplicity is on start-right, target on end-left, matching
		# the class DB's terminal roles rather than creating additional ranks.
		sign = if (endpoint == From) 1.0 else -1.0
		{ x: first.x + ux * along + uy * side * sign, y: first.y + uy * along - ux * side * sign }
	}

	draw : List(Node), List(Edge), [Down, Up, Left, Right], Theme.Options -> Drawing.Picture
	draw = |nodes, edges, direction, theme| EntityDraw.draw_sized(nodes, edges, direction, theme, [], [])

	draw_sized : List(Node), List(Edge), [Down, Up, Left, Right], Theme.Options, List(Str), List(OracleJson.Size) -> Drawing.Picture
	draw_sized = |nodes, edges, direction, theme, ids, overrides| {
		arranged = EntityDraw.arrange_sized(nodes, edges, direction, theme, ids, overrides)
		measured = arranged.measured
		labels = arranged.labels
		result = arranged.result
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
								$items = $items.append(Shape({ path: Drawing.rounded_rectangle(rect, EntityDraw.radius(theme)), paint: { fill: Fill(color), stroke: NoStroke } }))
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
					points = EntityDraw.clip_points(EntityDraw.route_points(route), edge, measured, result.layout.positions, EntityDraw.radius(theme))
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
		for i in 0..<labels.len() {
			match (labels.get(i), result.label_anchors.get(i)) {
				(Ok(s), Ok(p)) => {
					h = s.block.height
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x: p.x - s.block.width / 2 - 2, y: p.y - h / 2 - 2, width: s.block.width + 4, height: h + 4 }, 3), paint: { fill: Fill(theme.label_background), stroke: NoStroke } }))
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
					title_h = m.title_height
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x, y, width: m.width, height: m.height }, EntityDraw.radius(theme)), paint: EntityDraw.paint(theme.background, theme.node_stroke, theme.line_width) }))
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x, y, width: m.width, height: title_h }, EntityDraw.radius(theme)), paint: { fill: Fill(theme.node_fill), stroke: NoStroke } }))
					node = nodes.get(i) ?? { kind: ClassBox, title: "", annotations: [], sections: [], table: [] }
					annotation_height = m.annotations.fold(0.0, |height, annotation| height + annotation.height)
					var $title_top = y + (m.title_height - m.title.height - annotation_height) / 2
					for annotation in m.annotations {
						$items = $items.concat(EntityDraw.text(annotation, { x: p.x, y: $title_top }, Center, theme, theme.node_text))
						$title_top = $title_top + annotation.height
					}
					$items = $items.concat(EntityDraw.style_items(EntityDraw.text(m.title, { x: p.x, y: $title_top }, Center, theme, theme.node_text), False, False, node.kind == ClassBox))
					var $top = y + title_h
					for section_index in 0..<m.sections.len() {
						section = m.sections.get(section_index) ?? []
						raw_section = node.sections.get(section_index) ?? []
						$items = $items.append(EntityDraw.line({ x, y: $top }, { x: x + m.width, y: $top }, theme.node_stroke, theme.line_width))
						section_padding = theme.padding * 12 / 15 * (if (node.sections.all(List.is_empty)) 0.75 else 1)
						$top = $top + section_padding
						for row_index in 0..<section.len() {
							row = section.get(row_index) ?? { lines: [], width: 0, height: 0, baseline: 0, step: 0, font_size: 0 }
							raw = raw_section.get(row_index) ?? ""
							member = ClassMember.parse(raw, raw.contains("("))
							row_items = EntityDraw.text(row, { x: x + theme.padding * 12 / 15, y: $top }, Start, theme, theme.node_text)
							$items = $items.concat(EntityDraw.style_items(row_items, node.kind == ClassBox and member.classifier == "*", node.kind == ClassBox and member.classifier == "$", False))
							$top = $top + row.height
							if row_index + 1 < section.len() {
								$top = $top + theme.font_size * 3 / 14
							}
						}
						$top = $top + section_padding
					}
					if !m.table.is_empty() {
						$top = y + title_h
						for row_index in 0..<m.table.len() {
							row = m.table.get(row_index) ?? []
							row_height = m.row_heights.get(row_index) ?? 0
							$items = $items.append(EntityDraw.line({ x, y: $top }, { x: x + m.width, y: $top }, theme.node_stroke, theme.line_width))
							var $left = x
							for column in 0..<row.len() {
								cell = row.get(column) ?? { lines: [], width: 0, height: 0, baseline: 0, step: 0, font_size: 0 }
								$items = $items.concat(EntityDraw.text(cell, { x: $left + theme.padding * 24 / 155 / 30, y: $top + (row_height - cell.height) / 2 }, Start, theme, theme.node_text))
								if column > 0 {
									$items = $items.append(EntityDraw.line({ x: $left, y: y + title_h }, { x: $left, y: y + m.height }, theme.node_stroke, theme.line_width))
								}
								$left = $left + (m.column_widths.get(column) ?? 0)
							}
							$top = $top + row_height
						}
					}
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle({ x, y, width: m.width, height: m.height }, EntityDraw.radius(theme)), paint: { fill: NoFill, stroke: Stroke({ color: theme.node_stroke, width: theme.line_width }) } }))
				}
				_ => {}
			}
		}
		{ view: result.layout.bounds, items: $items }
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
	node = { kind: ClassBox, table: [], annotations: [], title: "Title", sections: [["first", "second"]] }
	measured = EntityDraw.measure(node, theme)
	picture = EntityDraw.draw([node], [], Down, theme)
	labels = picture.items.fold(
		[],
		|out, item| match item {
			Text(label) => out.append(label)
			StyledText(styled) => out.append(styled.label)
			_ => out
		},
	)
	Drawing.is_finite(picture) and measured.height >= 64 * 3 and match labels {
		[title, first, second] => title.origin.y >= 60
			and first.origin.y - title.origin.y >= 64
			and second.origin.y - first.origin.y >= 64
			and second.origin.y + 15 <= measured.height + FlowLayout.content_origin
		_ => False
	}
}

## Regression: wrapped and explicit multiline cells reserve the full glyph
## extents even when successive baselines are much closer than one em.
expect {
	theme = Theme.Options.{ font_size: 64, line_height: 0.01, padding: 0, max_label_width: 90, wrapping: Wrap }
	cell = EntityDraw.measure_text("first line\nsecond line with several words", theme)
	items = EntityDraw.text(cell, { x: 0, y: 0 }, Start, theme, theme.node_text)
	cell.lines.len() > 2 and cell.height >= 64 and items.all(
		|item| match item {
			Text(label) => label.origin.y >= 60 and label.origin.y + 15 <= cell.height
			_ => False
		},
	)
}

## Regression: edge-label reservations use their measured text boxes too.
expect {
	theme = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 90, wrapping: Wrap }
	picture = EntityDraw.draw(
		[{ kind: ClassBox, table: [], annotations: [], title: "A", sections: [["field"]] }, { kind: ClassBox, table: [], annotations: [], title: "B", sections: [] }],
		[{ from: 0, to: 1, label: "a long\nlabel", from_label: "1", to_label: "many", from_mark: None, to_mark: Arrow, dashed: False }],
		Right,
		theme,
	)
	Drawing.is_finite(picture) and picture.items.all(
		|item| match item {
			Text(label) => label.origin.y - 62 >= picture.view.y
				and label.origin.y + 15 <= picture.view.y + picture.view.height
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
	box = EntityDraw.measure({ kind: ClassBox, table: [], annotations: [], title: "Table", sections: [] }, theme)
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
