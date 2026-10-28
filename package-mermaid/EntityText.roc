import FlowText

## Internal text operations shared by the ER and class readers.
EntityText :: {}.{

	## Split compact attribute/member blocks without splitting crow's-foot
	## braces in relationship operators or braces inside quoted labels.
	blocks : Str -> List(Str)
	blocks = |source| {
		var $out = []
		for statement in EntityText.statements(source) {
			if statement.contains("--") or statement.contains("..") {
				$out = $out.append(statement)
			} else {
				var $current = []
				var $quoted = False
				var $escaped = False
				for c in statement.to_utf8() {
					if !$quoted and c == '{' {
						head = EntityText.trim(Str.from_utf8_lossy($current))
						$out = $out.append("${head} {")
						$current = []
					} else if !$quoted and c == '}' {
						row = EntityText.trim(Str.from_utf8_lossy($current))
						if !row.is_empty() {
							$out = $out.append(row)
						}
						$out = $out.append("}")
						$current = []
					} else {
						$current = $current.append(c)
						if c == '"' and !$escaped {
							$quoted = !$quoted
						}
						$escaped = c == '\\' and !$escaped
					}
				}
				tail = EntityText.trim(Str.from_utf8_lossy($current))
				if !tail.is_empty() {
					$out = $out.append(tail)
				}
			}
		}
		$out
	}

	trim : Str -> Str
	trim = FlowText.trim

	unquote : Str -> Str
	unquote = |text| {
		s = EntityText.trim(text)
		b = s.to_utf8()
		if b.len() >= 2 and b.first() == Ok('"') and b.last() == Ok('"') {
			Str.from_utf8_lossy(b.drop_first(1).drop_last(1))
		} else {
			s
		}
	}

	split : Str, Str -> [Found(Str, Str), Missing]
	split = |text, separator| match text.split_on(separator) {
		[] | [_] => Missing
		[first, .. as rest] => Found(first, Str.join_with(rest, separator))
	}

	## Line/semicolon statements, excluding comments outside quoted labels.
	statements : Str -> List(Str)
	statements = |text| {
		bytes = text.to_utf8()
		var $out = []
		var $line = []
		var $quoted = False
		var $comment = False
		var $escaped = False
		var $i = 0
		while $i < bytes.len() {
			c = bytes.get($i) ?? 0
			if c == '\n' or (c == ';' and !$quoted and !$comment) {
				s = EntityText.trim(Str.from_utf8_lossy($line))
				if !s.is_empty() {
					$out = $out.append(s)
				}
				$line = []
				$comment = False
				$escaped = False
			} else if !$comment {
				if !$quoted and c == '%' and bytes.get($i + 1) == Ok('%') {
					$comment = True
				} else {
					$line = $line.append(c)
					if c == '"' and !$escaped {
						$quoted = !$quoted
					}
					$escaped = c == '\\' and !$escaped
				}
			}
			$i = $i + 1
		}
		s = EntityText.trim(Str.from_utf8_lossy($line))
		if !s.is_empty() {
			$out = $out.append(s)
		}
		$out
	}

	tokens : Str -> List(Str)
	tokens = |text| {
		var $out = []
		var $word = []
		var $quoted = False
		var $escaped = False
		for c in text.to_utf8() {
			if (c == ' ' or c == '\t' or c == '\r') and !$quoted {
				if !$word.is_empty() {
					$out = $out.append(Str.from_utf8_lossy($word))
					$word = []
				}
			} else {
				$word = $word.append(c)
				if c == '"' and !$escaped {
					$quoted = !$quoted
				}
				$escaped = c == '\\' and !$escaped
			}
		}
		if !$word.is_empty() {
			$out = $out.append(Str.from_utf8_lossy($word))
		}
		$out
	}

	## A bare identifier or a quoted identifier, never punctuation/markup.
	identifier : Str -> Bool
	identifier = |text| {
		b = text.to_utf8()
		!b.is_empty() and (
			if b.first() == Ok('"') {
				b.len() > 2 and b.last() == Ok('"')
			} else {
				b.all(|c| c >= 128 or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-')
			}
		)
	}
}

expect EntityText.statements("erDiagram\n A ||--o{ B : \"owns; items\" %% ignored\n") == ["erDiagram", "A ||--o{ B : \"owns; items\""]
expect EntityText.tokens("string name PK,FK \"display name\"") == ["string", "name", "PK,FK", "\"display name\""]
