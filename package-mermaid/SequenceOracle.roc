import DiagramView
import Drawing
import OracleJson
import Sequence
import SequenceData
import SequenceDraw
import SequenceLayout
import SequenceStyle
import Theme

## Native observations for differential tests, never a public package API.
SequenceOracle :: {}.{

	## The public defaults now match the pinned sequence role defaults.
	## The harness still records both profiles so this remains explicit.
	reference_theme : Theme.Options
	reference_theme = Theme.Options.{}

	inspect : Str, Theme.Options -> Str
	inspect = |source, theme| SequenceOracle.inspect_sized(source, theme, [])

	inspect_sized : Str, Theme.Options, List(OracleJson.Size) -> Str
	inspect_sized = |source, theme, sizes| match Sequence.parse(source) {
		Err(_) => OracleJson.rejected("sequence")
		Ok(diagram) => if !Theme.validate(theme).is_empty() {
			OracleJson.rejected("sequence")
		} else {
			invalid = sizes.keep_if(|size| (size.kind != "node" and size.kind != "label") or !F64.is_finite(size.width) or !F64.is_finite(size.height) or size.width < 0 or size.height < 0 or size.width > 1_000_000_000 or size.height > 1_000_000_000)
			if !invalid.is_empty() {
				return OracleJson.object([("accepted", "false"), ("family", OracleJson.string("sequence")), ("size_problems", OracleJson.strings(invalid.map(|size| "${size.kind}:${size.id}")))])
			}
			geometry = SequenceLayout.layout_with_sizes(diagram, theme, sizes)
			picture = DiagramView.finish(SequenceDraw.draw_geometry(diagram, theme, geometry), theme)
			nodes = diagram.participants.map_with_index(
				|p, i| OracleJson.object([
					("id", OracleJson.string(p.id)),
					("box", OracleJson.rect({ x: (geometry.centers.get(i) ?? 0) - (geometry.widths.get(i) ?? 0) / 2, y: 0, width: geometry.widths.get(i) ?? 0, height: geometry.header_height })),
				]),
			)
			var $edges = []
			var $message = 0.U64
			for i in 0..<diagram.events.len() {
				match diagram.events.get(i) ?? EndBlock {
					Message(m) => {
						id = |index| (diagram.participants.get(index) ?? { id: "", label: "", actor: False, wrap: False, source_text: "" }).id
						$edges = $edges.append(OracleJson.object([("id", OracleJson.string("message-${$message.to_str()}")), ("from", OracleJson.string(id(m.from))), ("to", OracleJson.string(id(m.to))), ("points", OracleJson.array((geometry.message_points.get(i) ?? []).map(OracleJson.point)))]))
						$message = $message + 1
					}
					_ => {}
				}
			}
			labels = geometry.labels.map(|label| OracleJson.object([("id", OracleJson.string(label.id)), ("text", OracleJson.string(label.text)), ("box", OracleJson.rect(label.box)), ("measurement", OracleJson.boolean(!label.id.starts_with("participant-footer-") and !label.id.starts_with("block-kind-") and label.role != "title"))]))
			number_labels = geometry.numbers.map_with_index(
				|number, i| {
					block = SequenceLayout.measure(number.text, False, 0, Theme.Options.{ font_size: 12 })
					OracleJson.object([("id", OracleJson.string("number-${i.to_str()}")), ("text", OracleJson.string(number.text)), ("box", OracleJson.rect({ x: number.center.x - block.width / 2, y: number.center.y + 4 - 12, width: block.width, height: block.height })), ("measurement", "false")])
				},
			)
			unused = sizes.keep_if(
				|size| if size.kind == "node" {
					!diagram.participants.any(|p| p.id == size.id)
				} else {
					if size.id.ends_with("-initial") {
						base = size.id.drop_suffix("-initial")
						wrapping = SequenceStyle.resolve(theme)
						if base.starts_with("message-") {
							index = U64.from_str(base.drop_prefix("message-")) ?? diagram.events.len()
							!(
								diagram.events.keep_if(
									|event| match event {
										Message(_) => True
										_ => False
									},
								).map(
									|event| match event {
										Message(m) => SequenceStyle.wrap(m.wrap, wrapping)
										_ => False
									},
								).get(index) ?? False
							)
						} else if base.starts_with("note-") {
							index = U64.from_str(base.drop_prefix("note-")) ?? diagram.events.len()
							!(
								diagram.events.keep_if(
									|event| match event {
										Note(_) => True
										_ => False
									},
								).map(
									|event| match event {
										Note(n) => SequenceStyle.wrap(n.wrap, wrapping)
										_ => False
									},
								).get(index) ?? False
							)
						} else {
							True
						}
					} else {
						!geometry.labels.any(|label| label.id == size.id and !label.id.starts_with("participant-footer-") and !label.id.starts_with("block-kind-") and label.role != "title")
					}
				},
			)
			OracleJson.object([
				("accepted", "true"),
				("family", OracleJson.string("sequence")),
				("semantic", SequenceOracle.semantic(diagram)),
				("size_problems", OracleJson.strings(unused.map(|size| "unconsumed ${size.kind}:${size.id}"))),
				(
					"geometry",
					OracleJson.object([
						("view_box", OracleJson.rect(picture.view)),
						("nodes", OracleJson.array(nodes)),
						("edges", OracleJson.array($edges)),
						("labels", OracleJson.array(labels.concat(number_labels))),
						(
							"groups",
							OracleJson.array(
								geometry.frames.map(
									|frame| OracleJson.object([
										(
											"id",
											OracleJson.string(
												"block-${
													diagram.events.take_first(frame.index).keep_if(
														|event| match event {
															StartBlock(_) | Branch(_) => True
															_ => False
														},
													).len().to_str()
												}",
											),
										),
										("box", OracleJson.rect({ x: frame.left, y: frame.top, width: frame.right - frame.left, height: frame.bottom - frame.top })),
									]),
								),
							),
						),
					]),
				),
			])
		}
	}

	semantic : SequenceData.Diagram -> Str
	semantic = |diagram| {
		id = |index| (diagram.participants.get(index) ?? { id: "", label: "", actor: False, wrap: False, source_text: "" }).id
		participants = diagram.participants.map(|p| OracleJson.object([("id", OracleJson.string(p.id)), ("label", OracleJson.string(p.label)), ("actor", OracleJson.boolean(p.actor)), ("wrap", OracleJson.boolean(p.wrap))]))
		var $events = []
		var $blocks = []
		for event in diagram.events {
			match event {
				Message(m) => {
					head = match m.head {
						None => "none"
						Arrow => "arrow"
						Open => "open"
						Cross => "cross"
					}
					$events = $events.append(
						OracleJson.object([
							("kind", OracleJson.string("message")),
							("from", OracleJson.string(id(m.from))),
							("to", OracleJson.string(id(m.to))),
							("text", OracleJson.string(m.text)),
							("dotted", OracleJson.boolean(m.dotted)),
							("head", OracleJson.string(head)),
							("both", OracleJson.boolean(m.both)),
							("activate", OracleJson.boolean(m.activation == Start)),
							("wrap", OracleJson.boolean(m.wrap)),
						]),
					)
					match m.activation {
						Keep => {}
						Start => {
							$events = $events.append(OracleJson.object([("kind", OracleJson.string("activate")), ("participant", OracleJson.string(id(m.to)))]))
						}
						Stop => {
							$events = $events.append(OracleJson.object([("kind", OracleJson.string("deactivate")), ("participant", OracleJson.string(id(m.from)))]))
						}
					}
				}
				Note(n) => {
					side = match n.side {
						Left => "left"
						Right => "right"
						Over => "over"
					}
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("note")), ("from", OracleJson.string(id(n.from))), ("to", OracleJson.string(id(n.to))), ("side", OracleJson.string(side)), ("text", OracleJson.string(n.text)), ("wrap", OracleJson.boolean(n.wrap))]))
				}
				Activate(index) => {
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("activate")), ("participant", OracleJson.string(id(index)))]))
				}
				Deactivate(index) => {
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("deactivate")), ("participant", OracleJson.string(id(index)))]))
				}
				StartBlock(b) => {
					$blocks = $blocks.append(b.kind)
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("start")), ("block", OracleJson.string(b.kind)), ("text", OracleJson.string(b.text)), ("wrap", OracleJson.boolean(b.wrap))]))
				}
				Branch(b) => {
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("branch")), ("branch", OracleJson.string(b.kind)), ("text", OracleJson.string(b.text)), ("wrap", OracleJson.boolean(b.wrap))]))
				}
				EndBlock => {
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("end")), ("block", OracleJson.string($blocks.last() ?? ""))]))
					$blocks = $blocks.drop_last(1)
				}
				Numbering(n) => {
					start = match n.start {
						None => "null"
						Some(value) => OracleJson.number(value)
					}
					step = match n.step {
						None => "null"
						Some(value) => OracleJson.number(value)
					}
					$events = $events.append(OracleJson.object([("kind", OracleJson.string("numbering")), ("visible", OracleJson.boolean(n.visible)), ("start", start), ("step", step)]))
				}
			}
		}
		OracleJson.object([("participants", OracleJson.array(participants)), ("events", OracleJson.array($events)), ("autonumber", OracleJson.boolean(diagram.autonumber)), ("title", OracleJson.string(diagram.title))])
	}
}
