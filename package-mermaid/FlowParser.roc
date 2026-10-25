import Bytes
import FlowLexer

## The flowchart grammar from Mermaid's `flow.jison`, as a recursive-descent
## parser over `FlowLexer` tokens. It accepts the same token sequences as the
## LALR original and emits the database calls the original's semantic actions
## make, in the same order, so `FlowDb` can reproduce their effects exactly.
## Subgraph nesting uses an explicit stack, so depth is bounded by memory
## rather than by the native call stack.
FlowParser :: {}.{

	## Text as written, with whether it came from a quoted string.
	Text : { text : Str, quoted : Bool }

	LinkType : [Open, Point, Circle, Cross, DoublePoint, DoubleCircle, DoubleCross, Mismatched]

	Stroke : [Normal, Thick, Dotted, Invisible, MismatchedStroke]

	LinkInfo : { type : LinkType, stroke : Stroke, length : U64, text : [None, Some(Text)], id : [None, Some(Str)] }

	## One element of a subgraph body, as the original grammar collects it.
	Item : [Ids(List(Str)), Closed(U64), Direction(Str)]

	Header : [Named({ id : Str, title : Text }), Plain(Text), Anonymous]

	Event : [
		Vertex({ id : Str, text : [None, Some(Text)], shape : [None, Some(Str)] }),
		VertexStyle({ id : Str, styles : List(Str) }),
		Link({ starts : List(Str), ends : List(Str), info : LinkInfo }),
		SetClass({ ids : Str, class : Str }),
		AddClass({ ids : Str, styles : List(Str) }),
		LinkStyle({ positions : List(Str), styles : List(Str) }),
		LinkInterpolate({ positions : List(Str) }),

		## A subgraph closed. `Closed(k)` items refer to the k-th close.
		Subgraph({ header : Header, items : List(Item) }),
	]

	Parsed : { direction : Str, events : List(Event) }

	Failure : [Syntax(U64), Unsupported(Str)]

	parse : List(U8), List(FlowLexer.Token) -> Try(Parsed, Failure)
	parse = |bytes, tokens| {
		p = { bytes, tokens }
		header = FlowParser.graph_config(p, 0)?
		var $i = header.i
		var $events = []
		# Open subgraphs: their headers, and where each one's items begin in
		# the shared item list, so adding an item never copies a body.
		var $headers = []
		var $starts = []
		var $items = []
		var $closed = 0
		var $finished = False
		while !$finished {
			kind = FlowParser.kind_at(p, $i)
			open = !$headers.is_empty()
			match kind {
				Eof => {
					if open {
						return Err(Syntax($i))
					} else {
						$finished = True
					}
				}
				Semi | Newline | Space => {
					$i = $i + 1
				}
				End => {
					match ($headers.last(), $starts.last()) {
						(Ok(closing), Ok(start)) => {
							$events = $events.append(Subgraph({ header: closing, items: $items.drop_first(start) }))
							$items = $items.take_first(start)
							$headers = $headers.drop_last(1)
							$starts = $starts.drop_last(1)
							if !$headers.is_empty() {
								$items = $items.append(Closed($closed))
							}
							$closed = $closed + 1
							$i = $i + 1
						}
						_ => return Err(Syntax($i))
					}
				}
				Subgraph => {
					opened = FlowParser.subgraph_header(p, $i + 1)?
					$headers = $headers.append(opened.header)
					$starts = $starts.append($items.len())
					$i = opened.i
				}
				DirectionTb | DirectionBt | DirectionRl | DirectionLr | DirectionTd => {
					value = match kind {
						DirectionTb => "TB"
						DirectionBt => "BT"
						DirectionRl => "RL"
						DirectionLr => "LR"
						_ => "TD"
					}
					if open {
						$items = $items.append(Direction(value))
					}
					$i = $i + 1
				}
				Style => {
					parsed = FlowParser.style_statement(p, $i + 1)?
					$events = $events.append(VertexStyle(parsed.value))
					$i = FlowParser.separator(p, parsed.i)?
				}
				ClassDef => {
					parsed = FlowParser.class_def_statement(p, $i + 1)?
					$events = $events.append(AddClass(parsed.value))
					$i = FlowParser.separator(p, parsed.i)?
				}
				Class => {
					parsed = FlowParser.class_statement(p, $i + 1)?
					$events = $events.append(SetClass(parsed.value))
					$i = FlowParser.separator(p, parsed.i)?
				}
				LinkStyle => {
					parsed = FlowParser.link_style_statement(p, $i + 1)?
					$events = $events.concat(parsed.value)
					$i = FlowParser.separator(p, parsed.i)?
				}
				_ => {
					if FlowParser.is_id_token(kind) {
						parsed = FlowParser.vertex_statement(p, $i, $events)?
						$events = parsed.events
						if open {
							$items = $items.append(Ids(parsed.nodes))
						}
						$i = FlowParser.separator(p, parsed.i)?
					} else {
						return Err(Syntax($i))
					}
				}
			}
		}
		Ok({ direction: header.direction, events: $events })
	}

	kind_at : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> FlowLexer.Kind
	kind_at = |p, i|
		match p.tokens.get(i) {
			Ok(token) => token.kind
			Err(_) => Eof
		}

	text_of : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Str
	text_of = |p, i|
		match p.tokens.get(i) {
			Ok(token) => Bytes.slice_str(p.bytes, token.start, token.len)
			Err(_) => ""
		}

	## `graphConfig`: leading blank tokens, then `GRAPH NODIR` or
	## `GRAPH DIR FirstStmtSeparator`.
	graph_config : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, direction : Str }, Failure)
	graph_config = |p, start| {
		var $i = start
		while FlowParser.kind_at(p, $i) == Space or FlowParser.kind_at(p, $i) == Newline {
			$i = $i + 1
		}
		if FlowParser.kind_at(p, $i) != Graph {
			return Err(Syntax($i))
		}
		match FlowParser.kind_at(p, $i + 1) {
			NoDir => Ok({ i: $i + 2, direction: "TB" })
			Dir => {
				direction = FlowParser.text_of(p, $i + 1).trim()
				after = $i + 2
				match FlowParser.kind_at(p, after) {
					Semi | Newline => Ok({ i: after + 1, direction })
					Space if FlowParser.kind_at(p, after + 1) == Newline => Ok({ i: after + 2, direction })
					_ => Err(Syntax(after))
				}
			}
			_ => Err(Syntax($i + 1))
		}
	}

	## `separator: NEWLINE | SEMI | EOF`. End of input is left for the loop.
	separator : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try(U64, Failure)
	separator = |p, i|
		match FlowParser.kind_at(p, i) {
			Newline | Semi => Ok(i + 1)
			Eof => Ok(i)
			_ => Err(Syntax(i))
		}

	is_id_token : FlowLexer.Kind -> Bool
	is_id_token = |kind|
		match kind {
			Num | NodeString | Down | Minus | Default | Comma | Colon | Amp | Brkt | Mult | UnicodeText => True
			_ => False
		}

	is_alpha_num_token : FlowLexer.Kind -> Bool
	is_alpha_num_token = |kind|
		match kind {
			Num | UnicodeText | NodeString | Dir | Down | Minus | Comma | Colon | Amp | Brkt | Mult => True
			_ => False
		}

	is_no_tags_token : FlowLexer.Kind -> Bool
	is_no_tags_token = |kind|
		match kind {
			Num | NodeString | Space | Minus | Amp | UnicodeText | Colon | Mult | Brkt | StartLink => True
			Style | LinkStyle | ClassDef | Class | Graph | Dir | Subgraph | End | Down | Up => True
			_ => False
		}

	is_text_token : FlowLexer.Kind -> Bool
	is_text_token = |kind|
		match kind {
			Text | TagStart | TagEnd | UnicodeText => True
			_ => False
		}

	is_edge_text_token : FlowLexer.Kind -> Bool
	is_edge_text_token = |kind|
		match kind {
			EdgeText | UnicodeText => True
			_ => False
		}

	is_style_token : FlowLexer.Kind -> Bool
	is_style_token = |kind|
		match kind {
			Num | NodeString | Colon | Space | Brkt | Style => True
			_ => False
		}

	## One or more tokens accepted by `accept`, concatenated.
	run : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, (FlowLexer.Kind -> Bool) -> Try({ i : U64, value : Str }, Failure)
	run = |p, start, accept| {
		var $i = start
		var $text = ""
		while accept(FlowParser.kind_at(p, $i)) {
			$text = Str.concat($text, FlowParser.text_of(p, $i))
			$i = $i + 1
		}
		if ($i == start) Err(Syntax(start)) else Ok({ i: $i, value: $text })
	}

	## `text`, `edgeText` and `textNoTags` share a shape: a quoted string or a
	## token, then any further tokens of the family.
	text_with : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, (FlowLexer.Kind -> Bool) -> Try({ i : U64, value : FlowParser.Text }, Failure)
	text_with = |p, start, accept| {
		if FlowParser.kind_at(p, start) == Str {
			first = FlowParser.text_of(p, start)
			var $i = start + 1
			var $text = first
			while accept(FlowParser.kind_at(p, $i)) {
				$text = Str.concat($text, FlowParser.text_of(p, $i))
				$i = $i + 1
			}
			Ok({ i: $i, value: { text: $text, quoted: True } })
		} else {
			found = FlowParser.run(p, start, accept)?
			Ok({ i: found.i, value: { text: found.value, quoted: False } })
		}
	}

	expect_kind : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, FlowLexer.Kind -> Try(U64, Failure)
	expect_kind = |p, i, wanted| if (FlowParser.kind_at(p, i) == wanted) Ok(i + 1) else Err(Syntax(i))

	## After `subgraph`: `SPACE textNoTags SQS text SQE separator`,
	## `SPACE textNoTags separator`, or `separator`.
	subgraph_header : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, header : Header }, Failure)
	subgraph_header = |p, start| {
		if FlowParser.kind_at(p, start) == Space {
			id = FlowParser.text_with(p, start + 1, FlowParser.is_no_tags_token)?
			if FlowParser.kind_at(p, id.i) == Sqs {
				title = FlowParser.text_with(p, id.i + 1, FlowParser.is_text_token)?
				after = FlowParser.expect_kind(p, title.i, Sqe)?
				i = FlowParser.separator(p, after)?
				Ok({ i, header: Named({ id: id.value.text, title: title.value }) })
			} else {
				i = FlowParser.separator(p, id.i)?
				Ok({ i, header: Plain(id.value) })
			}
		} else {
			i = FlowParser.separator(p, start)?
			Ok({ i, header: Anonymous })
		}
	}

	## `stylesOpt`: styles separated by commas.
	styles : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : List(Str) }, Failure)
	styles = |p, start| {
		first = FlowParser.run(p, start, FlowParser.is_style_token)?
		var $i = first.i
		var $found = [first.value]
		while FlowParser.kind_at(p, $i) == Comma {
			next = FlowParser.run(p, $i + 1, FlowParser.is_style_token)?
			$found = $found.append(next.value)
			$i = next.i
		}
		Ok({ i: $i, value: $found })
	}

	## `STYLE SPACE idString SPACE stylesOpt`, after `STYLE`.
	style_statement : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : { id : Str, styles : List(Str) } }, Failure)
	style_statement = |p, start| {
		at_id = FlowParser.expect_kind(p, start, Space)?
		id = FlowParser.run(p, at_id, FlowParser.is_id_token)?
		at_styles = FlowParser.expect_kind(p, id.i, Space)?
		found = FlowParser.styles(p, at_styles)?
		Ok({ i: found.i, value: { id: id.value, styles: found.value } })
	}

	class_def_statement : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : { ids : Str, styles : List(Str) } }, Failure)
	class_def_statement = |p, start| {
		parsed = FlowParser.style_statement(p, start)?
		Ok({ i: parsed.i, value: { ids: parsed.value.id, styles: parsed.value.styles } })
	}

	class_statement : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : { ids : Str, class : Str } }, Failure)
	class_statement = |p, start| {
		at_ids = FlowParser.expect_kind(p, start, Space)?
		ids = FlowParser.run(p, at_ids, FlowParser.is_id_token)?
		at_class = FlowParser.expect_kind(p, ids.i, Space)?
		class = FlowParser.run(p, at_class, FlowParser.is_id_token)?
		Ok({ i: class.i, value: { ids: ids.value, class: class.value } })
	}

	## `LINKSTYLE SPACE (DEFAULT | numList) SPACE ...`, after `LINKSTYLE`.
	link_style_statement : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : List(Event) }, Failure)
	link_style_statement = |p, start| {
		at_positions = FlowParser.expect_kind(p, start, Space)?
		positions = if FlowParser.kind_at(p, at_positions) == Default {
			{ i: at_positions + 1, value: ["default"] }
		} else {
			first = FlowParser.expect_kind(p, at_positions, Num)?
			var $i = first
			var $found = [FlowParser.text_of(p, at_positions)]
			while FlowParser.kind_at(p, $i) == Comma and FlowParser.kind_at(p, $i + 1) == Num {
				$found = $found.append(FlowParser.text_of(p, $i + 1))
				$i = $i + 2
			}
			{ i: $i, value: $found }
		}
		at_rest = FlowParser.expect_kind(p, positions.i, Space)?
		if FlowParser.kind_at(p, at_rest) == Interpolate {
			at_curve = FlowParser.expect_kind(p, at_rest + 1, Space)?
			curve = FlowParser.run(p, at_curve, FlowParser.is_alpha_num_token)?
			interpolate = LinkInterpolate({ positions: positions.value })
			if FlowParser.kind_at(p, curve.i) == Space {
				found = FlowParser.styles(p, curve.i + 1)?
				Ok({ i: found.i, value: [interpolate, LinkStyle({ positions: positions.value, styles: found.value })] })
			} else {
				Ok({ i: curve.i, value: [interpolate] })
			}
		} else {
			found = FlowParser.styles(p, at_rest)?
			Ok({ i: found.i, value: [LinkStyle({ positions: positions.value, styles: found.value })] })
		}
	}

	## `vertexStatement`: a node group, then any number of `link node`
	## pairs, each optionally followed by spaces. Returns the statement's
	## node ids in the original's order: each later group before earlier ones.
	vertex_statement : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, List(Event) -> Try({ i : U64, nodes : List(Str), events : List(Event) }, Failure)
	vertex_statement = |p, start, events| {
		first = FlowParser.node(p, start, events)?
		var $i = if (FlowParser.kind_at(p, first.i) == Space) first.i + 1 else first.i
		var $events = first.events
		var $stmt = first.ids
		var $nodes = first.ids
		while FlowParser.is_link_start(FlowParser.kind_at(p, $i)) {
			link = FlowParser.link(p, $i)?
			target = FlowParser.node(p, link.i, $events)?
			$events = target.events.append(Link({ starts: $stmt, ends: target.ids, info: link.value }))
			$nodes = target.ids.concat($nodes)
			$stmt = target.ids
			$i = if (FlowParser.kind_at(p, target.i) == Space) target.i + 1 else target.i
		}
		Ok({ i: $i, nodes: $nodes, events: $events })
	}

	is_link_start : FlowLexer.Kind -> Bool
	is_link_start = |kind|
		match kind {
			Link | StartLink | LinkId => True
			_ => False
		}

	## `node`: styled vertices joined by `spaceList AMP spaceList`.
	node : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, List(Event) -> Try({ i : U64, ids : List(Str), events : List(Event) }, Failure)
	node = |p, start, events| {
		first = FlowParser.styled_vertex(p, start, events)?
		var $i = first.i
		var $ids = [first.id]
		var $events = first.events
		while FlowParser.kind_at(p, $i) == Space and FlowParser.kind_at(p, $i + 1) == Amp {
			at_vertex = FlowParser.expect_kind(p, $i + 2, Space)?
			next = FlowParser.styled_vertex(p, at_vertex, $events)?
			$ids = $ids.append(next.id)
			$events = next.events
			$i = next.i
		}
		Ok({ i: $i, ids: $ids, events: $events })
	}

	styled_vertex : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, List(Event) -> Try({ i : U64, id : Str, events : List(Event) }, Failure)
	styled_vertex = |p, start, events| {
		vertex = FlowParser.vertex(p, start)?
		value = vertex.value
		with_vertex = events.append(Vertex({ id: value.id, text: value.text, shape: value.shape }))
		if FlowParser.kind_at(p, vertex.i) == StyleSeparator {
			class = FlowParser.run(p, vertex.i + 1, FlowParser.is_id_token)?
			Ok({ i: class.i, id: vertex.value.id, events: with_vertex.append(SetClass({ ids: vertex.value.id, class: class.value })) })
		} else {
			Ok({ i: vertex.i, id: vertex.value.id, events: with_vertex })
		}
	}

	## `vertex`: an id, optionally followed by a bracketed label whose
	## delimiters choose the shape.
	vertex : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : { id : Str, text : [None, Some(FlowParser.Text)], shape : [None, Some(Str)] } }, Failure)
	vertex = |p, start| {
		id = FlowParser.run(p, start, FlowParser.is_id_token)?
		i = id.i
		one = |close, shape| [{ close, count: 1, shape }]
		form = match FlowParser.kind_at(p, i) {
			Sqs => Shape({ open: 1, closers: one(Sqe, "square") })
			DoubleCircleStart => Shape({ open: 1, closers: one(DoubleCircleEnd, "doublecircle") })
			Ps =>
				if FlowParser.kind_at(p, i + 1) == Ps {
					Shape({ open: 2, closers: [{ close: Pe, count: 2, shape: "circle" }] })
				} else {
					Shape({ open: 1, closers: one(Pe, "round") })
				}
			EllipseStart => Shape({ open: 1, closers: one(EllipseEnd, "ellipse") })
			StadiumStart => Shape({ open: 1, closers: one(StadiumEnd, "stadium") })
			SubroutineStart => Shape({ open: 1, closers: one(SubroutineEnd, "subroutine") })
			PropsStart => Props
			CylinderStart => Shape({ open: 1, closers: one(CylinderEnd, "cylinder") })
			DiamondStart =>
				if FlowParser.kind_at(p, i + 1) == DiamondStart {
					Shape({ open: 2, closers: [{ close: DiamondStop, count: 2, shape: "hexagon" }] })
				} else {
					Shape({ open: 1, closers: one(DiamondStop, "diamond") })
				}
			TagEnd => Shape({ open: 1, closers: one(Sqe, "odd") })
			TrapStart => Shape({ open: 1, closers: [{ close: TrapEnd, count: 1, shape: "trapezoid" }, { close: InvTrapEnd, count: 1, shape: "lean_right" }] })
			InvTrapStart => Shape({ open: 1, closers: [{ close: InvTrapEnd, count: 1, shape: "inv_trapezoid" }, { close: TrapEnd, count: 1, shape: "lean_left" }] })
			_ => Bare
		}
		match form {
			Bare => Ok({ i, value: { id: id.value, text: None, shape: None } })
			Props => Err(Unsupported("vertex properties"))
			Shape({ open, closers }) => {
				label = FlowParser.text_with(p, i + open, FlowParser.is_text_token)?
				closed = FlowParser.closing(p, label.i, closers)?
				Ok({ i: closed.i, value: { id: id.value, text: Some(label.value), shape: Some(closed.shape) } })
			}
		}
	}

	## The first closer that `count` consecutive `close` tokens satisfy.
	closing : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64, List({ close : FlowLexer.Kind, count : U64, shape : Str }) -> Try({ i : U64, shape : Str }, Failure)
	closing = |p, at, closers| {
		found = closers.find_first(
			|closer| {
				var $k = 0
				var $all = True
				while $all and $k < closer.count {
					if FlowParser.kind_at(p, at + $k) != closer.close {
						$all = False
					}
					$k = $k + 1
				}
				$all
			},
		)
		match found {
			Ok(closer) => Ok({ i: at + closer.count, shape: closer.shape })
			Err(_) => Err(Syntax(at))
		}
	}

	## `link`, with an optional `LINK_ID` prefix.
	link : { bytes : List(U8), tokens : List(FlowLexer.Token) }, U64 -> Try({ i : U64, value : LinkInfo }, Failure)
	link = |p, start| {
		has_id = FlowParser.kind_at(p, start) == LinkId
		id = if (has_id) Some(FlowParser.text_of(p, start)) else None
		i = if (has_id) start + 1 else start
		match FlowParser.kind_at(p, i) {
			Link => {
				shape = FlowParser.destruct_link(FlowParser.text_of(p, i), None)
				if FlowParser.kind_at(p, i + 1) == Pipe {
					label = FlowParser.text_with(p, i + 2, FlowParser.is_text_token)?
					after = FlowParser.expect_kind(p, label.i, Pipe)?
					next = if (FlowParser.kind_at(p, after) == Space) after + 1 else after
					Ok({ i: next, value: { ..shape, text: Some(label.value), id } })
				} else {
					Ok({ i: i + 1, value: { ..shape, id } })
				}
			}
			StartLink => {
				label = FlowParser.text_with(p, i + 1, FlowParser.is_edge_text_token)?
				if FlowParser.kind_at(p, label.i) == Link {
					shape = FlowParser.destruct_link(FlowParser.text_of(p, label.i), Some(FlowParser.text_of(p, i)))
					Ok({ i: label.i + 1, value: { ..shape, text: Some(label.value), id } })
				} else {
					Err(Syntax(label.i))
				}
			}
			_ => Err(Syntax(i))
		}
	}

	## `destructLink`: the arrowheads, stroke, and length a link spells.
	destruct_link : Str, [None, Some(Str)] -> LinkInfo
	destruct_link = |end_text, start_text| {
		info = FlowParser.destruct_end_link(end_text)
		match start_text {
			None => info
			Some(text) => {
				start = FlowParser.destruct_start_link(text)
				if start.stroke != info.stroke {
					{ ..info, type: Mismatched, stroke: MismatchedStroke }
				} else {
					type = match start.type {
						Open => Ok(info.type)
						Point => if (info.type == Point) Ok(DoublePoint) else Err({})
						Circle => if (info.type == Circle) Ok(DoubleCircle) else Err({})
						Cross => if (info.type == Cross) Ok(DoubleCross) else Err({})
						_ => Err({})
					}
					match type {
						Ok(t) => { ..info, type: t, stroke: start.stroke }
						Err(_) => { ..info, type: Mismatched, stroke: MismatchedStroke }
					}
				}
			}
		}
	}

	destruct_end_link : Str -> LinkInfo
	destruct_end_link = |raw| {
		str = raw.trim().to_utf8()
		last = Bytes.at(str, str.len() - 1)
		first = Bytes.at(str, 0)
		body = str.drop_last(1)
		{ type, line } = match last {
			'x' => if (first == 'x') { type: DoubleCross, line: body.drop_first(1) } else { type: Cross, line: body }
			'>' => if (first == '<') { type: DoublePoint, line: body.drop_first(1) } else { type: Point, line: body }
			'o' => if (first == 'o') { type: DoubleCircle, line: body.drop_first(1) } else { type: Circle, line: body }
			_ => { type: Open, line: body }
		}
		dots = line.count_if(|c| c == '.')
		line_first = Bytes.at(line, 0)
		stroke = if dots > 0 {
			Dotted
		} else if line_first == '~' and line.len() > 0 {
			Invisible
		} else if line_first == '=' and line.len() > 0 {
			Thick
		} else {
			Normal
		}
		length = if (dots > 0) dots else (if (line.len() > 0) line.len() - 1 else 0)
		{ type, stroke, length, text: None, id: None }
	}

	destruct_start_link : Str -> { type : LinkType, stroke : Stroke }
	destruct_start_link = |raw| {
		str = raw.trim().to_utf8()
		{ type, rest } = match Bytes.at(str, 0) {
			'<' => { type: Point, rest: str.drop_first(1) }
			'x' => { type: Cross, rest: str.drop_first(1) }
			'o' => { type: Circle, rest: str.drop_first(1) }
			_ => { type: Open, rest: str }
		}
		stroke = if rest.contains('.') {
			Dotted
		} else if rest.contains('=') {
			Thick
		} else {
			Normal
		}
		{ type, stroke }
	}
}

parsed_events : Str -> Try(List(FlowParser.Event), FlowParser.Failure)
parsed_events = |text| {
	bytes = text.to_utf8()
	match FlowLexer.tokenize(bytes) {
		Tokens(tokens) => FlowParser.parse(bytes, tokens).map_ok(|parsed| parsed.events)
		_ => Err(Syntax(0))
	}
}

is_err : Try(a, e) -> Bool
is_err = |result|
	match result {
		Ok(_) => False
		Err(_) => True
	}

expect FlowParser.destruct_link("-->", None) == { type: Point, stroke: Normal, length: 1, text: None, id: None }
expect FlowParser.destruct_link("-..->", None) == { type: Point, stroke: Dotted, length: 2, text: None, id: None }
expect FlowParser.destruct_link("====>", None) == { type: Point, stroke: Thick, length: 3, text: None, id: None }
expect FlowParser.destruct_link("<-->", None) == { type: DoublePoint, stroke: Normal, length: 1, text: None, id: None }
expect FlowParser.destruct_link(" ~~~ ", None) == { type: Open, stroke: Invisible, length: 1, text: None, id: None }
expect FlowParser.destruct_link("-->", Some("x--")) == { type: Mismatched, stroke: MismatchedStroke, length: 1, text: None, id: None }
expect FlowParser.destruct_link("--x", Some("x--")) == { type: DoubleCross, stroke: Normal, length: 1, text: None, id: None }
expect FlowParser.destruct_link(".->", Some("-.")) == { type: Point, stroke: Dotted, length: 1, text: None, id: None }

expect
	parsed_events("flowchart TD\nA --> B\n")
		== Ok([
			Vertex({ id: "A", text: None, shape: None }),
			Vertex({ id: "B", text: None, shape: None }),
			Link({ starts: ["A"], ends: ["B"], info: { type: Point, stroke: Normal, length: 1, text: None, id: None } }),
		])

expect
	parsed_events("graph LR\nsubgraph S [T]\na\nend\n")
		== Ok([Vertex({ id: "a", text: None, shape: None }), Subgraph({ header: Named({ id: "S ", title: { text: "T", quoted: False } }), items: [Ids(["a"])] })])

expect is_err(parsed_events("graph LR\nA[\n"))
expect is_err(parsed_events("graph LR\nA --> \n"))
expect is_err(parsed_events("graph LR\nsubgraph S\nA\n"))
