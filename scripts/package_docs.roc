#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	roc: "nightly-2026-11-24-ff5e544",
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
