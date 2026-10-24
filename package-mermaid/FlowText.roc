import Bytes
import HtmlEntities

## Label text handling that mirrors Mermaid: JavaScript `trim`, the quote
## stripping in `flowDb`, and the decoding that turns stored text into what a
## reader sees, where entity placeholders become characters and `<br>` tags
## become line breaks.
FlowText :: {}.{

	## JavaScript `String.prototype.trim`.
	trim : Str -> Str
	trim = |text| {
		bytes = text.to_utf8()
		start = Bytes.skip_space(bytes, 0)
		var $end = start
		var $i = start
		while $i < bytes.len() {
			space = Bytes.space_len(bytes, $i)
			if space > 0 {
				$i = $i + space
			} else {
				$i = $i + Bytes.char_len(Bytes.at(bytes, $i))
				$end = $i
			}
		}
		Bytes.slice_str(bytes, start, $end - start)
	}

	## What Mermaid's sanitizer does to plain text: HTML parsing drops NUL
	## characters. Its entity decoding and re-escaping cancel out until
	## `display`, and markup is reported separately by `has_markup`.
	sanitize : Str -> Str
	sanitize = |text| {
		bytes = text.to_utf8()
		if (bytes.contains(0)) Str.from_utf8_lossy(bytes.keep_if(|b| b != 0)) else text
	}

	## `flowDb` drops one pair of surrounding double quotes. A lone `"` stays,
	## because `substring(1, 0)` swaps its arguments.
	strip_quotes : Str -> Str
	strip_quotes = |text| {
		bytes = text.to_utf8()
		if bytes.len() >= 2 and Bytes.at(bytes, 0) == '"' and Bytes.at(bytes, bytes.len() - 1) == '"' {
			Bytes.slice_str(bytes, 1, bytes.len() - 2)
		} else {
			text
		}
	}

	## Whether stored text holds markup other than line breaks. Mermaid
	## passes such text through an HTML sanitizer and renders the result;
	## this package does not interpret markup yet.
	has_markup : Str -> Bool
	has_markup = |text| {
		bytes = text.to_utf8()
		var $i = 0
		var $found = False
		while !$found and $i < bytes.len() {
			if Bytes.at(bytes, $i) == '<' {
				next = Bytes.at(bytes, $i + 1)
				starts_tag = $i + 1 < bytes.len() and ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or next == '/' or next == '!' or next == '?')
				if starts_tag and FlowText.break_tag_len(bytes, $i) == 0 {
					$found = True
				}
			}
			$i = $i + 1
		}
		$found
	}

	## Length of a `<br\s*\/?>` tag at `i` (case-insensitive), or `0`.
	break_tag_len : List(U8), U64 -> U64
	break_tag_len = |bytes, i| {
		b = Bytes.at(bytes, i + 1)
		r = Bytes.at(bytes, i + 2)
		if Bytes.at(bytes, i) == '<' and (b == 'b' or b == 'B') and (r == 'r' or r == 'R') {
			after_space = Bytes.skip_space(bytes, i + 3)
			after_slash = if (Bytes.at(bytes, after_space) == '/') after_space + 1 else after_space
			if (Bytes.at(bytes, after_slash) == '>' and after_slash < bytes.len()) after_slash + 1 - i else 0
		} else {
			0
		}
	}

	## Stored text as displayed: placeholders back to entities, line-break
	## tags to `\n`, then HTML character references decoded. Unknown named
	## references stay as written, as they do in HTML.
	display : Str -> Str
	display = |text| {
		bytes = text.to_utf8()
		numeric = "ﬂ°°".to_utf8()
		named = "ﬂ°".to_utf8()
		suffix = "¶ß".to_utf8()
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		while $i < bytes.len() {
			if Bytes.starts_with_at(bytes, $i, numeric) {
				$out = $out.concat(['&', '#'])
				$i = $i + numeric.len()
			} else if Bytes.starts_with_at(bytes, $i, named) {
				$out = $out.append('&')
				$i = $i + named.len()
			} else if Bytes.starts_with_at(bytes, $i, suffix) {
				$out = $out.append(';')
				$i = $i + suffix.len()
			} else {
				tag = FlowText.break_tag_len(bytes, $i)
				if tag > 0 {
					$out = $out.append('\n')
					$i = $i + tag
				} else {
					$out = $out.append(Bytes.at(bytes, $i))
					$i = $i + 1
				}
			}
		}
		FlowText.decode_references($out)
	}

	## Character references decoded as the HTML tokenizer decodes text: the
	## longest known name wins, legacy names need no `;`, numeric references
	## need no `;` either, and invalid numbers become U+FFFD.
	decode_references : List(U8) -> Str
	decode_references = |bytes| {
		var $out = List.with_capacity(bytes.len())
		var $i = 0
		while $i < bytes.len() {
			b = Bytes.at(bytes, $i)
			decoded = if (b == '&') FlowText.reference_at(bytes, $i + 1) else None
			match decoded {
				Some({ codepoints, len }) => {
					$out = codepoints.fold($out, |acc, cp| acc.concat(Bytes.encode(cp)))
					$i = $i + 1 + len
				}
				None => {
					$out = $out.append(b)
					$i = $i + 1
				}
			}
		}
		Str.from_utf8_lossy($out)
	}

	## The reference starting just after an `&`, and how many bytes it spans.
	reference_at : List(U8), U64 -> [Some({ codepoints : List(U32), len : U64 }), None]
	reference_at = |bytes, start| {
		if Bytes.at(bytes, start) == '#' and start < bytes.len() {
			hex = Bytes.at(bytes, start + 1) == 'x' or Bytes.at(bytes, start + 1) == 'X'
			digits_start = if (hex) start + 2 else start + 1
			var $j = digits_start
			var $value = 0.U64
			while $j < bytes.len() and FlowText.digit_value(Bytes.at(bytes, $j), hex).is_ok() {
				digit = FlowText.digit_value(Bytes.at(bytes, $j), hex) ?? 0
				$value = U64.min(0x110000, $value * (if (hex) 16 else 10) + digit)
				$j = $j + 1
			}
			if $j == digits_start {
				None
			} else {
				end = if (Bytes.at(bytes, $j) == ';' and $j < bytes.len()) $j + 1 else $j
				Some({ codepoints: [FlowText.numeric_code_point($value)], len: end - start })
			}
		} else {
			var $len = U64.min(HtmlEntities.longest_name, bytes.len() - U64.min(start, bytes.len()))
			var $found = None
			while $found == None and $len > 0 {
				$found = match FlowText.named(bytes.sublist({ start, len: $len })) {
					Some(codepoints) => Some({ codepoints, len: $len })
					None => None
				}
				$len = $len - 1
			}
			$found
		}
	}

	digit_value : U8, Bool -> Try(U64, [NotDigit])
	digit_value = |d, hex|
		if d >= '0' and d <= '9' {
			Ok((d - '0').to_u64())
		} else if hex and d >= 'a' and d <= 'f' {
			Ok((d - 'a' + 10).to_u64())
		} else if hex and d >= 'A' and d <= 'F' {
			Ok((d - 'A' + 10).to_u64())
		} else {
			Err(NotDigit)
		}

	## The HTML numeric reference fixups.
	numeric_code_point : U64 -> U32
	numeric_code_point = |value| {
		if value == 0 or value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF) {
			0xFFFD
		} else if value >= 0x80 and value <= 0x9F {
			FlowText.windows_1252.get(value - 0x80) ?? 0xFFFD
		} else {
			value.to_u32_wrap()
		}
	}

	## What C1 control references mean in HTML.
	windows_1252 : List(U32)
	windows_1252 = [
		0x20AC,
		0x81,
		0x201A,
		0x0192,
		0x201E,
		0x2026,
		0x2020,
		0x2021,
		0x02C6,
		0x2030,
		0x0160,
		0x2039,
		0x0152,
		0x8D,
		0x017D,
		0x8F,
		0x90,
		0x2018,
		0x2019,
		0x201C,
		0x201D,
		0x2022,
		0x2013,
		0x2014,
		0x02DC,
		0x2122,
		0x0161,
		0x203A,
		0x0153,
		0x9D,
		0x017E,
		0x0178,
	]

	## Binary search of the named reference table by name bytes.
	named : List(U8) -> [Some(List(U32)), None]
	named = |name| {
		entries = HtmlEntities.entries
		var $lo = 0
		var $hi = entries.len()
		var $found = None
		while $found == None and $lo < $hi {
			mid = ($lo + $hi) / 2
			entry = entries.get(mid) ?? { name: "", codepoints: [] }
			order = FlowText.compare_bytes(entry.name.to_utf8(), name)
			if order == Before {
				$lo = mid + 1
			} else if order == After {
				$hi = mid
			} else {
				$found = Some(entry.codepoints)
			}
		}
		$found
	}

	compare_bytes : List(U8), List(U8) -> [Before, Same, After]
	compare_bytes = |a, b| {
		shared = U64.min(a.len(), b.len())
		var $k = 0
		var $order = Same
		while $order == Same and $k < shared {
			x = Bytes.at(a, $k)
			y = Bytes.at(b, $k)
			$order = if (x < y) Before else if (x > y) After else Same
			$k = $k + 1
		}
		if $order != Same {
			$order
		} else if a.len() < b.len() {
			Before
		} else if a.len() > b.len() {
			After
		} else {
			Same
		}
	}
}

expect FlowText.trim("\u(00A0) a b \n") == "a b"
expect FlowText.trim("   ") == ""
expect FlowText.strip_quotes("\"x\"") == "x"
expect FlowText.strip_quotes("\"") == "\""
expect FlowText.display("ﬂ°quot¶ßhiﬂ°quot¶ß ﬂ°°35¶ß") == "\"hi\" #"
expect FlowText.display("a<br>b<BR/>c<br />d") == "a\nb\nc\nd"
expect FlowText.display("a &amp; b &unknown; c") == "a & b &unknown; c"
expect FlowText.has_markup("<b>x</b>")
expect !FlowText.has_markup("a < b<br/>")
expect FlowText.display("in&amp") == "in&"
expect FlowText.display("&notit; &#128; &#0; &#x41") == "¬it; € \u(FFFD) A"
expect FlowText.sanitize("a\u(0)b") == "ab"
