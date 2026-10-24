#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import src/Script

## Build the node editor with the `roc` on PATH and run its browser tests.
##
##     blueprint run editor-e2e
##     PLAYWRIGHT_WITH_DEPS=1 blueprint run editor-e2e
##
## Installs the locked npm dependencies and Playwright's Chromium, then runs
## the geometry unit tests and the Playwright suite against the native server.
## `PLAYWRIGHT_WITH_DEPS=1` also installs Chromium's system libraries, which
## needs administrator rights.
main! = |_args| {
	directory = "examples/node_editor"
	npm = Script.command("npm")
	npm.run_in!(["ci"], directory)?
	with_deps = Script.env_or!("PLAYWRIGHT_WITH_DEPS", "")? == "1"
	Script.command("npx").run_in!(["playwright", "install"].concat(if (with_deps) ["--with-deps"] else []).concat(["chromium"]), directory)?
	npm.run_in!(["run", "build"], directory)?
	npm.run_in!(["test"], directory)
}
