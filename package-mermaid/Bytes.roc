## UTF-8 byte scanning with JavaScript regular-expression character classes,
## so ported Mermaid patterns see exactly the characters their originals see.
## Positions are byte offsets; reading past the end yields `0`, which callers
## pair with explicit bounds checks wherever a real NUL could matter.
Bytes :: {}.{

	at : List(U8), U64 -> U8
	at = |bytes, i| bytes.get(i) ?? 0

	## `\w`: ASCII letters, digits, and `_`.
	is_word : U8 -> Bool
	is_word = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_'

	is_digit : U8 -> Bool
	is_digit = |b| b >= '0' and b <= '9'

	## Byte length of the JavaScript `\s` character at `i`, or `0`.
	space_len : List(U8), U64 -> U64
	space_len = |bytes, i| {
		b = Bytes.at(bytes, i)
		if i >= bytes.len() {
			0
		} else if b == ' ' or (b >= 0x09 and b <= 0x0D) {
			1
		} else if b < 0x80 {
			0
		} else {
			cp = Bytes.code_point(bytes, i)
			if cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0xFEFF {
				Bytes.char_len(b)
			} else {
				0
			}
		}
	}

	## First position at or after `i` that is not `\s`.
	skip_space : List(U8), U64 -> U64
	skip_space = |bytes, i| {
		var $j = i
		var $step = Bytes.space_len(bytes, $j)
		while $step > 0 {
			$j = $j + $step
			$step = Bytes.space_len(bytes, $j)
		}
		$j
	}

	## Byte length of a line terminator for `.` at `i` (`\n`, `\r`, U+2028,
	## U+2029), or `0`.
	line_terminator_len : List(U8), U64 -> U64
	line_terminator_len = |bytes, i| {
		b = Bytes.at(bytes, i)
		if i >= bytes.len() {
			0
		} else if b == '\n' or b == '\r' {
			1
		} else if b == 0xE2 and Bytes.at(bytes, i + 1) == 0x80 and (Bytes.at(bytes, i + 2) == 0xA8 or Bytes.at(bytes, i + 2) == 0xA9) {
			3
		} else {
			0
		}
	}

	## Position of the first line terminator at or after `i`, or the length.
	line_terminator_from : List(U8), U64 -> U64
	line_terminator_from = |bytes, i| {
		var $j = i
		while $j < bytes.len() and Bytes.line_terminator_len(bytes, $j) == 0 {
			$j = $j + 1
		}
		$j
	}

	## Start of the line after the one containing `i`, where `^` with the
	## multiline flag matches; the length if there is none.
	next_line_start : List(U8), U64 -> U64
	next_line_start = |bytes, i| {
		end = Bytes.line_terminator_from(bytes, i)
		if end >= bytes.len() {
			bytes.len()
		} else {
			end + Bytes.line_terminator_len(bytes, end)
		}
	}

	## Position of the first `target` at or after `i`, or the length.
	find_byte : List(U8), U64, U8 -> U64
	find_byte = |bytes, i, target| {
		var $j = i
		while $j < bytes.len() and Bytes.at(bytes, $j) != target {
			$j = $j + 1
		}
		$j
	}

	starts_with_at : List(U8), U64, List(U8) -> Bool
	starts_with_at = |bytes, i, prefix| {
		if i + prefix.len() > bytes.len() {
			False
		} else {
			var $k = 0
			var $same = True
			while $same and $k < prefix.len() {
				if Bytes.at(bytes, i + $k) != Bytes.at(prefix, $k) {
					$same = False
				}
				$k = $k + 1
			}
			$same
		}
	}

	## Whether bytes `a`, `b` start at `i`.
	pair_at : List(U8), U64, U8, U8 -> Bool
	pair_at = |bytes, i, a, b| i + 1 < bytes.len() and Bytes.at(bytes, i) == a and Bytes.at(bytes, i + 1) == b

	## Whether bytes `a`, `b`, `c` start at `i`.
	triple_at : List(U8), U64, U8, U8, U8 -> Bool
	triple_at = |bytes, i, a, b, c| i + 2 < bytes.len() and Bytes.at(bytes, i) == a and Bytes.at(bytes, i + 1) == b and Bytes.at(bytes, i + 2) == c

	## In the `\s` run starting at `i`, the position of its last `\n`.
	last_newline_in_space_run : List(U8), U64 -> [Some(U64), None]
	last_newline_in_space_run = |bytes, i| {
		var $j = i
		var $last = None
		var $step = Bytes.space_len(bytes, $j)
		while $step > 0 {
			if Bytes.at(bytes, $j) == '\n' {
				$last = Some($j)
			}
			$j = $j + $step
			$step = Bytes.space_len(bytes, $j)
		}
		$last
	}

	## Length of the UTF-8 sequence that starts with lead byte `b`.
	char_len : U8 -> U64
	char_len = |b|
		if b < 0x80 {
			1
		} else if b >= 0xF0 {
			4
		} else if b >= 0xE0 {
			3
		} else if b >= 0xC0 {
			2
		} else {
			1
		}

	## The code point of the UTF-8 sequence starting at `i`. Input comes from
	## a `Str`, so sequences are well formed.
	code_point : List(U8), U64 -> U32
	code_point = |bytes, i| {
		b0 = Bytes.at(bytes, i).to_u32()
		b1 = (Bytes.at(bytes, i + 1).to_u32()).bitwise_and(0x3F)
		b2 = (Bytes.at(bytes, i + 2).to_u32()).bitwise_and(0x3F)
		b3 = (Bytes.at(bytes, i + 3).to_u32()).bitwise_and(0x3F)
		if b0 < 0x80 {
			b0
		} else if b0 >= 0xF0 {
			(b0.bitwise_and(0x07)).shl_wrap(18).bitwise_or(b1.shl_wrap(12)).bitwise_or(b2.shl_wrap(6)).bitwise_or(b3)
		} else if b0 >= 0xE0 {
			(b0.bitwise_and(0x0F)).shl_wrap(12).bitwise_or(b1.shl_wrap(6)).bitwise_or(b2)
		} else {
			(b0.bitwise_and(0x1F)).shl_wrap(6).bitwise_or(b1)
		}
	}

	## UTF-8 encoding of one code point.
	encode : U32 -> List(U8)
	encode = |cp|
		if cp < 0x80 {
			[cp.to_u8_wrap()]
		} else if cp < 0x800 {
			[(cp.shr_zf_wrap(6)).bitwise_or(0xC0).to_u8_wrap(), (cp.bitwise_and(0x3F)).bitwise_or(0x80).to_u8_wrap()]
		} else if cp < 0x10000 {
			[
				(cp.shr_zf_wrap(12)).bitwise_or(0xE0).to_u8_wrap(),
				(cp.shr_zf_wrap(6).bitwise_and(0x3F)).bitwise_or(0x80).to_u8_wrap(),
				(cp.bitwise_and(0x3F)).bitwise_or(0x80).to_u8_wrap(),
			]
		} else {
			[
				(cp.shr_zf_wrap(18)).bitwise_or(0xF0).to_u8_wrap(),
				(cp.shr_zf_wrap(12).bitwise_and(0x3F)).bitwise_or(0x80).to_u8_wrap(),
				(cp.shr_zf_wrap(6).bitwise_and(0x3F)).bitwise_or(0x80).to_u8_wrap(),
				(cp.bitwise_and(0x3F)).bitwise_or(0x80).to_u8_wrap(),
			]
		}

	## The string for a byte range of `bytes`. Ranges always fall on character
	## boundaries of valid UTF-8, so the lossy conversion never substitutes.
	slice_str : List(U8), U64, U64 -> Str
	slice_str = |bytes, start, len| Str.from_utf8_lossy(bytes.sublist({ start, len }))
}

expect Bytes.space_len("\u(00A0)x".to_utf8(), 0) == 2
expect Bytes.space_len("x".to_utf8(), 0) == 0
expect Bytes.code_point("é".to_utf8(), 0) == 0xE9
expect Bytes.code_point("ﬂ".to_utf8(), 0) == 0xFB02
expect Bytes.encode(0xFB02) == "ﬂ".to_utf8()
expect Bytes.encode(0x1F600) == "😀".to_utf8()
expect Bytes.line_terminator_from("ab\u(2028)c".to_utf8(), 0) == 2
expect Bytes.last_newline_in_space_run(" \n \n x".to_utf8(), 0) == Some(3)
