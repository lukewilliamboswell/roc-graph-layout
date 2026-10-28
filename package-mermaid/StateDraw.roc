import Drawing
import Flowchart
import FlowDraw
import FlowDrawEdge
import FlowDrawStyle
import FlowGeometry
import FlowLayout
import FlowTheme
import StateLayout
import StateModel
import StateParser
import TextMeasure
import Theme
import font.Font

## State-specific sizing and painting over the reusable compound flow layout.
StateDraw :: {}.{
	Block : FlowGeometry.TextBlock

	block : Str, Theme.Options -> Block
	block = |text, options| StateDraw.measure_block(text, options, if (options.wrapping == NoWrap) NoWrap else Width(options.max_label_width))

	compartment_block : Str, Theme.Options -> Block
	compartment_block = |text, options| StateDraw.measure_block(text, options, if (options.wrapping == Wrap) Width(options.max_label_width) else NoWrap)

	state_padding : Theme.Options -> F64
	state_padding = |options| options.padding * 8 / 15

	radius : Theme.Options -> F64
	radius = |options| if (options.corners == Square) 0 else options.corner_radius

	measure_block : Str, Theme.Options, [NoWrap, Width(F64)] -> Block
	measure_block = |text, options, wrap| {
		measured = TextMeasure.block(text, { font: TextMeasure.inter, size: options.font_size, line_height: options.line_height, wrap, align: Middle })
		# Browser-rounded metrics are authoritative at ordinary sizes.
		# Unrounded font extents retain finite tiny text without charging
		# every ordinary label for an emoji descender it does not contain.
		metrics = Font.metrics(TextMeasure.inter)
		scale = options.font_size / Font.units_per_em(TextMeasure.inter).to_f64()
		raw_height = (metrics.ascent + metrics.descent).to_f64() * scale
		height = if (text == "") 0 else raw_height + (measured.lines.len().max(1) - 1).to_f64() * options.font_size * options.line_height
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
	make_flow = |diagram| StateDraw.make_flow_with(diagram, Theme.Options.{})

	make_flow_with : StateModel.Diagram, Theme.Options -> Flowchart.Diagram
	make_flow_with = |diagram, options| {
		direction: diagram.direction,
		nodes: diagram.states.map(
			|state| {
				id: state.id,
				label: StateDraw.display_label(state),
				shape: match state.effective_kind {
					Initial | Final => Circle
					Choice => Diamond
					Fork | Join => Rectangle
					Normal => if (options.corners == Square or (state.descriptions.len() > 1 and options.corners == FamilyDefault)) Rectangle else Rounded
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
		groups: diagram.groups.map(|group| { id: group.id, title: group.title, container: group.container, direction: group.direction, classes: if (group.styles.is_empty()) group.classes else group.classes.append("@style:${group.id}") }),
		classes: diagram.classes.concat(diagram.groups.keep_if(|group| !group.styles.is_empty()).map(|group| { name: "@style:${group.id}", styles: group.styles })),
	}

	display_label : StateModel.State -> Str
	display_label = |state| if (state.effective_kind == Normal) Str.join_with(if (state.descriptions.is_empty()) [state.label] else state.descriptions, "\n") else ""

	measure_sizes : StateModel.Diagram, Theme.Options -> FlowGeometry.Sizes
	measure_sizes = |diagram, options| {
		nodes: diagram.states.map(
			|state| {
				title = if (state.descriptions.len() > 1) StateDraw.compartment_block(state.label, options) else StateDraw.block(state.label, options)
				body = StateDraw.compartment_block(Str.join_with(state.descriptions.drop_first(1), "\n"), options)
				text = StateDraw.block(StateDraw.display_label(state), options)
				size = match state.effective_kind {
					Initial | Final => { width: 14, height: 14 }
					Choice => { width: 28, height: 28 }
					Fork | Join => match diagram.direction {
						Left | Right => { width: 10, height: 70 }
						Up | Down => { width: 70, height: 10 }
					}
					Normal => {
						width: if (state.descriptions.len() > 1) title.width.max(body.width) + StateDraw.state_padding(options) else title.width.max(120) + StateDraw.state_padding(options) * 2,
						height: if (state.descriptions.len() > 1) title.height + body.height + StateDraw.state_padding(options) * 1.5 + 5 else title.height + StateDraw.state_padding(options) * 2,
					}
				}
				{ width: size.width, height: size.height, label: text }
			},
		),
		edge_labels: diagram.transitions.map(|edge| if (edge.label == "") None else Some(StateDraw.compartment_block(edge.label, options))),
		group_titles: diagram.groups.map(|group| StateDraw.compartment_block(group.title, options)),
	}

	unwrapped : Str, Theme.Options -> Block
	unwrapped = |text, options| StateDraw.measure_block(text, options, NoWrap)

	Setup : { flow : Flowchart.Diagram, sizes : FlowGeometry.Sizes, geometry : FlowGeometry.Geometry }

	setup : StateModel.Diagram, Theme.Options -> Setup
	setup = |diagram, options| StateDraw.setup_sized(diagram, options, [])

	SizeInput : { kind : Str, id : Str, width : F64, height : F64 }

	setup_sized : StateModel.Diagram, Theme.Options, List(SizeInput) -> Setup
	setup_sized = |diagram, options, inputs| {
		base = StateDraw.make_flow_with(diagram, options)
		measured = StateDraw.measure_sizes(diagram, options)
		blank = { lines: [], width: 0, height: 0 }
		note_nodes = diagram.notes.map_with_index(
			|note, i| {
				id: "@state-note:${i.to_str()}",
				label: note.text,
				shape: Rectangle,
				container: Group(base.groups.len() + i),
				classes: [],
				styles: [],
			},
		)
		note_groups = diagram.notes.map_with_index(
			|_note, i| {
				id: "@state-note-group:${i.to_str()}",
				title: "",
				container: Root,
				direction: Inherit,
				classes: [],
			},
		)
		associations = diagram.notes.map_with_index(
			|note, i| {
				note_endpoint = Node(base.nodes.len() + i)
				{ id: "state-note-edge-${i.to_str()}", from: if (note.side == Left) note_endpoint else note.state, to: if (note.side == Left) note.state else note_endpoint, label: "", line: Dotted, start: None, end: None, length: 1, classes: [], styles: [] }
			},
		)
		flow = { ..base, nodes: base.nodes.concat(note_nodes), groups: base.groups.concat(note_groups), edges: base.edges.concat(associations) }
		sizes = {
			..measured,
			nodes: measured.nodes.concat(
				diagram.notes.map(
					|note| {
						label = StateDraw.block(note.text, options)
						padding = options.padding
						{ label, width: label.width.max(120) + padding * 2, height: label.height + padding * 2 }
					},
				),
			),
			edge_labels: measured.edge_labels.concat(diagram.notes.map(|_| None)),
			group_titles: measured.group_titles.concat(diagram.notes.map(|note| { ..blank, height: StateDraw.unwrapped(note.text, options).height })),
		}
		supplied = {
			..sizes,
			nodes: sizes.nodes.map_with_index(
				|node, i| {
					id = match diagram.states.get(i) {
						Ok(state) => StateModel.state_id(diagram, state)
						Err(_) => "${StateModel.endpoint_id(diagram, (diagram.notes.get(i - diagram.states.len()) ?? { state: Node(0), side: Right, text: "", after_transition: 0 }).state)}----note"
					}
					bounds = StateDraw.measured_size(inputs, "node", id, { width: node.width, height: node.height })
					{ ..node, width: bounds.width, height: bounds.height }
				},
			),
			group_titles: sizes.group_titles.map_with_index(
				|title, i| {
					match diagram.groups.get(i) {
						Err(_) => {
							note = diagram.notes.get(i - diagram.groups.len()) ?? crash "note group index aligned"
							id = "note-group-${StateModel.endpoint_id(diagram, note.state)}"
							measured_label = StateDraw.unwrapped(note.text, options)
							bounds = StateDraw.measured_size(inputs, "group", id, { width: measured_label.width, height: measured_label.height })
							{ ..title, height: bounds.height }
						}
						Ok(group) => {
							bounds = StateDraw.measured_size(inputs, "group", "group-${group.id}", { width: title.width, height: title.height })
							{ ..title, width: bounds.width, height: bounds.height }
						}
					}
				},
			),
			edge_labels: sizes.edge_labels.map_with_index(
				|label, i| match label {
					None => None
					Some(label_block) => {
						bounds = StateDraw.measured_size(inputs, "label", "transition-${i.to_str()}", { width: label_block.width, height: label_block.height })
						Some({ ..label_block, width: bounds.width, height: bounds.height })
					}
				},
			),
		}
		hidden_labels = diagram.notes.map_with_index(
			|note, i| {
				label = StateDraw.unwrapped(note.text, options)
				id = "note-group-${StateModel.endpoint_id(diagram, note.state)}"
				measured_label = StateDraw.measured_size(inputs, "group", id, { width: label.width, height: label.height })
				{ group: diagram.groups.len() + i, width: measured_label.width, height: measured_label.height }
			},
		)
		var $edge_order = []
		var $note_index = 0
		for transition in 0..<(diagram.transitions.len() + 1) {
			while $note_index < diagram.notes.len() and (diagram.notes.get($note_index) ?? crash "note index in bounds").after_transition <= transition {
				$edge_order = $edge_order.append(diagram.transitions.len() + $note_index)
				$note_index = $note_index + 1
			}
			if transition < diagram.transitions.len() {
				$edge_order = $edge_order.append(transition)
			}
		}
		registration = diagram.declarations.fold(
			[],
			|items, declaration| match declaration {
				State(id) => items.append(NodeItem(diagram.states.find_first_index(|state| state.id == id) ?? crash "registered state exists"))
				Composite(id) => items.append(GroupItem(diagram.groups.find_first_index(|group| group.id == id) ?? crash "registered composite exists"))
				Note(i) => items.concat([GroupItem(diagram.groups.len() + i), NodeItem(diagram.states.len() + i)])
			},
		)
		placed = StateLayout.layout(flow, supplied, hidden_labels, $edge_order, registration)
		# Flowchart diamonds are drawn half a pixel right of the layout
		# box. State choices are centred on that box instead.
		state_nodes = placed.nodes.map_with_index(
			|rect, i| match diagram.states.get(i) {
				Ok(state) if state.effective_kind == Choice => { ..rect, x: rect.x - 0.5 }
				_ => rect
			},
		)
		label_boxes = supplied.edge_labels.map(
			|label| match label {
				None => None
				Some(label_block) => Some({ width: label_block.width + 4, height: label_block.height + 4 })
			},
		)
		title_boxes = supplied.group_titles.map(|title_block| { width: title_block.width, height: title_block.height })
		normalized = FlowLayout.normalise({ ..placed, nodes: state_nodes }, label_boxes, title_boxes)
		clipped = FlowTheme.clip_routes(flow, normalized, StateDraw.radius(options))
		# SVG cluster titles overhang the painted frame by2px. Include their
		# actual label boxes with Mermaid's8px diagram margin in the frame.
		var $bounds = clipped.bounds
		for i in 0..<diagram.groups.len() {
			title = supplied.group_titles.get(i) ?? blank
			rect = clipped.groups.get(i) ?? clipped.bounds
			if title.height > 0 {
				$bounds = StateDraw.union($bounds, { x: rect.x + rect.width / 2 - title.width / 2 - 8, y: rect.y - 10, width: title.width + 16, height: title.height + 16 })
			}
		}
		{ flow, sizes: supplied, geometry: { ..clipped, bounds: $bounds } }
	}

	measured_size : List(SizeInput), Str, Str, { width : F64, height : F64 } -> { width : F64, height : F64 }
	measured_size = |inputs, kind, id, original| match inputs.find_first(|input| input.kind == kind and input.id == id) {
		Err(_) => original
		Ok(input) => {
			if !F64.is_finite(input.width) or !F64.is_finite(input.height) or input.width < 0 or input.height < 0 {
				crash "invalid measured state layout size"
			}
			{ width: input.width, height: input.height }
		}
	}

	drawing_theme : Theme.Options -> FlowDraw.Theme
	drawing_theme = |options| {
		..FlowDraw.mermaid,
		font_size: options.font_size,
		line_height: options.line_height,
		corner_radius: StateDraw.radius(options),
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
	draw = |diagram, options| StateDraw.draw_setup(diagram, options, StateDraw.setup(diagram, options))

	draw_setup : StateModel.Diagram, Theme.Options, Setup -> Drawing.Picture
	draw_setup = |diagram, options, prepared| {
		flow = prepared.flow
		sizes = prepared.sizes
		geometry = prepared.geometry
		theme = StateDraw.drawing_theme(options)
		var $items = []
		base_groups = flow.groups.take_first(diagram.groups.len())
		# Composite bodies precede edges and state bodies in painting order.
		for g in FlowDraw.group_order(base_groups).order {
			match (flow.groups.get(g), geometry.groups.get(g), sizes.group_titles.get(g)) {
				(Ok(_group), Ok(rect), Ok(title)) => {
					original = diagram.groups.get(g) ?? crash "authored group index aligned"
					styled = !original.styles.is_empty() or !original.classes.is_empty()
					# Pinned Mermaid suppresses the composite palette for authored
					# styles but does not apply those declarations to cluster shapes.
					paint = { fill: Fill(if (styled) options.node_fill else options.group_fill), stroke: Stroke({ color: if (styled) options.node_stroke else options.group_stroke, width: options.line_width }) }
					color = options.node_text
					group_radius = if (options.corners == Rounded) options.corner_radius else 0
					$items = $items.append(Shape({ path: Drawing.rounded_rectangle(rect, group_radius), paint }))
					body_fill = Fill(if (styled) options.node_fill else options.background)
					inner = { x: rect.x, y: rect.y + title.height + 2, width: rect.width, height: (rect.height - title.height - 6).max(0) }
					if inner.height > 0 {
						$items = $items.append(Shape({ path: Drawing.rectangle(inner), paint: { fill: body_fill, stroke: paint.stroke } }))
					}
					$items = $items.concat(StateDraw.lines(title.lines, rect.x + rect.width / 2, rect.y - 2, color, options))
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
						rect = { x: at.x - label_block.width / 2 - 2, y: at.y - label_block.height / 2 - 2, width: label_block.width + 4, height: label_block.height + 4 }
						$items = $items.append(Shape({ path: Drawing.rectangle(rect), paint: { fill: Fill(options.transition_label_background), stroke: NoStroke } }))
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
		# A note is an actual layout node with a dashed association, as in
		# Mermaid's state renderer. Its implicit group is transparent.
		for i in 0..<diagram.notes.len() {
			match (diagram.notes.get(i), geometry.nodes.get(diagram.states.len() + i)) {
				(Ok(note), Ok(rect)) => {
					note_block = StateDraw.block(note.text, options)
					paint = { fill: Fill(options.note_fill), stroke: Stroke({ color: options.note_stroke, width: options.line_width }) }
					$items = $items.append(Shape({ path: Drawing.rectangle(rect), paint }))
					$items = $items.concat(StateDraw.lines(note_block.lines, rect.x + rect.width / 2, rect.y + options.padding, options.note_text, options))
				}
				_ => {}
			}
		}

		{ view: geometry.bounds, items: $items }
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
		path = match state.effective_kind {
			Initial | Final => Drawing.ellipse({ x: cx, y: cy }, rect.width / 2, rect.height / 2)
			Choice => Drawing.polygon([{ x: cx, y: rect.y }, { x: rect.x + rect.width, y: cy }, { x: cx, y: rect.y + rect.height }, { x: rect.x, y: cy }])
			Fork | Join => Drawing.rectangle(rect)
			Normal => if (options.corners == Square or (state.descriptions.len() > 1 and options.corners == FamilyDefault)) Drawing.rectangle(rect) else Drawing.rounded_rectangle(rect, StateDraw.radius(options))
		}
		fill = match state.effective_kind {
			Initial => { fill: Fill(options.line), stroke: Stroke({ color: options.node_stroke, width: options.line_width / 2 }) }
			Fork | Join => FlowDraw.paint_of(overrides, options.line, options.line, options.line_width)
			Final => { fill: Fill(options.background), stroke: Stroke({ color: options.line, width: options.line_width }) }
			Normal | Choice => paint
		}
		var $items = FlowDraw.shadows(StateDraw.drawing_theme(options), [path], fill, options.background).append(Shape({ path, paint: fill }))
		if state.effective_kind == Final {
			$items = $items.append(Shape({ path: Drawing.ellipse({ x: cx, y: cy }, rect.width * 5 / 28, rect.height * 5 / 28), paint: { fill: Fill(options.node_stroke), stroke: NoStroke } }))
		}
		if state.effective_kind == Normal {
			title = if (state.descriptions.len() > 1) StateDraw.compartment_block(state.label, options) else StateDraw.block(state.label, options)
			body = StateDraw.compartment_block(Str.join_with(state.descriptions.drop_first(1), "\n"), options)
			$items = $items.concat(StateDraw.lines(title.lines, cx, rect.y + (if (state.descriptions.len() > 1) StateDraw.state_padding(options) / 2 else StateDraw.state_padding(options)), color, options))
			if state.descriptions.len() > 1 {
				y = rect.y + StateDraw.state_padding(options) / 2 + title.height
				$items = $items.append(Shape({ path: [MoveTo({ x: rect.x, y }), LineTo({ x: rect.x + rect.width, y })], paint: { fill: NoFill, stroke: paint.stroke } }))
				$items = $items.concat(StateDraw.lines(body.lines, cx, rect.y + StateDraw.state_padding(options) + title.height + 5, color, options))
			}
		}
		$items
	}

	lines : List(Str), F64, F64, Drawing.Color, Theme.Options -> List(Drawing.Item)
	lines = |rows, x, top, color, options| rows.map_with_index(|text, i| Text({ text, origin: { x, y: top + StateDraw.baseline(options) + i.to_f64() * options.font_size * options.line_height }, size: options.font_size, align: Center, color }))

	## Contract probe: every text ink box belongs to a painted node, group,
	## note, or edge-label box, rather than merely fitting the outer canvas.
	labels_contained : Drawing.Picture, Theme.Options -> Bool
	labels_contained = |picture, options| StateDraw.labels_contained_in(picture, options, [])

	## Composite titles deliberately overhang their frame by2px in pinned
	## Mermaid; this explicit allowance applies only to authored groups.
	labels_contained_in : Drawing.Picture, Theme.Options, List(Drawing.Rect) -> Bool
	labels_contained_in = |picture, options, headers| {
		visible_items = match picture.items.first() {
			Ok(Shape(first)) if first.path == Drawing.rectangle(picture.view) and first.paint == { fill: Fill(options.background), stroke: NoStroke } => picture.items.drop_first(1)
			_ => picture.items
		}
		painted_candidates = visible_items.fold(
			[],
			|out, item| match item {
				Text(_) | StyledText(_) => out
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
		candidates = painted_candidates.concat(headers.map(|rect| { left: rect.x, top: rect.y - 2, right: rect.x + rect.width, bottom: rect.y + rect.height }))
		picture.items.all(
			|item| match item {
				Shape(_) => True
				Text(text_item) | StyledText({ label: text_item, italic: _, underline: _, bold: _ }) => {
					if text_item.text.is_empty() {
						True
					} else {
						measured = TextMeasure.block(text_item.text, { font: TextMeasure.inter, size: options.font_size, line_height: options.line_height, wrap: NoWrap, align: Middle })
						left = text_item.origin.x - measured.width / 2
						right = text_item.origin.x + measured.width / 2
						# A normal row must not be charged the emoji descent
						# of another font. Use this row's browser-style box,
						# retaining unrounded extents for tiny font settings.
						row_box = StateDraw.unwrapped(text_item.text, options)
						row_top = text_item.origin.y - StateDraw.baseline(options)
						row_bottom = row_top + row_box.height
						candidates.any(|bounds| left >= bounds.left - 0.001 and right <= bounds.right + 0.001 and row_top >= bounds.top - 0.001 and row_bottom <= bounds.bottom + 0.001)
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
	state = { id: "A", label: "Titleg", descriptions: ["Titleg", "Bodyg"], kind: Normal, effective_kind: Normal, container: Root, classes: [], styles: [] }
	diagram = { declarations: [], direction: Down, states: [state], transitions: [], groups: [], classes: [], notes: [] }
	size = StateDraw.measure_sizes(diagram, options).nodes.first()?
	rect = { x: 0, y: 0, width: size.width, height: size.height }
	labels = StateDraw.node(diagram, state, rect, options).fold(
		[],
		|out, item| match item {
			Text(label) | StyledText({ label, italic: _, underline: _, bold: _ }) => out.append(label)
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
	Drawing.is_finite(picture) and StateDraw.labels_contained_in(picture, options, StateDraw.setup(diagram, options).geometry.groups.take_first(diagram.groups.len()))
		and theme.line_height == 0.1 and theme.corner_radius == 19
}
