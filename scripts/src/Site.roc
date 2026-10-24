import cli.Env
import cli.OsStr
import cli.Path
import DocsArchive
import Release
import Script

## The documentation site published to GitHub Pages.
##
## The guides in `site/content` are rendered by the generator in
## `site/main.roc`. The API reference of the working tree is written by
## `roc docs` under `docs/<version>/`, beside that of every earlier release
## when they are fetched. `docs/` leads to the newest final release.
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
				guides!(roc, site, Path.join(temporary, "site-generator"))?
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

	## Write the API reference of the working tree to `output` with `roc docs`.
	docs! : Script.Command, Path => Try({}, _)
	docs! = |roc, output| {
		version = Script.file_name(output)?
		url_root = "${Release.site_base_path}/docs/${version}"
		roc.with_env("ROC_DOCS_URL_ROOT", OsStr.from_str(url_root)).run!(["docs", "package/main.roc", OsStr.from_str("--output=${Path.display(output)}")])?
		Script.require_file!(Path.join(output, "index.html"))
	}
}

guides! : Script.Command, Path, Path => Try({}, _)
guides! = |roc, site, generator| {
	roc.run!(["build", "site/main.roc", OsStr.from_str("--output=${Path.display(generator)}")])?
	Script.command(Path.to_os_str(generator)).run!(["site/content", Path.to_os_str(site)])?
	Path.copy_dir_with!("site/public", site, { symlinks: Preserve, destination: Merge })?
	assets = Path.join(site, "assets")
	Path.create_all!(assets)?
	Path.copy!("examples/build_pipeline/output.svg", Path.join(assets, "build-pipeline.svg"))
}

redirect = |version|
	"<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0; url=./${version}/\"><link rel=\"canonical\" href=\"./${version}/\"><title>API reference</title><a href=\"./${version}/\">API reference ${version}</a>\n"

expect redirect("0.2.0").contains("url=./0.2.0/")
