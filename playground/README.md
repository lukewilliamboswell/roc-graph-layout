# Signals playground

The playground source uses roc-signals for state, controlled inputs, layout
derivation, and SVG rendering. Layout computation remains in the pure
roc-graph-layout package; `LayoutDemo.roc` adapts graph data to its APIs and
preserves source ordering when consuming tree results.

The playground is not built or published at present. It depends on the
roc-signals `0.2.0-rc3` web platform, which does not compile on current Roc
nightlies, and returns to the site with a roc-signals release that does. The
browser test, `test_site.mjs`, is kept with it. The site build used to
download the matching `signals-examples.zip`, verify its published SHA-256
digest, and extract the three browser runtime modules the application needs:
`signals.mjs`, `wasm_memory_views.mjs` and `controlled_input_policy.mjs`.

## Verify the application

From the repository root, with a compiler roc-signals supports:

```sh
roc check playground/app.roc
roc test playground/app.roc --opt=interpreter
roc build playground/app.roc --target=x64musl --opt=size --output=playground-native
./playground-native playground/specs/initial.scm
./playground-native playground/specs/edits.scm
roc build playground/app.roc --opt=size --output=playground.wasm
```

Use `--opt=size` for browser builds. The dev backend has emitted Wasm that
fails validation; a successful compiler exit alone does not establish that a
browser can load the artifact.

The nine presets retain their individual drafts and settings while switching.
Layout is derived once from the active inputs and shared by the SVG preview,
error display, and returned-geometry inspector.

`playground.html` is the Signals mount page the site served the Wasm
from.
