import ClassDiagram
import ClassMember
import ClassRender
import Drawing
import EntityDraw
import EntityOracle
import OracleJson
import Theme

## Internal native class parser/layout facts for independent browser comparison.
ClassOracle :: {}.{
	reference_theme : Theme.Options
	reference_theme = EntityOracle.reference_theme

	inspect : Str, Theme.Options -> Str
	inspect = |source, theme| ClassOracle.inspect_sized(source, theme, [])

	inspect_sized : Str, Theme.Options, List(OracleJson.Size) -> Str
	inspect_sized = |source, theme, overrides| match (ClassDiagram.parse(source), ClassDiagram.draw(source, theme)) {
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
			OracleJson.object([("accepted", "true"), ("family", OracleJson.string("class")), ("semantic", semantic), ("geometry", geometry), ("size_problems", EntityOracle.size_problems(ids, ClassRender.edges(diagram.relationships), overrides))])
		}
		_ => OracleJson.rejected("class")
	}

	member : ClassMember.Member -> Str
	member = |m| OracleJson.object([("visibility", OracleJson.string(m.visibility)), ("classifier", OracleJson.string(m.classifier)), ("id", OracleJson.string(m.id)), ("parameters", OracleJson.string(m.parameters)), ("return_type", OracleJson.string(m.return_type)), ("text", OracleJson.string(m.text))])
}

expect ClassOracle.inspect_sized("classDiagram\nclass A", Theme.Options.{}, [{ kind: "label", id: "missing", width: 10, height: 10 }]).contains("unconsumed label:missing")

## Pinned independent head/tail-label fixture: the same production placement
## must reserve lateral margins before balancing node columns.
expect {
	source = "classDiagram\n A \"1\" --> \"many\" B\n C \"1\" --> D\n E --> \"many\" F\n G \"1\" --> \"many\" H : labelled\n I --> J : labelled"
	match ClassDiagram.parse(source) {
		Err(_) => False
		Ok(diagram) => {
			arranged = EntityDraw.arrange(ClassRender.nodes(diagram.classes), ClassRender.edges(diagram.relationships), diagram.direction, Theme.Options.{})
			arranged.result.layout.positions.get(2) == Ok({ x: 131.234375, y: 50.5 })
				and arranged.result.layout.positions.get(6) == Ok({ x: 317.90625, y: 50.5 })
				and arranged.result.layout.positions.get(9) == Ok({ x: 419.25, y: 362.5 })
		}
	}
}

## Independent four-port multiplicity fixture: source label cells require
## three14px strip rows, then named-side reflection must respect other routes.
expect {
	match ClassDiagram.parse("classDiagram\nHub \"1..*\" --> \"0..1\" A\nHub \"1..*\" --> \"0..1\" B\nHub \"1..*\" --> \"0..1\" C\nHub \"1..*\" --> \"0..1\" D") {
		Err(_) => False
		Ok(diagram) => {
			arranged = EntityDraw.arrange(ClassRender.nodes(diagram.classes), ClassRender.edges(diagram.relationships), Down, Theme.Options.{})
			arranged.result.layout.positions.get(1) == Ok({ x: 28.8359375, y: 263.5 })
				and arranged.result.layout.bounds.width == 331.71875
				and arranged.result.label_anchors.get(0) == Ok({ x: 141.73359375, y: 100 })
				and arranged.result.label_anchors.get(2) == Ok({ x: 174.31484375, y: 114 })
				and arranged.result.label_anchors.get(4) == Ok({ x: 180.56796875, y: 128 })
				and arranged.result.label_anchors.get(6) == Ok({ x: 186.82109375, y: 100 })
		}
	}
}

## A recognized endpoint size override must reach the production measured
## label block; accepting its role name alone is not a sized-control proof.
expect {
	match ClassDiagram.parse("classDiagram\nA \"1\" --> \"many\" B") {
		Err(_) => False
		Ok(diagram) => {
			arranged = EntityDraw.arrange_sized(ClassRender.nodes(diagram.classes), ClassRender.edges(diagram.relationships), Down, Theme.Options.{}, ["A", "B"], [{ kind: "label", id: "0-from-label", width: 100, height: 50 }])
			match arranged.labels.first() {
				Ok(label) => label.block.width == 100 and label.block.height == 50
				Err(_) => False
			}
		}
	}
}
