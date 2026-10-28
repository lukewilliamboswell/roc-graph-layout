import Drawing
import DiagramView
import StateDraw
import StateParser
import Theme

## Draw state lifecycles from `stateDiagram` or `stateDiagram-v2` text.
## Initial and final states, labelled transitions, aliases, descriptions,
## nested composite states, directions and choice/fork/join markers retain
## their state-machine meaning. Notes are adjacent layout nodes joined
## to their states by dashed associations. `classDef`, `class` and `style`
## change state colours, outlines and text colours. Pinned Mermaid retains
## composite style declarations but paints those composites using the
## base node colours; unstyled composites use the group colours.
##
## Concurrent regions, history states and interactions are reported as
## unsupported rather than approximated. State and transition lists preserve
## source order; endpoints use indices into states or composite groups.
StateDiagram := [].{

	## State-specific marks. Initial and final marks are scoped to their
	## composite; they are separate states even though both spell `[*]`.
	Kind : [Normal, Initial, Final, Choice, Fork, Join]

	Direction : [Down, Up, Right, Left]
	Container : [Root, Group(U64)]

	## A zero-based state index or a zero-based composite group index.
	Endpoint : [Node(U64), Group(U64)]

	## Descriptions retain every authored alias and description in order.
	## The first description is the display label, or the id when none was
	## supplied; further descriptions form the state's body compartment.
	## `kind` preserves the author's declaration. `effective_kind` follows
	## Mermaid's first registration: a stereotype declared after a transition
	## has already created the state retains the ordinary rendered shape.
	State : { id : Str, label : Str, descriptions : List(Str), kind : Kind, effective_kind : Kind, container : Container, classes : List(Str), styles : List(Str) }
	Transition : { from : Endpoint, to : Endpoint, label : Str }

	## A note retains how many transitions precede its declaration, so its
	## association preserves the source order of all graph edges.
	Note : { state : Endpoint, side : [Left, Right], text : Str, after_transition : U64 }
	Group : { id : Str, title : Str, descriptions : List(Str), container : Container, direction : [Inherit, Set(Direction)], classes : List(Str), styles : List(Str) }
	ClassDef : { name : Str, styles : List(Str) }

	## States, transitions, composites, style classes and notes remain in
	## source order. Containers refer to this diagram's `groups` list.
	## First registration order across states, composites and notes. State
	## and composite entries carry ids; note entries index the notes list.
	## This order determines deterministic placement and port ordering.
	Declaration : [State(Str), Composite(Str), Note(U64)]
	Diagram : { declarations : List(Declaration), direction : Direction, states : List(State), transitions : List(Transition), groups : List(Group), classes : List(ClassDef), notes : List(Note) }

	## Statement and shared drawing problems. `Syntax` includes the text
	## near an error; `Unsupported` explains a recognised feature that is
	## not interpreted; `InvalidTheme` identifies a numeric theme property.
	Problem : [NotAFlowchart, Syntax({ near : Str }), Unsupported(Str), InvalidTheme(Str), TooManyEdges, MissingLinkStyleEdge(Str), UnnamedGroup]

	## Read all independent statement problems in one result.
	parse : Str -> Try(Diagram, List(Problem))
	parse = StateParser.parse

	## Read and draw text with a shared theme. Numeric theme problems and
	## independent syntax problems are reported together. A base padding of 15
	## gives 8 pixels around state labels and 15 around notes; other padding
	## values scale these roles together. Family-default wrapping applies
	## to ordinary states and notes; transition labels and description
	## compartments stay unwrapped.
	## Composite frames are square by default, while ordinary states are
	## rounded. Explicit wrapping/corner choices override the role defaults.
	## `transition_label_background` colours the square backing of transition
	## labels; its default is white.
	draw : Str, Theme.Options -> Try(Drawing.Picture, List(Problem))
	draw = |source, options| {
		problems = Theme.validate(options)
		match StateDiagram.parse(source) {
			Err(syntax) => Err(problems.concat(syntax))
			Ok(diagram) => if (problems.is_empty()) Ok(DiagramView.finish(StateDraw.draw(diagram, options), options)) else Err(problems)
		}
	}

}

expect
	match StateDiagram.parse("stateDiagram-v2\n[*] --> Idle\nIdle --> Running : begin\nRunning --> [*]\n") {
		Ok(d) => d.states.len() == 4 and d.transitions.len() == 3 and d.states.first()?.kind == Initial and d.states.last()?.kind == Final
		Err(_) => False
	}

expect
	match StateDiagram.parse("stateDiagram\nstate \"Waiting for approval\" as Waiting\nWaiting: entry / notify\nWaiting: exit / dismiss\n") {
		Ok(d) => d.states.len() == 1 and (d.states.first()?.label == "Waiting for approval") and d.states.first()?.descriptions == ["Waiting for approval", "entry / notify", "exit / dismiss"]
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
		Ok(picture) => Drawing.is_finite(picture) and picture == DiagramView.finish(StateDraw.draw(StateDiagram.parse("stateDiagram-v2\nA --> B : a long transition label that needs to wrap into several lines\nB --> A\n")?, Theme.Options.{ max_label_width: 90, line_height: 1.8 }), Theme.Options.{ max_label_width: 90, line_height: 1.8 })
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

## Pinned Mermaid registers a state on its first transition; a later
## stereotype preserves declaration intent without replacing its shape.
expect
	match StateDiagram.parse("stateDiagram-v2\n[*] --> Select\nstate Select <<choice>>\n") {
		Ok(d) => (d.states.get(1) ?? crash "state exists").kind == Choice and (d.states.get(1) ?? crash "state exists").effective_kind == Normal
		Err(_) => False
	}

## Pinned Mermaid trims the block's outside whitespace while preserving
## indentation and blank lines inside a multiline note.
expect
	match StateDiagram.parse("stateDiagram-v2\nA\nnote right of A\n    First line\n        Second line\n\n    Fourth line\nend note\n") {
		Ok(d) => d.notes.first()?.text == "First line\n        Second line\n\n    Fourth line"
		Err(_) => False
	}

## The pinned state DB registers note containers inline, before a later
## final state; association edges retain their declaration positions too.
expect {
	d = StateDiagram.parse("stateDiagram-v2\n[*] --> Ready\nReady --> Done\nnote left of Ready: prepare\nnote right of Done: notify\nDone --> [*]\n")?
	d.declarations.take_last(3) == [Note(0), Note(1), State(d.states.last()?.id)]
		and d.notes.map(|note| note.after_transition) == [2, 2]
}
