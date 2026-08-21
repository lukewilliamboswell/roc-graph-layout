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
roc build examples/node_editor/main.roc --output examples/node_editor/node-editor
./examples/node_editor/node-editor
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

The browser console records structured `[node-editor]` events for graph
actions, direction and route-style changes, connections, drags, server
responses, and failures. Run `await nodeEditorDebug.copy()` in the console to
copy a self-contained reproduction containing the workspace, draft positions,
display settings, and latest 200 events. Use `nodeEditorDebug.dump()` to inspect
it as JSON, or `nodeEditorDebug.clear()` before reproducing one interaction.

Dragging keeps an optimistic draft until the retained SSE stream delivers the
accepted revision. Drops are exact; arrangements are separate Layered, Force,
and Stress commands. Persisted edges name stable source and target ports, and
older database documents are upgraded when read. Final routes always come from
the Roc package; `geometry.js` provides only transient previews and SVG path
appearance.

Open `/routing-gallery` while the example is running for deterministic routing
fixtures showing the node clearance boxes used by the final router.

Run the browser-independent interaction geometry tests with:

```sh
node examples/node_editor/geometry.test.js
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

The web platform dependency is basic-webserver 0.16.0. `Datastar.roc`,
`DatastarMarkup.roc`, `DatastarSignals.roc`, `ElementId.roc`, `SignalName.roc`,
`Selector.roc`, `RoutePath.roc`, `InternalDatastarName.roc`, and the pinned
Datastar v1.0.2 browser bundle are vendored from that release's Datastar
example under the Universal Permissive License. They intentionally retain the
original flat module layout because it is part of the verified Roc module
boundary on the pinned compiler.
