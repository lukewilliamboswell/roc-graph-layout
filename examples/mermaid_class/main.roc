#!/usr/bin/env roc
app [main!] {
	mermaid: "../../package-mermaid/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}
import pf.Path
import pf.Stdout
import mermaid.Mermaid
import mermaid.Theme
import "diagram.mmd" as source : Str

## Render the Mermaid source next to this example through the public API.
main! = |_args| match Mermaid.svg_with(source, Mermaid.Options.{ theme: Theme.Options.{} }) {
	Err(problems) => Err(DiagramProblems(problems))
	Ok(svg) => {
		output = Path.utf8("examples/mermaid_class/output.svg")
		Path.write_utf8!(output, svg)?
		Stdout.line!("Drew Mermaid class diagram -> ${Path.display(output)}")
	}
}
