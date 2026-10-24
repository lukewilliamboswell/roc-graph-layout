import Archive
import cli.Env
import cli.OsStr
import cli.Path
import Examples
import Headers
import Loopback
import Release
import Script

## Building the package bundles of a release, and testing an examples archive
## against them.
##
## A release publishes two packages. The layout package, `package/`, depends
## on nothing. The Mermaid package, `package-mermaid/`, depends on the layout
## package of the same release by its release URL, which is known before the
## release exists: the version and the layout bundle's file name fix it.
Bundle := [].{

	## The bundles of one release.
	Bundles : { layout : Path, mermaid : Path }

	## Bundle the working-tree packages for the release `version` into
	## `output_dir` with `roc`, returning the archives created.
	##
	## The layout package is bundled first. The Mermaid package is bundled
	## from a copy whose `layout` dependency is that bundle's release URL in
	## place of `../package/main.roc`. `roc bundle` resolves the dependencies
	## of what it bundles, and that URL does not exist yet, so the copy is
	## first checked against the layout bundle served from a loopback address,
	## which leaves it in an empty package cache, and then bundled with that
	## cache.
	build! : Script.Command, Str, Path => Try(Bundles, _)
	build! = |roc, version, output_dir| {
		if !Release.publishable_version(version) {
			return Script.fail!("not a publishable release version: ${version}")
		}
		Script.require_file!("package/main.roc")?
		Script.require_file!("package-mermaid/main.roc")?
		Path.create_all!(output_dir)?
		output = Path.absolute!(output_dir)?
		# `roc bundle` follows the imports of the package entry point, so the
		# fuzz targets, test modules and tools beside it are not included.
		layout = bundle!(roc, "package", output)?
		layout_url = match Release.bundle_url(version, Script.file_name(layout)?) {
			Ok(url) => url
			Err(_) => return Script.fail!("cannot name the release URL of ${Path.display(layout)} for ${version}")
		}
		mermaid = Env.with_temp_dir!(
			|temporary| {
				staged = Path.join(temporary, "package-mermaid")
				Path.copy_dir!("package-mermaid", staged)?
				main = Path.join(staged, "main.roc")
				Path.write_utf8!(main, Headers.with_dependency(Path.read_utf8!(main)?, Release.shorthand, layout_url)?)?
				server = Loopback.start!([layout])?
				served = Loopback.url(server, layout)?
				Script.info!("SERVE", "${served} in place of ${layout_url}")?
				fetching = roc.with_empty_package_cache(Path.join(temporary, "cache"))
				checked = Loopback.run!(server, fetching.cmd(["check", "main.roc", "--no-cache", "--replace-dep", OsStr.from_str(layout_url), OsStr.from_str(served)]).cwd(staged))?
				Loopback.stop!(server)?
				if checked.status != Exited(0) {
					return Script.fail!("package-mermaid does not check against the layout bundle\n${Str.from_utf8_lossy(checked.stdout_bytes)}${Str.from_utf8_lossy(checked.stderr_bytes)}")
				}
				bundle!(fetching, staged, output)
			},
		)?
		Ok({ layout, mermaid })
	}

	## The bundles named by `BUNDLE_PATH` and `MERMAID_BUNDLE_PATH`, or the two
	## in `directory` when those are unset: what the release steps after
	## `build!` work on. The bundles are told apart by their entry points: the
	## Mermaid package depends on the layout package, which depends on nothing.
	## The Mermaid bundle must depend on the layout bundle chosen.
	selected! : Path => Try(Bundles, _)
	selected! = |directory| {
		named = (Script.env_or!("BUNDLE_PATH", "")?, Script.env_or!("MERMAID_BUNDLE_PATH", "")?)
		candidates = match named {
			("", "") => {
				entries = if (Path.is_dir!(directory)?) Path.list!(directory)? else []
				entries.keep_if(|path| Path.display(path).ends_with(".tar.zst"))
			}
			(layout, mermaid) if layout != "" and mermaid != "" => [Path.utf8(layout), Path.utf8(mermaid)]
			_ => return Script.fail!("set both BUNDLE_PATH and MERMAID_BUNDLE_PATH, or neither")
		}
		Bundle.classify!(candidates, Path.display(directory))
	}

	## Tell the layout bundle and the Mermaid bundle among `candidates` apart,
	## failing unless there is exactly one of each and the Mermaid bundle
	## depends on the layout bundle. `place` names where they were found.
	classify! : List(Path), Str => Try(Bundles, _)
	classify! = |candidates, place| {
		var $layouts = []
		var $mermaids = []
		for bundle in candidates {
			Script.require_file!(bundle)?
			match Headers.dependency(entry_point!(bundle)?, Release.shorthand) {
				Ok(url) => {
					$mermaids = $mermaids.append((bundle, url))
				}
				Err(MissingDependency(_)) => {
					$layouts = $layouts.append(bundle)
				}
				Err(_) => return Script.fail!("${Path.display(bundle)} declares its layout dependency unreadably")
			}
		}
		match ($layouts, $mermaids) {
			([layout], [(mermaid, url)]) => {
				if !url.ends_with("/${Script.file_name(layout)?}") {
					return Script.fail!("${Path.display(mermaid)} depends on ${url}, not on ${Path.display(layout)}")
				}
				Ok({ layout, mermaid })
			}
			([], []) => Script.fail!("no bundles in ${place}: build them first, or set BUNDLE_PATH and MERMAID_BUNDLE_PATH")
			_ => Script.fail!("${place} must hold one layout bundle and one Mermaid bundle, not ${$layouts.len().to_str()} and ${$mermaids.len().to_str()}: set BUNDLE_PATH and MERMAID_BUNDLE_PATH to choose them")
		}
	}

	## The release URLs of `bundles` as release `version` publishes them.
	## Fails when the Mermaid bundle was made for another version, whose
	## layout bundle URL it would name.
	urls! : Bundles, Str => Try(Release.Urls, _)
	urls! = |bundles, version| {
		layout = match Release.bundle_url(version, Script.file_name(bundles.layout)?) {
			Ok(url) => url
			Err(_) => return Script.fail!("cannot name the release URL of ${Path.display(bundles.layout)} for ${version}")
		}
		mermaid = match Release.bundle_url(version, Script.file_name(bundles.mermaid)?) {
			Ok(url) => url
			Err(_) => return Script.fail!("cannot name the release URL of ${Path.display(bundles.mermaid)} for ${version}")
		}
		if Headers.dependency(entry_point!(bundles.mermaid)?, Release.shorthand) != Ok(layout) {
			return Script.fail!("${Path.display(bundles.mermaid)} was not bundled for ${version}: it must depend on ${layout}")
		}
		Ok({ layout, mermaid })
	}

	## Run the examples in `archive`, exactly as archived, against `bundles`.
	##
	## The archived examples name the release URLs of the bundles, which do
	## not exist before the release does. So the bundles are served from a
	## loopback address and Roc is told to load each wherever its URL is
	## declared, including the layout URL that the Mermaid bundle declares.
	## The files under test are the files a release would publish.
	test! = |roc, bundles, archive| {
		Env.with_temp_dir!(
			|temporary| {
				unpacked = Archive.unpack!(archive, Path.join(temporary, "unpacked"))?
				for (bundle, url) in [(bundles.layout, unpacked.urls.layout), (bundles.mermaid, unpacked.urls.mermaid)] {
					if !url.ends_with("/${Script.file_name(bundle)?}") {
						return Script.fail!("${Path.display(archive)} depends on ${url}, which is not ${Path.display(bundle)}")
					}
				}
				server = Loopback.start!([bundles.layout, bundles.mermaid])?
				layout = ["--replace-dep", OsStr.from_str(unpacked.urls.layout), OsStr.from_str(Loopback.url(server, bundles.layout)?)]
				mermaid = ["--replace-dep", OsStr.from_str(unpacked.urls.mermaid), OsStr.from_str(Loopback.url(server, bundles.mermaid)?)]
				Script.info!("SERVE", "${server.base} in place of ${unpacked.urls.layout} and ${unpacked.urls.mermaid}")?
				# An empty package cache makes Roc fetch the bundles from the server.
				fetching = roc.with_empty_package_cache(Path.join(temporary, "cache"))
				ran = Examples.run!(
					fetching,
					{
						root: unpacked.root,
						source: Served(server),
						spec: unpacked.cases,
						mode: Compare,
						# Roc rejects a replacement for a source nothing declares,
						# and the Mermaid package declares the layout package.
						roc_args: |source|
							if Headers.dependency(source, Release.mermaid_shorthand).is_ok() {
								layout.concat(mermaid)
							} else {
								layout
							},
					},
				)
				Loopback.stop!(server)?
				ran
			},
		)
	}
}

# Bundle the package whose entry point is `main.roc` in `directory` into
# `output`, returning the archive. `roc bundle` does not report the file it
# writes, so it writes into an empty directory and the one archive found
# there is moved into place.
bundle! = |roc, directory, output|
	Env.with_temp_dir!(
		|staging| {
			_ = roc.capture!(["bundle", "main.roc", "--output-dir", Path.to_os_str(staging)], directory, [])?
			created = match Path.list!(staging)?.keep_if(|path| Path.display(path).ends_with(".tar.zst")) {
				[one] => one
				found => return Script.fail!("roc bundle wrote ${found.len().to_str()} archives instead of one")
			}
			bundle = Path.join(output, Script.file_name(created)?)
			Path.copy!(created, bundle)?
			Script.info!("BUNDLE", "${Path.display(bundle)} (${Path.size_in_bytes!(bundle)?.to_str()} bytes)")?
			Ok(bundle)
		},
	)

# The text of a bundle's `main.roc`. tar reads zstd archives by calling zstd.
entry_point! = |bundle| {
	bytes = Script.command("tar").capture!(["--zstd", "-x", "-O", "-f", Path.to_os_str(bundle), "main.roc"], ".", [])?
	Str.from_utf8(bytes).map_err(|_| BundleEntryPointNotUtf8(Path.display(bundle)))
}
