import Drawing
import EntityDraw
import EntityText
import Flowchart
import Theme

## Read and draw Mermaid `erDiagram` database models. Entity headers,
## attribute rows, keys and comments are retained. Relationship ends show
## exactly-one, optional-one, one-or-more or zero-or-more cardinalities;
## non-identifying (`..`) relationships use dashed lines.
##
## `direction TB`, `BT`, `LR` and `RL` choose the reading direction.
## Unsupported statements are reported rather than silently discarded.
EntityRelationship :: {}.{
	Attribute : { type : Str, name : Str, keys : List(Str), comment : Str }
	Entity : { id : Str, label : Str, attributes : List(Attribute) }
	Cardinality : [ExactlyOne, ZeroOne, OneMany, ZeroMany]
	Relationship : { from : U64, to : U64, from_cardinality : Cardinality, to_cardinality : Cardinality, identifying : Bool, label : Str }
	Diagram : { entities : List(Entity), relationships : List(Relationship), direction : [Down, Up, Left, Right] }
	Problem : Flowchart.Problem

	parse : Str -> Try(Diagram, List(Problem))
	parse = |source| {
		lines = EntityText.blocks(source)
		if lines.first() != Ok("erDiagram") {
			return Err([Unsupported("expected erDiagram")])
		}
		var $entities = []
		var $relationships = []
		var $direction = Down
		var $open = None
		var $problems = []
		for line in lines.drop_first(1) {
			words = EntityText.tokens(line)
			match $open {
				Some(index) => {
					if line == "}" {
						$open = None
					}
					else {
						match EntityRelationshipInternals.attribute(words) {
							Err(_) => {
								$problems = $problems.append(Syntax({ near: line }))
							}
							Ok(attribute) => {
								entity = $entities.get(index) ?? { id: "", label: "", attributes: [] }
								# The open index was inserted into this exact list.
								$entities = $entities.set(index, { ..entity, attributes: entity.attributes.append(attribute) }) ?? []
							}
						}
					}
				}
				None => {
					if line.starts_with("direction ") {
						match words {
							[_, "TB"] | [_, "TD"] => {
								$direction = Down
							}
							[_, "BT"] => {
								$direction = Up
							}
							[_, "LR"] => {
								$direction = Right
							}
							[_, "RL"] => {
								$direction = Left
							}
							_ => {
								$problems = $problems.append(Syntax({ near: line }))
							}
						}
					} else if line.contains("--") or line.contains("..") {
						match EntityRelationshipInternals.relationship(line) {
							Err(_) => {
								$problems = $problems.append(Syntax({ near: line }))
							}
							Ok(parsed) => {
								from = EntityRelationshipInternals.ensure($entities, parsed.from)
								to = EntityRelationshipInternals.ensure(from.entities, parsed.to)
								$entities = to.entities
								$relationships = $relationships.append({ from: from.index, to: to.index, from_cardinality: parsed.from_cardinality, to_cardinality: parsed.to_cardinality, identifying: parsed.identifying, label: parsed.label })
							}
						}
					} else {
						match words {
							[id] if EntityText.identifier(id) => {
								found = EntityRelationshipInternals.ensure($entities, EntityText.unquote(id))
								$entities = found.entities
							}
							[id, "{"] if EntityText.identifier(id) => {
								found = EntityRelationshipInternals.ensure($entities, EntityText.unquote(id))
								$entities = found.entities
								$open = Some(found.index)
							}
							_ => {
								$problems = $problems.append(Unsupported("ER statement: ${line}"))
							}
						}
					}
				}
			}
		}
		if $open != None {
			$problems = $problems.append(Syntax({ near: "unclosed entity attribute block" }))
		}
		if $relationships.len() > 500 {
			$problems = $problems.append(TooManyEdges)
		}
		if $problems.is_empty() {
			Ok({ entities: $entities, relationships: $relationships, direction: $direction })
		} else {
			Err($problems)
		}
	}

	draw : Str, Theme.Options -> Try(Drawing.Picture, List(Problem))
	draw = |source, theme| {
		problems = Theme.validate(theme)
		match EntityRelationship.parse(source) {
			Err(found) => Err(problems.concat(found))
			Ok(diagram) => if problems.is_empty() {
				Ok(EntityRelationship.draw_diagram(diagram, theme))
			} else {
				Err(problems)
			}
		}
	}

	## Draw an already parsed diagram with a validated theme. Entity and
	## relationship order follows the source, including parallel relationships.
	draw_diagram : Diagram, Theme.Options -> Drawing.Picture
	draw_diagram = |diagram, theme| EntityDraw.draw(
		diagram.entities.map(
			|e| {
				title: e.label,
				sections: if (e.attributes.is_empty()) [] else [
					e.attributes.map(
						|a| {
							keys = if (a.keys.is_empty()) "" else "  ${Str.join_with(a.keys, ", ")}"
							comment = if (a.comment.is_empty()) "" else "  — ${a.comment}"
							"${a.type} ${a.name}${keys}${comment}"
						},
					),
				],
			},
		),
		diagram.relationships.map(|r| { from: r.from, to: r.to, label: r.label, from_label: "", to_label: "", from_mark: Cardinality(r.from_cardinality), to_mark: Cardinality(r.to_cardinality), dashed: !r.identifying }),
		diagram.direction,
		theme,
	)
}

EntityRelationshipInternals :: {}.{
	ensure : List(EntityRelationship.Entity), Str -> { entities : List(EntityRelationship.Entity), index : U64 }
	ensure = |entities, id| {
		var $found = None
		for i in 0..<entities.len() {
			if (entities.get(i) ?? { id: "", label: "", attributes: [] }).id == id {
				$found = Some(i)
			}
		}
		match $found {
			Some(index) => { entities, index }
			None => { entities: entities.append({ id, label: id, attributes: [] }), index: entities.len() }
		}
	}

	attribute : List(Str) -> Try(EntityRelationship.Attribute, [Invalid])
	attribute = |words| match words {
		[kind, name, .. as rest] => {
			var $keys = []
			var $comment = ""
			var $valid = EntityText.identifier(name) and !kind.is_empty()
			for token in rest {
				if token.starts_with("\"") and token.ends_with("\"") {
					$comment = EntityText.unquote(token)
				}
				else {
					for key in token.split_on(",") {
						if key == "PK" or key == "FK" or key == "UK" {
							$keys = $keys.append(key)
						}
						else if !key.is_empty() {
							$valid = False
						}
					}
				}
			}
			if $valid {
				Ok({ type: kind, name, keys: $keys, comment: $comment })
			} else {
				Err(Invalid)
			}
		}
		_ => Err(Invalid)
	}

	relationship : Str -> Try({ from : Str, to : Str, from_cardinality : EntityRelationship.Cardinality, to_cardinality : EntityRelationship.Cardinality, identifying : Bool, label : Str }, [Invalid])
	relationship = |line| {
		match EntityText.split(line, ":") {
			Missing => Err(Invalid)
			Found(head, label) => {
				identifying = head.contains("--")
				match EntityText.split(head, if (identifying) "--" else "..") {
					Missing => Err(Invalid)
					Found(left, right) => {
						l = EntityText.trim(left).to_utf8()
						r = EntityText.trim(right).to_utf8()
						if l.len() < 3 or r.len() < 3 {
							return Err(Invalid)
						}
						from = EntityText.trim(Str.from_utf8_lossy(l.drop_last(2)))
						to = EntityText.trim(Str.from_utf8_lossy(r.drop_first(2)))
						a = Str.from_utf8_lossy(l.take_last(2))
						b = Str.from_utf8_lossy(r.take_first(2))
						if !EntityText.identifier(from) or !EntityText.identifier(to) {
							return Err(Invalid)
						}
						from_cardinality = match a {
							"||" => ExactlyOne
							"|o" => ZeroOne
							"}|" => OneMany
							"}o" => ZeroMany
							_ => return Err(Invalid)
						}
						to_cardinality = match b {
							"||" => ExactlyOne
							"o|" => ZeroOne
							"|{" => OneMany
							"o{" => ZeroMany
							_ => return Err(Invalid)
						}
						Ok({ from: EntityText.unquote(from), to: EntityText.unquote(to), from_cardinality, to_cardinality, identifying, label: EntityText.unquote(label) })
					}
				}
			}
		}
	}
}

expect match EntityRelationship.parse("erDiagram\n CUSTOMER ||--o{ ORDER : places\n CUSTOMER {\n int id PK\n string name \"display name\"\n }\n ORDER {\n int id PK\n int customer_id FK\n }\n") {
	Ok(d) => d.entities.len() == 2 and (d.entities.get(0) ?? { id: "", label: "", attributes: [] }).attributes.len() == 2 and (d.relationships.get(0) ?? { from: 0, to: 0, from_cardinality: ExactlyOne, to_cardinality: ExactlyOne, identifying: True, label: "" }).to_cardinality == ZeroMany
	Err(_) => False
}
expect match EntityRelationship.draw("erDiagram", Theme.Options.{}) {
	Ok(p) => Drawing.is_finite(p)
	Err(_) => False
}
expect match EntityRelationship.parse("erDiagram\n style A fill:red\n click A url\n") {
	Err(p) => p.len() == 2
	Ok(_) => False
}

## Regression: compact blocks must not split crow's-foot operators.
expect match EntityRelationship.parse("erDiagram; A { int id PK }; A||--o{B : contains") {
	Ok(d) => d.entities.len() == 2 and d.relationships.len() == 1 and (d.entities.get(0) ?? { id: "", label: "", attributes: [] }).attributes.len() == 1
	Err(_) => False
}

expect {
	source = "erDiagram\n A ||--o{ A : self\n A ||..|{ B : parallel one\n A ||--o{ B : parallel two\n ISOLATED\n"
	match EntityRelationship.parse(source) {
		Err(_) => False
		Ok(d) => d.entities.len() == 3 and d.relationships.len() == 3 and [Down, Up, Left, Right].all(
			|direction| {
				p = EntityRelationship.draw_diagram({ ..d, direction }, Theme.Options.{ max_label_width: 80 })
				Drawing.is_finite(p) and p == EntityRelationship.draw_diagram({ ..d, direction }, Theme.Options.{ max_label_width: 80 })
			},
		)
	}
}

expect match EntityRelationship.draw("erDiagram\nA {\nbad\nalso_bad\n", Theme.Options.{ padding: -1 }) {
	Err(problems) => problems.len() == 4
	Ok(_) => False
}

expect match EntityRelationship.parse("erDiagram\n A }o..o| B : \"a: b\"\n") {
	Ok(d) => match d.relationships.first() {
		Ok(r) => r.from_cardinality == ZeroMany and r.to_cardinality == ZeroOne and !r.identifying and r.label == "a: b"
		Err(_) => False
	}
	Err(_) => False
}
