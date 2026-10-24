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

## The layering phase (cycle breaking, label nodes, network simplex
## layering, long-edge splitting and port sorting): every node of a graph
## lies in exactly one of its layers, and every edge between two nodes of
## one graph runs between neighbouring layers or within one.

Input : FlowLayoutGraph.Model

input : { diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes } -> Input
input = |d| FlowLayoutImport.build(d.diagram, d.sizes).model

phase : Input -> FlowLayoutGraph.Model
phase = |m| FlowLayoutElk.layered(m)

check : { diagram : Flowchart.Diagram, sizes : FlowGeometry.Sizes }, Input, FlowLayoutGraph.Model -> Try({}, Str)
check = |_, _, m| {
	var $seen = List.repeat(0, m.nodes.len())
	for g in 0..<m.graphs.len() {
		layers = FlowLayoutGraph.graph(m, g).layers
		for l in 0..<layers.len() {
			for n in layers.get(l) ?? [] {
				$seen = $seen.set(n, ($seen.get(n) ?? 0) + 1) ?? $seen
				node = FlowLayoutGraph.node(m, n)
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
		edge = FlowLayoutGraph.edge(m, e)
		if edge.source != FlowLayoutGraph.nil and edge.target != FlowLayoutGraph.nil {
			s = FlowLayoutGraph.node(m, FlowLayoutGraph.port(m, edge.source).node)
			t = FlowLayoutGraph.node(m, FlowLayoutGraph.port(m, edge.target).node)
			if s.graph == t.graph and s.layer != FlowLayoutGraph.nil and t.layer != FlowLayoutGraph.nil and t.layer > s.layer + 1 {
				return Err("layering: an edge skips a layer")
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
			Fuzz.expect_no_leaks!(|{}| phase(large_input))
			if !within(small_input, large_input, small_cost.allocations, large_cost.allocations) {
				crash "layering: ${FlowLayoutFuzz.copies.to_str()} copies took ${large_cost.allocations.to_str()} allocations, against ${small_cost.allocations.to_str()} for ${FlowLayoutFuzz.base_copies.to_str()}"
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
				crash "layering: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	name: "mermaid-flowchart-layout-layering",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| FlowLayoutFuzz.text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}
