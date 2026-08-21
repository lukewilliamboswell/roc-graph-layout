## One validated editor mutation requested by the browser.
Command := [
	AddEdge({ from : U64, source_port : Str, target_port : Str, to : U64 }),
	AddNode,
	AddPort({ node : U64, role : [Input, Output] }),
	Arrange({ algorithm : [Force, Layered, Stress], direction : [Down, Left, Right, Up] }),
	DeleteEdge(U64),
	DeleteNode(U64),
	DeletePort({ node : U64, port_id : Str }),
	MoveNode({ node : U64, x : F64, y : F64 }),
	MovePort({ movement : [Earlier, Later], node : U64, port_id : Str }),
	ReevaluatePort({ node : U64, port_id : Str }),
	RenameNode({ label : Str, node : U64 }),
	ReplaceDocument(Str),
	Reset,
	ResizeNode({ height : F64, node : U64, width : F64 }),
	UpdateEdge({ color : Str, edge : U64, label : Str, label_height : F64, label_placement : [Center, NearSource, NearTarget], label_width : F64 }),
	UpdatePort({ label : Str, node : U64, placement : [Automatic, Bottom, Left, Right, Top], port_id : Str, role : [Input, Output] }),
].{
	is_eq : _

	## Decode the editor's existing `commandKind` and `commandPayload` signals.
	## String spellings belong to this browser boundary; successful commands are
	## fully typed and contain only fields meaningful to their operation.
	from_browser : Str, Str -> Try(Command, [InvalidPayload])
	from_browser = decode_browser_command
}

decode_browser_command : Str, Str -> Try(Command, [InvalidPayload])
decode_browser_command = |kind, json| match kind {
	"add-node" => Ok(AddNode)
	"move-node" => {
		payload : { node : U64, x : F64, y : F64 }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(MoveNode(payload))
	}
	"resize-node" => {
		payload : { height : F64, node : U64, width : F64 }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(ResizeNode(payload))
	}
	"rename-node" => {
		payload : { label : Str, node : U64 }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(RenameNode(payload))
	}
	"add-port" => {
		payload : { node : U64, role : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		role = parse_role(payload.role)?
		Ok(AddPort({ node: payload.node, role }))
	}
	"move-port" => {
		payload : { direction : Str, node : U64, port_id : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		movement = parse_movement(payload.direction)?
		Ok(MovePort({ movement, node: payload.node, port_id: payload.port_id }))
	}
	"update-port" => {
		payload : { label : Str, node : U64, port_id : Str, role : Str, side : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		role = parse_role(payload.role)?
		placement = parse_port_placement(payload.side)?
		Ok(UpdatePort({ label: payload.label, node: payload.node, placement, port_id: payload.port_id, role }))
	}
	"reevaluate-port" => {
		payload : { node : U64, port_id : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(ReevaluatePort(payload))
	}
	"delete-port" => {
		payload : { node : U64, port_id : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(DeletePort(payload))
	}
	"delete-node" => {
		payload : { node : U64 }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(DeleteNode(payload.node))
	}
	"delete-edge" => {
		payload : { edge : U64 }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(DeleteEdge(payload.edge))
	}
	"update-edge" => {
		payload : { color : Str, edge : U64, label : Str, label_height : F64, label_width : F64, placement : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		label_placement = parse_label_placement(payload.placement)?
		Ok(UpdateEdge({ color: payload.color, edge: payload.edge, label: payload.label, label_height: payload.label_height, label_placement, label_width: payload.label_width }))
	}
	"add-edge" => {
		payload : { from : U64, source_port : Str, target_port : Str, to : U64 }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(AddEdge(payload))
	}
	"arrange" => {
		payload : { algorithm : Str, direction : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		algorithm = parse_algorithm(payload.algorithm)?
		direction = parse_direction(payload.direction)?
		Ok(Arrange({ algorithm, direction }))
	}
	"replace-document" => {
		payload : { document : Str }
		payload = Json.parse(json) ? |_| InvalidPayload
		Ok(ReplaceDocument(payload.document))
	}
	"reset" => Ok(Reset)
	_ => Err(InvalidPayload)
}

parse_role = |raw| match raw {
	"input" => Ok(Input)
	"output" => Ok(Output)
	_ => Err(InvalidPayload)
}

parse_movement = |raw| match raw {
	"up" => Ok(Earlier)
	"down" => Ok(Later)
	_ => Err(InvalidPayload)
}

parse_port_placement = |raw| match raw {
	"auto" => Ok(Automatic)
	"top" => Ok(Top)
	"right" => Ok(Right)
	"bottom" => Ok(Bottom)
	"left" => Ok(Left)
	_ => Err(InvalidPayload)
}

parse_label_placement = |raw| match raw {
	"center" => Ok(Center)
	"near-source" => Ok(NearSource)
	"near-target" => Ok(NearTarget)
	_ => Err(InvalidPayload)
}

parse_algorithm = |raw| match raw {
	"force" => Ok(Force)
	"stress" => Ok(Stress)
	"layered" => Ok(Layered)
	_ => Err(InvalidPayload)
}

parse_direction = |raw| match raw {
	"down" => Ok(Down)
	"up" => Ok(Up)
	"left" => Ok(Left)
	"right" => Ok(Right)
	_ => Err(InvalidPayload)
}

## fuzz regression: command payloads select an exact typed shape.
expect {
	command = Command.from_browser("add-port", "{\"node\":7,\"role\":\"input\"}")?
	command == AddPort({ node: 7, role: Input })
}

expect {
	command = Command.from_browser("move-port", "{\"node\":7,\"port_id\":\"out\",\"direction\":\"up\"}")?
	command == MovePort({ movement: Earlier, node: 7, port_id: "out" })
}

expect Command.from_browser("arrange", "{\"algorithm\":\"free\",\"direction\":\"down\"}").is_err()

expect Command.from_browser("update-port", "{\"node\":7,\"port_id\":\"out\",\"label\":\"A\",\"role\":\"input\",\"side\":\"diagonal\"}").is_err()
