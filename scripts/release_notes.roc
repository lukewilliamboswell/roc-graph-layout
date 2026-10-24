#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Path
import src/Bundle
import src/Notes
import src/Release
import src/Script

## Render the body of a GitHub release from its hand-written notes.
##
##     RELEASE_VERSION=0.2.0 blueprint run release-notes
##
## Reads `docs/releases/<version>.md`, fills in the release URL of the only
## bundle in `dist` (or the one `BUNDLE_PATH` names), adds the compilers the
## release was built with and links to its documentation and examples, and
## writes `dist/release-notes.md`. A dry run, whose version is
## 0.0.1-dry-run, renders the notes of the newest version instead.
main! = |_args| {
	version = Script.env!("RELEASE_VERSION")?
	notes_version = if (version == Release.dry_run_version) newest_notes!()? else version
	path = Notes.file(notes_version)
	if !Path.is_file!(Path.utf8(path))? {
		return Script.fail!("${path} does not exist: write the release notes before releasing ${version}")
	}
	bundle = Bundle.selected!("dist")?
	package_url = match Release.bundle_url(version, Script.file_name(bundle)?) {
		Ok(url) => url
		Err(_) => return Script.fail!("cannot name the release URL of ${Path.display(bundle)} for ${version}")
	}
	body = match Notes.render(Path.read_utf8!(Path.utf8(path))?, { notes_version, version, package_url }) {
		Ok(text) => text
		Err(WrongTitle(found)) => return Script.fail!("${path} must open with \"${Notes.title(notes_version)}\", not \"${found}\"")
		Err(UnusedPlaceholder) => return Script.fail!("${path} must show the package URL as ${Notes.placeholder}")
		Err(UnresolvedPlaceholder) => return Script.fail!("${path} uses a placeholder other than ${Notes.placeholder}")
	}
	roc = Script.roc!()?.capture_utf8!(["version"], ".")?.trim().drop_prefix("Roc compiler version ")
	roc_stable = Script.roc_stable!()?.capture_utf8!(["version"], ".")?.trim().drop_prefix("Roc compiler version ")
	output = Path.utf8("dist/release-notes.md")
	Path.write_utf8!(output, "${body}${Notes.compilers({ roc, roc_stable })}")?
	Script.info!("NOTES", Path.display(output))
}

newest_notes! = || {
	versions = Path.list!(Path.utf8("docs/releases"))?
		.map_try(Script.file_name)?
		.keep_if(|name| name.ends_with(".md"))
		.map(|name| name.drop_suffix(".md"))
		.keep_if(Release.valid_version)
	match Release.newest_first(versions) {
		[newest, ..] => Ok(newest)
		[] => Script.fail!("docs/releases holds no release notes")
	}
}
