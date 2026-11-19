app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.6.2/3kyiehxxzwAsjM23uCQGJ3Hx7dAAdzSGtK3k9Jq7Egtu.tar.zst" }
import fuzz.Fuzz
import LayeredFlowFuzz
import LayeredFlowImport
import LayeredFlow
import LayeredFlowGraph

# Compare the same layered-flow input at three increasing component counts.
# `roc build --opt=speed package/measure_flow_layering.roc --output=...`
# followed by `<binary> check --report-dir=<fresh-directory>` records the
# preparation, zero-work control and layering regions. Repeat with --opt=dev
# to investigate backend ownership costs. No baseline is accepted here.
# Adding 100 to a count selects the unresolved mixed-order witness.
witness = |code| if code >= 100 {
	[43.U8, 10, 10]
} else {
	[10, 10, 3, 8]
}

count_of = |code| if code >= 100 {
	code - 100
} else {
	code
}

property! : U64 => Fuzz.Outcome
property! = |code| {
	count = count_of(code)
	if count != 8 and count != 16 and count != 32 {
		return Fuzz.reject
	}
	match LayeredFlowFuzz.diagram(witness(code), count) {
		None => Fuzz.reject
		Some(d) => {
			prepared = Fuzz.measure!("prepare", || LayeredFlowImport.build(d.diagram, d.sizes).model)
			m = prepared.value
			control = Fuzz.measure!("control", || m.nodes.len())
			layered = Fuzz.measure!("layering", || LayeredFlow.layered(m))
			if control.value != m.nodes.len() or layered.value.nodes.len() < m.nodes.len() {
				crash "bad benchmark"
			}
			Fuzz.keep
		}
	}
}

target = Fuzz.target_with!({
	name: "flow-layering-investigation",
	generator: Fuzz.u64_in(8, 132),
	examples: [
		Fuzz.example({ name: "copies-8", revision: "1", make: || 8 }),
		Fuzz.example({ name: "copies-16", revision: "1", make: || 16 }),
		Fuzz.example({ name: "copies-32", revision: "1", make: || 32 }),
		Fuzz.example({ name: "mixed-8", revision: "1", make: || 108 }),
		Fuzz.example({ name: "mixed-16", revision: "1", make: || 116 }),
		Fuzz.example({ name: "mixed-32", revision: "1", make: || 132 }),
	],
	test!: property!,
	show: |code| match LayeredFlowFuzz.diagram(witness(code), count_of(code)) {
		None => "none"
		Some(d) => Str.inspect(LayeredFlow.layered(LayeredFlowImport.build(d.diagram, d.sizes).model))
	},
})
