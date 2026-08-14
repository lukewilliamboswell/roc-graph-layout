# Playground build

The GitHub Pages release site serves the checked-in `www/app.wasm` and
`www/runtime.js`. They are vendored temporarily because Roc
`nightly-2026-08-13-2fdd90e` needs the Wasm Boxy runtime-linking fix from Roc
commit `4de66456239fa70c8ce887b00d273586d46ae627` to build this app with
`--opt=dev`.

Eight examples are interactive in this artifact. Compound is omitted because
calling `Compound.layout` makes this pinned dev backend emit an invalid Wasm
function (`expected i64, found i32`). The LLVM backend cannot compile the
combined app within the available memory. Re-enable the `layout.Compound`
import and `run_compound` implementation when a nightly fixes that code
generation bug.

The app uses the matching Joy fork bundle:

`EF5SoS3kKaYNmGUYjwb3wt722A4TbyaJ4NxJbBYpL2W5.tar.zst`

Build that bundle from the Joy fork after removing the host's `__multi3`
definition, which the pinned Roc dev builtins now provide. The matching Joy
runtime supplies the dev backend's remaining `fmod`, `fmodf`, and 128-bit shift
imports. Serve the archive locally so Roc treats it like a released package:

```sh
cd /path/to/joy/dist
python3 -m http.server 8765 --bind 127.0.0.1
```

Temporarily point `pf` in `app.roc` at the localhost archive, then build with
the patched compiler:

```sh
/path/to/patched/roc build --opt=dev --target=wasm32 --no-cache \
  --output=playground/www/app.wasm playground/app.roc
```

Copy `www/runtime.js` from the same Joy bundle. Restore the release URL in
`app.roc` before committing. The currently vendored files have these SHA-256
digests:

```text
5bde2f4f4fee9cb860dd64b24d4de624ced8253d684934d9a8e5f89ccb24d493  app.wasm
f122f8eb69159b3a9273f84e2d5fcd3d56833c4b5fcedd8571e4f6905b36e0ba  runtime.js
```

Once a published Roc nightly includes the runtime-linking fix, regenerate the
files with `roc playground/build.roc` and re-enable that build in CI.
