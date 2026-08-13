# roc-graph-layout

A Roc package for deterministic, renderer-independent graph layout. It returns
node positions, edge routes, and drawing bounds without choosing how they are
rendered.

The currently supported end-to-end layout is `Layered`, for directed flows such
as dependencies, pipelines, and process diagrams.

## Example

```roc
nodes = [
    { width: 90, height: 40 },
    { width: 90, height: 40 },
]
edges = [{ from: 0, to: 1 }]

input = { ..Layered.default_input, graph: { nodes, edges } }
settings = { ..Layered.default_settings, node_gap: 24, layer_gap: 70 }

result = Layered.layout(input, settings)?

# result.layout.positions lines up with nodes
# result.layout.routes lines up with edges
# result.layout.bounds encloses the drawing
```

See the [build-pipeline example](examples/build_pipeline/main.roc) for a complete
program that writes the result as SVG.

For repeated layouts of the same input and settings, use `Layered.prepare` once
and pass the result to `Layered.layout_prepared`. Changed input must be prepared
again.

## Development

Run the project checks with:

```sh
./scripts/check.roc
./scripts/test.roc
./scripts/bundle.roc [DIR]   # default DIR is dist
./scripts/all.roc            # check, test, then bundle
```

CI uses the nightly pinned in `.roc-version`. Locally, scripts use `roc` on
your `PATH`, or the executable path in `ROC`; for example,
`ROC=../roc/target/release/roc ./scripts/all.roc`.
