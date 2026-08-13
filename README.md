# roc-graph-layout

A Roc package for deterministic, renderer-independent graph layout. It returns
node positions, edge routes, and drawing bounds without choosing how they are
rendered. Positions are node centers; routes are straight lines, polylines, or
chains of smooth cubic curves, and their endpoints attach to node box
boundaries so arrowheads land on the box.

The supported end-to-end layouts:

- `Layered` — directed flows such as dependencies, pipelines, and process
  diagrams, with orientation-preserving cycle handling, exact layer
  assignment, and balanced coordinates; `Layered.layout_exact` swaps the
  crossing-reduction heuristic for an effort-capped exact search that reports
  whether optimality was proven.
- `Tree` — input that is already a hierarchy, drawn level by level
  (`Tree.layout`) or radially with the root at the center
  (`Tree.layout_radial`).
- `Graph` — any sized graph: `layout_circular` (a ring, neighbors seated
  together), `layout_force` (organic clusters from a seeded simulation), and
  `layout_stress` (drawn distances track graph distances). The `ForceLayout`
  and `StressLayout` modules add reusable preparation, position hints, and
  pinned nodes; `RadialLayout` draws concentric rings by depth from a root.
- `Constrained` — stress layout subject to domain rules: minimum separation
  along an axis, alignment, and containment bands.

Placement-independent passes compose with any layout: `Pack` (shelf packing
for forests and disconnected components), `Overlap` (minimal-movement overlap
removal), and `Metrics` (crossings, bends, stress, separation violations, and
displacement, for comparing layouts by measurement).

## Example

```roc
nodes = [
    { width: 90, height: 40 },
    { width: 90, height: 40 },
]
edges = [{ from: 0, to: 1 }]

input = { ..Layered.default_input, graph: { nodes, edges } }
settings = { ..Layered.default_settings, node_gap: 24, layer_gap: 70 }

result = Layered.layout(input, settings, Layered.default_run)?

# result.layout.positions lines up with nodes
# result.layout.routes lines up with edges
# result.layout.bounds encloses the drawing
```

See the [build-pipeline example](examples/build_pipeline/main.roc) for a
complete program that writes the result as SVG, the
[org-chart example](examples/org_chart/main.roc) for a level-by-level tree,
the [mind-map example](examples/mind_map/main.roc) for a radial tree, the
[service-ring example](examples/service_ring/main.roc) for a circular graph,
and the [collab-network example](examples/collab_network/main.roc) for a
force-directed graph with a disconnected component.

For repeated layouts of the same input and settings, use `Layered.prepare` once
and pass the result to `Layered.layout_prepared` with `Layered.default_run`.
Changed input must be prepared again.

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
