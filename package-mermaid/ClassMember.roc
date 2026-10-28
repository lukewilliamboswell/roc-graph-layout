import EntityText

## Mermaid's class-member grammar and canonical display text, shared by
## actual rendering and the independent-oracle probe. Raw source remains in
## the public parsed model; classifier semantics are never inferred from pixels.
ClassMember :: {}.{
	Member : { visibility : Str, classifier : Str, id : Str, parameters : Str, return_type : Str, text : Str }

	parse : Str, Bool -> Member
	parse = |raw, method| {
		input = EntityText.trim(raw)
		bytes = input.to_utf8()
		first = bytes.first() ?? 0
		visibility = if first == '+' or first == '-' or first == '#' or first == '~' {
			Str.from_utf8_lossy([first])
		} else {
			""
		}
		body = if (visibility.is_empty()) input else Str.from_utf8_lossy(bytes.drop_first(1))
		var $classifier = ""
		var $id = body
		var $parameters = ""
		var $return = ""
		if method {
			match EntityText.split(body, "(") {
				Missing => {}
				Found(name, rest) => {
					$id = name
					parts = rest.split_on(")")
					$parameters = EntityText.trim(Str.join_with(parts.drop_last(1), ")"))
					tail = parts.last() ?? ""
					head = tail.to_utf8().first() ?? 0
					if head == '$' or head == '*' {
						$classifier = Str.from_utf8_lossy([head])
						$return = EntityText.trim(Str.from_utf8_lossy(tail.to_utf8().drop_first(1)))
					} else {
						$return = EntityText.trim(tail)
						last = $return.to_utf8().last() ?? 0
						if last == '$' or last == '*' {
							$classifier = Str.from_utf8_lossy([last])
							$return = EntityText.trim(Str.from_utf8_lossy($return.to_utf8().drop_last(1)))
						}
					}
				}
			}
		} else {
			last = body.to_utf8().last() ?? 0
			if last == '$' or last == '*' {
				$classifier = Str.from_utf8_lossy([last])
				$id = Str.from_utf8_lossy(body.to_utf8().drop_last(1))
			}
		}
		id = if ($id.starts_with(" ")) " ${EntityText.trim($id)}" else EntityText.trim($id)
		suffix = if method {
			result = if ($return.is_empty()) "" else " : ${ClassMember.generic($return)}"
			"(${ClassMember.generic($parameters)})${result}"
		} else {
			""
		}
		{ visibility, classifier: $classifier, id, parameters: $parameters, return_type: $return, text: "${visibility}${ClassMember.generic(id)}${suffix}" }
	}

	generic : Str -> Str
	generic = |text| {
		parts = text.split_on("~")
		var $out = ""
		for i in 0..<parts.len() {
			if i > 0 {
				$out = $out.concat(if (i % 2 == 1) "<" else ">")
			}
			$out = $out.concat(parts.get(i) ?? "")
		}
		$out
	}

	class_name : Str -> { id : Str, generic_type : Str }
	class_name = |raw| {
		parts = raw.split_on("~")
		{ id: parts.first() ?? raw, generic_type: if (parts.len() >= 3) Str.join_with(parts.drop_first(1).drop_last(1), "~") else "" }
	}
}

expect ClassMember.parse("+authorize() bool", True) == { visibility: "+", classifier: "", id: "authorize", parameters: "", return_type: "bool", text: "+authorize() : bool" }
expect ClassMember.parse("+get()* Result", True).classifier == "*"
expect ClassMember.parse("+String id$", False).text == "+String id"
