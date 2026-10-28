app [main!] { pf: platform "../benchmarks/platform/main.roc" }

import pf.Measure
import pf.Stdout
import LayeredFlow
import LayeredFlowGraph
import LayeredFlowImport
import LayeredFlowInput
import LayeredFlowLabels
import LayeredFlowLoops
import LayeredFlowPlace
import LayeredFlowFixtures

## Native phase telemetry over numeric chain/wide graphs. No text, parser,
## drawing or reference positions participate. Build with --opt=speed.
##
##     flow_phase_bench <zero|construct|layers|order|place|labels|label-control|layout> <edge-count> <chain|wide>
##
## Input construction and preceding phases run outside the measured interval.
## The zero and label-control operations distinguish fixed cost and label work.
main! = |args| {
	operation = args.get(1) ?? "layout"
	count = U64.from_str(args.get(2) ?? "100") ?? 100
	kind = args.get(3) ?? "wide"
	diagram : LayeredFlowInput.Input
	diagram = {
		direction: Down,
		nodes: List.repeat({ container: Root }, count + 1),
		edges: List.repeat(0, count).map_with_index(|_, i| { from: Node(if (kind == "chain") i else 0), to: Node(i + 1) }),
		groups: [],
		spacing: LayeredFlowFixtures.root_spacing,
		padding: { top: 12, right: 12, bottom: 12, left: 12 },
	}
	sizes : LayeredFlowInput.Sizes
	sizes = { nodes: List.repeat({ width: 51, height: 77 }, count + 1), edge_labels: List.repeat(None, count), group_titles: [] }
	telemetry = if operation == "zero" {
		_ = Measure.start!({})
		Measure.finish!(0)
	} else if operation == "construct" {
		_ = Measure.start!({})
		result = LayeredFlowImport.build(diagram, sizes)
		Measure.finish!(result.model.nodes.len())
	} else if operation == "layout" {
		_ = Measure.start!({})
		result = LayeredFlow.layout_raw(diagram, sizes)
		Measure.finish!(result.nodes.len() + result.edges.len())
	} else {
		setup = LayeredFlowImport.build(diagram, sizes)
		if operation == "layers" {
			_ = Measure.start!({})
			result = LayeredFlow.layered(setup.model)
			Measure.finish!(result.nodes.len())
		} else {
			layered = LayeredFlow.layered(setup.model)
			if operation == "order" {
				_ = Measure.start!({})
				result = LayeredFlow.order(layered, False, [])
				Measure.finish!(result.model.nodes.len())
			} else {
				ordered = LayeredFlow.order(layered, False, [])
				if operation == "place" {
					_ = Measure.start!({})
					result = LayeredFlow.placed(ordered.model, ordered.randoms)
					Measure.finish!(result.nodes.len())
				} else {
					model = LayeredFlowPlace.margins(LayeredFlowPlace.place_ports(LayeredFlowLoops.restore(ordered.model, 0), 0), 0)
					labels = if operation == "label-control" {
						List.repeat({ from: None, to: None }, count)
					} else {
						List.repeat({ from: Some({ width: 16.328125, height: 14 }), to: Some({ width: 28.53125, height: 26 }) }, count)
					}
					_ = Measure.start!({})
					result = LayeredFlowLabels.margins(model, 0, labels)
					observation = result.nodes.fold(0.0, |sum, node| sum + node.margin.right + node.margin.bottom).to_u64_try() ?? 0
					Measure.finish!(observation)
				}
			}
		}
	}
	Stdout.line!("${telemetry},\"operation\":\"${operation}\",\"edges\":${count.to_str()}}")
}
