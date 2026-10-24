import cli.Env
import cli.Path
import Files
import Headers
import Release
import Script
import Spec
import Text

## The examples archive attached to each release.
##
## It holds complete copies of the examples, and of the helper packages they
## share, in which the package dependency is that release's bundle URL, so they
## keep working exactly as published. Its `spec.json` lists their cases in the
## form the shared nightly runner of roc-automation reads. The examples in the
## repository always depend on the working tree instead.
Archive := [].{

	## The cases of the working tree's examples.
	cases : Path
	cases = "tests/examples.json"

	## The archive named by `EXAMPLES_ARCHIVE`, or the only one in `directory`
	## when that is unset.
	selected! = |directory| {
		match Script.env_or!("EXAMPLES_ARCHIVE", "")? {
			"" => {}
			named => return Ok(Path.utf8(named))
		}
		entries = if (Path.is_dir!(directory)?) Path.list!(directory)? else []
		match entries.keep_if(|path| Path.display(path).ends_with(".zip") and Path.display(path).contains("${Release.name}-examples-")) {
			[archive] => Ok(archive)
			[] => Script.fail!("no examples archive in ${Path.display(directory)}: package one first, or set EXAMPLES_ARCHIVE")
			_ => Script.fail!("several examples archives in ${Path.display(directory)}: set EXAMPLES_ARCHIVE to choose one")
		}
	}

	## The example directories a release archives, sorted: every directory of
	## `examples/` except an interactive service, which says `## scripts: service`.
	directories! : () => Try(List(Path), _)
	directories! = || {
		var $kept = []
		for directory in Files.sort_paths(Path.list!("examples")?) {
			if Path.is_dir!(directory)? {
				main = Path.join(directory, "main.roc")
				service = Path.is_file!(main)? and Path.read_utf8!(main)?.contains("## scripts: service")
				if !service {
					$kept = $kept.append(directory)
				}
			}
		}
		Ok($kept)
	}

	## Write the archive for the release `version`, whose bundle is named
	## `bundle_file`, into `output_dir`. Returns the path of the archive.
	pack! = |version, bundle_file, output_dir| {
		if Release.valid_version(version) and !Release.publishable_version(version) {
			return Script.fail!("version ${version} is reserved by Roc: the lowest publishable version is 0.0.1")
		}
		url = match Release.bundle_url(version, bundle_file) {
			Ok(value) => value
			Err(InvalidVersion(_)) => return Script.fail!("not a release version: ${version}")
			Err(InvalidBundleFile(_)) => return Script.fail!("not a bundle file name: ${bundle_file}")
		}
		apps = match Spec.parse(Path.read_utf8!(Archive.cases)?) {
			Ok(parsed) => parsed
			Err(InvalidSpec) => return Script.fail!("${Path.display(Archive.cases)} does not list the cases of the examples")
		}
		root = Release.examples_root(version)
		Path.create_all!(output_dir)?
		archive = Path.join(Path.absolute!(output_dir)?, Release.examples_archive(version))
		# zip adds to an existing archive, which would keep entries from an earlier run.
		if Path.exists!(archive)? {
			Path.delete!(archive)?
		}

		Env.with_temp_dir!(
			|temporary| {
				stage = Path.join(temporary, root)
				var $entries = ["${root}/README.md", "${root}/spec.json"]
				for directory in Archive.directories!()? {
					name = Script.file_name(directory)?
					staged = Path.join(Path.join(stage, "examples"), name)
					Path.create_all!(staged)?
					for file in Files.direct_roc_files!(directory)? {
						file_name = Script.file_name(file)?
						Path.write_utf8!(Path.join(staged, file_name), archived(Path.read_utf8!(file)?, url)?)?
						$entries = $entries.append("${root}/examples/${name}/${file_name}")
					}
				}
				Path.write_utf8!(Path.join(stage, "README.md"), Release.examples_readme(version, url))?
				Path.write_utf8!(Path.join(stage, "spec.json"), Spec.render_suite(apps, version, url))?
				# -X leaves out owner and timestamp extras; -@ reads the entries to add.
				_ = Script.command("zip").capture!(["-q", "-X", Path.to_os_str(archive), "-@"], temporary, Str.to_utf8(Str.join_with($entries, "\n")))?
				Ok({})
			},
		)?
		Script.info!("ARCHIVE", "${Path.display(archive)} with ${Release.shorthand}: \"${url}\"")?
		Ok(archive)
	}

	## Unpack `archive` into `destination` after checking that it holds
	## nothing but examples of one roc-graph-layout release. Returns the
	## directory that holds `examples/`, the bundle URL the examples depend
	## on, the release version, and a file of the archived cases in the form
	## of `tests/examples.json`.
	unpack! = |archive, destination| {
		Script.require_file!(archive)?
		file_name = Script.file_name(archive)?
		Path.create_all!(destination)?
		if !file_name.ends_with(".zip") {
			return Script.fail!("not an examples archive: ${file_name}")
		}
		root_name = file_name.drop_suffix(".zip")
		root = unzip!(archive, root_name, destination)?
		suite = match Spec.parse_suite(Path.read_utf8!(Path.join(root, "spec.json"))?) {
			Ok(parsed) => parsed
			Err(InvalidSpec) => return Script.fail!("${file_name} holds no valid spec.json, so there is nothing to compare its examples with")
		}
		url = match suite.dependencies {
			[only] => only
			_ => return Script.fail!("the archived spec.json must name exactly one ${Release.name} bundle")
		}
		version = match Release.version_of_bundle_url(url) {
			Ok(value) => value
			Err(_) => return Script.fail!("archived examples must depend on a published ${Release.name} release bundle, not ${url}")
		}
		if file_name != Release.examples_archive(version) or suite.release != version or suite.schema_version != 1 {
			return Script.fail!("${file_name} holds examples of release ${suite.release}, bundled for ${version}")
		}
		for example in Files.roc_sources!(Path.join(root, "examples"))? {
			if Headers.has_roc_pin(example.source) {
				return Script.fail!("archived examples must not pin a Roc compiler")
			}
			if Headers.is_app(example.source) and Headers.dependency(example.source, Release.shorthand) != Ok(url) {
				return Script.fail!("${Path.display(example.path)} must depend on ${url}")
			}
		}
		cases_file = Path.join(destination, "cases.json")
		Path.write_utf8!(cases_file, Spec.render(suite.apps))?
		Ok({ root, url, version, cases: cases_file })
	}
}

# An example as archived: an application's package dependency becomes the
# release URL, and nothing else changes. Helper packages have no such dependency.
archived = |source, url|
	if Headers.is_app(source) {
		Headers.with_dependency(source, Release.shorthand, url)
	} else {
		Ok(source)
	}

unzip! = |archive, root, destination| {
	unzip = Script.command("unzip")
	# -Z1 lists entry names, one per line, without unpacking anything.
	entries = Text.lines(unzip.capture_utf8!(["-Z1", Path.to_os_str(archive)], ".")?)
	match entries.keep_if(|entry| !Release.valid_examples_entry(root, entry)) {
		[] => {}
		[entry, ..] => return Script.fail!("unexpected entry in the examples archive: ${entry}")
	}
	_ = unzip.capture!(["-q", Path.to_os_str(archive), "-d", Path.to_os_str(destination)], ".", [])?
	Ok(Path.join(destination, root))
}
