import "FontInter-OFL.txt" as inter_licence_file : List(U8)
import Drawing
import Flowchart
import FlowTheme
import Svg
import Theme

## Turn Mermaid text into a picture or an SVG document in one call. Labels
## are measured with the metrics of the Inter typeface, as Mermaid 12 lays
## out text, so show the result with Inter available (for example as a web
## font) for text to fit its boxes exactly.
##
## Flowcharts (`flowchart` and `graph`) are supported. For other text, or
## features not interpreted yet, the problems say why; see `Flowchart`.
Mermaid := [].{

	## Override only the appearance choices you need. For example,
	## `Options.{ theme: Theme.Options.{ font_size: 16 } }` measures labels
	## at 16 pixels and gives them the corresponding space before layout.
	Options := { theme : Theme.Options ?? Theme.Options.{} }

	Problem : Flowchart.Problem

	## Read and lay out Mermaid text, giving a picture of outlines and text
	## lines that any vector renderer can paint.
	draw : Str -> [Ok(Drawing.Picture), Err(List(Flowchart.Problem))]
	draw = |text| Mermaid.draw_with(text, Options.{})

	## Draw with selected appearance options. Invalid numeric properties
	## and independent source problems are reported together.
	draw_with : Str, Options -> Try(Drawing.Picture, List(Problem))
	draw_with = |text, options| match FlowTheme.draw(text, options.theme) {
		Ok(picture) => Ok(MermaidParts.finish(picture, options.theme))
		Err(problems) => Err(problems)
	}

	## Read and lay out Mermaid text as a standalone SVG document whose labels
	## are set in Inter.
	svg : Str -> [Ok(Str), Err(List(Flowchart.Problem))]
	svg = |text| Mermaid.svg_with(text, Options.{})

	## Write standalone SVG using the same sizing and layout as `draw_with`.
	svg_with : Str, Options -> Try(Str, List(Problem))
	svg_with = |text, options|
		match Mermaid.draw_with(text, options) {
			# The typeface labels are measured with, as SVG and CSS name it.
			Ok(picture) => Ok(Svg.document(picture, "Inter, sans-serif"))
			Err(problems) => Err(problems)
		}

	## Lay out and draw a flowchart that has already been read.
	draw_flowchart : Flowchart.Diagram -> Drawing.Picture
	draw_flowchart = |diagram| {
		theme = Theme.Options.{}
		MermaidParts.finish(FlowTheme.draw_diagram(diagram, theme), theme)
	}

	## The licence of the Inter font data built into this package for
	## measuring labels: the SIL Open Font License 1.1. Include it with
	## anything that redistributes that data, such as a PDF embedding it.
	font_licence : Str
	font_licence = Str.from_utf8_lossy(inter_licence_file)
}

MermaidParts :: {}.{
	finish : Drawing.Picture, Theme.Options -> Drawing.Picture
	finish = |picture, theme| {
		if picture.items.is_empty() {
			return picture
		}
		# Account for wide strokes and an optional offset shadow in the
		# exported view, then paint a true background for dark themes too.
		margin = theme.line_width / 2
		shadow = match theme.shadow {
			NoShadow => { x: 0, y: 0 }
			Shadow(s) => { x: s.dx, y: s.dy }
		}
		left = margin + (-shadow.x).max(0)
		top = margin + (-shadow.y).max(0)
		view = { x: picture.view.x - left, y: picture.view.y - top, width: picture.view.width + left + margin + shadow.x.max(0), height: picture.view.height + top + margin + shadow.y.max(0) }
		background = Shape({ path: Drawing.rectangle(view), paint: { fill: Fill(theme.background), stroke: NoStroke } })
		{ view, items: [background].concat(picture.items) }
	}
}

expect
	match Mermaid.svg("flowchart LR\n  A[Start] --> B{Choice}\n") {
		Ok(svg) => svg.starts_with("<svg ") and svg.contains(">Start</text>") and svg.contains(">Choice</text>")
		Err(_) => False
	}

expect Mermaid.svg("sequenceDiagram\n") == Err([NotAFlowchart])

expect
	match Mermaid.draw("flowchart TD\n") {
		Ok(picture) => picture.items.is_empty()
		Err(_) => False
	}

expect Mermaid.font_licence.contains("SIL Open Font License, Version 1.1")

expect {
	options = Mermaid.Options.{ theme: Theme.Options.{ font_size: 20, line_height: 1.8, max_label_width: 90, background: Drawing.rgb(0x0F172A), node_text: Drawing.white } }
	source = "flowchart LR\n A[A long label that should wrap] --> B[Done]\n"
	match (Mermaid.draw_with(source, options), Mermaid.svg_with(source, options)) {
		(Ok(picture), Ok(svg)) => Drawing.is_finite(picture)
			and Mermaid.draw_with(source, options) == Ok(picture)
			and svg == Svg.document(picture, "Inter, sans-serif")
			and svg.contains("#0f172a") and svg.contains("font-size=\"20\"")
		_ => False
	}
}

expect
	match Mermaid.draw_with("flowchart TD\n A[unfinished\n", Mermaid.Options.{ theme: Theme.Options.{ font_size: 0, line_width: -1 } }) {
		Err(problems) => problems.len() == 3
		Ok(_) => False
	}

expect
	match Mermaid.draw("flowchart TD\n") {
		Ok(picture) => Drawing.is_finite(picture) and picture.view.width >= 0 and picture.view.height >= 0
		Err(_) => False
	}
