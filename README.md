# roc-graph-layout

A Roc package for graph layout algorithms. Early scaffold — API not yet designed.

Currently exposes a single placeholder module, `Foo`, to validate the package
structure and CI. Real modules will replace it as the layout algorithms take
shape.

## Tasks

Local scripting is done with small [basic-cli](https://github.com/roc-lang/basic-cli)
apps in `scripts/`, each runnable directly (via shebang) or through `roc`:

```sh
./scripts/check.roc
./scripts/test.roc
./scripts/bundle.roc [DIR]   # default DIR is dist
./scripts/all.roc            # check, test, then bundle
```

Shared subcommand logic and helpers (running `roc`, reading `.roc-version`,
etc.) live in `scripts/Tasks.roc` and are imported by each task script. Add
new tasks (e.g. `fuzz.roc`) the same way: a tiny app that imports `Tasks` and
calls into it, or adds a new function there.

Set `ROC=/path/to/roc` if `roc` isn't already on your `PATH`.
