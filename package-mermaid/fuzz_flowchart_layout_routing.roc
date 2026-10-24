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
import FlowLayoutRandom

## The placement and routing phases together (routing needs each inner
## graph placed and sized first): every edge's bends are finite, and every
## bend lies inside its graph's box.

Input : { model : FlowLayoutGraph.Model, randoms : List(FlowLayoutRandom.Random) }

input : { diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes } -> Input
input = |d| {
	r = FlowLayoutElk.order(FlowLayoutElk.layered(FlowLayoutImport.build(d.diagram, d.sizes).model), False, [])
	{ model: r.model, randoms: r.randoms }
}

phase : Input -> FlowLayoutGraph.Model
phase = |x| FlowLayoutElk.placed(x.model, x.randoms)

check : { diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes }, Input, FlowLayoutGraph.Model -> Try({}, Str)
check = |_, _, m| {
	if !m.edges.all(|e| e.bends.all(|b| F64.is_finite(b.x) and F64.is_finite(b.y))) {
		return Err("routing: a bend is not finite")
	}
	if !m.graphs.all(|g| F64.is_finite(g.width) and F64.is_finite(g.height) and g.width >= 0 and g.height >= 0) {
		return Err("routing: a graph's size is not finite")
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
			Fuzz.expect_no_leaks!(|{}| phase(large_input))
			if !within(small_input, large_input, small_cost.allocations, large_cost.allocations) {
				crash "routing: ${FlowLayoutFuzz.copies.to_str()} copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for ${FlowLayoutFuzz.base_copies.to_str()}"
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
				crash "routing: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	name: "mermaid-flowchart-layout-routing",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| FlowLayoutFuzz.text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}
