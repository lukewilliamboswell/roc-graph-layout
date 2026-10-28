import Drawing
import Flowchart
import FlowDrawEdge
import Theme

## State transitions use Mermaid's concave barb marker, not the flowchart
## triangle. Notes use the state inline2px dash pattern and no marker.
StateDrawEdge :: {}.{
	draw : Flowchart.Edge, List(Drawing.Point), List(FlowDrawEdge.Hop), Theme.Options -> List(Drawing.Item)
	draw = |edge, route, hops, options| {
		if route.len() < 2 {
			return []
		}
		n = route.len()
		end = route.last() ?? crash "nonempty route"
		before = route.get(n - 2) ?? end
		direction = FlowDrawEdge.direction(before, end)
		# The state renderer leaves5.5px of approach clearance, then places
		# a margin marker with refX17 and its tip at19.
		shifted = if edge.end == Arrow {
			route.set(n - 1, { x: end.x - direction.x * 5.5, y: end.y - direction.y * 5.5 }) ?? []
		} else route
		pieces = FlowDrawEdge.pieces(shifted, hops)
		total = pieces.fold(0.0, |length, piece| length + FlowDrawEdge.length(piece))
		pattern = if edge.line == Dotted and total <= 500000 {
			[2.0, 2.0]
		} else [total, 0]
		path = FlowDrawEdge.trace(pieces, FlowDrawEdge.dashes(total, pattern))
		line = Shape({ path, paint: { fill: NoFill, stroke: Stroke({ color: options.line, width: options.line_width }) } })
		if edge.end != Arrow {
			return [line]
		}
		match FlowDrawEdge.ends(pieces) {
			Err(_) => [line]
			Ok(at) => {
				place = |along, across| { x: at.end.x + at.end_dir.x * along - at.end_dir.y * across, y: at.end.y + at.end_dir.y * along + at.end_dir.x * across }
				barb = Drawing.polygon([place(2, 0), place(-6, 7), place(-4, 0), place(-6, -7)])
				[line, Shape({ path: barb, paint: { fill: Fill(options.line), stroke: NoStroke } })]
			}
		}
	}
}

expect {
	result = StateDrawEdge.draw({ id: "", from: Node(0), to: Node(1), label: "", line: Solid, start: None, end: Arrow, length: 1, classes: [], styles: [] }, [{ x: 0, y: 0 }, { x: 0, y: 50 }], [], Theme.Options.{})
	match result.last()? {
		Shape(shape) => shape.path == Drawing.polygon([{ x: 0, y: 46.5 }, { x: -7, y: 38.5 }, { x: 0, y: 40.5 }, { x: 7, y: 38.5 }])
		_ => False
	}
}
