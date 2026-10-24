#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Env
import cli.OsStr
import cli.Path
import src/Bundle
import src/Release
import src/Script
import src/Text

## Check that a release version promises what the change to the public API
## of the layout package needs, with `roc bump` against the latest published
## release.
##
##     RELEASE_VERSION=0.2.0 blueprint run check-version
##
## Needs `gh` to be authenticated, for example through `GH_TOKEN`. A version
## that understates a breaking change fails. `roc bump` must be able to
## compile the previous release; when a newer compiler no longer can, set
## `SKIP_API_COMPARISON=1` to release anyway and say so in the notes.
##
## Only the layout package is compared. The Mermaid package, published
## beside it under the same version, is not compared.
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
	previous = match Text.lines(gh.capture_utf8!(["api", "repos/${Release.repository}/releases?per_page=100", "--jq", query], ".")?) {
		[] => return Script.info!("FIRST", "no earlier release to compare ${version} with")
		# Releases before the Mermaid package published the layout package alone.
		[tag, only] => {
			if Release.version_of_bundle_url(only) != Ok(tag) {
				return Script.fail!("release ${tag} has an unexpected bundle URL: ${only}")
			}
			only
		}
		[tag, .. as bundles] => {
			if bundles.any(|bundle| Release.version_of_bundle_url(bundle) != Ok(tag)) {
				return Script.fail!("release ${tag} has an unexpected bundle URL among ${Str.join_with(bundles, ", ")}")
			}
			layout_url!(gh, tag)?
		}
	}
	Script.info!("COMPARE", "the layout package with ${previous}; the Mermaid package is not compared")?
	# A release candidate is held to what its final release must promise.
	Script.roc!()?.run!(["bump", "--old", OsStr.from_str(previous), "--expect", OsStr.from_str(Release.final_of(version)), "package/main.roc"])
}

# The URL of the layout bundle of the release `tag`, which publishes several:
# they are downloaded and told apart by what they hold.
layout_url! = |gh, tag|
	Env.with_temp_dir!(
		|temporary| {
			_ = gh.capture!(["release", "download", OsStr.from_str(tag), "--repo", OsStr.from_str(Release.repository), "--pattern", "*.tar.zst", "--dir", Path.to_os_str(temporary)], ".", [])?
			bundles = Bundle.classify!(Path.list!(temporary)?, "release ${tag}")?
			match Release.bundle_url(tag, Script.file_name(bundles.layout)?) {
				Ok(url) => Ok(url)
				Err(_) => Script.fail!("release ${tag} has an unexpected layout bundle: ${Path.display(bundles.layout)}")
			}
		},
	)
