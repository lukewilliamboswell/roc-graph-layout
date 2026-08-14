ExampleData :: {}.{
	GraphFixture : { labels : List(Str), graph : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) } }
	transit_network : GraphFixture
	transit_network = {
		labels: ["Central", "Museum", "Harbor", "Market", "University", "Gardens", "Stadium", "Airport", "North", "South"],
		graph: { nodes: List.repeat({ width: 92, height: 32 }, 10), edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 3 }, { from: 3, to: 4 }, { from: 4, to: 5 }, { from: 3, to: 6 }, { from: 6, to: 7 }, { from: 0, to: 8 }, { from: 0, to: 9 }, { from: 2, to: 5 }, { from: 5, to: 7 }] },
	}
}
