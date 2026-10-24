#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import src/Archive
import src/Bundle
import src/Script

## Test an examples archive, unchanged, against the bundles it names.
##
##     blueprint run test-bundle
##     BUNDLE_PATH=dist/<hash>.tar.zst MERMAID_BUNDLE_PATH=dist/<hash>.tar.zst EXAMPLES_ARCHIVE=dist/roc-graph-layout-examples-0.2.0.zip blueprint run test-bundle
##
## Tests the layout and Mermaid bundles and the only examples archive in
## `dist` unless `BUNDLE_PATH`, `MERMAID_BUNDLE_PATH` and `EXAMPLES_ARCHIVE`
## name them. The release workflow passes the exact files it is about to
## publish, which catches packaging mistakes that checking the source tree
## cannot.
main! = |_args| {
	roc = Script.roc!()?
	bundles = Bundle.selected!("dist")?
	archive = Archive.selected!("dist")?
	Bundle.test!(roc, bundles, archive)
}
