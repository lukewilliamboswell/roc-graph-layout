#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Path
import src/Preview
import src/Script
import src/Site

## Build the documentation site and preview it locally.
##
##     blueprint run serve
##     SITE_PORT=8000 blueprint run serve
##
## Takes the same `SITE_OUTPUT`, `SITE_VERSION` and `FETCH_RELEASE_DOCS` as
## `site.roc`, and serves on a free port unless `SITE_PORT` names one.
main! = |_args| {
	roc = Script.roc!()?
	output = Path.absolute!(Path.utf8(Script.env_or!("SITE_OUTPUT", "dist/site")?))?
	version = Script.env_or!("SITE_VERSION", "main")?
	releases = match Script.env_or!("FETCH_RELEASE_DOCS", "")? {
		"" | "0" => SkipReleaseDocs
		_ => FetchReleaseDocs
	}
	requested = Script.env_or!("SITE_PORT", "0")?
	port = match U16.from_str(requested) {
		Ok(value) => value
		Err(_) => return Script.fail!("SITE_PORT must be between 0 and 65535, not ${requested}")
	}
	Site.assemble!(roc, output, version, releases)?
	Preview.serve!(output, port)
}
