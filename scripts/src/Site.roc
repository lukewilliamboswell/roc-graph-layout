import cli.Env
import cli.OsStr
import cli.Path
import DocsArchive
import Release
import Script

## The documentation site published to GitHub Pages.
##
## The guide in `docs/index.adoc` is rendered by roc-automation's shared
## `roc-docs` utility, as pages, Markdown copies, `llms.txt` and a PDF. The API
## reference of the working tree is written by `roc docs` under
## `docs/<version>/`, beside that of every earlier release when they are
## fetched. `docs/` leads to the newest final release.
Site := [].{

	## Write the site to `output`, replacing what is there. `version` names
	## the API reference of the working tree: a release version, or `main`.
	assemble! = |roc, output, version, releases| {
		if version != "main" and !Release.valid_version(version) {
			return Script.fail!("the site version must be main or a release version, not ${version}")
		}
		Env.with_temp_dir!(
			|temporary| {
				site = Path.join(temporary, "site")
				Path.create_all!(site)?
				guides!(site, version, "${Release.name}.pdf")?
				docs = Path.join(site, "docs")
				Site.docs!(roc, Path.join(docs, version))?
				restored = match releases {
					FetchReleaseDocs => DocsArchive.fetch!(docs, version)?
					SkipReleaseDocs => []
				}
				finals = Release.newest_first(restored.concat(if (Release.is_final(version)) [version] else []))
				Path.write_utf8!(Path.join(docs, "index.html"), redirect(finals.first() ?? version))?
				Path.write_utf8!(Path.join(site, ".nojekyll"), "")?
				if Path.exists!(output)? {
					Path.delete_all!(output)?
				}
				Path.create_all!(output)?
				Path.copy_dir_with!(site, output, { symlinks: Preserve, destination: Merge })?
				Script.info!("SITE", Path.display(output))
			},
		)
	}

	## Render the guide's PDF for the release `version` into `output_dir`,
	## returning its path, `roc-graph-layout-<version>.pdf`.
	manual! : Str, Path => Try(Path, _)
	manual! = |version, output_dir| {
		file_name = "${Release.name}-${version}.pdf"
		rendered = render!(version, file_name)?
		Path.create_all!(output_dir)?
		manual = Path.join(output_dir, file_name)
		Path.copy!(Path.join(rendered, file_name), manual)?
		Script.info!("MANUAL", Path.display(manual))?
		Ok(manual)
	}

	## Write the API reference of the working tree to `output` with `roc docs`.
	docs! : Script.Command, Path => Try({}, _)
	docs! = |roc, output| {
		version = Script.file_name(output)?
		url_root = "${Release.site_base_path}/docs/${version}"
		roc.with_env("ROC_DOCS_URL_ROOT", OsStr.from_str(url_root)).run!(["docs", "package/main.roc", OsStr.from_str("--output=${Path.display(output)}")])?
		Script.require_file!(Path.join(output, "index.html"))
	}
}

guides! : Path, Str, Str => Try({}, _)
guides! = |site, version, pdf| {
	rendered = render!(version, pdf)?
	Path.copy_dir_with!(Path.join(rendered, "site"), site, { symlinks: Preserve, destination: Merge })?
	# The guide links to this drawing, which an example draws; roc-docs embeds
	# only PNG images.
	assets = Path.join(site, "assets")
	Path.create_all!(assets)?
	Path.copy!("examples/build_pipeline/output.svg", Path.join(assets, "build-pipeline.svg"))
}

# roc-docs writes only inside its workspace, so it renders into the ignored
# `.docs-out`, replacing what an earlier render left there.
render! : Str, Str => Try(Path, _)
render! = |version, pdf| {
	output : Str
	output = ".docs-out"
	Script.command("roc-docs").run!(["build", "--workspace", ".", "--docs-directory", "docs", "--entrypoint", "index.adoc", "--output-directory", OsStr.from_str(output), "--pdf-filename", OsStr.from_str(pdf), "--docs-version", OsStr.from_str(version)])?
	Ok(Path.utf8(output))
}

redirect = |version|
	"<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0; url=./${version}/\"><link rel=\"canonical\" href=\"./${version}/\"><title>API reference</title><a href=\"./${version}/\">API reference ${version}</a>\n"

expect redirect("0.2.0").contains("url=./0.2.0/")
