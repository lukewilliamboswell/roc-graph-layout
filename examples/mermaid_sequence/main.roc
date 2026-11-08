#!/usr/bin/env roc
app [main!] {
	mermaid: "../../package-mermaid/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.27.0/9yjxqdGTP4xSpSEmDazwTmRsehfRZzA19pwEKkR6fj1g.tar.zst",
}

import pf.Path
import pf.Stdout
import mermaid.Mermaid

## Render a conversation with a nested retry and approval decision.
## Run from the repository root; the example writes a standalone SVG.
main! = |_args| {
	source = Path.read_utf8!(Path.utf8("examples/mermaid_sequence/chart.mmd"))?
	match Mermaid.svg(source) {
		Err(problems) => Err(SequenceProblems(problems))
		Ok(svg) => {
			Path.write_utf8!(Path.utf8("examples/mermaid_sequence/output.svg"), svg)?
			Stdout.line!("Drew examples/mermaid_sequence/output.svg")
		}
	}
}
