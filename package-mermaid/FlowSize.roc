import Flowchart
import FlowGeometry
import font.Font
import TextMeasure

## How much room each part of a flowchart needs, sized as Mermaid 12 sizes
## it with its default look and theme: node labels wrap at 120 px and every
## labelled node is at least 120 px wide inside its padding, edge labels
## wrap at 200 px, and group titles never wrap. Text is 14 px with lines
## 1.1 em apart.
##
## A node's size is its whole outline's bounding box. Edge labels and group
## titles are the size of their text; Mermaid draws an edge label on a
## background 2 px larger on every side.
FlowSize :: {}.{

	## `padding` is Mermaid's `flowchart.padding`, which some shapes use
	## around their label; `min_width` is `flowchart.minNodeWidth`, the least
	## width of a labelled node's label area; the wrapping widths are where
	## node and edge labels start a new line.
	Settings : { font : Font, font_size : F64, line_height : F64, padding : F64, min_width : F64, node_wrapping_width : F64, edge_wrapping_width : F64 }

	## Mermaid 12.2.0's defaults, measured with Inter.
	mermaid : Settings
	mermaid = { font: TextMeasure.inter, font_size: 14.0, line_height: 1.1, padding: 15.0, min_width: 120.0, node_wrapping_width: 120.0, edge_wrapping_width: 200.0 }

	sizes : Flowchart.Diagram, Settings -> FlowGeometry.Sizes
	sizes = |diagram, settings| {
		node_style = FlowSize.style(settings, Width(settings.node_wrapping_width), Middle)
		edge_style = FlowSize.style(settings, Width(settings.edge_wrapping_width), Middle)
		title_style = FlowSize.style(settings, NoWrap, Start)
		{
			nodes: diagram.nodes.map(
				|node| {
					label = TextMeasure.block(node.label, node_style)
					size = FlowSize.shape_size(node.shape, label, !node.label.is_empty(), settings)
					{ width: size.width, height: size.height, label }
				},
			),
			edge_labels: diagram.edges.map(|edge| if (edge.label.is_empty()) None else Some(TextMeasure.block(edge.label, edge_style))),
			group_titles: diagram.groups.map(|group| TextMeasure.block(group.title, title_style)),
		}
	}

	style : Settings, [Width(F64), NoWrap], [Start, Middle] -> TextMeasure.Style
	style = |settings, wrap, align| { font: settings.font, size: settings.font_size, line_height: settings.line_height, wrap, align }

	## The bounding box of a node's outline around a label of this size.
	## `labelled` is whether the node has label text at all; only labelled
	## nodes are widened to the minimum width, and circles never are.
	shape_size : Flowchart.Shape, FlowGeometry.TextBlock, Bool, Settings -> { width : F64, height : F64 }
	shape_size = |shape, label, labelled, settings| {
		p = FlowSize.finite(settings.padding)
		h = label.height
		# The label area, widened to the minimum width.
		w = if (labelled) label.width.max(FlowSize.finite(settings.min_width)) else label.width
		size = match shape {
			Rectangle => { width: w + 32.0, height: h + 24.0 }
			Rounded => { width: w + 2.0 * p, height: h + 2.0 * p }
			Stadium => FlowSize.stadium(w, h)
			Subroutine => { width: w + 44.0, height: h + 12.0 }
			Cylinder => {
				body = w + 24.0
				ry = body / 2.0 / (2.5 + body / 50.0)
				{ width: body, height: h + 24.0 + 3.0 * ry }
			}
			Circle => {
				d = 2.0 * (FlowSize.half_diagonal(label) + 16.0)
				{ width: d, height: d }
			}
			DoubleCircle => {
				d = 2.0 * (FlowSize.half_diagonal(label) + 16.0 + 12.0)
				{ width: d, height: d }
			}
			# Mermaid 12 cannot draw `(-...-)` ("No such shape: ellipse"); this is
			# the ellipse through the corners of a rounded node's box.
			Ellipse => { width: (w + 2.0 * p) * FlowSize.sqrt2, height: (h + 2.0 * p) * FlowSize.sqrt2 }
			Asymmetric => { width: w + 42.0 + (h + 24.0) / 4.0, height: h + 24.0 }
			Diamond => {
				s = w + p + h + p
				{ width: s, height: s }
			}
			Hexagon => {
				height = h + 70.0
				{ width: w + 2.0 * height / 3.5 + 32.0, height }
			}
			LeanRight | LeanLeft | Trapezoid => {
				height = h + p
				{ width: w + 2.0 * p + height, height }
			}
			InverseTrapezoid => {
				height = h + 2.0 * p
				{ width: w + 4.0 * p + height, height }
			}
		}
		{ width: FlowSize.finite(size.width), height: FlowSize.finite(size.height) }
	}

	sqrt2 : F64
	sqrt2 = (2.0).sqrt()

	half_diagonal : FlowGeometry.TextBlock -> F64
	half_diagonal = |label| (label.width * label.width + label.height * label.height).sqrt() / 2.0

	## Mermaid's stadium: round ends drawn as 50-point polylines, sized so
	## the label clears the inscribed circle of the ends. The polyline's
	## outermost points sit just inside the true round ends.
	stadium : F64, F64 -> { width : F64, height : F64 }
	stadium = |w, h| {
		height = h + 24.0
		c = (F64.pi / 98.0).cos()
		inscribed = height * c
		cap = (inscribed * inscribed - h * h).max(0.0).sqrt()
		outline = (w + height / 4.0 + 40.0).max(1.5 * height + (height - inscribed)).max(w + 40.0 + height - cap)
		{ width: outline - height * (1.0 - c), height }
	}

	finite : F64 -> F64
	finite = |value| if (F64.is_finite(value) and value > 0.0) value else 0.0
}

sized : Str -> List({ width : F64, height : F64 })
sized = |text|
	match Flowchart.parse(text) {
		Ok(diagram) => FlowSize.sizes(diagram, FlowSize.mermaid).nodes.map(|n| { width: n.width, height: n.height })
		Err(_) => []
	}

near : List({ width : F64, height : F64 }), List({ width : F64, height : F64 }) -> Bool
near = |a, b| a.len() == b.len() and a.map2(b, |x, y| (x.width - y.width).abs() < 1.0e-3 and (x.height - y.height).abs() < 1.0e-3).all(|ok| ok)

# Mermaid 12.2.0's node boxes for one-letter labels (tests/mermaid/measure/shapes-small).
expect
	near(
		sized("flowchart TD\n  e1[x] --- e2(x) --- e3([x]) --- e4[[x]] --- e5[(x)] --- e6((x)) --- e7(((x))) --- e8>x]\n  e9{x} --- f1{{x}} --- f2[/x/] --- f3[\\x\\] --- f4[/x\\] --- f5[\\x/]\n"),
		[
			{ width: 152, height: 41 },
			{ width: 150, height: 47 },
			{ width: 170.2289276123047, height: 41 },
			{ width: 164, height: 29 },
			{ width: 144, height: 81.14869689941406 },
			{ width: 50.78829574584961, height: 50.78829574584961 },
			{ width: 74.78829193115234, height: 74.78829193115234 },
			{ width: 172.25, height: 41 },
			{ width: 167, height: 167 },
			{ width: 201.7142791748047, height: 87 },
			{ width: 182, height: 32 },
			{ width: 182, height: 32 },
			{ width: 182, height: 32 },
			{ width: 227, height: 47 },
		],
	)

# Empty labels: no minimum width.
expect
	near(
		sized("flowchart TD\n  g1[\" \"] --- g3([\" \"]) --- g5[(\" \")] --- g6((\" \")) --- h1{{\" \"}} --- h5[\\\" \"/]\n"),
		[
			{ width: 32, height: 24 },
			{ width: 45.9876708984375, height: 24 },
			{ width: 24, height: 36.08053970336914 },
			{ width: 32, height: 32 },
			{ width: 72, height: 70 },
			{ width: 90, height: 30 },
		],
	)

expect
	match Flowchart.parse("flowchart LR\n  A -->|go| B\n  A --> C\n  subgraph s [Title]\n    C\n  end\n") {
		Ok(diagram) => {
			result = FlowSize.sizes(diagram, FlowSize.mermaid)
			result.nodes.len() == 3
				and result.edge_labels.len() == 2
				and result.group_titles.len() == 1
				and (
					match result.edge_labels {
						[Some(label), None] => label.lines == ["go"]
						_ => False
					}
				)
		}
		Err(_) => False
	}
