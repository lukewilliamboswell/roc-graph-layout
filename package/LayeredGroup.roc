import LayeredFlowGraph

## Recursive geometric ownership value. Construction is exposed through
## Layered.group; solver phases and validation helpers are separate.
LayeredGroup := [
	Group(
		{
			children : List([Node(U64), Nested(LayeredGroup)]),
			flow : [Together, Separate([Down, Up, Left, Right])],
			spacing : [Inherit, Set(LayeredFlowGraph.Spacing)],
			padding : { top : F64, right : F64, bottom : F64, left : F64 },
			min_width : F64,
			min_height : F64,
		},
	),
]
