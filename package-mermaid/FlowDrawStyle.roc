import Drawing
import Flowchart

## The parts of CSS a flowchart's `classDef`, `class`, `style` and
## `linkStyle` statements can set that a drawing can show: fill and stroke
## colours, stroke width, and text colour. Other properties (dashes,
## opacity, fonts, ...) are ignored, as are values this reader does not
## understand.
FlowDrawStyle :: {}.{

	## What the declarations set; `Keep` leaves the theme's value. A fill or
	## stroke of `none` removes it.
	Overrides : {
		fill : [Keep, Paint(Drawing.Color), Remove],
		stroke : [Keep, Paint(Drawing.Color), Remove],
		stroke_width : [Keep, Width(F64)],
		color : [Keep, Paint(Drawing.Color)],
	}

	none : Overrides
	none = { fill: Keep, stroke: Keep, stroke_width: Keep, color: Keep }

	## The overrides from a node's, edge's or group's class names and its own
	## declarations: first the `default` class when `with_default` is set and
	## the diagram defines one, then each named class in order, then the
	## element's own declarations, later ones winning.
	resolve : List(Flowchart.ClassDef), List(Str), List(Str), Bool -> Overrides
	resolve = |class_defs, classes, styles, with_default| {
		var $o = FlowDrawStyle.none
		if with_default {
			for def in class_defs {
				if def.name == "default" {
					$o = FlowDrawStyle.apply($o, def.styles)
				}
			}
		}
		for name in classes {
			for def in class_defs {
				if def.name == name {
					$o = FlowDrawStyle.apply($o, def.styles)
				}
			}
		}
		FlowDrawStyle.apply($o, styles)
	}

	## Applies declarations such as `fill:#f96` or `stroke-width: 4px`, each
	## of which may hold several separated by `;`.
	apply : Overrides, List(Str) -> Overrides
	apply = |start, declarations| {
		var $o = start
		for text in declarations {
			for declaration in text.split_on(";") {
				$o = FlowDrawStyle.declare($o, declaration)
			}
		}
		$o
	}

	declare : Overrides, Str -> Overrides
	declare = |o, declaration| {
		bytes = declaration.to_utf8()
		match FlowDrawStyle.index_of(bytes, ':') {
			Err(_) => o
			Ok(colon) => {
				name = FlowDrawStyle.lower(FlowDrawStyle.trim(bytes.take_first(colon)))
				raw = FlowDrawStyle.lower(FlowDrawStyle.trim(bytes.drop_first(colon + 1)))
				value = FlowDrawStyle.trim(FlowDrawStyle.strip_important(raw))
				if name == "fill".to_utf8() {
					if value == "none".to_utf8() or value == "transparent".to_utf8() {
						{ ..o, fill: Remove }
					} else {
						match FlowDrawStyle.color(value) {
							Ok(c) => { ..o, fill: Paint(c) }
							Err(_) => o
						}
					}
				} else if name == "stroke".to_utf8() {
					if value == "none".to_utf8() or value == "transparent".to_utf8() {
						{ ..o, stroke: Remove }
					} else {
						match FlowDrawStyle.color(value) {
							Ok(c) => { ..o, stroke: Paint(c) }
							Err(_) => o
						}
					}
				} else if name == "stroke-width".to_utf8() {
					match FlowDrawStyle.length(value) {
						Ok(w) => { ..o, stroke_width: Width(w) }
						Err(_) => o
					}
				} else if name == "color".to_utf8() {
					match FlowDrawStyle.color(value) {
						Ok(c) => { ..o, color: Paint(c) }
						Err(_) => o
					}
				} else {
					o
				}
			}
		}
	}

	## A CSS colour: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa` (alpha ignored),
	## `rgb(r, g, b)` or `rgba(r, g, b, a)` with numbers 0 to 255, or one of
	## the common colour names. Expects lower case.
	color : List(U8) -> Try(Drawing.Color, [NotAColor])
	color = |value|
		match value {
			['#', .. as digits] => FlowDrawStyle.hex_color(digits)
			['r', 'g', 'b', 'a', '(', .. as rest] => FlowDrawStyle.rgb_function(rest)
			['r', 'g', 'b', '(', .. as rest] => FlowDrawStyle.rgb_function(rest)
			_ => FlowDrawStyle.named(value)
		}

	hex_color : List(U8) -> Try(Drawing.Color, [NotAColor])
	hex_color = |digits| {
		nibble = |i| FlowDrawStyle.hex_digit(digits.get(i) ?? 'x')
		short = |i| match nibble(i) {
			Ok(v) => Ok(v * 17)
			Err(e) => Err(e)
		}
		long = |i| match (nibble(i), nibble(i + 1)) {
			(Ok(h), Ok(l)) => Ok(h * 16 + l)
			_ => Err(NotAColor)
		}
		if digits.len() == 3 or digits.len() == 4 {
			match (short(0), short(1), short(2)) {
				(Ok(r), Ok(g), Ok(b)) => Ok({ red: r, green: g, blue: b })
				_ => Err(NotAColor)
			}
		} else if digits.len() == 6 or digits.len() == 8 {
			match (long(0), long(2), long(4)) {
				(Ok(r), Ok(g), Ok(b)) => Ok({ red: r, green: g, blue: b })
				_ => Err(NotAColor)
			}
		} else {
			Err(NotAColor)
		}
	}

	hex_digit : U8 -> Try(U8, [NotAColor])
	hex_digit = |c|
		if c >= '0' and c <= '9' {
			Ok(c - '0')
		} else if c >= 'a' and c <= 'f' {
			Ok(c - 'a' + 10)
		} else {
			Err(NotAColor)
		}

	## The arguments of `rgb(` up to `)`: three whole numbers, clamped to 255.
	rgb_function : List(U8) -> Try(Drawing.Color, [NotAColor])
	rgb_function = |rest| {
		var $parts = []
		var $current = []
		var $closed = False
		for c in rest {
			if !$closed {
				if c == ')' {
					$closed = True
				} else if c == ',' or c == ' ' or c == '/' {
					if !$current.is_empty() {
						$parts = $parts.append($current)
						$current = []
					}
				} else {
					$current = $current.append(c)
				}
			}
		}
		if !$current.is_empty() {
			$parts = $parts.append($current)
		}
		channel = |i| FlowDrawStyle.channel($parts.get(i) ?? [])
		if $closed and ($parts.len() == 3 or $parts.len() == 4) {
			match (channel(0), channel(1), channel(2)) {
				(Ok(r), Ok(g), Ok(b)) => Ok({ red: r, green: g, blue: b })
				_ => Err(NotAColor)
			}
		} else {
			Err(NotAColor)
		}
	}

	## A whole number 0 to 255 (larger values clamp to 255).
	channel : List(U8) -> Try(U8, [NotAColor])
	channel = |digits|
		if digits.is_empty() or digits.len() > 6 or !digits.all(|c| c >= '0' and c <= '9') {
			Err(NotAColor)
		} else {
			value : U32
			value = digits.fold(0, |acc, c| acc * 10 + (c - '0').to_u32())
			Ok(if (value > 255) 255 else value.to_u8_wrap())
		}

	named : List(U8) -> Try(Drawing.Color, [NotAColor])
	named = |value| {
		name = Str.from_utf8_lossy(value)
		found = FlowDrawStyle.names.find_first(|entry| entry.0 == name)
		match found {
			Ok(entry) => Ok(Drawing.rgb(entry.1))
			Err(_) => Err(NotAColor)
		}
	}

	## CSS colour names Mermaid diagrams commonly use.
	names : List((Str, U32))
	names = [
		("black", 0x000000),
		("white", 0xFFFFFF),
		("red", 0xFF0000),
		("green", 0x008000),
		("blue", 0x0000FF),
		("yellow", 0xFFFF00),
		("orange", 0xFFA500),
		("purple", 0x800080),
		("gray", 0x808080),
		("grey", 0x808080),
		("pink", 0xFFC0CB),
		("brown", 0xA52A2A),
		("cyan", 0x00FFFF),
		("aqua", 0x00FFFF),
		("magenta", 0xFF00FF),
		("fuchsia", 0xFF00FF),
		("lime", 0x00FF00),
		("navy", 0x000080),
		("teal", 0x008080),
		("olive", 0x808000),
		("maroon", 0x800000),
		("silver", 0xC0C0C0),
		("gold", 0xFFD700),
		("coral", 0xFF7F50),
		("salmon", 0xFA8072),
		("tomato", 0xFF6347),
		("violet", 0xEE82EE),
		("indigo", 0x4B0082),
		("beige", 0xF5F5DC),
		("khaki", 0xF0E68C),
		("lightgray", 0xD3D3D3),
		("lightgrey", 0xD3D3D3),
		("darkgray", 0xA9A9A9),
		("darkgrey", 0xA9A9A9),
		("lightblue", 0xADD8E6),
		("lightgreen", 0x90EE90),
		("lightyellow", 0xFFFFE0),
		("darkblue", 0x00008B),
		("darkgreen", 0x006400),
		("darkred", 0x8B0000),
		("orangered", 0xFF4500),
		("steelblue", 0x4682B4),
		("skyblue", 0x87CEEB),
		("whitesmoke", 0xF5F5F5),
	]

	## A length in pixels: a number with an optional `px` unit.
	length : List(U8) -> Try(F64, [NotALength])
	length = |value| {
		digits = match value {
			[.. as head, 'p', 'x'] => FlowDrawStyle.trim(head)
			_ => value
		}
		var $whole = 0.0
		var $fraction = 0.0
		var $scale = 1.0
		var $seen_point = False
		var $ok = !digits.is_empty() and digits.len() < 12
		for c in digits {
			if c >= '0' and c <= '9' {
				d = (c - '0').to_f64()
				if $seen_point {
					$scale = $scale / 10
					$fraction = $fraction + d * $scale
				} else {
					$whole = $whole * 10 + d
				}
			} else if c == '.' and !$seen_point {
				$seen_point = True
			} else {
				$ok = False
			}
		}
		if ($ok) Ok($whole + $fraction) else Err(NotALength)
	}

	index_of : List(U8), U8 -> Try(U64, [NotFound])
	index_of = |bytes, target| {
		var $i = 0
		var $found = Err(NotFound)
		while $i < bytes.len() and $found == Err(NotFound) {
			if (bytes.get($i) ?? 0) == target {
				$found = Ok($i)
			}
			$i = $i + 1
		}
		$found
	}

	trim : List(U8) -> List(U8)
	trim = |bytes| {
		space = |c| c == ' ' or c == '\t' or c == '\n' or c == '\r'
		var $start = 0
		while $start < bytes.len() and space(bytes.get($start) ?? 'x') {
			$start = $start + 1
		}
		var $end = bytes.len()
		while $end > $start and space(bytes.get($end - 1) ?? 'x') {
			$end = $end - 1
		}
		bytes.sublist({ start: $start, len: $end - $start })
	}

	lower : List(U8) -> List(U8)
	lower = |bytes| bytes.map(|c| if (c >= 'A' and c <= 'Z') c + 32 else c)

	strip_important : List(U8) -> List(U8)
	strip_important = |value| {
		marker = "!important".to_utf8()
		if value.len() >= marker.len() and value.drop_first(value.len() - marker.len()) == marker {
			value.take_first(value.len() - marker.len())
		} else {
			value
		}
	}
}

expect FlowDrawStyle.color("#f96".to_utf8()) == Ok({ red: 0xFF, green: 0x99, blue: 0x66 })
expect FlowDrawStyle.color("#28253d".to_utf8()) == Ok({ red: 0x28, green: 0x25, blue: 0x3D })
expect FlowDrawStyle.color("rgb(1, 2, 300)".to_utf8()) == Ok({ red: 1, green: 2, blue: 255 })
expect FlowDrawStyle.color("blue".to_utf8()) == Ok({ red: 0, green: 0, blue: 255 })
expect FlowDrawStyle.color("#ggg".to_utf8()) == Err(NotAColor)
expect FlowDrawStyle.length("4px".to_utf8()) == Ok(4)
expect FlowDrawStyle.length("2.5".to_utf8()) == Ok(2.5)
expect FlowDrawStyle.length("4em".to_utf8()) == Err(NotALength)

expect
	FlowDrawStyle.resolve(
		[{ name: "hot", styles: ["fill:#f96", "stroke:#333"] }, { name: "default", styles: ["fill:#eee"] }],
		["hot"],
		["stroke-width: 4px !important", "color:red", "fill:none;stroke:NONE"],
		True,
	)
		== { fill: Remove, stroke: Remove, stroke_width: Width(4), color: Paint({ red: 255, green: 0, blue: 0 }) }

expect FlowDrawStyle.resolve([{ name: "default", styles: ["fill:#eee"] }], [], [], True).fill == Paint({ red: 0xEE, green: 0xEE, blue: 0xEE })
expect FlowDrawStyle.resolve([{ name: "default", styles: ["fill:#eee"] }], [], [], False).fill == Keep
