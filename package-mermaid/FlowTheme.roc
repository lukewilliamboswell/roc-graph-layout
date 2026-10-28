import Drawing
import Flowchart
import FlowDraw
import FlowDrawShape
import FlowGeometry
import FlowLayout
import FlowSize
import FlowThemeShape
import FlowThemeRoute
import TextMeasure
import Theme

## The themed flowchart path keeps sizing and drawing in the same units.
## The legacy comparison pipeline retains Mermaid's recorded defaults.
FlowTheme :: {}.{
	draw : Str, Theme.Options -> Try(Drawing.Picture, List(Flowchart.Problem))
	draw = |text, theme| {
		problems = Theme.validate(theme)
		match Flowchart.parse(text) {
			Err(found) => Err(found.concat(problems))
			Ok(diagram) => if problems.is_empty() {
				Ok(FlowTheme.draw_diagram(diagram, theme))
			} else {
				Err(problems)
			}
		}
	}

	sizes : Flowchart.Diagram, Theme.Options -> FlowGeometry.Sizes
	sizes = |diagram, theme| {
		if theme.font_size == 14 and theme.line_height == 1.1 and theme.max_label_width == 120 and theme.padding == 15 and theme.wrapping != NoWrap {
			return FlowSize.sizes(diagram, FlowSize.mermaid)
		}
		style = {
			font: TextMeasure.inter,
			size: theme.font_size,
			line_height: theme.line_height,
			wrap: if theme.wrapping == NoWrap {
				NoWrap
			} else {
				Width(theme.max_label_width)
			},
			align: Middle,
		}
		metrics = TextMeasure.metrics_of(style)
		measure = |text| FlowTheme.measured_block(text, style, metrics.ascent.max(metrics.emoji_ascent), metrics.descent.max(metrics.emoji_descent))
		{
			nodes: diagram.nodes.map(
				|node| {
					label = measure(node.label)
					size = FlowThemeShape.size(node.shape, label, theme)
					{ width: size.width, height: size.height, label }
				},
			),
			edge_labels: diagram.edges.map(|edge| if (edge.label.is_empty()) None else Some(measure(edge.label))),
			group_titles: diagram.groups.map(|group| measure(group.title)),
		}
	}

	measured_block : Str, TextMeasure.Style, F64, F64 -> FlowGeometry.TextBlock
	measured_block = |text, style, ascent, descent| {
		measured = TextMeasure.block(text, style)
		if measured.lines.all(|line| line == "") {
			return measured
		}
		painted_height = FlowDraw.height_with(measured.lines.len(), style.size, style.line_height)
		last_baseline = style.size + (measured.lines.len() - 1).to_f64() * style.size * style.line_height
		above_center = painted_height / 2 + ascent - style.size
		below_center = last_baseline + descent - painted_height / 2
		# FlowDraw centres its baseline box rather than the font's ascent /
		# descent box. Their difference is visible at large font sizes and
		# very small line spacing; reserve both sides of the actual ink.
		{ ..measured, height: measured.height.max(2 * above_center).max(2 * below_center) }
	}

	rounded_point : Drawing.Rect, F64, Drawing.Point, Drawing.Point -> Drawing.Point
	rounded_point = FlowThemeRoute.project_point

	clip_routes : Flowchart.Diagram, FlowGeometry.Geometry, F64 -> FlowGeometry.Geometry
	clip_routes = FlowThemeRoute.clip

	radius : Theme.Options -> F64
	radius = |theme| if theme.corners == Square {
		0
	} else {
		theme.corner_radius
	}

	draw_diagram : Flowchart.Diagram, Theme.Options -> Drawing.Picture
	draw_diagram = |diagram, theme| {
		measured = FlowTheme.sizes(diagram, theme)
		geometry = FlowTheme.clip_routes(diagram, FlowLayout.layout(diagram, measured), FlowTheme.radius(theme))
		paint = {
			..FlowDraw.mermaid,
			font_size: theme.font_size,
			line_height: theme.line_height,
			corner_radius: FlowTheme.radius(theme),
			background: theme.background,
			node_fill: theme.node_fill,
			node_stroke: theme.node_stroke,
			node_stroke_width: theme.line_width,
			node_text: theme.node_text,
			line: theme.line,
			line_width: theme.line_width,
			thick_line_width: theme.line_width * 1.75,
			label_background: theme.label_background,
			label_background_opacity: theme.label_background_opacity,
			label_text: theme.label_text,
			group_colors: if theme.group_fill == Drawing.rgb(0xFDF4FF) and theme.group_stroke == Drawing.rgb(0xE879F9) {
				FlowDraw.mermaid.group_colors
			} else {
				[{ fill: theme.group_fill, stroke: theme.group_stroke }]
			},
			group_stroke_width: theme.line_width / 2,
			group_text: theme.node_text,
			shadow: theme.shadow,
		}
		FlowDraw.draw_with(diagram, measured, geometry, paint)
	}
}

expect
	match FlowTheme.draw("flowchart TD\nA[A long description that wraps onto several lines] --> B[Done]\n", Theme.Options.{ max_label_width: 80, font_size: 20, line_height: 1.8 }) {
		Ok(picture) => Drawing.is_finite(picture) and picture.items.count_if(
			|item| match item {
				Text(_) => True
				_ => False
			},
		) > 2
		Err(_) => False
	}

expect
	match FlowTheme.draw("sequenceDiagram\n", Theme.Options.{ font_size: -1, padding: -2 }) {
		Err(problems) => problems.len() == 3
		Ok(_) => False
	}

# These checks test the actual painted outlines, independently of the sizing
# formulas, by winding through their straight and flattened cubic segments.
FlowThemeChecks :: {}.{
	Line : { from : Drawing.Point, to : Drawing.Point }

	flatten : List(Drawing.Segment) -> List(Line)
	flatten = |segments| {
		var $lines = []
		var $at = { x: 0, y: 0 }
		var $first = $at
		for segment in segments {
			match segment {
				MoveTo(point) => {
					$at = point
					$first = point
				}
				LineTo(point) => {
					$lines = $lines.append({ from: $at, to: point })
					$at = point
				}
				Close => {
					$lines = $lines.append({ from: $at, to: $first })
					$at = $first
				}
				CubicTo(curve) => {
					start = $at
					steps : U64
					steps = 128
					for offset in 0..<steps {
						i = offset + 1
						t = i.to_f64() / 128
						u = 1 - t
						point = {
							x: u * u * u * start.x + 3 * u * u * t * curve.control_1.x + 3 * u * t * t * curve.control_2.x + t * t * t * curve.end.x,
							y: u * u * u * start.y + 3 * u * u * t * curve.control_1.y + 3 * u * t * t * curve.control_2.y + t * t * t * curve.end.y,
						}
						$lines = $lines.append({ from: $at, to: point })
						$at = point
					}
				}
			}
		}
		$lines
	}

	inside : Drawing.Point, List(Line) -> Bool
	inside = |point, lines| {
		initial_winding : I64
		initial_winding = 0
		var $winding = initial_winding
		for line in lines {
			dx = line.to.x - line.from.x
			dy = line.to.y - line.from.y
			cross = dx * (point.y - line.from.y) - dy * (point.x - line.from.x)
			along = (point.x - line.from.x) * dx + (point.y - line.from.y) * dy
			length_sq = dx * dx + dy * dy
			if cross.abs() <= 0.001 * length_sq.sqrt() and along >= 0 and along <= length_sq and length_sq > 0 {
				return True
			}
			if line.from.y <= point.y {
				if line.to.y > point.y and cross > 0 {
					$winding = $winding + 1
				}
			} else if line.to.y <= point.y and cross < 0 {
				$winding = $winding - 1
			}
		}
		$winding != 0
	}

	padded_label_inside : Flowchart.Shape, FlowGeometry.TextBlock, Theme.Options -> Bool
	padded_label_inside = |shape, label, theme| {
		size = FlowThemeShape.size(shape, label, theme)
		rect = { x: 0, y: 0, width: size.width, height: size.height }
		outline = FlowDrawShape.outline(shape, rect)
		path = if shape == Rounded {
			Drawing.rounded_rectangle(rect, theme.corner_radius)
		} else if shape == DoubleCircle {
			outline.paths.last() ?? []
		} else {
			outline.paths.first() ?? []
		}
		lines = FlowThemeChecks.flatten(path)
		half_width = label.width / 2 + theme.padding
		half_height = label.height / 2 + theme.padding
		cx = rect.width / 2 + outline.label_offset.x
		cy = rect.height / 2 + outline.label_offset.y
		[{ x: cx - half_width, y: cy - half_height }, { x: cx + half_width, y: cy - half_height }, { x: cx + half_width, y: cy + half_height }, { x: cx - half_width, y: cy + half_height }].all(|point| FlowThemeChecks.inside(point, lines))
	}

	route_contract : Str -> Bool
	route_contract = |source| {
		match Flowchart.parse(source) {
			Err(_) => False
			Ok(diagram) => {
				theme = Theme.Options.{ max_label_width: 90, corner_radius: 1024 }
				sizes = FlowTheme.sizes(diagram, theme)
				before = FlowLayout.layout(diagram, sizes)
				after = FlowThemeRoute.clip(diagram, before, theme.corner_radius)
				if before.nodes != after.nodes or before.groups != after.groups or before.bounds != after.bounds or before.edges.len() != after.edges.len() {
					return False
				}
				var $changed = False
				var $valid = True
				for i in 0..<diagram.edges.len() {
					match (diagram.edges.get(i), before.edges.get(i), after.edges.get(i)) {
						(Ok(edge), Ok(old), Ok(route)) => {
							if old.points != route.points {
								$changed = True
							}
							if old.label != route.label or old.points.len() != route.points.len() {
								$valid = False
							}
							if !route.points.map_with_index(
								|point, p| {
									match route.points.get(p + 1) {
										Err(_) => True
										Ok(next) => (next.x - point.x).abs() < 0.00001 or (next.y - point.y).abs() < 0.00001
									}
								},
							).all(|ok| ok) {
								$valid = False
							}
							for (endpoint, terminal) in [(edge.from, route.points.first()), (edge.to, route.points.last())] {
								match (endpoint, terminal) {
									(Node(n), Ok(point)) => match (diagram.nodes.get(n), after.nodes.get(n)) {
										(Ok(node), Ok(rect)) if node.shape == Rounded => {
											if !FlowThemeRoute.on_outline(point, rect, theme.corner_radius) {
												$valid = False
											}
										}
										_ => {}
									}
									_ => {}
								}
							}
						}
						_ => {
							$valid = False
						}
					}
				}
				$valid and $changed and Drawing.is_finite(FlowTheme.draw_diagram(diagram, theme))
			}
		}
	}
}

expect {
	label = { lines: ["A wrapped label", "with three rows", "and safe padding"], width: 130, height: 63 }
	[Rectangle, Rounded, Stadium, Subroutine, Cylinder, Circle, DoubleCircle, Ellipse, Asymmetric, Diamond, Hexagon, LeanRight, LeanLeft, Trapezoid, InverseTrapezoid].all(
		|shape| {
			[0.0, 12.0, 40.0].all(
				|padding| {
					ok = FlowThemeChecks.padded_label_inside(shape, label, Theme.Options.{ padding, corner_radius: 1024 })
					if !ok {
						crash Str.inspect((shape, padding))
					}
					ok
				},
			)
		},
	)
}

expect ["TD", "BT", "LR", "RL"].all(
	|direction| {
		source = "flowchart ${direction}\nA(A long source label that wraps over several lines and creates real rounded corners)\nA --> B\nA --> C\nA --> D\nA --> E\nA --> F\nA --> G\nA --> H\nA --> I\nA --> J\nA -->|retry| A\nA -->|parallel| B\n"
		ok = FlowThemeChecks.route_contract(source)
		if !ok {
			crash direction
		}
		ok
	},
)

expect {
	source = "flowchart TD\nA[Long glyphs wrap safely below the node title] --> B[End]\n"
	match Flowchart.parse(source) {
		Err(_) => False
		Ok(diagram) => {
			theme = Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 120, corner_radius: 1024 }
			measured = FlowTheme.sizes(diagram, theme)
			style = { font: TextMeasure.inter, size: theme.font_size, line_height: theme.line_height, wrap: Width(theme.max_label_width), align: Middle }
			metrics = TextMeasure.metrics_of(style)
			measured.nodes.all(
				|node| {
					rows = node.label.lines.len()
					painted_height = FlowDraw.height_with(rows, theme.font_size, theme.line_height)
					first_baseline = node.height / 2 - painted_height / 2 + theme.font_size
					last_baseline = first_baseline + (rows - 1).to_f64() * theme.font_size * theme.line_height
					first_baseline - metrics.ascent >= -0.00001 and last_baseline + metrics.descent <= node.height + 0.00001
				},
			) and Drawing.is_finite(FlowTheme.draw_diagram(diagram, theme))
		}
	}
}

expect {
	shapes = [Rectangle, Rounded, Stadium, Subroutine, Cylinder, Circle, DoubleCircle, Ellipse, Asymmetric, Diamond, Hexagon, LeanRight, LeanLeft, Trapezoid, InverseTrapezoid]
	diagram : Flowchart.Diagram
	diagram = { direction: Down, nodes: shapes.map_with_index(|shape, i| { id: i.to_str(), label: "A long label wraps over several rows of actual glyphs", shape, container: Root, classes: [], styles: [] }), edges: [], groups: [], classes: [] }
	[14.0, 64.0].all(
		|font_size| [0.1, 1.4].all(
			|line_height| [0.0, 12.0].all(
				|padding| {
					theme = Theme.Options.{ font_size, line_height, padding, max_label_width: 90, corner_radius: 1024 }
					measured = FlowTheme.sizes(diagram, theme)
					measured.nodes.map_with_index(|node, i| FlowThemeChecks.padded_label_inside(shapes.get(i) ?? Rectangle, node.label, theme)).all(|ok| ok)
				},
			),
		),
	)
}
