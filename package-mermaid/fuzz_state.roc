app [target] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}

import Drawing
import StateDiagram
import StateDraw
import Svg
import Theme
import fuzz.Fuzz

## Arbitrary Mermaid state text must either report problems or produce a
## finite deterministic picture. Parsed endpoint indices and layout lists
## must retain state/transition/group alignment. Generated valid graphs keep
## cycles, self-loops, parallel edges and scoped initial/final markers live
## even when a raw byte corpus rarely spells a whole state diagram.
test : List(U8) -> Fuzz.Outcome
test = |bytes| {
	source = Str.from_utf8_lossy(bytes)
	options = match (bytes.first() ?? 0) % 4 {
		0 => Theme.Options.{}
		1 => Theme.Options.{ font_size: 64, line_height: 0.1, padding: 0, max_label_width: 300 }
		2 => Theme.Options.{ font_size: 64, line_height: 0.01, padding: 0, max_label_width: 90 }
		_ => Theme.Options.{ font_size: 0.001, line_height: 0.01, padding: 0 }
	}
	_ = check(source, options)
	count = 1 + (bytes.first() ?? 0).to_u64() % 12
	var $lines = ["stateDiagram-v2", "[*] --> S0"]
	for i in 0..<count {
		j = (bytes.get(i + 1) ?? i.to_u8_wrap()).to_u64() % count
		$lines = $lines.append("S${i.to_str()} --> S${j.to_str()} : transition ${i.to_str()}")
	}
	$lines = $lines.concat(["S0 --> [*]", "S0: entry / synchronize", "note right of S0 : Retryg"])
	check(Str.join_with($lines, "\n"), options)
}

check : Str, Theme.Options -> Fuzz.Outcome
check = |source, options| match StateDiagram.parse(source) {
	Err(_) => Fuzz.reject
	Ok(diagram) => {
		prepared = StateDraw.setup(diagram, options)
		geometry = prepared.geometry
		if geometry.nodes.len() != diagram.states.len() + diagram.notes.len() or geometry.edges.len() != diagram.transitions.len() + diagram.notes.len() or geometry.groups.len() != diagram.groups.len() + diagram.notes.len() {
			crash "state geometry lost source alignment"
		}
		for edge in diagram.transitions {
			for endpoint in [edge.from, edge.to] {
				valid = match endpoint {
					Node(i) => i < diagram.states.len()
					Group(i) => i < diagram.groups.len()
				}
				if !valid {
					crash "state transition has an invalid endpoint"
				}
			}
		}
		first = StateDraw.draw(diagram, options)
		second = StateDraw.draw(diagram, options)
		if first != second {
			crash "state rendering is not deterministic"
		}
		if !Drawing.is_finite(first) {
			crash "state rendering emitted non-finite geometry"
		}
		if !StateDraw.labels_contained(first, options) {
			crash "state text escaped its node, group, note, or edge-label box"
		}
		svg = Svg.document(first, "Inter")
		if !svg.starts_with("<svg ") or !svg.ends_with("</svg>\n") {
			crash "state renderer did not produce an SVG document"
		}
		Fuzz.keep
	}
}

target = Fuzz.target_with({ name: "mermaid-state", generator: Fuzz.raw_bytes, test, show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)) })

expect {
	_ = test("stateDiagram-v2\n[*] --> Idle\nIdle --> Idle : retry\nIdle --> [*]\n".to_utf8())
	True
}

expect {
	_ = test("stateDiagram-v2\nstate Nested {\n[*] --> A\nA --> [*]\n}\n[*] --> Nested\nNested --> [*]\n".to_utf8())
	True
}
