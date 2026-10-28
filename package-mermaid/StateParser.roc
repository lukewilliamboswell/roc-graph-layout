import Flowchart
import FlowText
import StateModel

## A bounded statement reader. Endpoints are resolved after declarations so
## a composite may be referenced before its body appears.
StateParser :: {}.{
	RawTransition : { from : Str, to : Str, label : Str }
	RawNote : { state : Str, side : [Left, Right], text : Str, after_transition : U64 }
	Reader : { declarations : List(StateModel.Declaration), direction : Flowchart.Direction, states : List(StateModel.State), transitions : List(RawTransition), groups : List(StateModel.Group), classes : List(Flowchart.ClassDef), notes : List(RawNote), stack : List(U64), problems : List(Flowchart.Problem) }

	parse : Str -> Try(StateModel.Diagram, List(Flowchart.Problem))
	parse = |source| {
		lines = source.split_on("\n")
		initial : Reader
		initial = { declarations: [], direction: Down, states: [], transitions: [], groups: [], classes: [], notes: [], stack: [], problems: [] }
		var $reader = initial
		var $header = False
		var $note = None
		for raw in lines {
			line = FlowText.trim(StateParser.comment(raw))
			if line != "" or $note != None {
				if !$header {
					$header = True
					if line != "stateDiagram" and line != "stateDiagram-v2" and line != "stateDiagram;" and line != "stateDiagram-v2;" {
						$reader = { ..$reader, problems: $reader.problems.append(Unsupported("expected stateDiagram or stateDiagram-v2")) }
					}
				} else {
					match $note {
						Some(note) => {
							if line == "end note" {
								$reader = { ..$reader, notes: $reader.notes.append({ ..note, text: FlowText.trim(note.text) }) }
								$note = None
							} else {
								content = StateParser.comment(raw)
								text = if (note.text == "") line else "${note.text}\n${content}"
								$note = Some({ ..note, text })
							}
						}
						None => {
							for statement in StateParser.statements(line) {
								text = FlowText.trim(statement)
								if text != "" {
									if text.starts_with("note ") {
										parsed = StateParser.read_note(text)
										match parsed {
											Err(problem) => {
												$reader = { ..$reader, problems: $reader.problems.append(problem) }
											}
											Ok(found) => {
												$reader = { ..$reader, declarations: $reader.declarations.append(Note($reader.notes.len())) }
												$reader = StateParser.ensure($reader, found.note.state, StateParser.current_container($reader))
												if found.inline {
													$reader = { ..$reader, notes: $reader.notes.append({ ..found.note, after_transition: $reader.transitions.len() }) }
												} else {
													$note = Some({ ..found.note, after_transition: $reader.transitions.len() })
												}
											}
										}
									} else {
										$reader = StateParser.statement($reader, text)
									}
								}
							}
						}
					}
				}
			}
		}
		if !$header {
			$reader = { ..$reader, problems: $reader.problems.append(Unsupported("expected stateDiagram or stateDiagram-v2")) }
		}
		if $note != None {
			$reader = { ..$reader, problems: $reader.problems.append(Syntax({ near: "unclosed state note" })) }
		}
		if !$reader.stack.is_empty() {
			$reader = { ..$reader, problems: $reader.problems.append(Syntax({ near: "unclosed composite state" })) }
		}
		reader = $reader
		states = reader.states.keep_if(|state| !reader.groups.any(|group| group.id == state.id))
		var $transitions = []
		var $notes = []
		var $problems = reader.problems
		for raw_edge in reader.transitions {
			match (StateParser.endpoint(raw_edge.from, states, reader.groups), StateParser.endpoint(raw_edge.to, states, reader.groups)) {
				(Ok(from), Ok(to)) => {
					$transitions = $transitions.append({ from, to, label: raw_edge.label })
				}
				_ => {
					$problems = $problems.append(Syntax({ near: "${raw_edge.from} --> ${raw_edge.to}" }))
				}
			}
		}
		for raw_note in reader.notes {
			match StateParser.endpoint(raw_note.state, states, reader.groups) {
				Ok(state) => {
					$notes = $notes.append({ state, side: raw_note.side, text: raw_note.text, after_transition: raw_note.after_transition })
				}
				Err(_) => {
					$problems = $problems.append(Syntax({ near: "note names unknown state ${raw_note.state}" }))
				}
			}
		}
		if $problems.is_empty() {
			Ok({ declarations: reader.declarations, direction: reader.direction, states, transitions: $transitions, groups: reader.groups, classes: reader.classes, notes: $notes })
		} else {
			Err($problems)
		}
	}

	endpoint : Str, List(StateModel.State), List(StateModel.Group) -> Try(Flowchart.Endpoint, [Missing])
	endpoint = |id, states, groups| {
		var $found = Err(Missing)
		for i in 0..<states.len() {
			if (states.get(i) ?? StateParser.empty_state("", Root)).id == id {
				$found = Ok(Node(i))
			}
		}
		for i in 0..<groups.len() {
			if (groups.get(i) ?? { id: "", title: "", descriptions: [], container: Root, direction: Inherit, classes: [], styles: [] }).id == id {
				$found = Ok(Group(i))
			}
		}
		$found
	}

	statement : Reader, Str -> Reader
	statement = |reader, text| {
		if text == "}" {
			if reader.stack.is_empty() {
				StateParser.problem(reader, Syntax({ near: text }))
			} else {
				{ ..reader, stack: reader.stack.drop_last(1) }
			}
		} else if text == "--" {
			StateParser.problem(reader, Unsupported("concurrent state regions"))
		} else if text.starts_with("direction ") {
			match StateParser.read_direction(FlowText.trim(Str.join_with(text.split_on(" ").drop_first(1), " "))) {
				Err(_) => StateParser.problem(reader, Syntax({ near: text }))
				Ok(direction) =>
					match reader.stack.last() {
						Err(_) => { ..reader, direction }
						Ok(i) =>
							match reader.groups.get(i) {
								Err(_) => StateParser.problem(reader, Syntax({ near: text }))
								Ok(group) => { ..reader, groups: reader.groups.set(i, { ..group, direction: Set(direction) }) ?? [] }
							}
					}
			}
		} else if text.starts_with("classDef ") {
			StateParser.class_def(reader, text)
		} else if text.starts_with("class ") {
			StateParser.class_statement(reader, text)
		} else if text.starts_with("style ") {
			StateParser.style_statement(reader, text)
		} else if text.starts_with("state ") {
			StateParser.declaration(reader, FlowText.trim(StateParser.after(text, "state ")))
		} else if text.contains("-->") {
			StateParser.transition(reader, text)
		} else if text.contains(":::") and !StateParser.split_label(text).found {
			styled = StateParser.styled_id(text)
			if !StateParser.valid_id(styled.id) or !styled.classes.all(StateParser.valid_id) {
				StateParser.problem(reader, Syntax({ near: text }))
			} else {
				next = StateParser.ensure(reader, styled.id, StateParser.current_container(reader))
				{ ..next, states: next.states.map(|state| if (state.id == styled.id) { ..state, classes: state.classes.concat(styled.classes) } else state) }
			}
		} else if text.contains(":") {
			found = StateParser.split_first(text, ":")
			id = FlowText.trim(found.left)
			if !StateParser.valid_id(id) {
				StateParser.problem(reader, Syntax({ near: text }))
			} else {
				next = StateParser.ensure(reader, id, StateParser.current_container(reader))
				description = FlowText.display(FlowText.trim(found.right))
				states = next.states.map(|state| if (state.id == id) { ..state, label: if (state.descriptions.is_empty()) description else state.label, descriptions: state.descriptions.append(description), effective_kind: Normal } else state)
				groups = next.groups.map(|group| if (group.id == id) { ..group, title: if (group.descriptions.is_empty()) description else group.title, descriptions: group.descriptions.append(description) } else group)
				{ ..next, states, groups }
			}
		} else if text.starts_with("%%{") or text.starts_with("---") or text.starts_with("click ") {
			StateParser.problem(reader, Unsupported(text))
		} else if StateParser.valid_id(text) {
			StateParser.ensure(reader, text, StateParser.current_container(reader))
		} else {
			StateParser.problem(reader, Syntax({ near: text }))
		}
	}

	declaration : Reader, Str -> Reader
	declaration = |reader, source| {
		opened = source.ends_with("{")
		raw = FlowText.trim(if (opened) Str.from_utf8_lossy(source.to_utf8().drop_last(1)) else source)
		annotation = StateParser.split_first(raw, "<<")
		base = FlowText.trim(annotation.left)
		named = StateParser.split_first(base, " as ")
		styled = StateParser.styled_id(if (named.found) named.right else base)
		id = styled.id
		label = FlowText.display(StateParser.unquote(if (named.found) named.left else styled.id))
		if !StateParser.valid_id(id) or !styled.classes.all(StateParser.valid_id) or (named.found and (!FlowText.trim(named.left).starts_with("\"") or !FlowText.trim(named.left).ends_with("\""))) {
			StateParser.problem(reader, Syntax({ near: source }))
		} else if opened {
			if reader.groups.any(|group| group.id == id) {
				StateParser.problem(reader, Syntax({ near: "duplicate composite ${id}" }))
			} else {
				prior = reader.states.find_first(|state| state.id == id)
				classes = (
					match prior {
						Ok(state) => state.classes
						Err(_) => []
					}
				).concat(styled.classes)
				styles = match prior {
					Ok(state) => state.styles
					Err(_) => []
				}
				descriptions = (
					match prior {
						Ok(state) => state.descriptions
						Err(_) => []
					}
				).concat(if (named.found) [label] else [])
				group = { id, title: descriptions.first() ?? id, descriptions, container: StateParser.current_container(reader), direction: Inherit, classes, styles }
				{ ..reader, groups: reader.groups.append(group), declarations: if (reader.declarations.contains(State(id))) reader.declarations.map(|item| if (item == State(id)) Composite(id) else item) else reader.declarations.append(Composite(id)), stack: reader.stack.append(reader.groups.len()) }
			}
		} else if reader.groups.any(|group| group.id == id) {
			if annotation.found {
				StateParser.problem(reader, Unsupported("composite state annotation"))
			} else {
				{ ..reader, groups: reader.groups.map(|group| if (group.id == id) { ..group, title: if (group.descriptions.is_empty()) label else group.title, descriptions: group.descriptions.concat(if (named.found) [label] else []), classes: group.classes.concat(styled.classes) } else group) }
			}
		} else {
			kind : StateModel.Kind
			kind = if annotation.found {
				match FlowText.trim(annotation.right) {
					"choice>>" => Choice
					"fork>>" => Fork
					"join>>" => Join
					_ => Normal
				}
			} else {
				Normal
			}
			next = StateParser.ensure(reader, id, StateParser.current_container(reader))
			known_annotation = !annotation.found or kind != Normal
			if !known_annotation {
				StateParser.problem(next, Unsupported("state annotation <<${annotation.right}"))
			} else {
				{ ..next, states: next.states.map(|state| if (state.id == id) { ..state, label: if (named.found and state.descriptions.is_empty()) label else state.label, descriptions: state.descriptions.concat(if (named.found) [label] else []), kind: if (annotation.found) kind else state.kind, effective_kind: if (named.found) Normal else if (!reader.states.any(|previous| previous.id == id)) kind else state.effective_kind, container: StateParser.current_container(reader), classes: state.classes.concat(styled.classes) } else state) }
			}
		}
	}

	transition : Reader, Str -> Reader
	transition = |reader, source| {
		arrow = StateParser.split_first(source, "-->")
		labelled = StateParser.split_label(arrow.right)
		from_styled = StateParser.styled_id(arrow.left)
		to_styled = StateParser.styled_id(labelled.left)
		from_text = from_styled.id
		to_text = to_styled.id
		from = if (from_text == "[*]") StateParser.pseudo_id(reader, "initial") else from_text
		to = if (to_text == "[*]") StateParser.pseudo_id(reader, "final") else to_text
		if from_text == "[H]" or from_text == "[H*]" or to_text == "[H]" or to_text == "[H*]" {
			StateParser.problem(reader, Unsupported("state history"))
		} else if (!StateParser.valid_id(from) and from_text != "[*]") or (!StateParser.valid_id(to) and to_text != "[*]") or labelled.left.contains("-->") or !from_styled.classes.all(StateParser.valid_id) or !to_styled.classes.all(StateParser.valid_id) {
			StateParser.problem(reader, Syntax({ near: source }))
		} else {
			first = StateParser.ensure(reader, from, StateParser.current_container(reader))
			second = StateParser.ensure(first, to, StateParser.current_container(reader))
			states = second.states.map(|state| if (state.id == from and from_text == "[*]") { ..state, kind: Initial, effective_kind: Initial, label: "" } else if (state.id == to and to_text == "[*]") { ..state, kind: Final, effective_kind: Final, label: "" } else if (state.id == from) { ..state, classes: state.classes.concat(from_styled.classes) } else if (state.id == to) { ..state, classes: state.classes.concat(to_styled.classes) } else state)
			if second.transitions.len() >= 500 {
				if (second.problems.contains(TooManyEdges)) second else StateParser.problem(second, TooManyEdges)
			} else {
				{ ..second, states, transitions: second.transitions.append({ from, to, label: FlowText.display(FlowText.trim(labelled.right)) }) }
			}
		}
	}

	pseudo_id : Reader, Str -> Str
	pseudo_id = |reader, kind| match reader.stack.last() {
		Err(_) => "@${kind}:root"
		Ok(group) => "@${kind}:${group.to_str()}"
	}

	current_container : Reader -> Flowchart.Container
	current_container = |reader| match reader.stack.last() {
		Err(_) => Root
		Ok(group) => Group(group)
	}

	ensure : Reader, Str, Flowchart.Container -> Reader
	ensure = |reader, id, container| {
		if reader.states.any(|state| state.id == id) or reader.groups.any(|group| group.id == id) {
			reader
		} else {
			{ ..reader, states: reader.states.append(StateParser.empty_state(id, container)), declarations: reader.declarations.append(State(id)) }
		}
	}

	empty_state : Str, Flowchart.Container -> StateModel.State
	empty_state = |id, container| { id, label: id, descriptions: [], kind: Normal, effective_kind: Normal, container, classes: [], styles: [] }

	read_note : Str -> Try({ note : RawNote, inline : Bool }, Flowchart.Problem)
	read_note = |text| {
		labelled = StateParser.split_first(text, ":")
		words = labelled.left.split_on(" ").keep_if(|s| s != "")
		match words {
			["note", side, "of", id] if (side == "left" or side == "right") and StateParser.valid_id(id) =>
				Ok({ note: { state: id, side: if (side == "left") Left else Right, text: FlowText.display(FlowText.trim(labelled.right)), after_transition: 0 }, inline: labelled.found })
			_ => Err(Syntax({ near: text }))
		}
	}

	class_def : Reader, Str -> Reader
	class_def = |reader, text| {
		rest = StateParser.after(text, "classDef ")
		parts = StateParser.split_first(rest, " ")
		if !parts.found or !StateParser.valid_id(parts.left) {
			StateParser.problem(reader, Syntax({ near: text }))
		} else {
			if reader.classes.any(|definition| definition.name == parts.left) {
				{ ..reader, classes: reader.classes.map(|definition| if (definition.name == parts.left) { ..definition, styles: definition.styles.concat(StateParser.css(parts.right)) } else definition) }
			} else {
				{ ..reader, classes: reader.classes.append({ name: parts.left, styles: StateParser.css(parts.right) }) }
			}
		}
	}

	class_statement : Reader, Str -> Reader
	class_statement = |reader, text| {
		words = StateParser.after(text, "class ").split_on(" ").keep_if(|part| part != "")
		name = words.last() ?? ""
		ids = Str.join_with(words.drop_last(1), "").split_on(",").map(FlowText.trim)
		if !StateParser.valid_id(name) or words.len() < 2 or !ids.all(StateParser.valid_id) {
			StateParser.problem(reader, Syntax({ near: text }))
		} else {
			next = ids.fold(reader, |acc, id| StateParser.ensure(acc, id, StateParser.current_container(reader)))
			{
				..next,
				states: next.states.map(|state| if (ids.contains(state.id)) { ..state, classes: state.classes.append(name) } else state),
				groups: next.groups.map(|group| if (ids.contains(group.id)) { ..group, classes: group.classes.append(name) } else group),
			}
		}
	}

	style_statement : Reader, Str -> Reader
	style_statement = |reader, text| {
		parts = StateParser.split_first(StateParser.after(text, "style "), " ")
		id = parts.left
		styles = StateParser.css(parts.right)
		if !parts.found or !StateParser.valid_id(id) {
			StateParser.problem(reader, Syntax({ near: text }))
		} else if reader.groups.any(|group| group.id == id) {
			{ ..reader, groups: reader.groups.map(|group| if (group.id == id) { ..group, styles } else group) }
		} else {
			next = StateParser.ensure(reader, id, StateParser.current_container(reader))
			{ ..next, states: next.states.map(|s| if (s.id == id) { ..s, styles } else s) }
		}
	}

	css : Str -> List(Str)
	css = |text| {
		var $parts = []
		var $part = []
		var $depth = 0
		for c in text.to_utf8() {
			if c == '(' {
				$depth = $depth + 1
			}
			if c == ')' and $depth > 0 {
				$depth = $depth - 1
			}
			if c == ',' and $depth == 0 {
				$parts = $parts.append(FlowText.trim(Str.from_utf8_lossy($part)))
				$part = []
			} else {
				$part = $part.append(c)
			}
		}
		$parts.append(FlowText.trim(Str.from_utf8_lossy($part)))
	}

	read_direction : Str -> Try(Flowchart.Direction, [BadDirection])
	read_direction = |text| match text {
		"LR" => Ok(Right)
		"RL" => Ok(Left)
		"TB" | "TD" => Ok(Down)
		"BT" => Ok(Up)
		_ => Err(BadDirection)
	}

	problem : Reader, Flowchart.Problem -> Reader
	problem = |reader, problem| { ..reader, problems: reader.problems.append(problem) }

	valid_id : Str -> Bool
	valid_id = |text| !text.is_empty() and !text.to_utf8().any(|c| c <= ' ' or c == ':' or c == ';' or c == '{' or c == '}' or c == '[' or c == ']' or c == '"' or c == '<' or c == '>' or c == '@')

	styled_id : Str -> { id : Str, classes : List(Str) }
	styled_id = |text| {
		parts = FlowText.trim(text).split_on(":::")
		{ id: FlowText.trim(parts.first() ?? ""), classes: parts.drop_first(1).map(FlowText.trim) }
	}

	split_label : Str -> { left : Str, right : Str, found : Bool }
	split_label = |text| {
		bytes = text.to_utf8()
		var $quoted = False
		var $at = bytes.len()
		var $i = 0
		while $i < bytes.len() {
			c = bytes.get($i) ?? 0
			if c == '"' {
				$quoted = !$quoted
			}
			previous = if ($i > 0) bytes.get($i - 1) ?? 0 else 0
			if !$quoted and c == ':' and previous != ':' and (bytes.get($i + 1) ?? 0) != ':' {
				$at = $i
				break
			}
			$i = $i + 1
		}
		{ left: Str.from_utf8_lossy(bytes.take_first($at)), right: Str.from_utf8_lossy(bytes.drop_first($at + 1)), found: $at < bytes.len() }
	}

	split_first : Str, Str -> { left : Str, right : Str, found : Bool }
	split_first = |text, delimiter| {
		parts = text.split_on(delimiter)
		{ left: parts.first() ?? "", right: Str.join_with(parts.drop_first(1), delimiter), found: parts.len() > 1 }
	}

	after : Str, Str -> Str
	after = |text, prefix| Str.from_utf8_lossy(text.to_utf8().drop_first(prefix.to_utf8().len()))

	unquote : Str -> Str
	unquote = |text| {
		raw = FlowText.trim(text)
		if raw.starts_with("\"") and raw.ends_with("\"") and raw.to_utf8().len() >= 2 {
			Str.from_utf8_lossy(raw.to_utf8().drop_first(1).drop_last(1))
		} else {
			raw
		}
	}

	comment : Str -> Str
	comment = |text| {
		if FlowText.trim(text).starts_with("%%{") {
			return text
		}
		var $quoted = False
		var $out = []
		var $i = 0
		bytes = text.to_utf8()
		while $i < bytes.len() {
			c = bytes.get($i) ?? 0
			if c == '"' {
				$quoted = !$quoted
			}
			if !$quoted and c == '%' and (bytes.get($i + 1) ?? 0) == '%' {
				break
			}
			$out = $out.append(c)
			$i = $i + 1
		}
		Str.from_utf8_lossy($out)
	}

	statements : Str -> List(Str)
	statements = |text| {
		var $out = []
		var $part = []
		var $quoted = False
		for c in text.to_utf8() {
			if c == '"' {
				$quoted = !$quoted
			}
			if c == ';' and !$quoted {
				$out = $out.append(Str.from_utf8_lossy($part))
				$part = []
			} else {
				$part = $part.append(c)
			}
		}
		$out.append(Str.from_utf8_lossy($part))
	}
}
