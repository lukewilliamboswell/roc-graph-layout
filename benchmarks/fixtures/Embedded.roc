## Small compile-time fixtures shared by the benchmark dispatcher. Large
## scaling ladders stay generated so compiler time is not part of the result.
Embedded := [].{
	get : Str -> { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }
	get = |name| if name == "service_ring" {
		{
			nodes: List.repeat({ width: 64, height: 32 }, 8),
			edges: [
				{ from: 0, to: 1 },
				{ from: 1, to: 2 },
				{ from: 2, to: 3 },
				{ from: 3, to: 4 },
				{ from: 4, to: 5 },
				{ from: 5, to: 6 },
				{ from: 6, to: 7 },
				{ from: 7, to: 0 },
				{ from: 0, to: 4 },
				{ from: 2, to: 6 },
			],
		}
	} else {
		{
			nodes: List.repeat({ width: 90, height: 40 }, 7),
			edges: [
				{ from: 0, to: 1 },
				{ from: 0, to: 2 },
				{ from: 1, to: 3 },
				{ from: 2, to: 3 },
				{ from: 3, to: 4 },
				{ from: 3, to: 5 },
				{ from: 4, to: 6 },
				{ from: 5, to: 6 },
				{ from: 0, to: 5 },
			],
		}
	}
}
