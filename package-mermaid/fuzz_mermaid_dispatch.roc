app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	mermaid: "main.roc",
}

import fuzz.Fuzz
import mermaid.Drawing
import mermaid.Mermaid
import mermaid.Svg
import mermaid.Theme

target = Fuzz.target_with({ name: "Mermaid public dispatch and themes", generator: Fuzz.raw_bytes, test: verify, show: Str.inspect })

## Exercise every family even from an empty corpus, varying text size,
## wrapping and padding. The same picture must back both public outputs.
verify : List(U8) -> Fuzz.Outcome
verify = |bytes| {
	choice = (bytes.get(0) ?? 0).to_u64()
	label = "A descriptive label ${choice.to_str()} with enough words to wrap"
	source = match choice % 5 {
		0 => "flowchart TD\nA[${label}] --> B[Done]\nB --> A\nA --> A\nIsolated[Separate]\n"
		1 => "sequenceDiagram\nactor A as Reader\nparticipant B as Service\nA->>B: ${label}\nB-->>A: Result\nA->>A: Think again\n"
		2 => "erDiagram\nACCOUNT ||--o{ ORDER : \"${label}\"\nACCOUNT {\nstring id PK\n}\n"
		3 => "classDiagram\nParent <|-- Child\nclass Child {\n+String value\n+run() Boolean\n}\n"
		_ => "stateDiagram-v2\n[*] --> Idle\nIdle --> Busy : ${label}\nBusy --> Idle : retry\nBusy --> [*]\n"
	}
	theme = Theme.Options.{
		font_size: 8 + (bytes.get(1) ?? 6).to_f64() / 4,
		max_label_width: 40 + (bytes.get(2) ?? 120).to_f64(),
		line_height: (1 + (bytes.get(3) ?? 40).to_f64()) / 64,
		padding: (bytes.get(4) ?? 12).to_f64() / 2,
		corner_radius: (bytes.get(5) ?? 8).to_f64(),
		line_width: (bytes.get(6) ?? 12).to_f64() / 8,
		shadow: if (bytes.get(7) ?? 0) % 2 == 0 {
			NoShadow
		} else {
			Shadow({ dx: (bytes.get(8) ?? 140).to_f64() - 128, dy: (bytes.get(9) ?? 140).to_f64() - 128, opacity: 0.2 })
		},
	}
	options = Mermaid.Options.{ theme }
	match Mermaid.draw_with(source, options) {
		Err(problems) => crash "a generated supported diagram was rejected: ${Str.inspect(problems)}"
		Ok(picture) => {
			if !Drawing.is_finite(picture) {
				crash "non-finite public drawing"
			}
			if Mermaid.draw_with(source, options) != Ok(picture) {
				crash "non-deterministic public drawing"
			}
			if Mermaid.svg_with(source, options) != Ok(Svg.document(picture, "Inter, sans-serif")) {
				crash "SVG and picture disagree"
			}
			for item in picture.items {
				match item {
					Text(painted_text) => if !inside(painted_text.origin, picture.view) {
						crash "text anchor outside view"
					}
					Shape(shape) => for segment in shape.path {
						points = match segment {
							MoveTo(p) | LineTo(p) => [p]
							CubicTo(c) => [c.control_1, c.control_2, c.end]
							Close => []
						}
						if !points.all(|p| inside(p, picture.view)) {
							crash "painted path outside view"
						}
					}
				}
			}
			invalid = Mermaid.Options.{ theme: Theme.Options.{ font_size: 0, padding: -1 } }
			match Mermaid.draw_with(source, invalid) {
				Ok(_) => crash "invalid theme was accepted"
				Err(problems) => if problems != [InvalidTheme("font_size"), InvalidTheme("padding")] {
					crash "theme problems were not aggregated"
				}
			}
			Fuzz.keep
		}
	}
}

inside : Drawing.Point, Drawing.Rect -> Bool
inside = |p, view| p.x >= view.x - 0.001 and p.y >= view.y - 0.001
	and p.x <= view.x + view.width + 0.001 and p.y <= view.y + view.height + 0.001

expect {
	for choice in [0, 1, 2, 3, 4] {
		_ = verify([choice])
		_ = verify([choice, 255, 0, 0, 0, 255, 255, 1, 0, 255])
		_ = verify([choice, 64, 255, 255, 255, 255, 0, 1, 255, 0])
	}
	True
}
