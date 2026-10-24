app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst" }

import fuzz.Fuzz
import Flowchart

## Reading cost grows linearly with the text. The input chooses a mix of
## statements; the same mix is repeated 1 and 8 times with fresh ids, and the
## larger text must not take more than about 8 times the allocations of the
## smaller. Repeated whole-list copies or rescans show up as a ratio near 64.
## Optionally everything sits inside one subgraph, so a single large group
## body is covered too. Reading must also free everything it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	small = diagram_text(bytes, 1)
	large = diagram_text(bytes, 8)
	small_cost = Fuzz.measure_allocs!(|{}| Flowchart.parse(small))
	large_cost = Fuzz.measure_allocs!(|{}| Flowchart.parse(large))
	Fuzz.expect_no_leaks!(|{}| Flowchart.parse(large))
	if large_cost.allocations > 10 * small_cost.allocations + 256 {
		crash "reading 8 times the text took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for one copy"
	}
	Fuzz.keep
}

## One statement per input byte (up to 24), each in one of several forms,
## repeated `copies` times with ids that are unique to each copy.
diagram_text : List(U8), U64 -> Str
diagram_text = |bytes, copies| {
	choices = bytes.take_first(24)
	wrapped = (bytes.first() ?? 0) % 2 == 1
	var $lines = ["flowchart TD"]
	if wrapped {
		$lines = $lines.append("subgraph outer [Everything]")
	}
	for copy in 0..<copies {
		for index in 0..<choices.len() {
			choice = choices.get(index) ?? 0
			$lines = $lines.concat(statement(choice, "${copy.to_str()}_${index.to_str()}"))
		}
	}
	if wrapped {
		$lines = $lines.append("end")
	}
	Str.join_with($lines, "\n").concat("\n")
}

statement : U8, Str -> List(Str)
statement = |choice, id|
	match choice % 8 {
		0 => ["  n${id} --> m${id}"]
		1 => ["  n${id}[Label ${id}] -->|yes| m${id}{{Check}}"]
		2 => ["  subgraph s${id} [Group ${id}]", "    a${id} --> b${id}", "  end"]
		3 => ["  a${id} & b${id} --> c${id} & d${id}"]
		4 => ["  n${id} -.-> m${id} ==> o${id}"]
		5 => ["  classDef k${id} fill:#fff,stroke:#333", "  n${id}:::k${id}"]
		6 => ["  n${id}((Round)) -- text --> m${id}[(Store)]", "  style n${id} fill:#f96"]
		_ => ["  subgraph s${id}", "    subgraph t${id}", "      a${id}", "    end", "  end"]
	}

target = Fuzz.target_with!({
	name: "mermaid-flowchart-scaling",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| diagram_text(bytes, 1),
})
