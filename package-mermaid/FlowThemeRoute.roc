import Flowchart
import FlowGeometry

## Project rounded-node attachments onto their actual custom-radius border.
## Only a route's terminal coordinate along its existing axis changes; its
## other points, node positions and edge-label positions remain unchanged.
FlowThemeRoute :: {}.{
	clip : Flowchart.Diagram, FlowGeometry.Geometry, F64 -> FlowGeometry.Geometry
	clip = |diagram, geometry, radius| {
		if radius <= 0 or !diagram.nodes.any(|node| node.shape == Rounded) {
			geometry
		} else {
			{
				..geometry,
				edges: geometry.edges.map_with_index(
					|route, i| {
						match diagram.edges.get(i) {
							Err(_) => route
							Ok(edge) => {
								start = FlowThemeRoute.at_node(edge.from, diagram, geometry, route.points, radius)
								points = FlowThemeRoute.at_node(edge.to, diagram, geometry, start.rev(), radius).rev()
								{ ..route, points }
							}
						}
					},
				),
			}
		}
	}

	at_node : Flowchart.Endpoint, Flowchart.Diagram, FlowGeometry.Geometry, List(FlowGeometry.Point), F64 -> List(FlowGeometry.Point)
	at_node = |endpoint, diagram, geometry, points, radius| match endpoint {
		Group(_) => points
		Node(i) => match (diagram.nodes.get(i), geometry.nodes.get(i)) {
			(Ok(node), Ok(rect)) if node.shape == Rounded => FlowThemeRoute.terminal(points, rect, radius)
			_ => points
		}
	}

	terminal : List(FlowGeometry.Point), FlowGeometry.Rect, F64 -> List(FlowGeometry.Point)
	terminal = |points, rect, radius| match points.first() {
		Err(_) => points
		Ok(first) => match points.find_first(|candidate| (candidate.x - first.x).abs() > 0.000001 or (candidate.y - first.y).abs() > 0.000001) {
			Err(_) => points
			Ok(next) => {
				projected = FlowThemeRoute.project_point(rect, radius, first, next)
				if projected == first {
					points
				} else {
					# first() proved that zero is an in-bounds index.
					points.set(0, projected) ?? []
				}
			}
		}
	}

	project_point : FlowGeometry.Rect, F64, FlowGeometry.Point, FlowGeometry.Point -> FlowGeometry.Point
	project_point = |rect, given_radius, first, next| {
		radius = given_radius.min(rect.width / 2).min(rect.height / 2)
		if radius <= 0 or FlowThemeRoute.on_outline(first, rect, radius) {
			return first
		}
		if (next.x - first.x).abs() <= 0.000001 and (next.y - first.y).abs() <= 0.000001 {
			return first
		}
		if (next.y - first.y).abs() <= 0.000001 {
			if first.y < rect.y or first.y > rect.y + rect.height {
				return first
			}
			across = (radius - (first.y - rect.y).min(rect.y + rect.height - first.y)).max(0).min(radius)
			depth = radius - (radius * radius - across * across).max(0).sqrt()
			{ x: if (first.x <= rect.x + rect.width / 2) rect.x + depth else rect.x + rect.width - depth, y: first.y }
		} else if (next.x - first.x).abs() <= 0.000001 {
			if first.x < rect.x or first.x > rect.x + rect.width {
				return first
			}
			across = (radius - (first.x - rect.x).min(rect.x + rect.width - first.x)).max(0).min(radius)
			depth = radius - (radius * radius - across * across).max(0).sqrt()
			{ x: first.x, y: if (first.y <= rect.y + rect.height / 2) rect.y + depth else rect.y + rect.height - depth }
		} else {
			# Layout supplies orthogonal terminal segments. For malformed
			# geometry neither independent coordinate change is justified.
			first
		}
	}

	## Equation of the border, used independently by geometry tests. Straight
	## sides and quarter circles share the distance to the inner rectangle.
	on_outline : FlowGeometry.Point, FlowGeometry.Rect, F64 -> Bool
	on_outline = |point, rect, given_radius| {
		radius = given_radius.min(rect.width / 2).min(rect.height / 2)
		dx = (point.x - (rect.x + rect.width / 2)).abs() - (rect.width / 2 - radius)
		dy = (point.y - (rect.y + rect.height / 2)).abs() - (rect.height / 2 - radius)
		distance = (dx.max(0) * dx.max(0) + dy.max(0) * dy.max(0)).sqrt() + dx.max(dy).min(0) - radius
		distance.abs() < 0.00001
	}
}

expect {
	rect = { x: 10, y: 20, width: 160, height: 100 }
	paths = [
		[{ x: 22, y: 20 }, { x: 22, y: 0 }],
		[{ x: 158, y: 120 }, { x: 158, y: 140 }],
		[{ x: 10, y: 32 }, { x: 0, y: 32 }],
		[{ x: 170, y: 108 }, { x: 190, y: 108 }],
	]
	paths.all(
		|points| {
			clipped = FlowThemeRoute.terminal(points, rect, 50)
			first = clipped.first() ?? { x: 0, y: 0 }
			original = points.first() ?? { x: 0, y: 0 }
			next = points.get(1) ?? original
			FlowThemeRoute.on_outline(first, rect, 50) and clipped.get(1) == points.get(1)
				and (if (original.x == next.x) first.x == original.x else first.y == original.y)
		},
	)
}

expect {
	rect = { x: 0, y: 0, width: 100, height: 40 }
	points = [{ x: 50, y: 0 }, { x: 50, y: -20 }]
	FlowThemeRoute.terminal(points, rect, 20) == points
		and FlowThemeRoute.terminal([], rect, 20) == []
		and FlowThemeRoute.terminal([{ x: 0, y: 0 }], rect, 20) == [{ x: 0, y: 0 }]
}
