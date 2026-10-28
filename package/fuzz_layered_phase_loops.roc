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
import LayeredFlowRandom

## Self-loops, many per node, some labelled: every self-loop leaves and
## re-enters its own node's box, with finite points. The cost measured is
## that of placing and routing (where loops get their sides, lanes and
## room), on diagrams already layered and ordered.

Input : { diagram : LayeredFlowInput.Input, setup : LayeredFlowImport.Setup, model : LayeredFlowGraph.Model, randoms : List(LayeredFlowRandom.Random) }

input : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes } -> Input
input = |d| {
	r = LayeredFlow.ordered_traced(d.diagram, d.sizes, False)
	{ diagram: d.diagram, setup: r.setup, model: r.model, randoms: r.randoms }
}

phase : Input -> LayeredFlow.Raw
phase = |x| LayeredFlow.export(x.diagram, x.setup, LayeredFlow.placed(x.model, x.randoms))

on_box : { x : F64, y : F64 }, { x : F64, y : F64, width : F64, height : F64 } -> Bool
on_box = |p, r| {
	tol = 0.01
	inside = p.x >= r.x - tol and p.x <= r.x + r.width + tol and p.y >= r.y - tol and p.y <= r.y + r.height + tol
	edge = (p.x - r.x).abs() <= tol or (p.x - r.x - r.width).abs() <= tol or (p.y - r.y).abs() <= tol or (p.y - r.y - r.height).abs() <= tol
	inside and edge
}

check : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes }, Input, LayeredFlow.Raw -> Try({}, Str)
check = |d, _, raw| {
	for i in 0..<d.diagram.edges.len() {
		edge = d.diagram.edges.get(i) ?? { from: Node(0), to: Node(0) }
		route = raw.edges.get(i) ?? { points: [], label: None }
		if !route.points.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y)) {
			return Err("loops: a point is not finite")
		}
		match (edge.from, edge.to) {
			(Node(a), Node(b)) if a == b => {
				box = raw.nodes.get(a) ?? { x: 0, y: 0, width: 0, height: 0 }
				first = route.points.first() ?? { x: F64.nan, y: 0 }
				last = route.points.last() ?? { x: F64.nan, y: 0 }
				if route.points.len() < 2 or !on_box(first, box) or !on_box(last, box) {
					return Err("loops: a self-loop does not leave and return to its node")
				}
			}
			_ => {}
		}
	}
	Ok({})
}

within : Input, Input, U64, U64 -> Bool
within = |_, _, small, large| LayeredFlowFuzz.within_bound(small, large)

## Cost: `LayeredFlowFuzz.copies` copies of the statements must not cost
## more than `LayeredFlowFuzz.allowed_growth` times the allocations of
## `LayeredFlowFuzz.base_copies` copies (plus a constant), and the phase must
## free everything it allocates.
test! : List(U8) => Fuzz.Outcome
test! = |bytes| {
	outcome = test(bytes)
	match (LayeredFlowFuzz.loops_diagram(bytes, LayeredFlowFuzz.base_copies), LayeredFlowFuzz.loops_diagram(bytes, LayeredFlowFuzz.copies)) {
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
				crash "loops: ${LayeredFlowFuzz.copies.to_str()} copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for ${LayeredFlowFuzz.base_copies.to_str()}"
			}
		}
		_ => {}
	}
	outcome
}

test : List(U8) -> Fuzz.Outcome
test = |bytes|
	match LayeredFlowFuzz.loops_diagram(bytes, 1) {
		None => Fuzz.reject
		Some(d) => {
			x = input(d)
			result = phase(x)
			if result != phase(x) {
				crash "loops: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	name: "graph-layout-flow-loops",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| LayeredFlowFuzz.loops_text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}

## fuzz regression: a node with several self-loops, a few copies over;
## the cost bound compares eight copies against thirty-two.
expect {
	fixture = LayeredFlowFixtures.get("fuzz-regression-loops-many")
	d = { diagram: fixture.diagram, sizes: fixture.sizes }
	before = input(d)
	check(d, before, phase(before)) == Ok({})
}

## fuzz regression: ordering many copies takes more sweeps; the loops
## target measures placing and routing only.
expect {
	fixture = LayeredFlowFixtures.get("fuzz-regression-loops-sweeps")
	d = { diagram: fixture.diagram, sizes: fixture.sizes }
	before = input(d)
	check(d, before, phase(before)) == Ok({})
}
