app [target] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}

import Drawing
import FlowLayout
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
	_ = check(source)
	count = 1 + (bytes.first() ?? 0).to_u64() % 12
	var $lines = ["stateDiagram-v2", "[*] --> S0"]
	for i in 0..<count {
		j = (bytes.get(i + 1) ?? i.to_u8_wrap()).to_u64() % count
		$lines = $lines.append("S${i.to_str()} --> S${j.to_str()} : transition ${i.to_str()}")
	}
	$lines = $lines.append("S0 --> [*]")
	check(Str.join_with($lines, "\n"))
}

check : Str -> Fuzz.Outcome
check = |source| match StateDiagram.parse(source) {
	Err(_) => Fuzz.reject
	Ok(diagram) => {
		options = Theme.Options.{}
		sizes = StateDraw.measure_sizes(diagram, options)
		geometry = FlowLayout.layout(StateDraw.make_flow(diagram), sizes)
		if geometry.nodes.len() != diagram.states.len() or geometry.edges.len() != diagram.transitions.len() or geometry.groups.len() != diagram.groups.len() {
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
