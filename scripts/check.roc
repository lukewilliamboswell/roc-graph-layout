#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

import cli.Cmd
import cli.Duration
import cli.Env
import cli.OsStr
import cli.Path
import src/Archive
import src/Bundle
import src/DocsArchive
import src/Examples
import src/Files
import src/Headers
import src/Release
import src/Script
import src/Site
import src/Text

## Everything CI checks, in one command.
##
##     blueprint run check
##
## Two compilers take part. `roc-stable`, pinned by Blueprint.roc, runs this
## script and checks the other scripts. The package, the examples, the site,
## the benchmarks and what a release would publish are checked with the `roc`
## on PATH, which is meant to be the latest nightly.
main! = |_args| {
	roc_stable = Script.roc_stable!()?
	roc = Script.roc!()?

	Script.section!("Compilers")?
	roc_stable.run!(["version"])?
	roc.run!(["version"])?

	check_compiler_pins!()?
	check_scripts!(roc_stable)?
	check_package!(roc)?
	check_examples!(roc)?
	check_node_editor!(roc)?
	check_fuzz_targets!(roc)?
	check_benchmarks!()?
	check_release_artifacts!(roc)?
	check_site!(roc)?

	Script.section!("Whitespace")?
	Script.command("git").run!(["diff", "--check"])
}

# The package compiler floats, so nothing outside scripts/ names a compiler.
# Each script names the tooling compiler, and Blueprint.roc is the authority:
# someone who runs a script with another `roc` is then told why it misbehaves.
check_compiler_pins! = || {
	Script.section!("Compiler pins")?
	for stale in [".roc-version", ".github/roc-nightly.json"] {
		if Path.exists!(Path.utf8(stale))? {
			return Script.fail!("${stale} must not exist: this repository does not pin the package compiler")
		}
	}
	# Only tracked sources: installed dependencies such as node_modules are not ours.
	tracked = Script.command("git").capture_utf8!(["ls-files", "--", "*.roc"], ".")?
	for name in Text.lines(tracked).keep_if(|path| !path.starts_with("scripts/")) {
		if Headers.has_roc_pin(Path.read_utf8!(Path.utf8(name))?) {
			return Script.fail!("${name}: remove the `roc:` header field")
		}
	}
	tag = match Headers.stable_tag(Path.read_utf8!("Blueprint.roc")?) {
		Ok(value) => value
		Err(NoStableCompiler) => return Script.fail!("Blueprint.roc does not name roc-stable with Fetch(\"roc-stable\", Recipes.roc_nightly(\"<tag>\"))")
	}
	for file in Files.roc_sources!("scripts")?.keep_if(|script| Headers.is_app(script.source)) {
		if Headers.roc_pin(file.source) != Ok(tag) {
			return Script.fail!("${Path.display(file.path)}: the app header must declare roc: \"${tag}\", the roc-stable release in Blueprint.roc")
		}
	}
	Script.pass!("only the scripts name a compiler, and it is ${tag}")
}

check_scripts! = |roc_stable| {
	Script.section!("Scripts, with the tooling compiler")?
	# The modules without effects carry the tests of the scripts' logic.
	for module_name in ["BenchCases", "BenchFormat", "BenchJson", "BenchReport", "Headers", "Notes", "Release", "Report", "Spec", "Text"] {
		roc_stable.run!(["test", OsStr.from_str("scripts/src/${module_name}.roc")])?
	}
	# These need the cli platform of an app for their pure parts.
	for (module_name, entry) in [("Preview", "serve"), ("Site", "site")] {
		roc_stable.run!(["test", OsStr.from_str("scripts/src/${module_name}.roc"), OsStr.from_str("--main=scripts/${entry}.roc")])?
	}
	for script in Files.direct_roc_files!("scripts")? {
		roc_stable.run!(["check", Path.to_os_str(script)])?
	}
	roc_stable.run!(["fmt", "--check", "scripts"])
}

check_package! = |roc| {
	Script.section!("Package")?
	roc.run!(["fmt", "--check", "package", "examples", "benchmarks"])?
	roc.run!(["check", "package/main.roc", "--no-cache"])?
	# The default backend and the interpreter have disagreed before, so the
	# tests run in both.
	roc.run!(["test", "package/main.roc", "--no-cache"])?
	roc.run!(["test", "package/main.roc", "--opt=interpreter", "--no-cache"])?
	# Each fuzz target's expects hold its contract and its distilled corpus
	# regressions.
	for target in Files.direct_roc_files!("package")? {
		if Script.file_name(target)?.starts_with("fuzz_") {
			roc.run!(["test", Path.to_os_str(target), "--no-cache"])?
		}
	}
	Ok({})
}

check_examples! = |roc| {
	Script.section!("Examples, against the working tree")?
	# Committed examples must exercise the working tree, never a published bundle.
	for directory in Files.sort_paths(Path.list!("examples")?) {
		main = Path.join(directory, "main.roc")
		if Path.is_file!(main)? {
			source = Path.read_utf8!(main)?
			if Headers.is_app(source) and Headers.dependency(source, Release.shorthand) != Ok("../../package/main.roc") {
				return Script.fail!("${Path.display(main)}: the app header must declare ${Release.shorthand}: \"../../package/main.roc\"")
			}
			# An interactive service is not run, but must still build.
			if source.contains("## scripts: service") {
				roc.run!(["check", Path.to_os_str(main), "--no-cache"])?
			}
		}
	}
	Examples.run!(roc, { root: ".", source: Direct, spec: Archive.cases, mode: Compare, roc_args: [] })?
	# Each example rewrote its drawing; the committed one must be what it drew.
	Script.command("git").run!(["diff", "--exit-code", "--", ":(glob)examples/**/output.svg"])
}

check_benchmarks! = || {
	Script.section!("Benchmarks, smoke rung")?
	match Headers.dependency(Path.read_utf8!("benchmarks/main.roc")?, Release.shorthand) {
		Ok("../package/main.roc") => {}
		_ => return Script.fail!("benchmarks/main.roc: the app header must declare ${Release.shorthand}: \"../package/main.roc\"")
	}
	Env.with_temp_dir!(|output| Script.command("scripts/bench.roc").run!(["--", "smoke", "--output", Path.to_os_str(output)]))
}

# A target that is never built goes stale, and its expects alone do not run
# the generated inputs. Each one is built natively and runs a short, seeded
# campaign. A longer search is `<target> run`, outside CI.
check_fuzz_targets! = |roc| {
	Script.section!("Fuzz targets, native seeded runs")?
	system = Script.command("uname").capture_utf8!(["-sm"], ".")?.trim()
	if system != "Linux x86_64" and system != "Darwin arm64" {
		return Script.info!("SKIP", "roc-fuzz builds only for Linux x86-64 and Apple Silicon macOS, not ${system}")
	}
	Env.with_temp_dir!(
		|build| {
			for target in Files.direct_roc_files!("package")? {
				name = Script.file_name(target)?
				if name.starts_with("fuzz_") {
					executable = Path.join(build, name.drop_suffix(".roc"))
					roc.run!(["build", "--fuzz", Path.to_os_str(target), OsStr.from_str("--output=${Path.display(executable)}")])?
					# A fresh corpus each time: `run` otherwise grows ./.roc-fuzz/corpus,
					# and the next seeded run would start from different inputs.
					corpus = Path.join(Path.join(build, "corpus"), name)
					Path.create_all!(corpus)?
					artifacts = OsStr.from_str("--artifact-dir=${Path.display(Path.join(build, "artifacts"))}")
					Script.command(Path.to_os_str(executable)).run!(["run", Path.to_os_str(corpus), "--runs=2000", "--seed=1", artifacts])?
				}
			}
			Ok({})
		},
	)
}

# The node editor is a service, so the examples harness only builds it. This
# starts the native binary, waits for it to serve its page, and reads the first
# event of its update stream, which renders the document through the layout
# and routing code.
check_node_editor! = |roc| {
	Script.section!("Node editor, native smoke run")?
	Env.with_temp_dir!(
		|temporary| {
			executable = Path.join(temporary, "node-editor")
			roc.run!(["build", "examples/node_editor/main.roc", OsStr.from_str("--output=${Path.display(executable)}")])?
			port = "18187"
			child = Cmd.new(Path.to_os_str(executable))
				.cwd("examples/node_editor")
				.env("ROC_GRAPH_LAYOUT_NODE_EDITOR_DB", Path.to_os_str(Path.join(temporary, "node_editor.db")))
				.env("ROC_GRAPH_LAYOUT_NODE_EDITOR_PORT", OsStr.from_str(port))
				.stdout(Null)
				.spawn!()?
			probed = probe_node_editor!(port)
			child.kill!()?
			probed
		},
	)
}

probe_node_editor! = |port| {
	base = "http://127.0.0.1:${port}"
	var $ready = Bool.False
	var $attempts = 0
	while !$ready and $attempts < 100 {
		output = Cmd.new("curl").args(["-sf", "-o", "/dev/null", OsStr.from_str("${base}/")]).run!()?
		if output.status == Exited(0) {
			$ready = Bool.True
		} else {
			$attempts = $attempts + 1
			Duration.sleep!(Duration.millis(200))?
		}
	}
	if !$ready {
		return Script.fail!("the node editor did not serve ${base}/ within 20 seconds")
	}
	# The update stream stays open, so curl stops it after its first event.
	stream = Cmd.new("curl").args(["-s", "-m", "3", OsStr.from_str("${base}/updates")]).run!()?
	if !Str.from_utf8_lossy(stream.stdout_bytes).contains("event: datastar-patch-elements") {
		return Script.fail!("the node editor's update stream did not render the document")
	}
	Script.pass!("the node editor serves its page and renders the document")
}

# Build what a release would publish, and test those files instead of the
# source tree.
check_release_artifacts! = |roc| {
	Script.section!("Release bundle and examples archive")?
	Env.with_temp_dir!(
		|temporary| {
			output = Path.join(temporary, "dist")
			bundle = Bundle.build!(roc, output)?
			archive = Archive.pack!(Release.dry_run_version, Script.file_name(bundle)?, output)?
			Bundle.test!(roc, bundle, archive)?

			unpacked = Archive.unpack!(archive, Path.join(temporary, "unpacked"))?
			for directory in Archive.directories!()? {
				for file in Files.direct_roc_files!(directory)? {
					relative = "examples/${Script.file_name(directory)?}/${Script.file_name(file)?}"
					source = Path.read_utf8!(file)?
					expected = if (Headers.is_app(source)) Headers.with_dependency(source, Release.shorthand, unpacked.url)? else source
					if Path.read_utf8!(Path.join(unpacked.root, relative))? != expected {
						return Script.fail!("the archived ${relative} differs by more than its package dependency")
					}
				}
			}
			Script.pass!("archived examples differ from the repository's only in the package dependency")
		},
	)
}

check_site! = |roc| {
	Script.section!("Documentation site and docs archive")?
	Env.with_temp_dir!(
		|temporary| {
			Site.assemble!(roc, Path.join(temporary, "site"), "main", SkipReleaseDocs)?

			docs_root = Path.join(temporary, "docs")
			Site.docs!(roc, Path.join(docs_root, Release.dry_run_version))?
			first = DocsArchive.pack!(docs_root, Release.dry_run_version, Path.join(temporary, "first"))?
			second = DocsArchive.pack!(docs_root, Release.dry_run_version, Path.join(temporary, "second"))?
			if Path.read_bytes!(first)? != Path.read_bytes!(second)? {
				return Script.fail!("packing the same documentation twice gave different archives")
			}
			restored = Path.join(temporary, "restored")
			DocsArchive.restore!(first, Release.dry_run_version, restored)?
			Script.require_file!(Path.join(Path.join(restored, Release.dry_run_version), "index.html"))?
			Script.pass!("documentation archive is reproducible and restores")
		},
	)
}
