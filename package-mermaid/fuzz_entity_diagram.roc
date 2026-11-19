app [target] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.2/3JcFLxX7P572R7BwYN1rNMm8kZh6HQnrVQL1oXetMmMX.tar.zst",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
	layout: "../package/main.roc",
}
import fuzz.Fuzz
import EntityRelationship
import Drawing
import Theme
import Svg

## Arbitrary input and generated valid diagrams exercise parsing, source
## alignment, finite geometry, escaping and deterministic native drawing.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	source = if (bytes.first() ?? 0) % 2 == 0 {
		generate(bytes)
	} else {
		Str.from_utf8_lossy(bytes)
	}
	parsed = EntityRelationship.parse(source)
	if parsed != EntityRelationship.parse(source) {
		crash "parsing is not deterministic"
	}
	match parsed {
		Err([]) => crash "rejected without an explanation"
		Err(_) => Fuzz.keep
		Ok(diagram) => {
			count = diagram.entities.len()
			if !diagram.relationships.all(|r| r.from < count and r.to < count) {
				crash "relationship source alignment is invalid"
			}
			theme = Theme.Options.{}
			picture = match EntityRelationship.draw(source, theme) {
				Ok(p) => p
				Err(_) => crash "successfully parsed diagram did not draw"
			}
			if !Drawing.is_finite(picture) {
				crash "non-finite picture"
			}
			if Ok(picture) != EntityRelationship.draw(source, theme) {
				crash "drawing is not deterministic"
			}
			svg = Svg.document(picture, "Inter")
			if !svg.starts_with("<svg ") or !svg.ends_with("</svg>\n") {
				crash "invalid SVG document"
			}
			Fuzz.keep
		}
	}
}

generate : List(U8) -> Str
generate = |bytes| {
	count = 1 + (bytes.get(1) ?? 3).to_u64() % 10
	var $source = "erDiagram\n"
	for i in 0..<count {
		$source = $source.concat("N${i.to_str()} {\n int id PK\n}\n")
	}
	for i in 0..<bytes.len().min(24) {
		a = (bytes.get(i) ?? 0).to_u64() % count
		b = (bytes.get(i + 1) ?? 0).to_u64() % count
		$source = $source.concat("N${a.to_str()} ||--o{ N${b.to_str()} : \"item <&> ${i.to_str()}\"\n")
	}
	$source
}

target = Fuzz.target_with({ examples: [Fuzz.example({ name: "relationship", revision: "1", make: || "erDiagram\nA ||--o{ B : owns\n".to_utf8() })], name: "mermaid-entity-diagram", generator: Fuzz.raw_bytes, test, show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)) })

expect {
	_ = test([0, 2, 0, 1, 1, 0, 2, 2])
	True
}
