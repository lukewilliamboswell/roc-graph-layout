import Flowchart
import FlowGeometry
import FlowLayoutLevel

## Where every part of a flowchart goes, given how much room each part
## needs. The arrangement follows Mermaid's default flowchart layout: nodes
## sit in layers along the flow, a subgraph is a box laid out from its own
## members and then placed as one block among its siblings, a label sits on
## its edge in the middle layer the edge passes, and edges run as
## right-angled lines from outline to outline.
##
## Every diagram has a layout, including an empty one; results are
## index-aligned with the diagram and identical for identical input. All
## coordinates are finite.
FlowLayout :: {}.{

	## Lay out a diagram. `sizes` is index-aligned with the diagram; a missing
	## or unusable size counts as zero.
	layout : Flowchart.Diagram, FlowGeometry.Sizes -> FlowGeometry.Geometry
	layout = |diagram, sizes| {
		plan = FlowLayout.make_plan(diagram, sizes)
		placed = FlowLayout.place_all(plan, FlowLayout.solve_levels(plan))
		FlowLayout.normalise(placed.geometry, plan.label_sizes)
	}

	## Spacing at the top level of the drawing.
	root_spacing : FlowLayoutLevel.Spacing
	root_spacing = { node_node: 40, node_layers: 40, edge_node_layers: 20, edge_edge: 20, loop_depth: 20 }

	## Spacing inside subgraphs.
	group_spacing : FlowLayoutLevel.Spacing
	group_spacing = { node_node: 50, node_layers: 24, edge_node_layers: 30, edge_edge: 20, loop_depth: 12 }

	## Empty space between a subgraph's frame and its members.
	group_padding : F64
	group_padding = 24

	## Extra width a subgraph frame keeps beside its title.
	title_room : F64
	title_room = 8

	## Height a title strip adds beyond the title's own height.
	title_strip : F64
	title_strip = 3

	## Where content starts and how far the drawing's bounds reach past it.
	content_origin : F64
	content_origin = 12

	bounds_margin : F64
	bounds_margin = 8

	Size : FlowLayoutLevel.Size

	Point : FlowGeometry.Point

	Rect : FlowGeometry.Rect

	Direction : [Down, Up, Right, Left]

	## A member of one level: a node, or a subgraph drawn as one box.
	Item : [Leaf(U64), Box(U64)]

	## What an edge is to the layout.
	EdgeRole : [
		## Laid out at a level, between two of its members.
		Level({ level : U64, index : U64, from_item : Item, to_item : Item, from_ports : List({ level : U64, index : U64 }), to_ports : List({ level : U64, index : U64 }) }),

		## A loop at a level, on one member.
		Loop({ level : U64, index : U64 }),

		## Between a subgraph and something inside it.
		Inside({ group : U64, inner : [Node(U64), Group(U64)], group_first : Bool }),
	]

	## A level is a subgraph, by index, or the whole drawing, numbered after
	## the subgraphs.
	Plan : {
		diagram : Flowchart.Diagram,
		node_sizes : List(Size),
		label_sizes : List([None, Some(Size)]),
		titles : List(Size),
		directions : List(Direction),

		## The members of each level, in the order Mermaid gives them.
		items : List(List(Item)),

		## Which member of its level each node and each subgraph is.
		node_slots : List(U64),
		group_slots : List(U64),
		roles : List(EdgeRole),

		## Diagram edges and loops handled at each level.
		level_edges : List(List(U64)),
		level_loops : List(List(U64)),

		## Connections leaving or entering each level for edges laid out
		## further out.
		level_ports : List(List({ item : Item, outgoing : Bool, edge : U64 })),

		## Subgraphs from the outside in, each after its parent.
		order : List(U64),
		empty : List(Bool),
	}

	finite_size : F64 -> F64
	finite_size = |value| if (F64.is_finite(value) and value > 0) value else 0

	no_group : Flowchart.Group
	no_group = { id: "", title: "", container: Root, direction: Inherit, classes: [] }

	## Groups enclosing a container, innermost first.
	ancestors : List(Flowchart.Group), Flowchart.Container -> List(U64)
	ancestors = |groups, container| {
		var $out = []
		var $at = container
		var $going = True
		while $going {
			match $at {
				Root => {
					$going = False
				}
				Group(g) =>
					if g < groups.len() and !$out.contains(g) {
						$out = $out.append(g)
						$at = (groups.get(g) ?? FlowLayout.no_group).container
					} else {
						$going = False
					}
			}
		}
		$out
	}

	## The leading part of a chain up to and including `stop`.
	until : List(U64), U64 -> List(U64)
	until = |chain, stop|
		match chain.find_first_index(|x| x == stop) {
			Ok(i) => chain.take_first(i + 1)
			Err(_) => chain
		}

	## Subgraphs directly inside a container, last declared first, which is
	## the order Mermaid hands them to layout.
	children_groups : List(Flowchart.Group), Flowchart.Container -> List(U64)
	children_groups = |groups, container| {
		var $out = []
		var $i = groups.len()
		while $i > 0 {
			$i = $i - 1
			if (groups.get($i) ?? FlowLayout.no_group).container == container {
				$out = $out.append($i)
			}
		}
		$out
	}

	## Subgraphs from the outside in, children in layout order.
	preorder : List(Flowchart.Group) -> List(U64)
	preorder = |groups| {
		var $out = []
		var $stack = FlowLayout.children_groups(groups, Root).rev()
		var $steps = 0
		while !$stack.is_empty() and $steps < groups.len() {
			g = $stack.last() ?? 0
			$stack = $stack.drop_last(1)
			if !$out.contains(g) {
				$out = $out.append(g)
				$stack = $stack.concat(FlowLayout.children_groups(groups, Group(g)).rev())
			}
			$steps = $steps + 1
		}
		$out
	}

	make_plan : Flowchart.Diagram, FlowGeometry.Sizes -> Plan
	make_plan = |diagram, sizes| {
		groups = diagram.groups
		group_count = groups.len()
		root = group_count
		node_sizes = diagram.nodes.map_with_index(
			|_, i|
				match sizes.nodes.get(i) {
					Ok(size) => { width: FlowLayout.finite_size(size.width), height: FlowLayout.finite_size(size.height) }
					Err(_) => { width: 0, height: 0 }
				},
		)
		titles = groups.map_with_index(
			|_, g|
				match sizes.group_titles.get(g) {
					Ok(block) => { width: FlowLayout.finite_size(block.width), height: FlowLayout.finite_size(block.height) }
					Err(_) => { width: 0, height: 0 }
				},
		)
		label_sizes = diagram.edges.map_with_index(
			|_, e|
				match sizes.edge_labels.get(e) ?? None {
					Some(block) => Some({ width: FlowLayout.finite_size(block.width), height: FlowLayout.finite_size(block.height) })
					None => None
				},
		)
		node_ancestors = diagram.nodes.map(|node| FlowLayout.ancestors(groups, node.container))
		group_ancestors = groups.map(|group| FlowLayout.ancestors(groups, group.container))
		level_of = |container|
			match container {
				Root => root
				Group(g) => if (g < group_count) g else root
			}

		# Members of each level: subgraphs first, then nodes.
		var $items = List.repeat([], group_count + 1)
		var $group_slots = List.repeat(0, group_count)
		var $node_slots = List.repeat(0, diagram.nodes.len())
		order = FlowLayout.preorder(groups)
		for level in [root].concat(order) {
			container = if (level == root) Root else Group(level)
			for g in FlowLayout.children_groups(groups, container) {
				$group_slots = $group_slots.set(g, ($items.get(level) ?? []).len()) ?? []
				$items = $items.set(level, ($items.get(level) ?? []).append(Box(g))) ?? []
			}
		}
		for i in 0..<diagram.nodes.len() {
			level = level_of((diagram.nodes.get(i) ?? { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }).container)
			$node_slots = $node_slots.set(i, ($items.get(level) ?? []).len()) ?? []
			$items = $items.set(level, ($items.get(level) ?? []).append(Leaf(i))) ?? []
		}
		items = $items
		empty = groups.map_with_index(|_, g| (items.get(g) ?? []).is_empty())

		chain_of = |end|
			match end {
				Node(i) => node_ancestors.get(i) ?? []
				Group(g) => [g].concat(group_ancestors.get(g) ?? [])
			}
		# The member of `level` that holds an edge end.
		item_at = |end, level| {
			chain = chain_of(end)
			holder = if level == root {
				chain.last()
			} else {
				match chain.find_first_index(|g| g == level) {
					Ok(0) => Err(OutOfBounds)
					Ok(k) => chain.get(k - 1)
					Err(_) => Err(OutOfBounds)
				}
			}
			match holder {
				Ok(g) => Box(g)
				Err(_) =>
					match end {
						Node(i) => Leaf(i)
						Group(g) => Box(g)
					}
			}
		}

		# Roles, and which subgraphs give up their own direction because an
		# edge crosses into them, as in Mermaid.
		var $marked = List.repeat(False, group_count)
		var $level_edges = List.repeat([], group_count + 1)
		var $level_loops = List.repeat([], group_count + 1)
		var $level_ports = List.repeat([], group_count + 1)
		var $roles = []
		for e in 0..<diagram.edges.len() {
			edge = diagram.edges.get(e) ?? { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }
			from_chain = chain_of(edge.from)
			to_chain = chain_of(edge.to)
			lca = match from_chain.find_first(|g| to_chain.contains(g)) {
				Ok(g) => g
				Err(_) => root
			}
			from_parent = (
				match edge.from {
					Node(_) => from_chain
					Group(_) => from_chain.drop_first(1)
				}
			).first()
			to_parent = (
				match edge.to {
					Node(_) => to_chain
					Group(_) => to_chain.drop_first(1)
				}
			).first()
			if from_parent != to_parent {
				for g in FlowLayout.until(from_chain, lca).concat(FlowLayout.until(to_chain, lca)) {
					$marked = $marked.set(g, True) ?? []
				}
			}
			role = if edge.from == edge.to {
				level = match edge.from {
					Node(i) => level_of((diagram.nodes.get(i) ?? { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }).container)
					Group(g) => level_of((groups.get(g) ?? FlowLayout.no_group).container)
				}
				Loop({ level, index: ($level_loops.get(level) ?? []).len() })
			} else {
				match (edge.from, edge.to) {
					(Group(g), inner) if lca == g => Inside({ group: g, inner, group_first: True })
					(inner, Group(g)) if lca == g => Inside({ group: g, inner, group_first: False })
					_ => {
						# The subgraphs an end lies inside, below the level the edge is
						# laid out at, innermost first.
						crossed = |end, chain|
							(
								match end {
									Node(_) => chain
									Group(_) => chain.drop_first(1)
								}
							).take_first(chain.find_first_index(|g| g == lca) ?? chain.len())
						var $from_ports = []
						for h in crossed(edge.from, from_chain) {
							$from_ports = $from_ports.append({ level: h, index: ($level_ports.get(h) ?? []).len() })
							$level_ports = $level_ports.set(h, ($level_ports.get(h) ?? []).append({ item: item_at(edge.from, h), outgoing: True, edge: e })) ?? []
						}
						var $to_ports = []
						for h in crossed(edge.to, to_chain) {
							$to_ports = $to_ports.append({ level: h, index: ($level_ports.get(h) ?? []).len() })
							$level_ports = $level_ports.set(h, ($level_ports.get(h) ?? []).append({ item: item_at(edge.to, h), outgoing: False, edge: e })) ?? []
						}
						from_ports = $from_ports
						to_ports = $to_ports
						Level({ level: lca, index: ($level_edges.get(lca) ?? []).len(), from_item: item_at(edge.from, lca), to_item: item_at(edge.to, lca), from_ports, to_ports })
					}
				}
			}
			match role {
				Level(r) => {
					$level_edges = $level_edges.set(r.level, ($level_edges.get(r.level) ?? []).append(e)) ?? []
				}
				Loop(r) => {
					$level_loops = $level_loops.set(r.level, ($level_loops.get(r.level) ?? []).append(e)) ?? []
				}
				Inside(_) => {}
			}
			$roles = $roles.append(role)
		}

		marked = $marked
		own_direction = |g|
			match (groups.get(g) ?? FlowLayout.no_group).direction {
				Set(d) if !(marked.get(g) ?? False) => Some(d)
				_ => None
			}
		directions = groups.map_with_index(
			|_, g| {
				chain = [g].concat(group_ancestors.get(g) ?? [])
				match chain.find_first(|a| own_direction(a) != None) {
					Ok(a) =>
						match own_direction(a) {
							Some(d) => d
							None => diagram.direction
						}
					Err(_) => diagram.direction
				}
			},
		)
		{
			diagram,
			node_sizes,
			label_sizes,
			titles,
			directions,
			items,
			node_slots: $node_slots,
			group_slots: $group_slots,
			roles: $roles,
			level_edges: $level_edges,
			level_loops: $level_loops,
			level_ports: $level_ports,
			order,
			empty,
		}
	}

	direction_of : Plan, U64 -> Direction
	direction_of = |plan, level| plan.directions.get(level) ?? plan.diagram.direction

	## A box's extent along and across the flow of a level's direction.
	canonical : Size, Direction -> Size
	canonical = |size, direction|
		match direction {
			Down | Up => size
			Right | Left => { width: size.height, height: size.width }
		}

	## Turn a point of a level's downward layout to the level's direction.
	turn : Point, Size, Direction -> Point
	turn = |p, size, direction|
		match direction {
			Down => p
			Up => { x: p.x, y: size.height - p.y }
			Right => { x: p.y, y: p.x }
			Left => { x: size.height - p.y, y: p.x }
		}

	## A level, laid out and turned to its direction: positions relative to
	## the level's content corner.
	Solved : {
		centers : List(Point),
		routes : List(List(Point)),
		labels : List([None, Some(Point)]),
		loop_routes : List(List(Point)),
		loop_labels : List([None, Some(Point)]),
		port_routes : List(List(Point)),
		size : Size,
	}

	empty_solved : Solved
	empty_solved = { centers: [], routes: [], labels: [], loop_routes: [], loop_labels: [], port_routes: [], size: { width: 0, height: 0 } }

	## The box a subgraph is drawn as, given its laid-out content.
	frame_size : Plan, U64, Size -> Size
	frame_size = |plan, g, content| {
		title = plan.titles.get(g) ?? { width: 0, height: 0 }
		if plan.empty.get(g) ?? False {
			{ width: title.width + FlowLayout.title_room, height: 0 }
		} else {
			pad = FlowLayout.group_padding
			{ width: (content.width + pad * 2).max(title.width + FlowLayout.title_room), height: content.height + pad * 2 + FlowLayout.header(plan, g) }
		}
	}

	header : Plan, U64 -> F64
	header = |plan, g| {
		title = plan.titles.get(g) ?? { width: 0, height: 0 }
		if (title.height > 0) title.height + FlowLayout.title_strip else 0
	}

	solve_levels : Plan -> List(Solved)
	solve_levels = |plan| {
		group_count = plan.directions.len()
		root = group_count
		var $solved = List.repeat(FlowLayout.empty_solved, group_count + 1)
		var $frames = List.repeat({ width: 0, height: 0 }, group_count)
		# Edges drawn against the flow where they are laid out leave the
		# subgraphs they start in through the top rather than the bottom.
		var $against = List.repeat(False, plan.roles.len())
		for level in plan.order.append(root) {
			slot = |item|
				match item {
					Leaf(i) => plan.node_slots.get(i) ?? 0
					Box(g) => plan.group_slots.get(g) ?? 0
				}
			level_edges = plan.level_edges.get(level) ?? []
			pairs = level_edges.map(
				|e|
					match plan.roles.get(e) {
						Ok(Level(r)) => { from: slot(r.from_item), to: slot(r.to_item) }
						_ => { from: 0, to: 0 }
					},
			)
			flags = FlowLayoutLevel.feedback((plan.items.get(level) ?? []).len(), pairs)
			for k in 0..<level_edges.len() {
				if flags.get(k) ?? False {
					$against = $against.set(level_edges.get(k) ?? 0, True) ?? []
				}
			}
		}
		against = $against
		for level in plan.order.rev().append(root) {
			direction = FlowLayout.direction_of(plan, level)
			spacing = if (level == root) FlowLayout.root_spacing else FlowLayout.group_spacing
			items = plan.items.get(level) ?? []
			display_sizes = items.map(
				|item|
					match item {
						Leaf(i) => plan.node_sizes.get(i) ?? { width: 0, height: 0 }
						Box(g) => $frames.get(g) ?? { width: 0, height: 0 }
					},
			)
			slot_of = |item|
				match item {
					Leaf(i) => plan.node_slots.get(i) ?? 0
					Box(g) => plan.group_slots.get(g) ?? 0
				}
			edges = (plan.level_edges.get(level) ?? []).map(
				|e|
					match plan.roles.get(e) {
						Ok(Level(r)) => {
							from: slot_of(r.from_item),
							to: slot_of(r.to_item),
							label: match plan.label_sizes.get(e) ?? None {
								Some(size) => Some(FlowLayout.canonical(size, direction))
								None => None
							},
						}
						_ => { from: 0, to: 0, label: None }
					},
			)
			loops = (plan.level_loops.get(level) ?? []).map(
				|e| {
					edge = plan.diagram.edges.get(e) ?? { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }
					item = match edge.from {
						Node(i) => slot_of(Leaf(i))
						Group(g) => slot_of(Box(g))
					}
					{
						item,
						label: match plan.label_sizes.get(e) ?? None {
							Some(size) => Some(FlowLayout.canonical(size, direction))
							None => None
						},
					}
				},
			)
			ports = (plan.level_ports.get(level) ?? []).map(|p| { item: slot_of(p.item), outgoing: p.outgoing != (against.get(p.edge) ?? False), key: None })
			result = FlowLayoutLevel.solve({ sizes: display_sizes.map(|s| FlowLayout.canonical(s, direction)), edges, loops, ports, spacing })
			size = result.size
			turned = |p| FlowLayout.turn(p, size, direction)
			turn_label = |label|
				match label {
					Some(p) => Some(turned(p))
					None => None
				}
			solved = {
				centers: result.centers.map(turned),
				routes: result.routes.map(|r| r.map(turned)),
				labels: result.labels.map(turn_label),
				loop_routes: result.loop_routes.map(|r| r.map(turned)),
				loop_labels: result.loop_labels.map(turn_label),
				port_routes: result.port_routes.map(|r| r.map(turned)),
				size: FlowLayout.canonical(size, direction),
			}
			$solved = $solved.set(level, solved) ?? []
			if level < group_count {
				$frames = $frames.set(level, FlowLayout.frame_size(plan, level, solved.size)) ?? []
			}
		}
		$solved
	}

	center_rect : Point, Size -> Rect
	center_rect = |center, size| { x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height }

	## Every part in place, before the drawing is moved to Mermaid's origin.
	place_all : Plan, List(Solved) -> { geometry : FlowGeometry.Geometry, origins : List(Point) }
	place_all = |plan, solved| {
		group_count = plan.directions.len()
		root = group_count
		level_solved = |level| solved.get(level) ?? FlowLayout.empty_solved

		# Content corners and frames, from the outside in.
		var $origins = List.repeat({ x: 0, y: 0 }, group_count + 1)
		var $frames = List.repeat({ x: 0, y: 0, width: 0, height: 0 }, group_count)
		for g in plan.order {
			parent = match (plan.diagram.groups.get(g) ?? FlowLayout.no_group).container {
				Root => root
				Group(p) => if (p < group_count) p else root
			}
			origin = $origins.get(parent) ?? { x: 0, y: 0 }
			local = (level_solved(parent).centers.get(plan.group_slots.get(g) ?? 0)) ?? { x: 0, y: 0 }
			content = level_solved(g).size
			frame = FlowLayout.frame_size(plan, g, content)
			rect = FlowLayout.center_rect({ x: origin.x + local.x, y: origin.y + local.y }, frame)
			$frames = $frames.set(g, rect) ?? []
			$origins = $origins.set(g, { x: rect.x + (rect.width - content.width) / 2, y: rect.y + FlowLayout.group_padding + FlowLayout.header(plan, g) }) ?? []
		}
		origins = $origins
		frames = $frames
		node_level = |i|
			match (plan.diagram.nodes.get(i) ?? { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }).container {
				Root => root
				Group(g) => if (g < group_count) g else root
			}
		node_rects = plan.node_sizes.map_with_index(
			|size, i| {
				level = node_level(i)
				origin = origins.get(level) ?? { x: 0, y: 0 }
				local = level_solved(level).centers.get(plan.node_slots.get(i) ?? 0) ?? { x: 0, y: 0 }
				FlowLayout.center_rect({ x: origin.x + local.x, y: origin.y + local.y }, size)
			},
		)
		end_rect = |end|
			match end {
				Node(i) => node_rects.get(i) ?? { x: 0, y: 0, width: 0, height: 0 }
				Group(g) => frames.get(g) ?? { x: 0, y: 0, width: 0, height: 0 }
			}
		raw_edges = plan.roles.map_with_index(
			|role, e| {
				match role {
					Level(r) => {
						origin = origins.get(r.level) ?? { x: 0, y: 0 }
						move = |p| { x: p.x + origin.x, y: p.y + origin.y }
						route = (level_solved(r.level).routes.get(r.index) ?? []).map(move)
						# Inside subgraphs the edge runs through each one's port, then
						# jogs across the frame's padding to where the frame is crossed.
						port_route = |port|
							(level_solved(port.level).port_routes.get(port.index) ?? []).map(
								|p| {
									o = origins.get(port.level) ?? { x: 0, y: 0 }
									{ x: p.x + o.x, y: p.y + o.y }
								},
							)
						through = |ports, inward| {
							var $points = []
							for port in ports {
								next = if (inward) port_route(port).rev() else port_route(port)
								direction = FlowLayout.direction_of(plan, port.level)
								$points = if ($points.is_empty()) next else FlowLayout.splice($points, next, direction)
							}
							$points
						}
						direction = FlowLayout.direction_of(plan, r.level)
						with_start = if (r.from_ports.is_empty()) route else FlowLayout.splice(through(r.from_ports, False), route, direction)
						points = if (r.to_ports.is_empty()) with_start else FlowLayout.splice(with_start, through(r.to_ports.rev(), True), direction)
						label = match level_solved(r.level).labels.get(r.index) ?? None {
							Some(p) => Some(move(p))
							None => None
						}
						{ points: FlowLayoutLevel.simplify(points), label }
					}
					Loop(r) => {
						origin = origins.get(r.level) ?? { x: 0, y: 0 }
						move = |p| { x: p.x + origin.x, y: p.y + origin.y }
						{
							points: (level_solved(r.level).loop_routes.get(r.index) ?? []).map(move),
							label: match level_solved(r.level).loop_labels.get(r.index) ?? None {
								Some(p) => Some(move(p))
								None => None
							},
						}
					}
					Inside(r) => {
						inner = end_rect(r.inner)
						outer = frames.get(r.group) ?? { x: 0, y: 0, width: 0, height: 0 }
						cx = inner.x + inner.width / 2
						points = [{ x: cx, y: outer.y }, { x: cx, y: inner.y }]
						label = match plan.label_sizes.get(e) ?? None {
							Some(_) => Some({ x: cx, y: (outer.y + inner.y) / 2 })
							None => None
						}
						{ points: if (r.group_first) points else points.rev(), label }
					}
				}
			},
		)
		# Edges at a node whose outline is not its box run on from the box
		# to the outline, as Mermaid's do.
		edges = raw_edges.map_with_index(
			|geometry, e| {
				edge = plan.diagram.edges.get(e) ?? { id: "", from: Node(0), to: Node(0), label: "", line: Solid, start: None, end: None, length: 1, classes: [], styles: [] }
				shape_at = |end|
					match end {
						Node(i) =>
							match plan.diagram.nodes.get(i) {
								Ok(node) => Some({ shape: node.shape, rect: node_rects.get(i) ?? { x: 0, y: 0, width: 0, height: 0 } })
								Err(_) => None
							}
						Group(_) => None
					}
				started = match shape_at(edge.from) {
					Some(at) => FlowLayout.to_outline(geometry.points, at.shape, at.rect)
					None => geometry.points
				}
				points = match shape_at(edge.to) {
					Some(at) => FlowLayout.to_outline(started.rev(), at.shape, at.rect).rev()
					None => started
				}
				{ ..geometry, points }
			},
		)
		{ geometry: { nodes: node_rects, edges, groups: frames, bounds: { x: 0, y: 0, width: 0, height: 0 } }, origins }
	}

	## Continue `first`, which ends inside a frame, with `second`, which
	## starts on that frame, joining the two with a jog across the frame's
	## padding.
	splice : List(Point), List(Point), Direction -> List(Point)
	splice = |first, second, direction|
		match (first.last(), second.first()) {
			(Ok(a), Ok(b)) => first.drop_last(1).concat(FlowLayout.jog(a, b, direction)).concat(second.drop_first(1))
			_ => first.concat(second)
		}

	## Start a route on a node's outline: if its first point lies on the
	## node's box where the outline is further in, add the point where a
	## straight line in from there meets the outline.
	to_outline : List(Point), Flowchart.Shape, Rect -> List(Point)
	to_outline = |points, shape, rect|
		match points.first() {
			Err(_) => points
			Ok(port) => {
				near = |u, v| (u - v).abs() < 0.01
				w = rect.width / 2
				h = rect.height / 2
				cx = rect.x + w
				cy = rect.y + h
				vertical_side = near(port.y, rect.y) or near(port.y, rect.y + rect.height)
				horizontal_side = near(port.x, rect.x) or near(port.x, rect.x + rect.width)
				# How far in from the box the outline is at this port, never past
				# the middle.
				raw_depth = if w <= 0 or h <= 0 {
					0
				} else if vertical_side {
					across = ((port.x - cx).abs() / w).min(1)
					match shape {
						Diamond => h * across
						Circle | DoubleCircle | Ellipse => h * (1 - (1 - across * across).max(0).sqrt())
						Hexagon => {
							m = rect.height / 4
							inset = (w - m).max(0)
							if ((port.x - cx).abs() <= inset or m <= 0) 0 else h * (((port.x - cx).abs() - inset) / m).min(1)
						}
						_ => 0
					}
				} else if horizontal_side {
					along = ((port.y - cy).abs() / h).min(1)
					match shape {
						Diamond => w * along
						Circle | DoubleCircle | Ellipse => w * (1 - (1 - along * along).max(0).sqrt())
						Hexagon => (rect.height / 4).min(w) * along
						Stadium => h * (1 - (1 - along * along).max(0).sqrt())
						_ => 0
					}
				} else {
					0
				}
				depth = raw_depth.min(if (vertical_side) h else w)
				if depth < 0.5 {
					points
				} else if vertical_side {
					inward = if (near(port.y, rect.y)) depth else 0 - depth
					[{ x: port.x, y: port.y + inward }].concat(points)
				} else {
					inward = if (near(port.x, rect.x)) depth else 0 - depth
					[{ x: port.x + inward, y: port.y }].concat(points)
				}
			}
		}

	## Join two points with right angles: straight on, across halfway, and
	## straight on again, along the flow of `direction`.
	jog : Point, Point, Direction -> List(Point)
	jog = |a, b, direction| {
		near = |u, v| (u - v).abs() < 0.01
		if near(a.x, b.x) or near(a.y, b.y) {
			[a, b]
		} else {
			match direction {
				Down | Up => {
					mid = (a.y + b.y) / 2
					[a, { x: a.x, y: mid }, { x: b.x, y: mid }, b]
				}
				Right | Left => {
					mid = (a.x + b.x) / 2
					[a, { x: mid, y: a.y }, { x: mid, y: b.y }, b]
				}
			}
		}
	}

	## Move everything so content starts at Mermaid's origin, and set the
	## bounds Mermaid gives the drawing: the content plus a margin.
	normalise : FlowGeometry.Geometry, List([None, Some(Size)]) -> FlowGeometry.Geometry
	normalise = |geometry, label_sizes| {
		var $min_x = F64.infinity
		var $min_y = F64.infinity
		var $max_x = 0 - F64.infinity
		var $max_y = 0 - F64.infinity
		for r in geometry.nodes.concat(geometry.groups) {
			$min_x = $min_x.min(r.x)
			$min_y = $min_y.min(r.y)
			$max_x = $max_x.max(r.x + r.width)
			$max_y = $max_y.max(r.y + r.height)
		}
		for i in 0..<geometry.edges.len() {
			edge = geometry.edges.get(i) ?? { points: [], label: None }
			for p in edge.points {
				$min_x = $min_x.min(p.x)
				$min_y = $min_y.min(p.y)
				$max_x = $max_x.max(p.x)
				$max_y = $max_y.max(p.y)
			}
			match (edge.label, label_sizes.get(i) ?? None) {
				(Some(p), Some(size)) => {
					$min_x = $min_x.min(p.x - size.width / 2)
					$min_y = $min_y.min(p.y - size.height / 2)
					$max_x = $max_x.max(p.x + size.width / 2)
					$max_y = $max_y.max(p.y + size.height / 2)
				}
				_ => {}
			}
		}
		origin = FlowLayout.content_origin
		margin = FlowLayout.bounds_margin
		if !F64.is_finite($min_x) or !F64.is_finite($min_y) or !F64.is_finite($max_x) or !F64.is_finite($max_y) {
			{ ..geometry, bounds: { x: origin - margin, y: origin - margin, width: margin * 2, height: margin * 2 } }
		} else {
			dx = origin - $min_x
			dy = origin - $min_y
			fix = |v| if (F64.is_finite(v)) v else 0
			move = |p| { x: fix(p.x + dx), y: fix(p.y + dy) }
			move_rect = |r| { x: fix(r.x + dx), y: fix(r.y + dy), width: fix(r.width), height: fix(r.height) }
			{
				nodes: geometry.nodes.map(move_rect),
				groups: geometry.groups.map(move_rect),
				edges: geometry.edges.map(
					|edge| {
						points: edge.points.map(move),
						label: match edge.label {
							Some(p) => Some(move(p))
							None => None
						},
					},
				),
				bounds: { x: origin - margin, y: origin - margin, width: fix($max_x - $min_x + margin * 2), height: fix($max_y - $min_y + margin * 2) },
			}
		}
	}
}

## Lays out `text` with every node 152 by 41, labels 30 by 17 and titles
## 40 by 17, as Mermaid measures common short labels.
test_layout : Str -> [Some(FlowGeometry.Geometry), None]
test_layout = |text|
	match Flowchart.parse(text) {
		Ok(diagram) => {
			box = { width: 152, height: 41, label: { lines: [], width: 0, height: 0 } }
			block = { lines: [], width: 30, height: 17 }
			sizes = {
				nodes: List.repeat(box, diagram.nodes.len()),
				edge_labels: diagram.edges.map(|e| if (e.label.is_empty()) None else Some(block)),
				group_titles: List.repeat({ lines: [], width: 40, height: 17 }, diagram.groups.len()),
			}
			Some(FlowLayout.layout(diagram, sizes))
		}
		Err(_) => None
	}

## A chain reads down the page 40 apart, inside bounds with Mermaid's margin.
expect
	match test_layout("flowchart TD\n  A --> B --> C\n") {
		Some(g) =>
			g.nodes == [{ x: 12, y: 12, width: 152, height: 41 }, { x: 12, y: 93, width: 152, height: 41 }, { x: 12, y: 174, width: 152, height: 41 }]
				and g.bounds == { x: 4, y: 4, width: 168, height: 219 }
				and g.edges.map(|e| e.points) == [[{ x: 88, y: 53 }, { x: 88, y: 93 }], [{ x: 88, y: 134 }, { x: 88, y: 174 }]]
		None => False
	}

## An empty diagram has empty bounds at Mermaid's origin.
expect
	match test_layout("flowchart LR\n") {
		Some(g) => g.nodes == [] and g.bounds == { x: 4, y: 4, width: 16, height: 16 }
		None => False
	}

## Cycles, self-loops, parallel edges, edges to subgraphs and empty and
## nested subgraphs all lay out, aligned with the diagram.
expect {
	text = "flowchart LR\n  a --> a\n  a --> b --> a\n  a --> b\n  subgraph s [S]\n    subgraph t [T]\n      c\n    end\n    subgraph e [E]\n    end\n  end\n  b -->|x| s\n  s --> c\n  c --> e\n"
	match test_layout(text) {
		Some(g) => g.nodes.len() == 3 and g.groups.len() == 3 and g.edges.len() == 7 and g.edges.all(|e| e.points.len() >= 2)
		None => False
	}
}

## A label sits on its edge, which bends only at right angles.
expect
	match test_layout("flowchart TD\n  A -->|yes| B\n") {
		Some(g) =>
			match g.edges {
				[edge] => edge.label != None and edge.points.len() == 2
				_ => False
			}
		None => False
	}

## Layout is deterministic.
expect test_layout("flowchart TD\n  A --> B & C & D\n  B --> E\n  C --> E\n  E --> A\n") == test_layout("flowchart TD\n  A --> B & C & D\n  B --> E\n  C --> E\n  E --> A\n")
