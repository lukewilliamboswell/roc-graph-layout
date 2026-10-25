#!/usr/bin/env roc
app [main!] {
	mermaid: "../../package-mermaid/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import mermaid.Mermaid

## A Mermaid flowchart turned into a standalone SVG document with one call.
## `Mermaid.svg` reads the text, sizes each label with the metrics of the
## Inter typeface, lays the chart out and draws it. The document names Inter
## as its font, so view it where Inter is available for labels to fit exactly.
##
##     roc examples/mermaid_svg/main.roc [chart.mmd]
##
## Draws the flowchart in the file given, or the one below without one.
flowchart =
	\\flowchart LR
	\\  request([Pull request]) --> checks{Checks pass?}
	\\  checks -->|yes| review[Code review]
	\\  checks -->|no| fix[Fix and push]
	\\  fix --> checks
	\\  review --> merge[(Main branch)]

main! : List(_) => Try({}, _)
main! = |args| {
	text = match args {
		[file] => Path.read_utf8!(Path.utf8(OsStr.display(file)))?
		_ => flowchart
	}
	match Mermaid.svg(text) {
		Err(problems) => Err(MermaidProblems(problems))
		Ok(svg) => {
			output = Path.utf8("examples/mermaid_svg/output.svg")
			output.write_utf8!(svg)?
			Stdout.line!("Drew a Mermaid flowchart -> ${Path.display(output)}")
		}
	}
}
