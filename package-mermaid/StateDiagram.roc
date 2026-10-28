import Drawing
import Flowchart
import StateDraw
import StateModel
import StateParser
import Theme

## Draw state lifecycles from `stateDiagram` or `stateDiagram-v2` text.
## Initial and final states, labelled transitions, aliases, descriptions,
## nested composite states, directions and choice/fork/join markers retain
## their state-machine meaning. Notes are arranged in non-overlapping side
## columns and name the state they describe. `classDef`, `class` and `style`
## change node and composite colours, outlines and text.
##
## Concurrent regions, history states and interactions are reported as
## unsupported rather than approximated. State and transition lists preserve
## source order; endpoints use indices into states or composite groups.
StateDiagram := [].{
	Kind : StateModel.Kind
	State : StateModel.State
	Transition : StateModel.Transition
	Note : StateModel.Note
	Diagram : StateModel.Diagram
	Problem : Flowchart.Problem

	## Read all independent statement problems in one result.
	parse : Str -> Try(Diagram, List(Problem))
	parse = StateParser.parse

	## Read and draw text with a shared theme. Numeric theme problems and
	## independent syntax problems are reported together.
	draw : Str, Theme.Options -> Try(Drawing.Picture, List(Problem))
	draw = |source, options| {
		problems = Theme.validate(options)
		match StateDiagram.parse(source) {
			Err(syntax) => Err(problems.concat(syntax))
			Ok(diagram) => if (problems.is_empty()) Ok(StateDiagram.draw_diagram(diagram, options)) else Err(problems)
		}
	}

	## Draw an already-read state machine with validated theme options.
	draw_diagram : Diagram, Theme.Options -> Drawing.Picture
	draw_diagram = StateDraw.draw
}

expect
	match StateDiagram.parse("stateDiagram-v2\n[*] --> Idle\nIdle --> Running : begin\nRunning --> [*]\n") {
		Ok(d) => d.states.len() == 4 and d.transitions.len() == 3 and d.states.first()?.kind == Initial and d.states.last()?.kind == Final
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram\nstate \"Waiting for approval\" as Waiting\nWaiting: entry / notify\nWaiting: exit / dismiss\n") {
		Ok(d) => d.states.len() == 1 and (d.states.first()?.label == "Waiting for approval") and d.states.first()?.descriptions == ["entry / notify", "exit / dismiss"]
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\n[*] --> Machine\nstate Machine {\n[*] --> Idle\nIdle --> [*]\n}\nMachine --> [*]\n") {
		Ok(d) => d.groups.len() == 1 and d.states.len() == 5 and d.states.count_if(|s| s.kind == Initial) == 2 and d.states.count_if(|s| s.kind == Final) == 2 and d.transitions.len() == 4
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nstate Check <<choice>>\nstate Split <<fork>>\nstate Merge <<join>>\nCheck --> Split\nSplit --> Merge\n") {
		Ok(d) => d.states.map(|s| s.kind) == [Choice, Fork, Join]
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\ndirection LR\nA --> A : retry\nA --> B\nA --> B : again\nnote right of A : Watch retries\n") {
		Ok(d) => d.direction == Right and d.transitions.len() == 3 and d.notes.len() == 1
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nstate A {\n--\nclick A\n") {
		Err(problems) => problems.len() == 3
		Ok(_) => False
	}

expect
	match StateDiagram.draw("stateDiagram-v2\n", Theme.Options.{}) {
		Ok(picture) => Drawing.is_finite(picture)
		Err(_) => False
	}

expect
	match StateDiagram.draw("stateDiagram-v2\nA --> B : a long transition label that needs to wrap into several lines\nB --> A\n", Theme.Options.{ max_label_width: 90, line_height: 1.8 }) {
		Ok(picture) => Drawing.is_finite(picture) and picture == StateDiagram.draw_diagram(StateDiagram.parse("stateDiagram-v2\nA --> B : a long transition label that needs to wrap into several lines\nB --> A\n")?, Theme.Options.{ max_label_width: 90, line_height: 1.8 })
		Err(_) => False
	}

## The global start/stop pair and each composite's pair remain distinct,
## even when groups are referenced before their declarations.
expect
	match StateDiagram.parse("stateDiagram-v2\nOuter --> [*]\nstate Outer {\n state Inner {\n  [*] --> Leaf\n  Leaf --> [*]\n }\n [*] --> Inner\n Inner --> [*]\n}\n[*] --> Outer\n") {
		Ok(d) => d.groups.len() == 2 and d.states.count_if(|s| s.kind == Initial) == 3 and d.states.count_if(|s| s.kind == Final) == 3 and d.transitions.len() == 6
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nclass A, B ready\nclassDef ready fill:#D1FAE5\nA:::ready --> B:::ready : go: now\n") {
		Ok(d) => d.states.len() == 2 and d.states.all(|s| s.classes == ["ready", "ready"]) and d.transitions.first()?.label == "go: now"
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nstate Parent {\nChild\n}\nParent: A labelled composite\n") {
		Ok(d) => d.states.len() == 1 and d.groups.first()?.title == "A labelled composite"
		Err(_) => False
	}

expect
	match StateDiagram.draw("stateDiagram-v2\nA --> [H]\n--\n", Theme.Options.{ font_size: 0, padding: -1 }) {
		Err(problems) => problems.len() == 4
		Ok(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\n%%{init: {'theme': 'dark'}}%%\nA --> B\n") {
		Err(problems) => !problems.is_empty()
		Ok(_) => False
	}

expect
	match StateDiagram.draw("stateDiagram-v2\nA --> B\n", Theme.Options.{ shadow: Shadow({ dx: 500, dy: -200, opacity: 0.2 }), line_width: 100 }) {
		Ok(picture) => Drawing.is_finite(picture) and picture.view.width > 500 and picture.view.y < -100
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nstate \"Named before its body\" as Parent\nstate Parent {\nChild\n}\n") {
		Ok(d) => d.groups.first()?.title == "Named before its body"
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nstate Parent {\nChild\n}\nstate \"Named after its body\" as Parent\n") {
		Ok(d) => d.groups.first()?.title == "Named after its body"
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram-v2\nstate \"unterminated as Broken\n") {
		Err(_) => True
		Ok(_) => False
	}
