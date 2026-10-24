#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Env
import cli.Path
import src/DocsArchive
import src/Script
import src/Site

## Build the documentation attached to a release: the API reference archive
## and the guide as a PDF.
##
##     RELEASE_VERSION=0.2.0 blueprint run package-docs
##
## Writes `roc-graph-layout-docs-<version>.zip` and `roc-graph-layout-<version>.pdf`
## to `dist`, or to the directory named by `OUTPUT_DIR`. The site restores the
## archive for later releases.
main! = |_args| {
	roc = Script.roc!()?
	version = Script.env!("RELEASE_VERSION")?
	output_dir = Path.utf8(Script.env_or!("OUTPUT_DIR", "dist")?)
	Env.with_temp_dir!(
		|temporary| {
			Site.docs!(roc, Path.join(temporary, version))?
			_ = DocsArchive.pack!(temporary, version, output_dir)?
			_ = Site.manual!(version, output_dir)?
			Ok({})
		},
	)
}
