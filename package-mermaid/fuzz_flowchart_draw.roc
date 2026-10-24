app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Drawing
import Flowchart
import FlowDraw
import FlowGeometry
import Svg

## The drawing contract on any diagram the reader accepts, with synthetic
## sizes and geometry: drawing is total and deterministic, every coordinate
## it produces is finite, and the SVG it writes is well-formed XML whatever
## the label text holds.
##
## The input is Mermaid text, then optionally a 0xFF byte and more bytes.
## Those bytes choose the geometry (boxes, routes with repeated and
## crossing points, label positions, missing entries) and replace label
## text with arbitrary bytes, including markup characters, quotes and
## control characters.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	split = split_at_marker(bytes)
	match Flowchart.parse(Str.from_utf8_lossy(split.source)) {
		Err(_) => Fuzz.reject
		Ok(parsed) => {
			diagram = relabel(parsed, split.extra)
			input = synthesize(diagram, split.extra)
			picture = FlowDraw.draw(diagram, input.sizes, input.geometry)
			if picture != FlowDraw.draw(diagram, input.sizes, input.geometry) {
				crash "drawing the same diagram twice gave different pictures"
			}
			if !Drawing.is_finite(picture) {
				crash "a drawing holds a coordinate that is not finite"
			}
			svg = Svg.document(picture, "Inter \"<&>\"")
			if svg != Svg.document(picture, "Inter \"<&>\"") {
				crash "writing the same picture twice gave different SVG"
			}
			match well_formed(svg.to_utf8()) {
				Ok({}) => Fuzz.keep
				Err(why) => crash "the SVG is not well-formed XML: ${why}"
			}
		}
	}
}

split_at_marker : List(U8) -> { source : List(U8), extra : List(U8) }
split_at_marker = |bytes| {
	var $i = 0
	while $i < bytes.len() and (bytes.get($i) ?? 0) != 0xFF {
		$i = $i + 1
	}
	{ source: bytes.take_first($i), extra: bytes.drop_first($i + 1) }
}

## The extra byte at `k`, cycling, or a fixed byte when there are none.
byte : List(U8), U64 -> U8
byte = |extra, k| if (extra.is_empty()) 7 else extra.get(k % extra.len()) ?? 7

## Replaces each label with a slice of the extra bytes (read as lossy
## UTF-8) when the first extra byte is odd.
relabel : Flowchart.Diagram, List(U8) -> Flowchart.Diagram
relabel = |diagram, extra|
	if byte(extra, 0) % 2 == 0 {
		diagram
	} else {
		text = |k| Str.from_utf8_lossy(extra.drop_first(k % (extra.len() + 1)).take_first(1 + byte(extra, k).to_u64() % 12))
		{
			..diagram,
			nodes: diagram.nodes.map_with_index(|n, k| { ..n, label: text(k * 3) }),
			edges: diagram.edges.map_with_index(|e, k| { ..e, label: text(k * 5 + 1) }),
			groups: diagram.groups.map_with_index(|g, k| { ..g, title: text(k * 7 + 2) }),
		}
	}

coordinate : List(U8), U64 -> F64
coordinate = |extra, k| (byte(extra, k).to_f64() - 100) * 6.5

block : Str, List(U8), U64 -> FlowGeometry.TextBlock
block = |label, extra, k| { lines: label.split_on("\n"), width: byte(extra, k).to_f64(), height: 17 }

## Sizes and geometry from the extra bytes. When the second extra byte is
## odd, the last node, edge and group have no entries.
synthesize : Flowchart.Diagram, List(U8) -> { sizes : FlowGeometry.Sizes, geometry : FlowGeometry.Geometry }
synthesize = |diagram, extra| {
	short = byte(extra, 1) % 2 == 1
	trim = |list| if (short) list.drop_last(1) else list
	rect = |k| { x: coordinate(extra, k), y: coordinate(extra, k + 1), width: byte(extra, k + 2).to_f64(), height: byte(extra, k + 3).to_f64() / 2 }
	route = |k| {
		count = byte(extra, k).to_u64() % 7
		var $points = []
		for j in 0..<count {
			# Every third byte repeats the previous point, so routes hold
			# empty segments too.
			if j > 0 and byte(extra, k + 1 + 2 * j) % 3 == 0 {
				$points = $points.append($points.last() ?? { x: 0, y: 0 })
			} else {
				$points = $points.append({ x: coordinate(extra, k + 1 + 2 * j), y: coordinate(extra, k + 2 + 2 * j) })
			}
		}
		$points
	}
	{
		sizes: {
			nodes: trim(diagram.nodes.map_with_index(|n, k| { width: 10, height: 10, label: block(n.label, extra, k) })),
			edge_labels: trim(
				diagram.edges.map_with_index(
					|e, k|
						if (e.label == "") None else Some(block(e.label, extra, k + 3)),
				),
			),
			group_titles: trim(diagram.groups.map_with_index(|g, k| block(g.title, extra, k + 5))),
		},
		geometry: {
			nodes: trim(diagram.nodes.map_with_index(|_, k| rect(k * 4 + 2))),
			edges: trim(
				diagram.edges.map_with_index(
					|_, k| {
						label = if (byte(extra, k + 9) % 4 == 0) None else Some({ x: coordinate(extra, k + 10), y: coordinate(extra, k + 11) })
						{ points: route(k * 9 + 3), label }
					},
				),
			),
			groups: trim(diagram.groups.map_with_index(|_, k| rect(k * 4 + 5))),
			bounds: rect(0),
		},
	}
}

## Whether text is well-formed XML of the shape `Svg` writes: balanced
## elements with quoted attributes, character data without raw `<` or bare
## `&`, only known entities, and no characters XML cannot hold.
well_formed : List(U8) -> Try({}, Str)
well_formed = |bytes| {
	var $stack = []
	var $i = 0
	var $error = Ok({})
	var $root_closed = False
	while $i < bytes.len() and $error == Ok({}) {
		c = bytes.get($i) ?? 0
		if c < 0x20 and c != '\n' {
			$error = Err("control character")
		} else if c == 0xEF and (bytes.get($i + 1) ?? 0) == 0xBF and (bytes.get($i + 2) ?? 0) >= 0xBE {
			$error = Err("U+FFFE or U+FFFF")
		} else if c == '&' {
			match entity_len(bytes, $i) {
				Ok(len) => {
					$i = $i + len - 1
				}
				Err(_) => {
					$error = Err("bare ampersand")
				}
			}
		} else if c == '>' {
			$error = Err("raw >")
		} else if c == '<' {
			if $root_closed {
				$error = Err("content after the root element")
			} else {
				tag = read_tag(bytes, $i)
				match tag {
					Err(why) => {
						$error = Err(why)
					}
					Ok(t) => {
						if t.closing {
							match $stack.last() {
								Ok(open) if open == t.name => {
									$stack = $stack.drop_last(1)
									if $stack.is_empty() {
										$root_closed = True
									}
								}
								_ => {
									$error = Err("unbalanced closing tag")
								}
							}
						} else if !t.empty {
							$stack = $stack.append(t.name)
						}
						$i = t.end - 1
					}
				}
			}
		} else if !$root_closed and $stack.is_empty() and c != '\n' and c != ' ' {
			$error = Err("text outside the root element")
		}
		$i = $i + 1
	}
	match $error {
		Err(why) => Err(why)
		Ok({}) => if ($stack.is_empty() and $root_closed) Ok({}) else Err("unclosed element")
	}
}

## Length of a known entity reference at `i`.
entity_len : List(U8), U64 -> Try(U64, [Unknown])
entity_len = |bytes, i| {
	known = ["&amp;", "&lt;", "&gt;", "&quot;", "&apos;"]
	found = known.find_first(|e| bytes.drop_first(i).take_first(e.to_utf8().len()) == e.to_utf8())
	match found {
		Ok(e) => Ok(e.to_utf8().len())
		Err(_) => Err(Unknown)
	}
}

## A start, end or empty-element tag at `i`: its name, and the index just
## past its `>`. Attribute values must be quoted and hold no `<` or bare `&`.
read_tag : List(U8), U64 -> Try({ name : List(U8), closing : Bool, empty : Bool, end : U64 }, Str)
read_tag = |bytes, start| {
	closing = (bytes.get(start + 1) ?? 0) == '/'
	var $i = if (closing) start + 2 else start + 1
	name_start = $i
	while $i < bytes.len() and is_name_byte(bytes.get($i) ?? 0) {
		$i = $i + 1
	}
	name = bytes.sublist({ start: name_start, len: $i - name_start })
	var $error = if (name.is_empty()) Err("tag without a name") else Ok({})
	var $done = False
	var $empty = False
	while !$done and $error == Ok({}) {
		c = bytes.get($i) ?? 0
		if $i >= bytes.len() {
			$error = Err("unterminated tag")
		} else if c == '>' {
			$done = True
			$i = $i + 1
		} else if c == '/' and (bytes.get($i + 1) ?? 0) == '>' and !closing {
			$done = True
			$empty = True
			$i = $i + 2
		} else if c == ' ' and !closing {
			$i = $i + 1
			attr_start = $i
			while $i < bytes.len() and is_name_byte(bytes.get($i) ?? 0) {
				$i = $i + 1
			}
			if $i == attr_start or (bytes.get($i) ?? 0) != '=' or (bytes.get($i + 1) ?? 0) != '"' {
				$error = Err("malformed attribute")
			} else {
				$i = $i + 2
				while $i < bytes.len() and (bytes.get($i) ?? 0) != '"' and $error == Ok({}) {
					v = bytes.get($i) ?? 0
					if v == '<' {
						$error = Err("< in an attribute value")
					} else if v == '&' {
						match entity_len(bytes, $i) {
							Ok(len) => {
								$i = $i + len - 1
							}
							Err(_) => {
								$error = Err("bare ampersand in an attribute value")
							}
						}
					} else if v < 0x20 {
						$error = Err("control character in an attribute value")
					}
					$i = $i + 1
				}
				if $i >= bytes.len() {
					$error = Err("unterminated attribute value")
				}
				$i = $i + 1
			}
		} else {
			$error = Err("unexpected byte in a tag")
		}
	}
	match $error {
		Err(why) => Err(why)
		Ok({}) => Ok({ name, closing, empty: $empty, end: $i })
	}
}

is_name_byte : U8 -> Bool
is_name_byte = |c| (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == ':'

target = Fuzz.target_with({
	name: "mermaid-flowchart-draw",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})

expect well_formed("<svg a=\"1\">\n<path d=\"M0 0\"/>\n<text>a &amp; b</text>\n</svg>\n".to_utf8()) == Ok({})
expect well_formed("<svg><text>a & b</text></svg>".to_utf8()) != Ok({})
expect well_formed("<svg><text>a</svg>".to_utf8()) != Ok({})

expect {
	_ = test("flowchart LR\n  A[\"x\"] -->|go| B{y}\n  subgraph S\n    C(((c))) -.-x D\n  end\n  A o--o C\n".to_utf8())
	True
}

## Label text with markup, quotes and control characters stays escaped.
expect {
	source = "flowchart TD\n  A --> B\n  A -- t --> C\n".to_utf8()
	extra = [1, 0, '<', '&', '"', '\'', 0, 0x1F, '>', 0xEF, 0xBF, 0xBF, 9, 200, 30, 40, 50]
	_ = test(source.append(0xFF).concat(extra))
	True
}
