import ./Command
import layout.ForceLayout
import layout.Geom
import layout.Layered
import layout.Route
import layout.StressLayout

## Document identity owns validation and conversion at the JSON boundary.
Role : [Input, Output]

Side : [Bottom, Left, Right, Top]

PortPlacement : [Automatic, Bottom, Left, Right, Top]

Arrangement : [Force, Free, Layered, Stress]

Direction : [Down, Left, Right, Up]

EdgeLabelPlacement : [Center, NearSource, NearTarget]

Port : { id : Str, label : Str, role : Role, side : PortPlacement, resolved_side : Side, offset : F64 }

Node : { id : U64, label : Str, x : F64, y : F64, width : F64, height : F64, ports : List(Port) }

Edge : { id : U64, from : U64, to : U64, source_port : Str, target_port : Str, label : Str, color : Str, label_placement : EdgeLabelPlacement, label_width : F64, label_height : F64 }

RawPort : { id : Str, label : Str, role : Str, side : Str, resolved_side : Str, offset : F64 }

RawNode : { id : U64, label : Str, x : F64, y : F64, width : F64, height : F64, ports : List(RawPort) }

RawEdge : { id : U64, from : U64, to : U64, source_port : Str, target_port : Str, label : Str, color : Str, label_placement : Str, label_width : F64, label_height : F64 }

RawDocument : { next_node_id : U64, next_edge_id : U64, next_port_id : U64, direction : Str, arrangement : Str, layers : List(U64), guides : List(Guide), nodes : List(RawNode), edges : List(RawEdge) }

Guide : { edge : U64, points : List(Geom.Point) }

Document := { next_node_id : U64, next_edge_id : U64, next_port_id : U64, direction : Direction, arrangement : Arrangement, layers : List(U64), guides : List(Guide), nodes : List(Node), edges : List(Edge) }.{
	Role : [Input, Output]
	Side : [Bottom, Left, Right, Top]
	PortPlacement : [Automatic, Bottom, Left, Right, Top]
	Arrangement : [Force, Free, Layered, Stress]
	Direction : [Down, Left, Right, Up]
	EdgeLabelPlacement : [Center, NearSource, NearTarget]
	Port : { id : Str, label : Str, role : Role, side : PortPlacement, resolved_side : Side, offset : F64 }
	Node : { id : U64, label : Str, x : F64, y : F64, width : F64, height : F64, ports : List(Port) }
	Edge : { id : U64, from : U64, to : U64, source_port : Str, target_port : Str, label : Str, color : Str, label_placement : EdgeLabelPlacement, label_width : F64, label_height : F64 }
	Guide : { edge : U64, points : List(Geom.Point) }
	RouteView : { edge : U64, from : U64, to : U64, source_port : Str, target_port : Str, points : List(Geom.Point), label : Str, color : Str, label_placement : EdgeLabelPlacement, label_anchor : Geom.Point, label_width : F64, label_height : F64 }
	View : { revision : I64, document : Document, routes : List(RouteView), message : Str }
	Change : { document : Document, message : Str, accepted : Bool }

	initial : Document
	initial = initial_document
	apply : Document, Command -> Change
	apply = apply_command
	decode : Str -> Try(Document, [InvalidDocument])
	decode = decode_document
	to_json : Document -> Try(Str, [Infinity, NaN, NegativeInfinity])
	to_json = encode_document
	view : Document, I64, Str -> View
	view = make_view
	port_connection_count : Document, U64, Str -> U64
	port_connection_count = count_port_connections
	normalize : Document -> Document
	normalize = normalize_auto_ports
	role_text : Role -> Str
	role_text = role_str
	side_text : Side -> Str
	side_text = side_str
	port_placement_text : PortPlacement -> Str
	port_placement_text = port_placement_str
	direction_text : Direction -> Str
	direction_text = direction_str
	arrangement_text : Arrangement -> Str
	arrangement_text = arrangement_str
	edge_label_placement_text : EdgeLabelPlacement -> Str
	edge_label_placement_text = edge_label_placement_str
}

input_port : Port
input_port = { id: "in", label: "A", role: Input, side: Top, resolved_side: Top, offset: 0.5 }

output_port : Port
output_port = { id: "out", label: "B", role: Output, side: Bottom, resolved_side: Bottom, offset: 0.5 }

editor_route_settings = { ..Route.default_settings, obstacle_gap: 24 }

initial_document : Document
initial_document = {
	next_node_id: 4,
	next_edge_id: 4,
	next_port_id: 1,
	direction: Down,
	arrangement: Free,
	layers: [],
	guides: [],
	nodes: [
		{ id: 1, label: "Request", x: 210, y: 110, width: 160, height: 64, ports: [input_port, output_port] },
		{ id: 2, label: "Review", x: 470, y: 260, width: 160, height: 64, ports: [input_port, output_port] },
		{ id: 3, label: "Release", x: 250, y: 430, width: 160, height: 64, ports: [{ ..input_port, offset: 0.35 }, { ..input_port, id: "in-alt", label: "B", offset: 0.65 }, { ..output_port, label: "C" }] },
	],
	edges: [
		{ id: 1, from: 1, to: 2, source_port: "out", target_port: "in", label: "review", color: "#7895dd", label_placement: Center, label_width: 58, label_height: 22 },
		{ id: 2, from: 2, to: 3, source_port: "out", target_port: "in", label: "release", color: "#7895dd", label_placement: Center, label_width: 65, label_height: 22 },
		{ id: 3, from: 1, to: 3, source_port: "out", target_port: "in-alt", label: "", color: "#7895dd", label_placement: Center, label_width: 0, label_height: 0 },
	],
}

apply_command : Document, Command -> Change
apply_command = |document, command| {
	free = |next| { ..next, arrangement: Free, layers: [], guides: [] }
	match command {
		AddNode => {
			if document.nodes.len() >= 200 {
				return rejected(document, "The command was not applicable.")
			}
			id = document.next_node_id
			input_id = "port-${document.next_port_id.to_str()}"
			output_id = "port-${(document.next_port_id + 1).to_str()}"
			node = { id, label: "Node ${id.to_str()}", x: 160 + (id % 5).to_f64() * 190, y: 120 + ((id / 5) % 4).to_f64() * 130, width: 160, height: 64, ports: [{ ..input_port, id: input_id, side: Automatic, resolved_side: Left }, { ..output_port, id: output_id, side: Automatic, resolved_side: Right }] }
			{ document: free({ ..document, next_node_id: id + 1, next_port_id: document.next_port_id + 2, nodes: document.nodes.append(node) }), message: "Node added.", accepted: True }
		}
		MoveNode(p) => {
			if !finite(p.x, p.y) {
				return rejected(document, "The command was not applicable.")
			}
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
		}
		ResizeNode(p) => {
			if !finite(p.width, p.height) or p.width < 96 or p.width > 480 or p.height < 52 or p.height > 320 {
				return rejected(document, "The command was not applicable.")
			}
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
		}
		RenameNode(p) => {
			if Str.count_utf8_bytes(p.label) > 120 {
				return rejected(document, "The command was not applicable.")
			}
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
		}
		AddPort(p) => {
			role = p.role
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
								role,
								side: Automatic,
								resolved_side: if role == Input {
									Left
								} else {
									Right
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
		}
		MovePort(p) => {
			movement = p.movement
			found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id))
			moved_nodes = document.nodes.map(
				|node| if node.id == p.node {
					{ ..node, ports: move_port(node.ports, p.port_id, movement) }
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
		}
		UpdatePort(p) => {
			if Str.count_utf8_bytes(p.label) > 64 {
				return rejected(document, "The command was not applicable.")
			}
			role = p.role
			port_side = p.placement
			found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id))
			used = count_port_connections(document, p.node, p.port_id) > 0
			role_ok = match find_port(document, p.node, p.port_id) {
				Ok(port) => port.role == role or !used
				Err(_) => False
			}
			changed_nodes = document.nodes.map(
				|node| if node.id == p.node {
					{
						..node,
						ports: node.ports.map(
							|port| if port.id == p.port_id {
								resolved = match port_side {
									Automatic if port.role != role => fallback_side(role)
									Automatic if port.side != Automatic => side_for_port(document, p.node, p.port_id, role)
									Automatic => port.resolved_side
									Top => Top
									Right => Right
									Bottom => Bottom
									Left => Left
								}
								{ ..port, label: p.label, role, side: port_side, resolved_side: resolved }
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
		}
		ReevaluatePort(p) => {
			found = document.nodes.any(|node| node.id == p.node and node.ports.any(|port| port.id == p.port_id and port.side == Automatic))
			nodes = document.nodes.map(
				|node| if node.id == p.node {
					{
						..node,
						ports: node.ports.map(
							|port| if port.id == p.port_id and port.side == Automatic {
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
		}
		DeletePort(p) => {
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
		}
		DeleteNode(node_id) => {
			found = document.nodes.any(|node| node.id == node_id)
			next = { ..document, nodes: document.nodes.keep_if(|node| node.id != node_id), edges: document.edges.keep_if(|edge| edge.from != node_id and edge.to != node_id) }
			{ document: free(normalize_auto_ports(next)), message: "Node deleted.", accepted: found }
		}
		DeleteEdge(edge_id) => {
			found = document.edges.any(|edge| edge.id == edge_id)
			{ document: free(normalize_auto_ports({ ..document, edges: document.edges.keep_if(|edge| edge.id != edge_id) })), message: "Connection deleted.", accepted: found }
		}
		UpdateEdge(p) => {
			if Str.count_utf8_bytes(p.label) > 120 or !valid_color(p.color) or !finite(p.label_width, p.label_height) or p.label_width < 0 or p.label_width > 1200 or p.label_height < 0 or p.label_height > 80 {
				return rejected(document, "The command was not applicable.")
			}
			placement = p.label_placement
			found = document.edges.any(|edge| edge.id == p.edge)
			old = document.edges.find_first(|edge| edge.id == p.edge)
			geometry_changed = match old {
				Ok(edge) => edge.label != p.label or edge.label_placement != placement or edge.label_width != p.label_width or edge.label_height != p.label_height
				Err(_) => False
			}
			next = {
				..document,
				edges: document.edges.map(
					|edge| if edge.id == p.edge {
						{ ..edge, label: p.label, color: p.color, label_placement: placement, label_width: p.label_width, label_height: p.label_height }
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
		}
		AddEdge(p) => {
			if document.edges.len() >= 500 or !can_add_connection(document, p.from, p.source_port, p.to, p.target_port) {
				return rejected(document, "The command was not applicable.")
			}
			id = document.next_edge_id
			edge = { id, from: p.from, to: p.to, source_port: p.source_port, target_port: p.target_port, label: "", color: "#7895dd", label_placement: Center, label_width: 0, label_height: 0 }
			locked = lock_new_connection(document, edge)
			{ document: free(redistribute_ports({ ..locked, next_edge_id: id + 1, edges: locked.edges.append(edge) })), message: "Connection added.", accepted: True }
		}
		Arrange(p) => arrange(document, arrangement_from_command(p.algorithm), p.direction)
		ReplaceDocument(json) => {
			match Document.decode(json) {
				Ok(value) if valid_document(value) => { document: normalize_auto_ports(value), message: "Previous editor state restored.", accepted: True }
				_ => { document, message: "The history snapshot was invalid.", accepted: False }
			}
		}
		Reset => {
			{ document: Document.initial, message: "Workspace reset.", accepted: True }
		}
	}
}

## Layout and routing

arrange : Document, Arrangement, Direction -> Change
arrange = |document, algorithm, direction| {
	nodes = document.nodes.map(|node| { width: node.width, height: node.height })
	edges = indexed_edges(document)
	spec = { nodes, edges }
	if algorithm == Force {
		match ForceLayout.layout_force(spec, ForceLayout.force_defaults, { ..ForceLayout.force_default_run, hints: document.nodes.map(|node| Geom.point(node.x, node.y)) }) {
			Ok(result) => accepted_positions(document, result.layout.positions, Force, direction, [], [], "Force arrangement applied.")
			Err(_) => rejected(document, "Force arrangement could not be applied.")
		}
	} else if algorithm == Stress {
		match StressLayout.layout_stress(spec, StressLayout.stress_defaults, { ..StressLayout.stress_default_run, hints: document.nodes.map(|node| Geom.point(node.x, node.y)) }) {
			Ok(result) => accepted_positions(document, result.layout.positions, Stress, direction, [], [], "Stress arrangement applied.")
			Err(_) => rejected(document, "Stress arrangement could not be applied.")
		}
	} else {
		match Layered.layout({ ..Layered.default_input, graph: spec, attachments: attachments(document), edge_labels: route_edge_labels(document) }, { ..Layered.default_settings, direction, routing: editor_route_settings }, Layered.default_run) {
			Ok(result) => accepted_positions(document, result.layout.positions, Layered, direction, result.layers, result.layout.routes.map_with_index(|route, edge| { edge, points: interior(route) }), "Layered arrangement applied.")
			Err(_) => rejected(document, "Layered arrangement could not be applied.")
		}
	}
}

arrangement_from_command : [Force, Layered, Stress] -> Arrangement
arrangement_from_command = |algorithm| match algorithm {
	Force => Force
	Layered => Layered
	Stress => Stress
}

accepted_positions : Document, List(Geom.Point), Arrangement, Direction, List(U64), List(Guide), Str -> Change
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
	routes = match Route.layout(input, editor_route_settings) {
		Ok(result) => result.layout.routes.map_with_index(
			|route, i| {
				edge = document.edges.get(i) ?? { id: 0, from: 0, to: 0, source_port: "", target_port: "", label: "", color: "#7895dd", label_placement: Center, label_width: 0, label_height: 0 }
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

route_label_placement = |placement| match placement {
	Center => Center
	NearSource => Near(From)
	NearTarget => Near(To)
}

route_edge_labels = |document| document.edges.fold_with_index(
	[],
	|found, edge, index| if edge.label.is_empty() {
		found
	} else {
		found.append({ edge: index, width: edge.label_width, height: edge.label_height, placement: route_label_placement(edge.label_placement) })
	},
)

indexed_edges : Document -> List({ from : U64, to : U64 })
indexed_edges = |document| document.edges.keep_oks(
	|edge| match (document.nodes.find_first_index(|node| node.id == edge.from), document.nodes.find_first_index(|node| node.id == edge.to)) {
		(Ok(from), Ok(to)) => Ok({ from, to })
		_ => Err({})
	},
)

## Ports and connections

find_port : Document, U64, Str -> Try(Port, [NoPort])
find_port = |document, node_id, port_id| match document.nodes.find_first(|node| node.id == node_id) {
	Ok(node) => match node.ports.find_first(|port| port.id == port_id) {
		Ok(port) => Ok(port)
		Err(_) => Err(NoPort)
	}
	Err(_) => Err(NoPort)
}

count_port_connections : Document, U64, Str -> U64
count_port_connections = |document, node_id, port_id| document.edges.fold(
	0.U64,
	|count, edge| if (edge.from == node_id and edge.source_port == port_id) or (edge.to == node_id and edge.target_port == port_id) {
		count + 1
	} else {
		count
	},
)

fallback_side = |role| if role == Input {
	Left
} else {
	Right
}

port_label = |index| ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P"].get(index) ?? "Port"

move_port = |ports, port_id, direction| match ports.find_first_index(|port| port.id == port_id) {
	Err(_) => ports
	Ok(index) => {
		target = if direction == Earlier and index > 0 {
			index - 1
		} else if direction == Later and index + 1 < ports.len() {
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

side_toward : { x : F64, y : F64 }, { x : F64, y : F64 }, Role -> Side
side_toward = |from, to, role| {
	dx = to.x - from.x
	dy = to.y - from.y
	if dx == 0 and dy == 0 {
		fallback_side(role)
	} else if dx.abs() >= dy.abs() {
		if dx < 0 {
			Left
		} else {
			Right
		}
	} else if dy < 0 {
		Top
	} else {
		Bottom
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
					selected_side = resolve_port_placement(port.side, port.resolved_side)
					same = node.ports.fold_with_index(
						[],
						|found, other, other_index| {
							other_side = resolve_port_placement(other.side, other.resolved_side)
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

resolve_port_placement : PortPlacement, Side -> Side
resolve_port_placement = |placement, automatic| match placement {
	Automatic => automatic
	Top => Top
	Right => Right
	Bottom => Bottom
	Left => Left
}

normalize_auto_ports = |document| {
	nodes = document.nodes.map(
		|node| {
			..node,
			ports: node.ports.map(
				|port| if port.side == Automatic and count_port_connections(document, node.id, port.id) == 0 {
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
				|port| if node.id == edge.from and port.id == edge.source_port and port.side == Automatic and count_port_connections(document, node.id, port.id) == 0 {
					{ ..port, resolved_side: side_toward(from_center, to_center, port.role) }
				} else if node.id == edge.to and port.id == edge.target_port and port.side == Automatic and count_port_connections(document, node.id, port.id) == 0 {
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
	(Ok(from), Ok(to)) => from.role == Output and to.role == Input
	_ => False
}

can_add_connection = |document, from_node, from_id, to_node, to_id| valid_connection(document, from_node, from_id, to_node, to_id) and !document.edges.any(|edge| edge.to == to_node and edge.target_port == to_id)

route_side = |value| match value {
	Top => Top
	Right => Right
	Bottom => Bottom
	Left => Left
}

attachments : Document -> List(Route.AttachmentRule)
attachments = |document| document.edges.fold_with_index(
	[],
	|rules, edge, i| match (find_port(document, edge.from, edge.source_port), find_port(document, edge.to, edge.target_port)) {
		(Ok(from), Ok(to)) => rules.concat([{ edge: i, endpoint: From, attachment: Fixed({ side: route_side(from.resolved_side), offset: from.offset }) }, { edge: i, endpoint: To, attachment: Fixed({ side: route_side(to.resolved_side), offset: to.offset }) }])
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

## Validation and document decoding

finite : F64, F64 -> Bool
finite = |a, b| F64.is_finite(a) and F64.is_finite(b)

hex_byte = |byte| (byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 70) or (byte >= 97 and byte <= 102)

valid_color = |color| {
	bytes = Str.to_utf8(color)
	bytes.len() == 7 and bytes.first() == Ok(35) and bytes.drop_first(1).all(hex_byte)
}

valid_port = |port| !port.id.is_empty() and Str.count_utf8_bytes(port.id) <= 80 and Str.count_utf8_bytes(port.label) <= 64 and F64.is_finite(port.offset) and port.offset >= 0 and port.offset <= 1

unique_ports = |node| node.ports.fold_with_index(True, |unique, port, i| unique and !node.ports.fold_with_index(False, |found, other, j| found or (j < i and other.id == port.id)))

input_capacity_ok = |document| document.nodes.all(|node| node.ports.all(|port| port.role != Input or count_port_connections(document, node.id, port.id) <= 1))

valid_document : Document -> Bool
valid_document = |document| document.nodes.len() <= 200 and document.edges.len() <= 500 and document.nodes.all(|node| finite(node.x, node.y) and finite(node.width, node.height) and node.width >= 96 and node.height >= 52 and node.ports.len() <= 16 and node.ports.all(valid_port) and unique_ports(node)) and document.edges.all(|edge| valid_connection(document, edge.from, edge.source_port, edge.to, edge.target_port) and Str.count_utf8_bytes(edge.label) <= 120 and valid_color(edge.color) and finite(edge.label_width, edge.label_height) and edge.label_width >= 0 and edge.label_width <= 1200 and edge.label_height >= 0 and edge.label_height <= 80) and input_capacity_ok(document)

decode_document : Str -> Try(Document, [InvalidDocument])
decode_document = |text| {
	raw : RawDocument
	raw = Json.parse(text) ? |_| InvalidDocument
	nodes : List(Node)
	nodes = raw.nodes.fold(
		Ok([]),
		|state, node| match (state, decode_raw_node(node)) {
			(Ok(found), Ok(converted)) => Ok(found.append(converted))
			_ => Err(InvalidDocument)
		},
	)?
	edges : List(Edge)
	edges = raw.edges.fold(
		Ok([]),
		|state, edge| match (state, decode_raw_edge(edge)) {
			(Ok(found), Ok(converted)) => Ok(found.append(converted))
			_ => Err(InvalidDocument)
		},
	)?
	document : Document
	document = {
		next_node_id: raw.next_node_id,
		next_edge_id: raw.next_edge_id,
		next_port_id: raw.next_port_id,
		direction: parse_direction(raw.direction)?,
		arrangement: parse_arrangement(raw.arrangement)?,
		layers: raw.layers,
		guides: raw.guides,
		nodes,
		edges,
	}
	if valid_document(document) {
		Ok(document)
	} else {
		Err(InvalidDocument)
	}
}

decode_raw_node : RawNode -> Try(Node, [InvalidDocument])
decode_raw_node = |node| {
	ports = node.ports.fold(
		Ok([]),
		|state, port| match (state, decode_raw_port(port)) {
			(Ok(found), Ok(converted)) => Ok(found.append(converted))
			_ => Err(InvalidDocument)
		},
	)?
	Ok({ id: node.id, label: node.label, x: node.x, y: node.y, width: node.width, height: node.height, ports })
}

decode_raw_port : RawPort -> Try(Port, [InvalidDocument])
decode_raw_port = |port| Ok({ id: port.id, label: port.label, role: parse_role(port.role)?, side: parse_port_placement(port.side)?, resolved_side: parse_side(port.resolved_side)?, offset: port.offset })

decode_raw_edge : RawEdge -> Try(Edge, [InvalidDocument])
decode_raw_edge = |edge| Ok({ id: edge.id, from: edge.from, to: edge.to, source_port: edge.source_port, target_port: edge.target_port, label: edge.label, color: edge.color, label_placement: parse_edge_label_placement(edge.label_placement)?, label_width: edge.label_width, label_height: edge.label_height })

encode_document : Document -> Try(Str, [Infinity, NaN, NegativeInfinity])
encode_document = |document| Json.to_str_try({
	next_node_id: document.next_node_id,
	next_edge_id: document.next_edge_id,
	next_port_id: document.next_port_id,
	direction: direction_str(document.direction),
	arrangement: arrangement_str(document.arrangement),
	layers: document.layers,
	guides: document.guides,
	nodes: document.nodes.map(|node| { id: node.id, label: node.label, x: node.x, y: node.y, width: node.width, height: node.height, ports: node.ports.map(|port| { id: port.id, label: port.label, role: role_str(port.role), side: port_placement_str(port.side), resolved_side: side_str(port.resolved_side), offset: port.offset }) }),
	edges: document.edges.map(|edge| { id: edge.id, from: edge.from, to: edge.to, source_port: edge.source_port, target_port: edge.target_port, label: edge.label, color: edge.color, label_placement: edge_label_placement_str(edge.label_placement), label_width: edge.label_width, label_height: edge.label_height }),
})

parse_role : Str -> Try(Role, [InvalidDocument])
parse_role = |raw| match raw {
	"input" => Ok(Input)
	"output" => Ok(Output)
	_ => Err(InvalidDocument)
}

role_str : Role -> Str
role_str = |role| match role {
	Input => "input"
	Output => "output"
}

parse_side : Str -> Try(Side, [InvalidDocument])
parse_side = |raw| match raw {
	"top" => Ok(Top)
	"right" => Ok(Right)
	"bottom" => Ok(Bottom)
	"left" => Ok(Left)
	_ => Err(InvalidDocument)
}

side_str : Side -> Str
side_str = |side| match side {
	Top => "top"
	Right => "right"
	Bottom => "bottom"
	Left => "left"
}

parse_port_placement : Str -> Try(PortPlacement, [InvalidDocument])
parse_port_placement = |raw| match raw {
	"auto" => Ok(Automatic)
	"top" => Ok(Top)
	"right" => Ok(Right)
	"bottom" => Ok(Bottom)
	"left" => Ok(Left)
	_ => Err(InvalidDocument)
}

port_placement_str : PortPlacement -> Str
port_placement_str = |placement| match placement {
	Automatic => "auto"
	Top => "top"
	Right => "right"
	Bottom => "bottom"
	Left => "left"
}

parse_direction : Str -> Try(Direction, [InvalidDocument])
parse_direction = |raw| match raw {
	"down" => Ok(Down)
	"up" => Ok(Up)
	"left" => Ok(Left)
	"right" => Ok(Right)
	_ => Err(InvalidDocument)
}

direction_str : Direction -> Str
direction_str = |direction| match direction {
	Down => "down"
	Up => "up"
	Left => "left"
	Right => "right"
}

parse_arrangement : Str -> Try(Arrangement, [InvalidDocument])
parse_arrangement = |raw| match raw {
	"free" => Ok(Free)
	"force" => Ok(Force)
	"stress" => Ok(Stress)
	"layered" => Ok(Layered)
	_ => Err(InvalidDocument)
}

arrangement_str : Arrangement -> Str
arrangement_str = |arrangement| match arrangement {
	Free => "free"
	Force => "force"
	Stress => "stress"
	Layered => "layered"
}

parse_edge_label_placement : Str -> Try(EdgeLabelPlacement, [InvalidDocument])
parse_edge_label_placement = |raw| match raw {
	"center" => Ok(Center)
	"near-source" => Ok(NearSource)
	"near-target" => Ok(NearTarget)
	_ => Err(InvalidDocument)
}

edge_label_placement_str : EdgeLabelPlacement -> Str
edge_label_placement_str = |placement| match placement {
	Center => "center"
	NearSource => "near-source"
	NearTarget => "near-target"
}

## Automatic sides lock toward the first connected neighbor while occupied,
## and an occupied input rejects a second connection.
expect {
	document = {
		..initial_document,
		nodes: [
			{ id: 1, label: "A", x: 0, y: 0, width: 160, height: 64, ports: [{ ..output_port, side: Automatic, resolved_side: Right }] },
			{ id: 2, label: "B", x: 200, y: 0, width: 160, height: 64, ports: [{ ..input_port, side: Automatic, resolved_side: Left }] },
		],
		edges: [],
	}
	edge = { id: 1, from: 1, to: 2, source_port: "out", target_port: "in", label: "", color: "#7895dd", label_placement: Center, label_width: 0, label_height: 0 }
	locked = lock_new_connection(document, edge)
	connected = { ..locked, edges: [edge] }
	(find_port(locked, 1, "out") ?? output_port).resolved_side == Right and (find_port(locked, 2, "in") ?? input_port).resolved_side == Left and !can_add_connection(connected, 1, "out", 2, "in")
}

## Reordering preserves stable port identities and moves only the requested
## neighbor, so persisted edges continue to name the same ports.
expect {
	ports = [input_port, { ..input_port, id: "alternate", label: "Alternate" }, output_port]
	moved = move_port(ports, "out", Earlier)
	unchanged = move_port(moved, "in", Earlier)
	(moved.get(1) ?? input_port).id == "out" and moved.len() == ports.len() and unchanged == moved
}
