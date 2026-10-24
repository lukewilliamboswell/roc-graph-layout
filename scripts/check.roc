#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	roc: "nightly-2026-10-23-18478ff",
}

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
	check_mermaid_package!(roc)?
	check_examples!(roc)?
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
	for directory in ["package", "package-mermaid", "examples", "benchmarks", "site", "playground", "tools"] {
		for file in Files.roc_sources!(Path.utf8(directory))? {
			if Headers.has_roc_pin(file.source) {
				return Script.fail!("${Path.display(file.path)}: remove the `roc:` header field")
			}
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
	roc.run!(["fmt", "--check", "package", "examples", "benchmarks", "site"])?
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

check_mermaid_package! = |roc| {
	Script.section!("Mermaid package")?
	roc.run!(["fmt", "--check", "package-mermaid", "tools/mermaid-oracle"])?
	roc.run!(["check", "package-mermaid/main.roc", "--no-cache"])?
	roc.run!(["test", "package-mermaid/main.roc", "--no-cache"])?
	roc.run!(["test", "package-mermaid/main.roc", "--opt=interpreter", "--no-cache"])?
	# Fuzz targets hold their contracts; the generated Oracle modules hold what
	# Mermaid did with each recorded case.
	for target in Files.direct_roc_files!("package-mermaid")? {
		name = Script.file_name(target)?
		if name.starts_with("fuzz_") or name.starts_with("Oracle") {
			roc.run!(["test", Path.to_os_str(target), "--no-cache"])?
		}
	}
	for tool in Files.direct_roc_files!("tools/mermaid-oracle")? {
		roc.run!(["check", Path.to_os_str(tool), "--no-cache"])?
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
