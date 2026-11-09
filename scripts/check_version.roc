#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Env
import cli.Cmd
import cli.Stdout
import cli.Stderr
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
## compare changed releases within the same breaking-version boundary; an exact
## two-bundle content proof can establish an unchanged later patch. An increasing
## major version, or minor version within 0.x, already promises every possible
## API change. That proof still validates the previous release and bundle URLs.
##
## Only the layout package is compared. The Mermaid package, published
## beside it under the same version, is not compared.
main! = |_args| {
	version = Script.env!("RELEASE_VERSION")?
	if !Release.publishable_version(version) {
		return Script.fail!("not a publishable release version: ${version}")
	}
	match Release.breaking_suffices(version, "0.0.0") {
		Ok(_) => {}
		Err(reason) => return Script.fail!(reason)
	}
	gh = Script.command("gh")
	# The newest published final release, and the URL of its bundle.
	query = "[.[] | select((.draft or .prerelease) | not)] | first | [.tag_name] + [.assets[] | select(.name | endswith(\".tar.zst\")) | .browser_download_url] | .[]"
	metadata = Text.lines(gh.capture_utf8!(["api", "repos/${Release.repository}/releases?per_page=100", "--jq", query], ".")?)
	if metadata.is_empty() {
		return Script.info!("FIRST", "no earlier release to compare ${version} with")
	}
	previous_release = match Release.previous_release(metadata) {
		Ok(previous) => previous
		Err(reason) => return Script.fail!(reason)
	}
	previous = match previous_release.bundles {
		[only] => only
		_ => layout_url!(gh, previous_release.version)?
	}
	sufficient = match Release.breaking_suffices(version, previous_release.version) {
		Ok(value) => value
		Err(reason) => return Script.fail!(reason)
	}
	if sufficient {
		return Script.info!("BREAKING VERSION", "${version} crosses the breaking-version boundary of ${previous_release.version}; no public API comparison is required")
	}

	# A packaging-only later patch can prove both bundle contents directly.
	# Integrity errors stop the gate; actual source changes still need roc bump.
	if Release.is_final(version) {
		identity = Cmd.new("python3").args(["scripts/check_bundle_identity.py", OsStr.from_str(version), OsStr.from_str(previous_release.version), OsStr.from_str(Script.env_or!("OUTPUT_DIR", "dist")?)]).run!()?
		Stdout.write_bytes!(identity.stdout_bytes)?
		Stderr.write_bytes!(identity.stderr_bytes)?
		match identity.status {
			Exited(0) => return Script.info!("IDENTICAL BUNDLES", "fresh layout bytes and Mermaid dependency rebinding prove unchanged package contents")
			Exited(3) => {}
			_ => return Script.fail!("bundle identity integrity validation failed")
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
