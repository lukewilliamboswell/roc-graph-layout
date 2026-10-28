import FlowGeometry
import layout.Layered

## Geometry-only adaptation shared by Mermaid renderers. Core outputs retain
## source indices; these helpers attach measured labels to the matching edge.
DiagramLayout :: {}.{
	finite_size : F64 -> F64
	finite_size = |value| if (F64.is_finite(value) and value > 0) value else 0
	Edge : { points : List(FlowGeometry.Point), label : [None, Some(FlowGeometry.Point)] }
	Placement : { point : FlowGeometry.Point, port : FlowGeometry.Point }
	Ends : { from : [None, Some(Placement)], to : [None, Some(Placement)] }
	routes : Layered.GroupedResult, List({ edge : U64, width : F64, height : F64 }) -> List(Edge)
	routes = |result, labels| {
		var $edges = result.layout.routes.map(
			|route| {
				points = match route {
					Polyline(values) => values
					Line(a, b) => [a, b]
					Curves(_) => crash "coordinated layout returns polylines"
				}
				{ points, label: None }
			},
		)
		for (label, index) in labels.map_with_index(|label, index| (label, index)) {
			edge = $edges.get(label.edge) ?? crash "validated center-label edge"
			anchor = result.label_anchors.get(index) ?? crash "center labels are source aligned"
			$edges = $edges.set(label.edge, { ..edge, label: Some(anchor) }) ?? []
		}
		$edges
	}
	ends : Layered.GroupedResult, List({ edge : U64, endpoint : [From, To], width : F64, height : F64 }) -> List(Ends)
	ends = |result, labels| {
		var $ends = List.repeat({ from: None, to: None }, result.layout.routes.len())
		for (label, index) in labels.map_with_index(|label, index| (label, index)) {
			placement = Some(result.end_label_placements.get(index) ?? crash "endpoint labels are source aligned")
			old = $ends.get(label.edge) ?? crash "validated endpoint-label edge"
			$ends = $ends.set(
				label.edge,
				if label.endpoint == From {
					{ ..old, from: placement }
				} else {
					{ ..old, to: placement }
				},
			) ?? []
		}
		$ends
	}
}
