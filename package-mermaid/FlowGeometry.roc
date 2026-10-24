## The values passed between the stages that turn a `Flowchart.Diagram`
## into a drawing: text measurement and node sizing produce `Sizes`, layout
## turns them into `Geometry`, and drawing reads both. Every list is
## index-aligned with the matching list of the diagram: `nodes` with its
## nodes, `edge_labels` and `edges` with its edges, `group_titles` and
## `groups` with its groups.
##
## Units are CSS pixels, with x to the right and y down, as in SVG.
FlowGeometry :: {}.{

	Point : { x : F64, y : F64 }

	## A box by its top-left corner.
	Rect : { x : F64, y : F64, width : F64, height : F64 }

	## A label as drawn: its lines, after explicit breaks and wrapping, and
	## the size of the box they fill.
	TextBlock : { lines : List(Str), width : F64, height : F64 }

	## How much room each part of a diagram needs. A node's `width` and
	## `height` are its whole shape's bounding box, label and padding
	## included. An edge without a label has `None`.
	Sizes : {
		nodes : List({ width : F64, height : F64, label : TextBlock }),
		edge_labels : List([None, Some(TextBlock)]),
		group_titles : List(TextBlock),
	}

	## Where each part of a diagram goes. A node's rectangle is its shape's
	## bounding box. An edge is a polyline from its start's outline to its
	## end's outline, with the centre of its label if it has one. A group's
	## rectangle encloses its members and its title. `bounds` encloses
	## everything.
	Geometry : {
		nodes : List(Rect),
		edges : List({ points : List(Point), label : [None, Some(Point)] }),
		groups : List(Rect),
		bounds : Rect,
	}
}
