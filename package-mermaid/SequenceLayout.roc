import Drawing
import FlowText
import SequenceData
import SequenceStyle
import TextMeasure
import Theme
import font.Font

## Sequence geometry follows the pinned Mermaid renderer's actor bands,
## per-actor message margins and source-ordered vertical bounds updates.
SequenceLayout :: {}.{
	Block : { lines : List(Str), width : F64, height : F64 }
	Row : { top : F64, height : F64, label : Block }
	Label : { id : Str, text : Str, box : Drawing.Rect, origin : Drawing.Point, size : F64, role : Str }
	Frame : { index : U64, kind : Str, top : F64, left : F64, right : F64, bottom : F64, branches : List(U64) }
	Geometry : {
		centers : List(F64),
		widths : List(F64),
		rows : List(Row),
		header_height : F64,
		width : F64,
		height : F64,
		margin : F64,
		footer_y : F64,
		view : Drawing.Rect,
		headers : List(Drawing.Rect),
		footers : List(Drawing.Rect),
		notes : List(Drawing.Rect),
		message_points : List(List(Drawing.Point)),
		frames : List(Frame),
		activations : List({ index : U64, rect : Drawing.Rect }),
		labels : List(Label),
		numbers : List({ center : Drawing.Point, text : Str }),
	}

	line_height : Theme.Options -> F64
	line_height = |theme| {
		style = { font: TextMeasure.inter, size: theme.font_size, line_height: 1, wrap: NoWrap, align: Middle }
		metrics = TextMeasure.metrics_of(style)
		(metrics.ascent + metrics.descent).max(theme.font_size * 1.2)
	}

	measure : Str, Bool, F64, Theme.Options -> Block
	measure = |text, wrap, width, theme| {
		measured = TextMeasure.block(
			text,
			{
				font: TextMeasure.inter,
				size: theme.font_size,
				line_height: theme.line_height,
				wrap: if wrap {
					Width(width.max(0.001))
				} else {
					NoWrap
				},
				align: Middle,
			},
		)
		glyph_height = SequenceLayout.line_height(theme)
		height = if text.is_empty() {
			0
		} else {
			glyph_height + (measured.lines.len().max(1) - 1).to_f64() * glyph_height * theme.line_height
		}
		{
			lines: if text.is_empty() {
				[]
			} else {
				measured.lines
			},
			width: measured.width,
			height,
		}
	}

	measure_source : Str, Str, Bool, F64, Theme.Options -> Block
	measure_source = |display, stored, wrap, width, theme| {
		measured = SequenceLayout.measure(stored, SequenceStyle.wrap(wrap, theme), width, theme)
		if stored == display {
			measured
		} else { ..measured, lines: measured.lines.map(FlowText.display) }
	}

	text_labels : Str, Block, F64, F64, F64, Str, Theme.Options -> List(Label)
	text_labels = |id, block, x, top, step, role, theme| {
		metrics = TextMeasure.metrics_of({ font: TextMeasure.inter, size: theme.font_size, line_height: theme.line_height, wrap: NoWrap, align: Middle })
		block.lines.map_with_index(
			|text, i| {
				single = SequenceLayout.measure(text, False, 0, theme)
				y = top + i.to_f64() * step
				{
					id: if block.lines.len() == 1 {
						id
					} else {
						"${id}-row-${i.to_str()}"
					},
					text,
					box: {
						x: if role == "title" {
							x
						} else {
							x - single.width / 2
						},
						y,
						width: single.width,
						height: SequenceLayout.line_height(theme),
					},
					origin: { x, y: y + metrics.ascent },
					size: theme.font_size,
					role,
				}
			},
		)
	}

	zero_rect : Drawing.Rect
	zero_rect = { x: 0, y: 0, width: 0, height: 0 }

	Size : { kind : Str, id : Str, width : F64, height : F64 }
	measured : List(Size), Str, Block -> Block
	measured = |sizes, id, block| match sizes.find_first(|size| size.kind == "label" and size.id == id) {
		Ok(size) => { ..block, width: size.width, height: TextMeasure.round(size.height) }
		Err(_) => {
			rows = sizes.keep_if(|size| size.kind == "label" and size.id.starts_with("${id}-row-"))
			if rows.is_empty() {
				block
			} else { ..block, width: rows.fold(0.0, |width, size| width.max(size.width)), height: rows.fold(0.0, |height, size| height + TextMeasure.round(size.height)) }
		}
	}

	layout : SequenceData.Diagram, Theme.Options -> Geometry
	layout = |diagram, theme| SequenceLayout.layout_with_sizes(diagram, theme, [])

	layout_with_sizes : SequenceData.Diagram, Theme.Options, List(Size) -> Geometry
	layout_with_sizes = |diagram, options, sizes| {
		theme = SequenceStyle.resolve(options)
		n = diagram.participants.len()
		padding = theme.padding
		minimum_width = 150.0
		actor_labels = diagram.participants.map(|p| SequenceLayout.measured(sizes, "participant-header-${p.id}", SequenceLayout.measure_source(p.label, p.source_text, p.wrap, theme.max_label_width, theme)))
		widths = actor_labels.map_with_index(
			|b, i| {
				p = diagram.participants.get(i) ?? { id: "", label: "", actor: False, wrap: False, source_text: "" }
				match sizes.find_first(|size| size.kind == "node" and size.id == p.id) {
					Ok(size) => size.width
					Err(_) => if SequenceStyle.wrap(p.wrap, theme) {
						(theme.max_label_width + padding * 2).max(minimum_width)
					} else {
						(TextMeasure.round(b.width) + padding * 2).max(minimum_width)
					}
				}
			},
		)
		header_height = actor_labels.map_with_index(
			|b, i| {
				participant = diagram.participants.get(i) ?? { id: "", label: "", actor: False, wrap: False, source_text: "" }
				match sizes.find_first(|size| size.kind == "node" and size.id == participant.id) {
					Ok(size) => size.height
					Err(_) => (56 + b.height).max(65)
				}
			},
		).fold(0.0, |height, actual| height.max(actual))
		var $ids = List.repeat("", diagram.events.len())
		var $mi = 0.U64
		var $ni = 0.U64
		var $ci = 0.U64
		for i in 0..<diagram.events.len() {
			key = match diagram.events.get(i) ?? EndBlock {
				Message(_) => {
					id = "message-${$mi.to_str()}"
					$mi = $mi + 1
					id
				}
				Note(_) => {
					id = "note-${$ni.to_str()}"
					$ni = $ni + 1
					id
				}
				StartBlock(_) | Branch(_) => {
					id = "block-${$ci.to_str()}"
					$ci = $ci + 1
					id
				}
				_ => ""
			}
			$ids = $ids.set(i, key) ?? []
		}
		# Mermaid seats adjacent actors from their own largest connecting
		# message, rather than a global largest gap applied to every column.
		var $margins = List.repeat(50.0, n)
		for event_index in 0..<diagram.events.len() {
			event = diagram.events.get(event_index) ?? EndBlock
			match event {
				Message(m) => {
					b = SequenceLayout.measured(sizes, $ids.get(event_index) ?? "", SequenceLayout.measure_source(m.text, m.source_text, m.wrap, theme.max_label_width, theme))
					w = TextMeasure.round(b.width) + padding * 2
					left = m.from.min(m.to)
					if m.from == m.to {
						if left < n {
							next_width = widths.get(left + 1) ?? 0
							required = w / 2 + 50 - (widths.get(left) ?? 0) / 2 - next_width / 2
							$margins = $margins.set(left, ($margins.get(left) ?? 50).max(required)) ?? []
						}
					} else if m.from + 1 == m.to or m.to + 1 == m.from {
						required = w + 50 - (widths.get(left) ?? 0) / 2 - (widths.get(left + 1) ?? 0) / 2
						$margins = $margins.set(left, ($margins.get(left) ?? 50).max(required)) ?? []
					}
				}
				Note(note) => {
					b = SequenceLayout.measured(sizes, $ids.get(event_index) ?? "", SequenceLayout.measure_source(note.text, note.source_text, note.wrap, theme.max_label_width, theme))
					w = TextMeasure.round(b.width) + padding * 2
					slot = match note.side {
						Left => if note.from > 0 {
							Some(note.from - 1)
						} else {
							None
						}
						Right => if note.from + 1 < n {
							Some(note.from)
						} else {
							None
						}
						Over => if note.to > 0 {
							Some(note.to - 1)
						} else {
							None
						}
					}
					match slot {
						None => {}
						Some(i) => {
							amount = if note.side == Over {
								w / 2
							} else {
								w
							}
							required = amount + 50 - (widths.get(i) ?? 0) / 2 - (widths.get(i + 1) ?? 0) / 2
							$margins = $margins.set(i, ($margins.get(i) ?? 50).max(required)) ?? []
						}
					}
				}
				_ => {}
			}
		}
		var $headers = []
		var $centers = []
		var $x = 0.0
		for i in 0..<n {
			width = widths.get(i) ?? minimum_width
			$headers = $headers.append({ x: $x, y: 0, width, height: header_height })
			$centers = $centers.append($x + width / 2)
			$x = $x + width + ($margins.get(i) ?? 50)
		}
		content_width = if n == 0 {
			0
		} else {
			$x - ($margins.last() ?? 50)
		}
		# A first pass derives caption wrapping widths from the actors and
		# messages a block actually contains (Mermaid calculateLoopBounds).
		var $caption_widths = List.repeat(minimum_width, diagram.events.len())
		var $spans = []
		for i in 0..<diagram.events.len() {
			match diagram.events.get(i) ?? EndBlock {
				StartBlock(_) => {
					$spans = $spans.append({ index: i, left: F64.infinity, right: -F64.infinity, width: 0.0, branches: [] })
				}
				Branch(_) => if !$spans.is_empty() {
					last = $spans.last() ?? { index: 0, left: 0, right: 0, width: 0, branches: [] }
					$spans = $spans.set($spans.len() - 1, { ..last, branches: last.branches.append(i) }) ?? []
				}
				EndBlock => match $spans.last() {
					Err(_) => {}
					Ok(span) => {
						width = span.width.max(minimum_width - 50)
						$caption_widths = $caption_widths.set(span.index, width) ?? []
						for branch in span.branches {
							$caption_widths = $caption_widths.set(branch, width) ?? []
						}
						$spans = $spans.drop_last(1)
					}
				}
				Message(m) => {
					b = SequenceLayout.measured(sizes, $ids.get(i) ?? "", SequenceLayout.measure_source(m.text, m.source_text, m.wrap, theme.max_label_width, theme))
					from = $centers.get(m.from) ?? 0
					to = $centers.get(m.to) ?? 0
					model_width = (TextMeasure.round(b.width) + padding * 2).max((from - to).abs() + padding * 2).max(minimum_width)
					$spans = $spans.map(
						|span| {
							left = if m.from == m.to {
								span.left.min(($headers.get(m.from) ?? SequenceLayout.zero_rect).x - model_width / 2).min(($headers.get(m.from) ?? SequenceLayout.zero_rect).x - (widths.get(m.from) ?? 0) / 2)
							} else {
								span.left.min(from + 1)
							}
							right = if m.from == m.to {
								span.right.max(($headers.get(m.to) ?? SequenceLayout.zero_rect).x + model_width / 2)
							} else {
								span.right.max(to - 1)
							}
							{ ..span, left, right, width: span.width.max((right - left).abs()).max(model_width) - 50 }
						},
					)
				}
				_ => {}
			}
		}
		var $rows = []
		var $points = List.repeat([], diagram.events.len())
		var $notes = List.repeat(SequenceLayout.zero_rect, diagram.events.len())
		var $labels = []
		var $frames = []
		var $open = []
		var $active = []
		var $activations = []
		var $numbers = []
		var $number = 1.0
		var $step = 1.0
		var $numbered = False
		var $message_index = 0.U64
		var $note_index = 0.U64
		var $control_index = 0.U64
		var $current = header_height
		var $min_x = 0.0
		var $max_x = content_width
		var $max_y = header_height
		metrics = Font.metrics(TextMeasure.inter)
		x_half = metrics.x_height.to_f64() * theme.font_size / Font.units_per_em(TextMeasure.inter).to_f64() / 2
		glyph_height = SequenceLayout.line_height(theme)
		for i in 0..<diagram.events.len() {
			event = diagram.events.get(i) ?? EndBlock
			start = $current
			var $row_label = { lines: [], width: 0.0, height: 0.0 }
			var $insert = None
			var $activation = None
			match event {
				Numbering(numbering) => {
					$numbered = numbering.visible
					match numbering.start {
						None => {}
						Some(value) => {
							if value != 0 {
								$number = value
							}
						}
					}
					match numbering.step {
						None => {}
						Some(value) => {
							if value != 0 {
								$step = value
							}
						}
					}
				}
				Activate(index) => {
					$activation = Some({ index, start: True })
				}
				Deactivate(index) => {
					$activation = Some({ index, start: False })
				}
				Message(m) => {
					from = $centers.get(m.from) ?? 0
					to = $centers.get(m.to) ?? 0
					from_bounds = $active.fold(
						{ left: from - 1, right: from + 1 },
						|b, a| if (a.index == m.from) { left: b.left.min(a.rect.x), right: b.right.max(a.rect.x + a.rect.width) } else {
							b
						},
					)
					to_bounds = $active.fold(
						{ left: to - 1, right: to + 1 },
						|b, a| if (a.index == m.to) { left: b.left.min(a.rect.x), right: b.right.max(a.rect.x + a.rect.width) } else {
							b
						},
					)
					direction = if from_bounds.left <= to_bounds.left {
						1.0
					} else {
						-1.0
					}
					source_x = if direction > 0 {
						from_bounds.right
					} else {
						from_bounds.left
					}
					target_base = if direction > 0 {
						to_bounds.left
					} else {
						to_bounds.right
					}
					# Neo's endpoint clearances and arrow-marker inset are
					# part of route geometry, including unfilled arrows.
					source_adjusted = source_x + if m.both {
						direction * 6
					} else {
						0
					}
					target_adjusted = target_base - direction * (
						if !m.dotted and m.head == None {
							0
						} else {
							3
						}
					) - direction * (
						if m.head == None {
							0
						} else {
							3
						}
					) - direction * (
						if m.activation == Start and (to_bounds.right - to_bounds.left).abs() <= 2 {
							4
						} else {
							0
						}
					)
					self_message = m.from == m.to
					end_x = if self_message {
						source_adjusted
					} else {
						target_adjusted
					}
					b = SequenceLayout.measured(sizes, $ids.get(i) ?? "", SequenceLayout.measure_source(m.text, m.source_text, m.wrap, (source_adjusted - end_x).abs().max(minimum_width) + padding * 2, theme))
					$row_label = b
					line_box = if b.lines.is_empty() {
						glyph_height
					} else {
						b.height / b.lines.len().to_f64()
					}
					line_y = start + line_box + b.height + 10
					$current = line_y + if self_message {
						30
					} else {
						0
					}
					number_offset = if $numbered and !self_message {
						if m.both {
							if direction > 0 {
								12
							} else {
								-6
							}
						} else {
							6
						}
					} else {
						0
					}
					point_x = source_adjusted + number_offset
					points = if self_message {
						initial_x = source_adjusted + if $numbered and m.both {
							10
						} else {
							0
						}
						[{ x: initial_x, y: line_y }, { x: initial_x + 60, y: line_y - 10 }, { x: source_adjusted + 60, y: line_y + 30 }, { x: source_adjusted, y: line_y + 20 }]
					} else {
						[{ x: point_x, y: line_y }, { x: end_x, y: line_y }]
					}
					$points = $points.set(i, points) ?? []
					text_x = if self_message {
						source_adjusted
					} else {
						TextMeasure.round(source_adjusted.min(end_x) + (source_adjusted - end_x).abs() / 2)
					}
					text_y_attr = TextMeasure.round(start + 10 + padding / 2)
					label_top = text_y_attr + theme.font_size + x_half - TextMeasure.metrics_of({ font: TextMeasure.inter, size: theme.font_size, line_height: 1, wrap: NoWrap, align: Middle }).ascent
					$labels = $labels.concat(SequenceLayout.text_labels("message-${$message_index.to_str()}", b, text_x, label_top, glyph_height * theme.line_height, "message", theme))
					if $numbered {
						number_x = if direction > 0 {
							from_bounds.left.min(to_bounds.left) + 1
						} else {
							from_bounds.right.max(to_bounds.right) - 1
						}
						$numbers = $numbers.append({ center: { x: number_x, y: line_y }, text: $number.to_str() })
					}
					$message_index = $message_index + 1
					$number = TextMeasure.round(($number + $step) * 100) / 100
					x0 = if self_message {
						source_adjusted - TextMeasure.round(b.width).max(minimum_width) / 2
					} else {
						from_bounds.left.min(to_bounds.left)
					}
					x1 = if self_message {
						source_adjusted + TextMeasure.round(b.width).max(minimum_width) / 2
					} else {
						from_bounds.right.max(to_bounds.right)
					}
					$insert = Some({
						x: x0,
						y: start,
						width: x1 - x0,
						height: if self_message {
							$current - start + 20
						} else {
							$current - start
						},
					})
					match m.activation {
						Keep => {}
						Start => {
							$activation = Some({ index: m.to, start: True })
						}
						Stop => {
							$activation = Some({ index: m.from, start: False })
						}
					}
				}
				Note(note) => {
					first = $headers.get(note.from) ?? SequenceLayout.zero_rect
					last = $headers.get(note.to) ?? SequenceLayout.zero_rect
					b = SequenceLayout.measured(sizes, $ids.get(i) ?? "", SequenceLayout.measure_source(note.text, note.source_text, note.wrap, theme.max_label_width, theme))
					width = if SequenceStyle.wrap(note.wrap, theme) {
						(theme.max_label_width + padding * 2).max(minimum_width)
					} else {
						(TextMeasure.round(b.width) + padding * 2).max(
							if note.side == Over and note.from == note.to {
								first.width.max(minimum_width)
							} else {
								(first.width + last.width) / 2
							},
						)
					}
					actual_width = if note.side == Over and note.from != note.to {
						((first.x + first.width / 2) - (last.x + last.width / 2)).abs() + 50
					} else {
						width
					}
					x = match note.side {
						Left => first.x - actual_width + (first.width - 50) / 2
						Right => first.x + (first.width + 50) / 2
						Over => if note.from == note.to {
							first.x + (first.width - actual_width) / 2
						} else {
							(first.x + first.width / 2).min(last.x + last.width / 2) - 25
						}
					}
					wrapped = SequenceLayout.measured(sizes, $ids.get(i) ?? "", SequenceLayout.measure_source(note.text, note.source_text, note.wrap, actual_width - padding * 2, theme))
					$row_label = wrapped
					rect = { x, y: start + 10, width: actual_width, height: wrapped.height + padding * 2 }
					$notes = $notes.set(i, rect) ?? []
					$current = rect.y + rect.height
					label_top = TextMeasure.round(rect.y + padding / 2) + theme.font_size + x_half - TextMeasure.metrics_of({ font: TextMeasure.inter, size: theme.font_size, line_height: 1, wrap: NoWrap, align: Middle }).ascent
					$labels = $labels.concat(SequenceLayout.text_labels("note-${$note_index.to_str()}", wrapped, TextMeasure.round(rect.x + rect.width / 2), label_top, glyph_height * theme.line_height, "note", theme))
					$note_index = $note_index + 1
					$insert = Some(rect)
				}
				StartBlock(b) => {
					caption = SequenceLayout.measured(
						sizes,
						$ids.get(i) ?? "",
						SequenceLayout.measure_source(
							if b.text.is_empty() {
								""
							} else {
								"[${b.text}]"
							},
							if b.source_text.is_empty() {
								""
							} else {
								"[${b.source_text}]"
							},
							True,
							($caption_widths.get(i) ?? minimum_width) - padding * 2,
							theme,
						),
					)
					$row_label = caption
					$open = $open.append({ index: i, kind: b.kind, top: start + 10, left: F64.infinity, right: -F64.infinity, bottom: start + 10, branches: [] })
					$current = start + 25 + if b.text.is_empty() {
						0
					} else {
						caption.height.max(20)
					}
					$control_index = $control_index + 1
				}
				Branch(b) => {
					caption = SequenceLayout.measured(
						sizes,
						$ids.get(i) ?? "",
						SequenceLayout.measure_source(
							if b.text.is_empty() {
								""
							} else {
								"[${b.text}]"
							},
							if b.source_text.is_empty() {
								""
							} else {
								"[${b.source_text}]"
							},
							True,
							($caption_widths.get(i) ?? minimum_width) - padding * 2,
							theme,
						),
					)
					$row_label = caption
					if !$open.is_empty() {
						last = $open.last() ?? { index: 0, kind: "", top: start, left: 0, right: 0, bottom: start, branches: [] }
						$open = $open.set($open.len() - 1, { ..last, branches: last.branches.append(i) }) ?? []
					}
					$current = start + 25 + if b.text.is_empty() {
						0
					} else {
						caption.height.max(20)
					}
					$control_index = $control_index + 1
				}
				EndBlock => match $open.last() {
					Err(_) => {}
					Ok(frame) => {
						complete = if F64.is_finite(frame.left) and F64.is_finite(frame.right) {
							frame
						} else { ..frame, left: 0, right: content_width.max(minimum_width), bottom: $current + 10 }
						$frames = $frames.append(complete)
						$current = $current.max(complete.bottom)
						$min_x = $min_x.min(complete.left)
						$max_x = $max_x.max(complete.right)
						$max_y = $max_y.max(complete.bottom)
						$open = $open.drop_last(1)
					}
				}
			}
			match $insert {
				None => {}
				Some(rect) => {
					$min_x = $min_x.min(rect.x)
					$max_x = $max_x.max(rect.x + rect.width)
					$max_y = $max_y.max(rect.y + rect.height)
					count = $open.len()
					$open = $open.map_with_index(
						|frame, j| {
							pad = (count - j).to_f64() * 10
							{ ..frame, left: frame.left.min(rect.x - pad), right: frame.right.max(rect.x + rect.width + pad), bottom: frame.bottom.max(rect.y + rect.height + pad) }
						},
					)
				}
			}
			match $activation {
				None => {}
				Some(action) => if action.start {
					depth = $active.count_if(|a| a.index == action.index)
					left = ($centers.get(action.index) ?? 0) + (depth.to_f64() - 1) * 5
					$active = $active.append({ index: action.index, rect: { x: left, y: $current + 2, width: 10, height: 0 } })
				} else {
					match $active.rev().find_first_index(|a| a.index == action.index) {
						Err(_) => {}
						Ok(reverse) => {
							index = $active.len() - reverse - 1
							a = $active.get(index) ?? { index: action.index, rect: SequenceLayout.zero_rect }
							rect = if (a.rect.y + 18 > $current) { ..a.rect, y: $current - 6, height: 18 } else { ..a.rect, height: $current - a.rect.y }
							$activations = $activations.append({ index: a.index, rect })
							$active = $active.take_first(index).concat($active.drop_first(index + 1))
						}
					}
				}
			}
			$rows = $rows.append({ top: start, height: $current - start, label: $row_label })
		}
		footer_y = $current + 20
		# Mermaid paints activation bars only when their closing event occurs.
		# Dangling starts still affect endpoint placement, but have no bar.
		footers = $headers.map(|r| { ..r, y: footer_y })
		for i in 0..<n {
			p = diagram.participants.get(i) ?? { id: "", label: "", actor: False, wrap: False, source_text: "" }
			b = actor_labels.get(i) ?? { lines: [], width: 0, height: 0 }
			center = $centers.get(i) ?? 0
			painted_height = glyph_height + (b.lines.len().max(1) - 1).to_f64() * theme.font_size * theme.line_height
			for footer in [False, True] {
				y = if footer {
					footer_y
				} else {
					0
				}
				top = if p.actor {
					if footer {
						y + 56
					} else {
						header_height - 6 - painted_height
					}
				} else {
					y + header_height / 2 - painted_height / 2
				}
				prefix = if footer {
					"participant-footer"
				} else {
					"participant-header"
				}
				$labels = $labels.concat(SequenceLayout.text_labels("${prefix}-${p.id}", b, center, top, theme.font_size * theme.line_height, "participant", theme))
			}
		}
		# Paint control captions in source order, but use their measured final
		# frame boxes (which are only known when the block closes).
		var $control = 0.U64
		for i in 0..<diagram.events.len() {
			event = diagram.events.get(i) ?? EndBlock
			match event {
				StartBlock(b) => {
					frame = $frames.find_first(|f| f.index == i) ?? { index: i, kind: b.kind, top: 0, left: 0, right: content_width.max(minimum_width), bottom: 0, branches: [] }
					caption = ($rows.get(i) ?? { top: 0, height: 0, label: { lines: [], width: 0, height: 0 } }).label
					x = frame.left + 25 + (frame.right - frame.left) / 2
					$labels = $labels.concat(SequenceLayout.text_labels("block-${$control.to_str()}", caption, x, TextMeasure.round(frame.top + 15 + 2.5) - TextMeasure.metrics_of({ font: TextMeasure.inter, size: theme.font_size, line_height: 1, wrap: NoWrap, align: Middle }).ascent, glyph_height * theme.line_height, "control", theme))
					kind = SequenceLayout.measure(b.kind, False, 0, theme)
					$labels = $labels.concat(SequenceLayout.text_labels("block-kind-${$control.to_str()}", kind, TextMeasure.round(frame.left + 25), frame.top + 20 + x_half - TextMeasure.metrics_of({ font: TextMeasure.inter, size: theme.font_size, line_height: 1, wrap: NoWrap, align: Middle }).ascent, glyph_height, "control-kind", theme))
					$control = $control + 1
				}
				Branch(_) => {
					frame = $frames.find_first(|f| f.branches.contains(i)) ?? { index: i, kind: "", top: 0, left: 0, right: content_width.max(minimum_width), bottom: 0, branches: [] }
					row = $rows.get(i) ?? { top: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
					$labels = $labels.concat(SequenceLayout.text_labels("block-${$control.to_str()}", row.label, (frame.left + frame.right) / 2, TextMeasure.round(row.top + 30 + 2.5) - TextMeasure.metrics_of({ font: TextMeasure.inter, size: theme.font_size, line_height: 1, wrap: NoWrap, align: Middle }).ascent, glyph_height * theme.line_height, "control", theme))
					$control = $control + 1
				}
				_ => {}
			}
		}
		if !diagram.title.is_empty() {
			title_theme = Theme.Options.{ font_size: theme.font_size * 0.875, line_height: theme.line_height }
			title = SequenceLayout.measure(diagram.title, False, 0, title_theme)
			$labels = $labels.concat(SequenceLayout.text_labels("title", title, ($max_x - $min_x) / 2 - 100, -25 - title_theme.font_size, glyph_height, "title", title_theme))
		}
		extra_title = if diagram.title.is_empty() {
			0
		} else {
			40
		}
		height = footer_y + header_height + 10 + 20 - 10 + 1 + 30 + extra_title
		view = if n == 0 and diagram.events.is_empty() and diagram.title.is_empty() {
			SequenceLayout.zero_rect
		} else { x: $min_x - 50, y: -10 - extra_title, width: $max_x - $min_x + 100, height }
		{ centers: $centers, widths, rows: $rows, header_height, width: view.width, height: view.height, margin: 0, footer_y, view, headers: $headers, footers, notes: $notes, message_points: $points, frames: $frames, activations: $activations, labels: $labels, numbers: $numbers }
	}
}
