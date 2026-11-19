app [target] {
	fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst",
}

import fuzz.Fuzz
import LayeredFlowFuzz
import LayeredFlowInput
import LayeredFlowGraph
import LayeredFlowImport

## The import phase: the working graph built from a diagram. Every diagram
## node and subgraph gets a layout node, every edge between two existing
## ends a layout edge, and every node lies in the graph of its container.

Input : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes }

input : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes } -> Input
input = |d| d

phase : Input -> LayeredFlowImport.Setup
phase = |x| LayeredFlowImport.build(x.diagram, x.sizes)

check : { diagram : LayeredFlowInput.Input, sizes : LayeredFlowInput.Sizes }, Input, LayeredFlowImport.Setup -> Try({}, Str)
check = |d, _, setup| {
	if setup.node_of.len() != d.diagram.nodes.len() or setup.group_node.len() != d.diagram.groups.len() or setup.edge_of.len() != d.diagram.edges.len() {
		return Err("import: results are not aligned with the diagram")
	}
	if setup.node_of.any(|n| n >= setup.model.nodes.len()) or setup.group_node.any(|n| n >= setup.model.nodes.len()) {
		return Err("import: a diagram node has no layout node")
	}
	if setup.edge_of.any(|e| e >= setup.model.edges.len()) {
		return Err("import: an edge has no layout edge")
	}
	for g in 0..<setup.model.graphs.len() {
		for n in LayeredFlowGraph.graph(setup.model, g).nodes {
			if LayeredFlowGraph.node(setup.model, n).graph != g {
				return Err("import: a node is listed in a graph it is not in")
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
			small_cost = Fuzz.measure!("allocations", || phase(small_input))
			large_cost = Fuzz.measure!("allocations", || phase(large_input))
			# Results are dropped inside each closure: the dev backend keeps a value
			# bound to `_` alive until its block ends, which would read as a leak.
			Fuzz.expect_no_leaks!(
				|| {
					_ = phase(large_input)
					{}
				},
			)
			if !within(small_input, large_input, allocation_calls(small_cost.stats), allocation_calls(large_cost.stats)) {
				crash "import: ${LayeredFlowFuzz.copies.to_str()} copies took ${allocation_calls(large_cost.stats).to_str()} allocations, against ${allocation_calls(small_cost.stats).to_str()} for ${LayeredFlowFuzz.base_copies.to_str()}"
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
				crash "import: the same input gave different results"
			}
			match check(d, x, result) {
				Ok({}) => Fuzz.keep
				Err(problem) => crash problem
			}
		}
	}

target = Fuzz.target_with!({
	examples: [],
	name: "graph-layout-flow-import",
	generator: Fuzz.raw_bytes,
	test!,
	show: |bytes| LayeredFlowFuzz.text(bytes, 1),
})

expect {
	_ = test([0].concat("abcdefghijklmnopqrstuvwxyz0123456789".to_utf8()))
	True
}

# The previous counter included both allocation and reallocation calls.
# Keep the existing growth bounds on that same quantity.
allocation_calls : Fuzz.Stats -> U64
allocation_calls = |stats| stats.allocs + stats.reallocs
