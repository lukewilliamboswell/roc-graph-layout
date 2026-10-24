import Release

## Turning a release's notes into the body of its GitHub release.
##
## The notes are written by hand in `docs/releases/<version>.md`. They cannot
## name the release's bundle URLs, because each holds the hash of a bundle
## that does not exist until the release builds it. They say `{package-url}`
## for the layout package and `{mermaid-url}` for the Mermaid package
## instead, and the release fills them in.
Notes := [].{

	## What stands for the release's layout bundle URL in the notes, which
	## every release's notes show.
	placeholder : Str
	placeholder = "{package-url}"

	## What stands for the release's Mermaid bundle URL in the notes.
	mermaid_placeholder : Str
	mermaid_placeholder = "{mermaid-url}"

	## Where the notes of the release `version` are written.
	file : Str -> Str
	file = |version| "docs/releases/${version}.md"

	## The heading the notes of `version` must open with.
	title : Str -> Str
	title = |version| "# ${Release.name} ${version}"

	## The body of the GitHub release `version` from the hand-written notes
	## `source` of `notes_version`, which differs from `version` only for a dry
	## run. The heading is dropped, because GitHub shows the release name.
	render : Str, { notes_version : Str, version : Str, urls : Release.Urls } -> Try(Str, [WrongTitle(Str), UnusedPlaceholder, UnresolvedPlaceholder])
	render = |source, { notes_version, version, urls }|
		match Str.split_first(source, "\n") {
			Ok({ before, after }) if before == Notes.title(notes_version) => {
				if !after.contains(Notes.placeholder) {
					return Err(UnusedPlaceholder)
				}
				body = Str.replace_each(after, Notes.placeholder, urls.layout)
					.replace_each(Notes.mermaid_placeholder, urls.mermaid)
				if body.contains("{package-") or body.contains("{mermaid-") {
					return Err(UnresolvedPlaceholder)
				}
				Ok("${body.trim()}\n\n${links(version, urls)}")
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

links = |version, urls| {
	download = "https://github.com/${Release.repository}/releases/download/${version}"
	Str.join_with(
		[
			"## Links",
			"",
			"- Layout package: `${urls.layout}`",
			"- Mermaid package: `${urls.mermaid}`",
			"- [API reference](${Release.site}/docs/${version}/) and [Mermaid API reference](${Release.site}/docs/${version}/mermaid/)",
			"- [Examples](${download}/${Release.examples_archive(version)}), each depending on this release",
			"",
			"",
		],
		"\n",
	)
}

source = "# roc-graph-layout 0.2.0\n\nAdd `${Notes.placeholder}` to your header.\n"

urls = { layout: "https://example.com/A.tar.zst", mermaid: "https://example.com/M.tar.zst" }

rendered = Notes.render(source, { notes_version: "0.2.0", version: "0.2.0", urls })

expect rendered.map_ok(|text| text.starts_with("Add `https://example.com/A.tar.zst` to your header.\n\n## Links\n")) == Ok(Bool.True)
expect rendered.map_ok(|text| text.contains("/docs/0.2.0/)") and text.contains("/docs/0.2.0/mermaid/)")) == Ok(Bool.True)
expect rendered.map_ok(|text| text.contains("- Mermaid package: `https://example.com/M.tar.zst`\n")) == Ok(Bool.True)
expect Notes.render("# roc-graph-layout 0.3.0\n\n`{package-url}` and `{mermaid-url}`\n", { notes_version: "0.3.0", version: "0.3.0", urls }).map_ok(|text| text.starts_with("`https://example.com/A.tar.zst` and `https://example.com/M.tar.zst`\n")) == Ok(Bool.True)
expect Notes.render(source, { notes_version: "0.3.0", version: "0.3.0", urls }) == Err(WrongTitle("# roc-graph-layout 0.2.0"))
expect Notes.render("# roc-graph-layout 0.2.0\n\nNo URL.\n", { notes_version: "0.2.0", version: "0.2.0", urls }) == Err(UnusedPlaceholder)
expect Notes.render("# roc-graph-layout 0.2.0\n\n{package-url} {package-docs}\n", { notes_version: "0.2.0", version: "0.2.0", urls }) == Err(UnresolvedPlaceholder)
expect Notes.render("# roc-graph-layout 0.2.0\n\n{package-url} {mermaid-docs}\n", { notes_version: "0.2.0", version: "0.2.0", urls }) == Err(UnresolvedPlaceholder)
expect Notes.compilers({ roc: "nightly-a", roc_stable: "nightly-b" }).contains("`roc-stable` nightly-b")
