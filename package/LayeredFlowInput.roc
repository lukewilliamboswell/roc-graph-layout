import LayeredFlowGraph

## Internal validated, index-addressed input to coordinated flow layout.
## Dimensions contain all reserved space; no text or rendering data enters
## the solver. Public recursive input is flattened before this boundary.
LayeredFlowInput :: {}.{
	Container : [Root, Group(U64)]
	Endpoint : [Node(U64), Group(U64)]
	Node : { container : Container }
	Edge : { from : Endpoint, to : Endpoint }
	Size : { width : F64, height : F64 }
	Group : {
		container : Container,
		direction : [Inherit, Set(LayeredFlowGraph.Direction)],
		separate : Bool,
		spacing : LayeredFlowGraph.Spacing,
		padding : LayeredFlowGraph.Margins,
		min_width : F64,
		min_height : F64,
	}
	Input : {
		direction : LayeredFlowGraph.Direction,
		nodes : List(Node),
		groups : List(Group),
		edges : List(Edge),
		spacing : LayeredFlowGraph.Spacing,
		padding : LayeredFlowGraph.Margins,
	}
	Sizes : {
		nodes : List(Size),
		edge_labels : List([None, Some(Size)]),
		group_titles : List(Size),
	}
	default_group : Group
	default_group = {
		container: Root,
		direction: Inherit,
		separate: False,
		spacing: LayeredFlowGraph.blank_spacing,
		padding: LayeredFlowGraph.no_box,
		min_width: 0,
		min_height: 0,
	}
}
