app [main!] { pf: platform "platform/main.roc" }

import pf.Measure
import pf.Stdout

# Native controls for separating platform entry and measurement from layout.
main! = |args| {
	match args.get(1) ?? "entry" {
		"entry" => Stdout.line!(args.len().to_str())
		"measure" => {
			_ = Measure.start!({})
			Stdout.line!(Measure.finish!(args.len()))
		}
		_ => Err(Exit(2))
	}
}
