import Drawing

## Internal JSON vocabulary for native oracle probes, never exported by the
## package. Numbers remain numbers; a non-finite observation is explicit.
OracleJson :: {}.{
	string : Str -> Str
	string = |text| {
		hex = |n| if n < 10 {
			'0' + n
		} else {
			'a' + n - 10
		}
		var $out = ['"']
		for b in text.to_utf8() {
			$out = if b == '"' or b == '\\' {
				$out.append('\\').append(b)
			} else if b < 32 {
				$out.concat(['\\', 'u', '0', '0', hex(b // 16), hex(b % 16)])
			} else {
				$out.append(b)
			}
		}
		Str.from_utf8_lossy($out.append('"'))
	}
	number : F64 -> Str
	number = |value| if F64.is_finite(value) {
		value.to_str()
	} else {
		"null"
	}
	boolean : Bool -> Str
	boolean = |value| if value {
		"true"
	} else {
		"false"
	}
	array : List(Str) -> Str
	array = |values| "[${Str.join_with(values, ",")}]"
	object : List((Str, Str)) -> Str
	object = |fields| "{${Str.join_with(fields.map(|pair| "${OracleJson.string(pair.0)}:${pair.1}"), ",")}}"
	point : Drawing.Point -> Str
	point = |p| OracleJson.object([("x", OracleJson.number(p.x)), ("y", OracleJson.number(p.y))])
	rect : Drawing.Rect -> Str
	rect = |r| OracleJson.object([("x", OracleJson.number(r.x)), ("y", OracleJson.number(r.y)), ("width", OracleJson.number(r.width)), ("height", OracleJson.number(r.height))])
	strings : List(Str) -> Str
	strings = |values| OracleJson.array(values.map(OracleJson.string))
	rejected : Str -> Str
	rejected = |family| OracleJson.object([("family", OracleJson.string(family)), ("accepted", "false")])
}

expect OracleJson.string("a\n\t\"\\") == "\"a\\u000a\\u0009\\\"\\\\\""
