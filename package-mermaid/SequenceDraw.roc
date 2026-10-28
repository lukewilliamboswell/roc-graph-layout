import Drawing
import SequenceData
import SequenceParse
import TextMeasure
import Theme

SequenceDraw :: {}.{
	Block : { lines : List(Str), width : F64, height : F64 }
	Row : { top : F64, height : F64, label : Block }
	Geometry : { centers : List(F64), widths : List(F64), rows : List(Row), header_height : F64, width : F64, height : F64, margin : F64 }

	block : Str, Theme.Options -> Block
	block = |text, theme| TextMeasure.block(text, { font: TextMeasure.inter, size: theme.font_size, line_height: theme.line_height, wrap: Width(theme.max_label_width), align: Middle })

	text : Block, F64, F64, Drawing.Color, Theme.Options -> List(Drawing.Item)
	text = |label, x, top, color, theme| label.lines.map_with_index(|line, i| Text({ text: line, origin: { x, y: top + theme.font_size + i.to_f64() * theme.font_size * theme.line_height }, size: theme.font_size, align: Center, color }))

	shape : List(Drawing.Segment), Drawing.Color, Drawing.Color, F64 -> Drawing.Item
	shape = |path, fill, stroke, width| Shape({ path, paint: { fill: Fill(fill), stroke: Stroke({ color: stroke, width }) } })

	line : Drawing.Point, Drawing.Point, Bool, Drawing.Color, F64 -> Drawing.Item
	line = |a, b, dotted, color, width| {
		dx = b.x - a.x
		dy = b.y - a.y
		length = (dx * dx + dy * dy).sqrt()
		var $path = []
		if !dotted or length == 0 {
			$path = [MoveTo(a), LineTo(b)]
		} else {
			var $at = 0.0
			while $at < length {
				stop = ($at + 4).min(length)
				$path = $path.concat([MoveTo({ x: a.x + dx * $at / length, y: a.y + dy * $at / length }), LineTo({ x: a.x + dx * stop / length, y: a.y + dy * stop / length })])
				$at = $at + 8
			}
		}
		Shape({ path: $path, paint: { fill: NoFill, stroke: Stroke({ color, width }) } })
	}

	event_text : SequenceData.Event -> Str
	event_text = |event| match event {
		Message(m) => m.text
		Note(n) => n.text
		StartBlock(b) => "${b.kind}  ${b.text}"
		Branch(b) => "${b.kind}  ${b.text}"
		_ => ""
	}

	layout : SequenceData.Diagram, Theme.Options -> Geometry
	layout = |diagram, theme| {
		labels = diagram.participants.map(|p| SequenceDraw.block(p.label, theme))
		var $widths = labels.map(|b| (b.width + theme.padding * 2).max(80))
		var $header_height = theme.font_size + theme.padding * 2
		for i in 0..<diagram.participants.len() {
			label = labels.get(i) ?? { lines: [], width: 0, height: 0 }
			participant = diagram.participants.get(i) ?? { id: "", label: "", actor: False }
			$header_height = $header_height.max(
				label.height + theme.padding * 2 + if participant.actor {
					42
				} else {
					0
				},
			)
		}
		var $texts = []
		var $number = 0.U64
		var $gap = 48.0
		var $depth = 0.U64
		var $max_depth = 0.U64
		var $left_note = 0.0
		var $right_note = 0.0
		var $frame_width = 0.0
		var $activation_depths = List.repeat(0.U64, diagram.participants.len())
		for event in diagram.events {
			raw = SequenceDraw.event_text(event)
			label_text = match event {
				Message(_) => {
					$number = $number + 1
					if diagram.autonumber {
						"${$number.to_str()}. ${raw}"
					} else {
						raw
					}
				}
				_ => raw
			}
			label = SequenceDraw.block(label_text, theme)
			$texts = $texts.append(label)
			action = match event {
				Activate(index) => Some({ index, start: True })
				Deactivate(index) => Some({ index, start: False })
				Message(m) => match m.activation {
					Keep => None
					Start => Some({ index: m.to, start: True })
					Stop => Some({ index: m.from, start: False })
				}
				_ => None
			}
			match action {
				None => {}
				Some(a) => {
					depth = $activation_depths.get(a.index) ?? 0
					if a.start {
						next = depth + 1
						# Parsed activation indices are in bounds. A wide header
						# also reserves space for the stack beside its lifeline.
						$activation_depths = $activation_depths.set(a.index, next) ?? []
						$widths = $widths.set(a.index, ($widths.get(a.index) ?? 0).max((next.to_f64() * 5 + 12) * 2)) ?? []
					} else if depth > 0 {
						$activation_depths = $activation_depths.set(a.index, depth - 1) ?? []
					}
				}
			}
			match event {
				Message(m) => {
					hops = if m.from > m.to {
						m.from - m.to
					} else {
						m.to - m.from
					}
					if hops == 0 {
						$gap = $gap.max(label.width + theme.padding * 2 + 40)
						if m.from + 1 == diagram.participants.len() {
							$right_note = $right_note.max(label.width.max(60) + 40)
						}
					} else {
						$gap = $gap.max((label.width + theme.padding * 2 + 24) / hops.to_f64())
					}
				}
				Note(n) => {
					if n.from == n.to and n.side == Over and n.from < $widths.len() {
						$widths = $widths.set(n.from, ($widths.get(n.from) ?? 0).max(label.width + theme.padding * 2)) ?? []
					}
					if n.side == Left {
						if n.from == 0 {
							$left_note = $left_note.max(label.width + theme.padding * 2 + 20)
						}
						else {
							$gap = $gap.max(label.width + theme.padding * 2 + 32)
						}
					}
					if n.side == Right {
						if n.from + 1 == diagram.participants.len() {
							$right_note = $right_note.max(label.width + theme.padding * 2 + 20)
						}
						else {
							$gap = $gap.max(label.width + theme.padding * 2 + 32)
						}
					}
				}
				StartBlock(_) => {
					$frame_width = $frame_width.max(label.width + theme.padding * 4 + 48)
					$depth = $depth + 1
					$max_depth = $max_depth.max($depth)
				}
				Branch(_) => {
					$frame_width = $frame_width.max(label.width + theme.padding * 4 + 48)
				}
				EndBlock => {
					if $depth > 0 {
						$depth = $depth - 1
					}
				}
				_ => {}
			}
		}
		frame_margin = $max_depth.to_f64() * 12
		margin = 24 + theme.padding + frame_margin
		var $x = margin + $left_note
		var $centers = []
		for width in $widths {
			$centers = $centers.append($x + width / 2)
			$x = $x + width + $gap
		}
		columns_width = if $widths.is_empty() {
			0
		} else {
			$x - $gap + $right_note + margin
		}
		chart_width = columns_width.max($frame_width)
		title = SequenceDraw.block(diagram.title, theme)
		final_width = chart_width.max(
			if diagram.title.is_empty() {
				0
			} else {
				title.width + margin * 2
			},
		)
		title_height = if diagram.title.is_empty() {
			0
		} else {
			title.height + theme.padding * 2
		}
		var $top = margin + title_height + $header_height + 24
		var $rows = []
		for i in 0..<diagram.events.len() {
			label = $texts.get(i) ?? { lines: [], width: 0, height: 0 }
			event = diagram.events.get(i) ?? EndBlock
			height = match event {
				Message(m) => label.height + 32 + if m.from == m.to {
					28
				} else {
					0
				}
				Note(_) => label.height + theme.padding * 2 + 20
				StartBlock(_) | Branch(_) => label.height + theme.padding * 2 + 12
				EndBlock => 18
				Activate(_) | Deactivate(_) => 12
			}
			$rows = $rows.append({ top: $top, height, label })
			$top = $top + height
		}
		{
			centers: $centers,
			widths: $widths,
			rows: $rows,
			header_height: $header_height,
			width: final_width,
			height: if $widths.is_empty() and diagram.events.is_empty() and diagram.title.is_empty() {
				0
			} else {
				$top + 24 + $header_height + margin
			},
			margin,
		}
	}

	draw : SequenceData.Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, theme| {
		geometry = SequenceDraw.layout(diagram, theme)
		if diagram.participants.is_empty() and diagram.events.is_empty() {
			label = SequenceDraw.block(diagram.title, theme)
			if diagram.title.is_empty() {
				return { view: { x: 0, y: 0, width: 0, height: 0 }, items: [] }
			}
			view = { x: 0, y: 0, width: label.width + theme.padding * 2, height: label.height + theme.padding * 2 }
			background = Shape({ path: Drawing.rectangle(view), paint: { fill: Fill(theme.background), stroke: NoStroke } })
			return { view, items: [background].concat(SequenceDraw.text(label, view.width / 2, theme.padding, theme.node_text, theme)) }
		}
		var $items = []
		title = SequenceDraw.block(diagram.title, theme)
		title_height = if diagram.title.is_empty() {
			0
		} else {
			title.height + theme.padding * 2
		}
		header_y = geometry.margin + title_height
		footer_y = geometry.height - geometry.margin - geometry.header_height
		if !diagram.title.is_empty() {
			$items = $items.concat(SequenceDraw.text(title, geometry.width / 2, geometry.margin, theme.node_text, theme))
		}
		# Frames are drawn before lifelines and message content.
		var $frames = []
		var $frame_items = []
		for i in 0..<diagram.events.len() {
			row = geometry.rows.get(i) ?? { top: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
			match diagram.events.get(i) ?? EndBlock {
				StartBlock(_) => {
					$frames = $frames.append({ top: row.top, depth: $frames.len() })
				}
				EndBlock => match $frames.last() {
					Err(_) => {}
					Ok(frame) => {
						x = theme.padding + 12 + frame.depth.to_f64() * 12
						rect = { x, y: frame.top, width: (geometry.width - 2 * x).max(0), height: row.top + row.height - frame.top }
						$frame_items = $frame_items.append(SequenceDraw.shape(Drawing.rounded_rectangle(rect, theme.corner_radius), theme.group_fill, theme.group_stroke, theme.line_width))
						$frames = $frames.drop_last(1)
					}
				}
				_ => {}
			}
		}
		# Close order is inner first, so reverse it to paint outer frames first.
		$items = $items.concat($frame_items.rev())
		for x in geometry.centers {
			$items = $items.append(SequenceDraw.line({ x, y: header_y + geometry.header_height }, { x, y: footer_y }, True, theme.group_stroke, theme.line_width))
		}
		# Activation bars sit above lifelines and below message arrows.
		var $activations = []
		for i in 0..<diagram.events.len() {
			row = geometry.rows.get(i) ?? { top: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
			event = diagram.events.get(i) ?? EndBlock
			action = match event {
				Activate(index) => Some({ index, start: True })
				Deactivate(index) => Some({ index, start: False })
				Message(m) => match m.activation {
					Keep => None
					Start => Some({ index: m.to, start: True })
					Stop => Some({ index: m.from, start: False })
				}
				_ => None
			}
			match action {
				None => {}
				Some(a) => {
					y = row.top + match event {
						Message(m) => row.label.height + 8 + if m.from == m.to {
							28
						} else {
							0
						}
						_ => 0
					}
					if a.start {
						depth = $activations.count_if(|entry| entry.index == a.index)
						$activations = $activations.append({ index: a.index, top: y, depth })
					} else {
						match $activations.rev().find_first_index(|entry| entry.index == a.index) {
							Err(_) => {}
							Ok(reverse_index) => {
								index = $activations.len() - reverse_index - 1
								active = $activations.get(index) ?? { index: a.index, top: y, depth: 0 }
								$items = $items.append(SequenceDraw.activation(active, y, geometry, theme))
								$activations = $activations.take_first(index).concat($activations.drop_first(index + 1))
							}
						}
					}
				}
			}
		}
		for active in $activations {
			$items = $items.append(SequenceDraw.activation(active, footer_y, geometry, theme))
		}
		for i in 0..<diagram.events.len() {
			row = geometry.rows.get(i) ?? { top: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
			match diagram.events.get(i) ?? EndBlock {
				Message(m) => {
					from_x = geometry.centers.get(m.from) ?? 0
					to_x = geometry.centers.get(m.to) ?? 0
					y = row.top + row.label.height + 8
					self_message = m.from == m.to
					text_x = if self_message {
						from_x + row.label.width / 2 + 20
					} else {
						(from_x + to_x) / 2
					}
					$items = $items.concat(SequenceDraw.text(row.label, text_x, row.top, theme.label_text, theme))
					if self_message {
						right = from_x + row.label.width.max(60) + 24
						$items = $items.append(SequenceDraw.line({ x: from_x, y }, { x: right, y }, m.dotted, theme.line, theme.line_width))
						$items = $items.append(SequenceDraw.line({ x: right, y }, { x: right, y: y + 28 }, m.dotted, theme.line, theme.line_width))
						$items = $items.append(SequenceDraw.line({ x: right, y: y + 28 }, { x: to_x, y: y + 28 }, m.dotted, theme.line, theme.line_width))
						$items = $items.concat(SequenceDraw.head({ x: to_x, y: y + 28 }, -1, m.head, theme))
						if m.both {
							$items = $items.concat(SequenceDraw.head({ x: from_x, y }, -1, m.head, theme))
						}
					} else {
						direction = if to_x >= from_x {
							1.0
						} else {
							-1.0
						}
						$items = $items.append(SequenceDraw.line({ x: from_x, y }, { x: to_x, y }, m.dotted, theme.line, theme.line_width))
						$items = $items.concat(SequenceDraw.head({ x: to_x, y }, direction, m.head, theme))
						if m.both {
							$items = $items.concat(SequenceDraw.head({ x: from_x, y }, -direction, m.head, theme))
						}
					}
				}
				Note(n) => {
					first = geometry.centers.get(n.from) ?? 0
					last = geometry.centers.get(n.to) ?? 0
					width = row.label.width + theme.padding * 2
					x = match n.side {
						Left => first - width - 16
						Right => first + 16
						Over => (first + last) / 2 - width / 2
					}
					rect = { x, y: row.top, width, height: row.label.height + theme.padding * 2 }
					$items = $items.concat(SequenceDraw.box(Drawing.rounded_rectangle(rect, theme.corner_radius), theme.group_fill, theme.group_stroke, theme))
					$items = $items.concat(SequenceDraw.text(row.label, x + width / 2, row.top + theme.padding, theme.label_text, theme))
				}
				StartBlock(_) => {
					$items = $items.concat(SequenceDraw.frame_label(row, geometry, theme))
				}
				Branch(_) => {
					$items = $items.append(SequenceDraw.line({ x: theme.padding + 12, y: row.top }, { x: geometry.width - theme.padding - 12, y: row.top }, True, theme.group_stroke, theme.line_width))
					$items = $items.concat(SequenceDraw.frame_label(row, geometry, theme))
				}
				_ => {}
			}
		}
		for i in 0..<diagram.participants.len() {
			participant = diagram.participants.get(i) ?? { id: "", label: "", actor: False }
			x = geometry.centers.get(i) ?? 0
			width = geometry.widths.get(i) ?? 0
			for y in [header_y, footer_y] {
				$items = $items.concat(SequenceDraw.participant(participant, { x: x - width / 2, y, width, height: geometry.header_height }, theme))
			}
		}
		extent = match theme.shadow {
			NoShadow => { left: 0.0, top: 0.0, right: 0.0, bottom: 0.0 }
			Shadow(shadow) => { left: (-shadow.dx).max(0), top: (-shadow.dy).max(0), right: shadow.dx.max(0), bottom: shadow.dy.max(0) }
		}
		stroke_margin = theme.line_width / 2
		view = { x: -extent.left - stroke_margin, y: -extent.top - stroke_margin, width: geometry.width + extent.left + extent.right + stroke_margin * 2, height: geometry.height + extent.top + extent.bottom + stroke_margin * 2 }
		background = Shape({ path: Drawing.rectangle(view), paint: { fill: Fill(theme.background), stroke: NoStroke } })
		{ view, items: [background].concat($items) }
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
				Text(label) => {
					measured = TextMeasure.block(label.text, style)
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

	frame_label : Row, Geometry, Theme.Options -> List(Drawing.Item)
	frame_label = |row, _geometry, theme| {
		rect = { x: theme.padding + 24, y: row.top + 2, width: row.label.width + theme.padding * 2, height: row.label.height + theme.padding * 2 }
		[SequenceDraw.shape(Drawing.rounded_rectangle(rect, theme.corner_radius), theme.label_background, theme.group_stroke, theme.line_width)].concat(SequenceDraw.text(row.label, rect.x + rect.width / 2, rect.y + theme.padding, theme.node_text, theme))
	}

	activation : { index : U64, top : F64, depth : U64 }, F64, Geometry, Theme.Options -> Drawing.Item
	activation = |active, bottom, geometry, theme| {
		x = (geometry.centers.get(active.index) ?? 0) - 6 + active.depth.to_f64() * 5
		SequenceDraw.shape(Drawing.rectangle({ x, y: active.top, width: 12, height: (bottom - active.top).max(0) }), theme.node_fill, theme.accent, theme.line_width)
	}

	head : Drawing.Point, F64, [None, Arrow, Open, Cross], Theme.Options -> List(Drawing.Item)
	head = |p, direction, kind, theme| match kind {
		None => []
		Arrow => [SequenceDraw.shape(Drawing.polygon([{ x: p.x - direction * 9, y: p.y - 4 }, p, { x: p.x - direction * 9, y: p.y + 4 }]), theme.line, theme.line, theme.line_width)]
		Open => [SequenceDraw.line({ x: p.x - direction * 9, y: p.y - 4 }, p, False, theme.line, theme.line_width), SequenceDraw.line(p, { x: p.x - direction * 9, y: p.y + 4 }, False, theme.line, theme.line_width)]
		Cross => [SequenceDraw.line({ x: p.x - 5, y: p.y - 5 }, { x: p.x + 5, y: p.y + 5 }, False, theme.line, theme.line_width), SequenceDraw.line({ x: p.x - 5, y: p.y + 5 }, { x: p.x + 5, y: p.y - 5 }, False, theme.line, theme.line_width)]
	}

	participant : SequenceData.Participant, Drawing.Rect, Theme.Options -> List(Drawing.Item)
	participant = |p, rect, theme| {
		x = rect.x + rect.width / 2
		label = SequenceDraw.block(p.label, theme)
		if p.actor {
			y = rect.y + 8
			[
				SequenceDraw.shape(Drawing.ellipse({ x, y }, 7, 7), theme.node_fill, theme.node_stroke, theme.line_width),
				SequenceDraw.line({ x, y: y + 7 }, { x, y: y + 24 }, False, theme.node_stroke, theme.line_width),
				SequenceDraw.line({ x: x - 12, y: y + 14 }, { x: x + 12, y: y + 14 }, False, theme.node_stroke, theme.line_width),
				SequenceDraw.line({ x, y: y + 24 }, { x: x - 10, y: y + 34 }, False, theme.node_stroke, theme.line_width),
				SequenceDraw.line({ x, y: y + 24 }, { x: x + 10, y: y + 34 }, False, theme.node_stroke, theme.line_width),
			].concat(SequenceDraw.text(label, x, rect.y + 46, theme.node_text, theme))
		} else {
			SequenceDraw.box(Drawing.rounded_rectangle(rect, theme.corner_radius), theme.node_fill, theme.node_stroke, theme).concat(SequenceDraw.text(label, x, rect.y + (rect.height - label.height) / 2, theme.node_text, theme))
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
