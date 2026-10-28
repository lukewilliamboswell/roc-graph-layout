app [target] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}
import fuzz.Fuzz
import ClassDiagram
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
	parsed = ClassDiagram.parse(source)
	if parsed != ClassDiagram.parse(source) {
		crash "parsing is not deterministic"
	}
	match parsed {
		Err([]) => crash "rejected without an explanation"
		Err(_) => Fuzz.keep
		Ok(diagram) => {
			count = diagram.classes.len()
			if !diagram.relationships.all(|r| r.from < count and r.to < count) {
				crash "relationship source alignment is invalid"
			}
			theme = Theme.Options.{}
			picture = match ClassDiagram.draw(source, theme) {
				Ok(p) => p
				Err(_) => crash "successfully parsed diagram did not draw"
			}
			if !Drawing.is_finite(picture) {
				crash "non-finite picture"
			}
			if Ok(picture) != ClassDiagram.draw(source, theme) {
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
	var $source = "classDiagram\n"
	for i in 0..<count {
		$source = $source.concat("class N${i.to_str()} {\n +String id\n}\n")
	}
	for i in 0..<bytes.len().min(24) {
		a = (bytes.get(i) ?? 0).to_u64() % count
		b = (bytes.get(i + 1) ?? 0).to_u64() % count
		$source = $source.concat("N${a.to_str()} --> N${b.to_str()} : \"item <&> ${i.to_str()}\"\n")
	}
	$source
}

target = Fuzz.target_with({ name: "mermaid-class-diagram", generator: Fuzz.raw_bytes, test, show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)) })

expect {
	_ = test([0, 2, 0, 1, 1, 0, 2, 2])
	True
}
