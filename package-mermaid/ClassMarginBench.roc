app [main!] {
	font: "https://github.com/lukewilliamboswell/roc-font/releases/download/0.1.0-rc2/A14BmicBaf6dm4K9kdYH9j8Y6BoAZrpUmxWh9sojsFy5.tar.zst",
	layout: "../package/main.roc",
	pf: platform "../benchmarks/platform/main.roc",
}
import pf.Measure
import pf.Stdout
import Flowchart
import FlowLayoutElk
import FlowLayoutPlace
import FlowLayoutLoops
import EntityLayout
import ClassMarginBefore
main! = |args| {
	operation = args.get(1) ?? "after"
	count = U64.from_str(args.get(2) ?? "4") ?? 4
	source = "flowchart TB\n".concat(Str.join_with(List.repeat(0, count).map_with_index(|_, i| "Hub --> N${i.to_str()}"), "\n"))
	diagram = Flowchart.parse(source) ?? crash "benchmark source"
	sizes = { nodes: diagram.nodes.map(|_| { width: 51, height: 77, label: { lines: [], width: 0, height: 0 } }), edge_labels: diagram.edges.map(|_| None), group_titles: [] }
	ordered = FlowLayoutElk.ordered_traced(diagram, sizes, False)
	model = FlowLayoutPlace.margins(FlowLayoutPlace.place_ports(FlowLayoutLoops.restore(ordered.model, 0), 0), 0)
	labels = diagram.edges.map(|_| { from: Some({ width: 16.328125, height: 14 }), to: Some({ width: 28.53125, height: 26 }) })
	control = diagram.edges.map(|_| { from: None, to: None })
	_ = Measure.start!({})
	result = if operation == "before" {
		ClassMarginBefore.margins(model, 0, labels, True)
	}
	else if operation == "control" {
		EntityLayout.margins(model, 0, control, True)
	}
	else {
		EntityLayout.margins(model, 0, labels, True)
	}
	observation = result.nodes.fold(0.0, |sum, node| sum + node.margin.right + node.margin.bottom).to_u64_try() ?? 0
	measurement = Measure.finish!(observation)
	Stdout.line!("${measurement}}")
}
