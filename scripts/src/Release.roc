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

	## The version a pull request builds and tests its release under. It is
	## never published.
	dry_run_version : Str
	dry_run_version = "0.0.1-dry-run"

	## Whether `value` is the file name `roc bundle` gives a package archive.
	valid_bundle_file : Str -> Bool
	valid_bundle_file = |value| value.ends_with(".tar.zst") and Text.is_alphanumeric(value.drop_suffix(".tar.zst"))

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
	## directory is `root`: the README, the case specification, or a Roc file
	## of one example directory, `examples/<dir>/<file>.roc`.
	valid_examples_entry : Str, Str -> Bool
	valid_examples_entry = |root, entry|
		if entry == "${root}/README.md" or entry == "${root}/spec.json" {
			Bool.True
		} else if entry.starts_with("${root}/examples/") {
			match Str.split_on(entry.drop_prefix("${root}/examples/"), "/") {
				[directory, ""] => Text.is_plain(directory, "_-")
				[directory, file] => Text.is_plain(directory, "_-") and file.ends_with(".roc") and Text.is_plain(file.drop_suffix(".roc"), "_-")
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
