import Release

## Turning a release's notes into the body of its GitHub release.
##
## The notes are written by hand in `docs/releases/<version>.md`. They cannot
## name the release's bundle URL, because it holds the hash of a bundle that
## does not exist until the release builds it. They say `{package-url}`
## instead, and the release fills it in.
Notes := [].{

	## What stands for the release's bundle URL in the notes.
	placeholder : Str
	placeholder = "{package-url}"

	## Where the notes of the release `version` are written.
	file : Str -> Str
	file = |version| "docs/releases/${version}.md"

	## The heading the notes of `version` must open with.
	title : Str -> Str
	title = |version| "# ${Release.name} ${version}"

	## The body of the GitHub release `version` from the hand-written notes
	## `source` of `notes_version`, which differs from `version` only for a dry
	## run. The heading is dropped, because GitHub shows the release name.
	render : Str, { notes_version : Str, version : Str, package_url : Str } -> Try(Str, [WrongTitle(Str), UnusedPlaceholder, UnresolvedPlaceholder])
	render = |source, { notes_version, version, package_url }|
		match Str.split_first(source, "\n") {
			Ok({ before, after }) if before == Notes.title(notes_version) => {
				if !after.contains(Notes.placeholder) {
					return Err(UnusedPlaceholder)
				}
				body = Str.replace_each(after, Notes.placeholder, package_url)
				if body.contains("{package-") {
					return Err(UnresolvedPlaceholder)
				}
				Ok("${body.trim()}\n\n${links(version)}")
			}
			Ok({ before, .. }) => Err(WrongTitle(before))
			Err(_) => Err(WrongTitle(source))
		}

	## The section that says what a release was built and tested with. No
	## header pins the package compiler, so this is where a release states it.
	compilers : { roc : Str, roc_stable : Str } -> Str
	compilers = |versions|
		Str.join_with(
			[
				"## Compilers",
				"",
				"- Package and examples built and tested with `roc` ${versions.roc}",
				"- Release tooling run with `roc-stable` ${versions.roc_stable}",
				"",
			],
			"\n",
		)
}

links = |version| {
	download = "https://github.com/${Release.repository}/releases/download/${version}"
	Str.join_with(
		[
			"## Links",
			"",
			"- [API reference](${Release.site}/docs/${version}/)",
			"- [Examples](${download}/${Release.examples_archive(version)}), each depending on this release",
			"",
			"",
		],
		"\n",
	)
}

source = "# roc-graph-layout 0.2.0\n\nAdd `${Notes.placeholder}` to your header.\n"

rendered = Notes.render(source, { notes_version: "0.2.0", version: "0.2.0", package_url: "https://example.com/A.tar.zst" })

expect rendered.map_ok(|text| text.starts_with("Add `https://example.com/A.tar.zst` to your header.\n\n## Links\n")) == Ok(Bool.True)
expect rendered.map_ok(|text| text.contains("/docs/0.2.0/)")) == Ok(Bool.True)
expect Notes.render(source, { notes_version: "0.3.0", version: "0.3.0", package_url: "x" }) == Err(WrongTitle("# roc-graph-layout 0.2.0"))
expect Notes.render("# roc-graph-layout 0.2.0\n\nNo URL.\n", { notes_version: "0.2.0", version: "0.2.0", package_url: "x" }) == Err(UnusedPlaceholder)
expect Notes.render("# roc-graph-layout 0.2.0\n\n{package-url} {package-docs}\n", { notes_version: "0.2.0", version: "0.2.0", package_url: "x" }) == Err(UnresolvedPlaceholder)
expect Notes.compilers({ roc: "nightly-a", roc_stable: "nightly-b" }).contains("`roc-stable` nightly-b")
