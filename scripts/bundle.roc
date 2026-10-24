#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Path
import src/Bundle
import src/Script

## Bundle the working-tree packages for a release.
##
##     RELEASE_VERSION=0.2.0 blueprint run bundle
##
## Writes two archives to `dist`, or to the directory named by `OUTPUT_DIR`:
## the layout package, and the Mermaid package, which depends on the layout
## bundle by its URL in the release `version`.
main! = |_args| {
	# The bundles hold the packages being developed, so the floating compiler
	# builds them. The tooling compiler only runs this script.
	roc = Script.roc!()?
	version = Script.env!("RELEASE_VERSION")?
	output_dir = Script.env_or!("OUTPUT_DIR", "dist")?
	_ = Bundle.build!(roc, version, Path.utf8(output_dir))?
	Ok({})
}
