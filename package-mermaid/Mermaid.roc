import "FontInter-OFL.txt" as inter_licence_file : List(U8)
import Drawing
import FlowDraw
import FlowLayout
import FlowSize
import Flowchart
import Svg

## Turn Mermaid text into a picture or an SVG document in one call. Labels
## are measured with the metrics of the Inter typeface, as Mermaid 12 lays
## out text, so show the result with Inter available (for example as a web
## font) for text to fit its boxes exactly.
##
## Flowcharts (`flowchart` and `graph`) are supported. For other text, or
## features not interpreted yet, the problems say why; see `Flowchart`.
Mermaid := [].{

	## Read and lay out Mermaid text, giving a picture of outlines and text
	## lines that any vector renderer can paint.
	draw : Str -> [Ok(Drawing.Picture), Err(List(Flowchart.Problem))]
	draw = |text|
		match Flowchart.parse(text) {
			Ok(diagram) => Ok(Mermaid.draw_flowchart(diagram))
			Err(problems) => Err(problems)
		}

	## Read and lay out Mermaid text as a standalone SVG document whose labels
	## are set in Inter.
	svg : Str -> [Ok(Str), Err(List(Flowchart.Problem))]
	svg = |text|
		match Mermaid.draw(text) {
			# The typeface labels are measured with, as SVG and CSS name it.
			Ok(picture) => Ok(Svg.document(picture, "Inter, sans-serif"))
			Err(problems) => Err(problems)
		}

	## Lay out and draw a flowchart that has already been read.
	draw_flowchart : Flowchart.Diagram -> Drawing.Picture
	draw_flowchart = |diagram| {
		sizes = FlowSize.sizes(diagram, FlowSize.mermaid)
		geometry = FlowLayout.layout(diagram, sizes)
		FlowDraw.draw(diagram, sizes, geometry)
	}

	## The licence of the Inter font data built into this package for
	## measuring labels: the SIL Open Font License 1.1. Include it with
	## anything that redistributes that data, such as a PDF embedding it.
	font_licence : Str
	font_licence = Str.from_utf8_lossy(inter_licence_file)
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
