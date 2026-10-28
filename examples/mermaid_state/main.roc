#!/usr/bin/env roc
app [main!] {
	mermaid: "../../package-mermaid/main.roc",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import mermaid.StateDiagram
import mermaid.Svg
import mermaid.Theme

import "lifecycle.mmd" as source : Str

## State syntax, composite groups and state-specific geometry through the
## public API and the family defaults. Shared record properties allow
## callers to override only the appearance settings they want to change.
main! = |args| {
	text = match args {
		[file] => Path.read_utf8!(Path.utf8(OsStr.display(file)))?
		_ => source
	}
	picture = match StateDiagram.draw(text, Theme.Options.{}) {
		Ok(value) => value
		Err(problems) => return Err(StateProblems(problems))
	}
	Path.write_utf8!(Path.utf8("examples/mermaid_state/output.svg"), Svg.document(picture, "Inter, sans-serif"))?
	Stdout.line!("Drew a Mermaid state lifecycle -> examples/mermaid_state/output.svg")
}
