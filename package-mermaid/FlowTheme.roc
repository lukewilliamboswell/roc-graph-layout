import Drawing
import Flowchart
import FlowDraw
import FlowGeometry
import FlowLayout
import FlowSize
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
		minimum_width : F64
		minimum_width = 80
		settings = { ..FlowSize.mermaid, font_size: theme.font_size, line_height: theme.line_height, padding: theme.padding, node_wrapping_width: theme.max_label_width, edge_wrapping_width: theme.max_label_width, min_width: minimum_width.min(theme.max_label_width) }
		measured = FlowSize.sizes(diagram, settings)
		{
			..measured,
			nodes: measured.nodes.map_with_index(
				|size, i| {
					node = diagram.nodes.get(i)
					match node {
						Ok(n) => if n.shape == Rectangle {
							{ ..size, width: size.label.width.max(settings.min_width) + 2 * theme.padding, height: size.label.height + 2 * theme.padding }
						} else {
							size
						}
						Err(_) => size
					}
				},
			),
			group_titles: diagram.groups.map(|group| TextMeasure.block(group.title, { font: TextMeasure.inter, size: theme.font_size, line_height: theme.line_height, wrap: Width(theme.max_label_width), align: Middle })),
		}
	}

	draw_diagram : Flowchart.Diagram, Theme.Options -> Drawing.Picture
	draw_diagram = |diagram, theme| {
		measured = FlowTheme.sizes(diagram, theme)
		geometry = FlowLayout.layout(diagram, measured)
		paint = {
			..FlowDraw.mermaid,
			font_size: theme.font_size,
			line_height: theme.line_height,
			corner_radius: theme.corner_radius,
			background: theme.background,
			node_fill: theme.node_fill,
			node_stroke: theme.node_stroke,
			node_stroke_width: theme.line_width,
			node_text: theme.node_text,
			line: theme.line,
			line_width: theme.line_width,
			thick_line_width: theme.line_width * 1.75,
			label_background: theme.label_background,
			label_background_opacity: 1,
			label_text: theme.label_text,
			group_colors: [{ fill: theme.group_fill, stroke: theme.group_stroke }],
			group_stroke_width: theme.line_width,
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
