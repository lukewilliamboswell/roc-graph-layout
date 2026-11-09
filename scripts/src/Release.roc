import Text

## Names and URLs of what a roc-graph-layout release publishes.
Release := [].{

	## The repository that publishes releases, in owner/name form.
	repository : Str
	repository = "lukewilliamboswell/roc-graph-layout"

	## The package name used in asset names.
	name : Str
	name = "roc-graph-layout"

	## The shorthand applications give the layout package in their header.
	shorthand : Str
	shorthand = "layout"

	## The shorthand applications give the Mermaid package in their header.
	## The Mermaid package itself depends on the layout package as `layout`.
	mermaid_shorthand : Str
	mermaid_shorthand = "mermaid"

	## The bundle URLs of one release: its layout package, and its Mermaid
	## package, which depends on that layout package.
	Urls : { layout : Str, mermaid : Str }

	## The address the documentation site is served from.
	site : Str
	site = "https://lukewilliamboswell.github.io/roc-graph-layout"

	## The path the site is served under, which `roc docs` needs to link
	## between pages.
	site_base_path : Str
	site_base_path = "/roc-graph-layout"

	## Whether `value` is a release version: `x.y.z`, optionally with a
	## `-prerelease` suffix.
	valid_version : Str -> Bool
	valid_version = |value|
		match Str.split_first(value, "-") {
			Ok({ before, after }) => core_version(before) and Text.is_plain(after, ".-")
			Err(_) => core_version(value)
		}

	## Whether `version` is a final release, which the site leads with: exactly `x.y.z`.
	is_final : Str -> Bool
	is_final = |version| core_version(version)

	## The final release a version leads to: `version` without its
	## `-prerelease` suffix. A release candidate promises what its final
	## release will, and `roc bump` reads only `x.y.z`.
	final_of : Str -> Str
	final_of = |version|
		match Str.split_first(version, "-") {
			Ok({ before, .. }) => before
			Err(_) => version
		}

	## Whether `version` can be in a package URL. Roc reads 0.0.0 there as "no
	## version" and rejects the URL, so the lowest usable version is 0.0.1.
	publishable_version : Str -> Bool
	publishable_version = |version| Release.valid_version(version) and version != "0.0.0" and !version.starts_with("0.0.0-")

	## Crossing a breaking-version boundary satisfies every possible API-change
	## lower bound: major after 1.0, minor within 0.x. Malformed metadata never
	## proves a bump, and releases within a boundary still need API comparison.
	breaking_suffices : Str, Str -> Try(Bool, Str)
	breaking_suffices = |requested, previous| {
		if !Release.publishable_version(requested) or !Release.is_final(previous) {
			return Err("requested and latest-final versions must be semantic versions")
		}
		for version in [requested, previous] {
			if !Release.final_of(version).split_on(".").all(|part| part == "0" or !part.starts_with("0")) {
				return Err("version components must not contain leading zeroes")
			}
		}
		match requested.split_first("-") {
			Ok({ after, .. }) => if !after.split_on(".").all(|part| !part.is_empty() and (!Text.is_digits(part) or part == "0" or !part.starts_with("0"))) {
				return Err("invalid prerelease identifiers")
			}
			Err(_) => {}
		}
		next = Release.final_of(requested).split_on(".").map_try(|part| U64.from_str(part).map_err(|_| "requested version component exceeds the supported integer range"))?
		old = previous.split_on(".").map_try(|part| U64.from_str(part).map_err(|_| "latest-final version component exceeds the supported integer range"))?
		match (next, old) {
			([next_major, next_minor, _], [old_major, old_minor, _]) => Ok(next_major > old_major or (old_major == 0 and next_major == 0 and next_minor > old_minor))
			_ => Err("requested and latest-final versions must have three components")
		}
	}

	## Validate release metadata before a version boundary can satisfy API checking.
	previous_release : List(Str) -> Try({ version : Str, bundles : List(Str) }, Str)
	previous_release = |metadata|
		match metadata {
			[version, .. as bundles] if !bundles.is_empty() => {
				_ = Release.breaking_suffices("1.0.0", version)?
				if !bundles.all(|bundle| Release.version_of_bundle_url(bundle) == Ok(version)) {
					return Err("previous release bundles must belong to this repository and its exact release version")
				}
				Ok({ version, bundles })
			}
			_ => Err("previous release must name a final version and at least one bundle")
		}

	## The version a pull request builds and tests its release under. It is
	## never published.
	dry_run_version : Str
	dry_run_version = "0.0.1-dry-run"

	## A hash-named archive, optionally prefixed with its package namespace.
	valid_bundle_file : Str -> Bool
	valid_bundle_file = |value| Release.bundle_hash_file(value).is_ok()

	## The hash-only filename, accepting old release names as well as the two
	## named assets. The filename prefix is part of Roc's package identity.
	bundle_hash_file : Str -> Try(Str, [InvalidBundleFile(Str)])
	bundle_hash_file = |value| {
		stem = value.drop_suffix(".tar.zst")
		hash = if stem.starts_with("layout-") {
			stem.drop_prefix("layout-")
		} else if stem.starts_with("mermaid-") {
			stem.drop_prefix("mermaid-")
		} else {
			stem
		}
		if value.ends_with(".tar.zst") and Text.is_alphanumeric(hash) {
			Ok("${hash}.tar.zst")
		} else {
			Err(InvalidBundleFile(value))
		}
	}

	## Give each package its own versioned URL identity in the same release.
	bundle_asset_name : [Layout, Mermaid], Str -> Try(Str, [InvalidBundleFile(Str)])
	bundle_asset_name = |kind, value| {
		hash_file = Release.bundle_hash_file(value)?
		prefix = match kind {
			Layout => "layout"
			Mermaid => "mermaid"
		}
		Ok("${prefix}-${hash_file}")
	}

	## The immutable URL of a bundle attached to the release `version`.
	bundle_url : Str, Str -> Try(Str, [InvalidVersion(Str), InvalidBundleFile(Str)])
	bundle_url = |version, bundle_file|
		if !Release.valid_version(version) {
			Err(InvalidVersion(version))
		} else if !Release.valid_bundle_file(bundle_file) {
			Err(InvalidBundleFile(bundle_file))
		} else {
			Ok("https://github.com/${Release.repository}/releases/download/${version}/${bundle_file}")
		}

	## The release version a bundle URL belongs to, if it is one of this
	## repository's immutable release bundle URLs.
	version_of_bundle_url : Str -> Try(Str, [NotAReleaseBundle(Str)])
	version_of_bundle_url = |url|
		match Str.split_on(url.drop_prefix("https://github.com/${Release.repository}/releases/download/"), "/") {
			[version, bundle_file] if Release.bundle_url(version, bundle_file) == Ok(url) => Ok(version)
			_ => Err(NotAReleaseBundle(url))
		}

	## The single top-level directory of the examples archive.
	examples_root : Str -> Str
	examples_root = |version| "${Release.name}-examples-${version}"

	## The examples archive attached to the release `version`.
	examples_archive : Str -> Str
	examples_archive = |version| "${Release.examples_root(version)}.zip"

	## Whether `entry` may appear in the examples archive whose top-level
	## directory is `root`: the README, the case specification, or a Roc or
	## Mermaid source file directly inside one example directory.
	valid_examples_entry : Str, Str -> Bool
	valid_examples_entry = |root, entry|
		if entry == "${root}/README.md" or entry == "${root}/spec.json" {
			Bool.True
		} else if entry.starts_with("${root}/examples/") {
			match Str.split_on(entry.drop_prefix("${root}/examples/"), "/") {
				[directory, ""] => Text.is_plain(directory, "_-")
				[directory, file] => Text.is_plain(directory, "_-") and ((file.ends_with(".roc") and Text.is_plain(file.drop_suffix(".roc"), "_-"))
					or (file.ends_with(".mmd") and Text.is_plain(file.drop_suffix(".mmd"), "_-")))
				[""] => Bool.True
				_ => Bool.False
			}
		} else {
			entry == "${root}/"
		}

	## The documentation archive attached to the release `version`.
	docs_archive : Str -> Str
	docs_archive = |version| "${Release.name}-docs-${version}.zip"

	## Pick the documentation archive out of the asset names of the release
	## `version`. Release 0.1.0 attached `docs.tar.gz` instead of a `.zip`.
	find_docs_archive : Str, List(Str) -> [Zip(Str), LegacyTarball(Str), Missing]
	find_docs_archive = |version, assets|
		if assets.contains(Release.docs_archive(version)) {
			Zip(Release.docs_archive(version))
		} else if assets.contains("docs.tar.gz") {
			LegacyTarball("docs.tar.gz")
		} else {
			Missing
		}

	## Whether `entry` may appear in the documentation archive of `version`:
	## a path beneath the `version` directory that cannot escape it.
	valid_docs_entry : Str, Str -> Bool
	valid_docs_entry = |version, entry|
		match Str.split_on(entry.drop_suffix("/"), "/") {
			[first, .. as rest] => first == version and !entry.contains("\\") and rest.all(|segment| segment != "" and segment != "." and segment != "..")
			[] => Bool.False
		}

	## Order `x.y.z` versions from newest to oldest, comparing numbers, not text.
	newest_first : List(Str) -> List(Str)
	newest_first = |versions|
		List.sort_with(versions.map(|version| (numbers(version), version)), |(left, _), (right, _)| compare_numbers(right, left))
			.map(|(_, version)| version)

	## The README at the top of the examples archive.
	examples_readme : Str, Urls -> Str
	examples_readme = |version, urls|
		Str.join_with(
			[
				"# ${Release.name} ${version} examples",
				"",
				"These are the ${Release.name} examples as they were when ${version} was released.",
				"Each application depends on that release's packages, the layout package",
				"",
				"    ${Release.shorthand}: \"${urls.layout}\"",
				"",
				"or the Mermaid package, which depends on the layout package itself:",
				"",
				"    ${Release.mermaid_shorthand}: \"${urls.mermaid}\"",
				"",
				"Install the Roc compiler named in the release notes, then run an example",
				"from this directory; it writes its drawing beside its source:",
				"",
				"    roc examples/org_chart/main.roc",
				"",
				"`spec.json` records what each example printed when ${version} was released.",
				"",
				"Release notes: https://github.com/${Release.repository}/releases/tag/${version}",
				"",
			],
			"\n",
		)
}

numbers = |version| {
	base = match Str.split_first(version, "-") {
		Ok({ before, .. }) => before
		Err(_) => version
	}
	Str.split_on(base, ".").map(|part| U64.from_str(part).ok_or(0))
}

compare_numbers = |left, right|
	match (left, right) {
		([a, .. as left_rest], [b, .. as right_rest]) =>
			if (a < b) Before else if (a > b) After else compare_numbers(left_rest, right_rest)
		([], []) => Same
		([], _) => Before
		(_, []) => After
	}

core_version = |value|
	match Str.split_on(value, ".") {
		[major, minor, patch] => Text.is_digits(major) and Text.is_digits(minor) and Text.is_digits(patch)
		_ => Bool.False
	}

url = "https://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.2.0/Abc123.tar.zst"

root = "roc-graph-layout-examples-0.2.0"

expect Release.valid_version("0.2.0") and Release.valid_version("1.0.0-rc.1") and Release.valid_version(Release.dry_run_version)
expect !Release.valid_version("0.2") and !Release.valid_version("v0.2.0") and !Release.valid_version("0.2.0-") and !Release.valid_version("0.2.0/x")
expect Release.is_final("0.2.0") and !Release.is_final("1.0.0-rc.1")
expect Release.final_of("0.3.0-rc1") == "0.3.0" and Release.final_of("1.0.0-rc.1") == "1.0.0" and Release.final_of("0.2.0") == "0.2.0"
expect Release.publishable_version("0.0.1-dry-run") and !Release.publishable_version("0.0.0") and !Release.publishable_version("0.0.0-rc1")
expect Release.valid_bundle_file("Abc123.tar.zst") and !Release.valid_bundle_file("../Abc123.tar.zst") and !Release.valid_bundle_file(".tar.zst")
expect Release.bundle_asset_name(Layout, "Abc123.tar.zst") == Ok("layout-Abc123.tar.zst")
expect Release.bundle_asset_name(Mermaid, "Abc123.tar.zst") == Ok("mermaid-Abc123.tar.zst")
expect Release.valid_bundle_file("layout-Abc123.tar.zst") and Release.valid_bundle_file("mermaid-Abc123.tar.zst")
expect !Release.valid_bundle_file("layout-.tar.zst") and !Release.valid_bundle_file("layout-../Abc123.tar.zst") and !Release.valid_bundle_file("layout-mermaid-Abc123.tar.zst")
expect Release.bundle_url("0.2.0", "Abc123.tar.zst") == Ok(url)
expect Release.bundle_url("latest", "Abc123.tar.zst") == Err(InvalidVersion("latest"))
expect Release.bundle_url("0.2.0", "a/b.tar.zst") == Err(InvalidBundleFile("a/b.tar.zst"))
expect Release.version_of_bundle_url(url) == Ok("0.2.0")
expect Release.version_of_bundle_url("http://127.0.0.1:8000/Abc123.tar.zst").is_err() and Release.version_of_bundle_url("../../package/main.roc").is_err()
expect Release.examples_archive("0.2.0") == "roc-graph-layout-examples-0.2.0.zip"
expect Release.valid_examples_entry(root, "${root}/README.md") and Release.valid_examples_entry(root, "${root}/spec.json")
expect Release.valid_examples_entry(root, "${root}/examples/org_chart/main.roc") and Release.valid_examples_entry(root, "${root}/examples/svg/Svg.roc")
expect Release.valid_examples_entry(root, "${root}/examples/svg/") and Release.valid_examples_entry(root, "${root}/examples/")
expect !Release.valid_examples_entry(root, "${root}/examples/org_chart/output.svg")
expect Release.valid_examples_entry(root, "${root}/examples/mermaid_sequence/chart.mmd")
expect !Release.valid_examples_entry(root, "${root}/examples/mermaid_sequence/../chart.mmd") and !Release.valid_examples_entry(root, "${root}/examples/mermaid_sequence/chart.mmd.exe")
expect !Release.valid_examples_entry(root, "${root}/examples/../escape/main.roc") and !Release.valid_examples_entry(root, "${root}/examples/a/b/main.roc")
expect !Release.valid_examples_entry(root, "/etc/passwd") and !Release.valid_examples_entry(root, "other/examples/svg/Svg.roc")
expect Release.find_docs_archive("0.2.0", ["Abc123.tar.zst", "roc-graph-layout-docs-0.2.0.zip"]) == Zip("roc-graph-layout-docs-0.2.0.zip")
expect Release.find_docs_archive("0.1.0", ["Abc123.tar.zst", "docs.tar.gz"]) == LegacyTarball("docs.tar.gz")
expect Release.find_docs_archive("0.1.0", ["Abc123.tar.zst"]) == Missing
expect Release.valid_docs_entry("0.2.0", "0.2.0/index.html") and Release.valid_docs_entry("0.2.0", "0.2.0/")
expect !Release.valid_docs_entry("0.2.0", "../escape") and !Release.valid_docs_entry("0.2.0", "0.2.0/../../escape") and !Release.valid_docs_entry("0.2.0", "0.1.0/index.html")
expect Release.newest_first(["0.9.0", "0.13.1", "0.10.0", "0.13.0"]) == ["0.13.1", "0.13.0", "0.10.0", "0.9.0"]
expect Release.examples_readme("0.2.0", { layout: url, mermaid: "M" }).contains("    layout: \"${url}\"\n")
expect Release.examples_readme("0.2.0", { layout: url, mermaid: "M" }).contains("    mermaid: \"M\"\n")

expect Release.breaking_suffices("4.0.0", "3.0.0") == Ok(True)
expect Release.breaking_suffices("4.0.0-rc.1", "3.0.0") == Ok(True)
expect Release.breaking_suffices("3.1.0", "3.0.0") == Ok(False)
expect Release.breaking_suffices("3.0.1", "3.0.0") == Ok(False)
expect Release.breaking_suffices("3.0.0", "3.0.0") == Ok(False)
expect Release.breaking_suffices("2.0.0", "3.0.0") == Ok(False)
expect Release.breaking_suffices("1.0.0", "0.9.0") == Ok(True)
expect ["", "garbage", "v3.0.0", "3.0.0-rc.1", "03.0.0", "3.00.0", "18446744073709551616.0.0"].all(|previous| Release.breaking_suffices("4.0.0", previous).is_err())
expect ["04.0.0", "4.00.0", "4.0.00", "4.0.0-.", "4.0.0-rc..1", "4.0.0-01", "18446744073709551616.0.0"].all(|requested| Release.breaking_suffices(requested, "3.0.0").is_err())

expect Release.breaking_suffices("10.0.0", "9.0.0") == Ok(True)
expect Release.breaking_suffices("18446744073709551615.0.0", "18446744073709551614.0.0") == Ok(True)
expect Release.breaking_suffices("4.0.0", "18446744073709551615.0.0") == Ok(False)

expect Release.breaking_suffices("0.12.0", "0.11.0") == Ok(True)
expect Release.breaking_suffices("0.12.0-rc.1", "0.11.9") == Ok(True)
expect Release.breaking_suffices("0.11.1", "0.11.0") == Ok(False)
expect Release.breaking_suffices("0.11.0", "0.11.0") == Ok(False)
expect Release.breaking_suffices("0.10.9", "0.11.0") == Ok(False)
expect Release.breaking_suffices("0.12.0", "1.11.0") == Ok(False)
expect Release.breaking_suffices("0.10.0", "0.9.9") == Ok(True)
expect Release.breaking_suffices("0.18446744073709551615.0", "0.18446744073709551614.0") == Ok(True)
expect ["0.18446744073709551616.0", "0.11.18446744073709551616"].all(|previous| Release.breaking_suffices("0.12.0", previous).is_err())
expect ["0.18446744073709551616.0", "0.12.18446744073709551616"].all(|requested| Release.breaking_suffices(requested, "0.11.0").is_err())

expect Release.previous_release(["0.2.0", url]) == Ok({ version: "0.2.0", bundles: [url] })
expect [[], ["0.2.0"], ["0.2.0", ""], ["0.2.0", "https://github.com/other/repo/releases/download/0.2.0/Abc.tar.zst"], ["0.2.0", "https://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.1.0/Abc.tar.zst"], ["0.2.0-rc.1", url], ["00.2.0", url]].all(|metadata| Release.previous_release(metadata).is_err())
expect Release.previous_release(["0.2.0", url, "https://github.com/other/repo/releases/download/0.2.0/Abc.tar.zst"]).is_err()

expect Release.breaking_suffices("0.3.0", "0.2.0") == Ok(True)
expect Release.breaking_suffices("0.3.0-rc.1", "0.2.9") == Ok(True)
expect ["1.18446744073709551616.0", "1.0.18446744073709551616"].all(|requested| Release.breaking_suffices(requested, "0.2.0").is_err())
expect ["1.18446744073709551616.0", "1.0.18446744073709551616"].all(|previous| Release.breaking_suffices("2.0.0", previous).is_err())
expect Release.previous_release(["0.3.0", "https://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.3.0/layout-Abc.tar.zst", "https://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.3.0/mermaid-Def.tar.zst"]).is_ok()
expect ["http://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.2.0/Abc.tar.zst", "https://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.2.0/../Abc.tar.zst", "https://github.com/lukewilliamboswell/roc-graph-layout/releases/download/0.2.0/Abc.tar.zst?redirect=1"].all(|bundle| Release.previous_release(["0.2.0", bundle]).is_err())
