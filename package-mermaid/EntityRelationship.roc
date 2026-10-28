import Drawing
import EntityDraw
import EntityText
import Flowchart
import Theme

## Read and draw Mermaid `erDiagram` database models. Entity headers,
## attribute rows, nullable types, keys and comments are retained. Square-bracket
## entity aliases change the displayed header while references retain the ID. Relationship ends show
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
	## Source statement problems and invalid numeric theme properties.
	Problem : [NotAFlowchart, Syntax({ near : Str }), Unsupported(Str), InvalidTheme(Str), TooManyEdges, MissingLinkStyleEdge(Str), UnnamedGroup]

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
					} else if EntityText.split(line, "--") != Missing or EntityText.split(line, "..") != Missing {
						match EntityRelationshipInternals.relationship(line) {
							Err(_) => {
								$problems = $problems.append(Syntax({ near: line }))
							}
							Ok(parsed) => {
								from = EntityRelationshipInternals.ensure($entities, parsed.from)
								to = EntityRelationshipInternals.ensure(from.entities, parsed.to)
								$entities = EntityRelationshipInternals.rename(EntityRelationshipInternals.rename(to.entities, from.index, parsed.from_label), to.index, parsed.to_label)
								$relationships = $relationships.append({ from: from.index, to: to.index, from_cardinality: parsed.from_cardinality, to_cardinality: parsed.to_cardinality, identifying: parsed.identifying, label: parsed.label })
							}
						}
					} else {
						open = line.ends_with("{")
						reference = if (open) EntityText.trim(Str.from_utf8_lossy(line.to_utf8().drop_last(1))) else line
						match EntityRelationshipInternals.reference(reference) {
							Some(ref) => {
								found = EntityRelationshipInternals.ensure($entities, ref.id)
								$entities = EntityRelationshipInternals.rename(found.entities, found.index, ref.label)
								if open {
									$open = Some(found.index)
								}
							}
							None => {
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
				Ok(EntityRelationshipInternals.draw(diagram, theme))
			} else {
				Err(problems)
			}
		}
	}

}

EntityRelationshipInternals :: {}.{
	draw : EntityRelationship.Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, theme| EntityDraw.draw(
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

	Reference : { id : Str, label : [Some(Str), None] }
	reference : Str -> [Some(Reference), None]
	reference = |raw| {
		text = EntityText.trim(raw)
		if EntityText.identifier(text) {
			return Some({ id: EntityText.unquote(text), label: None })
		}
		match EntityText.split(text, "[") {
			Missing => None
			Found(id_raw, label_raw) => {
				id = EntityText.trim(id_raw)
				label = EntityText.trim(label_raw)
				if EntityText.identifier(id) and label.ends_with("]") {
					display = EntityText.unquote(Str.from_utf8_lossy(label.to_utf8().drop_last(1)))
					if display.is_empty() {
						None
					} else {
						Some({ id: EntityText.unquote(id), label: Some(display) })
					}
				} else {
					None
				}
			}
		}
	}

	rename : List(EntityRelationship.Entity), U64, [Some(Str), None] -> List(EntityRelationship.Entity)
	rename = |entities, index, label| match label {
		None => entities
		Some(display) => {
			entity = entities.get(index) ?? { id: "", label: "", attributes: [] }
			# index is returned by ensure for this exact list.
			entities.set(index, { ..entity, label: display }) ?? []
		}
	}

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

	attribute_word : Str, Bool -> Bool
	attribute_word = |word, type_word| {
		bytes = word.to_utf8()
		body = if (type_word and bytes.last() == Ok('?')) bytes.drop_last(1) else if (!type_word and bytes.first() == Ok('*')) bytes.drop_first(1) else bytes
		first = body.first() ?? 0
		alpha = |c| (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c >= 128
		!body.is_empty() and alpha(first) and body.all(|c| alpha(c) or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '[' or c == ']' or c == '(' or c == ')')
	}

	attribute : List(Str) -> Try(EntityRelationship.Attribute, [Invalid])
	attribute = |words| match words {
		[kind, name, .. as rest] => {
			var $keys = []
			var $comment = ""
			var $has_comment = False
			var $valid = EntityRelationshipInternals.attribute_word(name, False) and EntityRelationshipInternals.attribute_word(kind, True)
			for token in rest {
				if token.starts_with("\"") and token.ends_with("\"") {
					if $has_comment {
						$valid = False
					}
					$has_comment = True
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

	relationship : Str -> Try({ from : Str, to : Str, from_label : [Some(Str), None], to_label : [Some(Str), None], from_cardinality : EntityRelationship.Cardinality, to_cardinality : EntityRelationship.Cardinality, identifying : Bool, label : Str }, [Invalid])
	relationship = |line| {
		match EntityText.split(line, ":") {
			Missing => Err(Invalid)
			Found(head, label) => {
				identifying = EntityText.split(head, "--") != Missing
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
						from_ref = match EntityRelationshipInternals.reference(from) {
							Some(ref) => ref
							None => return Err(Invalid)
						}
						to_ref = match EntityRelationshipInternals.reference(to) {
							Some(ref) => ref
							None => return Err(Invalid)
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
						Ok({ from: from_ref.id, to: to_ref.id, from_label: from_ref.label, to_label: to_ref.label, from_cardinality, to_cardinality, identifying, label: EntityText.unquote(label) })
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
				p = EntityRelationshipInternals.draw({ ..d, direction }, Theme.Options.{ max_label_width: 80 })
				Drawing.is_finite(p) and p == EntityRelationshipInternals.draw({ ..d, direction }, Theme.Options.{ max_label_width: 80 })
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

## Entity aliases change visible headers without changing source references.
expect match EntityRelationship.parse("erDiagram\n CUSTOMER[Customer account] {\n string? display_name\n int account_id PK, FK \"account reference\"\n }\n CUSTOMER ||--o{ ORDER[\"Purchase order\"] : places\n CUSTOMER\n") {
	Ok(d) => match (d.entities.get(0), d.entities.get(1)) {
		(Ok(customer), Ok(order)) => customer.id == "CUSTOMER" and customer.label == "Customer account" and order.id == "ORDER" and order.label == "Purchase order" and match customer.attributes.get(1) {
			Ok(attribute) => attribute.keys == ["PK", "FK"] and attribute.comment == "account reference"
			Err(_) => False
		}
		_ => False
	}
	Err(_) => False
}

expect match EntityRelationship.parse("erDiagram\n A[\"Name: one--two\"] ||--o{ B : \"uses: records\"\n A { string? name }\n") {
	Ok(d) => match d.entities.first() {
		Ok(entity) => entity.label == "Name: one--two" and (entity.attributes.first() ?? { type: "", name: "", keys: [], comment: "" }).type == "string?"
		Err(_) => False
	}
	Err(_) => False
}

expect match EntityRelationship.draw("erDiagram\n A[Customer account]\n A ||--o{ B[\"Purchase order\"] : places\n", Theme.Options.{}) {
	Ok(picture) => Drawing.is_finite(picture) and picture.items.any(
		|item| match item {
			Text(label) => label.text == "Customer account"
			_ => False
		},
	)
	Err(_) => False
}

expect match EntityRelationship.parse("erDiagram %% schema\nA ||--o{ B : has\n") {
	Ok(diagram) => diagram.entities.len() == 2 and diagram.relationships.len() == 1
	Err(_) => False
}

## A second comment is invalid source, never a silent replacement of the first.
expect match EntityRelationship.parse("erDiagram\nA {\nstring name \"first\" \"second\"\n}\n") {
	Err([Syntax(_)]) => True
	_ => False
}
