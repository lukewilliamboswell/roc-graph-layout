#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Path
import src/Script
import src/Site

## Build the documentation site: the guides and the API reference.
##
##     blueprint run site
##     SITE_VERSION=0.2.0 FETCH_RELEASE_DOCS=1 blueprint run site
##
## Writes to `dist/site`, or to the directory named by `SITE_OUTPUT`,
## replacing what is there. `SITE_VERSION` names the working tree's API
## reference, `main` unless set. With `FETCH_RELEASE_DOCS=1` the API reference
## of every earlier release is restored beside it, which needs `gh`.
main! = |_args| {
	roc = Script.roc!()?
	output = Path.absolute!(Path.utf8(Script.env_or!("SITE_OUTPUT", "dist/site")?))?
	version = Script.env_or!("SITE_VERSION", "main")?
	releases = match Script.env_or!("FETCH_RELEASE_DOCS", "")? {
		"" | "0" => SkipReleaseDocs
		_ => FetchReleaseDocs
	}
	Site.assemble!(roc, output, version, releases)
}
