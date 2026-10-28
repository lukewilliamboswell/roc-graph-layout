import ClassDiagram
import ClassMember
import ClassRender
import Drawing
import EntityDraw
import EntityOracle
import Mermaid
import OracleJson
import Theme

## Internal native class parser/layout facts for independent browser comparison.
ClassOracle :: {}.{
	reference_theme : Theme.Options
	reference_theme = EntityOracle.reference_theme

	inspect : Str, Theme.Options -> Str
	inspect = |source, theme| ClassOracle.inspect_sized(source, theme, [])

	inspect_sized : Str, Theme.Options, List(OracleJson.Size) -> Str
	inspect_sized = |source, theme, overrides| match (ClassDiagram.parse(source), Mermaid.draw_with(source, Mermaid.Options.{ theme })) {
		(Ok(diagram), Ok(default_picture)) => {
			picture = if (overrides.is_empty()) default_picture else EntityDraw.draw_sized(ClassRender.nodes(diagram.classes), ClassRender.edges(diagram.relationships), diagram.direction, theme, diagram.classes.map(|c| c.id), overrides)
			ids = diagram.classes.map(|c| c.id)
			semantic = OracleJson.object([
				("direction", OracleJson.string(Str.inspect(diagram.direction))),
				(
					"classes",
					OracleJson.array(
						diagram.classes.map(
							|c| OracleJson.object([
								("id", OracleJson.string(c.id)),
								("label", OracleJson.string(c.label)),
								("generic_type", OracleJson.string(c.generic_type)),
								("fields", OracleJson.array(c.fields.map(|raw| ClassOracle.member(ClassMember.parse(raw, False))))),
								("methods", OracleJson.array(c.methods.map(|raw| ClassOracle.member(ClassMember.parse(raw, True))))),
								("annotations", OracleJson.strings(c.annotations.map(|a| Str.from_utf8_lossy(a.to_utf8().drop_first(2).drop_last(2))))),
							]),
						),
					),
				),
				(
					"relationships",
					OracleJson.array(
						diagram.relationships.map(
							|r| OracleJson.object([
								("from", OracleJson.string(ids.get(r.from) ?? "")),
								("to", OracleJson.string(ids.get(r.to) ?? "")),
								("kind", OracleJson.string(Str.inspect(r.kind))),
								("reversed", OracleJson.boolean(r.reversed)),
								("bidirectional", OracleJson.boolean(r.bidirectional)),
								("label", OracleJson.string(r.label)),
								("from_multiplicity", OracleJson.string(r.from_multiplicity)),
								("to_multiplicity", OracleJson.string(r.to_multiplicity)),
							]),
						),
					),
				),
			])
			geometry = EntityOracle.geometry_sized(ids, ClassRender.nodes(diagram.classes), ClassRender.edges(diagram.relationships), [], diagram.direction, theme, picture, overrides)
			OracleJson.object([("accepted", "true"), ("family", OracleJson.string("class")), ("semantic", semantic), ("geometry", geometry)])
		}
		_ => OracleJson.rejected("class")
	}

	member : ClassMember.Member -> Str
	member = |m| OracleJson.object([("visibility", OracleJson.string(m.visibility)), ("classifier", OracleJson.string(m.classifier)), ("id", OracleJson.string(m.id)), ("parameters", OracleJson.string(m.parameters)), ("return_type", OracleJson.string(m.return_type)), ("text", OracleJson.string(m.text))])
}
