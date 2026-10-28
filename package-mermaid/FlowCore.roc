import Flowchart
import FlowGeometry
import FlowSourceLayout
import layout.Layered

## Measured Mermaid flow input projected onto the public geometry API.
## Source registration, title padding and hierarchy policy belong here;
## ranking, ordering, placement and routing belong to the core package.
FlowCore :: {}.{
	Raw : { nodes : List(FlowGeometry.Rect), groups : List(FlowGeometry.Rect), edges : List({ points : List(FlowGeometry.Point), label : [None, Some(FlowGeometry.Point)] }) }
	finite : F64 -> F64
	finite = |v| if (F64.is_finite(v) and v > 0) v else 0

	layout : Flowchart.Diagram, FlowGeometry.Sizes -> Raw
	layout = |diagram, sizes| FlowCore.arrange(diagram, sizes, [], [], []).raw

	Size : { width : F64, height : F64 }
	Ends : { from : [None, Some(Size)], to : [None, Some(Size)] }
	Placement : { point : FlowGeometry.Point, port : FlowGeometry.Point }
	EndPlacements : { from : [None, Some(Placement)], to : [None, Some(Placement)] }
	Reservation : { group : U64, width : F64, height : F64 }
	arrange : Flowchart.Diagram, FlowGeometry.Sizes, List(Ends), List(Reservation), List(FlowSourceLayout.Item) -> { raw : Raw, ends : List(EndPlacements) }
	arrange = |diagram, sizes, terminal_sizes, reservations, registration| {
		children_of = |container| FlowSourceLayout.registered_children(diagram, container, registration)
		# Preserve the source reader's registration without exposing engine state.
		var $stack = children_of(Root).rev()
		var $preorder = []
		while !$stack.is_empty() {
			item = $stack.last() ?? crash "nonempty registration traversal"
			$stack = $stack.drop_last(1)
			match item {
				NodeItem(_) => {}
				GroupItem(g) => {
					$preorder = $preorder.append(g)
					$stack = $stack.concat(children_of(Group(g)).rev())
				}
			}
		}
		preorder = $preorder
		separate = FlowSourceLayout.separate_groups(diagram)
		var $directions = List.repeat(diagram.direction, diagram.groups.len())
		for g in preorder {
			group = diagram.groups.get(g) ?? crash "registered group"
			parent_direction = match group.container {
				Root => diagram.direction
				Group(parent) => $directions.get(parent) ?? crash "registered parent"
			}
			direction = if separate.get(g) ?? False {
				match group.direction {
					Set(d) => d
					Inherit => Right
				}
			} else parent_direction
			$directions = $directions.set(g, direction) ?? []
		}
		root_spacing = FlowSourceLayout.root_spacing
		group_spacing = FlowSourceLayout.group_spacing
		var $built = List.repeat(Layered.default_group, diagram.groups.len())
		for g in preorder.rev() {
			items = children_of(Group(g))
			children = items.map(
				|item| match item {
					NodeItem(n) => Node(n)
					GroupItem(child) => Nested($built.get(child) ?? crash "child completed before parent")
				},
			)
			title = sizes.group_titles.get(g) ?? { lines: [], width: 0, height: 0 }
			width = FlowCore.finite(title.width)
			height = (FlowCore.finite(title.height) - 2).max(0)
			direction = $directions.get(g) ?? crash "registered group direction"
			vertical = direction == Down or direction == Up
			min = width + (if (width > 0) 10 else 8)
			value = Group({
				children,
				flow: if (separate.get(g) ?? False) Separate(direction) else Together,
				spacing: Set(group_spacing),
				padding: { top: 24 + (if (height > 0) height + 5 else 0), right: 24, bottom: 24, left: 24 },
				min_width: if (vertical or items.is_empty()) 0 else min,
				min_height: if (!vertical or items.is_empty()) 0 else min,
				label: if (items.is_empty()) None else Some({ width, height }),
			})
			$built = $built.set(g, value) ?? []
		}
		root_children = children_of(Root).map(
			|item| match item {
				NodeItem(n) => Node(n)
				GroupItem(g) => Nested($built.get(g) ?? crash "registered root group")
			},
		)
		endpoint = |end| match end {
			Node(n) => Node(n)
			Group(g) => Group(1 + (preorder.find_first_index(|i| i == g) ?? crash "registered edge endpoint"))
		}
		labels = diagram.edges.map_with_index(
			|edge, e| match sizes.edge_labels.get(e) ?? None {
				None => []
				Some(block) => if edge.label.is_empty() {
					[]
				} else [{ edge: e, width: FlowCore.finite(block.width) + 4, height: FlowCore.finite(block.height) + 4 }]
			},
		).fold([], |all, part| all.concat(part))
		end_labels = terminal_sizes.map_with_index(
			|ends, e| {
				from = match ends.from {
					None => []
					Some(size) => [{ edge: e, endpoint: From, width: FlowCore.finite(size.width), height: FlowCore.finite(size.height) }]
				}
				to = match ends.to {
					None => []
					Some(size) => [{ edge: e, endpoint: To, width: FlowCore.finite(size.width), height: FlowCore.finite(size.height) }]
				}
				from.concat(to)
			},
		).fold([], |all, parts| all.concat(parts))
		input = {
			..Layered.default_grouped_input,
			nodes: diagram.nodes.map_with_index(
				|_, i| {
					size = sizes.nodes.get(i) ?? { width: 0, height: 0, label: { lines: [], width: 0, height: 0 } }
					{ width: FlowCore.finite(size.width), height: FlowCore.finite(size.height) }
				},
			),
			edges: diagram.edges.map(|edge| { from: endpoint(edge.from), to: endpoint(edge.to) }),
			edge_labels: labels,
			end_labels,
			group_reservations: reservations.map(|r| { group: 1 + (preorder.find_first_index(|g| g == r.group) ?? crash "registered reservation group"), width: FlowCore.finite(r.width), height: FlowCore.finite(r.height) }),
			root: Group({ children: root_children, flow: Together, spacing: Set(root_spacing), padding: { top: 12, right: 12, bottom: 12, left: 12 }, min_width: 0, min_height: 0, label: None }),
		}
		result = match Layered.layout_grouped(input, { ..Layered.default_grouped_settings, direction: diagram.direction }, Layered.default_grouped_run) {
			Ok(value) => value
			Err(_) => crash "parsed and measured flow input satisfies the geometry contract"
		}
		groups = diagram.groups.map_with_index(|_, g| result.groups.get(1 + (preorder.find_first_index(|i| i == g) ?? crash "registered group index")) ?? crash "group results aligned")
		edges = result.layout.routes.map_with_index(
			|route, e| {
				points = match route {
					Polyline(values) => values
					Line(a, b) => [a, b]
					Curves(_) => crash "coordinated flow returns polylines"
				}
				label = match labels.find_first_index(|item| item.edge == e) {
					Ok(i) => Some(result.label_anchors.get(i) ?? crash "source-aligned label anchor")
					Err(_) => None
				}
				{ points, label }
			},
		)
		var $ends = List.repeat({ from: None, to: None }, diagram.edges.len())
		for (label, i) in end_labels.map_with_index(|label, i| (label, i)) {
			placement = Some(result.end_label_placements.get(i) ?? crash "source-aligned endpoint label placement")
			old = $ends.get(label.edge) ?? crash "source-aligned endpoint edge"
			$ends = $ends.set(
				label.edge,
				if label.endpoint == From {
					{ ..old, from: placement }
				} else {
					{ ..old, to: placement }
				},
			) ?? []
		}
		{ raw: { nodes: result.nodes, groups, edges }, ends: $ends }
	}
}
