import Bytes

## A port of the flowchart lexer as the pinned Mermaid release compiled it
## from `flow.jison`; `tools/mermaid-oracle/lexer_table.mjs` prints that
## compiled table, which differs from the grammar file where jison rewrote a
## lookahead it could not translate. Jison tries rules
## in source order and takes the first that matches (not the longest), and
## each rule applies only in its declared states, so rules here keep that
## order and those states exactly. Jison also appends `\b` to every rule
## whose pattern ends in a word character, so keywords such as `class`,
## `graph` and `v` need a word boundary after them. Several of Mermaid's
## surprising behaviours follow from these rules: `end` swallows the
## whitespace after it, and a line containing `direction TB` anywhere
## becomes a single direction token from the current position.
##
## Rules that enter features this package does not interpret yet stop the
## scan with `Unsupported`, instead of guessing at the rest of the input.
FlowLexer :: {}.{

	Kind : [
		Graph,
		NoDir,
		Dir,
		Subgraph,
		End,
		Style,
		Default,
		LinkStyle,
		Interpolate,
		ClassDef,
		Class,
		Href,
		LinkTarget,
		DirectionTb,
		DirectionBt,
		DirectionRl,
		DirectionLr,
		DirectionTd,
		LinkId,
		Num,
		Brkt,
		StyleSeparator,
		Colon,
		Amp,
		Semi,
		Comma,
		Mult,
		Link,
		StartLink,
		EdgeText,
		EllipseStart,
		EllipseEnd,
		StadiumStart,
		StadiumEnd,
		SubroutineStart,
		SubroutineEnd,
		PropsStart,
		TagStart,
		TagEnd,
		CylinderStart,
		CylinderEnd,
		DoubleCircleStart,
		DoubleCircleEnd,
		TrapStart,
		TrapEnd,
		InvTrapStart,
		InvTrapEnd,
		Up,
		Down,
		Sep,
		NodeString,
		Minus,
		UnicodeText,
		Pipe,
		Ps,
		Pe,
		Sqs,
		Sqe,
		DiamondStart,
		DiamondStop,
		Text,
		Str,
		Newline,
		Space,
		Eof,
	]

	## A token is a byte range of the prepared source. A `Str` token's range
	## is the text between its quotes.
	Token : { kind : Kind, start : U64, len : U64 }

	State : [Initial, Dir, String, Text, TrapText, EllipseText, EdgeText, ThickEdgeText, DottedEdgeText]

	Outcome : [
		Tokens(List(Token)),

		## No rule matched at this byte offset.
		NoRule(U64),

		## A rule for a feature this package does not interpret yet matched at
		## this byte offset.
		Unsupported({ feature : Str, at : U64 }),
	]

	Action : [Stay, Push(State), Pop, GraphKeyword]

	Step : [
		Emit({ kind : Kind, len : U64, action : Action }),
		Silent({ len : U64, action : Action }),
		Stop(Str),
		NoMatch,
	]

	## The last position in the current line from which each `direction XX`
	## rule matches, and where that match ends. Lines are scanned once.
	DirectionCache : { from : U64, line_end : U64, found : List({ kind : Kind, start : U64, end : U64 }) }

	tokenize : List(U8) -> Outcome
	tokenize = |bytes| {
		len = bytes.len()
		var $tokens = List.with_capacity(len / 2 + 1)
		var $stack = [Initial]
		var $pos = 0
		var $first_graph = True
		var $cache = { from: 0, line_end: 0, found: [] }
		var $done = False
		var $outcome = NoRule(0)

		while !$done {
			if $pos >= len {
				$tokens = $tokens.append({ kind: Eof, start: len, len: 0 })
				$outcome = Tokens($tokens)
				$done = True
			} else {
				state = $stack.last() ?? Initial
				if state == Initial and !($cache.from <= $pos and $pos < $cache.line_end) {
					$cache = FlowLexer.direction_cache(bytes, $pos)
				}
				step = FlowLexer.step(bytes, $pos, state, $cache)
				match step {
					Emit({ kind, len: token_len, action }) => {
						$tokens = $tokens.append({ kind, start: $pos, len: token_len })
						$stack = FlowLexer.apply(action, $stack, $first_graph)
						if action == GraphKeyword {
							$first_graph = False
						}
						$pos = $pos + token_len
					}
					Silent({ len: skip, action }) => {
						$stack = FlowLexer.apply(action, $stack, $first_graph)
						$pos = $pos + skip
					}
					Stop(feature) => {
						$outcome = Unsupported({ feature, at: $pos })
						$done = True
					}
					NoMatch => {
						$outcome = NoRule($pos)
						$done = True
					}
				}
			}
		}

		$outcome
	}

	## Jison's `popState` never removes the initial state.
	apply : Action, List(State), Bool -> List(State)
	apply = |action, stack, first_graph|
		match action {
			Stay => stack
			Push(state) => stack.append(state)
			Pop => if (stack.len() > 1) stack.drop_last(1) else stack
			GraphKeyword => if (first_graph) stack.append(Dir) else stack
		}

	## Content of a `Str` token is between quotes; the opening quote is a
	## separate silent step, so string tokens carry only the content.
	step : List(U8), U64, State, DirectionCache -> Step
	step = |bytes, pos, state, cache| {
		initial = state == Initial
		b = Bytes.at(bytes, pos)
		next = Bytes.at(bytes, pos + 1)
		has_next = pos + 1 < bytes.len()

		# Accessibility statements, shape data and callbacks (INITIAL only).
		if initial and FlowLexer.keyword_then_colon_or_brace(bytes, pos, FlowLexer.acc_title_word, [':']) {
			return Stop("accessibility title")
		}
		if initial and FlowLexer.keyword_then_colon_or_brace(bytes, pos, FlowLexer.acc_descr_word, [':', '{']) {
			return Stop("accessibility description")
		}
		if initial and b == '@' and next == '{' and has_next {
			return Stop("shape data")
		}
		if initial and FlowLexer.word_then_space(bytes, pos, FlowLexer.call_word) > 0 {
			return Stop("click callback")
		}

		# Strings, in every state. Markdown strings are not interpreted yet.
		if b == '"' and next == '`' and has_next {
			return Stop("markdown string")
		}
		if state == String {
			if b == '"' {
				return Silent({ len: 1, action: Pop })
			}
			end = Bytes.find_byte(bytes, pos, '"')
			return Emit({ kind: Str, len: end - pos, action: Stay })
		}
		if b == '"' {
			return Silent({ len: 1, action: Push(String) })
		}

		if initial {
			match FlowLexer.keyword(bytes, pos) {
				Some(found) => return Emit({ kind: found.kind, len: found.len, action: Stay })
				None => {}
			}
			href = FlowLexer.prefix_then_one_space(bytes, pos, FlowLexer.href_word)
			if href > 0 {
				return Emit({ kind: Href, len: href, action: Stay })
			}
			if FlowLexer.word_then_space(bytes, pos, FlowLexer.click_word) > 0 {
				return Stop("click")
			}
			graph_len = FlowLexer.graph_keyword(bytes, pos)
			if graph_len > 0 {
				return Emit({ kind: Graph, len: graph_len, action: GraphKeyword })
			}
			if FlowLexer.word_at(bytes, pos, FlowLexer.subgraph_word) {
				return Emit({ kind: Subgraph, len: 8, action: Stay })
			}
			end_len = FlowLexer.end_keyword(bytes, pos)
			if end_len > 0 {
				return Emit({ kind: End, len: end_len, action: Stay })
			}
			target = FlowLexer.link_target(bytes, pos)
			if target > 0 {
				return Emit({ kind: LinkTarget, len: target, action: Stay })
			}
		}

		if state == Dir {
			match Bytes.last_newline_in_space_run(bytes, pos) {
				Some(at) => return Emit({ kind: NoDir, len: at + 1 - pos, action: Pop })
				None => {}
			}
			after = Bytes.skip_space(bytes, pos)
			dir_len = FlowLexer.direction_word(bytes, after)
			if dir_len > 0 {
				return Emit({ kind: Dir, len: after + dir_len - pos, action: Pop })
			}
		}

		if initial {
			match FlowLexer.direction_statement(cache, pos) {
				Some(found) => return Emit({ kind: found.kind, len: found.end - pos, action: Stay })
				None => {}
			}
			link_id = FlowLexer.link_id(bytes, pos)
			if link_id > 0 {
				return Emit({ kind: LinkId, len: link_id, action: Stay })
			}
			if Bytes.is_digit(b) {
				var $j = pos
				while Bytes.is_digit(Bytes.at(bytes, $j)) and $j < bytes.len() {
					$j = $j + 1
				}
				return Emit({ kind: Num, len: $j - pos, action: Stay })
			}
			if b == '#' {
				return Emit({ kind: Brkt, len: 1, action: Stay })
			}
			if Bytes.triple_at(bytes, pos, ':', ':', ':') {
				return Emit({ kind: StyleSeparator, len: 3, action: Stay })
			}
			punctuation = match b {
				':' => Some(Colon)
				'&' => Some(Amp)
				';' => Some(Semi)
				',' => Some(Comma)
				'*' => Some(Mult)
				_ => None
			}
			match punctuation {
				Some(kind) => return Emit({ kind, len: 1, action: Stay })
				None => {}
			}
		}

		# Links. Each family's closing rule is shared with its edge-text state.
		if initial or state == EdgeText {
			found = FlowLexer.repeated_link(bytes, pos, '-')
			if found > 0 {
				return Emit({ kind: Link, len: found, action: Pop })
			}
		}
		if initial {
			found = FlowLexer.start_link(bytes, pos, '-', '-')
			if found > 0 {
				return Emit({ kind: StartLink, len: found, action: Push(EdgeText) })
			}
		}
		if state == EdgeText and (b != '-' or Bytes.at(bytes, pos + 1) != '-' or pos + 1 >= bytes.len()) {
			return Emit({ kind: EdgeText, len: FlowLexer.edge_text_len(bytes, pos, b), action: Stay })
		}
		if initial or state == ThickEdgeText {
			found = FlowLexer.repeated_link(bytes, pos, '=')
			if found > 0 {
				return Emit({ kind: Link, len: found, action: Pop })
			}
		}
		if initial {
			found = FlowLexer.start_link(bytes, pos, '=', '=')
			if found > 0 {
				return Emit({ kind: StartLink, len: found, action: Push(ThickEdgeText) })
			}
		}
		# Compiled as `[^=]|=(?!)`: the second branch never matches.
		if state == ThickEdgeText and b != '=' {
			return Emit({ kind: EdgeText, len: FlowLexer.edge_text_len(bytes, pos, b), action: Stay })
		}
		if initial or state == DottedEdgeText {
			found = FlowLexer.dotted_link(bytes, pos)
			if found > 0 {
				return Emit({ kind: Link, len: found, action: Pop })
			}
		}
		if initial {
			found = FlowLexer.start_link(bytes, pos, '-', '.')
			if found > 0 {
				return Emit({ kind: StartLink, len: found, action: Push(DottedEdgeText) })
			}
		}
		# Compiled as `[^\.]|\.(?!)`: the second branch never matches.
		if state == DottedEdgeText and b != '.' {
			return Emit({ kind: EdgeText, len: FlowLexer.edge_text_len(bytes, pos, b), action: Stay })
		}
		invisible = FlowLexer.invisible_link(bytes, pos)
		if invisible > 0 {
			return Emit({ kind: Link, len: invisible, action: Stay })
		}

		# Shapes.
		if state == EllipseText {
			if (b == '-' or b == '/' or b == ')') and next == ')' and has_next {
				return Emit({ kind: EllipseEnd, len: 2, action: Pop })
			}
			if !FlowLexer.is_bracket(b) {
				return Emit({ kind: Text, len: Bytes.char_len(b), action: Stay })
			}
		}
		pair = |x, y| b == x and next == y and has_next
		if pair('(', '-') {
			return Emit({ kind: EllipseStart, len: 2, action: Push(EllipseText) })
		}
		if state == Text and pair(']', ')') {
			return Emit({ kind: StadiumEnd, len: 2, action: Pop })
		}
		if pair('(', '[') {
			return Emit({ kind: StadiumStart, len: 2, action: Push(Text) })
		}
		if state == Text and pair(']', ']') {
			return Emit({ kind: SubroutineEnd, len: 2, action: Pop })
		}
		if pair('[', '[') {
			return Emit({ kind: SubroutineStart, len: 2, action: Push(Text) })
		}
		if initial and pair('[', '|') {
			return Emit({ kind: PropsStart, len: 2, action: Stay })
		}
		if initial and b == '>' {
			return Emit({ kind: TagEnd, len: 1, action: Push(Text) })
		}
		if state == Text and pair(')', ']') {
			return Emit({ kind: CylinderEnd, len: 2, action: Pop })
		}
		if pair('[', '(') {
			return Emit({ kind: CylinderStart, len: 2, action: Push(Text) })
		}
		if state == Text and Bytes.triple_at(bytes, pos, ')', ')', ')') {
			return Emit({ kind: DoubleCircleEnd, len: 3, action: Pop })
		}
		if Bytes.triple_at(bytes, pos, '(', '(', '(') {
			return Emit({ kind: DoubleCircleStart, len: 3, action: Push(Text) })
		}
		if state == TrapText {
			# `[\\(?=\])][\]]`: one of `\ ( ? = ] )` and then `]`.
			if (b == '\\' or b == '(' or b == '?' or b == '=' or b == ']' or b == ')') and next == ']' and has_next {
				return Emit({ kind: TrapEnd, len: 2, action: Pop })
			}
			if b == '/' and next == ']' and has_next {
				return Emit({ kind: InvTrapEnd, len: 2, action: Pop })
			}
			if (b == '/' or b == '\\') and !(next == ']' and has_next) {
				return Emit({ kind: Text, len: 1, action: Stay })
			}
			run = FlowLexer.trap_text_len(bytes, pos)
			if run > 0 {
				return Emit({ kind: Text, len: run, action: Stay })
			}
		}
		if pair('[', '/') {
			return Emit({ kind: TrapStart, len: 2, action: Push(TrapText) })
		}
		if pair('[', '\\') {
			return Emit({ kind: InvTrapStart, len: 2, action: Push(TrapText) })
		}

		if initial {
			single = match b {
				'<' => Some(TagStart)
				'^' => Some(Up)
				'v' if !(has_next and Bytes.is_word(next)) => Some(Down)
				'*' => Some(Mult)
				'#' => Some(Brkt)
				'&' => Some(Amp)
				_ => None
			}
			match single {
				Some(kind) => return Emit({ kind, len: 1, action: Stay })
				None => {}
			}
			if b == '\\' and next == '|' and has_next {
				return Emit({ kind: Sep, len: 2, action: Stay })
			}
			node_string = FlowLexer.node_string_len(bytes, pos)
			if node_string > 0 {
				return Emit({ kind: NodeString, len: node_string, action: Stay })
			}
			if b == '-' {
				return Emit({ kind: Minus, len: 1, action: Stay })
			}
			if b >= 0x80 and FlowLexer.is_unicode_text(Bytes.code_point(bytes, pos)) {
				return Emit({ kind: UnicodeText, len: Bytes.char_len(b), action: Stay })
			}
		}

		bracket = match b {
			'|' => Some({ open: Pipe, close: Pipe })
			'(' => Some({ open: Ps, close: Pe })
			')' => Some({ open: Pe, close: Pe })
			'[' => Some({ open: Sqs, close: Sqe })
			']' => Some({ open: Sqe, close: Sqe })
			'{' => Some({ open: DiamondStart, close: DiamondStop })
			'}' => Some({ open: DiamondStop, close: DiamondStop })
			_ => None
		}
		match bracket {
			Some(kinds) => {
				closes = b == '|' or b == ')' or b == ']' or b == '}'
				opens = b == '|' or b == '(' or b == '[' or b == '{'
				if state == Text and closes {
					return Emit({ kind: kinds.close, len: 1, action: Pop })
				}
				if opens {
					return Emit({ kind: kinds.open, len: 1, action: Push(Text) })
				}
			}
			None => {}
		}
		if state == Text {
			run = FlowLexer.text_len(bytes, pos)
			if run > 0 {
				return Emit({ kind: Text, len: run, action: Stay })
			}
		}

		if initial {
			if b == '\n' {
				var $j = pos
				while Bytes.at(bytes, $j) == '\n' and $j < bytes.len() {
					$j = $j + 1
				}
				return Emit({ kind: Newline, len: $j - pos, action: Stay })
			}
			space = FlowLexer.inline_space_len(bytes, pos)
			if space > 0 {
				return Emit({ kind: Space, len: space, action: Stay })
			}
		}

		NoMatch
	}

	## A literal rule as jison compiles it: `\b` is appended when the
	## literal ends in a word character.
	word_at : List(U8), U64, List(U8) -> Bool
	word_at = |bytes, pos, word| {
		end = pos + word.len()
		Bytes.starts_with_at(bytes, pos, word) and !(Bytes.is_word(Bytes.at(word, word.len() - 1)) and end < bytes.len() and Bytes.is_word(Bytes.at(bytes, end)))
	}

	# Rule literals as bytes, built once rather than at every step.
	acc_title_word : List(U8)
	acc_title_word = "accTitle".to_utf8()

	acc_descr_word : List(U8)
	acc_descr_word = "accDescr".to_utf8()

	call_word : List(U8)
	call_word = "call".to_utf8()

	click_word : List(U8)
	click_word = "click".to_utf8()

	href_word : List(U8)
	href_word = "href".to_utf8()

	subgraph_word : List(U8)
	subgraph_word = "subgraph".to_utf8()

	direction_word_bytes : List(U8)
	direction_word_bytes = "direction".to_utf8()

	direction_statement_order : List(Kind)
	direction_statement_order = [DirectionTb, DirectionBt, DirectionRl, DirectionLr, DirectionTd]

	keywords : List({ word : List(U8), kind : Kind })
	keywords = [
		{ word: "style".to_utf8(), kind: Style },
		{ word: "default".to_utf8(), kind: Default },
		{ word: "linkStyle".to_utf8(), kind: LinkStyle },
		{ word: "interpolate".to_utf8(), kind: Interpolate },
		{ word: "classDef".to_utf8(), kind: ClassDef },
		{ word: "class".to_utf8(), kind: Class },
	]

	graph_words : List(List(U8))
	graph_words = ["flowchart-elk".to_utf8(), "swimlane-beta".to_utf8(), "graph".to_utf8(), "flowchart".to_utf8()]

	link_target_words : List(List(U8))
	link_target_words = ["_self".to_utf8(), "_blank".to_utf8(), "_parent".to_utf8(), "_top".to_utf8()]

	header_direction_words : List(List(U8))
	header_direction_words = ["LR".to_utf8(), "RL".to_utf8(), "TB".to_utf8(), "BT".to_utf8(), "TD".to_utf8(), "BR".to_utf8(), "<".to_utf8(), ">".to_utf8(), "^".to_utf8(), "v".to_utf8()]

	## `accTitle\s*":"` and `accDescr\s*":"` / `accDescr\s*"{"`.
	keyword_then_colon_or_brace : List(U8), U64, List(U8), List(U8) -> Bool
	keyword_then_colon_or_brace = |bytes, pos, word, follow| {
		if Bytes.starts_with_at(bytes, pos, word) {
			after = Bytes.skip_space(bytes, pos + word.len())
			after < bytes.len() and follow.contains(Bytes.at(bytes, after))
		} else {
			False
		}
	}

	## `word[\s]+`: the match length, or `0`.
	word_then_space : List(U8), U64, List(U8) -> U64
	word_then_space = |bytes, pos, word| {
		if Bytes.starts_with_at(bytes, pos, word) and Bytes.space_len(bytes, pos + word.len()) > 0 {
			Bytes.skip_space(bytes, pos + word.len()) - pos
		} else {
			0
		}
	}

	## `word[\s]`: exactly one whitespace character after the word.
	prefix_then_one_space : List(U8), U64, List(U8) -> U64
	prefix_then_one_space = |bytes, pos, word| {
		if Bytes.starts_with_at(bytes, pos, word) {
			space = Bytes.space_len(bytes, pos + word.len())
			if (space > 0) word.len() + space else 0
		} else {
			0
		}
	}

	## Keywords in their rule order, each needing a word boundary after it.
	keyword : List(U8), U64 -> [Some({ kind : Kind, len : U64 }), None]
	keyword = |bytes, pos|
		FlowLexer.keywords.fold_until(
			None,
			|_, candidate|
				if FlowLexer.word_at(bytes, pos, candidate.word) {
					Break(Some({ kind: candidate.kind, len: candidate.word.len() }))
				} else {
					Continue(None)
				},
		)

	## The length of the first word in `words` that matches at `pos`, or `0`.
	first_word : List(U8), U64, List(List(U8)) -> U64
	first_word = |bytes, pos, words|
		words.fold_until(0, |_, word| if (FlowLexer.word_at(bytes, pos, word)) Break(word.len()) else Continue(0))

	graph_keyword : List(U8), U64 -> U64
	graph_keyword = |bytes, pos| FlowLexer.first_word(bytes, pos, FlowLexer.graph_words)

	## `"end"\b\s*`.
	end_keyword : List(U8), U64 -> U64
	end_keyword = |bytes, pos| {
		if Bytes.at(bytes, pos) == 'e' and Bytes.at(bytes, pos + 1) == 'n' and Bytes.at(bytes, pos + 2) == 'd' and pos + 2 < bytes.len() and !(pos + 3 < bytes.len() and Bytes.is_word(Bytes.at(bytes, pos + 3))) {
			Bytes.skip_space(bytes, pos + 3) - pos
		} else {
			0
		}
	}

	link_target : List(U8), U64 -> U64
	link_target = |bytes, pos| FlowLexer.first_word(bytes, pos, FlowLexer.link_target_words)

	## The direction words of the header, in rule order.
	direction_word : List(U8), U64 -> U64
	direction_word = |bytes, pos| FlowLexer.first_word(bytes, pos, FlowLexer.header_direction_words)

	## Scan the line from `pos` for every `direction\s+XX`, keeping for each
	## kind its last start. `.*` cannot cross a line terminator, but the
	## `\s+` after `direction` can, and the token then runs to the next `\n`.
	direction_cache : List(U8), U64 -> DirectionCache
	direction_cache = |bytes, pos| {
		line_end = Bytes.line_terminator_from(bytes, pos)
		word = FlowLexer.direction_word_bytes
		var $found = []
		var $s = pos
		while $s + word.len() <= line_end {
			if Bytes.starts_with_at(bytes, $s, word) and Bytes.space_len(bytes, $s + word.len()) > 0 {
				after = Bytes.skip_space(bytes, $s + word.len())
				kind = FlowLexer.direction_statement_kind(bytes, after)
				match kind {
					Some(k) => {
						end = Bytes.find_byte(bytes, after + 2, '\n')
						$found = $found.keep_if(|f| f.kind != k).append({ kind: k, start: $s, end })
					}
					None => {}
				}
			}
			$s = $s + 1
		}
		{ from: pos, line_end: if (line_end == pos) pos + 1 else line_end, found: $found }
	}

	direction_statement_kind : List(U8), U64 -> [Some(Kind), None]
	direction_statement_kind = |bytes, pos| {
		if Bytes.pair_at(bytes, pos, 'T', 'B') {
			Some(DirectionTb)
		} else if Bytes.pair_at(bytes, pos, 'B', 'T') {
			Some(DirectionBt)
		} else if Bytes.pair_at(bytes, pos, 'R', 'L') {
			Some(DirectionRl)
		} else if Bytes.pair_at(bytes, pos, 'L', 'R') {
			Some(DirectionLr)
		} else if Bytes.pair_at(bytes, pos, 'T', 'D') {
			Some(DirectionTd)
		} else {
			None
		}
	}

	## The first direction rule, in rule order, that matches from `pos`.
	direction_statement : DirectionCache, U64 -> [Some({ kind : Kind, end : U64 }), None]
	direction_statement = |cache, pos|
		FlowLexer.direction_statement_order.fold_until(
			None,
			|_, kind|
				match cache.found.find_first(|f| f.kind == kind and f.start >= pos) {
					Ok(f) => Break(Some({ kind, end: f.end }))
					Err(_) => Continue(None)
				},
		)

	## `[^\s\"]+\@(?=[^\{\"])`: greedy, so the last qualifying `@` in the run.
	link_id : List(U8), U64 -> U64
	link_id = |bytes, pos| {
		var $run_end = pos
		while $run_end < bytes.len() and Bytes.space_len(bytes, $run_end) == 0 and Bytes.at(bytes, $run_end) != '"' {
			$run_end = $run_end + 1
		}
		var $k = $run_end
		var $found = 0
		while $found == 0 and $k > pos + 1 {
			$k = $k - 1
			after = Bytes.at(bytes, $k + 1)
			if Bytes.at(bytes, $k) == '@' and $k + 1 < bytes.len() and after != '{' and after != '"' {
				$found = $k + 1 - pos
			}
		}
		$found
	}

	## `\s*[xo<]?CC+[Cxo>]\s*` for `C` in `-` and `=`.
	repeated_link : List(U8), U64, U8 -> U64
	repeated_link = |bytes, pos, c| {
		j = Bytes.skip_space(bytes, pos)
		k = if (FlowLexer.is_arrow_start(Bytes.at(bytes, j)) and j < bytes.len()) j + 1 else j
		var $run = 0
		while Bytes.at(bytes, k + $run) == c and k + $run < bytes.len() {
			$run = $run + 1
		}
		after = Bytes.at(bytes, k + $run)
		has_after = k + $run < bytes.len()
		end = if $run >= 2 and has_after and (after == 'x' or after == 'o' or after == '>') {
			k + $run + 1
		} else if $run >= 3 {
			k + $run
		} else {
			0
		}
		if (end == 0) 0 else Bytes.skip_space(bytes, end) - pos
	}

	## `\s*[xo<]?AB\s*`, the opening half of a link with text.
	start_link : List(U8), U64, U8, U8 -> U64
	start_link = |bytes, pos, a, b| {
		j = Bytes.skip_space(bytes, pos)
		k = if (FlowLexer.is_arrow_start(Bytes.at(bytes, j)) and j < bytes.len()) j + 1 else j
		if Bytes.at(bytes, k) == a and Bytes.at(bytes, k + 1) == b and k + 1 < bytes.len() {
			Bytes.skip_space(bytes, k + 2) - pos
		} else {
			0
		}
	}

	## `\s*[xo<]?\-?\.+\-[xo>]?\s*`.
	dotted_link : List(U8), U64 -> U64
	dotted_link = |bytes, pos| {
		j = Bytes.skip_space(bytes, pos)
		k0 = if (FlowLexer.is_arrow_start(Bytes.at(bytes, j)) and j < bytes.len()) j + 1 else j
		k = if (Bytes.at(bytes, k0) == '-' and k0 < bytes.len()) k0 + 1 else k0
		var $dots = 0
		while Bytes.at(bytes, k + $dots) == '.' and k + $dots < bytes.len() {
			$dots = $dots + 1
		}
		dash = k + $dots
		if $dots >= 1 and Bytes.at(bytes, dash) == '-' and dash < bytes.len() {
			tip = Bytes.at(bytes, dash + 1)
			end = if (dash + 1 < bytes.len() and (tip == 'x' or tip == 'o' or tip == '>')) dash + 2 else dash + 1
			Bytes.skip_space(bytes, end) - pos
		} else {
			0
		}
	}

	## `\s*\~\~[\~]+\s*`.
	invisible_link : List(U8), U64 -> U64
	invisible_link = |bytes, pos| {
		j = Bytes.skip_space(bytes, pos)
		var $run = 0
		while Bytes.at(bytes, j + $run) == '~' and j + $run < bytes.len() {
			$run = $run + 1
		}
		if ($run >= 3) Bytes.skip_space(bytes, j + $run) - pos else 0
	}

	is_arrow_start : U8 -> Bool
	is_arrow_start = |b| b == 'x' or b == 'o' or b == '<'

	## Edge text advances one character at a time.
	edge_text_len : List(U8), U64, U8 -> U64
	edge_text_len = |_bytes, _pos, b| Bytes.char_len(b)

	is_bracket : U8 -> Bool
	is_bracket = |b| b == '(' or b == ')' or b == '[' or b == ']' or b == '{' or b == '}'

	## `[^\\\[\]\(\)\{\}\/]+`.
	trap_text_len : List(U8), U64 -> U64
	trap_text_len = |bytes, pos| {
		var $j = pos
		while $j < bytes.len() and !FlowLexer.ends_trap_text(Bytes.at(bytes, $j)) {
			$j = $j + 1
		}
		$j - pos
	}

	ends_trap_text : U8 -> Bool
	ends_trap_text = |b| b == '\\' or b == '/' or FlowLexer.is_bracket(b)

	## `[^\[\]\(\)\{\}\|\"]+`.
	text_len : List(U8), U64 -> U64
	text_len = |bytes, pos| {
		var $j = pos
		while $j < bytes.len() and !FlowLexer.ends_text(Bytes.at(bytes, $j)) {
			$j = $j + 1
		}
		$j - pos
	}

	ends_text : U8 -> Bool
	ends_text = |b| b == '|' or b == '"' or FlowLexer.is_bracket(b)

	## `[^\S\n\r]+`.
	inline_space_len : List(U8), U64 -> U64
	inline_space_len = |bytes, pos| {
		var $j = pos
		var $step = Bytes.space_len(bytes, $j)
		while $step > 0 and Bytes.at(bytes, $j) != '\n' and Bytes.at(bytes, $j) != '\r' {
			$j = $j + $step
			$step = Bytes.space_len(bytes, $j)
		}
		$j - pos
	}

	## The grammar file says `([A-Za-z0-9!"\#$%&'*+\.`?\\_\/]|\-(?=[^\>\-\.])|=(?!=))+`,
	## but jison compiles the last branch to `(?!)`, which never matches, so
	## `=` is not part of an id.
	node_string_len : List(U8), U64 -> U64
	node_string_len = |bytes, pos| {
		len = bytes.len()
		var $j = pos
		var $going = True
		while $going and $j < len {
			c = Bytes.at(bytes, $j)
			after = Bytes.at(bytes, $j + 1)
			has_after = $j + 1 < len
			accepted = if FlowLexer.is_node_char(c) {
				True
			} else if c == '-' {
				has_after and after != '>' and after != '-' and after != '.'
			} else {
				False
			}
			if accepted {
				$j = $j + 1
			} else {
				$going = False
			}
		}
		$j - pos
	}

	is_node_char : U8 -> Bool
	is_node_char = |c|
		(c >= 'A' and c <= 'Z')
			or (c >= 'a' and c <= 'z')
			or (c >= '0' and c <= '9')
			or c == '!'
			or c == '"'
			or c == '#'
			or c == '$'
			or c == '%'
			or c == '&'
			or c == '\''
			or c == '*'
			or c == '+'
			or c == '.'
			or c == '`'
			or c == '?'
			or c == '\\'
			or c == '_'
			or c == '/'

	## Binary search of the ranges the jison `UNICODE_TEXT` rule accepts.
	is_unicode_text : U32 -> Bool
	is_unicode_text = |cp| {
		ranges = FlowLexer.unicode_text_ranges
		var $lo = 0
		var $hi = ranges.len()
		var $found = False
		while !$found and $lo < $hi {
			mid = ($lo + $hi) / 2
			range = ranges.get(mid) ?? { lo: 0, hi: 0 }
			if cp < range.lo {
				$hi = mid
			} else if cp > range.hi {
				$lo = mid + 1
			} else {
				$found = True
			}
		}
		$found
	}

	unicode_text_ranges : List({ lo : U32, hi : U32 })
	unicode_text_ranges = [
		{ lo: 0x00AA, hi: 0x00AA },
		{ lo: 0x00B5, hi: 0x00B5 },
		{ lo: 0x00BA, hi: 0x00BA },
		{ lo: 0x00C0, hi: 0x00D6 },
		{ lo: 0x00D8, hi: 0x00F6 },
		{ lo: 0x00F8, hi: 0x02C1 },
		{ lo: 0x02C6, hi: 0x02D1 },
		{ lo: 0x02E0, hi: 0x02E4 },
		{ lo: 0x02EC, hi: 0x02EC },
		{ lo: 0x02EE, hi: 0x02EE },
		{ lo: 0x0370, hi: 0x0374 },
		{ lo: 0x0376, hi: 0x0376 },
		{ lo: 0x0377, hi: 0x0377 },
		{ lo: 0x037A, hi: 0x037D },
		{ lo: 0x0386, hi: 0x0386 },
		{ lo: 0x0388, hi: 0x038A },
		{ lo: 0x038C, hi: 0x038C },
		{ lo: 0x038E, hi: 0x03A1 },
		{ lo: 0x03A3, hi: 0x03F5 },
		{ lo: 0x03F7, hi: 0x0481 },
		{ lo: 0x048A, hi: 0x0527 },
		{ lo: 0x0531, hi: 0x0556 },
		{ lo: 0x0559, hi: 0x0559 },
		{ lo: 0x0561, hi: 0x0587 },
		{ lo: 0x05D0, hi: 0x05EA },
		{ lo: 0x05F0, hi: 0x05F2 },
		{ lo: 0x0620, hi: 0x064A },
		{ lo: 0x066E, hi: 0x066E },
		{ lo: 0x066F, hi: 0x066F },
		{ lo: 0x0671, hi: 0x06D3 },
		{ lo: 0x06D5, hi: 0x06D5 },
		{ lo: 0x06E5, hi: 0x06E5 },
		{ lo: 0x06E6, hi: 0x06E6 },
		{ lo: 0x06EE, hi: 0x06EE },
		{ lo: 0x06EF, hi: 0x06EF },
		{ lo: 0x06FA, hi: 0x06FC },
		{ lo: 0x06FF, hi: 0x06FF },
		{ lo: 0x0710, hi: 0x0710 },
		{ lo: 0x0712, hi: 0x072F },
		{ lo: 0x074D, hi: 0x07A5 },
		{ lo: 0x07B1, hi: 0x07B1 },
		{ lo: 0x07CA, hi: 0x07EA },
		{ lo: 0x07F4, hi: 0x07F4 },
		{ lo: 0x07F5, hi: 0x07F5 },
		{ lo: 0x07FA, hi: 0x07FA },
		{ lo: 0x0800, hi: 0x0815 },
		{ lo: 0x081A, hi: 0x081A },
		{ lo: 0x0824, hi: 0x0824 },
		{ lo: 0x0828, hi: 0x0828 },
		{ lo: 0x0840, hi: 0x0858 },
		{ lo: 0x08A0, hi: 0x08A0 },
		{ lo: 0x08A2, hi: 0x08AC },
		{ lo: 0x0904, hi: 0x0939 },
		{ lo: 0x093D, hi: 0x093D },
		{ lo: 0x0950, hi: 0x0950 },
		{ lo: 0x0958, hi: 0x0961 },
		{ lo: 0x0971, hi: 0x0977 },
		{ lo: 0x0979, hi: 0x097F },
		{ lo: 0x0985, hi: 0x098C },
		{ lo: 0x098F, hi: 0x098F },
		{ lo: 0x0990, hi: 0x0990 },
		{ lo: 0x0993, hi: 0x09A8 },
		{ lo: 0x09AA, hi: 0x09B0 },
		{ lo: 0x09B2, hi: 0x09B2 },
		{ lo: 0x09B6, hi: 0x09B9 },
		{ lo: 0x09BD, hi: 0x09BD },
		{ lo: 0x09CE, hi: 0x09CE },
		{ lo: 0x09DC, hi: 0x09DC },
		{ lo: 0x09DD, hi: 0x09DD },
		{ lo: 0x09DF, hi: 0x09E1 },
		{ lo: 0x09F0, hi: 0x09F0 },
		{ lo: 0x09F1, hi: 0x09F1 },
		{ lo: 0x0A05, hi: 0x0A0A },
		{ lo: 0x0A0F, hi: 0x0A0F },
		{ lo: 0x0A10, hi: 0x0A10 },
		{ lo: 0x0A13, hi: 0x0A28 },
		{ lo: 0x0A2A, hi: 0x0A30 },
		{ lo: 0x0A32, hi: 0x0A32 },
		{ lo: 0x0A33, hi: 0x0A33 },
		{ lo: 0x0A35, hi: 0x0A35 },
		{ lo: 0x0A36, hi: 0x0A36 },
		{ lo: 0x0A38, hi: 0x0A38 },
		{ lo: 0x0A39, hi: 0x0A39 },
		{ lo: 0x0A59, hi: 0x0A5C },
		{ lo: 0x0A5E, hi: 0x0A5E },
		{ lo: 0x0A72, hi: 0x0A74 },
		{ lo: 0x0A85, hi: 0x0A8D },
		{ lo: 0x0A8F, hi: 0x0A91 },
		{ lo: 0x0A93, hi: 0x0AA8 },
		{ lo: 0x0AAA, hi: 0x0AB0 },
		{ lo: 0x0AB2, hi: 0x0AB2 },
		{ lo: 0x0AB3, hi: 0x0AB3 },
		{ lo: 0x0AB5, hi: 0x0AB9 },
		{ lo: 0x0ABD, hi: 0x0ABD },
		{ lo: 0x0AD0, hi: 0x0AD0 },
		{ lo: 0x0AE0, hi: 0x0AE0 },
		{ lo: 0x0AE1, hi: 0x0AE1 },
		{ lo: 0x0B05, hi: 0x0B0C },
		{ lo: 0x0B0F, hi: 0x0B0F },
		{ lo: 0x0B10, hi: 0x0B10 },
		{ lo: 0x0B13, hi: 0x0B28 },
		{ lo: 0x0B2A, hi: 0x0B30 },
		{ lo: 0x0B32, hi: 0x0B32 },
		{ lo: 0x0B33, hi: 0x0B33 },
		{ lo: 0x0B35, hi: 0x0B39 },
		{ lo: 0x0B3D, hi: 0x0B3D },
		{ lo: 0x0B5C, hi: 0x0B5C },
		{ lo: 0x0B5D, hi: 0x0B5D },
		{ lo: 0x0B5F, hi: 0x0B61 },
		{ lo: 0x0B71, hi: 0x0B71 },
		{ lo: 0x0B83, hi: 0x0B83 },
		{ lo: 0x0B85, hi: 0x0B8A },
		{ lo: 0x0B8E, hi: 0x0B90 },
		{ lo: 0x0B92, hi: 0x0B95 },
		{ lo: 0x0B99, hi: 0x0B99 },
		{ lo: 0x0B9A, hi: 0x0B9A },
		{ lo: 0x0B9C, hi: 0x0B9C },
		{ lo: 0x0B9E, hi: 0x0B9E },
		{ lo: 0x0B9F, hi: 0x0B9F },
		{ lo: 0x0BA3, hi: 0x0BA3 },
		{ lo: 0x0BA4, hi: 0x0BA4 },
		{ lo: 0x0BA8, hi: 0x0BAA },
		{ lo: 0x0BAE, hi: 0x0BB9 },
		{ lo: 0x0BD0, hi: 0x0BD0 },
		{ lo: 0x0C05, hi: 0x0C0C },
		{ lo: 0x0C0E, hi: 0x0C10 },
		{ lo: 0x0C12, hi: 0x0C28 },
		{ lo: 0x0C2A, hi: 0x0C33 },
		{ lo: 0x0C35, hi: 0x0C39 },
		{ lo: 0x0C3D, hi: 0x0C3D },
		{ lo: 0x0C58, hi: 0x0C58 },
		{ lo: 0x0C59, hi: 0x0C59 },
		{ lo: 0x0C60, hi: 0x0C60 },
		{ lo: 0x0C61, hi: 0x0C61 },
		{ lo: 0x0C85, hi: 0x0C8C },
		{ lo: 0x0C8E, hi: 0x0C90 },
		{ lo: 0x0C92, hi: 0x0CA8 },
		{ lo: 0x0CAA, hi: 0x0CB3 },
		{ lo: 0x0CB5, hi: 0x0CB9 },
		{ lo: 0x0CBD, hi: 0x0CBD },
		{ lo: 0x0CDE, hi: 0x0CDE },
		{ lo: 0x0CE0, hi: 0x0CE0 },
		{ lo: 0x0CE1, hi: 0x0CE1 },
		{ lo: 0x0CF1, hi: 0x0CF1 },
		{ lo: 0x0CF2, hi: 0x0CF2 },
		{ lo: 0x0D05, hi: 0x0D0C },
		{ lo: 0x0D0E, hi: 0x0D10 },
		{ lo: 0x0D12, hi: 0x0D3A },
		{ lo: 0x0D3D, hi: 0x0D3D },
		{ lo: 0x0D4E, hi: 0x0D4E },
		{ lo: 0x0D60, hi: 0x0D60 },
		{ lo: 0x0D61, hi: 0x0D61 },
		{ lo: 0x0D7A, hi: 0x0D7F },
		{ lo: 0x0D85, hi: 0x0D96 },
		{ lo: 0x0D9A, hi: 0x0DB1 },
		{ lo: 0x0DB3, hi: 0x0DBB },
		{ lo: 0x0DBD, hi: 0x0DBD },
		{ lo: 0x0DC0, hi: 0x0DC6 },
		{ lo: 0x0E01, hi: 0x0E30 },
		{ lo: 0x0E32, hi: 0x0E32 },
		{ lo: 0x0E33, hi: 0x0E33 },
		{ lo: 0x0E40, hi: 0x0E46 },
		{ lo: 0x0E81, hi: 0x0E81 },
		{ lo: 0x0E82, hi: 0x0E82 },
		{ lo: 0x0E84, hi: 0x0E84 },
		{ lo: 0x0E87, hi: 0x0E87 },
		{ lo: 0x0E88, hi: 0x0E88 },
		{ lo: 0x0E8A, hi: 0x0E8A },
		{ lo: 0x0E8D, hi: 0x0E8D },
		{ lo: 0x0E94, hi: 0x0E97 },
		{ lo: 0x0E99, hi: 0x0E9F },
		{ lo: 0x0EA1, hi: 0x0EA3 },
		{ lo: 0x0EA5, hi: 0x0EA5 },
		{ lo: 0x0EA7, hi: 0x0EA7 },
		{ lo: 0x0EAA, hi: 0x0EAA },
		{ lo: 0x0EAB, hi: 0x0EAB },
		{ lo: 0x0EAD, hi: 0x0EB0 },
		{ lo: 0x0EB2, hi: 0x0EB2 },
		{ lo: 0x0EB3, hi: 0x0EB3 },
		{ lo: 0x0EBD, hi: 0x0EBD },
		{ lo: 0x0EC0, hi: 0x0EC4 },
		{ lo: 0x0EC6, hi: 0x0EC6 },
		{ lo: 0x0EDC, hi: 0x0EDF },
		{ lo: 0x0F00, hi: 0x0F00 },
		{ lo: 0x0F40, hi: 0x0F47 },
		{ lo: 0x0F49, hi: 0x0F6C },
		{ lo: 0x0F88, hi: 0x0F8C },
		{ lo: 0x1000, hi: 0x102A },
		{ lo: 0x103F, hi: 0x103F },
		{ lo: 0x1050, hi: 0x1055 },
		{ lo: 0x105A, hi: 0x105D },
		{ lo: 0x1061, hi: 0x1061 },
		{ lo: 0x1065, hi: 0x1065 },
		{ lo: 0x1066, hi: 0x1066 },
		{ lo: 0x106E, hi: 0x1070 },
		{ lo: 0x1075, hi: 0x1081 },
		{ lo: 0x108E, hi: 0x108E },
		{ lo: 0x10A0, hi: 0x10C5 },
		{ lo: 0x10C7, hi: 0x10C7 },
		{ lo: 0x10CD, hi: 0x10CD },
		{ lo: 0x10D0, hi: 0x10FA },
		{ lo: 0x10FC, hi: 0x1248 },
		{ lo: 0x124A, hi: 0x124D },
		{ lo: 0x1250, hi: 0x1256 },
		{ lo: 0x1258, hi: 0x1258 },
		{ lo: 0x125A, hi: 0x125D },
		{ lo: 0x1260, hi: 0x1288 },
		{ lo: 0x128A, hi: 0x128D },
		{ lo: 0x1290, hi: 0x12B0 },
		{ lo: 0x12B2, hi: 0x12B5 },
		{ lo: 0x12B8, hi: 0x12BE },
		{ lo: 0x12C0, hi: 0x12C0 },
		{ lo: 0x12C2, hi: 0x12C5 },
		{ lo: 0x12C8, hi: 0x12D6 },
		{ lo: 0x12D8, hi: 0x1310 },
		{ lo: 0x1312, hi: 0x1315 },
		{ lo: 0x1318, hi: 0x135A },
		{ lo: 0x1380, hi: 0x138F },
		{ lo: 0x13A0, hi: 0x13F4 },
		{ lo: 0x1401, hi: 0x166C },
		{ lo: 0x166F, hi: 0x167F },
		{ lo: 0x1681, hi: 0x169A },
		{ lo: 0x16A0, hi: 0x16EA },
		{ lo: 0x1700, hi: 0x170C },
		{ lo: 0x170E, hi: 0x1711 },
		{ lo: 0x1720, hi: 0x1731 },
		{ lo: 0x1740, hi: 0x1751 },
		{ lo: 0x1760, hi: 0x176C },
		{ lo: 0x176E, hi: 0x1770 },
		{ lo: 0x1780, hi: 0x17B3 },
		{ lo: 0x17D7, hi: 0x17D7 },
		{ lo: 0x17DC, hi: 0x17DC },
		{ lo: 0x1820, hi: 0x1877 },
		{ lo: 0x1880, hi: 0x18A8 },
		{ lo: 0x18AA, hi: 0x18AA },
		{ lo: 0x18B0, hi: 0x18F5 },
		{ lo: 0x1900, hi: 0x191C },
		{ lo: 0x1950, hi: 0x196D },
		{ lo: 0x1970, hi: 0x1974 },
		{ lo: 0x1980, hi: 0x19AB },
		{ lo: 0x19C1, hi: 0x19C7 },
		{ lo: 0x1A00, hi: 0x1A16 },
		{ lo: 0x1A20, hi: 0x1A54 },
		{ lo: 0x1AA7, hi: 0x1AA7 },
		{ lo: 0x1B05, hi: 0x1B33 },
		{ lo: 0x1B45, hi: 0x1B4B },
		{ lo: 0x1B83, hi: 0x1BA0 },
		{ lo: 0x1BAE, hi: 0x1BAE },
		{ lo: 0x1BAF, hi: 0x1BAF },
		{ lo: 0x1BBA, hi: 0x1BE5 },
		{ lo: 0x1C00, hi: 0x1C23 },
		{ lo: 0x1C4D, hi: 0x1C4F },
		{ lo: 0x1C5A, hi: 0x1C7D },
		{ lo: 0x1CE9, hi: 0x1CEC },
		{ lo: 0x1CEE, hi: 0x1CF1 },
		{ lo: 0x1CF5, hi: 0x1CF5 },
		{ lo: 0x1CF6, hi: 0x1CF6 },
		{ lo: 0x1D00, hi: 0x1DBF },
		{ lo: 0x1E00, hi: 0x1F15 },
		{ lo: 0x1F18, hi: 0x1F1D },
		{ lo: 0x1F20, hi: 0x1F45 },
		{ lo: 0x1F48, hi: 0x1F4D },
		{ lo: 0x1F50, hi: 0x1F57 },
		{ lo: 0x1F59, hi: 0x1F59 },
		{ lo: 0x1F5B, hi: 0x1F5B },
		{ lo: 0x1F5D, hi: 0x1F5D },
		{ lo: 0x1F5F, hi: 0x1F7D },
		{ lo: 0x1F80, hi: 0x1FB4 },
		{ lo: 0x1FB6, hi: 0x1FBC },
		{ lo: 0x1FBE, hi: 0x1FBE },
		{ lo: 0x1FC2, hi: 0x1FC4 },
		{ lo: 0x1FC6, hi: 0x1FCC },
		{ lo: 0x1FD0, hi: 0x1FD3 },
		{ lo: 0x1FD6, hi: 0x1FDB },
		{ lo: 0x1FE0, hi: 0x1FEC },
		{ lo: 0x1FF2, hi: 0x1FF4 },
		{ lo: 0x1FF6, hi: 0x1FFC },
		{ lo: 0x2071, hi: 0x2071 },
		{ lo: 0x207F, hi: 0x207F },
		{ lo: 0x2090, hi: 0x209C },
		{ lo: 0x2102, hi: 0x2102 },
		{ lo: 0x2107, hi: 0x2107 },
		{ lo: 0x210A, hi: 0x2113 },
		{ lo: 0x2115, hi: 0x2115 },
		{ lo: 0x2119, hi: 0x211D },
		{ lo: 0x2124, hi: 0x2124 },
		{ lo: 0x2126, hi: 0x2126 },
		{ lo: 0x2128, hi: 0x2128 },
		{ lo: 0x212A, hi: 0x212D },
		{ lo: 0x212F, hi: 0x2139 },
		{ lo: 0x213C, hi: 0x213F },
		{ lo: 0x2145, hi: 0x2149 },
		{ lo: 0x214E, hi: 0x214E },
		{ lo: 0x2183, hi: 0x2183 },
		{ lo: 0x2184, hi: 0x2184 },
		{ lo: 0x2C00, hi: 0x2C2E },
		{ lo: 0x2C30, hi: 0x2C5E },
		{ lo: 0x2C60, hi: 0x2CE4 },
		{ lo: 0x2CEB, hi: 0x2CEE },
		{ lo: 0x2CF2, hi: 0x2CF2 },
		{ lo: 0x2CF3, hi: 0x2CF3 },
		{ lo: 0x2D00, hi: 0x2D25 },
		{ lo: 0x2D27, hi: 0x2D27 },
		{ lo: 0x2D2D, hi: 0x2D2D },
		{ lo: 0x2D30, hi: 0x2D67 },
		{ lo: 0x2D6F, hi: 0x2D6F },
		{ lo: 0x2D80, hi: 0x2D96 },
		{ lo: 0x2DA0, hi: 0x2DA6 },
		{ lo: 0x2DA8, hi: 0x2DAE },
		{ lo: 0x2DB0, hi: 0x2DB6 },
		{ lo: 0x2DB8, hi: 0x2DBE },
		{ lo: 0x2DC0, hi: 0x2DC6 },
		{ lo: 0x2DC8, hi: 0x2DCE },
		{ lo: 0x2DD0, hi: 0x2DD6 },
		{ lo: 0x2DD8, hi: 0x2DDE },
		{ lo: 0x2E2F, hi: 0x2E2F },
		{ lo: 0x3005, hi: 0x3005 },
		{ lo: 0x3006, hi: 0x3006 },
		{ lo: 0x3031, hi: 0x3035 },
		{ lo: 0x303B, hi: 0x303B },
		{ lo: 0x303C, hi: 0x303C },
		{ lo: 0x3041, hi: 0x3096 },
		{ lo: 0x309D, hi: 0x309F },
		{ lo: 0x30A1, hi: 0x30FA },
		{ lo: 0x30FC, hi: 0x30FF },
		{ lo: 0x3105, hi: 0x312D },
		{ lo: 0x3131, hi: 0x318E },
		{ lo: 0x31A0, hi: 0x31BA },
		{ lo: 0x31F0, hi: 0x31FF },
		{ lo: 0x3400, hi: 0x4DB5 },
		{ lo: 0x4E00, hi: 0x9FCC },
		{ lo: 0xA000, hi: 0xA48C },
		{ lo: 0xA4D0, hi: 0xA4FD },
		{ lo: 0xA500, hi: 0xA60C },
		{ lo: 0xA610, hi: 0xA61F },
		{ lo: 0xA62A, hi: 0xA62A },
		{ lo: 0xA62B, hi: 0xA62B },
		{ lo: 0xA640, hi: 0xA66E },
		{ lo: 0xA67F, hi: 0xA697 },
		{ lo: 0xA6A0, hi: 0xA6E5 },
		{ lo: 0xA717, hi: 0xA71F },
		{ lo: 0xA722, hi: 0xA788 },
		{ lo: 0xA78B, hi: 0xA78E },
		{ lo: 0xA790, hi: 0xA793 },
		{ lo: 0xA7A0, hi: 0xA7AA },
		{ lo: 0xA7F8, hi: 0xA801 },
		{ lo: 0xA803, hi: 0xA805 },
		{ lo: 0xA807, hi: 0xA80A },
		{ lo: 0xA80C, hi: 0xA822 },
		{ lo: 0xA840, hi: 0xA873 },
		{ lo: 0xA882, hi: 0xA8B3 },
		{ lo: 0xA8F2, hi: 0xA8F7 },
		{ lo: 0xA8FB, hi: 0xA8FB },
		{ lo: 0xA90A, hi: 0xA925 },
		{ lo: 0xA930, hi: 0xA946 },
		{ lo: 0xA960, hi: 0xA97C },
		{ lo: 0xA984, hi: 0xA9B2 },
		{ lo: 0xA9CF, hi: 0xA9CF },
		{ lo: 0xAA00, hi: 0xAA28 },
		{ lo: 0xAA40, hi: 0xAA42 },
		{ lo: 0xAA44, hi: 0xAA4B },
		{ lo: 0xAA60, hi: 0xAA76 },
		{ lo: 0xAA7A, hi: 0xAA7A },
		{ lo: 0xAA80, hi: 0xAAAF },
		{ lo: 0xAAB1, hi: 0xAAB1 },
		{ lo: 0xAAB5, hi: 0xAAB5 },
		{ lo: 0xAAB6, hi: 0xAAB6 },
		{ lo: 0xAAB9, hi: 0xAABD },
		{ lo: 0xAAC0, hi: 0xAAC0 },
		{ lo: 0xAAC2, hi: 0xAAC2 },
		{ lo: 0xAADB, hi: 0xAADD },
		{ lo: 0xAAE0, hi: 0xAAEA },
		{ lo: 0xAAF2, hi: 0xAAF4 },
		{ lo: 0xAB01, hi: 0xAB06 },
		{ lo: 0xAB09, hi: 0xAB0E },
		{ lo: 0xAB11, hi: 0xAB16 },
		{ lo: 0xAB20, hi: 0xAB26 },
		{ lo: 0xAB28, hi: 0xAB2E },
		{ lo: 0xABC0, hi: 0xABE2 },
		{ lo: 0xAC00, hi: 0xD7A3 },
		{ lo: 0xD7B0, hi: 0xD7C6 },
		{ lo: 0xD7CB, hi: 0xD7FB },
		{ lo: 0xF900, hi: 0xFA6D },
		{ lo: 0xFA70, hi: 0xFAD9 },
		{ lo: 0xFB00, hi: 0xFB06 },
		{ lo: 0xFB13, hi: 0xFB17 },
		{ lo: 0xFB1D, hi: 0xFB1D },
		{ lo: 0xFB1F, hi: 0xFB28 },
		{ lo: 0xFB2A, hi: 0xFB36 },
		{ lo: 0xFB38, hi: 0xFB3C },
		{ lo: 0xFB3E, hi: 0xFB3E },
		{ lo: 0xFB40, hi: 0xFB40 },
		{ lo: 0xFB41, hi: 0xFB41 },
		{ lo: 0xFB43, hi: 0xFB43 },
		{ lo: 0xFB44, hi: 0xFB44 },
		{ lo: 0xFB46, hi: 0xFBB1 },
		{ lo: 0xFBD3, hi: 0xFD3D },
		{ lo: 0xFD50, hi: 0xFD8F },
		{ lo: 0xFD92, hi: 0xFDC7 },
		{ lo: 0xFDF0, hi: 0xFDFB },
		{ lo: 0xFE70, hi: 0xFE74 },
		{ lo: 0xFE76, hi: 0xFEFC },
		{ lo: 0xFF21, hi: 0xFF3A },
		{ lo: 0xFF41, hi: 0xFF5A },
		{ lo: 0xFF66, hi: 0xFFBE },
		{ lo: 0xFFC2, hi: 0xFFC7 },
		{ lo: 0xFFCA, hi: 0xFFCF },
		{ lo: 0xFFD2, hi: 0xFFD7 },
		{ lo: 0xFFDA, hi: 0xFFDC },
	]
}

kinds : Str -> List(FlowLexer.Kind)
kinds = |text|
	match FlowLexer.tokenize(text.to_utf8()) {
		Tokens(tokens) => tokens.map(|t| t.kind)
		_ => []
	}

expect kinds("flowchart TD\nA-->B\n") == [Graph, Dir, Newline, NodeString, Link, NodeString, Newline, Eof]
expect kinds("graph\nA\n") == [Graph, NoDir, NodeString, Newline, Eof]
expect kinds("graph LR\nA -- go --> B\n") == [Graph, Dir, Newline, NodeString, StartLink, EdgeText, EdgeText, Link, NodeString, Newline, Eof]
expect kinds("graph LR\nA -.-> B\nA ==> C\nA ~~~ D\n") == [Graph, Dir, Newline, NodeString, Link, NodeString, Newline, NodeString, Link, NodeString, Newline, NodeString, Link, NodeString, Newline, Eof]
expect kinds("graph LR\nA[\"q\"]\n") == [Graph, Dir, Newline, NodeString, Sqs, Str, Sqe, Newline, Eof]
expect kinds("graph LR\nA((c))\n") == [Graph, Dir, Newline, NodeString, Ps, Ps, Text, Pe, Pe, Newline, Eof]
expect kinds("graph LR\nA[/t\\]\n") == [Graph, Dir, Newline, NodeString, TrapStart, Text, TrapEnd, Newline, Eof]
expect kinds("graph LR\nclasses\n") == [Graph, Dir, Newline, NodeString, Newline, Eof]
expect kinds("graph LR\nsubgraph S\nend\n") == [Graph, Dir, Newline, Subgraph, Space, NodeString, Newline, End, Eof]

## The direction rule is tried before node ids, so it claims the whole line.
expect kinds("graph LR\nA --> B direction TB\n") == [Graph, Dir, Newline, DirectionTb, Newline, Eof]
expect kinds("graph LR\nA e1@--> B\n") == [Graph, Dir, Newline, NodeString, Space, LinkId, Link, NodeString, Newline, Eof]
expect kinds("graph LR\nvery\nv\n") == [Graph, Dir, Newline, NodeString, Newline, Down, Newline, Eof]
expect kinds("graph LR\nCafé\n") == [Graph, Dir, Newline, NodeString, UnicodeText, Newline, Eof]
expect FlowLexer.tokenize("graph LR\nA@{ shape: rect }\n".to_utf8()) == Unsupported({ feature: "shape data", at: 10 })
expect FlowLexer.tokenize("graph LR\nA 😀\n".to_utf8()) == NoRule(11)
