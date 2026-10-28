import LayeredGroup
import Geom
import LayeredFlow
import LayeredFlowGraph
import LayeredFlowImport
import LayeredFlowInput
import LayeredFlowLabels

## Internal implementation of Layered's recursive grouped input boundary.
LayeredGrouped :: {}.{
	Size : { width : F64, height : F64 }
	Insets : { top : F64, right : F64, bottom : F64, left : F64 }
	Spacing : LayeredFlowGraph.Spacing
	Endpoint : [Node(U64), Group(U64)]
	Input : {
		nodes : List(Size),
		edges : List({ from : Endpoint, to : Endpoint }),
		edge_labels : List({ edge : U64, width : F64, height : F64 }),
		end_labels : List({ edge : U64, endpoint : [From, To], width : F64, height : F64 }),
		group_reservations : List({ group : U64, width : F64, height : F64 }),
		root : LayeredGroup,
	}
	Settings : { direction : [Down, Up, Left, Right], spacing : Spacing }
	RunArgs : { seed : I64 }
	Problem := [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingMember(U64),
		MissingNode(U64),
		DuplicateNode(U64),
		InvalidGroupSize(U64),
		InvalidGroupPadding(U64),
		InvalidGroupLabel(U64),
		InvalidGroupSpacing(U64),
		InvalidSpacing,
		MissingEdgeStart(U64),
		MissingEdgeEnd(U64),
		MissingLabelEdge(U64),
		InvalidLabelSize(U64),
		DuplicateLabel(U64),
		MissingEndLabelEdge(U64),
		InvalidEndLabelSize(U64),
		DuplicateEndLabel(U64),
		MissingReservationGroup(U64),
		InvalidReservationSize(U64),
		DuplicateReservation(U64),
	].{
		is_eq : _
	}
	Result : {
		layout : { positions : List(Geom.Point), routes : List(Geom.Route), bounds : Geom.Rect },
		nodes : List(Geom.Rect),
		groups : List(Geom.Rect),
		label_anchors : List(Geom.Point),
		end_label_placements : List({ point : Geom.Point, port : Geom.Point }),
		layers : List(U64),
		backward_edges : List(U64),
	}
	Prepared : GroupedPrepared
	default_group : LayeredGroup
	default_group = Group({ children: [], flow: Together, spacing: Inherit, padding: { top: 0, right: 0, bottom: 0, left: 0 }, min_width: 0, min_height: 0, label: None })
	default_input : Input
	default_input = { nodes: [], edges: [], edge_labels: [], end_labels: [], group_reservations: [], root: LayeredGrouped.default_group }
	default_settings : Settings
	default_settings = { direction: Down, spacing: LayeredFlowGraph.blank_spacing }
	default_run : RunArgs
	default_run = { seed: 1 }

	valid : F64 -> Bool
	valid = |v| F64.is_finite(v) and v >= 0
	valid_spacing : Spacing -> Bool
	valid_spacing = |s| [s.node_node, s.node_node_between_layers, s.edge_node, s.edge_node_between_layers, s.edge_edge, s.edge_edge_between_layers, s.edge_label, s.label_label, s.label_node, s.port_port, s.node_self_loop, s.ports_surrounding].all(LayeredGrouped.valid)

	prepare : Input, Settings -> [Ok(Prepared), Err(List(Problem))]
	prepare = |input, settings| {
		Group(root) = input.root
		var $problems = []
		if !LayeredGrouped.valid_spacing(settings.spacing) {
			$problems = $problems.append(InvalidSpacing)
		}
		for (size, i) in input.nodes.map_with_index(|size, i| (size, i)) {
			if !LayeredGrouped.valid(size.width) {
				$problems = $problems.append(InvalidNodeWidth(i))
			}
			if !LayeredGrouped.valid(size.height) {
				$problems = $problems.append(InvalidNodeHeight(i))
			}
		}
		var $seen = List.repeat(False, input.nodes.len())
		var $nodes = List.repeat({ container: Root }, input.nodes.len())
		var $groups = []
		var $titles = []
		var $registration = []
		root_spacing = match root.spacing {
			Inherit => settings.spacing
			Set(value) => value
		}
		var $stack = root.children.rev().map(|child| { parent: Root, child, spacing: root_spacing })
		var $group_values = [(0.U64, root)]
		while !$stack.is_empty() {
			item = $stack.last() ?? crash "nonempty traversal stack"
			$stack = $stack.drop_last(1)
			match item.child {
				Node(n) => {
					if n >= input.nodes.len() {
						$problems = $problems.append(MissingNode(n))
					}
					else if $seen.get(n) ?? False {
						$problems = $problems.append(DuplicateNode(n))
					}
					else {
						$seen = $seen.set(n, True) ?? []
						$nodes = $nodes.set(n, { container: item.parent }) ?? []
						$registration = $registration.append(NodeItem(n))
					}
				}
				Nested(Group(group)) => {
					g = $groups.len()
					spacing = match group.spacing {
						Inherit => item.spacing
						Set(value) => value
					}
					direction = match group.flow {
						Together => Inherit
						Separate(d) => Set(d)
					}
					$groups = $groups.append({ container: item.parent, direction, separate: group.flow != Together, spacing, padding: group.padding, min_width: group.min_width, min_height: group.min_height })
					$titles = $titles.append(
						match group.label {
							None => { width: 0, height: 0 }
							Some(size) => size
						},
					)
					$registration = $registration.append(GroupItem(g))
					$group_values = $group_values.append((g + 1, group))
					$stack = $stack.concat(group.children.rev().map(|child| { parent: Group(g), child, spacing }))
				}
			}
		}
		for i in 0..<$seen.len() {
			if !($seen.get(i) ?? False) {
				$problems = $problems.append(MissingMember(i))
			}
		}
		for (i, group) in $group_values {
			if !LayeredGrouped.valid(group.min_width) or !LayeredGrouped.valid(group.min_height) {
				$problems = $problems.append(InvalidGroupSize(i))
			}
			if ![group.padding.top, group.padding.right, group.padding.bottom, group.padding.left].all(LayeredGrouped.valid) {
				$problems = $problems.append(InvalidGroupPadding(i))
			}
			match group.label {
				None => {}
				Some(size) => {
					if !LayeredGrouped.valid(size.width) or !LayeredGrouped.valid(size.height) {
						$problems = $problems.append(InvalidGroupLabel(i))
					}
				}
			}
			match group.spacing {
				Inherit => {}
				Set(spacing) => {
					if !LayeredGrouped.valid_spacing(spacing) {
						$problems = $problems.append(InvalidGroupSpacing(i))
					}
				}
			}
		}
		endpoint_valid = |end| match end {
			Node(n) => n < input.nodes.len()
			Group(g) => g > 0 and g <= $groups.len()
		}
		for (edge, i) in input.edges.map_with_index(|edge, i| (edge, i)) {
			if !endpoint_valid(edge.from) {
				$problems = $problems.append(MissingEdgeStart(i))
			}
			if !endpoint_valid(edge.to) {
				$problems = $problems.append(MissingEdgeEnd(i))
			}
		}
		var $labels = List.repeat(None, input.edges.len())
		for (label, i) in input.edge_labels.map_with_index(|label, i| (label, i)) {
			if label.edge >= input.edges.len() {
				$problems = $problems.append(MissingLabelEdge(i))
			}
			if !LayeredGrouped.valid(label.width) or !LayeredGrouped.valid(label.height) {
				$problems = $problems.append(InvalidLabelSize(i))
			}
			if label.edge < $labels.len() {
				if ($labels.get(label.edge) ?? None) != None {
					$problems = $problems.append(DuplicateLabel(i))
				}
				$labels = $labels.set(label.edge, Some({ width: label.width, height: label.height })) ?? []
			}
		}
		var $end_sizes = List.repeat({ from: None, to: None }, input.edges.len())
		for (label, i) in input.end_labels.map_with_index(|label, i| (label, i)) {
			if label.edge >= input.edges.len() {
				$problems = $problems.append(MissingEndLabelEdge(i))
			}
			if !LayeredGrouped.valid(label.width) or !LayeredGrouped.valid(label.height) {
				$problems = $problems.append(InvalidEndLabelSize(i))
			}
			if label.edge < $end_sizes.len() {
				ends = $end_sizes.get(label.edge) ?? crash "validated end label index"
				old = if label.endpoint == From {
					ends.from
				} else ends.to
				if old != None {
					$problems = $problems.append(DuplicateEndLabel(i))
				}
				size = Some({ width: label.width, height: label.height })
				$end_sizes = $end_sizes.set(
					label.edge,
					if label.endpoint == From {
						{ ..ends, from: size }
					} else {
						{ ..ends, to: size }
					},
				) ?? []
			}
		}
		var $reserved = List.repeat(False, $groups.len() + 1)
		for (reservation, i) in input.group_reservations.map_with_index(|reservation, i| (reservation, i)) {
			if reservation.group >= $reserved.len() {
				$problems = $problems.append(MissingReservationGroup(i))
			}
			if !LayeredGrouped.valid(reservation.width) or !LayeredGrouped.valid(reservation.height) {
				$problems = $problems.append(InvalidReservationSize(i))
			}
			if reservation.group < $reserved.len() {
				if $reserved.get(reservation.group) ?? False {
					$problems = $problems.append(DuplicateReservation(i))
				}
				$reserved = $reserved.set(reservation.group, True) ?? []
			}
		}
		if !$problems.is_empty() {
			return Err($problems)
		}
		endpoint = |end| match end {
			Node(n) => Node(n)
			Group(g) => Group(g - 1)
		}
		spacing = match root.spacing {
			Inherit => settings.spacing
			Set(value) => value
		}
		direction = match root.flow {
			Together => settings.direction
			Separate(d) => d
		}
		diagram = { direction, nodes: $nodes, groups: $groups, edges: input.edges.map(|e| { from: endpoint(e.from), to: endpoint(e.to) }), spacing, padding: root.padding }
		sizes = { nodes: input.nodes, edge_labels: $labels, group_titles: $titles }
		setup = LayeredFlowImport.build_registered(diagram, sizes, $registration)
		Ok({ diagram, setup, labels: input.edge_labels, end_labels: input.end_labels, end_sizes: $end_sizes, reservations: input.group_reservations, min_width: root.min_width, min_height: root.min_height })
	}

	layout_prepared : Prepared, RunArgs -> Result
	layout_prepared = |prepared, args| prepared.run(args)
	layout : Input, Settings, RunArgs -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings, args| match LayeredGrouped.prepare(input, settings) {
		Err(problems) => Err(problems)
		Ok(prepared) => Ok(prepared.run(args))
	}
}

GroupedPrepared := {
	diagram : LayeredFlowInput.Input,
	setup : LayeredFlowImport.Setup,
	labels : List({ edge : U64, width : F64, height : F64 }),
	end_labels : List({ edge : U64, endpoint : [From, To], width : F64, height : F64 }),
	end_sizes : List(LayeredFlowLabels.Ends),
	reservations : List({ group : U64, width : F64, height : F64 }),
	min_width : F64,
	min_height : F64,
}.{
	run : GroupedPrepared, LayeredGrouped.RunArgs -> LayeredGrouped.Result
	run = |p, args| {
		layered = LayeredFlow.layered(p.setup.model)
		ordered = LayeredFlow.order_seeded(layered, False, [], args.seed)
		placed = LayeredFlow.placed_with_margins(
			ordered.model,
			ordered.randoms,
			|model, g| {
				var $model = LayeredFlowLabels.margins(model, g, p.end_sizes)
				direction = LayeredFlowGraph.graph(model, g).direction
				for reservation in p.reservations {
					if reservation.group > 0 {
						n = p.setup.group_node.get(reservation.group - 1) ?? crash "validated reservation group"
						node = LayeredFlowGraph.node($model, n)
						if node.graph == g {
							size = LayeredFlowImport.internal_size(direction, reservation.width, reservation.height)
							x = (size.width - node.width).max(0) / 2
							y = (size.height - node.height).max(0) / 2
							margin = { top: node.margin.top.max(y), bottom: node.margin.bottom.max(y), left: node.margin.left.max(x), right: node.margin.right.max(x) }
							$model = LayeredFlowGraph.set_node($model, n, { ..node, margin })
						}
					}
				}
				$model
			},
		)
		raw = LayeredFlow.export(p.diagram, p.setup, placed)
		point = |v| { x: Geom.saturate(v.x), y: Geom.saturate(v.y) }
		rect = |r| { x: Geom.saturate(r.x), y: Geom.saturate(r.y), width: Geom.saturate(r.width), height: Geom.saturate(r.height) }
		nodes = raw.nodes.map(rect)
		groups = raw.groups.map(rect)
		routes = raw.edges.map(|edge| Polyline(edge.points.map(point)))
		label_anchors = p.labels.map(
			|label| point(
				match (raw.edges.get(label.edge) ?? crash "validated label edge").label {
					Some(at) => at
					None => { x: 0, y: 0 }
				},
			),
		)
		end_placements = LayeredFlowLabels.placements(placed, p.end_sizes)
		end_label_placements = p.end_labels.map(
			|label| {
				ends = end_placements.get(label.edge) ?? crash "validated end label edge"
				placement = if label.endpoint == From {
					ends.from
				} else ends.to
				match placement {
					Some(value) => { point: point(value.point), port: point(value.port) }
					None => {
						route = (raw.edges.get(label.edge) ?? crash "validated end label edge").points
						at = point(
							if label.endpoint == From {
								route.first() ?? { x: 0, y: 0 }
							} else {
								route.last() ?? { x: 0, y: 0 }
							},
						)
						{ point: at, port: at }
					}
				}
			},
		)
		root = LayeredFlowGraph.graph(placed, 0)
		root_rect = LayeredFlow.turn_rect(root.direction, { x: 0, y: 0, width: root.width + root.padding.left + root.padding.right, height: root.height + root.padding.top + root.padding.bottom })
		var $bounds = { x: 0, y: 0, width: Geom.saturate(root_rect.width).max(p.min_width), height: Geom.saturate(root_rect.height).max(p.min_height) }
		for box in nodes.concat(groups) {
			$bounds = { x: $bounds.x.min(box.x), y: $bounds.y.min(box.y), width: $bounds.width.max(Geom.saturate(box.x + box.width)), height: $bounds.height.max(Geom.saturate(box.y + box.height)) }
		}
		for edge in raw.edges {
			for v in edge.points {
				at = point(v)
				$bounds = { x: $bounds.x.min(at.x), y: $bounds.y.min(at.y), width: $bounds.width.max(at.x), height: $bounds.height.max(at.y) }
			}
		}
		for (label, i) in p.labels.map_with_index(|label, i| (label, i)) {
			at = label_anchors.get(i) ?? crash "label anchors are input aligned"
			$bounds = { x: $bounds.x.min(Geom.saturate(at.x - label.width / 2)), y: $bounds.y.min(Geom.saturate(at.y - label.height / 2)), width: $bounds.width.max(Geom.saturate(at.x + label.width / 2)), height: $bounds.height.max(Geom.saturate(at.y + label.height / 2)) }
		}
		for (label, i) in p.end_labels.map_with_index(|label, i| (label, i)) {
			at = (end_label_placements.get(i) ?? crash "end labels aligned").point
			$bounds = { x: $bounds.x.min(Geom.saturate(at.x - label.width / 2)), y: $bounds.y.min(Geom.saturate(at.y - label.height / 2)), width: $bounds.width.max(Geom.saturate(at.x + label.width / 2)), height: $bounds.height.max(Geom.saturate(at.y + label.height / 2)) }
		}
		for reservation in p.reservations {
			if reservation.group == 0 {
				$bounds = { ..$bounds, width: $bounds.width.max(reservation.width), height: $bounds.height.max(reservation.height) }
			}
		}
		bounds = { ..$bounds, width: Geom.saturate($bounds.width - $bounds.x), height: Geom.saturate($bounds.height - $bounds.y) }
		layers = p.setup.node_of.map(|n| LayeredFlowGraph.node(placed, n).layer)
		backward_edges = p.setup.edge_of.map_with_index(|e, i| (i, (p.setup.flipped.get(i) ?? False) != LayeredFlowGraph.edge(placed, e).reversed)).keep_if(|(_, back)| back).map(|(i, _)| i)
		{ layout: { positions: nodes.map(|r| point({ x: r.x + r.width / 2, y: r.y + r.height / 2 })), routes, bounds }, nodes, groups: [bounds].concat(groups), label_anchors, end_label_placements, layers, backward_edges }
	}
}

## Empty graphs have source-aligned empty results and one root rectangle.
expect match LayeredGrouped.layout(LayeredGrouped.default_input, LayeredGrouped.default_settings, LayeredGrouped.default_run) {
	Err(_) => False
	Ok(result) => result.nodes.is_empty() and result.layout.routes.is_empty() and result.groups == [result.layout.bounds] and result.layout.bounds == Geom.empty_bounds
}

## Preparation reports independent size, ownership, endpoint and label problems.
expect {
	input = {
		..LayeredGrouped.default_input,
		nodes: [{ width: -1, height: -2 }, { width: 4, height: 5 }],
		edges: [{ from: Node(8), to: Group(0) }],
		edge_labels: [{ edge: 9, width: -3, height: 4 }],
	}
	match LayeredGrouped.prepare(input, LayeredGrouped.default_settings) {
		Ok(_) => False
		Err(problems) => problems == [InvalidNodeWidth(0), InvalidNodeHeight(0), MissingMember(0), MissingMember(1), MissingEdgeStart(0), MissingEdgeEnd(0), MissingLabelEdge(0), InvalidLabelSize(0)]
	}
}

## An empty child group remains a real measured box, including in vertical flow.
expect {
	Group(empty) = LayeredGrouped.default_group
	child = Group({ ..empty, min_width: 80, min_height: 30 })
	input = { ..LayeredGrouped.default_input, root: Group({ ..empty, children: [Nested(child)] }) }
	match LayeredGrouped.layout(input, LayeredGrouped.default_settings, LayeredGrouped.default_run) {
		Err(_) => False
		Ok(result) => match result.groups.get(1) {
			Err(_) => False
			Ok(box) => box.width == 80 and box.height == 30
		}
	}
}
