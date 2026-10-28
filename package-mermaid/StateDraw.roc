import Drawing
import Flowchart
import FlowDraw
import FlowDrawEdge
import FlowDrawStyle
import FlowGeometry
import FlowLayout
import FlowTheme
import StateModel
import StateParser
import TextMeasure
import Theme
import font.Font

## State-specific sizing and painting over the reusable compound flow layout.
StateDraw :: {}.{
	Block : FlowGeometry.TextBlock

	block : Str, Theme.Options -> Block
	block = |text, options| {
		measured = TextMeasure.block(text, { font: TextMeasure.inter, size: options.font_size, line_height: options.line_height, wrap: Width(options.max_label_width), align: Middle })
		# line_height controls baseline spacing, not the first glyph's box.
		# Reserve unrounded font extents too: tiny accepted font sizes must
		# not disappear when browser-style whole-pixel metrics round to zero.
		height = if text == "" {
			0
		} else {
			StateDraw.baseline(options) + StateDraw.descent(options) + (measured.lines.len().max(1) - 1).to_f64() * options.font_size * options.line_height
		}
		{ ..measured, height: height.max(measured.height) }
	}

	baseline : Theme.Options -> F64
	baseline = |options| {
		metrics = Font.metrics(TextMeasure.inter)
		ascent = metrics.ascent.to_f64() * options.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
		ascent.max(TextMeasure.round(ascent)).max(options.font_size * 0.95).max(TextMeasure.round(options.font_size * 0.95))
	}

	descent : Theme.Options -> F64
	descent = |options| {
		metrics = Font.metrics(TextMeasure.inter)
		extent = metrics.descent.to_f64() * options.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
		# Fallback emoji can reach a quarter-em below the baseline.
		extent.max(TextMeasure.round(extent)).max(options.font_size * 0.25).max(TextMeasure.round(options.font_size * 0.25))
	}

	make_flow : StateModel.Diagram -> Flowchart.Diagram
	make_flow = |diagram| {
		direction: diagram.direction,
		nodes: diagram.states.map(
			|state| {
				id: state.id,
				label: StateDraw.label(state),
				shape: match state.kind {
					Initial | Final => Circle
					Choice => Diamond
					Fork | Join => Rectangle
					Normal => Rounded
				},
				container: state.container,
				classes: state.classes,
				styles: state.styles,
			},
		),
		edges: diagram.transitions.map_with_index(
			|edge, i| {
				id: "state-edge-${i.to_str()}",
				from: edge.from,
				to: edge.to,
				label: edge.label,
				line: Solid,
				start: None,
				end: Arrow,
				length: 1,
				classes: [],
				styles: [],
			},
		),
		groups: diagram.groups,
		classes: diagram.classes,
	}

	label : StateModel.State -> Str
	label = |state| if (state.kind == Normal) Str.join_with([state.label].concat(state.descriptions), "\n") else ""

	measure_sizes : StateModel.Diagram, Theme.Options -> FlowGeometry.Sizes
	measure_sizes = |diagram, options| {
		nodes: diagram.states.map(
			|state| {
				title = StateDraw.block(state.label, options)
				body = StateDraw.block(Str.join_with(state.descriptions, "\n"), options)
				text = StateDraw.block(StateDraw.label(state), options)
				size = match state.kind {
					Initial => { width: 18, height: 18 }
					Final => { width: 26, height: 26 }
					Choice => { width: 34, height: 34 }
					Fork | Join => match diagram.direction {
						Left | Right => { width: 8, height: 70 }
						Up | Down => { width: 70, height: 8 }
					}
					Normal => {
						width: (title.width.max(body.width) + options.padding * 2).max(80),
						height: title.height + body.height + options.padding * (if (state.descriptions.is_empty()) 2 else 3),
					}
				}
				{ width: size.width, height: size.height, label: text }
			},
		),
		edge_labels: diagram.transitions.map(|edge| if (edge.label == "") None else Some(StateDraw.block(edge.label, options))),
		group_titles: diagram.groups.map(|group| StateDraw.block(group.title, options)),
	}

	drawing_theme : Theme.Options -> FlowDraw.Theme
	drawing_theme = |options| {
		..FlowDraw.mermaid,
		font_size: options.font_size,
		line_height: options.line_height,
		corner_radius: options.corner_radius,
		background: options.background,
		node_fill: options.node_fill,
		node_stroke: options.node_stroke,
		node_stroke_width: options.line_width,
		node_text: options.node_text,
		line: options.line,
		line_width: options.line_width,
		thick_line_width: options.line_width * 2,
		label_background: options.label_background,
		label_background_opacity: 1,
		label_text: options.label_text,
		group_colors: [{ fill: options.group_fill, stroke: options.group_stroke }],
		group_text: options.node_text,
		group_stroke_width: options.line_width,
		shadow: options.shadow,
	}

	draw : StateModel.Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, options| {
		flow = StateDraw.make_flow(diagram)
		sizes = StateDraw.measure_sizes(diagram, options)
		geometry = FlowTheme.clip_routes(flow, FlowLayout.layout(flow, sizes), options.corner_radius)
		theme = StateDraw.drawing_theme(options)
		var $items = []
		# Composite bodies precede edges and state bodies in painting order.
		for g in FlowDraw.group_order(flow.groups).order {
			match (flow.groups.get(g), geometry.groups.get(g), sizes.group_titles.get(g)) {
				(Ok(group), Ok(rect), Ok(title)) => {
					o = FlowDrawStyle.resolve(flow.classes, group.classes, [], False)
					paint = FlowDraw.paint_of(o, options.group_fill, options.group_stroke, options.line_width)
					color = match o.color {
						Paint(c) => c
						Keep => options.node_text
					}
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle(rect, options.corner_radius), paint }))
					$items = $items.concat(StateDraw.lines(title.lines, rect.x + rect.width / 2, rect.y, color, options))
				}
				_ => {}
			}
		}
		hops = FlowDrawEdge.hops(geometry.edges.map(|edge| edge.points))
		for i in 0..<flow.edges.len() {
			match (flow.edges.get(i), geometry.edges.get(i)) {
				(Ok(edge), Ok(route)) => {
					$items = $items.concat(FlowDraw.edge_items(flow, edge, route.points, hops.get(i) ?? [], theme))
				}
				_ => {}
			}
		}
		for i in 0..<flow.edges.len() {
			match (sizes.edge_labels.get(i), geometry.edges.get(i)) {
				(Ok(Some(label_block)), Ok(route)) => match route.label {
					Some(at) => {
						rect = { x: at.x - label_block.width / 2 - 3, y: at.y - label_block.height / 2 - 3, width: label_block.width + 6, height: label_block.height + 6 }
						$items = $items.append(Shape({ path: Drawing.rounded_rectangle(rect, 3), paint: { fill: Fill(options.label_background), stroke: NoStroke } }))
						$items = $items.concat(StateDraw.lines(label_block.lines, at.x, at.y - label_block.height / 2, options.label_text, options))
					}
					None => {}
				}
				_ => {}
			}
		}
		for i in 0..<diagram.states.len() {
			match (diagram.states.get(i), geometry.nodes.get(i)) {
				(Ok(state), Ok(rect)) => {
					$items = $items.concat(StateDraw.node(diagram, state, rect, options))
				}
				_ => {}
			}
		}
		# Notes live in side columns. Their state names identify the attachment;
		# stacking avoids both node collisions and collisions between notes.
		var $left_bottom = geometry.bounds.y
		var $right_bottom = geometry.bounds.y
		var $view = geometry.bounds
		match options.shadow {
			NoShadow => {}
			Shadow(shadow) => {
				for rect in geometry.nodes {
					$view = StateDraw.union($view, { ..rect, x: rect.x + shadow.dx, y: rect.y + shadow.dy })
				}
			}
		}
		var $outline_width = options.line_width
		for state in diagram.states {
			match FlowDrawStyle.resolve(diagram.classes, state.classes, state.styles, True).stroke_width {
				Keep => {}
				Width(width) => {
					$outline_width = $outline_width.max(width)
				}
			}
		}
		for group in diagram.groups {
			match FlowDrawStyle.resolve(diagram.classes, group.classes, [], False).stroke_width {
				Keep => {}
				Width(width) => {
					$outline_width = $outline_width.max(width)
				}
			}
		}
		for note in diagram.notes {
			anchor = match note.state {
				Node(i) => geometry.nodes.get(i) ?? geometry.bounds
				Group(i) => geometry.groups.get(i) ?? geometry.bounds
			}
			name = match note.state {
				Node(i) => (diagram.states.get(i) ?? { id: "", label: "", descriptions: [], kind: Normal, container: Root, classes: [], styles: [] }).label
				Group(i) => (diagram.groups.get(i) ?? { id: "", title: "", container: Root, direction: Inherit, classes: [] }).title
			}
			title = StateDraw.block(name, options)
			body = StateDraw.block(note.text, options)
			width = title.width.max(body.width) + options.padding * 2
			height = title.height + body.height + options.padding * 3
			y = match note.side {
				Left => anchor.y.max($left_bottom)
				Right => anchor.y.max($right_bottom)
			}
			x = match note.side {
				Left => geometry.bounds.x - width - 24
				Right => geometry.bounds.x + geometry.bounds.width + 24
			}
			rect = { x, y, width, height }
			paint = { fill: Fill(options.group_fill), stroke: Stroke({ color: options.group_stroke, width: options.line_width }) }
			$items = $items.append(Shape({ path: StateDraw.note_path(rect), paint }))
			$items = $items.concat(StateDraw.lines(title.lines, x + width / 2, y + options.padding, options.node_text, options))
			$items = $items.concat(StateDraw.lines(body.lines, x + width / 2, y + options.padding * 2 + title.height, options.label_text, options))
			match note.side {
				Left => {
					$left_bottom = y + height + 16
				}
				Right => {
					$right_bottom = y + height + 16
				}
			}
			$view = StateDraw.union($view, rect)
		}
		margin = ($outline_width / 2).max(8)
		view = { x: $view.x - margin, y: $view.y - margin, width: $view.width + margin * 2, height: $view.height + margin * 2 }
		{ view, items: [Shape({ path: Drawing.rectangle(view), paint: { fill: Fill(options.background), stroke: NoStroke } })].concat($items) }
	}

	node : StateModel.Diagram, StateModel.State, Drawing.Rect, Theme.Options -> List(Drawing.Item)
	node = |diagram, state, rect, options| {
		overrides = FlowDrawStyle.resolve(diagram.classes, state.classes, state.styles, True)
		paint = FlowDraw.paint_of(overrides, options.node_fill, options.node_stroke, options.line_width)
		color = match overrides.color {
			Paint(c) => c
			Keep => options.node_text
		}
		cx = rect.x + rect.width / 2
		cy = rect.y + rect.height / 2
		path = match state.kind {
			Initial | Final => Drawing.ellipse({ x: cx, y: cy }, rect.width / 2, rect.height / 2)
			Choice => Drawing.polygon([{ x: cx, y: rect.y }, { x: rect.x + rect.width, y: cy }, { x: cx, y: rect.y + rect.height }, { x: rect.x, y: cy }])
			Fork | Join => Drawing.rectangle(rect)
			Normal => Drawing.rounded_rectangle(rect, options.corner_radius)
		}
		fill = match state.kind {
			Initial => { fill: Fill(options.accent), stroke: NoStroke }
			Fork | Join => FlowDraw.paint_of(overrides, options.accent, options.accent, options.line_width)
			Final => { fill: Fill(options.background), stroke: Stroke({ color: options.accent, width: options.line_width }) }
			Normal | Choice => paint
		}
		var $items = FlowDraw.shadows(StateDraw.drawing_theme(options), [path], fill, options.background).append(Shape({ path, paint: fill }))
		if state.kind == Final {
			$items = $items.append(Shape({ path: Drawing.ellipse({ x: cx, y: cy }, rect.width / 2 - 5, rect.height / 2 - 5), paint: { fill: Fill(options.accent), stroke: NoStroke } }))
		}
		if state.kind == Normal {
			title = StateDraw.block(state.label, options)
			body = StateDraw.block(Str.join_with(state.descriptions, "\n"), options)
			$items = $items.concat(StateDraw.lines(title.lines, cx, rect.y + options.padding, color, options))
			if !state.descriptions.is_empty() {
				y = rect.y + options.padding * 1.5 + title.height
				$items = $items.append(Shape({ path: [MoveTo({ x: rect.x, y }), LineTo({ x: rect.x + rect.width, y })], paint: { fill: NoFill, stroke: paint.stroke } }))
				$items = $items.concat(StateDraw.lines(body.lines, cx, rect.y + options.padding * 2 + title.height, color, options))
			}
		}
		$items
	}

	lines : List(Str), F64, F64, Drawing.Color, Theme.Options -> List(Drawing.Item)
	lines = |rows, x, top, color, options| rows.map_with_index(|text, i| Text({ text, origin: { x, y: top + StateDraw.baseline(options) + i.to_f64() * options.font_size * options.line_height }, size: options.font_size, align: Center, color }))

	## Contract probe: every text ink box belongs to a painted node, group,
	## note, or edge-label box, rather than merely fitting the outer canvas.
	labels_contained : Drawing.Picture, Theme.Options -> Bool
	labels_contained = |picture, options| {
		scale = options.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
		metrics = Font.metrics(TextMeasure.inter)
		ascent = (metrics.ascent.to_f64() * scale).max(options.font_size * 0.95)
		below = (metrics.descent.to_f64() * scale).max(options.font_size * 0.25)
		candidates = picture.items.drop_first(1).fold(
			[],
			|out, item| match item {
				Text(_) => out
				Shape(painted) => match painted.paint.fill {
					NoFill => out
					Fill(_) => {
						points = painted.path.fold(
							[],
							|ps, segment| match segment {
								MoveTo(p) | LineTo(p) => ps.append(p)
								CubicTo(c) => ps.concat([c.control_1, c.control_2, c.end])
								Close => ps
							},
						)
						match points.first() {
							Err(_) => out
							Ok(first) => {
								extents = points.fold({ left: first.x, top: first.y, right: first.x, bottom: first.y }, |bounds, p| { left: bounds.left.min(p.x), top: bounds.top.min(p.y), right: bounds.right.max(p.x), bottom: bounds.bottom.max(p.y) })
								out.append(extents)
							}
						}
					}
				}
			},
		)
		picture.items.all(
			|item| match item {
				Shape(_) => True
				Text(text_item) => {
					if text_item.text.is_empty() {
						True
					} else {
						measured = TextMeasure.block(text_item.text, { font: TextMeasure.inter, size: options.font_size, line_height: options.line_height, wrap: NoWrap, align: Middle })
						left = text_item.origin.x - measured.width / 2
						right = text_item.origin.x + measured.width / 2
						top = text_item.origin.y - ascent
						bottom = text_item.origin.y + below
						candidates.any(|bounds| left >= bounds.left - 0.001 and right <= bounds.right + 0.001 and top >= bounds.top - 0.001 and bottom <= bounds.bottom + 0.001)
					}
				}
			},
		)
	}

	note_path : Drawing.Rect -> List(Drawing.Segment)
	note_path = |rect| {
		fold = (rect.width / 4).min(10).min(rect.height / 4)
		[MoveTo({ x: rect.x, y: rect.y }), LineTo({ x: rect.x + rect.width - fold, y: rect.y }), LineTo({ x: rect.x + rect.width, y: rect.y + fold }), LineTo({ x: rect.x + rect.width, y: rect.y + rect.height }), LineTo({ x: rect.x, y: rect.y + rect.height }), Close, MoveTo({ x: rect.x + rect.width - fold, y: rect.y }), LineTo({ x: rect.x + rect.width - fold, y: rect.y + fold }), LineTo({ x: rect.x + rect.width, y: rect.y + fold })]
	}

	union : Drawing.Rect, Drawing.Rect -> Drawing.Rect
	union = |a, b| {
		x = a.x.min(b.x)
		y = a.y.min(b.y)
		{ x, y, width: (a.x + a.width).max(b.x + b.width) - x, height: (a.y + a.height).max(b.y + b.height) - y }
	}
}

## Regression: tight baseline spacing cannot shrink the first glyph or
## move description ink across the title/body divider at zero padding.
expect {
	options = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 300 }
	state = { id: "A", label: "Titleg", descriptions: ["Bodyg"], kind: Normal, container: Root, classes: [], styles: [] }
	diagram = { direction: Down, states: [state], transitions: [], groups: [], classes: [], notes: [] }
	size = StateDraw.measure_sizes(diagram, options).nodes.first()?
	rect = { x: 0, y: 0, width: size.width, height: size.height }
	labels = StateDraw.node(diagram, state, rect, options).fold(
		[],
		|out, item| match item {
			Text(label) => out.append(label)
			_ => out
		},
	)
	scale = options.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
	metrics = Font.metrics(TextMeasure.inter)
	ascent = metrics.ascent.to_f64() * scale
	descent = metrics.descent.to_f64() * scale
	divider = StateDraw.block(state.label, options).height
	match labels {
		[title, body] => title.origin.y - ascent >= 0 and title.origin.y + descent <= divider
			and body.origin.y - ascent >= divider and body.origin.y + descent <= size.height
		_ => False
	}
}

expect {
	options = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 90 }
	block = StateDraw.block("g first line\ng second line with several words", options)
	scale = options.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
	metrics = Font.metrics(TextMeasure.inter)
	ascent = metrics.ascent.to_f64() * scale
	descent = metrics.descent.to_f64() * scale
	block.lines.len() > 3 and StateDraw.lines(block.lines, 0, 0, options.node_text, options).all(
		|item| match item {
			Text(label) => label.origin.y - ascent >= 0 and label.origin.y + descent <= block.height
			_ => False
		},
	)
}

expect {
	options = Theme.Options.{ font_size: 0.001, line_height: 0.01, padding: 0 }
	block = StateDraw.block("a\nb", options)
	block.height > StateDraw.baseline(options) and StateDraw.baseline(options) > 0
}

expect {
	options = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 300, corner_radius: 19 }
	diagram = StateParser.parse("stateDiagram-v2\nstate \"Titleg\" as A\nA: Bodyg\nA --> B : Edgeg\nnote right of A : Noteg\nstate Groupg {\nChildg\n}\nB --> Groupg\n")?
	picture = StateDraw.draw(diagram, options)
	theme = StateDraw.drawing_theme(options)
	Drawing.is_finite(picture) and StateDraw.labels_contained(picture, options)
		and theme.line_height == 0.1 and theme.corner_radius == 19
}
