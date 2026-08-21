# Node Editor

This native example is a persisted, free-form node editor for exercising node
placement, explicit arrangement commands, named ports, and obstacle-aware
routing. Nodes can add, reorder, and name input and output ports, choose fixed
or automatic sides, and edit connection labels, colors, and label placement in the
inspector. Inputs accept one connection while outputs support deterministic
fan-out. Datastar owns server actions, HTML reconciliation, inspector updates,
status signals, and the retained workspace stream. One light-DOM custom element
owns only continuous canvas interactions such as dragging, resizing, selection,
connection previews, panning, and zooming.

```sh
cd examples/node_editor
roc build main.roc --output node-editor
./node-editor
```

This repository requires the compiler named in its root `.roc-version`. When
using the example-local npm workflow, `npm run build` verifies the compiler
before compiling. It uses `roc` from `PATH` by default, or the executable in
`ROC`:

```sh
ROC=/path/to/the/pinned/roc npm run build
```

Set `ROC_GRAPH_LAYOUT_NODE_EDITOR_DB` to choose another database path. The
default is `node_editor.db` in the process's current working directory. Nodes
store their dimensions as geometry input and can be resized between the
editor's documented bounds. Set `ROC_GRAPH_LAYOUT_NODE_EDITOR_PORT` to choose
another listening port; the interactive default is 8000 and the browser tests
use their own port 18080.

The browser files under `assets/` are served directly by the platform's native
static-file service and are not embedded in the Roc executable. Run from this
directory, or set `ROC_GRAPH_LAYOUT_NODE_EDITOR_ASSETS` to this example's root
directory (the directory containing `assets/` and `style.css`). CSS and
JavaScript edits therefore require only a browser reload, not another native
build. These demo assets use a `no_store` cache policy so every reload reads the
current files.
The editor follows the operating-system color preference by default and offers
persistent light and dark overrides from the toolbar.

The browser console records structured `[node-editor]` events for graph
actions, direction and route-style changes, connections, drags, server
responses, and failures. Run `await nodeEditorDebug.copy()` in the console to
copy a self-contained reproduction containing the workspace, draft positions,
display settings, and latest 200 events. Use `nodeEditorDebug.dump()` to inspect
it as JSON, or `nodeEditorDebug.clear()` before reproducing one interaction.

Dragging keeps an optimistic draft until the retained SSE stream delivers the
accepted revision. Drops are exact; arrangements are separate Layered, Force,
and Stress commands. Persisted edges name stable source and target ports, and
the stored document uses only the demo's current shape. Final routes always
come from the Roc package; `assets/geometry.js` provides only transient previews
and SVG path appearance.

Open `/routing-gallery` while the example is running for deterministic routing
fixtures showing the node clearance boxes used by the final router.

Run the browser-independent interaction geometry tests with:

```sh
node examples/node_editor/tests/geometry.test.js
```

The example also owns its browser integration suite. From this directory,
install its local development dependency, build the native server, and run:

```sh
npm install
npm run build
npm test
```

These tests verify exact drag persistence, inspector edits and reloads, the
serialized route clearance contract, and the deterministic routing gallery.
Failure artifacts stay under this example's `test-results` and
`playwright-report` directories.

The web platform dependency is basic-webserver 0.16.0. Datastar's reusable
names and route types are a local Roc package at `datastar/main.roc`; its
basic-webserver adapters live beside that package. The pinned Datastar v1.0.2
browser bundle is under `assets/vendor/`. These files are vendored from that
release's Datastar example under the Universal Permissive License.

The Roc application decodes browser input into the `Command`, `Direction`,
`Arrangement`, `EditorSignals`, and `Selection` nominal type modules. Direction
and arrangement are closed tag unions with custom JSON `parser_for` and
`encoder_for` methods, so their wire-format strings do not leak into layout
logic. The persisted `Document`, `Node`, `Edge`, and `Port` values are nominal
types in `main.roc`; their associated methods form the application boundary
while larger layout and rendering helpers remain private to the application
module.
