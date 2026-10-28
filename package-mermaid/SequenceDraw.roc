import Drawing
import SequenceData
import SequenceLayout
import SequenceParse
import SequenceStyle
import TextMeasure
import Theme

SequenceDraw :: {}.{
	Block : SequenceLayout.Block
	Row : SequenceLayout.Row
	Geometry : SequenceLayout.Geometry

	block : Str, Theme.Options -> Block
	block = |text, theme| SequenceLayout.measure(text, True, theme.max_label_width, theme)
	layout : SequenceData.Diagram, Theme.Options -> Geometry
	layout = SequenceLayout.layout

	shape : List(Drawing.Segment), Drawing.Color, Drawing.Color, F64 -> Drawing.Item
	shape = |path, fill, stroke, width| Shape({ path, paint: { fill: Fill(fill), stroke: Stroke({ color: stroke, width }) } })

	line : Drawing.Point, Drawing.Point, Bool, Drawing.Color, F64 -> Drawing.Item
	line = |a, b, dotted, color, width| if dotted {
		SequenceDraw.dashes(a, b, 3, 3, color, width)
	} else {
		Shape({ path: [MoveTo(a), LineTo(b)], paint: { fill: NoFill, stroke: Stroke({ color, width }) } })
	}
	dashes : Drawing.Point, Drawing.Point, F64, F64, Drawing.Color, F64 -> Drawing.Item
	dashes = |a, b, on, off, color, width| {
		dx = b.x - a.x
		dy = b.y - a.y
		length = (dx * dx + dy * dy).sqrt()
		var $path = []
		var $at = 0.0
		while $at < length {
			stop = ($at + on).min(length)
			$path = $path.concat([MoveTo({ x: a.x + dx * $at / length, y: a.y + dy * $at / length }), LineTo({ x: a.x + dx * stop / length, y: a.y + dy * stop / length })])
			$at = $at + on + off
		}
		Shape({ path: $path, paint: { fill: NoFill, stroke: Stroke({ color, width }) } })
	}

	draw : SequenceData.Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, theme| SequenceDraw.draw_geometry(diagram, theme, SequenceDraw.layout(diagram, theme))

	draw_geometry : SequenceData.Diagram, Theme.Options, Geometry -> Drawing.Picture
	draw_geometry = |diagram, options, geometry| {
		theme = SequenceStyle.resolve(options)
		if diagram.participants.is_empty() and diagram.events.is_empty() and diagram.title.is_empty() {
			return { view: geometry.view, items: [] }
		}
		var $items = []
		for frame in geometry.frames.rev() {
			rect = { x: frame.left, y: frame.top, width: frame.right - frame.left, height: frame.bottom - frame.top }
			a = { x: rect.x, y: rect.y }
			b = { x: rect.x + rect.width, y: rect.y }
			c = { x: rect.x + rect.width, y: rect.y + rect.height }
			d = { x: rect.x, y: rect.y + rect.height }
			for pair in [(a, b), (b, c), (c, d), (d, a)] {
				$items = $items.append(SequenceDraw.dashes(pair.0, pair.1, 2, 2, theme.line, theme.line_width * 4 / 3))
			}
			tab = { x: frame.left, y: frame.top, width: 50, height: 35 }
			$items = $items.append(SequenceDraw.shape(Drawing.polygon([{ x: tab.x, y: tab.y }, { x: tab.x + 50, y: tab.y }, { x: tab.x + 50, y: tab.y + 28 }, { x: tab.x + 41.6, y: tab.y + 35 }, { x: tab.x, y: tab.y + 35 }]), theme.label_background, theme.line, theme.line_width * 2 / 3))
			for index in frame.branches {
				row = geometry.rows.get(index) ?? { top: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
				$items = $items.append(SequenceDraw.line({ x: frame.left, y: row.top + 15 }, { x: frame.right, y: row.top + 15 }, True, theme.line, theme.line_width * 4 / 3))
			}
		}
		for x in geometry.centers {
			$items = $items.append(SequenceDraw.line({ x, y: geometry.header_height }, { x, y: geometry.footer_y }, False, theme.node_stroke, theme.line_width * 4 / 3))
		}
		for activation in geometry.activations {
			colors = SequenceStyle.actor(activation.index, options)
			$items = $items.append(SequenceDraw.shape(Drawing.rectangle(activation.rect), colors.fill, colors.stroke, theme.line_width * 2 / 3))
		}
		for i in 0..<diagram.events.len() {
			match diagram.events.get(i) ?? EndBlock {
				Note(_) => {
					rect = geometry.notes.get(i) ?? SequenceLayout.zero_rect
					$items = $items.concat(
						SequenceDraw.box(
							Drawing.rectangle(rect),
							theme.note_fill,
							theme.note_stroke,
							Theme.Options.{ background: theme.background, line_width: theme.line_width * 2 / 3, shadow: theme.shadow },
						),
					)
				}
				Message(m) => {
					points = geometry.message_points.get(i) ?? []
					match points {
						[a, b] => {
							$items = $items.append(SequenceDraw.line(a, b, m.dotted, theme.line, theme.line_width))
							direction = if b.x >= a.x {
								1.0
							} else {
								-1.0
							}
							$items = $items.concat(SequenceDraw.head(b, direction, m.head, theme))
							if m.both {
								$items = $items.concat(SequenceDraw.head(a, -direction, m.head, theme))
							}
						}
						[a, c1, c2, b] => {
							if m.dotted {
								var $last = a
								for step in 1.U64..<41 {
									t = step.to_f64() / 40
									u = 1 - t
									p = { x: u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x, y: u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y }
									if step % 4 < 2 {
										$items = $items.append(SequenceDraw.line($last, p, False, theme.line, theme.line_width))
									}
									$last = p
								}
							} else {
								$items = $items.append(Shape({ path: [MoveTo(a), CubicTo({ control_1: c1, control_2: c2, end: b })], paint: { fill: NoFill, stroke: Stroke({ color: theme.line, width: theme.line_width }) } }))
							}
							$items = $items.concat(SequenceDraw.head(b, -1, m.head, theme))
							if m.both {
								$items = $items.concat(SequenceDraw.head(a, -1, m.head, theme))
							}
						}
						_ => {}
					}
				}
				_ => {}
			}
		}
		for i in 0..<diagram.participants.len() {
			p = diagram.participants.get(i) ?? { id: "", label: "", actor: False, wrap: False, source_text: "" }
			colors = SequenceStyle.actor(i, options)
			actor_theme = Theme.Options.{ background: theme.background, line_width: theme.line_width * 4 / 3, shadow: theme.shadow }
			header = geometry.headers.get(i) ?? SequenceLayout.zero_rect
			footer = geometry.footers.get(i) ?? SequenceLayout.zero_rect
			for is_footer in [False, True] {
				rect = if is_footer {
					footer
				} else {
					header
				}
				if p.actor {
					label = SequenceLayout.measure_source(p.label, p.source_text, p.wrap, theme.max_label_width, theme)
					bottom = if is_footer {
						rect.y + 50
					} else {
						rect.y + rect.height - label.height - 12
					}
					center = rect.x + rect.width / 2
					scale = 44.0 / 65.0
					gy = |offset| bottom - (60 - offset) * scale
					$items = $items.concat([
						SequenceDraw.shape(Drawing.ellipse({ x: center, y: gy(10) }, 15 * scale, 15 * scale), colors.fill, colors.stroke, actor_theme.line_width),
						SequenceDraw.line({ x: center, y: gy(25) }, { x: center, y: gy(45) }, False, colors.stroke, actor_theme.line_width),
						SequenceDraw.line({ x: center - 18 * scale, y: gy(33) }, { x: center + 18 * scale, y: gy(33) }, False, colors.stroke, actor_theme.line_width),
						SequenceDraw.line({ x: center - 18 * scale, y: gy(60) }, { x: center, y: gy(45) }, False, colors.stroke, actor_theme.line_width),
						SequenceDraw.line({ x: center, y: gy(45) }, { x: center + 16 * scale, y: gy(60) }, False, colors.stroke, actor_theme.line_width),
					])
				} else {
					$items = $items.concat(SequenceDraw.box(Drawing.rounded_rectangle(rect, theme.corner_radius), colors.fill, colors.stroke, actor_theme))
				}
			}
		}
		for label in geometry.labels {
			color = if label.role == "participant" or label.role == "title" or label.role == "control-kind" {
				theme.node_text
			} else {
				if label.role == "note" {
					theme.note_text
				} else {
					theme.label_text
				}
			}
			$items = $items.append(
				Text({
					text: label.text,
					origin: label.origin,
					size: label.size,
					align: if label.role == "title" {
						Start
					} else {
						Center
					},
					color,
				}),
			)
		}
		for number in geometry.numbers {
			$items = $items.append(SequenceDraw.shape(Drawing.ellipse(number.center, 6, 6), theme.line, theme.line, 0))
			$items = $items.append(
				Text({
					text: number.text,
					origin: { x: number.center.x, y: number.center.y + 4 },
					size: 12,
					align: Center,
					color: theme.background,
				}),
			)
		}
		background = Shape({ path: Drawing.rectangle(geometry.view), paint: { fill: Fill(theme.background), stroke: NoStroke } })
		{ view: geometry.view, items: [background].concat($items) }
	}

	head : Drawing.Point, F64, [None, Arrow, Open, Cross], Theme.Options -> List(Drawing.Item)
	head = |p, direction, kind, theme| match kind {
		None => []
		Arrow => [Shape({ path: Drawing.polygon([{ x: p.x - 8.9 * direction, y: p.y - 5 }, { x: p.x + 2.1 * direction, y: p.y }, { x: p.x - 7.9 * direction, y: p.y + 5 }]), paint: { fill: Fill(theme.line), stroke: Stroke({ color: theme.line, width: 1 }) } })]
		Open => [Shape({ path: Drawing.polygon([{ x: p.x + 2.5 * theme.line_width * direction, y: p.y }, { x: p.x - 6.5 * theme.line_width * direction, y: p.y + 6 * theme.line_width }, { x: p.x - 1.5 * theme.line_width * direction, y: p.y }, { x: p.x - 6.5 * theme.line_width * direction, y: p.y - 6 * theme.line_width }]), paint: { fill: Fill(theme.line), stroke: Stroke({ color: theme.line, width: 1 }) } })]
		Cross => [SequenceDraw.line({ x: p.x - 3 * theme.line_width, y: p.y - 2.5 * theme.line_width }, { x: p.x + 2 * theme.line_width, y: p.y + 2.5 * theme.line_width }, False, theme.line, theme.line_width), SequenceDraw.line({ x: p.x + 2 * theme.line_width, y: p.y - 2.5 * theme.line_width }, { x: p.x - 3 * theme.line_width, y: p.y + 2.5 * theme.line_width }, False, theme.line, theme.line_width)]
	}

	## Conservative shape/control-point bounds and measured text extents.
	## Used by contract fuzzing as well as regression expectations.
	contains : Drawing.Picture, Theme.Options -> Bool
	contains = |picture, theme| {
		view = picture.view
		inside = |p| p.x >= view.x - 0.001 and p.x <= view.x + view.width + 0.001 and p.y >= view.y - 0.001 and p.y <= view.y + view.height + 0.001
		style = { font: TextMeasure.inter, size: theme.font_size, line_height: theme.line_height, wrap: NoWrap, align: Middle }
		picture.items.all(
			|item| match item {
				Shape(painted) => painted.path.all(
					|segment| match segment {
						MoveTo(p) | LineTo(p) => inside(p)
						CubicTo(c) => inside(c.control_1) and inside(c.control_2) and inside(c.end)
						Close => True
					},
				)
				StyledText(styled) => {
					measured = TextMeasure.block(styled.label.text, { ..style, size: styled.label.size })
					left = match styled.label.align {
						Start => styled.label.origin.x
						Center => styled.label.origin.x - measured.width / 2
						End => styled.label.origin.x - measured.width
					}
					inside({ x: left, y: styled.label.origin.y }) and inside({ x: left + measured.width, y: styled.label.origin.y })
				}
				Text(label) => {
					measured = TextMeasure.block(label.text, { ..style, size: label.size })
					left = match label.align {
						Start => label.origin.x
						Center => label.origin.x - measured.width / 2
						End => label.origin.x - measured.width
					}
					inside({ x: left, y: label.origin.y }) and inside({ x: left + measured.width, y: label.origin.y })
				}
			},
		)
	}

	box : List(Drawing.Segment), Drawing.Color, Drawing.Color, Theme.Options -> List(Drawing.Item)
	box = |path, fill, stroke, theme| {
		body = SequenceDraw.shape(path, fill, stroke, theme.line_width)
		match theme.shadow {
			NoShadow => [body]
			Shadow(shadow) => {
				channel = |value| (value.to_f64() * (1 - shadow.opacity)).round_to_i64_try() ?? 0
				color = { red: channel(theme.background.red).to_u8_wrap(), green: channel(theme.background.green).to_u8_wrap(), blue: channel(theme.background.blue).to_u8_wrap() }
				[Shape({ path: Drawing.translate(path, { x: shadow.dx, y: shadow.dy }), paint: { fill: Fill(color), stroke: NoStroke } }), body]
			}
		}
	}

}

expect
	match SequenceParse.parse("sequenceDiagram\nA->>B: A long message that must wrap and reserve enough horizontal and vertical space for the full label\nNote left of A: Left margin annotation\nB->>B: self invocation\n") {
		Err(_) => False
		Ok(d) => {
			g = SequenceDraw.layout(d, Theme.Options.{ max_label_width: 100 })
			g.centers.len() == d.participants.len() and g.rows.len() == d.events.len() and g.width > 0 and g.height > 0
				and g.rows.map(|row| row.top).sort_with(
					|a, b| if a < b {
						Before
					} else if a > b {
						After
					} else {
						Same
					},
				) == g.rows.map(|row| row.top)
		}
	}

expect
	match SequenceParse.parse("sequenceDiagram\nA->>B: A longer label that will wrap at a narrower width\n") {
		Err(_) => False
		Ok(d) => {
			small = SequenceDraw.layout(d, Theme.Options.{ font_size: 12, max_label_width: 100 })
			large = SequenceDraw.layout(d, Theme.Options.{ font_size: 24, max_label_width: 100 })
			large.height > small.height and large.header_height > small.header_height
		}
	}

## fuzz regression: self messages reserve their entire loop width, even
## when callers choose wrapping widths larger than the default.
expect
	match SequenceParse.parse("sequenceDiagram\nA->>A: This is a deliberately lengthy self message whose line remains much wider than the default wrap width when a caller chooses a wider wrapping setting for their diagrams\n") {
		Err(_) => False
		Ok(d) => {
			theme = Theme.Options.{ max_label_width: 500 }
			SequenceDraw.contains(SequenceDraw.draw(d, theme), theme)
		}
	}

## A bidirectional self message has two arrowheads, rather than silently
## becoming a one-way self call.
expect
	match (SequenceParse.parse("sequenceDiagram\nA->>A: self\n"), SequenceParse.parse("sequenceDiagram\nA<<->>A: self\n")) {
		(Ok(one), Ok(both)) => SequenceDraw.draw(both, Theme.Options.{}).items.len() == SequenceDraw.draw(one, Theme.Options.{}).items.len() + 1
		_ => False
	}

## Blocks remain visible when a conversation has no participants.
expect
	match SequenceParse.parse("sequenceDiagram\nloop Retry\nend\n") {
		Err(_) => False
		Ok(d) => {
			p = SequenceDraw.draw(d, Theme.Options.{})
			!p.items.is_empty() and p.view.width > 0 and p.view.height > 0 and SequenceDraw.contains(p, Theme.Options.{})
		}
	}

expect
	match SequenceParse.parse("sequenceDiagram\nparticipant A\nparticipant B\nNote left of B: A long explanation that must fit between the two participant lifelines without covering the first lifeline\n") {
		Err(_) => False
		Ok(d) => {
			theme = Theme.Options.{}
			g = SequenceDraw.layout(d, theme)
			label = SequenceDraw.block("A long explanation that must fit between the two participant lifelines without covering the first lifeline", theme)
			((g.centers.get(1) ?? 0) - (g.centers.get(0) ?? 0)) > label.width + theme.padding * 2 + 16
		}
	}

## fuzz regression: deep nested activation stacks reserve their actual
## horizontal extent instead of escaping the last participant's column.
expect {
	source = "sequenceDiagram\nparticipant A\n${Str.join_with(List.repeat("activate A", 40), "\n")}\nA->>A: nested operation\n${Str.join_with(List.repeat("deactivate A", 40), "\n")}\n"
	match SequenceParse.parse(source) {
		Err(_) => False
		Ok(d) => SequenceDraw.contains(SequenceDraw.draw(d, Theme.Options.{}), Theme.Options.{})
	}
}

## fuzz regression: a large-font critical legend must remain inside the view.
expect
	match SequenceParse.parse("sequenceDiagram\ncritical Reserve resource\nC->>C: Acquire lock\nend\n") {
		Err(_) => False
		Ok(diagram) => {
			theme = Theme.Options.{ font_size: 128, max_label_width: 800 }
			SequenceDraw.contains(SequenceDraw.draw(diagram, theme), theme)
		}
	}
