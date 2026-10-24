#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.OsStr
import src/Release
import src/Script
import src/Text

## Check that a release version promises what the change to the public API
## needs, with `roc bump` against the latest published release.
##
##     RELEASE_VERSION=0.2.0 blueprint run check-version
##
## Needs `gh` to be authenticated, for example through `GH_TOKEN`. A version
## that understates a breaking change fails. `roc bump` must be able to
## compile the previous release; when a newer compiler no longer can, set
## `SKIP_API_COMPARISON=1` to release anyway and say so in the notes.
main! = |_args| {
	version = Script.env!("RELEASE_VERSION")?
	if !Release.publishable_version(version) {
		return Script.fail!("not a publishable release version: ${version}")
	}
	if Script.env_or!("SKIP_API_COMPARISON", "")? == "1" {
		return Script.info!("SKIP", "the public API is not compared with the previous release")
	}
	gh = Script.command("gh")
	# The newest published final release, and the URL of its bundle.
	query = "[.[] | select((.draft or .prerelease) | not)] | first | [.tag_name] + [.assets[] | select(.name | endswith(\".tar.zst\")) | .browser_download_url] | .[]"
	match Text.lines(gh.capture_utf8!(["api", "repos/${Release.repository}/releases?per_page=100", "--jq", query], ".")?) {
		[] => Script.info!("FIRST", "no earlier release to compare ${version} with")
		[tag, url] => {
			if Release.version_of_bundle_url(url) != Ok(tag) {
				return Script.fail!("release ${tag} has an unexpected bundle URL: ${url}")
			}
			Script.roc!()?.run!(["bump", "--old", OsStr.from_str(url), "--expect", OsStr.from_str(version), "package/main.roc"])
		}
		found => Script.fail!("the latest release must have exactly one bundle, not ${(found.len() - 1).to_str()}")
	}
}
