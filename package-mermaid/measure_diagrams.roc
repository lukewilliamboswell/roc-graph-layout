app [main!] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	layout: "../package/main.roc",
	pf: platform "../benchmarks/platform/main.roc",
}

import pf.Measure
import pf.Stdout
import Flowchart
import FlowDraw
import FlowLayout
import FlowSize
import FlowTheme
import Theme

## Native allocation and time controls for Mermaid drawing. Source
## generation is outside measurement. Run with `draw|themed|parse|zero SIZE`.
main! = |args| {
	# The telemetry platform includes the executable as argument zero.
	operation = args.get(1) ?? "draw"
	n = U64.from_str(args.get(2) ?? "12") ?? 12
	var $source = "flowchart TD\n"
	for i in 0..<n {
		$source = $source.concat("N${i.to_str()}[A long label for service ${i.to_str()} with several descriptive words]\n")
		if i > 0 {
			$source = $source.concat("N${(i - 1).to_str()} -->|A labelled dependency| N${i.to_str()}\n")
		}
		if i > 2 {
			$source = $source.concat("N${(i - 3).to_str()} --> N${i.to_str()}\n")
		}
	}
	source = $source
	_ = Measure.start!({})
	observation = if operation == "zero" {
		source.to_utf8().len()
	} else if operation == "themed" {
		match FlowTheme.draw(source, Theme.Options.{}) {
			Ok(picture) => picture.items.len()
			Err(problems) => problems.len()
		}
	} else {
		match Flowchart.parse(source) {
			Err(problems) => problems.len()
			Ok(diagram) => if operation == "parse" {
				diagram.nodes.len() + diagram.edges.len()
			} else {
				sizes = FlowSize.sizes(diagram, FlowSize.mermaid)
				picture = FlowDraw.draw(diagram, sizes, FlowLayout.layout(diagram, sizes))
				picture.items.len()
			}
		}
	}
	measurement = Measure.finish!(observation)
	Stdout.line!("${measurement}}")
}
