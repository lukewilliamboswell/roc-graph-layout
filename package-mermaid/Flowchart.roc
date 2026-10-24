import FlowDb
import FlowLexer
import FlowParser
import FlowSource

## Read Mermaid flowchart text (`flowchart` or `graph`) into a diagram of
## nodes, edges and groups. The result is what Mermaid itself understands
## from the same text: the same text is accepted or rejected, ids resolve to
## the same nodes, and labels read the same, including Mermaid's handling of
## `#name;` entities and `<br>` line breaks.
##
## Some Mermaid features are recognised but not interpreted yet, such as
## `click` handlers, `@{ ... }` shape data, markdown strings, front matter and
## HTML markup in labels. Text using them is reported as `Unsupported` rather
## than read approximately.
##
## Labels keep everything the author wrote, where Mermaid's plain-text label
## rendering does not: a `>` in a label without a `<` is kept (Mermaid drops
## it, drawing `a -> b` as `a - b`), and `#quot;`-style entities show as the
## characters they name, as Mermaid's default HTML labels show them.
Flowchart := [].{

	## Which way the flow runs: `TB`/`TD` read down, `BT` up, `LR` right and
	## `RL` left.
	Direction : [Down, Up, Right, Left]

	## The outline a node is drawn with, named after Mermaid's bracket forms:
	## `[ ]` rectangle, `( )` rounded, `([ ])` stadium, `[[ ]]` subroutine,
	## `[( )]` cylinder, `(( ))` circle, `((( )))` double circle, `(- -)`
	## ellipse, `> ]` asymmetric, `{ }` diamond, `{{ }}` hexagon, `[/ /]` lean
	## right, `[\ \]` lean left, `[/ \]` trapezoid and `[\ /]` inverse
	## trapezoid. A node written without brackets is a rectangle.
	Shape : [Rectangle, Rounded, Stadium, Subroutine, Cylinder, Circle, DoubleCircle, Ellipse, Asymmetric, Diamond, Hexagon, LeanRight, LeanLeft, Trapezoid, InverseTrapezoid]

	## How an edge's line is drawn: `---` solid, `===` thick, `-.-` dotted,
	## `~~~` invisible.
	Line : [Solid, Thick, Dotted, Invisible]

	## What an edge end looks like: nothing, `>` arrow, `o` circle or `x`
	## cross.
	Arrowhead : [None, Arrow, Circle, Cross]

	## Where a node or group sits: at the top level, or inside the group at
	## this index of `groups`.
	Container : [Root, Group(U64)]

	## An edge end: the node at this index of `nodes`, or the group at this
	## index of `groups` when the edge names a subgraph.
	Endpoint : [Node(U64), Group(U64)]

	## A node in first-mention order. `label` is the displayed text, with
	## line breaks as `\n`. `classes` and `styles` are the class names and
	## CSS declarations the source attached, kept as written.
	Node : { id : Str, label : Str, shape : Shape, container : Container, classes : List(Str), styles : List(Str) }

	## An edge in source order. `length` is how many layers the edge asks to
	## span, from the number of dashes, dots or equals signs (1 to 10). `id`
	## is the id given with `id@-->`, or Mermaid's generated one.
	Edge : {
		id : Str,
		from : Endpoint,
		to : Endpoint,
		label : Str,
		line : Line,
		start : Arrowhead,
		end : Arrowhead,
		length : U64,
		classes : List(Str),
		styles : List(Str),
	}

	## A `subgraph`, in the order the subgraphs are declared. `direction` is
	## set by a `direction` statement inside it.
	Group : { id : Str, title : Str, container : Container, direction : [Inherit, Set(Direction)], classes : List(Str) }

	## A `classDef`: a class name and its CSS declarations.
	ClassDef : { name : Str, styles : List(Str) }

	Diagram : { direction : Direction, nodes : List(Node), edges : List(Edge), groups : List(Group), classes : List(ClassDef) }

	## Why text could not be read. `Syntax` quotes the text where reading
	## stopped. `MissingLinkStyleEdge` names a `linkStyle` position with no
	## edge, and `UnnamedGroup` is a `subgraph` with no name; Mermaid rejects
	## both. `TooManyEdges` is Mermaid's limit of 500 edges.
	Problem : [
		NotAFlowchart,
		Syntax({ near : Str }),
		Unsupported(Str),
		TooManyEdges,
		MissingLinkStyleEdge(Str),
		UnnamedGroup,
	]

	## Read flowchart text.
	parse : Str -> [Ok(Diagram), Err(List(Problem))]
	parse = |text|
		match FlowSource.prepare(text) {
			NotFlowchart => Err([NotAFlowchart])
			Unsupported(feature) => Err([Unsupported(feature)])
			Flowchart(bytes) =>
				match FlowLexer.tokenize(bytes) {
					NoRule(at) => Err([Syntax({ near: Flowchart.near(bytes, at) })])
					Unsupported(found) => Err([Unsupported(found.feature)])
					Tokens(tokens) =>
						match FlowParser.parse(bytes, tokens) {
							Err(Syntax(index)) => {
								at = match tokens.get(index) {
									Ok(token) => token.start
									Err(_) => bytes.len()
								}
								Err([Syntax({ near: Flowchart.near(bytes, at) })])
							}
							Err(Unsupported(feature)) => Err([Unsupported(feature)])
							Ok(parsed) =>
								match FlowDb.apply(parsed.events) {
									Err(problem) => Err([Flowchart.from_db(problem)])
									Ok(state) =>
										match FlowDb.diagram(state, parsed.direction) {
											Ok(diagram) => Ok(diagram)
											Err(problem) => Err([Flowchart.from_db(problem)])
										}
								}
						}
				}
		}

	from_db : FlowDb.Problem -> Problem
	from_db = |problem|
		match problem {
			TooManyEdges => TooManyEdges
			MissingLinkStyleEdge(position) => MissingLinkStyleEdge(position)
			UnnamedGroup => UnnamedGroup
			Unsupported(feature) => Unsupported(feature)
		}

	# Up to 24 bytes of the rest of the line at `at`, for error messages.
	near : List(U8), U64 -> Str
	near = |bytes, at| {
		var $end = at
		while $end < bytes.len() and $end - at < 24 and (bytes.get($end) ?? '\n') != '\n' {
			$end = $end + 1
		}
		Str.from_utf8_lossy(bytes.sublist({ start: at, len: $end - at }))
	}
}

expect
	Flowchart.parse("flowchart LR\n  A[Start] -->|go| B{Choice}\n")
		== Ok({
			direction: Right,
			nodes: [
				{ id: "A", label: "Start", shape: Rectangle, container: Root, classes: [], styles: [] },
				{ id: "B", label: "Choice", shape: Diamond, container: Root, classes: [], styles: [] },
			],
			edges: [
				{ id: "L_A_B_0", from: Node(0), to: Node(1), label: "go", line: Solid, start: None, end: Arrow, length: 1, classes: [], styles: [] },
			],
			groups: [],
			classes: [],
		})

expect Flowchart.parse("sequenceDiagram\n") == Err([NotAFlowchart])
expect Flowchart.parse("flowchart TD\n  A --> B %% trailing\n") == Err([Syntax({ near: "%% trailing" })])
expect Flowchart.parse("flowchart TD\n  subgraph\n  A\n  end\n") == Err([UnnamedGroup])
expect Flowchart.parse("flowchart TD\n  A --> B\n  linkStyle 1 stroke:red\n") == Err([MissingLinkStyleEdge("1")])
