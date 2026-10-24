## A JSON value that keeps every field, for the benchmark cases and samples.
##
## Case files must be checked for unknown and missing fields, and a sample
## row is the benchmark's own output with fields added, so neither fits a
## fixed record. Numbers keep the text they were written with.
BenchJson := [].{

	Value := [Null, Bool(Bool), Num(Str), Text(Str), Arr(List(Value)), Obj(List((Str, Value)))].{
		is_eq : _
	}

	## Read one JSON value, allowing surrounding whitespace.
	parse : Str -> Try(Value, [InvalidJson(Str)])
	parse = |text| {
		bytes = Str.to_utf8(text)
		{ value, next } = value_at(bytes, skip_space(bytes, 0))?
		end = skip_space(bytes, next)
		if (end == bytes.len()) Ok(value) else Err(InvalidJson("extra data at byte ${end.to_str()}"))
	}

	## The value as `json.dumps(value, sort_keys=True)` writes it: keys in
	## order, `, ` and `: ` between items, and every character outside ASCII
	## escaped.
	render : Value -> Str
	render = |value|
		match value {
			Null => "null"
			Bool(b) => if (b) "true" else "false"
			Num(raw) => raw
			Text(s) => quote(s)
			Arr(items) => "[${Str.join_with(items.map(BenchJson.render), ", ")}]"
			Obj(fields) => {
				sorted = List.sort_with(fields, |(a, _), (b, _)| compare_bytes(Str.to_utf8(a), Str.to_utf8(b)))
				"{${Str.join_with(sorted.map(|(key, item)| "${quote(key)}: ${BenchJson.render(item)}"), ", ")}}"
			}
		}

	## The field `key` of an object; the last one when it repeats.
	get : Value, Str -> Try(Value, [Missing])
	get = |value, key|
		match value {
			Obj(fields) => fields.keep_if(|(name, _)| name == key).last().map_ok(|(_, item)| item).map_err(|_| Missing)
			_ => Err(Missing)
		}

	## The object with `key` set to `item`, replacing an existing field.
	set : Value, Str, Value -> Value
	set = |value, key, item|
		match value {
			Obj(fields) =>
				if fields.any(|(name, _)| name == key) {
					Obj(fields.map(|(name, old)| if (name == key) (name, item) else (name, old)))
				} else {
					Obj(fields.append((key, item)))
				}
			other => other
		}

	## The field names of an object, in order.
	keys : Value -> List(Str)
	keys = |value|
		match value {
			Obj(fields) => fields.map(|(name, _)| name)
			_ => []
		}

	## The field `key` when it is a string.
	text : Value, Str -> Try(Str, [Missing, NotText(Str)])
	text = |value, key|
		match BenchJson.get(value, key)? {
			Text(s) => Ok(s)
			_ => Err(NotText(key))
		}

	## The field `key` when it is a non-negative integer.
	count : Value, Str -> Try(U64, [Missing, NotCount(Str)])
	count = |value, key|
		match BenchJson.get(value, key)? {
			Num(raw) => U64.from_str(raw).map_err(|_| NotCount(key))
			_ => Err(NotCount(key))
		}

	## The field `key` as a number of seconds, possibly fractional, in
	## milliseconds.
	millis : Value, Str -> Try(U64, [Missing, NotSeconds(Str)])
	millis = |value, key|
		match BenchJson.get(value, key)? {
			Num(raw) =>
				match Str.split_first(raw, ".") {
					Err(_) => U64.from_str(raw).map_ok(|s| s * 1000).map_err(|_| NotSeconds(key))
					Ok({ before, after }) => {
						whole = U64.from_str(before).map_err(|_| NotSeconds(key))?
						digits = Str.to_utf8(after).take_first(3)
						fraction = U64.from_str(Str.concat(Str.from_utf8_lossy(digits), Str.repeat("0", 3 - digits.len()))).map_err(|_| NotSeconds(key))?
						Ok(whole * 1000 + fraction)
					}
				}
			_ => Err(NotSeconds(key))
		}

	## Whether Python would read the value as true: anything but null, false,
	## zero, and empty text, lists and objects.
	is_truthy : Value -> Bool
	is_truthy = |value|
		match value {
			Null => Bool.False
			Bool(b) => b
			Num(raw) => Str.to_utf8(raw).any(|byte| byte >= '1' and byte <= '9')
			Text(s) => s != ""
			Arr(items) => !items.is_empty()
			Obj(fields) => !fields.is_empty()
		}
}

value_at : List(U8), U64 -> Try({ value : BenchJson.Value, next : U64 }, [InvalidJson(Str)])
value_at = |bytes, at|
	match bytes.get(at) {
		Ok('{') => object_at(bytes, skip_space(bytes, at + 1), [])
		Ok('[') => array_at(bytes, skip_space(bytes, at + 1), [])
		Ok('"') => {
			{ text, next } = string_at(bytes, at + 1)?
			Ok({ value: Text(text), next })
		}
		Ok('t') => literal(bytes, at, "true", Bool(Bool.True))
		Ok('f') => literal(bytes, at, "false", Bool(Bool.False))
		Ok('n') => literal(bytes, at, "null", Null)
		Ok(byte) if byte == '-' or (byte >= '0' and byte <= '9') => number_at(bytes, at)
		_ => Err(InvalidJson("expected a value at byte ${at.to_str()}"))
	}

literal : List(U8), U64, Str, BenchJson.Value -> Try({ value : BenchJson.Value, next : U64 }, [InvalidJson(Str)])
literal = |bytes, at, word, value| {
	expected = Str.to_utf8(word)
	if bytes.sublist({ start: at, len: expected.len() }) == expected {
		Ok({ value, next: at + expected.len() })
	} else {
		Err(InvalidJson("expected ${word} at byte ${at.to_str()}"))
	}
}

number_at : List(U8), U64 -> Try({ value : BenchJson.Value, next : U64 }, [InvalidJson(Str)])
number_at = |bytes, at| {
	var $end = at
	for byte in bytes.drop_first(at) {
		if (byte >= '0' and byte <= '9') or byte == '-' or byte == '+' or byte == '.' or byte == 'e' or byte == 'E' {
			$end = $end + 1
		} else {
			break
		}
	}
	raw = Str.from_utf8_lossy(bytes.sublist({ start: at, len: $end - at }))
	if valid_number(Str.to_utf8(raw)) {
		Ok({ value: Num(raw), next: $end })
	} else {
		Err(InvalidJson("invalid number ${raw}"))
	}
}

# -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
valid_number : List(U8) -> Bool
valid_number = |bytes| {
	unsigned = match bytes {
		['-', .. as rest] => rest
		_ => bytes
	}
	{ integer, rest } = digits(unsigned)
	integer_ok = match integer {
		['0'] => Bool.True
		[first, ..] => first != '0'
		[] => Bool.False
	}
	{ after_fraction, fraction_ok } = match rest {
		['.', .. as tail] => {
			{ integer: fraction, rest: after } = digits(tail)
			{ after_fraction: after, fraction_ok: !fraction.is_empty() }
		}
		_ => { after_fraction: rest, fraction_ok: Bool.True }
	}
	exponent_ok = match after_fraction {
		[] => Bool.True
		[e, .. as tail] if e == 'e' or e == 'E' => {
			signless = match tail {
				[s, .. as more] if s == '+' or s == '-' => more
				_ => tail
			}
			{ integer: power, rest: left } = digits(signless)
			!power.is_empty() and left.is_empty()
		}
		_ => Bool.False
	}
	integer_ok and fraction_ok and exponent_ok
}

digits : List(U8) -> { integer : List(U8), rest : List(U8) }
digits = |bytes| {
	var $count = 0
	for byte in bytes {
		if byte >= '0' and byte <= '9' {
			$count = $count + 1
		} else {
			break
		}
	}
	count = $count
	{ integer: bytes.take_first(count), rest: bytes.drop_first(count) }
}

string_at : List(U8), U64 -> Try({ text : Str, next : U64 }, [InvalidJson(Str)])
string_at = |bytes, start| {
	var $out = []
	var $at = start
	var $done = Bool.False
	while !$done {
		match bytes.get($at) {
			Ok('"') => {
				$done = Bool.True
				$at = $at + 1
			}
			Ok('\\') => {
				escaped = escape_at(bytes, $at + 1)?
				$out = $out.concat(escaped.bytes)
				$at = escaped.next
			}
			Ok(byte) if byte < 0x20 => return Err(InvalidJson("control character in a string at byte ${$at.to_str()}"))
			Ok(byte) => {
				$out = $out.append(byte)
				$at = $at + 1
			}
			Err(_) => return Err(InvalidJson("unterminated string"))
		}
	}
	match Str.from_utf8($out) {
		Ok(text) => Ok({ text, next: $at })
		Err(_) => Err(InvalidJson("a string is not UTF-8"))
	}
}

escape_at : List(U8), U64 -> Try({ bytes : List(U8), next : U64 }, [InvalidJson(Str)])
escape_at = |bytes, at|
	match bytes.get(at) {
		Ok('"') => Ok({ bytes: ['"'], next: at + 1 })
		Ok('\\') => Ok({ bytes: ['\\'], next: at + 1 })
		Ok('/') => Ok({ bytes: ['/'], next: at + 1 })
		Ok('b') => Ok({ bytes: [8], next: at + 1 })
		Ok('f') => Ok({ bytes: [12], next: at + 1 })
		Ok('n') => Ok({ bytes: [10], next: at + 1 })
		Ok('r') => Ok({ bytes: [13], next: at + 1 })
		Ok('t') => Ok({ bytes: [9], next: at + 1 })
		Ok('u') => {
			high = hex4(bytes, at + 1)?
			if high >= 0xD800 and high < 0xDC00 and bytes.sublist({ start: at + 5, len: 2 }) == ['\\', 'u'] {
				low = hex4(bytes, at + 7)?
				if low >= 0xDC00 and low < 0xE000 {
					Ok({ bytes: utf8(0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)), next: at + 11 })
				} else {
					Ok({ bytes: utf8(0xFFFD), next: at + 5 })
				}
			} else if high >= 0xD800 and high < 0xE000 {
				Ok({ bytes: utf8(0xFFFD), next: at + 5 })
			} else {
				Ok({ bytes: utf8(high), next: at + 5 })
			}
		}
		_ => Err(InvalidJson("invalid escape at byte ${at.to_str()}"))
	}

hex4 : List(U8), U64 -> Try(U32, [InvalidJson(Str)])
hex4 = |bytes, at| {
	var $value = 0.U32
	for byte in bytes.sublist({ start: at, len: 4 }) {
		d = if byte >= '0' and byte <= '9' {
			byte - '0'
		} else if byte >= 'a' and byte <= 'f' {
			byte - 'a' + 10
		} else if byte >= 'A' and byte <= 'F' {
			byte - 'A' + 10
		} else {
			return Err(InvalidJson("invalid \\u escape at byte ${at.to_str()}"))
		}
		$value = $value * 16 + d.to_u32()
	}
	if (bytes.len() >= at + 4) Ok($value) else Err(InvalidJson("truncated \\u escape"))
}

utf8 : U32 -> List(U8)
utf8 = |cp|
	if cp < 0x80 {
		[cp.to_u8_wrap()]
	} else if cp < 0x800 {
		[(0xC0 + cp.shr_zf_wrap(6)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
	} else if cp < 0x10000 {
		[(0xE0 + cp.shr_zf_wrap(12)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
	} else {
		[(0xF0 + cp.shr_zf_wrap(18)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(12).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.shr_zf_wrap(6).bitwise_and(0x3F)).to_u8_wrap(), (0x80 + cp.bitwise_and(0x3F)).to_u8_wrap()]
	}

array_at : List(U8), U64, List(BenchJson.Value) -> Try({ value : BenchJson.Value, next : U64 }, [InvalidJson(Str)])
array_at = |bytes, at, items|
	match bytes.get(at) {
		Ok(']') if items.is_empty() => Ok({ value: Arr(items), next: at + 1 })
		_ => {
			{ value, next } = value_at(bytes, at)?
			after = skip_space(bytes, next)
			match bytes.get(after) {
				Ok(',') => array_at(bytes, skip_space(bytes, after + 1), items.append(value))
				Ok(']') => Ok({ value: Arr(items.append(value)), next: after + 1 })
				_ => Err(InvalidJson("expected , or ] at byte ${after.to_str()}"))
			}
		}
	}

object_at : List(U8), U64, List((Str, BenchJson.Value)) -> Try({ value : BenchJson.Value, next : U64 }, [InvalidJson(Str)])
object_at = |bytes, at, fields|
	match bytes.get(at) {
		Ok('}') if fields.is_empty() => Ok({ value: Obj(fields), next: at + 1 })
		Ok('"') => {
			{ text: key, next: after_key } = string_at(bytes, at + 1)?
			colon = skip_space(bytes, after_key)
			if bytes.get(colon) != Ok(':') {
				return Err(InvalidJson("expected : at byte ${colon.to_str()}"))
			}
			{ value, next } = value_at(bytes, skip_space(bytes, colon + 1))?
			after = skip_space(bytes, next)
			match bytes.get(after) {
				Ok(',') => object_at(bytes, skip_space(bytes, after + 1), fields.append((key, value)))
				Ok('}') => Ok({ value: Obj(fields.append((key, value))), next: after + 1 })
				_ => Err(InvalidJson("expected , or } at byte ${after.to_str()}"))
			}
		}
		_ => Err(InvalidJson("expected a field name at byte ${at.to_str()}"))
	}

skip_space : List(U8), U64 -> U64
skip_space = |bytes, at|
	match bytes.get(at) {
		Ok(byte) if byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' => skip_space(bytes, at + 1)
		_ => at
	}

# A JSON string with every character outside printable ASCII escaped, as
# Python's `ensure_ascii` writes it.
quote : Str -> Str
quote = |s| {
	var $out = ['"']
	for cp in code_points(Str.to_utf8(s)) {
		$out = $out.concat(
			if cp == '"'.to_u32() {
				Str.to_utf8("\\\"")
			} else if cp == '\\'.to_u32() {
				Str.to_utf8("\\\\")
			} else if cp == 10 {
				Str.to_utf8("\\n")
			} else if cp == 13 {
				Str.to_utf8("\\r")
			} else if cp == 9 {
				Str.to_utf8("\\t")
			} else if cp == 8 {
				Str.to_utf8("\\b")
			} else if cp == 12 {
				Str.to_utf8("\\f")
			} else if cp < 0x20 or cp > 0x7E {
				if cp == 0x7F {
					[0x7F]
				} else if cp >= 0x10000 {
					v = cp - 0x10000
					Str.to_utf8("${hex_escape(0xD800 + v.shr_zf_wrap(10))}${hex_escape(0xDC00 + v.bitwise_and(0x3FF))}")
				} else {
					Str.to_utf8(hex_escape(cp))
				}
			} else {
				[cp.to_u8_wrap()]
			},
		)
	}
	Str.from_utf8_lossy($out.append('"'))
}

hex_escape : U32 -> Str
hex_escape = |cp| {
	hex = Str.to_utf8("0123456789abcdef")
	nibble = |shift| hex.get(cp.shr_zf_wrap(shift).bitwise_and(0xF).to_u64()) ?? '0'
	Str.from_utf8_lossy(['\\', 'u', nibble(12), nibble(8), nibble(4), nibble(0)])
}

# Decode valid UTF-8 into code points.
code_points : List(U8) -> List(U32)
code_points = |bytes| {
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		b0 = (bytes.get($at) ?? 0).to_u32()
		cont = |i| (bytes.get($at + i) ?? 0x80).to_u32().bitwise_and(0x3F)
		if b0 < 0x80 {
			$out = $out.append(b0)
			$at = $at + 1
		} else if b0 < 0xE0 {
			$out = $out.append(b0.bitwise_and(0x1F).shl_wrap(6) + cont(1))
			$at = $at + 2
		} else if b0 < 0xF0 {
			$out = $out.append(b0.bitwise_and(0x0F).shl_wrap(12) + cont(1).shl_wrap(6) + cont(2))
			$at = $at + 3
		} else {
			$out = $out.append(b0.bitwise_and(0x07).shl_wrap(18) + cont(1).shl_wrap(12) + cont(2).shl_wrap(6) + cont(3))
			$at = $at + 4
		}
	}
	$out
}

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |left, right|
	match (left, right) {
		([a, .. as left_rest], [b, .. as right_rest]) =>
			if (a < b) Before else if (a > b) After else compare_bytes(left_rest, right_rest)
		([], []) => Same
		([], _) => Before
		(_, []) => After
	}

sample = "{\"b\":[1,true,null],\"a\":\"x\\\"y\",\"c\":{}}"

expect BenchJson.parse(sample) == Ok(Obj([("b", Arr([Num("1"), Bool(Bool.True), Null])), ("a", Text("x\"y")), ("c", Obj([]))]))
expect BenchJson.parse(sample).map_ok(BenchJson.render) == Ok("{\"a\": \"x\\\"y\", \"b\": [1, true, null], \"c\": {}}")
expect BenchJson.parse(" [ -1.5e3 , 0 ] ") == Ok(Arr([Num("-1.5e3"), Num("0")]))
expect BenchJson.parse("[01]").is_err() and BenchJson.parse("[1,]").is_err() and BenchJson.parse("{} x").is_err() and BenchJson.parse("").is_err()
expect BenchJson.parse("\"\\u00e9\\ud83d\\ude00\"") == Ok(Text("é😀"))
expect BenchJson.render(Text("é😀\n\u(7f)")) == "\"\\u00e9\\ud83d\\ude00\\n\u(7f)\""
expect BenchJson.render(Obj([])) == "{}" and BenchJson.render(Arr([])) == "[]"
expect BenchJson.get(Obj([("a", Num("1")), ("a", Num("2"))]), "a") == Ok(Num("2"))
expect BenchJson.set(Obj([("a", Num("1"))]), "a", Null) == Obj([("a", Null)])
expect BenchJson.set(Obj([("a", Num("1"))]), "b", Null) == Obj([("a", Num("1")), ("b", Null)])
expect BenchJson.millis(Obj([("t", Num("30"))]), "t") == Ok(30000) and BenchJson.millis(Obj([("t", Num("0.25"))]), "t") == Ok(250)
expect !BenchJson.is_truthy(Obj([])) and !BenchJson.is_truthy(Num("0.0")) and BenchJson.is_truthy(Obj([("k", Null)]))
