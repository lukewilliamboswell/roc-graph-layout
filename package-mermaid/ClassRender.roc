import Drawing
import EntityDraw
import Theme

## Internal class-to-geometry projection shared by rendering and instrumentation.
ClassRender :: {}.{
	Class : { id : Str, label : Str, generic_type : Str, fields : List(Str), methods : List(Str), annotations : List(Str) }
	Relationship : { from : U64, to : U64, kind : [Inheritance, Realization, Composition, Aggregation, Association, Dependency, Link, DottedLink], reversed : Bool, bidirectional : Bool, label : Str, from_multiplicity : Str, to_multiplicity : Str }
	Diagram : { classes : List(Class), relationships : List(Relationship), direction : [Down, Up, Left, Right] }
	nodes : List(Class) -> List(EntityDraw.Node)
	nodes = |classes| classes.map(
		|c| {
			title = if (c.generic_type.is_empty()) c.label else "${c.label}<${c.generic_type}>"
			annotations = c.annotations.take_first(1).map(|a| "«${Str.from_utf8_lossy(a.to_utf8().drop_first(2).drop_last(2))}»")
			sections = [c.fields, c.methods]
			{ kind: ClassBox, table: [], title, annotations, sections }
		},
	)
	edges : List(Relationship) -> List(EntityDraw.Edge)
	edges = |relationships| relationships.map(
		|r| {
			marker = match r.kind {
				Inheritance | Realization => Triangle
				Composition => Diamond(True)
				Aggregation => Diamond(False)
				Association | Dependency => Arrow
				Link | DottedLink => None
			}
			{ from: r.from, to: r.to, label: r.label, from_label: r.from_multiplicity, to_label: r.to_multiplicity, from_mark: if (r.reversed or r.bidirectional) marker else None, to_mark: if (!r.reversed or r.bidirectional) marker else None, dashed: r.kind == Dependency or r.kind == Realization or r.kind == DottedLink }
		},
	)
	draw : Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, theme| EntityDraw.draw(ClassRender.nodes(diagram.classes), ClassRender.edges(diagram.relationships), diagram.direction, theme)
}
