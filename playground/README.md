# Signals playground

The playground source uses roc-signals for state, controlled inputs, layout
derivation, and SVG rendering. Layout computation remains in the pure
roc-graph-layout package; `LayoutDemo.roc` adapts graph data to its APIs and
preserves source ordering when consuming tree results.

The application pins the published roc-signals `0.2.0-rc3` web platform and its
required Roc compiler, `nightly-2026-09-04-c125b82`. The site builder downloads
the matching `signals-examples.zip`, verifies its published SHA-256 digest, and
extracts only the three browser runtime modules the application needs.

## Verify the application

From the repository root, using the compiler named in `app.roc`:

```sh
roc check playground/app.roc
roc test playground/app.roc --opt=interpreter
roc build playground/app.roc --target=x64musl --opt=size --output=playground-native
./playground-native playground/specs/initial.scm
./playground-native playground/specs/edits.scm
roc build playground/app.roc --opt=size --output=playground.wasm
```

Use `--opt=size` for browser builds. The pinned compiler's dev backend emits
Wasm that fails validation; a successful compiler exit alone does not establish
that a browser can load the artifact.

The nine presets retain their individual drafts and settings while switching.
Layout is derived once from the active inputs and shared by the SVG preview,
error display, and returned-geometry inspector.

The integrated site build produces the Signals mount page, Wasm, and matching
runtime modules (`signals.mjs`, `wasm_memory_views.mjs`, and
`controlled_input_policy.mjs`). Static guides are generated separately by the
released basic-ssg platform under `site/`.
