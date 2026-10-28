import Drawing
import SequenceDraw
import SequenceParse
import Theme

## Conversations between participants, with time running down the page.
## Accepts Mermaid `sequenceDiagram` text, participants and actors with
## aliases, messages, notes, activation bars, nested interaction blocks and
## automatic message numbering. Unsupported statements are reported rather
## than omitted. Labels wrap before columns and rows are spaced.
## Participant creation/destruction, participant boxes, `rect` highlights,
## links, configuration directives and front matter are not supported.
Sequence :: {}.{
	Participant : { id : Str, label : Str, actor : Bool }
	Message : { from : U64, to : U64, text : Str, dotted : Bool, head : [None, Arrow, Open, Cross], both : Bool, activation : [Keep, Start, Stop] }
	Note : { from : U64, to : U64, text : Str, side : [Left, Right, Over] }
	Event : [Message(Message), Note(Note), Activate(U64), Deactivate(U64), StartBlock({ kind : Str, text : Str }), Branch({ kind : Str, text : Str }), EndBlock]
	Diagram : { participants : List(Participant), events : List(Event), autonumber : Bool, title : Str }

	Problem : [
		NotAFlowchart,
		Syntax({ near : Str }),
		Unsupported(Str),
		InvalidTheme(Str),
		TooManyEdges,
		MissingLinkStyleEdge(Str),
		UnnamedGroup,
	]

	## Read a conversation, preserving participant and event source order.
	## Independent syntax and activation problems are returned together.
	parse : Str -> Try(Diagram, List(Problem))
	parse = SequenceParse.parse

	## Read and draw a conversation. A theme can override individual record
	## properties, for example `Theme.Options.{ font_size: 16 }`.
	draw : Str, Theme.Options -> Try(Drawing.Picture, List(Problem))
	draw = |source, theme| {
		problems = Theme.validate(theme)
		match Sequence.parse(source) {
			Err(found) => Err(problems.concat(found))
			Ok(diagram) => if problems.is_empty() {
				Ok(SequenceDraw.draw(diagram, theme))
			} else {
				Err(problems)
			}
		}
	}

}

expect
	match Sequence.parse("sequenceDiagram\nactor A as Reader\nparticipant B as API\nA->>B: Request\nB-->>A: Response\n") {
		Ok(d) => d.participants.len() == 2 and d.events.len() == 2 and (d.participants.get(0) ?? { id: "", label: "", actor: False }).actor
		Err(_) => False
	}

expect
	match Sequence.draw("sequenceDiagram\nA->>A: Retry a long operation with several words\n", Theme.Options.{}) {
		Ok(p) => Drawing.is_finite(p) and p == (Sequence.draw("sequenceDiagram\nA->>A: Retry a long operation with several words\n", Theme.Options.{}) ?? p)
		Err(_) => False
	}

expect
	match Sequence.draw("sequenceDiagram\n", Theme.Options.{}) {
		Ok(p) => p.items.is_empty() and Drawing.is_finite(p)
		Err(_) => False
	}

expect
	match Sequence.draw("sequenceDiagram\nnot a statement\n", Theme.Options.{ font_size: 0, padding: -1 }) {
		Err(problems) => problems.len() == 3
		Ok(_) => False
	}

expect
	match Sequence.draw("sequenceDiagram\nA->>B: message\n", Theme.Options.{ shadow: Shadow({ dx: -30, dy: 40, opacity: 0.2 }) }) {
		Err(_) => False
		Ok(p) => Drawing.is_finite(p) and p.view.x == -30 - 0.75
	}

expect
	match Sequence.draw("sequenceDiagram\nA->>B: message\n", Theme.Options.{ font_size: F64.nan, padding: -1, line_width: F64.infinity }) {
		Err(problems) => problems.len() == 3
		Ok(_) => False
	}
