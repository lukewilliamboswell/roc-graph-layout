import Flowchart
import FlowText
import SequenceData

SequenceParse :: {}.{
	parse : Str -> Try(SequenceData.Diagram, List(Flowchart.Problem))
	parse = |source| {
		if source.split_on("\n").map(Str.trim).any(|line| line.starts_with("%%{")) {
			return Err([Unsupported("sequence configuration directive")])
		}
		lines = source.split_on("\n").map(Str.trim).keep_if(|line| !line.is_empty() and !line.starts_with("%%"))
		if (lines.first() ?? "") != "sequenceDiagram" {
			return Err([Unsupported("expected sequenceDiagram")])
		}
		var $participants = []
		var $events = []
		var $problems = []
		var $blocks = []
		var $autonumber = False
		var $title = ""
		for line in lines.drop_first(1) {
			if line.starts_with("participant ") or line.starts_with("actor ") {
				actor = line.starts_with("actor ")
				raw = Str.from_utf8_lossy(
					line.to_utf8().drop_first(
						if actor {
							6
						} else {
							12
						},
					),
				).trim()
				parts = raw.split_on(" as ")
				id = (parts.first() ?? "").trim()
				label = if parts.len() > 1 {
					Str.join_with(parts.drop_first(1), " as ").trim()
				} else {
					id
				}
				if !SequenceParse.valid_id(id) or label.is_empty() {
					$problems = $problems.append(Syntax({ near: line }))
				} else {
					ensured = SequenceParse.ensure($participants, id)
					$participants = ensured.participants
					# ensure proves this index is in bounds.
					$participants = $participants.set(ensured.index, { id, label: SequenceParse.label(label), actor }) ?? []
				}
			} else if line == "autonumber" {
				$autonumber = True
			} else if line.starts_with("title ") {
				$title = Str.from_utf8_lossy(line.to_utf8().drop_first(6)).trim()
			} else if line.starts_with("activate ") or line.starts_with("deactivate ") {
				activate = line.starts_with("activate ")
				id = Str.from_utf8_lossy(
					line.to_utf8().drop_first(
						if activate {
							9
						} else {
							11
						},
					),
				).trim()
				if !SequenceParse.valid_id(id) {
					$problems = $problems.append(Syntax({ near: line }))
				} else {
					ensured = SequenceParse.ensure($participants, id)
					$participants = ensured.participants
					$events = $events.append(
						if activate {
							Activate(ensured.index)
						} else {
							Deactivate(ensured.index)
						},
					)
				}
			} else if line == "end" {
				if $blocks.is_empty() {
					$problems = $problems.append(Syntax({ near: line }))
				} else {
					$blocks = $blocks.drop_last(1)
					$events = $events.append(EndBlock)
				}
			} else if line == "else" or line.starts_with("else ") or line == "and" or line.starts_with("and ") or line == "option" or line.starts_with("option ") {
				kind = line.split_on(" ").first() ?? ""
				parent = $blocks.last() ?? ""
				allowed = (kind == "else" and parent == "alt") or (kind == "and" and parent == "par") or (kind == "option" and parent == "critical")
				if !allowed {
					$problems = $problems.append(Syntax({ near: line }))
				} else {
					$events = $events.append(Branch({ kind, text: Str.from_utf8_lossy(line.to_utf8().drop_first(kind.to_utf8().len())).trim() }))
				}
			} else if SequenceParse.block_kind(line) != "" {
				kind = SequenceParse.block_kind(line)
				$blocks = $blocks.append(kind)
				$events = $events.append(StartBlock({ kind, text: Str.from_utf8_lossy(line.to_utf8().drop_first(kind.to_utf8().len())).trim() }))
			} else if line.starts_with("Note ") or line.starts_with("note ") {
				raw = Str.from_utf8_lossy(line.to_utf8().drop_first(5))
				match SequenceParse.split(raw, ":") {
					None => {
						$problems = $problems.append(Syntax({ near: line }))
					}
					Some(parts) => {
						spec = parts.before.trim()
						side = if spec.starts_with("left of ") {
							Left
						} else if spec.starts_with("right of ") {
							Right
						} else {
							Over
						}
						prefix = if spec.starts_with("left of ") {
							8
						} else if spec.starts_with("right of ") {
							9
						} else if spec.starts_with("over ") {
							5
						} else {
							0
						}
						ids = Str.from_utf8_lossy(spec.to_utf8().drop_first(prefix)).split_on(",").map(Str.trim)
						if prefix == 0 or ids.is_empty() or ids.len() > 2 or !ids.all(SequenceParse.valid_id) or (side != Over and ids.len() != 1) {
							$problems = $problems.append(Syntax({ near: line }))
						} else {
							first = SequenceParse.ensure($participants, ids.first() ?? "")
							last = SequenceParse.ensure(first.participants, ids.last() ?? "")
							$participants = last.participants
							$events = $events.append(Note({ from: first.index, to: last.index, side, text: SequenceParse.label(parts.after) }))
						}
					}
				}
			} else {
				match SequenceParse.message(line) {
					Err(problem) => {
						$problems = $problems.append(problem)
					}
					Ok(m) => {
						first = SequenceParse.ensure($participants, m.from)
						last = SequenceParse.ensure(first.participants, m.to)
						$participants = last.participants
						$events = $events.append(Message({ from: first.index, to: last.index, text: SequenceParse.label(m.text), dotted: m.dotted, head: m.head, both: m.both, activation: m.activation }))
					}
				}
			}
		}
		if !$blocks.is_empty() {
			$problems = $problems.append(Syntax({ near: "unclosed sequence block" }))
		}
		var $depths = List.repeat(0, $participants.len())
		for event in $events {
			action = match event {
				Activate(i) => Some({ index: i, start: True })
				Deactivate(i) => Some({ index: i, start: False })
				Message(m) => match m.activation {
					Keep => None
					Start => Some({ index: m.to, start: True })
					Stop => Some({ index: m.from, start: False })
				}
				_ => None
			}
			match action {
				None => {}
				Some(a) => {
					depth = $depths.get(a.index) ?? 0
					if !a.start and depth == 0 {
						$problems = $problems.append(Syntax({ near: "deactivate without activate" }))
					} else {
						# Events are constructed from ensured participant indices.
						$depths = $depths.set(
							a.index,
							if a.start {
								depth + 1
							} else {
								depth - 1
							},
						) ?? []
					}
				}
			}
		}
		if !$problems.is_empty() {
			Err($problems)
		} else {
			Ok({ participants: $participants, events: $events, autonumber: $autonumber, title: $title })
		}
	}

	block_kind : Str -> Str
	block_kind = |line| ["alt", "opt", "loop", "par", "critical", "break"].find_first(|kind| line == kind or line.starts_with("${kind} ")) ?? ""

	label : Str -> Str
	label = |raw| FlowText.display(raw.trim())

	valid_id : Str -> Bool
	valid_id = |id| !id.is_empty() and id.to_utf8().all(|c| c != ' ' and c != '\t' and c != ':' and c != ';' and c != '-' and c != '>' and c != '<' and c != '{' and c != '}' and c != '"')

	ensure : List(SequenceData.Participant), Str -> { participants : List(SequenceData.Participant), index : U64 }
	ensure = |participants, id| {
		match participants.find_first_index(|p| p.id == id) {
			Ok(index) => { participants, index }
			Err(_) => { participants: participants.append({ id, label: id, actor: False }), index: participants.len() }
		}
	}

	split : Str, Str -> [None, Some({ before : Str, after : Str })]
	split = |text, separator| {
		parts = text.split_on(separator)
		if parts.len() < 2 {
			None
		} else {
			Some({ before: parts.first() ?? "", after: Str.join_with(parts.drop_first(1), separator) })
		}
	}

	message : Str -> Try({ from : Str, to : Str, text : Str, dotted : Bool, head : [None, Arrow, Open, Cross], both : Bool, activation : [Keep, Start, Stop] }, Flowchart.Problem)
	message = |line| {
		match SequenceParse.split(line, ":") {
			None => Err(Unsupported("sequence statement: ${line}"))
			Some(parts) => {
				for arrow in ["<<-->>", "<<->>", "-->>", "->>", "--x", "-x", "--)", "-)", "-->", "->"] {
					match SequenceParse.split(parts.before, arrow) {
						None => {}
						Some(ends) => {
							from = ends.before.trim()
							raw_to = ends.after.trim()
							activation = if raw_to.starts_with("+") {
								Start
							} else if raw_to.starts_with("-") {
								Stop
							} else {
								Keep
							}
							to = if activation == Keep {
								raw_to
							} else {
								Str.from_utf8_lossy(raw_to.to_utf8().drop_first(1)).trim()
							}
							if !SequenceParse.valid_id(from) or !SequenceParse.valid_id(to) {
								return Err(Syntax({ near: line }))
							}
							head = if arrow.ends_with("x") {
								Cross
							} else if arrow.ends_with(")") {
								Open
							} else if arrow.ends_with(">>") {
								Arrow
							} else {
								None
							}
							return Ok({ from, to, text: parts.after, dotted: arrow.to_utf8().contains('-') and arrow.contains("--"), head, both: arrow.starts_with("<<"), activation })
						}
					}
				}
				Err(Unsupported("sequence statement: ${line}"))
			}
		}
	}
}

expect
	match SequenceParse.parse("sequenceDiagram\nA->>B: x\nB-->>A: y\n") {
		Ok(d) => d.participants.map(|p| p.id) == ["A", "B"] and d.events.len() == 2
		Err(_) => False
	}

expect
	match SequenceParse.parse("sequenceDiagram\nalt allowed\nloop retry\nA->>B: x\nend\nelse denied\nB-->>A: no\nend\n") {
		Ok(d) => d.events.len() == 7
		Err(_) => False
	}

expect
	match SequenceParse.parse("sequenceDiagram\ndeactivate A\nend\nbox unsupported\n") {
		Err(problems) => problems.len() == 3
		Ok(_) => False
	}

expect
	match SequenceParse.parse("sequenceDiagram\nA->>+B: begin\nB-->>-A: finish\nNote over A,B: one<br/>two\nA-)B: async\nB--xA: cancel\nA<<-->>B: both\n") {
		Err(_) => False
		Ok(d) => d.events.len() == 6 and match d.events.get(2) {
			Ok(Note(n)) => n.text == "one\ntwo" and n.from == 0 and n.to == 1
			_ => False
		}
	}

expect
	match SequenceParse.parse("sequenceDiagram\nactor A as Person\nA->>B: request\nparticipant B as Backend\n") {
		Err(_) => False
		Ok(d) => d.participants.map(|p| p.label) == ["Person", "Backend"]
	}

expect
	match SequenceParse.parse("sequenceDiagram\npar one\nA->>B: first\nand two\nA->>C: second\nend\n") {
		Err(_) => False
		Ok(d) => d.participants.len() == 3 and d.events.len() == 5
	}

expect
	match SequenceParse.parse("%%{init: {}}%%\nsequenceDiagram\nA->>B: request\n") {
		Err([Unsupported(_)]) => True
		_ => False
	}
