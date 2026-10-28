import DiagramView
import Drawing
import Flowchart
import OracleJson
import StateDiagram
import StateDraw
import StateModel
import Theme

## Internal oracle observation. All source semantics remain explicit;
## geometry is measured from the same phases used by the public renderer.
StateOracle :: {}.{

	## Pinned Mermaid 12.2 state typography and label boxes: 14px Inter,
	## 1.1em baselines, state padding8, wrapping120 and rounded corners12.
	## The palette matches its classic white-state picture independently
	## from the package's independently configurable appearance options.
	reference_theme : Theme.Options
	reference_theme = Theme.Options.{ font_size: 14, line_height: 1.1, padding: 15, max_label_width: 120, corner_radius: 12, line_width: 2, background: Drawing.white, node_fill: Drawing.white, node_stroke: Drawing.rgb(0x28253D), node_text: Drawing.rgb(0x28253D), line: Drawing.black, transition_label_background: Drawing.white, label_text: Drawing.rgb(0x28253D), accent: Drawing.black, group_fill: Drawing.rgb(0xFDF4FF), group_stroke: Drawing.rgb(0xE879F9), note_fill: Drawing.rgb(0xFFF5AD), note_stroke: Drawing.rgb(0x28253D), note_text: Drawing.rgb(0x28253D) }

	inspect : Str, Theme.Options -> Str
	inspect = |source, theme| StateOracle.inspect_sized(source, theme, [])

	inspect_sized : Str, Theme.Options, List(OracleJson.Size) -> Str
	inspect_sized = |source, theme, inputs| match StateDiagram.parse(source) {
		Err(_) => OracleJson.rejected("state")
		Ok(diagram) => {
			if !Theme.validate(theme).is_empty() {
				return OracleJson.rejected("state")
			}
			setup = StateDraw.setup_sized(diagram, theme, inputs)
			picture = DiagramView.finish(StateDraw.draw_setup(diagram, theme, setup), theme)
			nodes = setup.geometry.nodes.map_with_index(
				|box, i| OracleJson.object([
					("id", OracleJson.string(StateOracle.node_id(diagram, i))),
					("box", OracleJson.rect(box)),
				]),
			)
			groups = setup.geometry.groups.take_first(diagram.groups.len()).map_with_index(
				|box, i| OracleJson.object([
					("id", OracleJson.string(StateOracle.group_id(diagram, i))),
					("box", OracleJson.rect(box)),
				]),
			)
			edges = setup.geometry.edges.map_with_index(
				|edge, i| {
					model = setup.flow.edges.get(i) ?? { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }
					OracleJson.object([
						("id", OracleJson.string(if (i < diagram.transitions.len()) "transition-${i.to_str()}" else "note-${(i - diagram.transitions.len()).to_str()}")),
						("from", OracleJson.string(StateOracle.flow_endpoint(diagram, model.from))),
						("to", OracleJson.string(StateOracle.flow_endpoint(diagram, model.to))),
						("points", OracleJson.array(edge.points.map(OracleJson.point))),
					])
				},
			)
			labels = setup.sizes.edge_labels.map_with_index(
				|label, i| match (label, setup.geometry.edges.get(i)) {
					(Some(block), Ok(edge)) => match edge.label {
						None => "null"
						Some(point) => OracleJson.object([
							("id", OracleJson.string("transition-${i.to_str()}")),
							("size_kind", OracleJson.string("label")),
							("text", OracleJson.string((diagram.transitions.get(i) ?? { from: Node(0), to: Node(0), label: "" }).label)),
							("box", OracleJson.rect({ x: point.x - block.width / 2, y: point.y - block.height / 2, width: block.width, height: block.height })),
						])
					}
					_ => "null"
				},
			).keep_if(|label| label != "null")
			titles = diagram.groups.map_with_index(
				|group, i| {
					block = setup.sizes.group_titles.get(i) ?? { lines: [], width: 0, height: 0 }
					rect = setup.geometry.groups.get(i) ?? setup.geometry.bounds
					OracleJson.object([
						("id", OracleJson.string("group-${group.id}")),
						("size_kind", OracleJson.string("group")),
						("text", OracleJson.string(group.title)),
						("box", OracleJson.rect({ x: rect.x + rect.width / 2 - block.width / 2, y: rect.y, width: block.width, height: block.height })),
					])
				},
			)
			text_runs = picture.items.fold(
				[],
				|items, item| match item {
					Shape(_) => items
					Text(label) => items.append(StateOracle.label_json(label, items.len(), theme))
					StyledText(styled) => items.append(StateOracle.label_json(styled.label, items.len(), theme))
				},
			)
			OracleJson.object([
				("accepted", "true"),
				("family", OracleJson.string("state")),
				("semantic", StateOracle.semantic(diagram)),
				(
					"geometry",
					OracleJson.object([
						("view_box", OracleJson.rect(picture.view)),
						("nodes", OracleJson.array(nodes)),
						("groups", OracleJson.array(groups)),
						("edges", OracleJson.array(edges)),
						("labels", OracleJson.array(labels.concat(titles))),
						("text_runs", OracleJson.array(text_runs)),
					]),
				),
			])
		}
	}

	label_json : Drawing.Label, U64, Theme.Options -> Str
	label_json = |label, i, theme| {
		block = StateDraw.block(label.text, theme)
		OracleJson.object([
			("id", OracleJson.string("label-${i.to_str()}")),
			("text", OracleJson.string(label.text)),
			("box", OracleJson.rect({ x: label.origin.x - block.width / 2, y: label.origin.y - StateDraw.baseline(theme), width: block.width, height: block.height })),
		])
	}

	semantic : StateModel.Diagram -> Str
	semantic = |diagram| OracleJson.object([
		("direction", OracleJson.string(StateOracle.direction(diagram.direction))),
		(
			"states",
			OracleJson.array(
				diagram.states.map(
					|state| OracleJson.object([
						("id", OracleJson.string(StateOracle.state_id(diagram, state))),
						("parent", StateOracle.parent(diagram, state.container)),
						("declared_kind", OracleJson.string(StateOracle.kind(state.kind))),
						("effective_kind", OracleJson.string(StateOracle.kind(state.effective_kind))),
						("descriptions", OracleJson.strings(state.descriptions)),
						("classes", OracleJson.strings(state.classes)),
						("styles", OracleJson.strings(state.styles)),
					]),
				),
			),
		),
		(
			"groups",
			OracleJson.array(
				diagram.groups.map(
					|group| OracleJson.object([
						("id", OracleJson.string(group.id)),
						("parent", StateOracle.parent(diagram, group.container)),
						(
							"direction",
							OracleJson.string(
								match group.direction {
									Inherit => "TB"
									Set(direction) => StateOracle.direction(direction)
								},
							),
						),
						("direction_set", OracleJson.boolean(group.direction != Inherit)),
						("descriptions", OracleJson.strings(group.descriptions)),
						("classes", OracleJson.strings(group.classes)),
						("styles", OracleJson.strings(group.styles)),
					]),
				),
			),
		),
		(
			"transitions",
			OracleJson.array(
				diagram.transitions.map_with_index(
					|edge, i| OracleJson.object([
						("id", OracleJson.string("transition-${i.to_str()}")),
						("from", OracleJson.string(StateOracle.flow_endpoint(diagram, edge.from))),
						("to", OracleJson.string(StateOracle.flow_endpoint(diagram, edge.to))),
						("label", OracleJson.string(edge.label)),
					]),
				),
			),
		),
		(
			"notes",
			OracleJson.array(
				diagram.notes.map(
					|note| OracleJson.object([
						("state", OracleJson.string(StateOracle.flow_endpoint(diagram, note.state))),
						("side", OracleJson.string(if (note.side == Left) "left" else "right")),
						("text", OracleJson.string(note.text)),
						("after_transition", note.after_transition.to_str()),
					]),
				),
			),
		),
		(
			"classes",
			OracleJson.array(
				diagram.classes.map(
					|definition| OracleJson.object([
						("name", OracleJson.string(definition.name)),
						("styles", OracleJson.strings(definition.styles)),
						("text_styles", OracleJson.strings(definition.styles.keep_if(|style| style.contains("color")).map(|style| Str.join_with(style.split_on("color"), "fill")))),
					]),
				),
			),
		),
	])

	direction : Flowchart.Direction -> Str
	direction = |value| match value {
		Down => "TB"
		Up => "BT"
		Right => "LR"
		Left => "RL"
	}

	kind : StateModel.Kind -> Str
	kind = |value| match value {
		Normal => "normal"
		Initial => "initial"
		Final => "final"
		Choice => "choice"
		Fork => "fork"
		Join => "join"
	}

	parent : StateModel.Diagram, Flowchart.Container -> Str
	parent = |diagram, container| match container {
		Root => "null"
		Group(i) => OracleJson.string((diagram.groups.get(i) ?? { id: "", title: "", descriptions: [], container: Root, direction: Inherit, classes: [], styles: [] }).id)
	}

	state_id : StateModel.Diagram, StateModel.State -> Str
	state_id = |diagram, state| match state.kind {
		Initial | Final => {
			scope = match state.container {
				Root => "root"
				Group(i) => (diagram.groups.get(i) ?? { id: "", title: "", descriptions: [], container: Root, direction: Inherit, classes: [], styles: [] }).id
			}
			suffix = if (state.kind == Initial) "start" else "end"
			"${scope}_${suffix}"
		}
		_ => state.id
	}

	node_id : StateModel.Diagram, U64 -> Str
	node_id = |diagram, i| match diagram.states.get(i) {
		Ok(state) => StateOracle.state_id(diagram, state)
		Err(_) => {
			note = diagram.notes.get(i - diagram.states.len()) ?? { state: Node(0), side: Right, text: "", after_transition: 0 }
			"${StateOracle.flow_endpoint(diagram, note.state)}----note"
		}
	}

	group_id : StateModel.Diagram, U64 -> Str
	group_id = |diagram, i| match diagram.groups.get(i) {
		Ok(group) => group.id
		Err(_) => {
			note = diagram.notes.get(i - diagram.groups.len()) ?? { state: Node(0), side: Right, text: "", after_transition: 0 }
			"${StateOracle.flow_endpoint(diagram, note.state)}----parent"
		}
	}

	flow_endpoint : StateModel.Diagram, Flowchart.Endpoint -> Str
	flow_endpoint = |diagram, endpoint| match endpoint {
		Node(i) => StateOracle.node_id(diagram, i)
		Group(i) => StateOracle.group_id(diagram, i)
	}
}

## Oracle-derived regression: a single state description replaces the id;
## an alias and later descriptions share one ordered description list.
## Recorded by pinned Mermaid12.2 in tests/mermaid/state/descriptions.mmd.
expect {
	diagram = StateDiagram.parse("stateDiagram-v2\nPlain: A description replaces the identifier\nstate \"An alias\" as Aliased\nAliased: entry / initialise\nAliased: exit / clean up\n")?
	diagram.states.map(|state| state.descriptions) == [["A description replaces the identifier"], ["An alias", "entry / initialise", "exit / clean up"]]
		and diagram.states.map(|state| state.label) == ["A description replaces the identifier", "An alias"]
}

## Oracle-derived regression: stateStart and stateEnd are14px, choices28px,
## fork/join bars70x10, and ordinary state label areas at least120px.
expect {
	diagram = StateDiagram.parse("stateDiagram-v2\nstate Pick <<choice>>\nstate Fork <<fork>>\nstate Join <<join>>\n[*] --> Normal\nNormal --> [*]\n")?
	sizes = StateDraw.measure_sizes(diagram, StateOracle.reference_theme).nodes
	sizes.map(|size| { width: size.width, height: size.height }) == [
		{ width: 28, height: 28 },
		{ width: 70, height: 10 },
		{ width: 70, height: 10 },
		{ width: 14, height: 14 },
		{ width: 136, height: 33 },
		{ width: 14, height: 14 },
	]
}

## Oracle-derived regression: notes are real nodes with dashed associations
## inside transparent root groups; they are not detached sidebars.
expect {
	diagram = StateDiagram.parse("stateDiagram-v2\nstate Group {\nA --> B\n}\nnote right of A: A note\n")?
	setup = StateDraw.setup(diagram, StateOracle.reference_theme)
	setup.flow.nodes.len() == 3 and setup.flow.groups.len() == 2 and setup.flow.edges.len() == 2
		and setup.flow.edges.last()?.line == Dotted and setup.flow.edges.last()?.end == None
		and setup.sizes.nodes.last()?.width == 150
		and setup.sizes.group_titles.last()?.height == 17
}

## Oracle-derived late-choice behavior: preserve the author's declaration
## in the public model while rendering the normal state registered by its
## earlier transition, exactly as pinned Mermaid does.
expect {
	diagram = StateDiagram.parse("stateDiagram-v2\n[*] --> Pick\nstate Pick <<choice>>\nPick --> Finished: proceed\n")?
	diagram.states.get(1)?.kind == Choice and diagram.states.get(1)?.effective_kind == Normal
}

expect {
	diagram = StateDiagram.parse("stateDiagram-v2\nA --> B: label\n")?
	supplied = StateDraw.setup_sized(diagram, StateOracle.reference_theme, [{ kind: "node", id: "A", width: 211, height: 57 }, { kind: "label", id: "transition-0", width: 90, height: 25 }])
	supplied.sizes.nodes.first()?.width == 211 and supplied.sizes.nodes.first()?.height == 57
		and supplied.sizes.edge_labels.first()? == Some({ lines: ["label"], width: 90, height: 25 })
}

## Pinned Chrome/Mermaid oracle regression: two notes register inline and
## association edges register between the second and final transition.
## Actual glyph/node measurements are inputs; positions are independent
## oracle outputs, not a second invocation of the native layout.
expect {
	d = StateDiagram.parse("stateDiagram-v2\ndirection LR\n[*] --> Ready\nReady --> Done: finish\nnote left of Ready: Prepare the work before it starts.\nnote right of Done\n        The work has finished.\n        Notify its subscribers.\nend note\nDone --> [*]\n")?
	setup = StateDraw.setup_sized(
		d,
		StateOracle.reference_theme,
		[
			{ kind: "node", id: "root_start", width: 14, height: 14 },
			{ kind: "node", id: "Ready", width: 136, height: 33 },
			{ kind: "node", id: "Done", width: 136, height: 33 },
			{ kind: "node", id: "root_end", width: 14.013293266296387, height: 14 },
			{ kind: "node", id: "Ready----note", width: 150, height: 62.40000152587888 },
			{ kind: "node", id: "Done----note", width: 150, height: 93.19999694824219 },
			{ kind: "label", id: "transition-1", width: 35.90625, height: 17 },
			{ kind: "group", id: "note-group-Ready", width: 217.78125, height: 17 },
			{ kind: "group", id: "note-group-Done", width: 150.28125, height: 32.400001525878906 },
		],
	)
	start = setup.geometry.nodes.get(0)?
	ready = setup.geometry.nodes.get(1)?
	left_note = setup.geometry.nodes.get(4)?
	right_note = setup.geometry.nodes.get(5)?
	(start.x - 205.890625).abs() < 0.0001 and (start.y - 111.69999694824217).abs() < 0.0001
		and (ready.x - 269.890625).abs() < 0.0001 and (ready.y - 161.80000305175778).abs() < 0.0001
		and (left_note.x - 45.890625).abs() < 0.0001 and (left_note.y - 206.6999931335449).abs() < 0.0001
		and (right_note.x - 735.796875).abs() < 0.0001 and (right_note.y - 71.4000015258789).abs() < 0.0001
}

## Pinned oracle regression: a disconnected annotated state retains its
## declaration order, while a separate chain has loops and parallel edges.
expect {
	d = StateDiagram.parse("stateDiagram-v2\ndirection LR\nstate \"An isolated state with a long name that wraps without escaping its box\" as Isolated\n[*] --> A\nA --> A: retry\nA --> B: first path\nA --> B: second path\nB --> [*]\nnote left of Isolated\n        An explicitly left-hand multi-line note.\n        This remains separate from the graph.\nend note\n")?
	setup = StateDraw.setup_sized(
		d,
		StateOracle.reference_theme,
		[
			{ kind: "node", id: "Isolated", width: 136, height: 94.60000610351565 },
			{ kind: "node", id: "root_start", width: 14, height: 14 },
			{ kind: "node", id: "A", width: 136, height: 33 },
			{ kind: "node", id: "B", width: 136, height: 33 },
			{ kind: "node", id: "root_end", width: 14.013293266296387, height: 14 },
			{ kind: "node", id: "Isolated----note", width: 150, height: 124.02148437500003 },
			{ kind: "label", id: "transition-1", width: 31.140625, height: 17 },
			{ kind: "label", id: "transition-2", width: 59.1875, height: 17 },
			{ kind: "label", id: "transition-3", width: 82.171875, height: 17 },
			{ kind: "group", id: "note-group-Isolated", width: 252.578125, height: 32.421485900878906 },
		],
	)
	isolated = setup.geometry.nodes.get(0)?
	start = setup.geometry.nodes.get(1)?
	note = setup.geometry.nodes.get(5)?
	(isolated.x - 304.578125).abs() < 0.0001 and (isolated.y - 191.63221740722653).abs() < 0.0001
		and (start.x - 223.2890625).abs() < 0.0001 and (start.y - 66.5).abs() < 0.0001
		and (note.x - 63.2890625).abs() < 0.0001 and (note.y - 176.92147827148435).abs() < 0.0001
}
