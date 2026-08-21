## Datastar-driven free-form node editor showcasing layout and routing.
## scripts: service
app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.16.0/42jC1JT3auhHSmv2Ah8mW5F2MXiAakq1UQQ4NQceQjXw.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	layout: "../../package/main.roc",
	ds: "./datastar/main.roc",
	roc: "nightly-2026-08-13-2fdd90e",
}

import ./datastar/Datastar
import ./datastar/DatastarMarkup
import ./Command
import ./Document
import pf.Attribute
import pf.Env
import pf.Html
import pf.Path
import pf.Server
import pf.Sqlite
import pf.Sse
import http.Response
import layout.Geom
import layout.Route

Context : Sqlite.Db

## Application transport and rendering types
Role : Document.Role

Side : Document.Side

PortPlacement : Document.PortPlacement

Arrangement : Document.Arrangement

Direction : Document.Direction

EdgeLabelPlacement : Document.EdgeLabelPlacement

Port : Document.Port

Node : Document.Node

Edge : Document.Edge

Guide : Document.Guide

RouteView : Document.RouteView

View : Document.View

Change : Document.Change

StoredWorkspace : { revision : I64, document : Str }

Signals : { revision : I64, operationId : Str, commandKind : Str, commandPayload : Str, selectedIds : Str, selectedEdgeIds : Str, pending : Bool, status : Str, routeStyle : Str, showLayers : Bool, direction : Str, serverAlive : Bool, acceptedRevision : U64, acceptedOperationId : Str }

Selection : { nodes : List(U64), edges : List(U64) }

StreamState : { revision : I64, signal_revision : I64, ticks : U64 }

program = { init!, respond!, shutdown! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64), InitFailed(Str), ..])
init! = || {
	db_path = match Env.var!("ROC_GRAPH_LAYOUT_NODE_EDITOR_DB") {
		Ok(value) => Path.from_os_str(value)
		Err(_) => Path.utf8("./node_editor.db")
	}
	db = Sqlite.open!(Sqlite.default_config(db_path)) ? |err| InitFailed(Str.inspect(err))
	Sqlite.execute!({ db, query: "CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL, document TEXT NOT NULL);", params: {} }) ? |err| InitFailed(Str.inspect(err))
	initial_json = Document.initial.to_json() ? |err| InitFailed(Str.inspect(err))
	Sqlite.execute!({ db, query: "INSERT OR IGNORE INTO workspace (id, revision, document) VALUES (1, 0, :document);", params: { document: initial_json } }) ? |err| InitFailed(Str.inspect(err))
	port = match Env.var_str!("ROC_GRAPH_LAYOUT_NODE_EDITOR_PORT") {
		Ok(value) => U16.from_str(value) ? |_| InitFailed("ROC_GRAPH_LAYOUT_NODE_EDITOR_PORT must be an integer from 0 through 65535.")
		Err(_) => 8000
	}
	asset_path = match Env.var!("ROC_GRAPH_LAYOUT_NODE_EDITOR_ASSETS") {
		Ok(value) => Path.from_os_str(value)
		Err(_) => Path.utf8(".")
	}
	assets = Server.file_root_with_cache({ id: "node_editor_assets", path: asset_path, cache: Server.no_store })
	index = Server.relative_file("assets/index.html").map_err(|_| InitFailed("The index asset path is invalid."))?
	styles = Server.relative_file("style.css").map_err(|_| InitFailed("The stylesheet asset path is invalid."))?
	datastar = Server.relative_file("assets/vendor/datastar-v1.0.2.js").map_err(|_| InitFailed("The Datastar asset path is invalid."))?
	geometry = Server.relative_file("assets/geometry.js").map_err(|_| InitFailed("The geometry asset path is invalid."))?
	canvas = Server.relative_file("assets/node-editor-canvas.js").map_err(|_| InitFailed("The canvas asset path is invalid."))?
	config =
		Server.with_request_body_limit(Server.default_config, Datastar.default_signals_limit_bytes)
			.with_listen({ host: "127.0.0.1", port })
			.with_file_roots([assets])
			.with_native_routes({
				files: [
					Server.static_file({ at: "/", files: assets, relative: index }),
					Server.static_file({ at: "/style.css", files: assets, relative: styles }),
					Server.static_file({ at: "/datastar.js", files: assets, relative: datastar }),
					Server.static_file({ at: "/geometry.js", files: assets, relative: geometry }),
					Server.static_file({ at: "/node-editor-canvas.js", files: assets, relative: canvas }),
				],
				liveness: [],
				readiness: [],
			})
	Ok({ config, context: db })
}

respond! : Server.Request, Context => Try(Server.Outcome, [ServerErr(Str), ..])
respond! = |request, db| {
	path = request_path(request)
	match (request.method(), path) {
		(GET, "/health") => Ok(Server.respond(text_response(200, "ok")))
		(GET, "/routing-gallery") => Ok(Server.respond(bytes_response(200, "text/html; charset=utf-8", Str.to_utf8(routing_gallery()))))
		(GET, "/updates") => Ok(Server.stream(Sse.unfold!({ revision: -1, signal_revision: -1, ticks: 0 }, |state| stream_step!(db, state))))
		(GET, "/inspector") => inspector!(db, request)
		(POST, "/actions") => action!(db, request)
		_ => Ok(Server.respond(text_response(404, "Not found")))
	}
}

request_path : Server.Request -> Str
request_path = |request| match request.target() {
	Resource({ raw_path, .. }) => raw_path
	_ => ""
}

## Persistence and request handlers

load! : Sqlite.Db => Try(StoredWorkspace, _)
load! = |db| Sqlite.query!({ db, query: "SELECT revision, document FROM workspace WHERE id = 1;", params: {}, limits: Sqlite.default_query_limits })

stream_step! : Sqlite.Db, StreamState => Try(Sse.Step(StreamState), [StreamFailed(Str)])
stream_step! = |db, state| {
	if state.signal_revision >= 0 {
		revision = state.signal_revision
		return Ok(Emit({ event: Datastar.patch_signals("{\"revision\":${revision.to_str()},\"pending\":false,\"serverAlive\":true,\"status\":\"Revision ${revision.to_str()} synchronized.\"}"), state: { revision, signal_revision: -1, ticks: 0 }, wake: Immediately }))
	}
	stored : StoredWorkspace
	stored = load!(db) ? |err| StreamFailed(Str.inspect(err))
	if stored.revision != state.revision {
		document = Document.decode(stored.document) ? |_| StreamFailed("Stored workspace is invalid")
		view = document.view(stored.revision, "Workspace synchronized.")
		Ok(Emit({ event: DatastarMarkup.patch_elements(workspace_fragment(view)), state: { revision: state.revision, signal_revision: stored.revision, ticks: 0 }, wake: Immediately }))
	} else if state.ticks >= 150 {
		Ok(Emit({ event: Datastar.patch_signals("{\"serverAlive\":true}"), state: { ..state, ticks: 0 }, wake: After(100) }))
	} else {
		Ok(Wait({ state: { ..state, ticks: state.ticks + 1 }, wake: After(100) }))
	}
}

action! : Sqlite.Db, Server.Request => Try(Server.Outcome, [ServerErr(Str), ..])
action! = |db, request| {
	signals : Signals
	signals = match Datastar.read_signals!(request) {
		Ok(value) => value
		Err(err) => return Ok(Server.respond(text_response(400, "Invalid Datastar signals: ${Str.inspect(err)}")))
	}
	command = match Command.from_browser(signals.commandKind, signals.commandPayload) {
		Ok(value) => value
		Err(_) => return Ok(Datastar.respond([signal_event(Bool.False, "The command payload was invalid.")]))
	}
	tx = Sqlite.begin!(db, Immediate) ? |err| ServerErr(Str.inspect(err))
	stored : StoredWorkspace
	stored = tx.query!({ query: "SELECT revision, document FROM workspace WHERE id = 1;", params: {}, limits: Sqlite.default_query_limits }) ? |err| ServerErr(Str.inspect(err))
	if stored.revision != signals.revision {
		tx.commit!() ? |err| ServerErr(Str.inspect(err))
		return Ok(Datastar.respond([Datastar.patch_signals("{\"pending\":false,\"revision\":${stored.revision.to_str()},\"status\":\"A newer workspace revision is available.\"}")]))
	}
	document = match Document.decode(stored.document) {
		Ok(value) => value
		Err(_) => return Ok(Datastar.respond([signal_event(Bool.False, "The stored workspace is invalid.")]))
	}
	changed = document.apply(command)
	if !changed.accepted {
		tx.commit!() ? |err| ServerErr(Str.inspect(err))
		return Ok(Datastar.respond([signal_event(Bool.False, changed.message)]))
	}
	json = changed.document.to_json() ? |err| ServerErr(Str.inspect(err))
	updated : StoredWorkspace
	updated = tx.query!({ query: "UPDATE workspace SET revision = revision + 1, document = :document WHERE id = 1 AND revision = :revision RETURNING revision, document;", params: { document: json, revision: stored.revision }, limits: Sqlite.default_query_limits }) ? |err| ServerErr(Str.inspect(err))
	tx.commit!() ? |err| ServerErr(Str.inspect(err))
	selection = selection_from_signals(signals)
	Ok(Datastar.respond([Datastar.patch_signals("{\"revision\":${updated.revision.to_str()},\"pending\":false,\"status\":${Json.to_str(changed.message)},\"acceptedRevision\":${updated.revision.to_str()},\"acceptedOperationId\":${Json.to_str(signals.operationId)}}"), DatastarMarkup.patch_elements(inspector_fragment(changed.document, selection.nodes, selection.edges))]))
}

signal_event : Bool, Str -> Sse.Event
signal_event = |pending, status| Datastar.patch_signals("{\"pending\":${Json.to_str(pending)},\"status\":${Json.to_str(status)}}")

inspector! : Sqlite.Db, Server.Request => Try(Server.Outcome, [ServerErr(Str), ..])
inspector! = |db, request| {
	signals : Signals
	signals = match Datastar.read_signals!(request) {
		Ok(value) => value
		Err(err) => return Ok(Server.respond(text_response(400, "Invalid Datastar signals: ${Str.inspect(err)}")))
	}
	selection = selection_from_signals(signals)
	stored : StoredWorkspace
	stored = load!(db) ? |err| ServerErr(Str.inspect(err))
	document = match Document.decode(stored.document) {
		Ok(value) => value
		Err(_) => return Ok(Server.respond(text_response(500, "Stored workspace is invalid")))
	}
	Ok(Datastar.respond([DatastarMarkup.patch_elements(inspector_fragment(document, selection.nodes, selection.edges))]))
}

selection_from_signals : Signals -> Selection
selection_from_signals = |signals| {
	nodes: Json.parse(signals.selectedIds) ?? [],
	edges: Json.parse(signals.selectedEdgeIds) ?? [],
}

## Editor HTML

workspace_fragment : View -> Html.Fragment
workspace_fragment = |view| Html.render_fragment([
	Html.span([Attribute.id("status"), Attribute.attribute("data-text", "$status")], [Html.text("Revision ${view.revision.to_str()} · ${view.message}")]),
	Html.div(
		[Attribute.id("workspace"), Attribute.attribute("data-revision", view.revision.to_str()), Attribute.attribute("data-signals", "{\"revision\":${view.revision.to_str()}}"), Attribute.attribute("data-document", document_json(view.document))],
		[
			Html.element(
				"node-editor-canvas",
				[
					Attribute.id("editor-canvas"),
					Attribute.attribute("data-arrangement", Document.arrangement_text(view.document.arrangement)),
					Attribute.attribute("data-direction", Document.direction_text(view.document.direction)),
					Attribute.attribute("data-layers", Json.to_str(view.document.layers)),
					Attribute.attribute("data-on:node-editor-command", "$operationId=evt.detail.operationId;$commandKind=evt.detail.kind;$commandPayload=JSON.stringify(evt.detail.payload);$pending=true;@post('/actions')"),
					Attribute.attribute("data-on:node-editor-selection", "$selectedIds=JSON.stringify(evt.detail.ids);$selectedEdgeIds=JSON.stringify(evt.detail.edges);@get('/inspector')"),
				],
				[
					Html.div([Attribute.id("layers"), Attribute.class("layers")], []),
					Html.element("svg", [Attribute.id("routes"), Attribute.attribute("aria-hidden", "true")], [arrow_defs].concat(view.routes.map(route_node))),
					Html.div([Attribute.id("nodes"), Attribute.class("nodes")], view.document.nodes.map(node_node)),
					Html.div([Attribute.class("selection-box"), Attribute.attribute("hidden", "")], []),
				],
			),
		],
	),
])

node_node : Node -> Html.Node
node_node = |node| Html.element(
	"article",
	[
		Attribute.id("node-${node.id.to_str()}"),
		Attribute.class("node"),
		Attribute.attribute("tabindex", "0"),
		Attribute.attribute("data-node-id", node.id.to_str()),
		Attribute.attribute("data-x", node.x.to_str()),
		Attribute.attribute("data-y", node.y.to_str()),
		Attribute.attribute("data-width", node.width.to_str()),
		Attribute.attribute("data-height", node.height.to_str()),
		Attribute.style("left:${node.x.to_str()}px;top:${node.y.to_str()}px;width:${node.width.to_str()}px;height:${node.height.to_str()}px"),
	],
	[
		Html.div([Attribute.class("node-title")], [Html.text(node.label)]),
		Html.div([Attribute.class("ports")], node.ports.map(port_node)),
		Html.div([Attribute.class("resize-handle"), Attribute.attribute("data-resize-node", "")], []),
	],
)

port_node : Port -> Html.Node
port_node = |port| {
	position = match port.resolved_side {
		Top | Bottom => "left:${(port.offset * 100).to_str()}%"
		_ => "top:${(port.offset * 100).to_str()}%"
	}
	role = Document.role_text(port.role)
	resolved_side = Document.side_text(port.resolved_side)
	placement = Document.port_placement_text(port.side)
	Html.button(
		[
			Attribute.class("port ${role} ${resolved_side}"),
			Attribute.attribute("data-port-id", port.id),
			Attribute.attribute("data-role", role),
			Attribute.attribute("data-side", resolved_side),
			Attribute.attribute("data-side-mode", placement),
			Attribute.attribute("data-offset", port.offset.to_str()),
			Attribute.attribute("title", "${port.label} · ${role}"),
			Attribute.attribute("aria-label", "${port.label}, ${role} port"),
			Attribute.style(position),
		],
		[
			Html.span(
				[Attribute.class("port-mark")],
				[
					Html.text(
						port.label,
					),
				],
			),
			Html.span(
				[Attribute.class("port-label")],
				[
					Html.text(
						if port.role == Input {
							"Input"
						} else {
							"Output"
						},
					),
				],
			),
		],
	)
}

route_node : RouteView -> Html.Node
route_node = |route| {
	path_attributes = [
		Attribute.attribute("data-edge-id", route.edge.to_str()),
		Attribute.attribute("data-from", route.from.to_str()),
		Attribute.attribute("data-to", route.to.to_str()),
		Attribute.attribute("data-source-port", route.source_port),
		Attribute.attribute("data-target-port", route.target_port),
		Attribute.attribute("data-points", points_json(route.points)),
		Attribute.attribute("d", angular_path(route.points)),
	]
	label = if route.label.is_empty() {
		[]
	} else {
		[
			Html.element("rect", [Attribute.class("edge-label-box"), Attribute.attribute("x", (route.label_anchor.x - route.label_width / 2).to_str()), Attribute.attribute("y", (route.label_anchor.y - route.label_height / 2).to_str()), Attribute.attribute("width", route.label_width.to_str()), Attribute.attribute("height", route.label_height.to_str()), Attribute.attribute("rx", "5")], []),
			Html.element("text", [Attribute.class("edge-label-text"), Attribute.attribute("x", route.label_anchor.x.to_str()), Attribute.attribute("y", (route.label_anchor.y + 4).to_str()), Attribute.attribute("text-anchor", "middle")], [Html.text(route.label)]),
		]
	}
	Html.element(
		"g",
		[Attribute.id("edge-${route.edge.to_str()}"), Attribute.class("edge"), Attribute.attribute("data-edge-id", route.edge.to_str()), Attribute.style("--edge-color:${route.color}")],
		[Html.element("path", path_attributes.concat([Attribute.class("route-hit")]), []), Html.element("path", path_attributes.concat([Attribute.class("route"), Attribute.attribute("marker-end", "url(#route-arrow)")]), [])].concat(label),
	)
}

arrow_defs = Html.element(
	"defs",
	[],
	[Html.element("marker", [Attribute.id("route-arrow"), Attribute.attribute("viewBox", "0 0 12 12"), Attribute.attribute("refX", "11"), Attribute.attribute("refY", "6"), Attribute.attribute("markerWidth", "8"), Attribute.attribute("markerHeight", "8"), Attribute.attribute("orient", "auto"), Attribute.attribute("markerUnits", "strokeWidth")], [Html.element("path", [Attribute.attribute("d", "M 1 1 L 11 6 L 1 11 z"), Attribute.attribute("fill", "context-stroke")], [])])],
)

document_json : Document -> Str
document_json = |document| document.to_json() ?? "{}"

points_json : List(Geom.Point) -> Str
points_json = |points| match Json.to_str_try(points) {
	Ok(value) => value
	Err(_) => "[]"
}

angular_path : List(Geom.Point) -> Str
angular_path = |points| match points {
	[] => ""
	[first, .. as rest] => rest.fold("M ${first.x.to_str()} ${first.y.to_str()}", |path, point| "${path} L ${point.x.to_str()} ${point.y.to_str()}")
}

option_node = |value, label, selected| Html.element(
	"option",
	[Attribute.attribute("value", value)].concat(
		if selected {
			[Attribute.attribute("selected", "")]
		} else {
			[]
		},
	),
	[Html.text(label)],
)

port_inspector = |document, node, port, index| {
	used = Document.port_connection_count(document, node.id, port.id) > 0
	role_attributes = [Attribute.attribute("data-port-role", ""), Attribute.attribute("aria-label", "Port role")].concat(
		if used {
			[Attribute.attribute("disabled", "")]
		} else {
			[]
		},
	)
	controls = [
		Html.input([Attribute.attribute("value", port.label), Attribute.attribute("data-port-label", ""), Attribute.attribute("aria-label", "Port label"), Attribute.attribute("maxlength", "64")]),
		Html.element("select", role_attributes, [option_node("input", "Input", port.role == Input), option_node("output", "Output", port.role == Output)]),
		Html.element("select", [Attribute.attribute("data-port-side", ""), Attribute.attribute("aria-label", "Port side")], [option_node("auto", "Automatic", port.side == Automatic), option_node("top", "Top", port.side == Top), option_node("right", "Right", port.side == Right), option_node("bottom", "Bottom", port.side == Bottom), option_node("left", "Left", port.side == Left)]),
	]
	auto_controls = if port.side == Automatic {
		[Html.span([Attribute.class("port-resolution")], [Html.text("Locked to ${Document.side_text(port.resolved_side)}")]), Html.button([Attribute.attribute("data-reevaluate-port", ""), Attribute.attribute("data-node", node.id.to_str()), Attribute.attribute("data-port", port.id)], [Html.text("Re-evaluate")])]
	} else {
		[]
	}
	move_controls = Html.div(
		[Attribute.class("port-order-actions")],
		[
			Html.button(
				[Attribute.class("small"), Attribute.attribute("data-move-port", "up"), Attribute.attribute("aria-label", "Move port up"), Attribute.attribute("title", "Move ${port.label} up")].concat(
					if index == 0 {
						[Attribute.attribute("disabled", "")]
					} else {
						[]
					},
				),
				[Html.text("↑")],
			),
			Html.button(
				[Attribute.class("small"), Attribute.attribute("data-move-port", "down"), Attribute.attribute("aria-label", "Move port down"), Attribute.attribute("title", "Move ${port.label} down")].concat(
					if index + 1 == node.ports.len() {
						[Attribute.attribute("disabled", "")]
					} else {
						[]
					},
				),
				[Html.text("↓")],
			),
		],
	)
	Html.li([Attribute.id("port-editor-${node.id.to_str()}-${port.id}"), Attribute.class("port-editor"), Attribute.attribute("data-node", node.id.to_str()), Attribute.attribute("data-port", port.id)], controls.concat(auto_controls).concat([move_controls, Html.button([Attribute.class("danger small"), Attribute.attribute("data-delete-port", "")], [Html.text("Delete port")])]))
}

edge_inspector = |edge| Html.div(
	[Attribute.class("edge-editor"), Attribute.attribute("data-edge", edge.id.to_str())],
	[
		Html.h2([], [Html.text("Connection ${edge.id.to_str()}")]),
		Html.label([], [Html.text("Label"), Html.input([Attribute.attribute("value", edge.label), Attribute.attribute("data-edge-label", ""), Attribute.attribute("maxlength", "120")])]),
		Html.label([], [Html.text("Color"), Html.input([Attribute.attribute("type", "color"), Attribute.attribute("value", edge.color), Attribute.attribute("data-edge-color", "")])]),
		Html.label([], [Html.text("Label position"), Html.element("select", [Attribute.attribute("data-edge-placement", "")], [option_node("center", "Center", edge.label_placement == Center), option_node("near-source", "Near source", edge.label_placement == NearSource), option_node("near-target", "Near target", edge.label_placement == NearTarget)])]),
		Html.p([Attribute.class("muted")], [Html.text("${edge.from.to_str()}:${edge.source_port} → ${edge.to.to_str()}:${edge.target_port}")]),
		Html.button([Attribute.class("danger"), Attribute.attribute("data-delete-edge", ""), Attribute.attribute("data-edge", edge.id.to_str())], [Html.text("Delete connection")]),
	],
)

inspector_fragment : Document, List(U64), List(U64) -> Html.Fragment
inspector_fragment = |document, selected, selected_edges| {
	nodes = document.nodes.keep_if(|node| selected.contains(node.id))
	edges = document.edges.keep_if(|edge| selected_edges.contains(edge.id))
	content = match (nodes, edges) {
		([], [edge]) => [edge_inspector(edge)]
		([], _) => [Html.p([], [Html.text("Select a node or connection to inspect and edit it.")])]
		([node], _) => [
			Html.h2([], [Html.text("Node ${node.id.to_str()}")]),
			Html.label([], [Html.text("Label"), Html.input([Attribute.attribute("value", node.label), Attribute.attribute("data-node-label", node.id.to_str()), Attribute.attribute("maxlength", "120")])]),
			Html.p([Attribute.class("muted")], [Html.text("${node.width.to_str()} × ${node.height.to_str()} at ${node.x.to_str()}, ${node.y.to_str()}")]),
			Html.h3([], [Html.text("Ports")]),
			Html.ul([Attribute.class("port-editors")], node.ports.map_with_index(|port, index| port_inspector(document, node, port, index))),
			Html.div([Attribute.class("add-port-actions")], [Html.button([Attribute.attribute("data-add-port", "input"), Attribute.attribute("data-node", node.id.to_str())], [Html.text("Add input")]), Html.button([Attribute.attribute("data-add-port", "output"), Attribute.attribute("data-node", node.id.to_str())], [Html.text("Add output")])]),
			Html.div([Attribute.class("destructive-actions")], [Html.button([Attribute.class("danger"), Attribute.attribute("data-delete-node", ""), Attribute.attribute("data-node", node.id.to_str())], [Html.text("Delete node")])]),
		]
		_ => [Html.h2([], [Html.text("${nodes.len().to_str()} nodes selected")]), Html.p([], [Html.text("Drag a selected node to move the selection.")])]
	}
	Html.render_fragment([Html.element("aside", [Attribute.id("inspector")], content)])
}

## Routing diagnostics gallery

gallery_points = |points| Str.join_with(points.map(|point| "${point.x.to_str()},${point.y.to_str()}"), " ")

gallery_route = |route| "<polyline class=\"gallery-route\" style=\"stroke:${route.color}\" points=\"${gallery_points(route.points)}\"/>"

gallery_node = |node| {
	x = node.x - node.width / 2
	y = node.y - node.height / 2
	inflated_x = x - Route.default_settings.obstacle_gap
	inflated_y = y - Route.default_settings.obstacle_gap
	inflated_width = node.width + Route.default_settings.obstacle_gap * 2
	inflated_height = node.height + Route.default_settings.obstacle_gap * 2
	"<rect class=\"gallery-obstacle\" x=\"${inflated_x.to_str()}\" y=\"${inflated_y.to_str()}\" width=\"${inflated_width.to_str()}\" height=\"${inflated_height.to_str()}\"/><rect class=\"gallery-node\" x=\"${x.to_str()}\" y=\"${y.to_str()}\" width=\"${node.width.to_str()}\" height=\"${node.height.to_str()}\" rx=\"10\"/><text x=\"${node.x.to_str()}\" y=\"${(node.y + 4).to_str()}\" text-anchor=\"middle\">${node.label}</text>"
}

gallery_metrics : List(RouteView) -> { bends : U64, length : F64 }
gallery_metrics = |routes| routes.fold(
	{ bends: 0.U64, length: 0.F64 },
	|total, route| {
		own = route.points.fold_with_index(
			{ bends: 0.U64, length: 0.F64 },
			|state, point, i| match route.points.get(i + 1) {
				Ok(next) => {
					bends: state.bends + if i > 0 {
						1
					} else {
						0
					},
					length: state.length + (next.x - point.x).abs() + (next.y - point.y).abs(),
				}
				Err(_) => state
			},
		)
		{ bends: total.bends + own.bends, length: total.length + own.length }
	},
)

gallery_card = |name, document| {
	view = Document.normalize(document).view(0, "")
	metrics = gallery_metrics(view.routes)
	markup = Str.join_with(view.document.nodes.map(gallery_node), "").concat(Str.join_with(view.routes.map(gallery_route), ""))
	"<article><header><h2>${name}</h2><span>${view.routes.len().to_str()} routes · ${metrics.bends.to_str()} bends · ${metrics.length.to_str()} px</span></header><svg viewBox=\"0 0 720 430\">${markup}</svg></article>"
}

gallery_document = |nodes, edges| {
	{ next_node_id: nodes.len() + 1, next_edge_id: edges.len() + 1, next_port_id: 1, direction: Down, arrangement: Free, layers: [], guides: [], nodes, edges }
}

gallery_edge = |id, from, to, source_port, target_port, color| { id, from, to, source_port, target_port, label: "", color, label_placement: Center, label_width: 0, label_height: 0 }

gallery_input_port : Port
gallery_input_port = { id: "in", label: "A", role: Input, side: Top, resolved_side: Top, offset: 0.5 }

gallery_output_port : Port
gallery_output_port = { id: "out", label: "B", role: Output, side: Bottom, resolved_side: Bottom, offset: 0.5 }

routing_gallery = || {
	shared_ports = gallery_document(
		[
			{ id: 1, label: "Request", x: 330, y: 70, width: 160, height: 64, ports: [gallery_output_port] },
			{ id: 2, label: "Review", x: 210, y: 310, width: 180, height: 72, ports: [gallery_input_port] },
			{ id: 3, label: "Archive", x: 500, y: 310, width: 160, height: 64, ports: [{ ..gallery_input_port, id: "in-2" }] },
		],
		[gallery_edge(1, 1, 2, "out", "in", "#7895dd"), gallery_edge(2, 1, 3, "out", "in-2", "#f3b36f")],
	)
	parallel = gallery_document(
		[
			{ id: 1, label: "Shared output", x: 300, y: 70, width: 180, height: 64, ports: [gallery_output_port] },
			{ id: 2, label: "Shared input", x: 300, y: 330, width: 220, height: 88, ports: [gallery_input_port] },
		],
		[gallery_edge(1, 1, 2, "out", "in", "#75d8b1"), gallery_edge(2, 1, 2, "out", "in", "#f3b36f")],
	)
	obstacle = gallery_document(
		[
			{ id: 1, label: "Start", x: 100, y: 210, width: 140, height: 64, ports: [{ ..gallery_output_port, side: Right, resolved_side: Right }] },
			{ id: 2, label: "Finish", x: 620, y: 210, width: 140, height: 64, ports: [{ ..gallery_input_port, side: Left, resolved_side: Left }] },
			{ id: 3, label: "Obstacle", x: 360, y: 210, width: 190, height: 120, ports: [] },
		],
		[gallery_edge(1, 1, 2, "out", "in", "#a88cff")],
	)
	cards = Str.join_with([gallery_card("Shared output fan", shared_ports), gallery_card("Parallel fixed ports", parallel), gallery_card("Obstacle clearance", obstacle)], "")
	"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Routing diagnostics</title><style>:root{color-scheme:dark;font:14px system-ui;background:#090e1b;color:#edf2ff}body{margin:0;padding:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:18px}article{border:1px solid #293657;border-radius:12px;background:#10182b;overflow:hidden}article header{display:flex;justify-content:space-between;align-items:baseline;padding:12px 16px}h1{margin-top:0}h2{font-size:15px;margin:0}span{color:#91a3ca;font-size:12px}svg{display:block;width:100%;background:#0c1426}.gallery-node{fill:#1d2b4c;stroke:#526da9}.gallery-obstacle{fill:none;stroke:#f3b36f55;stroke-dasharray:5 4}.gallery-route{fill:none;stroke-width:2}.gallery-node+text,text{fill:#edf2ff;font:12px system-ui}a{color:#9ebcff}</style></head><body><h1>Routing diagnostics</h1><p>Every dashed rectangle is the clearance boundary used by the final router. These fixtures are rendered directly from <code>Route.layout</code>.</p><p><a href=\"/\">Return to editor</a></p><main>${cards}</main></body></html>"
}

## HTTP responses and shutdown

bytes_response : U16, Str, List(U8) -> Response
bytes_response = |status, content_type, body| Response.from_status(status).with_headers([
	{ name: "Content-Type", value: content_type },
	{
		name: "Cache-Control",
		value: if content_type == "text/html; charset=utf-8" {
			"no-cache"
		} else {
			"public, max-age=3600"
		},
	},
]).with_body(body)

text_response : U16, Str -> Response
text_response = |status, body| bytes_response(status, "text/plain; charset=utf-8", Str.to_utf8(body))

shutdown! : Server.ShutdownReason, Context => Try({}, [Exit(I64), ..])
shutdown! = |_reason, _db| Ok({})
