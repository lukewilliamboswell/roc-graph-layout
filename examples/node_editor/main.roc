## Datastar-driven free-form node editor showcasing layout and routing.
app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.16.0/42jC1JT3auhHSmv2Ah8mW5F2MXiAakq1UQQ4NQceQjXw.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	layout: "../../package/main.roc",
	roc: "nightly-2026-08-13-2fdd90e",
}

import ./Datastar
import ./DatastarMarkup
import pf.Attribute
import pf.Env
import pf.Html
import pf.Path
import pf.Server
import pf.Sqlite
import pf.Sse
import http.Response
import layout.ForceLayout
import layout.Geom
import layout.Layered
import layout.Route
import layout.StressLayout

Context : Sqlite.Db

Port : { id : Str, label : Str, role : Str, side : Str, resolved_side : Str, offset : F64 }

Node : { id : U64, label : Str, x : F64, y : F64, width : F64, height : F64, ports : List(Port) }

Edge : { id : U64, from : U64, to : U64, source_port : Str, target_port : Str, label : Str, color : Str, label_placement : Str, label_width : F64, label_height : F64 }

Guide : { edge : U64, points : List(Geom.Point) }

Document : { schema_version : U64, next_node_id : U64, next_edge_id : U64, next_port_id : U64, direction : Str, arrangement : Str, layers : List(U64), guides : List(Guide), nodes : List(Node), edges : List(Edge) }

V2Port : { id : Str, label : Str, role : Str, side : Str, offset : F64 }

V2Node : { id : U64, label : Str, x : F64, y : F64, width : F64, height : F64, ports : List(V2Port) }

V2Edge : { id : U64, from : U64, to : U64, source_port : Str, target_port : Str }

V2Document : { next_node_id : U64, next_edge_id : U64, direction : Str, arrangement : Str, layers : List(U64), guides : List(Guide), nodes : List(V2Node), edges : List(V2Edge) }

LegacyNode : { id : U64, label : Str, x : F64, y : F64, placed : Bool, pinned : Bool }

LegacyDocument : { next_node_id : U64, next_edge_id : U64, direction : Str, nodes : List(LegacyNode), edges : List(V2Edge) }

StoredWorkspace : { revision : I64, document : Str }

Signals : { revision : I64, operationId : Str, commandKind : Str, commandPayload : Str, selectedIds : Str, selectedEdgeIds : Str, pending : Bool, status : Str, routeStyle : Str, showLayers : Bool, direction : Str, serverAlive : Bool, acceptedRevision : U64, acceptedOperationId : Str }

Payload : { node : U64, edge : U64, from : U64, to : U64, source_port : Str, target_port : Str, port_id : Str, role : Str, side : Str, color : Str, placement : Str, x : F64, y : F64, width : F64, height : F64, label_width : F64, label_height : F64, label : Str, algorithm : Str, direction : Str, document : Str }

RouteView : { edge : U64, from : U64, to : U64, source_port : Str, target_port : Str, points : List(Geom.Point), label : Str, color : Str, label_placement : Str, label_anchor : Geom.Point, label_width : F64, label_height : F64 }

View : { revision : I64, document : Document, routes : List(RouteView), message : Str }

StreamState : { revision : I64, signal_revision : I64, ticks : U64 }

input_port : Port
input_port = { id: "in", label: "A", role: "input", side: "top", resolved_side: "top", offset: 0.5 }

output_port : Port
output_port = { id: "out", label: "B", role: "output", side: "bottom", resolved_side: "bottom", offset: 0.5 }

initial_document : Document
initial_document = {
	schema_version: 4,
	next_node_id: 4,
	next_edge_id: 4,
	next_port_id: 1,
	direction: "down",
	arrangement: "free",
	layers: [],
	guides: [],
	nodes: [
		{ id: 1, label: "Request", x: 210, y: 110, width: 160, height: 64, ports: [input_port, output_port] },
		{ id: 2, label: "Review", x: 470, y: 260, width: 160, height: 64, ports: [input_port, output_port] },
		{ id: 3, label: "Release", x: 250, y: 430, width: 160, height: 64, ports: [{ ..input_port, offset: 0.35 }, { ..input_port, id: "in-alt", label: "B", offset: 0.65 }, { ..output_port, label: "C" }] },
	],
	edges: [
		{ id: 1, from: 1, to: 2, source_port: "out", target_port: "in", label: "review", color: "#7895dd", label_placement: "center", label_width: 58, label_height: 22 },
		{ id: 2, from: 2, to: 3, source_port: "out", target_port: "in", label: "release", color: "#7895dd", label_placement: "center", label_width: 65, label_height: 22 },
		{ id: 3, from: 1, to: 3, source_port: "out", target_port: "in-alt", label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 },
	],
}

program = { init!, respond!, shutdown! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64), InitFailed(Str), ..])
init! = || {
	db_path = match Env.var!("ROC_GRAPH_LAYOUT_NODE_EDITOR_DB") {
		Ok(value) => Path.from_os_str(value)
		Err(_) => Path.utf8("./node_editor.db")
	}
	db = Sqlite.open!(Sqlite.default_config(db_path)) ? |err| InitFailed(Str.inspect(err))
	Sqlite.execute!({ db, query: "CREATE TABLE IF NOT EXISTS workspace (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL, document TEXT NOT NULL);", params: {} }) ? |err| InitFailed(Str.inspect(err))
	initial_json = Json.to_str_try(initial_document) ? |err| InitFailed(Str.inspect(err))
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
	index = Server.relative_file("index.html").map_err(|_| InitFailed("The index asset path is invalid."))?
	styles = Server.relative_file("style.css").map_err(|_| InitFailed("The stylesheet asset path is invalid."))?
	datastar = Server.relative_file("datastar-v1.0.2.js").map_err(|_| InitFailed("The Datastar asset path is invalid."))?
	geometry = Server.relative_file("geometry.js").map_err(|_| InitFailed("The geometry asset path is invalid."))?
	canvas = Server.relative_file("node-editor-canvas.js").map_err(|_| InitFailed("The canvas asset path is invalid."))?
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
	path = match request.target() {
		Resource({ raw_path, .. }) => raw_path
		_ => ""
	}
	match (request.method(), path) {
		(GET, "/health") => Ok(Server.respond(text_response(200, "ok")))
		(GET, "/routing-gallery") => Ok(Server.respond(bytes_response(200, "text/html; charset=utf-8", Str.to_utf8(routing_gallery()))))
		(GET, "/updates") => Ok(Server.stream(Sse.unfold!({ revision: -1, signal_revision: -1, ticks: 0 }, |state| stream_step!(db, state))))
		(GET, "/inspector") => inspector!(db, request)
		(POST, "/actions") => action!(db, request)
		_ => Ok(Server.respond(text_response(404, "Not found")))
	}
}

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
		document = decode_document(stored.document) ? |_| StreamFailed("Stored workspace is invalid")
		view = make_view(document, stored.revision, "Workspace synchronized.")
		Ok(Emit({ event: DatastarMarkup.patch_elements(workspace_fragment(view)), state: { revision: state.revision, signal_revision: stored.revision, ticks: 0 }, wake: Immediately }))
	} else if state.ticks >= 150 {
		Ok(Emit({ event: Datastar.patch_signals("{\"serverAlive\":true}"), state: { ..state, ticks: 0 }, wake: After(100) }))
	} else {
		Ok(Wait({ state: { ..state, ticks: state.ticks + 1 }, wake: After(100) }))
	}
}

action! : Sqlite.Db, Server.Request => Try(Server.Outcome, [ServerErr(Str), ..])
action! = |db, request| {
	signals_result : Try(Signals, Datastar.SignalsError)
	signals_result = Datastar.read_signals!(request)
	signals : Signals
	signals = match signals_result {
		Ok(value) => value
		Err(err) => return Ok(Server.respond(text_response(400, "Invalid Datastar signals: ${Str.inspect(err)}")))
	}
	payload_result : Try(Payload, _)
	payload_result = Json.parse(signals.commandPayload)
	payload : Payload
	payload = match payload_result {
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
	document_result = decode_document(stored.document)
	document = match document_result {
		Ok(value) => value
		Err(_) => return Ok(Datastar.respond([signal_event(Bool.False, "The stored workspace is invalid.")]))
	}
	changed = apply_command(document, signals.commandKind, payload)
	if !changed.accepted {
		tx.commit!() ? |err| ServerErr(Str.inspect(err))
		return Ok(Datastar.respond([signal_event(Bool.False, changed.message)]))
	}
	json = Json.to_str_try(changed.document) ? |err| ServerErr(Str.inspect(err))
	updated : StoredWorkspace
	updated = tx.query!({ query: "UPDATE workspace SET revision = revision + 1, document = :document WHERE id = 1 AND revision = :revision RETURNING revision, document;", params: { document: json, revision: stored.revision }, limits: Sqlite.default_query_limits }) ? |err| ServerErr(Str.inspect(err))
	tx.commit!() ? |err| ServerErr(Str.inspect(err))
	selected_nodes : List(U64)
	selected_nodes = Json.parse(signals.selectedIds) ?? []
	selected_edges : List(U64)
	selected_edges = Json.parse(signals.selectedEdgeIds) ?? []
	Ok(Datastar.respond([Datastar.patch_signals("{\"revision\":${updated.revision.to_str()},\"pending\":false,\"status\":${Json.to_str(changed.message)},\"acceptedRevision\":${updated.revision.to_str()},\"acceptedOperationId\":${Json.to_str(signals.operationId)}}"), DatastarMarkup.patch_elements(inspector_fragment(changed.document, selected_nodes, selected_edges))]))
}

signal_event : Bool, Str -> Sse.Event
signal_event = |pending, status| Datastar.patch_signals("{\"pending\":${Json.to_str(pending)},\"status\":${Json.to_str(status)}}")

inspector! : Sqlite.Db, Server.Request => Try(Server.Outcome, [ServerErr(Str), ..])
inspector! = |db, request| {
	signals_result : Try(Signals, Datastar.SignalsError)
	signals_result = Datastar.read_signals!(request)
	signals : Signals
	signals = match signals_result {
		Ok(value) => value
		Err(err) => return Ok(Server.respond(text_response(400, "Invalid Datastar signals: ${Str.inspect(err)}")))
	}
	parsed : Try(List(U64), _)
	parsed = Json.parse(signals.selectedIds)
	selected = match parsed {
		Ok(value) => value
		Err(_) => []
	}
	parsed_edges : Try(List(U64), _)
	parsed_edges = Json.parse(signals.selectedEdgeIds)
	selected_edges = match parsed_edges {
		Ok(value) => value
		Err(_) => []
	}
	stored : StoredWorkspace
	stored = load!(db) ? |err| ServerErr(Str.inspect(err))
	document_result = decode_document(stored.document)
	document = match document_result {
		Ok(value) => value
		Err(_) => return Ok(Server.respond(text_response(500, "Stored workspace is invalid")))
	}
	Ok(Datastar.respond([DatastarMarkup.patch_elements(inspector_fragment(document, selected, selected_edges))]))
}

apply_command : Document, Str, Payload -> { document : Document, message : Str, accepted : Bool }
apply_command = |document, kind, p| {
	free = |next| { ..next, arrangement: "free", layers: [], guides: [] }
	if kind == "add-node" and document.nodes.len() < 200 {
		id = document.next_node_id
		input_id = "port-${document.next_port_id.to_str()}"
		output_id = "port-${(document.next_port_id + 1).to_str()}"
		node = { id, label: "Node ${id.to_str()}", x: 160 + (id % 5).to_f64() * 190, y: 120 + ((id / 5) % 4).to_f64() * 130, width: 160, height: 64, ports: [{ ..input_port, id: input_id, side: "auto", resolved_side: "left" }, { ..output_port, id: output_id, side: "auto", resolved_side: "right" }] }
		{ document: free({ ..document, next_node_id: id + 1, next_port_id: document.next_port_id + 2, nodes: document.nodes.append(node) }), message: "Node added.", accepted: True }
	} else if kind == "move-node" and finite(p.x, p.y) {
		found = document.nodes.any(|node| node.id == p.node)
		next = {
			..document,
			nodes: document.nodes.map(
				|node| if node.id == p.node {
					{ ..node, x: p.x, y: p.y }
				} else {
					node
				},
			),
		}
		{
			document: free(next),
			message: if found {
				"Node moved exactly to the dropped position."
			} else {
				"Node was not found."
			},
			accepted: found,
		}
	} else if kind == "resize-node" and finite(p.width, p.height) and p.width >= 96 and p.width <= 480 and p.height >= 52 and p.height <= 320 {
		found = document.nodes.any(|node| node.id == p.node)
		next = {
			..document,
			nodes: document.nodes.map(
				|node| if node.id == p.node {
					{ ..node, width: p.width, height: p.height }
				} else {
					node
				},
			),
		}
		{
			document: free(next),
			message: if found {
				"Node resized."
			} else {
				"Node was not found."
			},
			accepted: found,
		}
	} else if kind == "rename-node" and Str.count_utf8_bytes(p.label) <= 120 {
		found = document.nodes.any(|node| node.id == p.node)
		{
			document: {
				..document,
				nodes: document.nodes.map(
					|node| if node.id == p.node {
						{ ..node, label: p.label }
					} else {
						node
					},
				),
			},
			message: if found {
				"Label updated."
			} else {
				"Node was not found."
			},
			accepted: found,
		}
	} else if kind == "add-port" and ["input", "output"].contains(p.role) {
		found = document.nodes.any(|node| node.id == p.node and node.ports.len() < 16)
		port_id = "port-${document.next_port_id.to_str()}"
		next = {
			..document,
			next_port_id: document.next_port_id + 1,
			nodes: document.nodes.map(
				|node| if node.id == p.node {
					{
						..node,
						ports: node.ports.append({
							id: port_id,
							label: port_label(node.ports.len()),
							role: p.role,
							side: "auto",
							resolved_side: if p.role == "input" {
								"left"
							} else {
								"right"
							},
							offset: 0.5,
						}),
					}
				} else {
					node
				},
			),
		}
		{
			document: free(redistribute_ports(next)),
			message: if found {
				"Port added."
			} else {
				"The node cannot accept another port."
			},
			accepted: found,
		}
	} else if kind == "move-port" and ["up", "down"].contains(p.direction) {
		found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id))
		moved_nodes = document.nodes.map(
			|node| if node.id == p.node {
				{ ..node, ports: move_port(node.ports, p.port_id, p.direction) }
			} else {
				node
			},
		)
		{
			document: free(redistribute_ports({ ..document, nodes: moved_nodes })),
			message: if found {
				"Port order updated."
			} else {
				"Port not found."
			},
			accepted: found,
		}
	} else if kind == "update-port" and Str.count_utf8_bytes(p.label) <= 64 and ["input", "output"].contains(p.role) and ["auto", "top", "right", "bottom", "left"].contains(p.side) {
		found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id))
		used = port_connection_count(document, p.node, p.port_id) > 0
		role_ok = match find_port(document, p.node, p.port_id) {
			Ok(port) => port.role == p.role or !used
			Err(_) => False
		}
		changed_nodes = document.nodes.map(
			|node| if node.id == p.node {
				{
					..node,
					ports: node.ports.map(
						|port| if port.id == p.port_id {
							resolved = if p.side == "auto" and port.role != p.role {
								fallback_side(p.role)
							} else if p.side == "auto" and port.side != "auto" {
								side_for_port(document, p.node, p.port_id, p.role)
							} else if p.side == "auto" {
								port.resolved_side
							} else {
								p.side
							}
							{ ..port, label: p.label, role: p.role, side: p.side, resolved_side: resolved }
						} else {
							port
						},
					),
				}
			} else {
				node
			},
		)
		next = redistribute_ports({ ..document, nodes: changed_nodes })
		{
			document: free(next),
			message: if found and role_ok {
				"Port updated."
			} else if used {
				"Disconnect the port before changing its role."
			} else {
				"Port not found."
			},
			accepted: found and role_ok,
		}
	} else if kind == "reevaluate-port" {
		found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id and port.side == "auto"))
		nodes = document.nodes.map(
			|node| if node.id == p.node {
				{
					..node,
					ports: node.ports.map(
						|port| if port.id == p.port_id and port.side == "auto" {
							{ ..port, resolved_side: side_for_port(document, p.node, p.port_id, port.role) }
						} else {
							port
						},
					),
				}
			} else {
				node
			},
		)
		{
			document: free(redistribute_ports({ ..document, nodes })),
			message: if found {
				"Automatic side re-evaluated."
			} else {
				"Automatic port not found."
			},
			accepted: found,
		}
	} else if kind == "delete-port" {
		found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id))
		next = {
			..document,
			nodes: document.nodes.map(
				|node| if node.id == p.node {
					{ ..node, ports: node.ports.keep_if(|port| port.id != p.port_id) }
				} else {
					node
				},
			),
			edges: document.edges.keep_if(|edge| !(edge.from == p.node and edge.source_port == p.port_id) and !(edge.to == p.node and edge.target_port == p.port_id)),
		}
		{ document: free(normalize_auto_ports(redistribute_ports(next))), message: "Port and its connections deleted.", accepted: found }
	} else if kind == "delete-node" {
		found = document.nodes.any(|node| node.id == p.node)
		next = { ..document, nodes: document.nodes.keep_if(|node| node.id != p.node), edges: document.edges.keep_if(|edge| edge.from != p.node and edge.to != p.node) }
		{ document: free(normalize_auto_ports(next)), message: "Node deleted.", accepted: found }
	} else if kind == "delete-edge" {
		found = document.edges.any(|edge| edge.id == p.edge)
		{ document: free(normalize_auto_ports({ ..document, edges: document.edges.keep_if(|edge| edge.id != p.edge) })), message: "Connection deleted.", accepted: found }
	} else if kind == "update-edge" and Str.count_utf8_bytes(p.label) <= 120 and valid_color(p.color) and ["center", "near-source", "near-target"].contains(p.placement) and finite(p.label_width, p.label_height) and p.label_width >= 0 and p.label_width <= 1200 and p.label_height >= 0 and p.label_height <= 80 {
		found = document.edges.any(|edge| edge.id == p.edge)
		old = document.edges.find_first(|edge| edge.id == p.edge)
		geometry_changed = match old {
			Ok(edge) => edge.label != p.label or edge.label_placement != p.placement or edge.label_width != p.label_width or edge.label_height != p.label_height
			Err(_) => False
		}
		next = {
			..document,
			edges: document.edges.map(
				|edge| if edge.id == p.edge {
					{ ..edge, label: p.label, color: p.color, label_placement: p.placement, label_width: p.label_width, label_height: p.label_height }
				} else {
					edge
				},
			),
		}
		{
			document: if geometry_changed {
				free(next)
			} else {
				next
			},
			message: if found {
				"Connection updated."
			} else {
				"Connection not found."
			},
			accepted: found,
		}
	} else if kind == "add-edge" and document.edges.len() < 500 and can_add_connection(document, p.from, p.source_port, p.to, p.target_port) {
		id = document.next_edge_id
		edge = { id, from: p.from, to: p.to, source_port: p.source_port, target_port: p.target_port, label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 }
		locked = lock_new_connection(document, edge)
		{ document: free(redistribute_ports({ ..locked, next_edge_id: id + 1, edges: locked.edges.append(edge) })), message: "Connection added.", accepted: True }
	} else if kind == "arrange" {
		arrange(document, p.algorithm, p.direction)
	} else if kind == "replace-document" {
		replacement : Try(Document, _)
		replacement = Json.parse(p.document)
		match replacement {
			Ok(value) if valid_document(value) => { document: normalize_auto_ports(value), message: "Previous editor state restored.", accepted: True }
			_ => { document, message: "The history snapshot was invalid.", accepted: False }
		}
	} else if kind == "reset" {
		{ document: initial_document, message: "Workspace reset.", accepted: True }
	} else {
		{ document, message: "The command was not applicable.", accepted: False }
	}
}

arrange : Document, Str, Str -> { document : Document, message : Str, accepted : Bool }
arrange = |document, algorithm, raw_direction| {
	direction = if ["down", "up", "left", "right"].contains(raw_direction) {
		raw_direction
	} else {
		document.direction
	}
	nodes = document.nodes.map(|node| { width: node.width, height: node.height })
	edges = indexed_edges(document)
	spec = { nodes, edges }
	if algorithm == "force" {
		match ForceLayout.layout_force(spec, ForceLayout.force_defaults, { ..ForceLayout.force_default_run, hints: document.nodes.map(|node| Geom.point(node.x, node.y)) }) {
			Ok(result) => accepted_positions(document, result.layout.positions, "force", direction, [], [], "Force arrangement applied.")
			Err(_) => rejected(document, "Force arrangement could not be applied.")
		}
	} else if algorithm == "stress" {
		match StressLayout.layout_stress(spec, StressLayout.stress_defaults, { ..StressLayout.stress_default_run, hints: document.nodes.map(|node| Geom.point(node.x, node.y)) }) {
			Ok(result) => accepted_positions(document, result.layout.positions, "stress", direction, [], [], "Stress arrangement applied.")
			Err(_) => rejected(document, "Stress arrangement could not be applied.")
		}
	} else {
		layer_direction = match direction {
			"up" => Up
			"left" => Left
			"right" => Right
			_ => Down
		}
		match Layered.layout({ ..Layered.default_input, graph: spec, attachments: attachments(document), edge_labels: route_edge_labels(document) }, { ..Layered.default_settings, direction: layer_direction }, Layered.default_run) {
			Ok(result) => accepted_positions(document, result.layout.positions, "layered", direction, result.layers, result.layout.routes.map_with_index(|route, edge| { edge, points: interior(route) }), "Layered arrangement applied.")
			Err(_) => rejected(document, "Layered arrangement could not be applied.")
		}
	}
}

accepted_positions : Document, List(Geom.Point), Str, Str, List(U64), List(Guide), Str -> { document : Document, message : Str, accepted : Bool }
accepted_positions = |document, positions, arrangement, direction, layers, guides, message| {
	nodes = document.nodes.map_with_index(
		|node, i| match positions.get(i) {
			Ok(point) => { ..node, x: point.x, y: point.y }
			Err(_) => node
		},
	)
	{ document: { ..document, nodes, arrangement, direction, layers, guides }, message, accepted: True }
}

rejected : Document, Str -> { document : Document, message : Str, accepted : Bool }
rejected = |document, message| { document, message, accepted: False }

make_view : Document, I64, Str -> View
make_view = |document, revision, message| {
	nodes = document.nodes.map(|node| { width: node.width, height: node.height })
	edges = indexed_edges(document)
	positions = document.nodes.map(|node| Geom.point(node.x, node.y))
	labeled = document.edges.fold_with_index(
		[],
		|found, edge, index| if edge.label.is_empty() {
			found
		} else {
			found.append({ edge, index })
		},
	)
	input = { ..Route.default_input, graph: { nodes, edges }, positions, attachments: attachments(document), edge_labels: route_edge_labels(document), guides: document.guides }
	routes = match Route.layout(input, Route.default_settings) {
		Ok(result) => result.layout.routes.map_with_index(
			|route, i| {
				edge = document.edges.get(i) ?? { id: 0, from: 0, to: 0, source_port: "", target_port: "", label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 }
				label_index = labeled.find_first_index(|item| item.index == i)
				anchor = match label_index {
					Ok(index) => result.label_anchors.get(index) ?? { x: 0, y: 0 }
					Err(_) => { x: 0, y: 0 }
				}
				{ edge: edge.id, from: edge.from, to: edge.to, source_port: edge.source_port, target_port: edge.target_port, points: route_points(route), label: edge.label, color: edge.color, label_placement: edge.label_placement, label_anchor: anchor, label_width: edge.label_width, label_height: edge.label_height }
			},
		)
		Err(_) => []
	}
	{ revision, document, routes, message }
}

label_placement = |value| match value {
	"near-source" => Near(From)
	"near-target" => Near(To)
	_ => Center
}

route_edge_labels = |document| document.edges.fold_with_index(
	[],
	|found, edge, index| if edge.label.is_empty() {
		found
	} else {
		found.append({ edge: index, width: edge.label_width, height: edge.label_height, placement: label_placement(edge.label_placement) })
	},
)

indexed_edges : Document -> List({ from : U64, to : U64 })
indexed_edges = |document| document.edges.keep_oks(
	|edge| match (document.nodes.find_first_index(|node| node.id == edge.from), document.nodes.find_first_index(|node| node.id == edge.to)) {
		(Ok(from), Ok(to)) => Ok({ from, to })
		_ => Err({})
	},
)

find_port : Document, U64, Str -> Try(Port, [NoPort])
find_port = |document, node_id, port_id| match document.nodes.find_first(|node| node.id == node_id) {
	Ok(node) => match node.ports.find_first(|port| port.id == port_id) {
		Ok(port) => Ok(port)
		Err(_) => Err(NoPort)
	}
	Err(_) => Err(NoPort)
}

port_connection_count : Document, U64, Str -> U64
port_connection_count = |document, node_id, port_id| document.edges.fold(
	0.U64,
	|count, edge| if (edge.from == node_id and edge.source_port == port_id) or (edge.to == node_id and edge.target_port == port_id) {
		count + 1
	} else {
		count
	},
)

fallback_side = |role| if role == "input" {
	"left"
} else {
	"right"
}

port_label = |index| ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"].get(index) ?? "Port"

move_port = |ports, port_id, direction| match ports.find_first_index(|port| port.id == port_id) {
	Err(_) => ports
	Ok(index) => {
		target = if direction == "up" and index > 0 {
			index - 1
		} else if direction == "down" and index + 1 < ports.len() {
			index + 1
		} else {
			index
		}
		if target == index {
			ports
		} else {
			current = ports.get(index) ?? input_port
			other = ports.get(target) ?? input_port
			ports.map_with_index(
				|port, i| if i == index {
					other
				} else if i == target {
					current
				} else {
					port
				},
			)
		}
	}
}

side_toward : { x : F64, y : F64 }, { x : F64, y : F64 }, Str -> Str
side_toward = |from, to, role| {
	dx = to.x - from.x
	dy = to.y - from.y
	if dx == 0 and dy == 0 {
		fallback_side(role)
	} else if dx.abs() >= dy.abs() {
		if dx < 0 {
			"left"
		} else {
			"right"
		}
	} else if dy < 0 {
		"top"
	} else {
		"bottom"
	}
}

side_for_port = |document, node_id, port_id, role| {
	center = match document.nodes.find_first(|node| node.id == node_id) {
		Ok(node) => { x: node.x, y: node.y }
		Err(_) => { x: 0, y: 0 }
	}
	neighbors = document.edges.keep_oks(
		|edge| if edge.from == node_id and edge.source_port == port_id {
			match document.nodes.find_first(|node| node.id == edge.to) {
				Ok(node) => Ok({ x: node.x, y: node.y })
				Err(_) => Err(NotConnected)
			}
		} else if edge.to == node_id and edge.target_port == port_id {
			match document.nodes.find_first(|node| node.id == edge.from) {
				Ok(node) => Ok({ x: node.x, y: node.y })
				Err(_) => Err(NotConnected)
			}
		} else {
			Err(NotConnected)
		},
	)
	if neighbors.is_empty() {
		fallback_side(role)
	} else {
		count = neighbors.len().to_f64()
		centroid = neighbors.fold({ x: 0, y: 0 }, |sum, point| { x: sum.x + point.x / count, y: sum.y + point.y / count })
		side_toward(center, centroid, role)
	}
}

redistribute_ports = |document| {
	nodes = document.nodes.map(
		|node| {
			ports = node.ports.map_with_index(
				|port, index| {
					selected_side = if port.side == "auto" {
						port.resolved_side
					} else {
						port.side
					}
					same = node.ports.fold_with_index(
						[],
						|found, other, other_index| {
							other_side = if other.side == "auto" {
								other.resolved_side
							} else {
								other.side
							}
							if other_side == selected_side {
								found.append(other_index)
							} else {
								found
							}
						},
					)
					rank = same.find_first_index(|other_index| other_index == index) ?? 0
					offset = (rank + 1).to_f64() / (same.len() + 1).to_f64()
					{ ..port, resolved_side: selected_side, offset }
				},
			)
			{ ..node, ports }
		},
	)
	{ ..document, nodes }
}

normalize_auto_ports = |document| {
	nodes = document.nodes.map(
		|node| {
			..node,
			ports: node.ports.map(
				|port| if port.side == "auto" and port_connection_count(document, node.id, port.id) == 0 {
					{ ..port, resolved_side: fallback_side(port.role) }
				} else {
					port
				},
			),
		},
	)
	redistribute_ports({ ..document, nodes })
}

lock_new_connection = |document, edge| {
	from_center = match document.nodes.find_first(|node| node.id == edge.from) {
		Ok(node) => { x: node.x, y: node.y }
		Err(_) => { x: 0, y: 0 }
	}
	to_center = match document.nodes.find_first(|node| node.id == edge.to) {
		Ok(node) => { x: node.x, y: node.y }
		Err(_) => { x: 0, y: 0 }
	}
	nodes = document.nodes.map(
		|node| {
			ports = node.ports.map(
				|port| if node.id == edge.from and port.id == edge.source_port and port.side == "auto" and port_connection_count(document, node.id, port.id) == 0 {
					{ ..port, resolved_side: side_toward(from_center, to_center, port.role) }
				} else if node.id == edge.to and port.id == edge.target_port and port.side == "auto" and port_connection_count(document, node.id, port.id) == 0 {
					{ ..port, resolved_side: side_toward(to_center, from_center, port.role) }
				} else {
					port
				},
			)
			{ ..node, ports }
		},
	)
	{ ..document, nodes }
}

valid_connection : Document, U64, Str, U64, Str -> Bool
valid_connection = |document, from_node, from_id, to_node, to_id| match (find_port(document, from_node, from_id), find_port(document, to_node, to_id)) {
	(Ok(from), Ok(to)) => from.role == "output" and to.role == "input"
	_ => False
}

can_add_connection = |document, from_node, from_id, to_node, to_id| valid_connection(document, from_node, from_id, to_node, to_id) and !document.edges.any(|edge| edge.to == to_node and edge.target_port == to_id)

side : Str -> Route.Side
side = |value| match value {
	"right" => Right
	"bottom" => Bottom
	"left" => Left
	_ => Top
}

attachments : Document -> List(Route.AttachmentRule)
attachments = |document| document.edges.fold_with_index(
	[],
	|rules, edge, i| match (find_port(document, edge.from, edge.source_port), find_port(document, edge.to, edge.target_port)) {
		(Ok(from), Ok(to)) => rules.concat([{ edge: i, endpoint: From, attachment: Fixed({ side: side(from.resolved_side), offset: from.offset }) }, { edge: i, endpoint: To, attachment: Fixed({ side: side(to.resolved_side), offset: to.offset }) }])
		_ => rules
	},
)

route_points : Geom.Route -> List(Geom.Point)
route_points = |route| match route {
	Line(a, b) => [a, b]
	Polyline(points) => points
	Curves(segments) => segments.fold([], |all, segment| all.append(segment.from).append(segment.to))
}

interior : Geom.Route -> List(Geom.Point)
interior = |route| {
	points = route_points(route)
	if points.len() > 2 {
		points.drop_first(1).drop_last(1)
	} else {
		[]
	}
}

finite : F64, F64 -> Bool
finite = |a, b| F64.is_finite(a) and F64.is_finite(b)

hex_byte = |byte| (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70) or (byte >= 97 and byte <= 102)

valid_color = |color| {
	bytes = Str.to_utf8(color)
	bytes.len() == 7 and bytes.first() == Ok(35) and bytes.drop_first(1).all(hex_byte)
}

valid_port = |port| !port.id.is_empty() and Str.count_utf8_bytes(port.id) <= 80 and Str.count_utf8_bytes(port.label) <= 64 and ["input", "output"].contains(port.role) and ["auto", "top", "right", "bottom", "left"].contains(port.side) and ["top", "right", "bottom", "left"].contains(port.resolved_side) and F64.is_finite(port.offset) and port.offset >= 0 and port.offset <= 1

unique_ports = |node| node.ports.fold_with_index(True, |unique, port, i| unique and !node.ports.fold_with_index(False, |found, other, j| found or (j < i and other.id == port.id)))

input_capacity_ok = |document| document.nodes.all(|node| node.ports.all(|port| port.role != "input" or port_connection_count(document, node.id, port.id) <= 1))

valid_document_shape = |document| document.nodes.len() <= 200 and document.edges.len() <= 500 and document.nodes.all(|node| finite(node.x, node.y) and finite(node.width, node.height) and node.width >= 96 and node.height >= 52 and node.ports.len() <= 16 and node.ports.all(valid_port) and unique_ports(node)) and document.edges.all(|edge| valid_connection(document, edge.from, edge.source_port, edge.to, edge.target_port) and Str.count_utf8_bytes(edge.label) <= 120 and valid_color(edge.color) and ["center", "near-source", "near-target"].contains(edge.label_placement) and finite(edge.label_width, edge.label_height) and edge.label_width >= 0 and edge.label_width <= 1200 and edge.label_height >= 0 and edge.label_height <= 80) and input_capacity_ok(document)

valid_document : Document -> Bool
valid_document = |document| document.schema_version == 4 and valid_document_shape(document)

migrate_v3 = |old| redistribute_ports({
	..old,
	schema_version: 4,
	nodes: old.nodes.map(
		|node| {
			..node,
			ports: node.ports.map_with_index(
				|port, index| {
					..port,
					label: if ["Input", "Output", "Expedite"].contains(port.label) {
						port_label(index)
					} else {
						port.label
					},
				},
			),
		},
	),
})

migrate_v2 = |old| {
	base : Document
	base = {
		schema_version: 4,
		next_node_id: old.next_node_id,
		next_edge_id: old.next_edge_id,
		next_port_id: 1,
		direction: old.direction,
		arrangement: old.arrangement,
		layers: old.layers,
		guides: old.guides,
		nodes: old.nodes.map(|node| { id: node.id, label: node.label, x: node.x, y: node.y, width: node.width, height: node.height, ports: node.ports.map(|port| { id: port.id, label: port.label, role: port.role, side: port.side, resolved_side: port.side, offset: port.offset }) }),
		edges: [],
	}
	migrated = old.edges.fold(
		base,
		|state, old_edge| {
			occupied = state.edges.any(|edge| edge.to == old_edge.to and edge.target_port == old_edge.target_port)
			if occupied {
				new_port_id = "port-${state.next_port_id.to_str()}"
				original = find_port(state, old_edge.to, old_edge.target_port) ?? input_port
				copy_number = port_connection_count(state, old_edge.to, old_edge.target_port) + 1
				copy = { ..original, id: new_port_id, label: "${original.label} ${copy_number.to_str()}" }
				nodes = state.nodes.map(
					|node| if node.id == old_edge.to {
						{ ..node, ports: node.ports.append(copy) }
					} else {
						node
					},
				)
				edge = { id: old_edge.id, from: old_edge.from, to: old_edge.to, source_port: old_edge.source_port, target_port: new_port_id, label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 }
				{ ..state, next_port_id: state.next_port_id + 1, nodes, edges: state.edges.append(edge) }
			} else {
				edge = { id: old_edge.id, from: old_edge.from, to: old_edge.to, source_port: old_edge.source_port, target_port: old_edge.target_port, label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 }
				{ ..state, edges: state.edges.append(edge) }
			}
		},
	)
	redistribute_ports(migrated)
}

decode_document : Str -> Try(Document, [InvalidDocument])
decode_document = |text| {
	current : Try(Document, _)
	current = Json.parse(text)
	match current {
		Ok(document) if valid_document(document) => Ok(document)
		Ok(document) if document.schema_version == 3 and valid_document_shape(document) => Ok(migrate_v3(document))
		_ => {
			v2 : Try(V2Document, _)
			v2 = Json.parse(text)
			match v2 {
				Ok(old) => Ok(migrate_v2(old))
				Err(_) => {
					legacy : Try(LegacyDocument, _)
					legacy = Json.parse(text)
					match legacy {
						Ok(old) => Ok(migrate_v2({ next_node_id: old.next_node_id, next_edge_id: old.next_edge_id, direction: old.direction, arrangement: "free", layers: [], guides: [], nodes: old.nodes.map(|node| { id: node.id, label: node.label, x: node.x, y: node.y, width: 160, height: 64, ports: [{ id: "in", label: "Input", role: "input", side: "top", offset: 0.5 }, { id: "out", label: "Output", role: "output", side: "bottom", offset: 0.5 }] }), edges: old.edges }))
						Err(_) => Err(InvalidDocument)
					}
				}
			}
		}
	}
}

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
					Attribute.attribute("data-arrangement", view.document.arrangement),
					Attribute.attribute("data-direction", view.document.direction),
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
		"top" | "bottom" => "left:${(port.offset * 100).to_str()}%"
		_ => "top:${(port.offset * 100).to_str()}%"
	}
	Html.button(
		[
			Attribute.class("port ${port.role} ${port.resolved_side}"),
			Attribute.attribute("data-port-id", port.id),
			Attribute.attribute("data-role", port.role),
			Attribute.attribute("data-side", port.resolved_side),
			Attribute.attribute("data-side-mode", port.side),
			Attribute.attribute("data-offset", port.offset.to_str()),
			Attribute.attribute("title", "${port.label} · ${port.role}"),
			Attribute.attribute("aria-label", "${port.label}, ${port.role} port"),
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
						if port.role == "input" {
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
document_json = |document| match Json.to_str_try(document) {
	Ok(value) => value
	Err(_) => "{}"
}

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
	used = port_connection_count(document, node.id, port.id) > 0
	role_attributes = [Attribute.attribute("data-port-role", ""), Attribute.attribute("aria-label", "Port role")].concat(
		if used {
			[Attribute.attribute("disabled", "")]
		} else {
			[]
		},
	)
	controls = [
		Html.input([Attribute.attribute("value", port.label), Attribute.attribute("data-port-label", ""), Attribute.attribute("aria-label", "Port label"), Attribute.attribute("maxlength", "64")]),
		Html.element("select", role_attributes, [option_node("input", "Input", port.role == "input"), option_node("output", "Output", port.role == "output")]),
		Html.element("select", [Attribute.attribute("data-port-side", ""), Attribute.attribute("aria-label", "Port side")], [option_node("auto", "Automatic", port.side == "auto"), option_node("top", "Top", port.side == "top"), option_node("right", "Right", port.side == "right"), option_node("bottom", "Bottom", port.side == "bottom"), option_node("left", "Left", port.side == "left")]),
	]
	auto_controls = if port.side == "auto" {
		[Html.span([Attribute.class("port-resolution")], [Html.text("Locked to ${port.resolved_side}")]), Html.button([Attribute.attribute("data-reevaluate-port", ""), Attribute.attribute("data-node", node.id.to_str()), Attribute.attribute("data-port", port.id)], [Html.text("Re-evaluate")])]
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
		Html.label([], [Html.text("Label position"), Html.element("select", [Attribute.attribute("data-edge-placement", "")], [option_node("center", "Center", edge.label_placement == "center"), option_node("near-source", "Near source", edge.label_placement == "near-source"), option_node("near-target", "Near target", edge.label_placement == "near-target")])]),
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
	view = make_view(redistribute_ports(document), 0, "")
	metrics = gallery_metrics(view.routes)
	markup = Str.join_with(view.document.nodes.map(gallery_node), "").concat(Str.join_with(view.routes.map(gallery_route), ""))
	"<article><header><h2>${name}</h2><span>${view.routes.len().to_str()} routes · ${metrics.bends.to_str()} bends · ${metrics.length.to_str()} px</span></header><svg viewBox=\"0 0 720 430\">${markup}</svg></article>"
}

gallery_document = |nodes, edges| {
	{ schema_version: 4, next_node_id: nodes.len() + 1, next_edge_id: edges.len() + 1, next_port_id: 1, direction: "down", arrangement: "free", layers: [], guides: [], nodes, edges }
}

gallery_edge = |id, from, to, source_port, target_port, color| { id, from, to, source_port, target_port, label: "", color, label_placement: "center", label_width: 0, label_height: 0 }

routing_gallery = || {
	shared_ports = gallery_document(
		[
			{ id: 1, label: "Request", x: 330, y: 70, width: 160, height: 64, ports: [output_port] },
			{ id: 2, label: "Review", x: 210, y: 310, width: 180, height: 72, ports: [input_port] },
			{ id: 3, label: "Archive", x: 500, y: 310, width: 160, height: 64, ports: [{ ..input_port, id: "in-2" }] },
		],
		[gallery_edge(1, 1, 2, "out", "in", "#7895dd"), gallery_edge(2, 1, 3, "out", "in-2", "#f3b36f")],
	)
	parallel = gallery_document(
		[
			{ id: 1, label: "Shared output", x: 300, y: 70, width: 180, height: 64, ports: [output_port] },
			{ id: 2, label: "Shared input", x: 300, y: 330, width: 220, height: 88, ports: [input_port] },
		],
		[gallery_edge(1, 1, 2, "out", "in", "#75d8b1"), gallery_edge(2, 1, 2, "out", "in", "#f3b36f")],
	)
	obstacle = gallery_document(
		[
			{ id: 1, label: "Start", x: 100, y: 210, width: 140, height: 64, ports: [{ ..output_port, side: "right", resolved_side: "right" }] },
			{ id: 2, label: "Finish", x: 620, y: 210, width: 140, height: 64, ports: [{ ..input_port, side: "left", resolved_side: "left" }] },
			{ id: 3, label: "Obstacle", x: 360, y: 210, width: 190, height: 120, ports: [] },
		],
		[gallery_edge(1, 1, 2, "out", "in", "#a88cff")],
	)
	cards = Str.join_with([gallery_card("Shared output fan", shared_ports), gallery_card("Parallel fixed ports", parallel), gallery_card("Obstacle clearance", obstacle)], "")
	"<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Routing diagnostics</title><style>:root{color-scheme:dark;font:14px system-ui;background:#090e1b;color:#edf2ff}body{margin:0;padding:24px}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:18px}article{border:1px solid #293657;border-radius:12px;background:#10182b;overflow:hidden}article header{display:flex;justify-content:space-between;align-items:baseline;padding:12px 16px}h1{margin-top:0}h2{font-size:15px;margin:0}span{color:#91a3ca;font-size:12px}svg{display:block;width:100%;background:#0c1426}.gallery-node{fill:#1d2b4c;stroke:#526da9}.gallery-obstacle{fill:none;stroke:#f3b36f55;stroke-dasharray:5 4}.gallery-route{fill:none;stroke-width:2}.gallery-node+text,text{fill:#edf2ff;font:12px system-ui}a{color:#9ebcff}</style></head><body><h1>Routing diagnostics</h1><p>Every dashed rectangle is the clearance boundary used by the final router. These fixtures are rendered directly from <code>Route.layout</code>.</p><p><a href=\"/\">Return to editor</a></p><main>${cards}</main></body></html>"
}

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

## Current workspaces with several edges entering the old single input are
## migrated without dropping edges. Each additional edge receives a stable
## input port so the new capacity rule is valid immediately.
expect {
	old : V2Document
	old = {
		next_node_id: 3,
		next_edge_id: 3,
		direction: "down",
		arrangement: "free",
		layers: [],
		guides: [],
		nodes: [
			{ id: 1, label: "Source", x: 0, y: 0, width: 160, height: 64, ports: [{ id: "out", label: "Output", role: "output", side: "bottom", offset: 0.5 }] },
			{ id: 2, label: "Target", x: 0, y: 200, width: 160, height: 64, ports: [{ id: "in", label: "Input", role: "input", side: "top", offset: 0.5 }] },
		],
		edges: [{ id: 1, from: 1, to: 2, source_port: "out", target_port: "in" }, { id: 2, from: 1, to: 2, source_port: "out", target_port: "in" }],
	}
	migrated = migrate_v2(old)
	first = migrated.edges.get(0) ?? { id: 0, from: 0, to: 0, source_port: "", target_port: "", label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 }
	second = migrated.edges.get(1) ?? first
	migrated.edges.len() == 2 and first.target_port != second.target_port and valid_document(migrated)
}

## Automatic sides lock toward the first connected neighbor while occupied
## inputs reject another connection.
expect {
	document = {
		..initial_document,
		nodes: [
			{ id: 1, label: "A", x: 0, y: 0, width: 160, height: 64, ports: [{ ..output_port, side: "auto", resolved_side: "right" }] },
			{ id: 2, label: "B", x: 200, y: 0, width: 160, height: 64, ports: [{ ..input_port, side: "auto", resolved_side: "left" }] },
		],
		edges: [],
	}
	edge = { id: 1, from: 1, to: 2, source_port: "out", target_port: "in", label: "", color: "#7895dd", label_placement: "center", label_width: 0, label_height: 0 }
	locked = lock_new_connection(document, edge)
	connected = { ..locked, edges: [edge] }
	(find_port(locked, 1, "out") ?? output_port).resolved_side == "right" and (find_port(locked, 2, "in") ?? input_port).resolved_side == "left" and !can_add_connection(connected, 1, "out", 2, "in")
}

## Reordering preserves stable port identities and moves only the requested
## neighbor, so persisted edges continue to name the same ports.
expect {
	ports = [input_port, { ..input_port, id: "alternate", label: "Alternate" }, output_port]
	moved = move_port(ports, "out", "up")
	unchanged = move_port(moved, "in", "up")
	(moved.get(1) ?? input_port).id == "out" and moved.len() == ports.len() and unchanged == moved
}

## Version-three showcase defaults adopt compact alphabetic names without
## overwriting labels that the user already customized.
expect {
	old = {
		..initial_document,
		schema_version: 3,
		nodes: [{ id: 1, label: "Node", x: 0, y: 0, width: 160, height: 64, ports: [{ ..input_port, label: "Input" }, { ..output_port, label: "Custom" }] }],
		edges: [],
	}
	migrated = migrate_v3(old)
	ports = (migrated.nodes.first() ?? { id: 0, label: "", x: 0, y: 0, width: 0, height: 0, ports: [] }).ports
	(ports.get(0) ?? input_port).label == "A" and (ports.get(1) ?? output_port).label == "Custom" and valid_document(migrated)
}
