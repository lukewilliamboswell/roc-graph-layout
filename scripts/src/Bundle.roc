import Archive
import cli.Env
import cli.OsStr
import cli.Path
import Examples
import Loopback
import Script

## Building the package bundle, and testing an examples archive against one.
Bundle := [].{

	## Bundle the working-tree package into `output_dir` with `roc`,
	## returning the path of the archive it created.
	build! = |roc, output_dir| {
		Script.require_file!("package/main.roc")?
		Path.create_all!(output_dir)?
		output = Path.absolute!(output_dir)?
		# `roc bundle` does not report the file it writes, so it writes into an
		# empty directory and the one archive found there is moved into place.
		Env.with_temp_dir!(
			|staging| {
				# `roc bundle` follows the imports of the package entry point, so
				# the fuzz targets beside it in package/ are not included.
				_ = roc.capture!(["bundle", "main.roc", "--output-dir", Path.to_os_str(staging)], "package", [])?
				created = match Path.list!(staging)?.keep_if(|path| Path.display(path).ends_with(".tar.zst")) {
					[one] => one
					found => return Script.fail!("roc bundle wrote ${found.len().to_str()} archives instead of one")
				}
				bundle = Path.join(output, Script.file_name(created)?)
				Path.copy!(created, bundle)?
				Script.info!("BUNDLE", Path.display(bundle))?
				Ok(bundle)
			},
		)
	}

	## The bundle named by `BUNDLE_PATH`, or the only one in `directory` when
	## that is unset: what the release steps after `build!` work on.
	selected! = |directory| {
		match Script.env_or!("BUNDLE_PATH", "")? {
			"" => {}
			named => return Ok(Path.utf8(named))
		}
		entries = if (Path.is_dir!(directory)?) Path.list!(directory)? else []
		match entries.keep_if(|path| Path.display(path).ends_with(".tar.zst")) {
			[bundle] => Ok(bundle)
			[] => Script.fail!("no bundle in ${Path.display(directory)}: build one first, or set BUNDLE_PATH")
			_ => Script.fail!("several bundles in ${Path.display(directory)}: set BUNDLE_PATH to choose one")
		}
	}

	## Run the examples in `archive`, exactly as archived, against `bundle`.
	##
	## The archived examples name the release URL of the bundle, which does not
	## exist before the release does. So the bundle is served from a loopback
	## address and Roc is told to load it wherever that URL is declared. The
	## files under test are the files a release would publish.
	test! = |roc, bundle, archive| {
		Script.require_file!(bundle)?
		Env.with_temp_dir!(
			|temporary| {
				unpacked = Archive.unpack!(archive, Path.join(temporary, "unpacked"))?
				if !unpacked.url.ends_with("/${Script.file_name(bundle)?}") {
					return Script.fail!("${Path.display(archive)} depends on ${unpacked.url}, which is not ${Path.display(bundle)}")
				}
				server = Loopback.start!(bundle)?
				Script.info!("SERVE", "${server.url} in place of ${unpacked.url}")?
				# An empty package cache makes Roc fetch the bundle from the server.
				fetching = roc.with_empty_package_cache(Path.join(temporary, "cache"))
				ran = Examples.run!(
					fetching,
					{
						root: unpacked.root,
						source: Served(server),
						spec: unpacked.cases,
						mode: Compare,
						roc_args: ["--replace-dep", OsStr.from_str(unpacked.url), OsStr.from_str(server.url)],
					},
				)
				Loopback.stop!(server)?
				ran
			},
		)
	}
}
