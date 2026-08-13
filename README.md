# roc-graph-layout

A Roc package for deterministic, renderer-independent graph layout algorithms.
The API is an early executable scaffold based on [`design.md`](design.md).

The package currently exposes naive deterministic baselines for the four layout
families: `Tree.tidy`, `Layered.sweep`, `Graph.force`, and
`Constrained.stress`. The remaining algorithm names and the shared compound,
packing, overlap, routing, and metrics layers are scaffolded with implementation
plans in their module documentation. These APIs are intentionally provisional;
the TODOs describe the path to the build/run witness contract in the design.

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
