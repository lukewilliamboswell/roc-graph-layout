app [target] {
	font: "../vendor/roc-font/main.roc",
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import fuzz.Fuzz
import Flowchart
import FlowGeometry
import FlowSize
import TextMeasure

## The sizing contract on arbitrary text. Text that reads as a flowchart is
## sized; the sizes line up with the diagram's nodes, edges and groups, every
## length is finite and not negative, and sizing twice gives the same result.
## The same text is also measured as a single label, repeated 2 and 16
## times: the longer label must not cost more than about 8 times the
## allocations of the shorter (both are usually long enough to wrap, so like
## is compared with like), and measuring must free what it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes|
	match Str.from_utf8(bytes) {
		Err(_) => Fuzz.reject
		Ok(text) => {
			match Flowchart.parse(text) {
				Ok(diagram) => {
					sizes = FlowSize.sizes(diagram, FlowSize.mermaid)
					if sizes != FlowSize.sizes(diagram, FlowSize.mermaid) {
						crash "sizing the same diagram twice gave different results"
					}
					if sizes.nodes.len() != diagram.nodes.len() or sizes.edge_labels.len() != diagram.edges.len() or sizes.group_titles.len() != diagram.groups.len() {
						crash "sizes are not aligned with the diagram"
					}
					if !sizes.nodes.all(|n| valid(n.width) and valid(n.height) and block_ok(n.label)) {
						crash "a node size is not finite and non-negative"
					}
					if !sizes.group_titles.all(block_ok) {
						crash "a group title size is not finite and non-negative"
					}
					edges_ok = sizes.edge_labels.all(
						|label|
							match label {
								None => True
								Some(b) => block_ok(b)
							},
					)
					if !edges_ok {
						crash "an edge label size is not finite and non-negative"
					}
				}
				Err(_) => {}
			}
			label = label_text(text, 2)
			long = label_text(text, 16)
			style = { font: FlowSize.mermaid.font, size: 14.0, line_height: 1.1, wrap: Width(120.0), align: Middle }
			small_cost = Fuzz.measure_allocs!(|{}| TextMeasure.block(label, style))
			large_cost = Fuzz.measure_allocs!(|{}| TextMeasure.block(long, style))
			Fuzz.expect_no_leaks!(|{}| TextMeasure.block(long, style))
			if large_cost.allocations > 10 * small_cost.allocations + 256 {
				crash "measuring 8 times the text took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for one copy"
			}
			if !block_ok(TextMeasure.block(long, { ..style, wrap: NoWrap, align: Start })) {
				crash "a label size is not finite and non-negative"
			}
			Fuzz.keep
		}
	}

## Up to 64 bytes' worth of the text, repeated.
label_text : Str, U64 -> Str
label_text = |text, copies| {
	piece = Str.from_utf8_lossy(text.to_utf8().take_first(64))
	Str.join_with(List.repeat(piece, copies), " ")
}

valid : F64 -> Bool
valid = |value| F64.is_finite(value) and value >= 0.0

block_ok : FlowGeometry.TextBlock -> Bool
block_ok = |b| valid(b.width) and valid(b.height) and (b.width == 0.0 or b.height > 0.0)

target = Fuzz.target_with!({
	name: "mermaid-flowchart-sizes",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| Str.inspect(Str.from_utf8_lossy(bytes)),
})
