## Placement-independent edge routing.
Route :: {}.{

	## Naive router: retain each supplied pair as a straight center-to-center path.
	##
	## TODO: Accept graph edges, node boxes, ports, and label boxes; clip
	## endpoints to rectangular boundaries; fan parallel edges; create stable
	## self-loop stubs; and return the common Line/Polyline/Curves route shape.
	## Add an optional orthogonal pass over an axis-aligned visibility graph with
	## bend and congestion costs, deterministic edge order, and track nudging.
	straight : List({ from : { x : F64, y : F64 }, to : { x : F64, y : F64 } }) -> List(
		{
			from : { x : F64, y : F64 },
			to : { x : F64, y : F64 },
		},
	)
	straight = |endpoints| endpoints
}

## Straight routing preserves endpoint order.
expect {
	endpoints = [{ from: { x: 0, y: 1 }, to: { x: 2, y: 3 } }]
	Route.straight(endpoints) == endpoints
}
