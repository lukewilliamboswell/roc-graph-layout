app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst",
}

import fuzz.Fuzz
import LayeredFlowFuzz
import LayeredFlowInput
import LayeredFlow
import LayeredFlowGraph
import LayeredFlowImport

## The layering phase (cycle breaking, label nodes, network simplex
## layering, long-edge splitting and port sorting): every node of a graph
## lies in exactly one of its layers, and every edge between two nodes of
## one graph runs between neighbouring layers or within one.

Input : LayeredFlowGraph.Model

input : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes } -> Input
input = |d| LayeredFlowImport.build(d.diagram, d.sizes).model

phase : Input -> LayeredFlowGraph.Model
phase = |m| LayeredFlow.layered(m)

check : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes }, Input, LayeredFlowGraph.Model -> Try({}, Str)
check = |_, _, m| {
	var $seen = List.repeat(0, m.nodes.len())
	for g in 0..<m.graphs.len() {
		layers = LayeredFlowGraph.graph(m, g).layers
		for l in 0..<layers.len() {
			for n in layers.get(l) ?? [] {
				$seen = $seen.set(n, ($seen.get(n) ?? 0) + 1) ?? $seen
				node = LayeredFlowGraph.node(m, n)
				if node.graph != g or node.layer != l {
					return Err("layering: a node's layer does not list it")
				}
			}
		}
	}
	if $seen.any(|c| c > 1) {
		return Err("layering: a node is in two layers")
	}
	for e in 0..<m.edges.len() {
		edge = LayeredFlowGraph.edge(m, e)
		if edge.source != LayeredFlowGraph.nil and edge.target != LayeredFlowGraph.nil {
			s = LayeredFlowGraph.node(m, LayeredFlowGraph.port(m, edge.source).node)
			t = LayeredFlowGraph.node(m, LayeredFlowGraph.port(m, edge.target).node)
			if s.graph == t.graph and s.layer != LayeredFlowGraph.nil and t.layer != LayeredFlowGraph.nil and t.layer > s.layer + 1 {
				return Err("layering: an edge skips a layer")
			}
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
				crash "layering: ${LayeredFlowFuzz.copies.to_str()} copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for ${LayeredFlowFuzz.base_copies.to_str()}"
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
				crash "layering: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	name: "graph-layout-flow-layering",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| LayeredFlowFuzz.text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}
