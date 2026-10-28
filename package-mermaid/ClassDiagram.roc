import Drawing
import EntityDraw
import EntityText
import Flowchart
import Theme

## Read and draw Mermaid `classDiagram` models, with separate attribute and
## operation compartments. Inheritance, realization, composition, aggregation,
## association and dependency keep their distinct end markers and line styles.
## Quoted multiplicities and association labels receive space along the routes.
##
## Supports class declarations, member blocks, `Class : member`, annotations,
## generic names (`List~T~`) and reading directions. Namespaces, interactions
## and style directives are reported as unsupported rather than approximated.
ClassDiagram :: {}.{
	Class : { id : Str, label : Str, fields : List(Str), methods : List(Str), annotations : List(Str) }
	RelationshipKind : [Inheritance, Realization, Composition, Aggregation, Association, Dependency, Link, DottedLink]
	Relationship : { from : U64, to : U64, kind : RelationshipKind, reversed : Bool, bidirectional : Bool, label : Str, from_multiplicity : Str, to_multiplicity : Str }
	Diagram : { classes : List(Class), relationships : List(Relationship), direction : [Down, Up, Left, Right] }

	## Source statement problems and invalid numeric theme properties.
	Problem : [NotAFlowchart, Syntax({ near : Str }), Unsupported(Str), InvalidTheme(Str), TooManyEdges, MissingLinkStyleEdge(Str), UnnamedGroup]

	parse : Str -> Try(Diagram, List(Problem))
	parse = |source| {
		lines = EntityText.blocks(source)
		if lines.first() != Ok("classDiagram") {
			return Err([Unsupported("expected classDiagram")])
		}
		var $classes = []
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
					else if line.contains("{") or line.contains("}") {
						$problems = $problems.append(Syntax({ near: line }))
					}
					else {
						$classes = ClassDiagramInternals.member($classes, index, line)
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
					} else if line.starts_with("class ") {
						match ClassDiagramInternals.declaration(line) {
							Some(decl) => {
								found = ClassDiagramInternals.ensure($classes, decl.id)
								current = found.classes.get(found.index) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }
								$classes = found.classes.set(found.index, { ..current, label: decl.label }) ?? []
								if decl.open {
									$open = Some(found.index)
								}
							}
							None => {
								$problems = $problems.append(Unsupported("class declaration: ${line}"))
							}
						}
					} else {
						match ClassDiagramInternals.relationship(line) {
							Some(parsed) => {
								from = ClassDiagramInternals.ensure($classes, parsed.from)
								to = ClassDiagramInternals.ensure(from.classes, parsed.to)
								$classes = to.classes
								$relationships = $relationships.append({ from: from.index, to: to.index, kind: parsed.kind, reversed: parsed.reversed, bidirectional: parsed.bidirectional, label: parsed.label, from_multiplicity: parsed.from_multiplicity, to_multiplicity: parsed.to_multiplicity })
							}
							None => {
								if line.starts_with("<<") and line.contains(">>") {
									match words {
										[annotation, id] if annotation.ends_with(">>") and ClassDiagramInternals.identifier(id) => {
											found = ClassDiagramInternals.ensure($classes, id)
											$classes = ClassDiagramInternals.member(found.classes, found.index, annotation)
										}
										_ => {
											$problems = $problems.append(Syntax({ near: line }))
										}
									}
								} else {
									match EntityText.split(line, ":") {
										Found(raw_id, member) if ClassDiagramInternals.identifier(EntityText.trim(raw_id)) and !EntityText.trim(member).is_empty() => {
											found = ClassDiagramInternals.ensure($classes, EntityText.trim(raw_id))
											$classes = ClassDiagramInternals.member(found.classes, found.index, EntityText.trim(member))
										}
										_ => {
											$problems = $problems.append(Unsupported("class statement: ${line}"))
										}
									}
								}
							}
						}
					}
				}
			}
		}
		if $open != None {
			$problems = $problems.append(Syntax({ near: "unclosed class member block" }))
		}
		if $relationships.len() > 500 {
			$problems = $problems.append(TooManyEdges)
		}
		if $problems.is_empty() {
			Ok({ classes: $classes, relationships: $relationships, direction: $direction })
		} else {
			Err($problems)
		}
	}

	draw : Str, Theme.Options -> Try(Drawing.Picture, List(Problem))
	draw = |source, theme| {
		problems = Theme.validate(theme)
		match ClassDiagram.parse(source) {
			Err(found) => Err(problems.concat(found))
			Ok(diagram) => if problems.is_empty() {
				Ok(ClassDiagramInternals.draw(diagram, theme))
			} else {
				Err(problems)
			}
		}
	}

}

ClassDiagramInternals :: {}.{
	draw : ClassDiagram.Diagram, Theme.Options -> Drawing.Picture
	draw = |diagram, theme| EntityDraw.draw(
		diagram.classes.map(
			|c| {
				title = Str.join_with(c.annotations.concat([c.label]), "\n")
				sections = if (c.fields.is_empty() and c.methods.is_empty()) [] else [c.fields, c.methods]
				{ title, sections }
			},
		),
		diagram.relationships.map(
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
		),
		diagram.direction,
		theme,
	)

	declaration : Str -> [Some({ id : Str, label : Str, open : Bool }), None]
	declaration = |line| {
		raw = EntityText.trim(Str.from_utf8_lossy(line.to_utf8().drop_first(6)))
		open = raw.ends_with("{")
		body = if (open) EntityText.trim(Str.from_utf8_lossy(raw.to_utf8().drop_last(1))) else raw
		match EntityText.split(body, "[") {
			Missing => if ClassDiagramInternals.identifier(body) {
				Some({ id: body, label: ClassDiagramInternals.display(body), open })
			} else {
				None
			}
			Found(id_raw, label_raw) => {
				id = EntityText.trim(id_raw)
				label = EntityText.trim(label_raw)
				if ClassDiagramInternals.identifier(id) and label.ends_with("]") {
					Some({ id, label: EntityText.unquote(Str.from_utf8_lossy(label.to_utf8().drop_last(1))), open })
				} else {
					None
				}
			}
		}
	}

	display : Str -> Str
	display = |id| {
		parts = id.split_on("~")
		if parts.len() == 3 {
			"${parts.get(0) ?? ""}<${parts.get(1) ?? ""}>${parts.get(2) ?? ""}"
		} else {
			id
		}
	}

	identifier : Str -> Bool
	identifier = |id| {
		# Mermaid spells generic types with tildes. The full text is preserved
		# in the title while the same spelling resolves relationship endpoints.
		normalized = Str.join_with(id.split_on("~"), "_")
		EntityText.identifier(normalized)
	}

	ensure : List(ClassDiagram.Class), Str -> { classes : List(ClassDiagram.Class), index : U64 }
	ensure = |classes, id| {
		var $found = None
		for i in 0..<classes.len() {
			if (classes.get(i) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }).id == id {
				$found = Some(i)
			}
		}
		match $found {
			Some(index) => { classes, index }
			None => { classes: classes.append({ id, label: ClassDiagramInternals.display(id), fields: [], methods: [], annotations: [] }), index: classes.len() }
		}
	}

	member : List(ClassDiagram.Class), U64, Str -> List(ClassDiagram.Class)
	member = |classes, index, text| {
		item = classes.get(index) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }
		changed = if text.starts_with("<<") and text.ends_with(">>") {
			{ ..item, annotations: item.annotations.append(text) }
		}
		else if text.contains("(") {
			{ ..item, methods: item.methods.append(text) }
		}
		else {
			{ ..item, fields: item.fields.append(text) }
		}
		# Callers obtain index from ensure or from an already-open block.
		classes.set(index, changed) ?? []
	}

	Parsed : { from : Str, to : Str, kind : ClassDiagram.RelationshipKind, reversed : Bool, bidirectional : Bool, label : Str, from_multiplicity : Str, to_multiplicity : Str }
	relationship : Str -> [Some(Parsed), None]
	relationship = |line| {
		parts = match EntityText.split(line, ":") {
			Found(a, b) => { head: a, label: EntityText.unquote(b) }
			Missing => { head: line, label: "" }
		}
		for operator in ["<-->", "<..>", "<|..", "<|--", "..|>", "--|>", "*--", "--*", "o--", "--o", "<--", "-->", "<..", "..>", "--", ".."] {
			match EntityText.split(parts.head, operator) {
				Missing => {}
				Found(left, right) => {
					l = EntityText.tokens(left)
					r = EntityText.tokens(right)
					parsed_left = match l {
						[id] => { id, multi: "" }
						[id, multi] if multi.starts_with("\"") and multi.ends_with("\"") => { id, multi: EntityText.unquote(multi) }
						_ => return None
					}
					parsed_right = match r {
						[id] => { id, multi: "" }
						[multi, id] if multi.starts_with("\"") and multi.ends_with("\"") => { id, multi: EntityText.unquote(multi) }
						_ => return None
					}
					if !ClassDiagramInternals.identifier(parsed_left.id) or !ClassDiagramInternals.identifier(parsed_right.id) {
						return None
					}
					kind = match operator {
						"<|--" | "--|>" => Inheritance
						"<|.." | "..|>" => Realization
						"*--" | "--*" => Composition
						"o--" | "--o" => Aggregation
						"<--" | "-->" | "<-->" => Association
						"<.." | "..>" | "<..>" => Dependency
						".." => DottedLink
						_ => Link
					}
					reversed = operator.starts_with("<") or operator.starts_with("*") or operator.starts_with("o")
					return Some({ from: parsed_left.id, to: parsed_right.id, kind, reversed, bidirectional: operator == "<-->" or operator == "<..>", label: parts.label, from_multiplicity: parsed_left.multi, to_multiplicity: parsed_right.multi })
				}
			}
		}
		None
	}
}

expect match ClassDiagram.parse("classDiagram\n class Animal {\n +String name\n +speak() String\n }\n Animal <|-- Dog\n Owner \"1\" *-- \"many\" Dog : owns\n") {
	Ok(d) => d.classes.len() == 3 and d.relationships.len() == 2 and (d.classes.get(0) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }).methods == ["+speak() String"]
	Err(_) => False
}
expect match ClassDiagram.draw("classDiagram", Theme.Options.{}) {
	Ok(p) => Drawing.is_finite(p)
	Err(_) => False
}
expect match ClassDiagram.parse("classDiagram\n namespace A {\n click A callback\n") {
	Err(p) => p.len() == 2
	Ok(_) => False
}

## Regression: a compact class member block preserves its operation.
expect match ClassDiagram.parse("classDiagram; class A { +get() String }; A-->A : self") {
	Ok(d) => d.classes.len() == 1 and d.relationships.len() == 1 and (d.classes.get(0) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }).methods == ["+get() String"]
	Err(_) => False
}

expect match ClassDiagram.parse("classDiagram\n class List~T~\n class A[\"Display name\"]\n A -- List~T~\n") {
	Ok(d) => (d.classes.get(0) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }).label == "List<T>" and (d.classes.get(1) ?? { id: "", label: "", fields: [], methods: [], annotations: [] }).label == "Display name"
	Err(_) => False
}

expect {
	source = "classDiagram\n class Isolated\n A <|-- B\n A *-- B : composition\n B o-- A : aggregation\n A ..> A : dependency\n"
	match ClassDiagram.parse(source) {
		Err(_) => False
		Ok(d) => d.classes.len() == 3 and d.relationships.len() == 4 and [Down, Up, Left, Right].all(
			|direction| {
				p = ClassDiagramInternals.draw({ ..d, direction }, Theme.Options.{ max_label_width: 80 })
				Drawing.is_finite(p) and p == ClassDiagramInternals.draw({ ..d, direction }, Theme.Options.{ max_label_width: 80 })
			},
		)
	}
}

expect match ClassDiagram.draw("classDiagram\n namespace unsupported\n click A url\n", Theme.Options.{ font_size: 0 }) {
	Err(problems) => problems.len() == 3
	Ok(_) => False
}
