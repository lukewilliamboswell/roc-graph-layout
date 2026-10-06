# Playground: unpin from nightly-2026-09-04-c125b82

The package, examples, and scripts moved to `nightly-2026-10-04-130536d`. The
browser playground did not, and is deliberately pinned to the older compiler.

## Where the old pin lives

- `playground/app.roc` — `roc: "nightly-2026-09-04-c125b82"`
- `playground/README.md` — names the required compiler
- `.github/workflows/release.yaml` — the second `setup-roc` step
  (`nightly-tag: nightly-2026-09-04-c125b82`) provides the playground compiler;
  the first step reads the package pin from `package/main.roc`.
  `scripts/build_site.py` receives them separately as `--roc` (package) and
  `--playground-roc`.

## Why it is pinned

`roc check playground/app.roc` on `nightly-2026-10-04-130536d` reports
39 errors and 6 warnings, none in this repository:

- roc-signals `0.2.0-rc3` (`Ui.roc`, `Svg.roc`, `Signal.roc`, `Rows.roc`, ...):
  `redundant expose` errors, e.g. `import Signal exposing [Signal]`, because a
  type module's own type is now exposed automatically.
- `rvn` (`roc-rvn-v1.0.0-rc.2` from cdn.jasperwoudenberg.com) `Parser.roc`:
  `redundant open tag union` warnings.
- `playground/app.roc` itself has the same redundant exposes (lines importing
  `Elem`, `Signal`).

The same class of error hit roc-fuzz, basic-cli, and basic-webserver; their
newer releases fixed it (roc-fuzz 0.4.3, basic-cli 0.24.0, basic-webserver
0.17.0).

## Blockers

1. A roc-signals release newer than `0.2.0-rc3` that compiles on the new
   compiler. None exists as of 2026-10-06.
2. An `rvn` release that drops the redundant open tag unions (warnings only,
   but warnings make `roc check` exit non-zero in our scripts).

## Unpin checklist

1. Bump roc-signals and rvn URLs in `playground/app.roc`.
2. Remove the redundant `exposing [...]` entries in `playground/` and
   `examples/data` if the compiler flags them.
3. Set the compiler to the package nightly in `playground/app.roc` and
   `playground/README.md`.
4. `roc check playground/app.roc` reports zero errors and zero warnings.
5. `python3 scripts/build_site.py --roc "$(command -v roc)" --playground-roc "$(command -v roc)" --output /tmp/site --version test`
   then `node scripts/test_site.mjs`.
6. In `release.yaml`, delete the second `setup-roc` step and pass the package
   compiler for both `--roc` and `--playground-roc`.
7. Delete this file.
