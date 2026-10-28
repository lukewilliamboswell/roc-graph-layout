import Flowchart
import FlowGeometry
import FlowLayout
import FlowLayoutAdjust
import FlowLayoutElk
import FlowLayoutGraph
import FlowLayoutImport
import FlowLayoutPlace
import FlowLayoutRandom
import FlowLayoutRoute

## State note containers carry an unpainted, unwrapped label in Mermaid's
## layout input. The label still reserves space outside the note frame.
StateLayout :: {}.{
	HiddenLabel : { group : U64, width : F64, height : F64 }

	layout : Flowchart.Diagram, FlowGeometry.Sizes, List(HiddenLabel), List(U64), List(FlowLayoutImport.Item) -> FlowGeometry.Geometry
	layout = |diagram, sizes, labels, edge_order, registration| {
		ordered_diagram = { ..diagram, edges: edge_order.map(|i| diagram.edges.get(i) ?? crash "source edge index in bounds") }
		ordered_sizes = { ..sizes, edge_labels: edge_order.map(|i| sizes.edge_labels.get(i) ?? None) }
		setup = FlowLayoutImport.build_registered(ordered_diagram, ordered_sizes, registration)
		layered = FlowLayoutElk.layered(setup.model)
		ordered = FlowLayoutElk.order(layered, False, [])
		var $hidden = List.repeat(None, setup.model.nodes.len())
		for label in labels {
			n = setup.group_node.get(label.group) ?? FlowLayoutGraph.nil
			if n < $hidden.len() {
				$hidden = $hidden.set(n, Some(label)) ?? []
			}
		}
		var $m = ordered.model
		for g in FlowLayoutElk.bottom_up(ordered.model) {
			direction = FlowLayoutGraph.graph($m, g).direction
			vertical = FlowLayoutElk.vertical(direction)
			$m = FlowLayoutPlace.prepare($m, g, vertical)
			for layer in FlowLayoutGraph.graph($m, g).layers {
				for n in layer {
					node = FlowLayoutGraph.node($m, n)
					match node.origin {
						Group(_) => match $hidden.get(n) ?? None {
							None => {}
							Some(label) => {
								# A centred, unwrapped group label reserves equal
								# margins outside its frame on both sides.
								physical = FlowLayoutImport.internal_size(direction, label.width, 0)
								extra_x = (physical.width - node.width).max(0) / 2
								extra_y = (physical.height - node.height).max(0) / 2
								margin = { top: node.margin.top.max(extra_y), bottom: node.margin.bottom.max(extra_y), left: node.margin.left.max(extra_x), right: node.margin.right.max(extra_x) }
								$m = FlowLayoutGraph.set_node($m, n, { ..node, margin })
							}
						}
						_ => {}
					}
				}
			}
			$m = FlowLayoutPlace.brandes_koepf($m, g)
			fin = FlowLayoutRoute.finish($m, g, vertical, direction == Up, ordered.randoms.get(g) ?? FlowLayoutRandom.from_seed(1))
			$m = fin.model
			graph = FlowLayoutGraph.graph($m, g)
			if graph.separate {
				box = FlowLayoutGraph.node($m, graph.parent)
				outer = FlowLayoutGraph.graph($m, box.graph).direction
				if FlowLayoutElk.vertical(outer) != vertical {
					$m = FlowLayoutGraph.set_node($m, graph.parent, { ..box, width: box.height, height: box.width })
				}
			}
		}
		ordered_raw = FlowLayoutElk.export(ordered_diagram, setup, $m)
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
		nodes = adjusted.nodes.map_with_index(|rect, i| if ((diagram.nodes.get(i) ?? FlowLayoutImport.no_node).shape == Diamond) { ..rect, x: rect.x + 0.5 } else rect)
		FlowLayout.normalise({ nodes, groups: adjusted.groups, edges: adjusted.edges, bounds: { x: 0, y: 0, width: 0, height: 0 } }, label_sizes, title_sizes)
	}
}
