app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import fuzz.Fuzz
import LayeredFlowFixtures
import LayeredFlowFuzz
import LayeredFlowInput
import LayeredFlow
import LayeredFlowGraph
import LayeredFlowImport

## The ordering phase (crossing minimisation, run per graph laid out on its
## own): every layer afterwards holds the same nodes as before, reordered.

Input : LayeredFlowGraph.Model

input : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes } -> Input
input = |d| LayeredFlow.layered(LayeredFlowImport.build(d.diagram, d.sizes).model)

phase : Input -> LayeredFlowGraph.Model
phase = |m| LayeredFlow.order(m, False, []).model

check : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes }, Input, LayeredFlowGraph.Model -> Try({}, Str)
check = |_, before, after| {
	for g in 0..<before.graphs.len() {
		old = LayeredFlowGraph.graph(before, g).layers
		new = LayeredFlowGraph.graph(after, g).layers
		if old.len() != new.len() {
			return Err("ordering: the number of layers changed")
		}
		for l in 0..<old.len() {
			a = old.get(l) ?? []
			b = new.get(l) ?? []
			if a.len() != b.len() or !a.all(|n| b.contains(n)) {
				return Err("ordering: a layer's nodes changed")
			}
		}
	}
	Ok({})
}

## The search sweeps until it stops improving, and a larger diagram can
## need more sweeps (as the engine's does), so the bound is on the cost of
## a sweep: allocations per sweep, each side counted by a traced run.
within : Input, Input, U64, U64 -> Bool
within = |small_input, large_input, small, large| {
	sweeps = |m| LayeredFlow.order(m, True, []).trace.count_if(|line| line.starts_with("sweep")).max(1)
	small_sweeps = sweeps(small_input)
	large_sweeps = sweeps(large_input)
	large * small_sweeps <= LayeredFlowFuzz.allowed_growth * small * large_sweeps + 8192 * large_sweeps
}

## Cost: `LayeredFlowFuzz.copies` copies of the statements must not cost
## more than `LayeredFlowFuzz.allowed_growth` times the allocations of
## `LayeredFlowFuzz.base_copies` copies (plus a constant), and the phase must
## free everything it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	outcome = test(bytes)
	match (LayeredFlowFuzz.diagram(bytes, LayeredFlowFuzz.base_copies), LayeredFlowFuzz.diagram(bytes, LayeredFlowFuzz.copies)) {
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
				crash "ordering: ${LayeredFlowFuzz.copies.to_str()} copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for ${LayeredFlowFuzz.base_copies.to_str()}"
			}
		}
		_ => {}
	}
	outcome
}

test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match LayeredFlowFuzz.diagram(bytes, 1) {
		None => Fuzz.reject
		Some(d) => {
			x = input(d)
			result = phase(x)
			if result != phase(x) {
				crash "ordering: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	name: "graph-layout-flow-ordering",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| LayeredFlowFuzz.text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}

## fuzz regression: one copy of a small diagram needs no crossing
## minimisation; the cost bound compares eight copies against thirty-two.
expect {
	fixture = LayeredFlowFixtures.get("fuzz-regression-ordering-small")
	d = { diagram: fixture.diagram, sizes: fixture.sizes }
	before = input(d)
	check(d, before, phase(before)) == Ok({})
}

## fuzz regression: thirty-two copies need several times the sweeps of
## eight; the bound is on the cost of a sweep.
expect {
	fixture = LayeredFlowFixtures.get("fuzz-regression-ordering-sweeps")
	d = { diagram: fixture.diagram, sizes: fixture.sizes }
	before = input(d)
	check(d, before, phase(before)) == Ok({})
}
