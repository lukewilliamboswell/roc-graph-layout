import Drawing
import EntityDraw
import Theme

## Internal ER-to-geometry projection shared by rendering and instrumentation.
EntityRender :: {}.{
	Attribute : { type : Str, name : Str, keys : List(Str), comment : Str }
	Entity : { id : Str, label : Str, attributes : List(Attribute) }
	Relationship : { from : U64, to : U64, from_cardinality : [ExactlyOne, ZeroOne, OneMany, ZeroMany], to_cardinality : [ExactlyOne, ZeroOne, OneMany, ZeroMany], identifying : Bool, label : Str }
	Diagram : { entities : List(Entity), relationships : List(Relationship), direction : [Down, Up, Left, Right] }
	nodes : List(Entity) -> List(EntityDraw.Node)
	nodes = |entities| entities.map(
		|entity| {
			keys = entity.attributes.any(|a| !a.keys.is_empty())
			comments = entity.attributes.any(|a| !a.comment.is_empty())
			table = entity.attributes.map(
				|a| {
					core = [a.type, a.name]
					with_keys = if (keys) core.append(Str.join_with(a.keys, ",")) else core
					if (comments) with_keys.append(a.comment) else with_keys
				},
			)
			{ kind: EntityBox, has_comment_column: comments, title: entity.label, annotations: [], sections: [], table }
		},
	)
	edges : List(Relationship) -> List(EntityDraw.Edge)
	edges = |relationships| relationships.map(|r| { from: r.from, to: r.to, label: r.label, from_label: "", to_label: "", from_mark: Cardinality(r.from_cardinality), to_mark: Cardinality(r.to_cardinality), dashed: !r.identifying })
	draw : Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, theme| EntityDraw.draw(EntityRender.nodes(diagram.entities), EntityRender.edges(diagram.relationships), diagram.direction, theme)
}
