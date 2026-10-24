import Drawing
import Flowchart
import FlowDrawEdge
import FlowDrawShape
import FlowDrawStyle
import FlowGeometry

## Draws a laid-out flowchart the way Mermaid 12 renders it with its default
## look: white nodes with dark outlines and a faint offset shadow, black
## edges with rounded bends and hops at crossings, grey label backgrounds,
## and subgraphs tinted from a cycle of pastel colours. `classDef`, `class`,
## `style` and `linkStyle` statements change fill, stroke, stroke width and
## text colour.
##
## Every list in the sizes and geometry is read by the index of the matching
## diagram element; an element without an entry is not drawn.
FlowDraw :: {}.{

	## The colours and measures a drawing uses. Opacities run from 0 to 1;
	## translucent paint is drawn as the opaque colour it gives over what
	## lies beneath, since the drawing has no transparency.
	Theme : {
		font_size : F64,
		background : Drawing.Color,
		node_fill : Drawing.Color,
		node_stroke : Drawing.Color,
		node_stroke_width : F64,
		node_text : Drawing.Color,
		line : Drawing.Color,
		line_width : F64,
		thick_line_width : F64,
		label_background : Drawing.Color,
		label_background_opacity : F64,
		label_text : Drawing.Color,
		group_colors : List({ fill : Drawing.Color, stroke : Drawing.Color }),
		group_stroke_width : F64,
		group_text : Drawing.Color,
		shadow : [NoShadow, Shadow({ dx : F64, dy : F64, opacity : F64 })],
	}

	## Mermaid 12's default flowchart look on a white page.
	mermaid : Theme
	mermaid = {
		font_size: 14,
		background: Drawing.white,
		node_fill: Drawing.white,
		node_stroke: Drawing.rgb(0x28253D),
		node_stroke_width: 2,
		node_text: Drawing.rgb(0x28253D),
		line: Drawing.black,
		line_width: 2,
		thick_line_width: 3.5,
		label_background: Drawing.rgb(0xCCCCCC),
		label_background_opacity: 0.5,
		label_text: Drawing.rgb(0x28253D),
		group_colors: [
			{ fill: Drawing.rgb(0xFDF4FF), stroke: Drawing.rgb(0xE879F9) },
			{ fill: Drawing.rgb(0xF0FDFA), stroke: Drawing.rgb(0x2DD4BF) },
			{ fill: Drawing.rgb(0xFFF7ED), stroke: Drawing.rgb(0xFB923C) },
			{ fill: Drawing.rgb(0xECFEFF), stroke: Drawing.rgb(0x22D3EE) },
			{ fill: Drawing.rgb(0xF0FDF4), stroke: Drawing.rgb(0x4ADE80) },
			{ fill: Drawing.rgb(0xF5F3FF), stroke: Drawing.rgb(0xA78BFA) },
			{ fill: Drawing.rgb(0xFEF2F2), stroke: Drawing.rgb(0xF87171) },
			{ fill: Drawing.rgb(0xFEFCE8), stroke: Drawing.rgb(0xFACC15) },
			{ fill: Drawing.rgb(0xEEF2FF), stroke: Drawing.rgb(0x818CF8) },
			{ fill: Drawing.rgb(0xF7FEE7), stroke: Drawing.rgb(0xA3E635) },
			{ fill: Drawing.rgb(0xF0F9FF), stroke: Drawing.rgb(0x38BDF8) },
			{ fill: Drawing.rgb(0xFFF1F2), stroke: Drawing.rgb(0xFB7185) },
		],
		group_stroke_width: 1,
		group_text: Drawing.black,
		shadow: Shadow({ dx: 4, dy: 4, opacity: 0.06 }),
	}

	## Draw a diagram with Mermaid's default look.
	draw : Flowchart.Diagram, FlowGeometry.Sizes, FlowGeometry.Geometry -> Drawing.Picture
	draw = |diagram, sizes, geometry| FlowDraw.draw_with(diagram, sizes, geometry, FlowDraw.mermaid)

	## Draw a diagram with a theme. Groups come first, outer before inner,
	## then node shadows, edges, edge labels and nodes, as Mermaid layers
	## them.
	draw_with : Flowchart.Diagram, FlowGeometry.Sizes, FlowGeometry.Geometry, Theme -> Drawing.Picture
	draw_with = |diagram, sizes, geometry, theme| {
		walk = FlowDraw.group_order(diagram.groups)
		group_paint = FlowDraw.group_paints(diagram, walk, theme)
		var $items = []
		for g in walk.order {
			match (geometry.groups.get(g), group_paint.get(g)) {
				(Ok(rect), Ok(paint)) => {
					# An empty group's box has no height; SVG paints nothing for
					# such a rectangle, so Mermaid shows only the title.
					if rect.width > 0 and rect.height > 0 {
						$items = $items.concat(FlowDraw.shadowed(theme, [Drawing.rectangle(rect)], paint.paint, paint.beneath))
					}
					title = match sizes.group_titles.get(g) {
						Ok(block) => block.lines
						Err(_) => []
					}
					$items = $items.concat(FlowDraw.lines(title, rect.x + rect.width / 2, rect.y, theme.font_size, paint.text))
				}
				_ => {}
			}
		}
		# Node shadows go beneath the edges: Mermaid's shadow is translucent
		# and painted with the node, so lines it falls on show through.
		nodes = FlowDraw.node_layers(diagram, sizes, geometry, group_paint, theme)
		$items = $items.concat(nodes.shadows)
		routes = diagram.edges.map_with_index(
			|_, index|
				match geometry.edges.get(index) {
					Ok(route) => route.points
					Err(_) => []
				},
		)
		hops = FlowDrawEdge.hops(routes)
		var $strokes = []
		for index in 0..<diagram.edges.len() {
			match diagram.edges.get(index) {
				Ok(edge) => {
					drawn = FlowDraw.edge_items(diagram, edge, routes.get(index) ?? [], hops.get(index) ?? [], theme)
					for item in drawn {
						match item {
							Shape(sh) =>
								match (sh.paint.fill, sh.paint.stroke) {
									(NoFill, Stroke(st)) => {
										$strokes = $strokes.append({ path: sh.path, color: st.color, width: st.width })
									}
									_ => {}
								}
							Text(_) => {}
						}
					}
					$items = $items.concat(drawn)
				}
				Err(_) => {}
			}
		}
		for index in 0..<diagram.edges.len() {
			match (diagram.edges.get(index), sizes.edge_labels.get(index), geometry.edges.get(index)) {
				(Ok(edge), Ok(Some(block)), Ok(route)) =>
					match route.label {
						Some(at) => {
							o = FlowDrawStyle.resolve(diagram.classes, edge.classes, edge.styles, False)
							beneath = FlowDraw.beneath_point(at, geometry, walk, group_paint, theme)
							$items = $items.concat(FlowDraw.edge_label(block, at, o, beneath, $strokes, theme))
						}
						None => {}
					}
				_ => {}
			}
		}
		$items = $items.concat(nodes.bodies)
		{ view: geometry.bounds, items: $items }
	}

	## Groups in painting order, each before the groups inside it (the order
	## of `subgraph` statements in the source), with each group's position
	## in that order and its depth. A group whose container chain does not
	## reach the top level is left out.
	group_order : List(Flowchart.Group) -> { order : List(U64), slot : List(U64), depth : List(U64) }
	group_order = |groups| {
		n = groups.len()
		parent_of = |g|
			match groups.get(g) {
				Ok(group) =>
					match group.container {
						Group(p) => if (p < n) Ok(p) else Err(Root)
						Root => Err(Root)
					}
				Err(_) => Err(Root)
			}
		var $order = List.with_capacity(n)
		var $slot = List.repeat(0, n)
		var $depth = List.repeat(0, n)
		var $seen = List.repeat(False, n)
		var $stack = []
		for i in 0..<n {
			index = n - 1 - i
			match parent_of(index) {
				Err(_) => {
					$stack = $stack.append({ group: index, depth: 0 })
				}
				Ok(_) => {}
			}
		}
		while !$stack.is_empty() {
			top = $stack.last() ?? { group: 0, depth: 0 }
			$stack = $stack.drop_last(1)
			if !($seen.get(top.group) ?? True) {
				$seen = $seen.set(top.group, True) ?? []
				$slot = $slot.set(top.group, $order.len()) ?? []
				$depth = $depth.set(top.group, top.depth) ?? []
				$order = $order.append(top.group)
				for i in 0..<n {
					child = n - 1 - i
					if parent_of(child) == Ok(top.group) {
						$stack = $stack.append({ group: child, depth: top.depth + 1 })
					}
				}
			}
		}
		{ order: $order, slot: $slot, depth: $depth }
	}

	GroupPaint : { paint : Drawing.Paint, text : Drawing.Color, beneath : Drawing.Color, inside : Drawing.Color }

	## Each group's paint, the colour beneath it and the colour seen inside
	## it, by group index.
	group_paints : Flowchart.Diagram, { order : List(U64), slot : List(U64), depth : List(U64) }, Theme -> List(GroupPaint)
	group_paints = |diagram, walk, theme| {
		fallback = { paint: { fill: NoFill, stroke: NoStroke }, text: theme.group_text, beneath: theme.background, inside: theme.background }
		var $out = List.repeat(fallback, diagram.groups.len())
		for g in walk.order {
			match diagram.groups.get(g) {
				Err(_) => {}
				Ok(group) => {
					count = theme.group_colors.len()
					slot = walk.slot.get(g) ?? 0
					colors = if (count == 0) { fill: theme.background, stroke: theme.node_stroke } else theme.group_colors.get(slot % count) ?? { fill: theme.background, stroke: theme.node_stroke }
					o = FlowDrawStyle.resolve(diagram.classes, group.classes, [], False)
					beneath = match group.container {
						Root => theme.background
						Group(p) => ($out.get(p) ?? fallback).inside
					}
					paint = FlowDraw.paint_of(o, colors.fill, colors.stroke, theme.group_stroke_width)
					inside = match paint.fill {
						Fill(c) => c
						NoFill => beneath
					}
					text = match o.color {
						Paint(c) => c
						Keep => theme.group_text
					}
					$out = $out.set(g, { paint, text, beneath, inside }) ?? []
				}
			}
		}
		$out
	}

	## A theme's fill, stroke and width with overrides applied.
	paint_of : FlowDrawStyle.Overrides, Drawing.Color, Drawing.Color, F64 -> Drawing.Paint
	paint_of = |o, fill, stroke, width| {
		w = match o.stroke_width {
			Width(v) => v
			Keep => width
		}
		{
			fill: match o.fill {
				Keep => Fill(fill)
				Paint(c) => Fill(c)
				Remove => NoFill
			},
			stroke: match o.stroke {
				Keep => if (w > 0) Stroke({ color: stroke, width: w }) else NoStroke
				Paint(c) => if (w > 0) Stroke({ color: c, width: w }) else NoStroke
				Remove => NoStroke
			},
		}
	}

	## The colour beneath a point that is not inside any node: the inside of
	## the deepest group whose box holds it.
	beneath_point : Drawing.Point, FlowGeometry.Geometry, { order : List(U64), slot : List(U64), depth : List(U64) }, List(GroupPaint), Theme -> Drawing.Color
	beneath_point = |at, geometry, walk, paints, theme| {
		var $best = theme.background
		var $best_depth = 0
		var $found = False
		for g in walk.order {
			match geometry.groups.get(g) {
				Ok(r) =>
					if at.x >= r.x and at.x <= r.x + r.width and at.y >= r.y and at.y <= r.y + r.height {
						d = walk.depth.get(g) ?? 0
						if !$found or d >= $best_depth {
							$best = (paints.get(g) ?? { paint: { fill: NoFill, stroke: NoStroke }, text: theme.group_text, beneath: theme.background, inside: theme.background }).inside
							$best_depth = d
							$found = True
						}
					}
				Err(_) => {}
			}
		}
		$best
	}

	## `top` over `bottom` at an opacity from 0 to 1.
	blend : Drawing.Color, Drawing.Color, F64 -> Drawing.Color
	blend = |top, bottom, opacity| {
		a = if (F64.is_finite(opacity)) opacity.max(0).min(1) else 1
		mix = |t, b| {
			v = t.to_f64() * a + b.to_f64() * (1 - a)
			v.round_to_u8_try() ?? (if (v > 127) 255 else 0)
		}
		{ red: mix(top.red, bottom.red), green: mix(top.green, bottom.green), blue: mix(top.blue, bottom.blue) }
	}

	## Paths painted with a shadow first when the theme has one: the same
	## paths, offset, in the shadow's colour over what lies beneath.
	shadowed : Theme, List(List(Drawing.Segment)), Drawing.Paint, Drawing.Color -> List(Drawing.Item)
	shadowed = |theme, paths, paint, beneath| {
		var $out = []
		for path in paths {
			$out = $out.concat(FlowDraw.shadows(theme, [path], paint, beneath)).concat(FlowDraw.shape(path, paint))
		}
		$out
	}

	## The theme's shadows of paths, offset, in the shadow's colour over what
	## lies beneath; nothing when the theme has no shadow.
	shadows : Theme, List(List(Drawing.Segment)), Drawing.Paint, Drawing.Color -> List(Drawing.Item)
	shadows = |theme, paths, paint, beneath|
		match theme.shadow {
			NoShadow => []
			Shadow(s) => {
				shade = FlowDraw.blend(Drawing.black, beneath, s.opacity)
				shadow_paint = {
					fill: match paint.fill {
						Fill(_) => Fill(shade)
						NoFill => NoFill
					},
					stroke: match paint.stroke {
						Stroke(st) => Stroke({ color: shade, width: st.width })
						NoStroke => NoStroke
					},
				}
				paths.fold([], |acc, path| acc.concat(FlowDraw.shape(Drawing.translate(path, { x: s.dx, y: s.dy }), shadow_paint)))
			}
		}

	## A shape item, or nothing when it would paint nothing.
	shape : List(Drawing.Segment), Drawing.Paint -> List(Drawing.Item)
	shape = |path, paint|
		match (paint.fill, paint.stroke) {
			(NoFill, NoStroke) => []
			_ => if (path.is_empty()) [] else [Shape({ path, paint })]
		}

	## Lines of text centred on `x`, the block's top at `top`, spaced as
	## Mermaid spaces label rows: 1.1 em apart, the first baseline 1 em
	## below the top.
	lines : List(Str), F64, F64, F64, Drawing.Color -> List(Drawing.Item)
	lines = |rows, x, top, size, color| {
		var $out = []
		for k in 0..<rows.len() {
			row = rows.get(k) ?? ""
			if row != "" {
				$out = $out.append(Text({ text: row, origin: { x, y: top + size + k.to_f64() * size * 1.1 }, size, align: Center, color }))
			}
		}
		$out
	}

	## Height of a block of label rows: one line box (17 pixels at 14 pixel
	## text) plus 1.1 em for each further row.
	block_height : U64, F64 -> F64
	block_height = |rows, size| size * 17 / 14 + (rows.max(1) - 1).to_f64() * size * 1.1

	## Every node's shadow and body (outline and label), in node order.
	node_layers : Flowchart.Diagram, FlowGeometry.Sizes, FlowGeometry.Geometry, List(GroupPaint), Theme -> { shadows : List(Drawing.Item), bodies : List(Drawing.Item) }
	node_layers = |diagram, sizes, geometry, group_paint, theme| {
		var $shadows = []
		var $bodies = []
		for index in 0..<diagram.nodes.len() {
			match (diagram.nodes.get(index), geometry.nodes.get(index)) {
				(Ok(node), Ok(rect)) => {
					label = match sizes.nodes.get(index) {
						Ok(size) => size.label.lines
						Err(_) => []
					}
					beneath = match node.container {
						Root => theme.background
						Group(g) =>
							match group_paint.get(g) {
								Ok(p) => p.inside
								Err(_) => theme.background
							}
					}
					parts = FlowDraw.node_items(diagram, node, rect, label, beneath, theme)
					$shadows = $shadows.concat(parts.shadow)
					$bodies = $bodies.concat(parts.body)
				}
				_ => {}
			}
		}
		{ shadows: $shadows, bodies: $bodies }
	}

	node_items : Flowchart.Diagram, Flowchart.Node, Drawing.Rect, List(Str), Drawing.Color, Theme -> { shadow : List(Drawing.Item), body : List(Drawing.Item) }
	node_items = |diagram, node, rect, rows, beneath, theme| {
		o = FlowDrawStyle.resolve(diagram.classes, node.classes, node.styles, True)
		outline = FlowDrawShape.outline(node.shape, rect)
		paint = FlowDraw.paint_of(o, theme.node_fill, theme.node_stroke, theme.node_stroke_width)
		color = match o.color {
			Paint(c) => c
			Keep => theme.node_text
		}
		cx = rect.x + rect.width / 2 + outline.label_offset.x
		cy = rect.y + rect.height / 2 + outline.label_offset.y
		top = cy - FlowDraw.block_height(rows.len(), theme.font_size) / 2
		# Only the outermost path's shadow can fall outside the node, on
		# edges; the shadows of paths inside it (a double circle's inner
		# ring) fall on the node's own fill and are painted with it.
		outer = outline.paths.take_first(1)
		inner = outline.paths.drop_first(1)
		painted = |path|
			if outline.sketched {
				FlowDraw.shape(path, { fill: paint.fill, stroke: NoStroke }).concat(FlowDraw.shape(FlowDrawShape.sketch(path), { fill: NoFill, stroke: paint.stroke }))
			} else {
				FlowDraw.shape(path, paint)
			}
		{
			shadow: FlowDraw.shadows(theme, outer, paint, beneath),
			body: outer
				.fold([], |acc, path| acc.concat(painted(path)))
				.concat(FlowDraw.shadowed(theme, inner, paint, beneath))
				.concat(FlowDraw.lines(rows, cx, top, theme.font_size, color)),
		}
	}

	## An edge label on its background. The background is translucent in
	## Mermaid, so lines under it show through: they are redrawn inside the
	## background in the colour they take through it.
	edge_label : FlowGeometry.TextBlock, Drawing.Point, FlowDrawStyle.Overrides, Drawing.Color, List({ path : List(Drawing.Segment), color : Drawing.Color, width : F64 }), Theme -> List(Drawing.Item)
	edge_label = |block, at, o, beneath, strokes, theme| {
		if block.lines.all(|row| row == "") {
			[]
		} else {
			height = FlowDraw.block_height(block.lines.len(), theme.font_size)
			top = at.y - height / 2
			box = { x: at.x - block.width / 2 - 2, y: top - 2, width: block.width + 4, height: height + 4 }
			color = match o.color {
				Paint(c) => c
				Keep => theme.label_text
			}
			background = FlowDraw.blend(theme.label_background, beneath, theme.label_background_opacity)
			opacity = theme.label_background_opacity
			show_through = strokes.fold(
				[],
				|acc, st|
					acc.concat(FlowDraw.shape(FlowDrawEdge.clip(st.path, box), { fill: NoFill, stroke: Stroke({ color: FlowDraw.blend(theme.label_background, st.color, opacity), width: st.width }) })),
			)
			FlowDraw.shape(Drawing.rectangle(box), { fill: Fill(background), stroke: NoStroke })
				.concat(show_through)
				.concat(FlowDraw.lines(block.lines, at.x, top, theme.font_size, color))
		}
	}

	## Most dotted dashes drawn on one edge; a longer dotted edge is drawn
	## solid.
	dash_limit : U64
	dash_limit = 50000

	edge_items : Flowchart.Diagram, Flowchart.Edge, List(Drawing.Point), List(FlowDrawEdge.Hop), Theme -> List(Drawing.Item)
	edge_items = |diagram, edge, route, hops, theme| {
		o = FlowDrawStyle.resolve(diagram.classes, edge.classes, edge.styles, False)
		visible = edge.line != Invisible and o.stroke != Remove and route.len() >= 2
		if !visible {
			[]
		} else {
			color = match o.stroke {
				Paint(c) => c
				_ => theme.line
			}
			width = match o.stroke_width {
				Width(w) => w
				Keep => if (edge.line == Thick) theme.thick_line_width else theme.line_width
			}
			start = FlowDraw.end_kind(edge.start)
			end = FlowDraw.end_kind(edge.end)
			pieces = FlowDrawEdge.pieces(FlowDrawEdge.shift_ends(route, start, end), hops)
			total = pieces.fold(0.0, |acc, p| acc + FlowDrawEdge.length(p))
			s = FlowDrawEdge.hidden(start)
			e = FlowDrawEdge.hidden(end)
			middle = total - s - e
			pairs = if (middle > 0) (middle / 4).floor_to_u64_try() ?? 0 else 0
			pattern = if edge.line == Dotted and pairs <= FlowDraw.dash_limit {
				[0, s].concat(List.repeat([2.0, 2.0], pairs).join()).append(e)
			} else {
				[0, s, middle, e]
			}
			path = FlowDrawEdge.trace(pieces, FlowDrawEdge.dashes(total, pattern))
			line_items = if (width > 0) FlowDraw.shape(path, { fill: NoFill, stroke: Stroke({ color, width }) }) else []
			marks = match FlowDrawEdge.ends(pieces) {
				Err(_) => []
				Ok(at) => FlowDrawEdge.mark(start, Start, at.start, at.start_dir).concat(FlowDrawEdge.mark(end, Finish, at.end, at.end_dir))
			}
			mark_items = marks.map(
				|m|
					match m {
						Filled(p) => Shape({ path: p, paint: { fill: Fill(color), stroke: NoStroke } })
						Disc(p) => Shape({ path: p, paint: { fill: Fill(theme.line), stroke: NoStroke } })
						Stroked(st) => Shape({ path: st.path, paint: { fill: NoFill, stroke: Stroke({ color, width: st.width }) } })
					},
			)
			line_items.concat(mark_items)
		}
	}

	end_kind : Flowchart.Arrowhead -> FlowDrawEdge.End
	end_kind = |head|
		match head {
			None => None
			Arrow => Arrow
			Circle => Circle
			Cross => Cross
		}
}

expect FlowDraw.blend(Drawing.black, Drawing.white, 0.06) == { red: 240, green: 240, blue: 240 }
expect FlowDraw.blend(Drawing.rgb(0xCCCCCC), Drawing.white, 0.5) == { red: 230, green: 230, blue: 230 }

expect {
	walk = FlowDraw.group_order([
		{ id: "inner", title: "inner", container: Group(1), direction: Inherit, classes: [] },
		{ id: "outer", title: "outer", container: Root, direction: Inherit, classes: [] },
		{ id: "other", title: "other", container: Root, direction: Inherit, classes: [] },
	])
	walk == { order: [1, 0, 2], slot: [1, 0, 2], depth: [1, 0, 0] }
}

## An empty diagram draws nothing in the given bounds.
expect {
	picture = FlowDraw.draw(
		{ direction: Down, nodes: [], edges: [], groups: [], classes: [] },
		{ nodes: [], edge_labels: [], group_titles: [] },
		{ nodes: [], edges: [], groups: [], bounds: { x: 0, y: 0, width: 16, height: 16 } },
	)
	picture == { view: { x: 0, y: 0, width: 16, height: 16 }, items: [] }
}

## An empty group (a box with no height) shows only its title, as SVG
## paints nothing for a rectangle without area.
expect {
	picture = FlowDraw.draw(
		{ direction: Down, nodes: [], edges: [], groups: [{ id: "g", title: "Hollow", container: Root, direction: Inherit, classes: [] }], classes: [] },
		{ nodes: [], edge_labels: [], group_titles: [{ lines: ["Hollow"], width: 45, height: 17 }] },
		{ nodes: [], edges: [], groups: [{ x: 0, y: 20, width: 53, height: 0 }], bounds: { x: 0, y: 0, width: 60, height: 40 } },
	)
	is_text = |item|
		match item {
			Shape(_) => False
			Text(_) => True
		}
	picture.items.len() == 1 and picture.items.all(is_text)
}

## A group with area is still drawn, with its shadow.
expect {
	picture = FlowDraw.draw(
		{ direction: Down, nodes: [], edges: [], groups: [{ id: "g", title: "", container: Root, direction: Inherit, classes: [] }], classes: [] },
		{ nodes: [], edge_labels: [], group_titles: [{ lines: [""], width: 0, height: 0 }] },
		{ nodes: [], edges: [], groups: [{ x: 0, y: 0, width: 50, height: 30 }], bounds: { x: 0, y: 0, width: 60, height: 40 } },
	)
	picture.items.len() == 2
}

## A node's shadow is painted before the edges, so an edge leaving the node
## shows through it as it does through Mermaid's translucent shadow; the
## node itself is painted after the edges.
expect {
	node = |id| { id, label: id, shape: Rectangle, container: Root, classes: [], styles: [] }
	shadow_color = FlowDraw.blend(Drawing.black, Drawing.white, 0.06)
	picture = FlowDraw.draw(
		{
			direction: Down,
			nodes: [node("a"), node("b")],
			edges: [{ id: "e", from: Node(0), to: Node(1), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }],
			groups: [],
			classes: [],
		},
		{ nodes: [{ width: 40, height: 20, label: { lines: ["a"], width: 7, height: 17 } }, { width: 40, height: 20, label: { lines: ["b"], width: 7, height: 17 } }], edge_labels: [None], group_titles: [] },
		{
			nodes: [{ x: 0, y: 0, width: 40, height: 20 }, { x: 0, y: 60, width: 40, height: 20 }],
			edges: [{ points: [{ x: 20, y: 20 }, { x: 20, y: 60 }], label: None }],
			groups: [],
			bounds: { x: 0, y: 0, width: 50, height: 90 },
		},
	)
	kinds = picture.items.map(
		|item|
			match item {
				Shape(sh) =>
					match (sh.paint.fill, sh.paint.stroke) {
						(NoFill, Stroke(_)) => "edge"
						(Fill(c), _) => if (c == shadow_color) "shadow" else "node"
						_ => "other"
					}
				Text(_) => "text"
			},
	)
	kinds == ["shadow", "shadow", "edge", "node", "text", "node", "text"]
}

## A double circle's inner ring keeps its shadow, painted over the outer
## ring's fill, while the outer ring's shadow goes beneath the edges.
expect {
	theme = FlowDraw.mermaid
	parts = FlowDraw.node_items(
		{ direction: Down, nodes: [], edges: [], groups: [], classes: [] },
		{ id: "d", label: "", shape: DoubleCircle, container: Root, classes: [], styles: [] },
		{ x: 0, y: 0, width: 60, height: 60 },
		[],
		theme.background,
		theme,
	)
	parts.shadow.len() == 1 and parts.body.len() == 3
}
