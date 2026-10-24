app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Flowchart

## The reading contract on arbitrary text: every input is either read or
## rejected with at least one problem, reading is deterministic, and every
## index in a diagram resolves. Inputs are the raw bytes of the source text,
## so saved corpus files are ordinary Mermaid files the oracle can record.
test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			first = Flowchart.parse(text)
			if first != Flowchart.parse(text) {
				crash "reading the same text twice gave different results"
			}
			match first {
				Err([]) => crash "text was rejected without a problem"
				Err(_) => Fuzz.keep
				Ok(diagram) =>
					if consistent(diagram) {
						Fuzz.keep
					} else {
						crash "a diagram index does not resolve"
					}
			}
		}
	}

consistent : Flowchart.Diagram -> Bool
consistent = |diagram| {
	group_count = diagram.groups.len()
	node_count = diagram.nodes.len()
	in_group = |container|
		match container {
			Root => True
			Group(g) => g < group_count
		}
	endpoint = |end|
		match end {
			Node(n) => n < node_count
			Group(g) => g < group_count
		}
	diagram.nodes.all(|node| in_group(node.container))
		and diagram.edges.all(|edge| endpoint(edge.from) and endpoint(edge.to) and edge.length >= 1 and edge.length <= 10 and edge.id != "")
		and diagram.groups.all(|group| in_group(group.container))
		and acyclic(diagram.groups)
}

## Following containers from any group reaches the top level.
acyclic : List(Flowchart.Group) -> Bool
acyclic = |groups|
	groups.all(
		|group| {
			var $at = group.container
			var $steps = 0
			while $steps <= groups.len() and $at != Root {
				$at = match $at {
					Group(g) => (groups.get(g) ?? group).container
					Root => Root
				}
				$steps = $steps + 1
			}
			$at == Root
		},
	)

target = Fuzz.target_with({
	name: "mermaid-flowchart-parse",
	generator: Fuzz.raw_bytes,
	test,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})

expect {
	_ = test("flowchart TD\n  A --> B\n".to_utf8())
	True
}
expect {
	_ = test("not a diagram".to_utf8())
	True
}
