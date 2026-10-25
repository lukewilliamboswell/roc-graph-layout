app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
	layout: "../package/main.roc",
}

import fuzz.Fuzz
import FlowLayoutFuzz
import Flowchart
import FlowGeometry
import FlowLayoutElk
import FlowLayoutGraph
import FlowLayoutImport
import FlowLayoutPlace

## The placement phase (port placement, margins, label placement and
## Brandes and Koepf's node placement, per graph): positions are finite
## and nodes keep their order down each layer without overlapping.

Input : FlowLayoutGraph.Model

input : { diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes } -> Input
input = |d| FlowLayoutElk.order(FlowLayoutElk.layered(FlowLayoutImport.build(d.diagram, d.sizes).model), False, []).model

phase : Input -> FlowLayoutGraph.Model
phase = |m0| {
	var $m = m0
	for g in FlowLayoutElk.bottom_up(m0) {
		$m = FlowLayoutPlace.prepare($m, g, FlowLayoutElk.vertical(FlowLayoutGraph.graph($m, g).direction))
		$m = FlowLayoutPlace.brandes_koepf($m, g)
	}
	$m
}

check : { diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes }, Input, FlowLayoutGraph.Model -> Try({}, Str)
check = |_, _, m| {
	if !m.nodes.all(|n| F64.is_finite(n.x) and F64.is_finite(n.y)) {
		return Err("placement: a position is not finite")
	}
	for g in 0..<m.graphs.len() {
		for layer in FlowLayoutGraph.graph(m, g).layers {
			for i in 1..<layer.len() {
				a = FlowLayoutGraph.node(m, layer.get(i - 1) ?? 0)
				b = FlowLayoutGraph.node(m, layer.get(i) ?? 0)
				if a.y + a.height + a.margin.bottom > b.y - b.margin.top + 0.001 {
					return Err("placement: two nodes of a layer overlap")
				}
			}
		}
	}
	Ok({})
}

within : Input, Input, U64, U64 -> Bool
within = |_, _, small, large| FlowLayoutFuzz.within_bound(small, large)

## Cost: `FlowLayoutFuzz.copies` copies of the statements must not cost
## more than `FlowLayoutFuzz.allowed_growth` times the allocations of
## `FlowLayoutFuzz.base_copies` copies (plus a constant), and the phase must
## free everything it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	outcome = test(bytes)
	match (FlowLayoutFuzz.diagram(bytes, FlowLayoutFuzz.base_copies), FlowLayoutFuzz.diagram(bytes, FlowLayoutFuzz.copies)) {
		(Some(small), Some(large)) => {
			small_input = input(small)
			large_input = input(large)
			small_cost = Fuzz.measure_allocs!(|{}| phase(small_input))
			large_cost = Fuzz.measure_allocs!(|{}| phase(large_input))
			# Results are dropped inside each closure: the dev backend keeps a value
			# bound to `_` alive until its block ends, which would read as a leak.
			Fuzz.expect_no_leaks!(
				|{}| {
					_ = phase(large_input)
					{}
				},
			)
			if !within(small_input, large_input, small_cost.allocations, large_cost.allocations) {
				crash "placement: ${FlowLayoutFuzz.copies.to_str()} copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for ${FlowLayoutFuzz.base_copies.to_str()}"
			}
		}
		_ => {}
	}
	outcome
}

test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match FlowLayoutFuzz.diagram(bytes, 1) {
		None => Fuzz.reject
		Some(d) => {
			x = input(d)
			result = phase(x)
			if result != phase(x) {
				crash "placement: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	name: "mermaid-flowchart-layout-placement",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| FlowLayoutFuzz.text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}
