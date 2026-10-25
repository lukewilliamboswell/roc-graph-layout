#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Path
import src/Archive
import src/Bundle
import src/Script

## Build the examples archive attached to a release.
##
##     RELEASE_VERSION=0.2.0 blueprint run package-examples
##
## Writes `roc-graph-layout-examples-<version>.zip` to `dist`, or to the
## directory named by `OUTPUT_DIR`. The archived copies depend on the release
## URLs of the layout and Mermaid bundles in that directory, or of the ones
## `BUNDLE_PATH` and `MERMAID_BUNDLE_PATH` name. The examples in the
## repository are not changed.
main! = |_args| {
	version = Script.env!("RELEASE_VERSION")?
	output_dir = Path.utf8(Script.env_or!("OUTPUT_DIR", "dist")?)
	urls = Bundle.urls!(Bundle.selected!(output_dir)?, version)?
	_ = Archive.pack!(version, urls, output_dir)?
	Ok({})
}
