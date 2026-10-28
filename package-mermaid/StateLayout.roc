import Flowchart
import FlowGeometry
import FlowLayout
import FlowCore
import FlowLayoutAdjust
import FlowSourceLayout

## State note containers carry an unpainted, unwrapped label in Mermaid's
## layout input. The label still reserves space outside the note frame.
StateLayout :: {}.{
	HiddenLabel : { group : U64, width : F64, height : F64 }

	layout : Flowchart.Diagram, FlowGeometry.Sizes, List(HiddenLabel), List(U64), List(FlowSourceLayout.Item) -> FlowGeometry.Geometry
	layout = |diagram, sizes, labels, edge_order, registration| {
		ordered_diagram = { ..diagram, edges: edge_order.map(|i| diagram.edges.get(i) ?? crash "source edge index in bounds") }
		ordered_sizes = { ..sizes, edge_labels: edge_order.map(|i| sizes.edge_labels.get(i) ?? None) }
		# Hidden note labels reserve horizontal space but are not painted titles.
		reservations = labels.map(|label| { ..label, height: 0 })
		ordered_raw = FlowCore.arrange(ordered_diagram, ordered_sizes, [], reservations, registration).raw
		var $edge_of = List.repeat(0, edge_order.len())
		for i in 0..<edge_order.len() {
			$edge_of = $edge_of.set(edge_order.get(i) ?? 0, i) ?? []
		}
		raw = { ..ordered_raw, edges: $edge_of.map(|i| ordered_raw.edges.get(i) ?? crash "edge output aligned") }
		adjusted = FlowLayoutAdjust.adjust(diagram, sizes, raw)
		label_sizes = sizes.edge_labels.map(
			|label| match label {
				None => None
				Some(block) => Some({ width: block.width + 4, height: block.height + 4 })
			},
		)
		title_sizes = sizes.group_titles.map(|block| { width: block.width, height: block.height })
		nodes = adjusted.nodes.map_with_index(|rect, i| if ((diagram.nodes.get(i) ?? FlowSourceLayout.no_node).shape == Diamond) { ..rect, x: rect.x + 0.5 } else rect)
		FlowLayout.normalise({ nodes, groups: adjusted.groups, edges: adjusted.edges, bounds: { x: 0, y: 0, width: 0, height: 0 } }, label_sizes, title_sizes)
	}
}
