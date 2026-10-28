import Geom
import LayeredFlowGraph
import LayeredFlowPlace
import LayeredFlow

## Geometric endpoint-label packing. Measured label rectangles extend node
## margins before balancing and routing, rather than becoming extra layers.
LayeredFlowLabels :: {}.{
	LabelSize : { width : F64, height : F64 }
	Ends : { from : [None, Some(LabelSize)], to : [None, Some(LabelSize)] }
	Part : { edge : U64, from : Bool, along : F64, cross : F64 }
	Cell : { port : LayeredFlowGraph.Port, along : F64, cross : F64, thickness : F64, parts : List(Part) }
	PlacedCell : { cell : Cell, box : Geom.Rect }
	Placement : { point : Geom.Point, port : Geom.Point }
	EndPlacements : { from : [None, Some(Placement)], to : [None, Some(Placement)] }

	## ELK EndLabelPreprocessor: gather each port's padded head/tail labels,
	## select their smart side, then union their rectangles into node margins.
	## Internal model coordinates always read left to right. Only dimensions,
	## never oracle positions, participate in this production phase.
	margins : LayeredFlowGraph.Model, U64, List(Ends) -> LayeredFlowGraph.Model
	margins = |model, g, labels| {
		vertical = LayeredFlow.vertical(LayeredFlowGraph.graph(model, g).direction)
		if labels.all(|ends| ends.from == None and ends.to == None) {
			return model
		}
		var $model = model
		spacing = LayeredFlowGraph.graph(model, g).spacing
		for layer in LayeredFlowGraph.graph(model, g).layers {
			for index in layer {
				node = LayeredFlowGraph.node($model, index)
				if node.kind == Normal {
					var $margin = node.margin
					for placed in LayeredFlowLabels.node_cells($model, node, labels, vertical, spacing.edge_label, spacing.label_label * 2) {
						box = placed.box
						$margin = { top: $margin.top.max(-box.y), left: $margin.left.max(-box.x), right: $margin.right.max(box.x + box.width - node.width), bottom: $margin.bottom.max(box.y + box.height - node.height) }
					}
					$model = LayeredFlowGraph.set_node($model, index, { ..node, margin: $margin })
				}
			}
		}
		$model
	}

	node_cells : LayeredFlowGraph.Model, LayeredFlowGraph.Node, List(Ends), Bool, F64, F64 -> List(PlacedCell)
	node_cells = |model, node, labels, vertical, edge_label, label_label| {
		var $cells = []
		for p in node.ports {
			port = LayeredFlowGraph.port(model, p)
			var $along = 0.0
			var $cross = 0.0
			var $thickness = 0.0
			var $parts = []
			for e in port.outgoing.concat(port.incoming) {
				edge = LayeredFlowGraph.edge(model, e)
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
						$parts = $parts.append({
							edge: edge.origin,
							from: is_from,
							along: if vertical {
								size.height
							} else {
								size.width
							},
							cross: if vertical {
								size.width
							} else {
								size.height
							},
						})
					}
				}
			}
			if $along > 0 or $cross > 0 {
				$cells = $cells.append({ port, along: $along, cross: $cross, thickness: $thickness, parts: $parts })
			}
		}
		var $placed = []
		for side in [North, East, South, West] {
			side_cells = $cells.keep_if(|cell| cell.port.side == side)
			for c in 0..<side_cells.len() {
				cell = side_cells.get(c) ?? crash "proven cell index"
				above = side_cells.len() == 2 and (
					if side == North or side == East {
						c == 0
					} else {
						c == 1
					}
				)
				gap = cell.thickness + edge_label
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
					East => { x: node.width + node.margin.right + edge_label, y: cross_low, width: cell.along, height: cell.cross }
					West => { x: -node.margin.left - edge_label - cell.along, y: cross_low, width: cell.along, height: cell.cross }
					North => { x: along_low, y: -node.margin.top - edge_label - cell.cross, width: cell.along, height: cell.cross }
					South => { x: along_low, y: node.height + node.margin.bottom + edge_label, width: cell.along, height: cell.cross }
					Undefined => { x: 0, y: 0, width: 0, height: 0 }
				}
				$placed = $placed.append({ cell, box })
			}
		}
		$placed = LayeredFlowLabels.strip($placed, node, edge_label, label_label, vertical)
		$placed
	}

	Key : { key : F64, index : U64 }

	## Stable bottom-up merge avoids the pinned compiler's quadratic sorted
	## builtin path. Equal coordinates preserve source port order.
	sort : List(Key) -> List(Key)
	sort = |keys| {
		var $source = keys
		var $target = List.repeat({ key: 0, index: 0 }, keys.len())
		var $width = 1
		while $width < keys.len() {
			var $start = 0
			while $start < keys.len() {
				middle = ($start + $width).min(keys.len())
				end = (middle + $width).min(keys.len())
				var $a = $start
				var $b = middle
				for out in $start..<end {
					left = $source.get($a) ?? { key: 0, index: 0 }
					right = $source.get($b) ?? { key: 0, index: 0 }
					use_left = $a < middle and ($b >= end or left.key <= right.key)
					$target = $target.set(
						out,
						if use_left {
							left
						} else {
							right
						},
					) ?? []
					if use_left {
						$a = $a + 1
					} else {
						$b = $b + 1
					}
				}
				$start = end
			}
			previous = $source
			$source = $target
			$target = previous
			$width = $width * 2
		}
		$source
	}

	## ELK's rectangle-strip first-fit placement. The overlap graph itself
	## may be quadratic when every measured label occupies the same strip.
	## Lists stay flat and indexed; only genuine cross-interval intersections
	## participate in first-fit placement, ordered by their current strip depth.
	strip : List(PlacedCell), LayeredFlowGraph.Node, F64, F64, Bool -> List(PlacedCell)
	strip = |cells, node, edge_label, gap, vertical| {
		var $result = cells
		for side in (
			if vertical {
				[East, West]
			} else {
				[North, South]
			}
		) {
			keys = cells.map_with_index(
				|cell, index| {
					key: if vertical {
						cell.box.y
					} else {
						cell.box.x
					},
					index,
				},
			).keep_if(|key| (cells.get(key.index) ?? crash "cell index").cell.port.side == side)
			order = LayeredFlowLabels.sort(keys)
			var $offsets = List.repeat(0.0, cells.len())
			var $placed = []
			for key in order {
				current = cells.get(key.index) ?? crash "cell index"
				cross_size = if vertical {
					current.box.height
				} else {
					current.box.width
				}
				depth = if vertical {
					current.box.width
				} else {
					current.box.height
				}
				overlaps = $placed.keep_if(
					|old| {
						box = (cells.get(old) ?? crash "cell index").box
						low = if vertical {
							box.y
						} else {
							box.x
						}
						high = low + (
							if vertical {
								box.height
							} else {
								box.width
							}
						)
						low <= key.key + cross_size and high >= key.key
					},
				).map(|index| { key: $offsets.get(index) ?? 0, index })
				var $offset = 0.0
				for old in LayeredFlowLabels.sort(overlaps) {
					box = (cells.get(old.index) ?? crash "cell index").box
					old_depth = if vertical {
						box.width
					} else {
						box.height
					}
					if $offset < old.key + old_depth + gap and $offset + depth + gap > old.key {
						$offset = old.key + old_depth + gap
					}
				}
				$offsets = $offsets.set(key.index, $offset) ?? []
				$placed = $placed.append(key.index)
				box = match side {
					East => { ..current.box, x: node.width + node.margin.right + edge_label + $offset }
					West => { ..current.box, x: -node.margin.left - edge_label - depth - $offset }
					North => { ..current.box, y: -node.margin.top - edge_label - depth - $offset }
					South => { ..current.box, y: node.height + node.margin.bottom + edge_label + $offset }
					Undefined => current.box
				}
				$result = $result.set(key.index, { ..current, box }) ?? []
			}
		}
		$result
	}

	placements : LayeredFlowGraph.Model, List(Ends) -> List(EndPlacements)
	placements = |placed, labels| {
		if labels.all(|ends| ends.from == None and ends.to == None) {
			return List.repeat({ from: None, to: None }, labels.len())
		}
		# Reconstruct the same local cells from port-only margins; the placed
		# model already includes the expanded margins and must not add them twice.
		var $port_model = placed
		for g in LayeredFlow.bottom_up(placed) {
			$port_model = LayeredFlowPlace.margins($port_model, g)
		}
		model = $port_model
		bases = LayeredFlow.origins(model)
		places = LayeredFlow.placements(model, bases)
		var $result = List.repeat({ from: None, to: None }, labels.len())
		for node in model.nodes {
			if node.kind == Normal {
				spacing = LayeredFlowGraph.graph(model, node.graph).spacing
				vertical = LayeredFlow.vertical(LayeredFlowGraph.graph(model, node.graph).direction)
				base = bases.get(node.graph) ?? { x: 0, y: 0 }
				place = places.get(node.graph) ?? { direction: Right, dx: 0, dy: 0 }
				world = |point| LayeredFlow.place_point(place, { x: base.x + node.x + point.x, y: base.y + node.y + point.y })
				for cell in LayeredFlowLabels.node_cells(model, node, labels, vertical, spacing.edge_label, spacing.label_label * 2) {
					var $cross = 0.0
					for part in cell.cell.parts {
						along = if cell.cell.port.side == West {
							cell.box.width - part.along / 2
						} else {
							part.along / 2
						}
						point = world({ x: cell.box.x + along, y: cell.box.y + $cross + part.cross / 2 })
						port = world({ x: cell.cell.port.x + cell.cell.port.anchor_x, y: cell.cell.port.y + cell.cell.port.anchor_y })
						value = Some({ point, port })
						current = $result.get(part.edge) ?? crash "source-aligned label edge"
						$result = $result.set(
							part.edge,
							if part.from {
								{ ..current, from: value }
							} else {
								{ ..current, to: value }
							},
						) ?? []
						$cross = $cross + part.cross
					}
				}
			}
		}
		$result
	}
}
