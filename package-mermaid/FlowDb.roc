import Bytes
import FlowParser
import FlowText

## The effects of Mermaid's `flowDb` for the calls `FlowParser` emits, and the
## reading of the result that Mermaid hands to layout (`getData`): which ids
## are nodes and which are groups, who contains whom, and what each edge
## looks like. Indices replace Mermaid's string references in the result.
FlowDb :: {}.{

	Vertex : { id : Str, text : Str, shape : [None, Some(Str)], styles : List(Str), classes : List(Str) }

	EdgeRecord : {
		start : Str,
		end : Str,
		type : FlowParser.LinkType,
		stroke : FlowParser.Stroke,
		length : U64,
		text : Str,
		id : Str,
		classes : List(Str),
		styles : List(Str),
	}

	SubgraphRecord : { id : Str, nodes : List(Str), title : Str, dir : [None, Some(Str)], classes : List(Str) }

	ClassRecord : { id : Str, styles : List(Str) }

	State : {
		vertices : List(Vertex),
		vertex_index : Dict(Str, U64),
		edges : List(EdgeRecord),
		edge_index : Dict(Str, U64),
		pair_counts : Dict(Str, U64),
		subgraphs : List(SubgraphRecord),
		subgraph_index : Dict(Str, U64),
		members : Dict(Str, Bool),
		subgraph_count : U64,
		closed : List(Str),
		classes : List(ClassRecord),
		class_index : Dict(Str, U64),
		default_edge_style : List(Str),
	}

	Problem : [TooManyEdges, MissingLinkStyleEdge(Str), UnnamedGroup, Unsupported(Str)]

	## Mermaid's default `maxEdges`.
	max_edges : U64
	max_edges = 500

	empty : State
	empty = {
		vertices: [],
		vertex_index: Dict.empty(),
		edges: [],
		edge_index: Dict.empty(),
		pair_counts: Dict.empty(),
		subgraphs: [],
		subgraph_index: Dict.empty(),
		members: Dict.empty(),
		subgraph_count: 0,
		closed: [],
		classes: [],
		class_index: Dict.empty(),
		default_edge_style: [],
	}

	apply : List(FlowParser.Event) -> Try(State, Problem)
	apply = |events| {
		var $state = FlowDb.empty
		for event in events {
			$state = match event {
				Vertex({ id, text, shape }) => FlowDb.add_vertex($state, id, text, shape, [])
				VertexStyle({ id, styles }) => FlowDb.add_vertex($state, id, None, None, styles)
				Link({ starts, ends, info }) => FlowDb.add_link($state, starts, ends, info)?
				SetClass({ ids, class }) => FlowDb.set_class($state, ids, class)
				AddClass({ ids, styles }) => FlowDb.add_class($state, ids, styles)
				LinkStyle({ positions, styles }) => FlowDb.link_style($state, positions, styles)?
				LinkInterpolate({ positions }) => FlowDb.check_positions($state, positions)?
				Subgraph({ header, items }) => FlowDb.add_subgraph($state, header, items)?
			}
		}
		Ok($state)
	}

	## `addVertex`. An id already used by an edge is edge metadata, not a
	## vertex, so nothing happens.
	add_vertex : State, Str, [None, Some(FlowParser.Text)], [None, Some(Str)], List(Str) -> State
	add_vertex = |state, id, text, shape, styles| {
		if FlowText.trim(id) == "" or state.edge_index.contains(id) {
			state
		} else {
			{ index, created } = match state.vertex_index.get(id) {
				Ok(found) => { index: found, created: state }
				Err(_) => {
					appended = state.vertices.len()
					{
						index: appended,
						created: {
							..state,
							vertices: state.vertices.append({ id, text: id, shape: None, styles: [], classes: [] }),
							vertex_index: state.vertex_index.insert(id, appended),
						},
					}
				}
			}
			vertex = created.vertices.get(index) ?? { id, text: id, shape: None, styles: [], classes: [] }
			with_text = match text {
				Some(t) => { ..vertex, text: FlowText.strip_quotes(FlowText.sanitize(FlowText.trim(t.text))) }
				None => vertex
			}
			with_shape = match shape {
				Some(_) => { ..with_text, shape }
				None => with_text
			}
			updated = { ..with_shape, styles: with_shape.styles.concat(styles) }
			# `index` was found in or appended to the vertex list above.
			{ ..created, vertices: created.vertices.set(index, updated) ?? [] }
		}
	}

	## `addLink`: every start to every end. A link id applies only to the pair
	## of the last start and the first end.
	add_link : State, List(Str), List(Str), FlowParser.LinkInfo -> Try(State, Problem)
	add_link = |state, starts, ends, info| {
		link_id = match info.id {
			Some(raw) => Some(FlowDb.without_first_at(raw))
			None => None
		}
		last_start = starts.last() ?? ""
		first_end = ends.first() ?? ""
		var $state = state
		for start in starts {
			for end in ends {
				id = if (start == last_start and end == first_end) link_id else None
				$state = FlowDb.add_single_link($state, start, end, info, id)?
			}
		}
		Ok($state)
	}

	without_first_at : Str -> Str
	without_first_at = |raw| {
		bytes = raw.to_utf8()
		match bytes.find_first_index(|b| b == '@') {
			Ok(at) => Str.from_utf8_lossy(bytes.take_first(at).concat(bytes.drop_first(at + 1)))
			Err(_) => raw
		}
	}

	add_single_link : State, Str, Str, FlowParser.LinkInfo, [None, Some(Str)] -> Try(State, Problem)
	add_single_link = |state, start, end, info, id| {
		text = match info.text {
			Some(t) => FlowText.strip_quotes(FlowText.sanitize(FlowText.trim(t.text)))
			None => ""
		}
		pair = Str.concat(Str.concat(start, "\n"), end)
		existing = state.pair_counts.get(pair) ?? 0
		user_id = match id {
			Some(wanted) if wanted != "" and !state.edge_index.contains(wanted) => Some(wanted)
			_ => None
		}
		edge_id = match user_id {
			Some(wanted) => wanted
			None => {
				counter = if (existing == 0) 0 else existing + 1
				"L_${start}_${end}_${counter.to_str()}"
			}
		}
		if state.edges.len() >= FlowDb.max_edges {
			Err(TooManyEdges)
		} else {
			index = state.edges.len()
			edge = {
				start,
				end,
				type: info.type,
				stroke: info.stroke,
				length: if (info.length > 10) 10 else info.length,
				text,
				id: edge_id,
				classes: [],
				styles: [],
			}
			Ok({
				..state,
				edges: state.edges.append(edge),
				edge_index: if (state.edge_index.contains(edge_id)) state.edge_index else state.edge_index.insert(edge_id, index),
				pair_counts: state.pair_counts.insert(pair, existing + 1),
			})
		}
	}

	## `setClass`: each comma-separated id that names a vertex, an edge, or a
	## subgraph declared so far gains the class.
	set_class : State, Str, Str -> State
	set_class = |state, ids, class| {
		var $state = state
		for id in ids.split_on(",") {
			match $state.vertex_index.get(id) {
				Ok(i) => {
					vertex = $state.vertices.get(i) ?? { id, text: id, shape: None, styles: [], classes: [] }
					$state = { ..$state, vertices: $state.vertices.set(i, { ..vertex, classes: vertex.classes.append(class) }) ?? [] }
				}
				Err(_) => {}
			}
			match $state.edge_index.get(id) {
				Ok(i) => {
					edge = $state.edges.get(i) ?? FlowDb.placeholder_edge
					$state = { ..$state, edges: $state.edges.set(i, { ..edge, classes: edge.classes.append(class) }) ?? [] }
				}
				Err(_) => {}
			}
			match $state.subgraph_index.get(id) {
				Ok(i) => {
					sub = $state.subgraphs.get(i) ?? { id, nodes: [], title: "", dir: None, classes: [] }
					$state = { ..$state, subgraphs: $state.subgraphs.set(i, { ..sub, classes: sub.classes.append(class) }) ?? [] }
				}
				Err(_) => {}
			}
		}
		$state
	}

	placeholder_edge : EdgeRecord
	placeholder_edge = { start: "", end: "", type: Open, stroke: Normal, length: 1, text: "", id: "", classes: [], styles: [] }

	## `addClass`: styles are joined with commas, re-split on unescaped
	## commas and semicolons, and stored on each comma-separated class.
	add_class : State, Str, List(Str) -> State
	add_class = |state, ids, styles| {
		joined = Str.join_with(styles, ",")
		escaped = joined.replace_each("\\,", "§§§").replace_each(",", ";").replace_each("§§§", ",")
		parts = escaped.split_on(";")
		var $state = state
		for id in ids.split_on(",") {
			index = match $state.class_index.get(id) {
				Ok(i) => i
				Err(_) => {
					i = $state.classes.len()
					$state = { ..$state, classes: $state.classes.append({ id, styles: [] }), class_index: $state.class_index.insert(id, i) }
					i
				}
			}
			class = $state.classes.get(index) ?? { id, styles: [] }
			$state = { ..$state, classes: $state.classes.set(index, { ..class, styles: class.styles.concat(parts) }) ?? [] }
		}
		$state
	}

	## A `linkStyle` position as JavaScript indexes an array with it: only a
	## canonical decimal below the edge count names an edge.
	position : State, Str -> Try([Default, Index(U64)], Problem)
	position = |state, text| {
		if text == "default" {
			Ok(Default)
		} else {
			bytes = text.to_utf8()
			canonical = bytes.len() > 0 and bytes.len() <= 18 and (bytes.len() == 1 or (bytes.first() ?? '0') != '0')
			value = bytes.fold(0, |acc, d| acc * 10 + (d - '0').to_u64())
			if (canonical and value < state.edges.len()) Ok(Index(value)) else Err(MissingLinkStyleEdge(text))
		}
	}

	check_positions : State, List(Str) -> Try(State, Problem)
	check_positions = |state, positions| {
		for text in positions {
			_ = FlowDb.position(state, text)?
		}
		Ok(state)
	}

	## `updateLink`. A style without a fill gains `fill:none`.
	link_style : State, List(Str), List(Str) -> Try(State, Problem)
	link_style = |state, positions, styles| {
		var $state = state
		for text in positions {
			match FlowDb.position($state, text)? {
				Default => {
					$state = { ..$state, default_edge_style: styles }
				}
				Index(i) => {
					edge = $state.edges.get(i) ?? FlowDb.placeholder_edge
					filled = if (styles.any(|s| s.starts_with("fill"))) styles else styles.append("fill:none")
					$state = { ..$state, edges: $state.edges.set(i, { ..edge, styles: filled }) ?? [] }
				}
			}
		}
		Ok($state)
	}

	## `addSubGraph`.
	add_subgraph : State, FlowParser.Header, List(FlowParser.Item) -> Try(State, Problem)
	add_subgraph = |state, header, items| {
		named = FlowDb.subgraph_name(header)?
		var $seen = Dict.empty()
		var $list = []
		for item in items {
			for candidate in FlowDb.item_ids(state, item) {
				if FlowText.trim(candidate) != "" and !$seen.contains(candidate) {
					$seen = $seen.insert(candidate, True)
					$list = $list.append(candidate)
				}
			}
		}
		# The last `direction` statement in the body wins.
		dir = items.fold(
			None,
			|found, item|
				match item {
					Direction(value) => Some(value)
					_ => found
				},
		)
		raw_title = named.raw_title
		final_id = match named.id {
			Some(given) => given
			None => "subGraph${state.subgraph_count.to_str()}"
		}
		title = FlowText.trim(FlowText.sanitize(raw_title))
		nodes = $list.keep_if(|n| !state.members.contains(n) and n != final_id)
		members = nodes.fold(state.members, |acc, n| acc.insert(n, True))
		counted = { ..state, subgraph_count: state.subgraph_count + 1, members, closed: state.closed.append(final_id) }
		match state.subgraph_index.get(final_id) {
			Ok(i) => {
				existing = counted.subgraphs.get(i) ?? { id: final_id, nodes: [], title, dir, classes: [] }
				Ok({ ..counted, subgraphs: counted.subgraphs.set(i, { ..existing, nodes: existing.nodes.concat(nodes) }) ?? [] })
			}
			Err(_) => {
				i = counted.subgraphs.len()
				Ok({
					..counted,
					subgraphs: counted.subgraphs.append({ id: final_id, nodes, title, dir, classes: [] }),
					subgraph_index: counted.subgraph_index.insert(final_id, i),
				})
			}
		}
	}

	## A subgraph header's id, if it has one, and its raw title. The
	## anonymous form reaches `_id.text` on an undefined `_id`, which throws,
	## so Mermaid rejects it. In the plain form the id doubles as the title,
	## and whitespace anywhere in it means there is no id.
	subgraph_name : FlowParser.Header -> Try({ id : [Some(Str), None], raw_title : Str }, Problem)
	subgraph_name = |header|
		match header {
			Named({ id, title }) => Ok({ id: Some(FlowText.trim(id)), raw_title: title.text })
			Plain(text) => Ok({ id: if (FlowDb.has_space(text.text)) None else Some(FlowText.trim(text.text)), raw_title: text.text })
			Anonymous => Err(UnnamedGroup)
		}

	## The ids one body item contributes to its subgraph.
	item_ids : State, FlowParser.Item -> List(Str)
	item_ids = |state, item|
		match item {
			Ids(found) => found
			Closed(k) => [state.closed.get(k) ?? ""]
			Direction(_) => []
		}

	reversed : List(a) -> List(a)
	reversed = |list| list.fold_rev(List.with_capacity(list.len()), |item, acc| acc.append(item))

	## JavaScript `/\s/.test`.
	has_space : Str -> Bool
	has_space = |text| {
		bytes = text.to_utf8()
		var $i = 0
		var $found = False
		while !$found and $i < bytes.len() {
			if Bytes.space_len(bytes, $i) > 0 {
				$found = True
			}
			$i = $i + 1
		}
		$found
	}

	## What Mermaid hands to layout, with ids resolved to indices.
	diagram : State, Str -> Try(Diagram, Problem)
	diagram = |state, header_direction| {
		direction = FlowDb.direction(header_direction)?
		groups = FlowDb.group_order(state)?
		group_ids = state.subgraphs.map(|s| s.id)
		group_slot = groups.order.fold_with_index(Dict.empty(), |acc, sub, slot| acc.insert(sub, slot))
		is_group = |id| state.subgraph_index.contains(id)
		container_of = |id|
			match groups.parent.get(id) {
				Ok(parent) => Group(group_slot.get(state.subgraph_index.get(parent) ?? 0) ?? 0)
				Err(_) => Root
			}

		var $node_slot = Dict.empty()
		var $nodes = List.with_capacity(state.vertices.len())
		for vertex in state.vertices {
			if !is_group(vertex.id) {
				if FlowText.has_markup(vertex.text) {
					return Err(Unsupported("markup in a node label"))
				}
				$node_slot = $node_slot.insert(vertex.id, $nodes.len())
				$nodes = $nodes.append({
					id: vertex.id,
					label: FlowText.display(vertex.text),
					shape: FlowDb.shape(vertex.shape),
					container: container_of(vertex.id),
					classes: vertex.classes,
					styles: vertex.styles,
				})
			}
		}

		endpoint = |id|
			match state.subgraph_index.get(id) {
				Ok(sub) => Ok(Group(group_slot.get(sub) ?? 0))
				Err(_) =>
					match $node_slot.get(id) {
						Ok(slot) => Ok(Node(slot))
						Err(_) => Err(Unsupported("an edge to an id that is not a node"))
					}
			}

		var $edges = List.with_capacity(state.edges.len())
		for edge in state.edges {
			if FlowText.has_markup(edge.text) {
				return Err(Unsupported("markup in an edge label"))
			}
			from = endpoint(edge.start)?
			to = endpoint(edge.end)?
			heads = FlowDb.arrowheads(edge.type, edge.stroke)?
			line = match edge.stroke {
				Normal => Solid
				Thick => Thick
				Dotted => Dotted
				Invisible => Invisible
				MismatchedStroke => return Err(Unsupported("a link whose two ends disagree"))
			}
			$edges = $edges.append({
				id: edge.id,
				from,
				to,
				label: FlowText.display(edge.text),
				line,
				start: heads.start,
				end: heads.end,
				length: edge.length,
				classes: edge.classes,
				styles: state.default_edge_style.concat(edge.styles),
			})
		}

		var $groups = List.with_capacity(groups.order.len())
		for sub in groups.order {
			record = state.subgraphs.get(sub) ?? { id: "", nodes: [], title: "", dir: None, classes: [] }
			if FlowText.has_markup(record.title) {
				return Err(Unsupported("markup in a group title"))
			}
			group_direction = match record.dir {
				Some(value) => Set(FlowDb.direction(value)?)
				None => Inherit
			}
			$groups = $groups.append({
				id: record.id,
				title: FlowText.display(record.title),
				container: container_of(record.id),
				direction: group_direction,
				classes: record.classes,
			})
		}

		_ = group_ids
		Ok({
			direction,
			nodes: $nodes,
			edges: $edges,
			groups: $groups,
			classes: state.classes.map(|c| { name: c.id, styles: c.styles }),
		})
	}

	Diagram : {
		direction : [Down, Up, Right, Left],
		nodes : List({ id : Str, label : Str, shape : Shape, container : [Root, Group(U64)], classes : List(Str), styles : List(Str) }),
		edges : List(
			{
				id : Str,
				from : [Node(U64), Group(U64)],
				to : [Node(U64), Group(U64)],
				label : Str,
				line : [Solid, Thick, Dotted, Invisible],
				start : Arrowhead,
				end : Arrowhead,
				length : U64,
				classes : List(Str),
				styles : List(Str),
			},
		),
		groups : List({ id : Str, title : Str, container : [Root, Group(U64)], direction : [Inherit, Set([Down, Up, Right, Left])], classes : List(Str) }),
		classes : List({ name : Str, styles : List(Str) }),
	}

	Shape : [Rectangle, Rounded, Stadium, Subroutine, Cylinder, Circle, DoubleCircle, Ellipse, Asymmetric, Diamond, Hexagon, LeanRight, LeanLeft, Trapezoid, InverseTrapezoid]

	Arrowhead : [None, Arrow, Circle, Cross]

	## `setDirection`, then the reading Mermaid's layout gives each value.
	direction : Str -> Try([Down, Up, Right, Left], Problem)
	direction = |raw| {
		value = FlowText.trim(raw)
		bytes = value.to_utf8()
		if bytes.contains('v') {
			Ok(Down)
		} else if bytes.contains('>') {
			Ok(Right)
		} else if bytes.contains('^') {
			Ok(Up)
		} else if bytes.contains('<') {
			Ok(Left)
		} else {
			match value {
				"TB" | "TD" => Ok(Down)
				"BT" => Ok(Up)
				"LR" => Ok(Right)
				"RL" => Ok(Left)
				_ => Err(Unsupported("direction ${value}"))
			}
		}
	}

	shape : [None, Some(Str)] -> Shape
	shape = |stored|
		match stored {
			Some("round") => Rounded
			Some("stadium") => Stadium
			Some("subroutine") => Subroutine
			Some("cylinder") => Cylinder
			Some("circle") => Circle
			Some("doublecircle") => DoubleCircle
			Some("ellipse") => Ellipse
			Some("odd") => Asymmetric
			Some("diamond") => Diamond
			Some("hexagon") => Hexagon
			Some("lean_right") => LeanRight
			Some("lean_left") => LeanLeft
			Some("trapezoid") => Trapezoid
			Some("inv_trapezoid") => InverseTrapezoid
			_ => Rectangle
		}

	## `destructEdgeType`, with open and invisible links drawn without heads.
	arrowheads : FlowParser.LinkType, FlowParser.Stroke -> Try({ start : Arrowhead, end : Arrowhead }, Problem)
	arrowheads = |type, stroke| {
		if stroke == Invisible or type == Open {
			Ok({ start: None, end: None })
		} else {
			match type {
				Point => Ok({ start: None, end: Arrow })
				Circle => Ok({ start: None, end: Circle })
				Cross => Ok({ start: None, end: Cross })
				DoublePoint => Ok({ start: Arrow, end: Arrow })
				DoubleCircle => Ok({ start: Circle, end: Circle })
				DoubleCross => Ok({ start: Cross, end: Cross })
				Open => Ok({ start: None, end: None })
				Mismatched => Err(Unsupported("a link whose two ends disagree"))
			}
		}
	}

	## Subgraph containment as Mermaid's `parentDB` records it (the earliest
	## closed subgraph listing an id wins), and the subgraphs in declaration
	## order: a pre-order walk from the outermost ones. Containment that
	## loops cannot be drawn and is reported.
	group_order : State -> Try({ parent : Dict(Str, Str), order : List(U64) }, Problem)
	group_order = |state| {
		count = state.subgraphs.len()
		var $parent = Dict.empty()
		var $k = count
		while $k > 0 {
			$k = $k - 1
			sub = state.subgraphs.get($k) ?? { id: "", nodes: [], title: "", dir: None, classes: [] }
			for member in sub.nodes {
				$parent = $parent.insert(member, sub.id)
			}
		}
		# Children of each subgraph, in subgraph order.
		var $children = List.repeat([], count)
		var $roots = []
		for sub in state.subgraphs {
			index = state.subgraph_index.get(sub.id) ?? 0
			match $parent.get(sub.id) {
				Ok(parent_id) =>
					match state.subgraph_index.get(parent_id) {
						Ok(p) => {
							kids = $children.get(p) ?? []
							$children = $children.set(p, kids.append(index)) ?? []
						}
						Err(_) => {
							$roots = $roots.append(index)
						}
					}
				Err(_) => {
					$roots = $roots.append(index)
				}
			}
		}
		var $order = List.with_capacity(count)
		var $stack = FlowDb.reversed($roots)
		while !$stack.is_empty() {
			top = $stack.last() ?? 0
			$stack = $stack.drop_last(1)
			$order = $order.append(top)
			kids = $children.get(top) ?? []
			$stack = $stack.concat(FlowDb.reversed(kids))
		}
		if $order.len() == count {
			Ok({ parent: $parent, order: $order })
		} else {
			Err(Unsupported("groups that contain each other"))
		}
	}
}

# Each test pins one rule of Mermaid's flowDb, through the events the parser emits.

link_info : FlowParser.LinkInfo
link_info = { type: Point, stroke: Normal, length: 1, text: None, id: None }

vertex : Str -> FlowParser.Event
vertex = |id| Vertex({ id, text: None, shape: None })

title : Str -> FlowParser.Text
title = |text| { text, quoted: False }

applied : List(FlowParser.Event) -> FlowDb.State
applied = |events|
	match FlowDb.apply(events) {
		Ok(state) => state
		Err(_) => FlowDb.empty
	}

edge_ids : List(FlowParser.Event) -> List(Str)
edge_ids = |events| applied(events).edges.map(|e| e.id)

problem_of : List(FlowParser.Event) -> [None, Some(FlowDb.Problem)]
problem_of = |events|
	match FlowDb.apply(events) {
		Ok(_) => None
		Err(problem) => Some(problem)
	}

## Parallel edges number 0, then 2, 3: the second counter skips 1.
expect {
	link = Link({ starts: ["A"], ends: ["B"], info: link_info })
	edge_ids([vertex("A"), vertex("B"), link, link, link]) == ["L_A_B_0", "L_A_B_2", "L_A_B_3"]
}

## A link id names only the edge from the last start to the first end.
expect edge_ids([Link({ starts: ["A", "B"], ends: ["C", "D"], info: { ..link_info, id: Some("e1@") } })]) == ["L_A_C_0", "L_A_D_0", "e1", "L_B_D_0"]

## A link id already in use falls back to a generated one.
expect {
	named = Link({ starts: ["A"], ends: ["B"], info: { ..link_info, id: Some("e1@") } })
	edge_ids([named, Link({ starts: ["B"], ends: ["C"], info: { ..link_info, id: Some("e1@") } })]) == ["e1", "L_B_C_0"]
}

## Only the first `@` of a link id is removed.
expect FlowDb.without_first_at("a@b@") == "ab@"

## A vertex whose id is an edge's id is that edge's metadata, not a node.
expect !applied([Link({ starts: ["A"], ends: ["B"], info: { ..link_info, id: Some("e1@") } }), vertex("e1")]).vertex_index.contains("e1")

## A label defaults to the id; later text replaces it, trimmed, with one pair
## of surrounding quotes and any NUL removed.
expect {
	state = applied([vertex("A"), Vertex({ id: "A", text: Some({ text: "  \"He\u(0)llo\"  ", quoted: True }), shape: Some("round") })])
	state.vertices.map(|v| { text: v.text, shape: v.shape }) == [{ text: "Hello", shape: Some("round") }]
}

## Edge lengths are capped at 10.
expect applied([Link({ starts: ["A"], ends: ["B"], info: { ..link_info, length: 14 } })]).edges.map(|e| e.length) == [10]

## The 501st edge exceeds Mermaid's limit.
expect problem_of([Link({ starts: ["A"], ends: List.repeat("B", 501), info: link_info })]) == Some(TooManyEdges)

## linkStyle positions index edges as JavaScript arrays do.
expect {
	state = applied([Link({ starts: ["A"], ends: ["B"], info: link_info })])
	FlowDb.position(state, "0") == Ok(Index(0))
		and FlowDb.position(state, "default") == Ok(Default)
		and FlowDb.position(state, "00") == Err(MissingLinkStyleEdge("00"))
		and FlowDb.position(state, "1") == Err(MissingLinkStyleEdge("1"))
}

## A link style without a fill gains `fill:none`; one with a fill keeps it.
expect {
	state = applied([
		Link({ starts: ["A"], ends: ["B", "C"], info: link_info }),
		LinkStyle({ positions: ["0"], styles: ["stroke:red"] }),
		LinkStyle({ positions: ["1"], styles: ["fill:blue"] }),
	])
	state.edges.map(|e| e.styles) == [["stroke:red", "fill:none"], ["fill:blue"]]
}

## classDef splits on unescaped commas and on semicolons, for each named class.
expect {
	styles = ["fill:#f96", "stroke:#333", "font-family:x,y"]
	applied([AddClass({ ids: "a,b", styles: ["fill:#f96;stroke:#333", "font-family:x\\,y"] })]).classes == [{ id: "a", styles }, { id: "b", styles }]
}

## A class applies to the vertices, edges and subgraphs declared so far.
expect {
	state = applied([
		Link({ starts: ["A"], ends: ["B"], info: { ..link_info, id: Some("e1@") } }),
		Subgraph({ header: Named({ id: "S", title: title("T") }), items: [Ids(["A"])] }),
		SetClass({ ids: "e1,S,later", class: "hot" }),
		Subgraph({ header: Named({ id: "later", title: title("L") }), items: [Ids(["B"])] }),
	])
	state.edges.map(|e| e.classes) == [["hot"]] and state.subgraphs.map(|s| s.classes) == [["hot"], []]
}

## A plain subgraph name with white space has no id; an unnamed one is rejected.
expect {
	state = applied([Subgraph({ header: Plain(title("My Group")), items: [] })])
	state.subgraphs.map(|s| { id: s.id, title: s.title }) == [{ id: "subGraph0", title: "My Group" }]
		and problem_of([Subgraph({ header: Anonymous, items: [] })]) == Some(UnnamedGroup)
}

## A node belongs to the first subgraph closed around it, a subgraph never
## lists itself, and a repeated subgraph merges into the first, keeping its title.
expect {
	state = applied([
		Subgraph({ header: Named({ id: "one", title: title("First") }), items: [Ids(["a"])] }),
		Subgraph({ header: Named({ id: "two", title: title("Second") }), items: [Ids(["b", "a", "two"])] }),
		Subgraph({ header: Named({ id: "one", title: title("Again") }), items: [Ids(["c"])] }),
	])
	state.subgraphs.map(|s| { id: s.id, nodes: s.nodes, title: s.title }) == [{ id: "one", nodes: ["a", "c"], title: "First" }, { id: "two", nodes: ["b"], title: "Second" }]
}

## The last direction statement in a subgraph wins.
expect applied([Subgraph({ header: Named({ id: "S", title: title("S") }), items: [Direction("LR"), Ids(["a"]), Direction("BT")] })]).subgraphs.map(|s| s.dir) == [Some("BT")]

## Groups that contain each other cannot be drawn.
expect {
	state = applied([
		Subgraph({ header: Named({ id: "A", title: title("A") }), items: [Ids(["x"])] }),
		Subgraph({ header: Named({ id: "B", title: title("B") }), items: [Ids(["A"])] }),
		Subgraph({ header: Named({ id: "A", title: title("A") }), items: [Ids(["B"])] }),
	])
	FlowDb.group_order(state) == Err(Unsupported("groups that contain each other"))
}

## Groups come out in declaration order: outer before inner.
expect {
	state = applied([
		Subgraph({ header: Named({ id: "inner", title: title("i") }), items: [Ids(["x"])] }),
		Subgraph({ header: Named({ id: "outer", title: title("o") }), items: [Closed(0)] }),
	])
	match FlowDb.group_order(state) {
		Ok(found) => found.order == [1, 0]
		Err(_) => False
	}
}

expect FlowDb.direction("TD") == Ok(Down) and FlowDb.direction(" v") == Ok(Down) and FlowDb.direction("<") == Ok(Left)
expect FlowDb.direction("BR") == Err(Unsupported("direction BR"))
expect FlowDb.arrowheads(Point, Invisible) == Ok({ start: None, end: None })
expect FlowDb.arrowheads(DoubleCircle, Thick) == Ok({ start: Circle, end: Circle })
expect FlowDb.arrowheads(Mismatched, MismatchedStroke) == Err(Unsupported("a link whose two ends disagree"))
