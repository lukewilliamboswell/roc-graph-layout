#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.OsStr
import src/Examples
import src/Script

## Run the examples against the working tree and compare what they print
## with `tests/examples.json`.
##
##     blueprint run examples
##     blueprint run examples -- --update
##
## `--update` records what the examples print instead of comparing, adding a
## default case for an example that has none. Each example also rewrites its
## drawing, `examples/<dir>/output.svg`; `git diff` shows any change there.
main! = |args| {
	mode = match args.map(OsStr.display) {
		[] => Compare
		["--update"] => Update
		_ => return Script.fail!("usage: scripts/examples.roc [--update]")
	}
	Examples.run!(Script.roc!()?, { root: ".", source: Direct, spec: "tests/examples.json", mode, roc_args: |_| [] })
}
