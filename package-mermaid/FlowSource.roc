import Bytes

## Source preparation that runs before the flowchart grammar, reproducing
## Mermaid's own pipeline in order: line-ending and tag-attribute cleanup,
## comment removal, diagram detection, entity encoding, and the flowchart
## parser's brace-newline rewrite. Every step is a single forward scan.
FlowSource :: {}.{

	## What preparation decided about one source text.
	Prepared : [
		Flowchart(List(U8)),
		NotFlowchart,
		Unsupported(Str),
	]

	prepare : Str -> Prepared
	prepare = |text| {
		cleaned = FlowSource.strip_comment_lines(FlowSource.quote_tag_attributes(FlowSource.normalize_line_endings(text.to_utf8())))
		if FlowSource.has_front_matter(cleaned) {
			Unsupported("front matter")
		} else if FlowSource.contains(cleaned, "%%{".to_utf8()) {
			Unsupported("directive")
		} else {
			match FlowSource.detect(cleaned) {
				Flowchart => {
					encoded = FlowSource.encode_entities(cleaned).append('\n')
					Flowchart(FlowSource.collapse_brace_newlines(encoded))
				}
				Elk => Unsupported("ELK layout")
				Other => NotFlowchart
			}
		}
	}

	## `\r\n` and lone `\r` both become `\n`.
	normalize_line_endings : List(U8) -> List(U8)
	normalize_line_endings = |bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		while $i < bytes.len() {
			b = Bytes.at(bytes, $i)
			if b == '\r' {
				$out = $out.append('\n')
				$i = if (Bytes.at(bytes, $i + 1) == '\n' and $i + 1 < bytes.len()) $i + 2 else $i + 1
			} else {
				$out = $out.append(b)
				$i = $i + 1
			}
		}
		$out
	}

	## Inside every `<word ...>` tag, `="value"` becomes `='value'`.
	quote_tag_attributes : List(U8) -> List(U8)
	quote_tag_attributes = |bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		len = bytes.len()
		while $i < len {
			b = Bytes.at(bytes, $i)
			if b == '<' and $i + 1 < len and Bytes.is_word(Bytes.at(bytes, $i + 1)) {
				# `<(\w+)([^>]*)>`: the tag runs to the first `>`; without one
				# there is no match and the `<` is ordinary text.
				close = Bytes.find_byte(bytes, $i + 1, '>')
				if close < len {
					var $j = $i + 1
					while Bytes.is_word(Bytes.at(bytes, $j)) and $j < close {
						$j = $j + 1
					}
					$out = $out.concat(bytes.sublist({ start: $i, len: $j - $i }))
					$out = $out.concat(FlowSource.single_quote_values(bytes.sublist({ start: $j, len: close - $j })))
					$out = $out.append('>')
					$i = close + 1
				} else {
					$out = $out.append(b)
					$i = $i + 1
				}
			} else {
				$out = $out.append(b)
				$i = $i + 1
			}
		}
		$out
	}

	## `="([^"]*)"` becomes `='$1'` within one tag's attribute text.
	single_quote_values : List(U8) -> List(U8)
	single_quote_values = |attrs| {
		var $out = List.with_capacity(attrs.len())
		var $i = 0
		len = attrs.len()
		while $i < len {
			if Bytes.at(attrs, $i) == '=' and $i + 1 < len and Bytes.at(attrs, $i + 1) == '"' {
				close = Bytes.find_byte(attrs, $i + 2, '"')
				if close < len {
					$out = $out.concat(['=', '\''])
					$out = $out.concat(attrs.sublist({ start: $i + 2, len: close - $i - 2 }))
					$out = $out.append('\'')
					$i = close + 1
				} else {
					$out = $out.append('=')
					$i = $i + 1
				}
			} else {
				$out = $out.append(Bytes.at(attrs, $i))
				$i = $i + 1
			}
		}
		$out
	}

	## Mermaid's `cleanupComments`: `/^\s*%%(?!{)[^\n]+\n?/gm` removed, then the
	## result trimmed at the start. A match at a line start swallows any
	## whitespace before the `%%`, including blank lines; `%%` alone on a line
	## is not a comment here because `[^\n]+` needs at least one character.
	strip_comment_lines : List(U8) -> List(U8)
	strip_comment_lines = |bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		len = bytes.len()
		while $i < len {
			# `$i` is always a line start here.
			j = Bytes.skip_space(bytes, $i)
			is_comment = j + 2 < len
				and Bytes.at(bytes, j) == '%'
				and Bytes.at(bytes, j + 1) == '%'
				and Bytes.at(bytes, j + 2) != '{'
				and Bytes.at(bytes, j + 2) != '\n'
			if is_comment {
				line_end = Bytes.find_byte(bytes, j + 2, '\n')
				$i = if (line_end < len) line_end + 1 else len
			} else {
				next = Bytes.next_line_start(bytes, $i)
				$out = $out.concat(bytes.sublist({ start: $i, len: next - $i }))
				$i = next
			}
		}
		$out.drop_first(Bytes.skip_space($out, 0))
	}

	## A Jekyll-style `---` fence at the start, possibly indented.
	has_front_matter : List(U8) -> Bool
	has_front_matter = |bytes| {
		var $i = 0
		while Bytes.at(bytes, $i) == ' ' or Bytes.at(bytes, $i) == '\t' {
			$i = $i + 1
		}
		Bytes.starts_with_at(bytes, $i, "---".to_utf8())
	}

	contains : List(U8), List(U8) -> Bool
	contains = |bytes, needle| {
		var $i = 0
		var $found = False
		while !$found and $i + needle.len() <= bytes.len() {
			if Bytes.starts_with_at(bytes, $i, needle) {
				$found = True
			}
			$i = $i + 1
		}
		$found
	}

	## Mermaid's detector: `^\s*(graph|flowchart)` after `%%` comment runs are
	## replaced by a newline. Only the leading text decides the result.
	detect : List(U8) -> [Flowchart, Elk, Other]
	detect = |bytes| {
		var $i = Bytes.skip_space(bytes, 0)
		var $scanning = True
		while $scanning {
			if Bytes.at(bytes, $i) == '%' and Bytes.at(bytes, $i + 1) == '%' and $i + 1 < bytes.len() {
				line_end = Bytes.find_byte(bytes, $i, '\n')
				if line_end < bytes.len() {
					$i = Bytes.skip_space(bytes, line_end + 1)
				} else {
					$scanning = False
				}
			} else {
				$scanning = False
			}
		}
		if Bytes.starts_with_at(bytes, $i, "flowchart-elk".to_utf8()) {
			Elk
		} else if Bytes.starts_with_at(bytes, $i, "graph".to_utf8()) or Bytes.starts_with_at(bytes, $i, "flowchart".to_utf8()) {
			Flowchart
		} else {
			Other
		}
	}

	## Mermaid's `encodeEntities`. A trailing `;` is first dropped from style
	## and class definition lines that contain a color, then every `#word;`
	## becomes a private placeholder so the grammar never sees it. Numeric
	## entities use `ﬂ°°`; named ones `ﬂ°`; both end with `¶ß`.
	encode_entities : List(U8) -> List(U8)
	encode_entities = |bytes| {
		styled = FlowSource.drop_color_semicolons(bytes, "style".to_utf8())
		defined = FlowSource.drop_color_semicolons(styled, "classDef".to_utf8())
		FlowSource.replace_entities(defined)
	}

	## `/keyword.*:\S*#.*;/g` with its match's final `;` removed. `.` stops at
	## line terminators, so each line is independent. The match starts at
	## the first `keyword`, needs a `:` followed by non-space characters
	## reaching a `#`, and ends at the line's last `;` after that `#`.
	drop_color_semicolons : List(U8), List(U8) -> List(U8)
	drop_color_semicolons = |bytes, keyword| {
		var $out = List.with_capacity(bytes.len())
		var $start = 0
		len = bytes.len()
		while $start < len {
			line_end = Bytes.line_terminator_from(bytes, $start)
			drop = FlowSource.color_semicolon(bytes, $start, line_end, keyword)
			match drop {
				Some(at) => {
					$out = $out.concat(bytes.sublist({ start: $start, len: at - $start }))
					$out = $out.concat(bytes.sublist({ start: at + 1, len: line_end - at - 1 }))
				}
				None => {
					$out = $out.concat(bytes.sublist({ start: $start, len: line_end - $start }))
				}
			}
			# Copy the terminator itself.
			term = Bytes.line_terminator_len(bytes, line_end)
			$out = $out.concat(bytes.sublist({ start: line_end, len: term }))
			$start = line_end + (if (term == 0) 1 else term)
		}
		$out
	}

	## Position of the `;` the color rule removes on one line, if it applies.
	color_semicolon : List(U8), U64, U64, List(U8) -> [Some(U64), None]
	color_semicolon = |bytes, start, line_end, keyword| {
		var $k = start
		var $keyword_at = line_end
		while $k + keyword.len() <= line_end and $keyword_at == line_end {
			if Bytes.starts_with_at(bytes, $k, keyword) {
				$keyword_at = $k
			}
			$k = $k + 1
		}
		if $keyword_at == line_end {
			None
		} else {
			# Earliest `#` reachable from some `:` through non-space characters.
			var $hash = line_end
			var $i = $keyword_at + keyword.len()
			while $i < line_end and $hash == line_end {
				if Bytes.at(bytes, $i) == ':' {
					var $j = $i + 1
					var $run = True
					while $run and $j < line_end {
						if Bytes.at(bytes, $j) == '#' {
							$hash = $j
							$run = False
						} else if Bytes.space_len(bytes, $j) > 0 {
							$run = False
						} else {
							$j = $j + 1
						}
					}
				}
				$i = $i + 1
			}
			if $hash == line_end {
				None
			} else {
				var $semi = line_end
				var $m = $hash + 1
				while $m < line_end {
					if Bytes.at(bytes, $m) == ';' {
						$semi = $m
					}
					$m = $m + 1
				}
				if ($semi == line_end) None else Some($semi)
			}
		}
	}

	## `/#\w+;/g` to Mermaid's placeholders.
	replace_entities : List(U8) -> List(U8)
	replace_entities = |bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		len = bytes.len()
		while $i < len {
			b = Bytes.at(bytes, $i)
			if b == '#' {
				var $j = $i + 1
				while $j < len and Bytes.is_word(Bytes.at(bytes, $j)) {
					$j = $j + 1
				}
				if $j > $i + 1 and $j < len and Bytes.at(bytes, $j) == ';' {
					inner = bytes.sublist({ start: $i + 1, len: $j - $i - 1 })
					numeric = inner.all(|c| c >= '0' and c <= '9')
					prefix = if (numeric) FlowSource.numeric_entity_prefix else FlowSource.named_entity_prefix
					$out = $out.concat(prefix).concat(inner).concat(FlowSource.entity_suffix)
					$i = $j + 1
				} else {
					$out = $out.append(b)
					$i = $i + 1
				}
			} else {
				$out = $out.append(b)
				$i = $i + 1
			}
		}
		$out
	}

	numeric_entity_prefix : List(U8)
	numeric_entity_prefix = "ﬂ°°".to_utf8()

	named_entity_prefix : List(U8)
	named_entity_prefix = "ﬂ°".to_utf8()

	entity_suffix : List(U8)
	entity_suffix = "¶ß".to_utf8()

	## The flowchart parser's `src.replace(/}\s*\n/g, '}\n')`: whitespace after
	## a `}` up to the last newline of that whitespace run becomes one newline.
	collapse_brace_newlines : List(U8) -> List(U8)
	collapse_brace_newlines = |bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		len = bytes.len()
		while $i < len {
			b = Bytes.at(bytes, $i)
			$out = $out.append(b)
			if b == '}' {
				last_newline = Bytes.last_newline_in_space_run(bytes, $i + 1)
				match last_newline {
					Some(at) => {
						$out = $out.append('\n')
						$i = at + 1
					}
					None => {
						$i = $i + 1
					}
				}
			} else {
				$i = $i + 1
			}
		}
		$out
	}
}

expect FlowSource.normalize_line_endings("a\r\nb\rc".to_utf8()) == "a\nb\nc".to_utf8()
expect FlowSource.quote_tag_attributes("x <a href=\"y\"> z".to_utf8()) == "x <a href='y'> z".to_utf8()
expect FlowSource.strip_comment_lines("%% c\nflowchart TD\n  %% d\nA\n%%\nB".to_utf8()) == "flowchart TD\nA\n%%\nB".to_utf8()
expect FlowSource.strip_comment_lines("A\n%%{init}%%\n".to_utf8()) == "A\n%%{init}%%\n".to_utf8()
expect FlowSource.detect("%% x\n  graph TD".to_utf8()) == Flowchart
expect FlowSource.detect("graphics".to_utf8()) == Flowchart
expect FlowSource.detect("flowchart-elk TD".to_utf8()) == Elk
expect FlowSource.detect("sequenceDiagram".to_utf8()) == Other
expect FlowSource.encode_entities("A[#quot;x#quot; #35;]".to_utf8()) == "A[ﬂ°quot¶ßxﬂ°quot¶ß ﬂ°°35¶ß]".to_utf8()
expect FlowSource.encode_entities("style A fill:#f96;\nB".to_utf8()) == "style A fill:#f96\nB".to_utf8()

## Only the final `;` is spared, so an earlier `#f96;` still becomes an entity.
expect FlowSource.encode_entities("classDef c fill:#f96;stroke:#333;".to_utf8()) == "classDef c fill:ﬂ°f96¶ßstroke:#333".to_utf8()
expect FlowSource.collapse_brace_newlines("A{x}  \n\n B".to_utf8()) == "A{x}\n B".to_utf8()
