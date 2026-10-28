import Drawing
import FlowLayoutGraph

## Frozen authoring benchmark control before crowded label-strip placement.
## Not used by any production drawing.
## The prior head/tail-label margin phase, shared by real class rendering and
## reference-sized layout probes. Labels extend their node's margins before
## node balancing and edge routing, rather than becoming extra ranks.
ClassMarginBefore :: {}.{
	LabelSize : { width : F64, height : F64 }
	Ends : { from : [None, Some(LabelSize)], to : [None, Some(LabelSize)] }
	Cell : { port : FlowLayoutGraph.Port, along : F64, cross : F64, thickness : F64 }

	## ELK EndLabelPreprocessor: gather each port's padded head/tail labels,
	## select their smart side, then union their rectangles into node margins.
	## Internal model coordinates always read left to right. Only dimensions,
	## never oracle positions, participate in this production phase.
	margins : FlowLayoutGraph.Model, U64, List(Ends), Bool -> FlowLayoutGraph.Model
	margins = |model, g, labels, vertical| {
		var $model = model
		spacing = FlowLayoutGraph.graph(model, g).spacing
		for layer in FlowLayoutGraph.graph(model, g).layers {
			for index in layer {
				node = FlowLayoutGraph.node($model, index)
				if node.kind == Normal {
					var $cells = []
					for p in node.ports {
						port = FlowLayoutGraph.port($model, p)
						var $along = 0.0
						var $cross = 0.0
						var $thickness = 0.0
						for e in port.outgoing.concat(port.incoming) {
							edge = FlowLayoutGraph.edge($model, e)
							ends = labels.get(edge.origin) ?? { from: None, to: None }
							is_from = (edge.source == p) != edge.reversed
							maybe_size = if is_from {
								ends.from
							} else {
								ends.to
							}
							match maybe_size {
								None => {}
								Some(size) => {
									$along = $along.max(
										if vertical {
											size.height
										} else {
											size.width
										},
									)
									$cross = $cross + (
										if vertical {
											size.width
										} else {
											size.height
										}
									)
									$thickness = $thickness.max(edge.thickness)
								}
							}
						}
						if $along > 0 or $cross > 0 {
							$cells = $cells.append({ port, along: $along, cross: $cross, thickness: $thickness })
						}
					}
					var $margin = node.margin
					for side in [North, East, South, West] {
						cells = $cells.keep_if(|cell| cell.port.side == side)
						for c in 0..<cells.len() {
							cell = cells.get(c) ?? crash "proven cell index"
							above = cells.len() == 2 and (
								if side == North or side == East {
									c == 0
								} else {
									c == 1
								}
							)
							gap = cell.thickness + spacing.edge_label
							anchor_x = cell.port.x + cell.port.anchor_x
							anchor_y = cell.port.y + cell.port.anchor_y
							cross_low = if above {
								anchor_y - gap - cell.cross
							} else {
								anchor_y + gap
							}
							along_low = if above {
								anchor_x - gap - cell.along
							} else {
								anchor_x + gap
							}
							box = match side {
								East => { x: node.width + node.margin.right + spacing.edge_label, y: cross_low, width: cell.along, height: cell.cross }
								West => { x: -node.margin.left - spacing.edge_label - cell.along, y: cross_low, width: cell.along, height: cell.cross }
								North => { x: along_low, y: -node.margin.top - spacing.edge_label - cell.cross, width: cell.along, height: cell.cross }
								South => { x: along_low, y: node.height + node.margin.bottom + spacing.edge_label, width: cell.along, height: cell.cross }
								Undefined => { x: 0, y: 0, width: 0, height: 0 }
							}
							$margin = { top: $margin.top.max(-box.y), left: $margin.left.max(-box.x), right: $margin.right.max(box.x + box.width - node.width), bottom: $margin.bottom.max(box.y + box.height - node.height) }
						}
					}
					$model = FlowLayoutGraph.set_node($model, index, { ..node, margin: $margin })
				}
			}
		}
		$model
	}

}
