import "FontInter-OFL.txt" as inter_licence_file : List(U8)
import Drawing
import DiagramView
import ClassDiagram
import EntityRelationship
import Flowchart
import FlowTheme
import Sequence
import StateDiagram
import Svg
import Theme

## Turn Mermaid text into a picture or an SVG document in one call. Labels
## are measured with the metrics of the Inter typeface, as Mermaid 12 lays
## out text, so show the result with Inter available (for example as a web
## font) for text to fit its boxes exactly.
##
## Supports `flowchart`/`graph`, `sequenceDiagram`, `erDiagram`,
## `classDiagram`, and `stateDiagram`/`stateDiagram-v2`. Each family module
## describes its supported syntax and exposes its source-ordered model.
## Unsupported features are reported explicitly. The layout package stays
## independent of syntax, text measurement and rendering.
Mermaid := [].{

	## Override only the appearance choices you need. For example,
	## `Options.{ theme: Theme.Options.{ font_size: 16 } }` measures labels
	## at 16 pixels and gives them the corresponding space before layout.
	Options := { theme : Theme.Options ?? Theme.Options.{} }

	## Source problems and invalid numeric theme properties. `Syntax` names
	## the text near an error; `Unsupported` explains an unsupported feature.
	Problem : [NotAFlowchart, Syntax({ near : Str }), Unsupported(Str), InvalidTheme(Str), TooManyEdges, MissingLinkStyleEdge(Str), UnnamedGroup]

	## Read and lay out Mermaid text, giving a picture of outlines and text
	## lines that any vector renderer can paint.
	draw : Str -> [Ok(Drawing.Picture), Err(List(Flowchart.Problem))]
	draw = |text| Mermaid.draw_with(text, Options.{})

	## Draw with selected appearance options. Invalid numeric properties
	## and independent source problems are reported together.
	draw_with : Str, Options -> Try(Drawing.Picture, List(Problem))
	draw_with = |text, options| {
		header = MermaidParts.header(text)
		result = match header {
			"sequenceDiagram" => Sequence.draw(text, options.theme)
			"erDiagram" => EntityRelationship.draw(text, options.theme)
			"classDiagram" => ClassDiagram.draw(text, options.theme)
			"stateDiagram" | "stateDiagram-v2" => StateDiagram.draw(text, options.theme)
			_ => if header == "flowchart" or header == "graph" or header.starts_with("flowchart ") or header.starts_with("graph ") or header.starts_with("%%{") or header == "---" {
				FlowTheme.draw(text, options.theme)
			} else {
				Err([Unsupported("diagram type: ${header}")].concat(Theme.validate(options.theme)))
			}
		}
		match result {
			Ok(picture) => Ok(MermaidParts.finish(picture, options.theme))
			Err(problems) => Err(problems)
		}
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
	header : Str -> Str
	header = |source| {
		for line in source.split_on("\n") {
			clean = line.trim()
			if !clean.is_empty() and (!clean.starts_with("%%") or clean.starts_with("%%{")) {
				declaration = (clean.split_on("%%").first() ?? clean).trim()
				return (declaration.split_on(";").first() ?? declaration).trim()
			}
		}
		""
	}

	finish : Drawing.Picture, Theme.Options -> Drawing.Picture
	finish = DiagramView.finish
}

expect
	match Mermaid.svg("flowchart LR\n  A[Start] --> B{Choice}\n") {
		Ok(svg) => svg.starts_with("<svg ") and svg.contains(">Start</text>") and svg.contains(">Choice</text>")
		Err(_) => False
	}

expect Mermaid.svg("pie\n") == Err([Unsupported("diagram type: pie")])

expect
	match Mermaid.draw("flowchart TD\n") {
		Ok(picture) => picture.items.is_empty()
		Err(_) => False
	}

expect [
	"sequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Reply\n",
	"erDiagram\nCUSTOMER ||--o{ ORDER : places\n",
	"classDiagram\nAnimal <|-- Duck\nDuck : +swim()\n",
	"stateDiagram-v2\n[*] --> Idle\nIdle --> Working : start\nWorking --> [*]\n",
].all(
	|source| match Mermaid.draw(source) {
		Ok(picture) => Drawing.is_finite(picture) and !picture.items.is_empty()
			and Mermaid.draw(source) == Ok(picture)
			and Mermaid.svg(source) == Ok(Svg.document(picture, "Inter, sans-serif"))
		Err(_) => False
	},
)

expect Mermaid.font_licence.contains("SIL Open Font License, Version 1.1")

## regression: family declarations may end with a Mermaid comment.
expect [
	"sequenceDiagram %% conversation\nA->>B: Hi\n",
	"erDiagram %% database\nA ||--o{ B : owns\n",
	"classDiagram %% model\nA <|-- B\n",
	"stateDiagram-v2 %% lifecycle\n[*] --> Idle\n",
].all(
	|source| match Mermaid.draw(source) {
		Ok(picture) => Drawing.is_finite(picture) and !picture.items.is_empty()
		Err(_) => False
	},
)

## regression: explicit thick outlines must not be clipped by the SVG view.
expect
	match Mermaid.draw("flowchart TD\nA[Hello]\nstyle A stroke-width:100\n") {
		Ok(picture) => picture.view.x <= -38 and picture.view.y <= -38
			and picture.view.x + picture.view.width >= 166
			and picture.view.y + picture.view.height >= 103
		Err(_) => False
	}

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
