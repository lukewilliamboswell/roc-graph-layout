# Development environment and tasks for roc-graph-layout, realised by
# roc-blueprint without Nix.
#
#     blueprint run check    # everything CI checks
#     blueprint run site     # build the documentation site into dist/site
#     blueprint run serve    # build the site and preview it locally
#     blueprint shell        # the environment, to run scripts/*.roc directly
#     blueprint update       # refresh Blueprint.lock
#
# Two compilers are in play and are not interchangeable. `roc-stable` is the
# release named below; it runs the scripts under scripts/. The package, its
# examples, the site and the benchmarks are built with whatever `roc` is on
# PATH, which is meant to be the latest nightly, so nothing here provides a
# bare `roc`.
app [config] { pf: platform "https://github.com/lukewilliamboswell/roc-blueprint/releases/download/0.8.0/FbJymjYdCxx9vqMcau7r4tQfeAbnVGqqJoYrLGqPCqKu.tar.zst" }

import pf.Config
import pf.Recipes
import pf.System

config = [
	Name("roc-graph-layout"),
	Systems(["x86_64-linux", "aarch64-linux", "aarch64-darwin"]),
	Environment(
		"dev",
		[
			Programs(
				[
					Fetch("roc-stable", Recipes.roc_nightly("nightly-2026-10-23-18478ff")),
					# Builds the benchmark platform's host library.
					Fetch("zig", zig),
				],
			),
			# Every bundle the scripts depend on, including dependencies of
			# dependencies: `roc-stable deps scripts/check.roc` lists them.
			RocPackages(
				[
					"https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
				],
			),
			# Programs the scripts start, beside the package compiler `roc`.
			Expect(["chmod", "gh", "git", "roc", "shasum", "tar", "test", "touch", "unzip", "zip", "zstd"]),
		],
	),
	Shell("default", [Use("dev")]),
	# Everything CI checks: compiler pins, scripts, package tests, fuzz
	# targets, examples, benchmark smoke, release artifacts and the site.
	Task("check", [Use("dev"), Run(["scripts/check.roc"])]),
	# Run the examples and compare them with tests/examples.json. Pass
	# `-- --update` to record their current output instead.
	Task("examples", [Use("dev"), Run(["scripts/examples.roc", "--"])]),
	# Release steps: each reads RELEASE_VERSION, and writes into dist/.
	Task("check-version", [Use("dev"), Run(["scripts/check_version.roc"])]),
	Task("bundle", [Use("dev"), Run(["scripts/bundle.roc"])]),
	Task("package-examples", [Use("dev"), Run(["scripts/package_examples.roc"])]),
	Task("test-bundle", [Use("dev"), Run(["scripts/test_bundle.roc"])]),
	Task("package-docs", [Use("dev"), Run(["scripts/package_docs.roc"])]),
	Task("release-notes", [Use("dev"), Run(["scripts/release_notes.roc"])]),
	# The guides and API reference, into SITE_OUTPUT or dist/site.
	Task("site", [Use("dev"), Run(["scripts/site.roc"])]),
	Task("serve", [Use("dev"), Run(["scripts/serve.roc"])]),
	# Native optimized benchmarks: `-- smoke`, `-- scale` or
	# `-- compare <baseline-dir> <candidate-dir>`, each with `--output <dir>`.
	# The script's own `--` keeps Roc from reading its options.
	Task("bench", [Use("dev"), Run(["scripts/bench.roc", "--"])]),
	Task("tooling-version", [Use("dev"), Run(["roc-stable", "version"])]),
]

# Zig 0.16.0, kept whole because `zig` finds its standard library beside it.
zig : System -> Config.Download
zig = |system| {
	{ arch, os } = match system {
		"x86_64-linux" => { arch: "x86_64", os: "linux" }
		"aarch64-linux" => { arch: "aarch64", os: "linux" }
		"aarch64-darwin" => { arch: "aarch64", os: "macos" }
		_ => return Unavailable
	}
	top = "zig-${arch}-${os}-0.16.0"
	Archive("https://ziglang.org/download/0.16.0/${top}.tar.xz", TarXz, "${top}/zig")
}
