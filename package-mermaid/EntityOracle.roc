import Drawing
import EntityDraw
import EntityRelationship
import EntityRender
import OracleJson
import TextMeasure
import Theme
import font.Font

## Internal native facts for comparison with an independently recorded browser.
EntityOracle :: {}.{
	reference_theme : Theme.Options
	reference_theme = Theme.Options.{ node_fill: Drawing.white, node_stroke: Drawing.rgb(0x28253D), node_text: Drawing.rgb(0x28253D), line: Drawing.black, line_width: 2, label_background: Drawing.rgb(0xE5E5E5), label_text: Drawing.rgb(0x28253D), line_height: 1.1, max_label_width: 16384, padding: 15, corners: Square, wrapping: NoWrap }

	inspect : Str, Theme.Options -> Str
	inspect = |source, theme| EntityOracle.inspect_sized(source, theme, [])

	inspect_sized : Str, Theme.Options, List(OracleJson.Size) -> Str
	inspect_sized = |source, theme, overrides| match (EntityRelationship.parse(source), EntityRelationship.draw(source, theme)) {
		(Ok(diagram), Ok(default_picture)) => {
			picture = if (overrides.is_empty()) default_picture else EntityDraw.draw_sized(EntityRender.nodes(diagram.entities), EntityRender.edges(diagram.relationships), diagram.direction, theme, diagram.entities.map(|e| e.id), overrides)
			ids = diagram.entities.map(|e| e.id)
			semantic = OracleJson.object([
				("direction", OracleJson.string(Str.inspect(diagram.direction))),
				(
					"entities",
					OracleJson.array(
						diagram.entities.map(
							|e| OracleJson.object([
								("id", OracleJson.string(e.id)),
								("label", OracleJson.string(e.label)),
								("attributes", OracleJson.array(e.attributes.map(|a| OracleJson.object([("type", OracleJson.string(a.type)), ("name", OracleJson.string(a.name)), ("keys", OracleJson.strings(a.keys)), ("comment", OracleJson.string(a.comment))])))),
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
								("from_cardinality", OracleJson.string(Str.inspect(r.from_cardinality))),
								("to_cardinality", OracleJson.string(Str.inspect(r.to_cardinality))),
								("identifying", OracleJson.boolean(r.identifying)),
								("label", OracleJson.string(r.label)),
							]),
						),
					),
				),
			])
			columns = diagram.entities.map(
				|e| {
					keys = e.attributes.any(|a| !a.keys.is_empty())
					comments = e.attributes.any(|a| !a.comment.is_empty())
					core = ["type", "name"]
					with_keys = if (keys) core.append("keys") else core
					if (comments) with_keys.append("comment") else with_keys
				},
			)
			geometry = EntityOracle.geometry_sized(ids, EntityRender.nodes(diagram.entities), EntityRender.edges(diagram.relationships), columns, diagram.direction, theme, picture, overrides)
			OracleJson.object([("accepted", "true"), ("family", OracleJson.string("entity")), ("semantic", semantic), ("geometry", geometry), ("size_problems", EntityOracle.size_problems(ids, EntityRender.edges(diagram.relationships), overrides))])
		}
		_ => OracleJson.rejected("entity")
	}

	size_problems : List(Str), List(EntityDraw.Edge), List(OracleJson.Size) -> Str
	size_problems = |ids, edges, overrides| OracleJson.strings(
		overrides.keep_if(
			|value| {
				consumed = if value.kind == "node" {
					ids.contains(value.id)
				} else if value.kind == "label" or value.kind == "edge-label" {
					edges.map_with_index(|edge, i| (!edge.label.is_empty() and value.id == "${i.to_str()}-label") or (!edge.from_label.is_empty() and value.id == "${i.to_str()}-from-label") or (!edge.to_label.is_empty() and value.id == "${i.to_str()}-to-label")).any(|matched| matched)
				} else {
					False
				}
				!consumed
			},
		).map(|value| "unconsumed ${value.kind}:${value.id}"),
	)

	Role : { id : Str, lines : U64 }
	geometry : List(Str), List(EntityDraw.Node), List(EntityDraw.Edge), List(List(Str)), [Down, Up, Left, Right], Theme.Options, Drawing.Picture -> Str
	geometry = |ids, nodes, edges, columns, direction, theme, picture| EntityOracle.geometry_sized(ids, nodes, edges, columns, direction, theme, picture, [])

	geometry_sized : List(Str), List(EntityDraw.Node), List(EntityDraw.Edge), List(List(Str)), [Down, Up, Left, Right], Theme.Options, Drawing.Picture, List(OracleJson.Size) -> Str
	geometry_sized = |ids, nodes, edges, columns, direction, theme, picture, overrides| {
		arranged = EntityDraw.arrange_sized(nodes, edges, direction, theme, ids, overrides)
		boxes = arranged.measured.map_with_index(
			|m, i| {
				p = arranged.result.layout.positions.get(i) ?? { x: 0, y: 0 }
				{ x: p.x - m.width / 2, y: p.y - m.height / 2, width: m.width, height: m.height }
			},
		)
		routes = edges.map_with_index(|e, i| EntityDraw.clip_points(EntityDraw.route_points(arranged.result.layout.routes.get(i) ?? Polyline([])), e, arranged.measured, arranged.result.layout.positions, EntityDraw.radius(theme)))
		var $roles = []
		for spec in arranged.labels {
			role = match spec.placement {
				Center => "label"
				Near(From) => "from-label"
				Near(To) => "to-label"
			}
			$roles = $roles.append({ id: "${spec.edge.to_str()}-${role}", lines: spec.block.lines.len() })
		}
		for i in 0..<arranged.measured.len() {
			match (arranged.measured.get(i), nodes.get(i)) {
				(Ok(m), Ok(node)) => {
					id = ids.get(i) ?? ""
					for a in 0..<m.annotations.len() {
						$roles = $roles.append({ id: "${id}-annotation-${a.to_str()}", lines: (m.annotations.get(a) ?? m.title).lines.len() })
					}
					$roles = $roles.append({ id: "${id}-header", lines: m.title.lines.len() })
					for section in 0..<m.sections.len() {
						row_kind = if (section == 0) "field" else "method"
						rows = m.sections.get(section) ?? []
						for row in 0..<rows.len() {
							$roles = $roles.append({ id: "${id}-${row_kind}-${row.to_str()}", lines: (rows.get(row) ?? m.title).lines.len() })
						}
					}
					for row in 0..<m.table.len() {
						cells = m.table.get(row) ?? []
						names = columns.get(i) ?? []
						for column in 0..<cells.len() {
							cell = cells.get(column) ?? m.title
							$roles = $roles.append({ id: "${id}-attribute-${row.to_str()}-${names.get(column) ?? column.to_str()}", lines: cell.lines.len() })
						}
					}
					_ = node
				}
				_ => {}
			}
		}
		labels = picture.items.fold(
			[],
			|out, item| match item {
				Text(label) => out.append(label)
				StyledText(styled) => out.append(styled.label)
				Shape(_) => out
			},
		)
		var $offset = 0
		var $observed = []
		for role in $roles {
			group = labels.sublist({ start: $offset.min(labels.len()), len: role.lines.min(labels.len() - $offset.min(labels.len())) })
			$offset = $offset + role.lines
			text = Str.join_with(group.map(|label| label.text), " ")
			bounds = EntityOracle.label_box(group, theme)
			if !text.is_empty() {
				$observed = $observed.append(OracleJson.object([("id", OracleJson.string(role.id)), ("text", OracleJson.string(text)), ("box", OracleJson.rect(bounds))]))
			}
		}
		OracleJson.object([
			("view_box", OracleJson.rect(picture.view)),
			("nodes", OracleJson.array(boxes.map_with_index(|box, i| OracleJson.object([("id", OracleJson.string(ids.get(i) ?? "")), ("box", OracleJson.rect(box))])))),
			("edges", OracleJson.array(edges.map_with_index(|edge, i| OracleJson.object([("id", OracleJson.string(i.to_str())), ("from", OracleJson.string(ids.get(edge.from) ?? "")), ("to", OracleJson.string(ids.get(edge.to) ?? "")), ("points", OracleJson.array((routes.get(i) ?? []).map(OracleJson.point)))])))),
			("labels", OracleJson.array($observed)),
		])
	}

	label_box : List(Drawing.Label), Theme.Options -> Drawing.Rect
	label_box = |labels, theme| {
		if labels.is_empty() {
			return { x: 0, y: 0, width: 0, height: 0 }
		}
		var $x = F64.infinity
		var $y = F64.infinity
		var $right = -F64.infinity
		var $bottom = -F64.infinity
		for label in labels {
			measured = TextMeasure.block_advance(label.text, { font: TextMeasure.inter, size: label.size, line_height: theme.line_height, wrap: NoWrap, align: Start })
			ascent = TextMeasure.round(Font.metrics(TextMeasure.inter).ascent.to_f64() * label.size / Font.units_per_em(TextMeasure.inter).to_f64())
			left = label.origin.x - match label.align {
				Start => 0
				Center => measured.width / 2
				End => measured.width
			}
			top = label.origin.y - ascent
			$x = $x.min(left)
			$y = $y.min(top)
			$right = $right.max(left + measured.width)
			$bottom = $bottom.max(top + measured.height)
		}
		{ x: $x, y: $y, width: $right - $x, height: $bottom - $y }
	}
}

expect EntityOracle.inspect_sized("erDiagram\nA", Theme.Options.{}, [{ kind: "node", id: "missing", width: 10, height: 10 }]).contains("unconsumed node:missing")
