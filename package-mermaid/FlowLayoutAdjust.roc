import Flowchart
import FlowGeometry
import FlowLayoutElk
import FlowLayoutGraph

## What Mermaid does to the layout engine's result before drawing it:
## subgraph frames are pulled in to their content, empty subgraphs and tiny
## nodes are centred on the edge that reaches them, edges are cut where
## they meet a node's outline, short jogs next to an edge's ends are
## straightened when that costs nothing, and the labels of two edges
## between the same nodes are pushed apart.
FlowLayoutAdjust :: {}.{

	Point : FlowGeometry.Point

	Rect : FlowGeometry.Rect

	Size : { width : F64, height : F64 }

	End : [Node(U64), Group(U64)]

	## Room left around a subgraph's content, and the margin a port keeps
	## from the corners of its side.
	padding : F64
	padding = 24

	ports_surrounding : F64
	ports_surrounding = 12

	## Space a subgraph's title needs beyond its text.
	title_padding : F64
	title_padding = 8

	## Terminal jogs: how long the first run may be, and how far across it
	## may step, for the jog to be straightened.
	terminal_run_max : F64
	terminal_run_max = 30

	terminal_jog_max : F64
	terminal_jog_max = 16

	jog_eps : F64
	jog_eps = 0.01

	opposite_label_gap : F64
	opposite_label_gap = 4

	no_rect : Rect
	no_rect = { x: 0, y: 0, width: 0, height: 0 }

	finite : F64 -> F64
	finite = |value| if (F64.is_finite(value) and value > 0) value else 0

	## Apply Mermaid's adjustments. The result is index-aligned with the
	## diagram, in the engine's coordinates.
	adjust : Flowchart.Diagram, FlowGeometry.Sizes, FlowLayoutElk.Raw -> { nodes : List(Rect), groups : List(Rect), edges : List({ points : List(Point), label : [None, Some(Point)] }) }
	adjust = |diagram, sizes, raw| {
		group_count = diagram.groups.len()
		titles = FlowLayoutAdjust.upto(group_count).map(
			|g| {
				block = sizes.group_titles.get(g) ?? { lines: [], width: 0, height: 0 }
				FlowLayoutAdjust.finite(block.width) + FlowLayoutAdjust.title_padding
			},
		)
		parents = diagram.groups.map(
			|group|
				match group.container {
					Group(p) => if (p < group_count) p else FlowLayoutAdjust.root
					Root => FlowLayoutAdjust.root
				},
		)
		node_parents = diagram.nodes.map(
			|node|
				match node.container {
					Group(p) => if (p < group_count) p else FlowLayoutAdjust.root
					Root => FlowLayoutAdjust.root
				},
		)
		ends = diagram.edges.map(|edge| (FlowLayoutAdjust.end_of(edge.from), FlowLayoutAdjust.end_of(edge.to)))
		frames = FlowLayoutAdjust.even_frames(raw, parents, node_parents, ends, titles)
		aligned = FlowLayoutAdjust.align_degenerate(raw.nodes, frames, raw.edges, ends, titles)
		nodes = aligned.nodes
		groups = aligned.groups
		# A subgraph is drawn at least as wide as its title, about its centre.
		# An empty one with several edges also reaches over every point where
		# they meet it: the engine spreads their ports over a box of no size,
		# and Mermaid would leave all but one edge ending in the air. (With
		# one edge the point is already on the box, as in Mermaid.)
		var $anchors = List.repeat([], groups.len())
		for e in 0..<raw.edges.len() {
			points = (raw.edges.get(e) ?? { points: [], label: None }).points
			(from, to) = ends.get(e) ?? (Node(0), Node(0))
			for pair in [{ end: from, anchor: points.first() }, { end: to, anchor: points.last() }] {
				match (pair.end, pair.anchor) {
					(Group(g), Ok(p)) =>
						if g < $anchors.len() {
							$anchors = $anchors.set(g, ($anchors.get(g) ?? []).append(p)) ?? []
						}
					_ => {}
				}
			}
		}
		anchors = $anchors
		drawn = groups.map_with_index(
			|r, g| {
				width = r.width.max(titles.get(g) ?? 0)
				box = { x: r.x + r.width / 2 - width / 2, y: r.y, width, height: r.height }
				points = anchors.get(g) ?? []
				if (r.width > 0 and r.height > 0) or points.len() < 2 {
					box
				} else {
					min_x = points.fold(box.x, |acc, p| acc.min(p.x))
					max_x = points.fold(box.x + box.width, |acc, p| acc.max(p.x))
					min_y = points.fold(box.y, |acc, p| acc.min(p.y))
					max_y = points.fold(box.y + box.height, |acc, p| acc.max(p.y))
					{ x: min_x, y: min_y, width: max_x - min_x, height: max_y - min_y }
				}
			},
		)
		bounds_of = |end|
			match end {
				Node(i) => nodes.get(i) ?? FlowLayoutAdjust.no_rect
				Group(g) => drawn.get(g) ?? FlowLayoutAdjust.no_rect
			}
		shape_of = |end|
			match end {
				Node(i) => Some((diagram.nodes.get(i) ?? { id: "", label: "", shape: Rectangle, container: Root, classes: [], styles: [] }).shape)
				Group(_) => None
			}
		clipped = raw.edges.map_with_index(
			|geometry, e| {
				(from, to) = ends.get(e) ?? (Node(0), Node(0))
				edge = diagram.edges.get(e)
				start_marker = match edge {
					Ok(d) => FlowLayoutAdjust.marker_offset(d.start)
					Err(_) => 0
				}
				end_marker = match edge {
					Ok(d) => FlowLayoutAdjust.marker_offset(d.end)
					Err(_) => 0
				}
				points = FlowLayoutAdjust.clip(geometry.points, { bounds: bounds_of(from), shape: shape_of(from) }, { bounds: bounds_of(to), shape: shape_of(to) })
				{
					points: FlowLayoutAdjust.shorten_start(FlowLayoutAdjust.shorten_end(points, bounds_of(to), end_marker), bounds_of(from), start_marker),
					label: geometry.label,
				}
			},
		)
		label_sizes = diagram.edges.map_with_index(
			|edge, e|
				match sizes.edge_labels.get(e) ?? None {
					Some(block) =>
						if edge.label != "" and FlowLayoutAdjust.finite(block.width) > 0 and FlowLayoutAdjust.finite(block.height) > 0 {
							# The label box Mermaid measures: its text and two pixels around it.
							Some({ width: FlowLayoutAdjust.finite(block.width) + 4, height: FlowLayoutAdjust.finite(block.height) + 4 })
						} else {
							None
						}
					None => None
				},
		)
		straightened = FlowLayoutAdjust.straighten(clipped, label_sizes)
		separated = FlowLayoutAdjust.separate_labels(straightened, ends, label_sizes)
		{ nodes, groups: drawn, edges: separated }
	}

	root : U64
	root = 18446744073709551615

	end_of : Flowchart.Endpoint -> End
	end_of = |end|
		match end {
			Node(i) => Node(i)
			Group(g) => Group(g)
		}

	upto : U64 -> List(U64)
	upto = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## The groups an end sits in, innermost first; a group is not in its own
	## list.
	ancestors : End, List(U64), List(U64) -> List(U64)
	ancestors = |end, parents, node_parents| {
		start = match end {
			Node(i) => node_parents.get(i) ?? FlowLayoutAdjust.root
			Group(g) => parents.get(g) ?? FlowLayoutAdjust.root
		}
		var $out = []
		var $at = start
		var $guard = 0
		while $at != FlowLayoutAdjust.root and $guard <= parents.len() {
			$out = $out.append($at)
			$at = parents.get($at) ?? FlowLayoutAdjust.root
			$guard = $guard + 1
		}
		$out
	}

	## Pull each subgraph's frame in to its content: its members, the routes
	## of edges inside it, and where edges meet it, plus padding; never past
	## the engine's frame, never above its top, and at least as wide as its
	## title. Inner subgraphs first.
	even_frames : FlowLayoutElk.Raw, List(U64), List(U64), List((End, End)), List(F64) -> List(Rect)
	even_frames = |raw, parents, node_parents, ends, titles| {
		group_count = parents.len()
		depth = |g| FlowLayoutAdjust.ancestors(Group(g), parents, node_parents).len()
		# Deepest first; the merge sort keeps declaration order among equals.
		depths = FlowLayoutAdjust.upto(group_count).map(depth)
		order = FlowLayoutGraph.sort_by(FlowLayoutAdjust.upto(group_count), |a, b| (depths.get(b) ?? 0).to_i64_wrap() - (depths.get(a) ?? 0).to_i64_wrap())
		end_chains = ends.map(|(from, to)| (FlowLayoutAdjust.ancestors(from, parents, node_parents), FlowLayoutAdjust.ancestors(to, parents, node_parents)))
		var $frames = raw.groups
		for g in order {
			frame = $frames.get(g) ?? FlowLayoutAdjust.no_rect
			var $boxes = []
			for i in 0..<node_parents.len() {
				if (node_parents.get(i) ?? FlowLayoutAdjust.root) == g {
					r = raw.nodes.get(i) ?? FlowLayoutAdjust.no_rect
					if r.width != 0 and r.height != 0 {
						$boxes = $boxes.append(r)
					}
				}
			}
			for c in 0..<group_count {
				if (parents.get(c) ?? FlowLayoutAdjust.root) == g {
					r = $frames.get(c) ?? FlowLayoutAdjust.no_rect
					if r.width != 0 and r.height != 0 {
						$boxes = $boxes.append(r)
					}
				}
			}
			if !$boxes.is_empty() {
				var $min_x = F64.infinity
				var $max_x = 0 - F64.infinity
				var $max_y = 0 - F64.infinity
				for r in $boxes {
					$min_x = $min_x.min(r.x)
					$max_x = $max_x.max(r.x + r.width)
					$max_y = $max_y.max(r.y + r.height)
				}
				for e in 0..<ends.len() {
					(from, to) = ends.get(e) ?? (Node(0), Node(0))
					(from_chain, to_chain) = end_chains.get(e) ?? ([], [])
					points = (raw.edges.get(e) ?? { points: [], label: None }).points
					inside = from_chain.contains(g) and to_chain.contains(g)
					lane = if inside {
						points
					} else {
						starts = if (from == Group(g)) points.take_first(1) else []
						stops = if (to == Group(g)) points.take_last(1) else []
						starts.concat(stops)
					}
					for p in lane {
						$min_x = $min_x.min(p.x)
						$max_x = $max_x.max(p.x)
						$max_y = $max_y.max(p.y)
					}
				}
				left = frame.x.max($min_x - FlowLayoutAdjust.padding)
				right = (frame.x + frame.width).min($max_x + FlowLayoutAdjust.padding)
				bottom = (frame.y + frame.height).min($max_y + FlowLayoutAdjust.padding)
				floor = titles.get(g) ?? 0
				width0 = right - left
				(x, width) = if width0 < floor {
					shifted = left - (floor - width0) / 2
					(frame.x.max(shifted.min(frame.x + frame.width - floor)), floor.min(frame.width))
				} else {
					(left, width0)
				}
				height = bottom - frame.y
				if height > 0 and width > 0 and F64.is_finite(x) and F64.is_finite(width) and F64.is_finite(height) and g < $frames.len() {
					$frames = $frames.set(g, { x, y: frame.y, width, height }) ?? []
				}
			}
		}
		$frames
	}

	## Centre a node or subgraph that is too small for a port's margins on
	## the point where its first edge meets it.
	##
	## A move that would leave another of its edges off its outline is not
	## made; that only happens for boxes too small for their ports.
	align_degenerate : List(Rect), List(Rect), List({ points : List(Point), label : [None, Some(Point)] }), List((End, End)), List(F64) -> { nodes : List(Rect), groups : List(Rect) }
	align_degenerate = |nodes0, groups0, edges, ends, titles| {
		# Where each node's and subgraph's edges meet it.
		var $node_anchors = List.repeat([], nodes0.len())
		var $group_anchors = List.repeat([], groups0.len())
		for e in 0..<edges.len() {
			points = (edges.get(e) ?? { points: [], label: None }).points
			(from, to) = ends.get(e) ?? (Node(0), Node(0))
			for pair in [{ end: from, anchor: points.first() }, { end: to, anchor: points.last() }] {
				match pair.anchor {
					Ok(p) =>
						match pair.end {
							Node(i) =>
								if i < $node_anchors.len() {
									$node_anchors = $node_anchors.set(i, ($node_anchors.get(i) ?? []).append(p)) ?? []
								}
							Group(g) =>
								if g < $group_anchors.len() {
									$group_anchors = $group_anchors.set(g, ($group_anchors.get(g) ?? []).append(p)) ?? []
								}
						}
					Err(_) => {}
				}
			}
		}
		node_anchors = $node_anchors
		group_anchors = $group_anchors
		var $nodes = nodes0
		var $groups = groups0
		var $done_nodes = List.repeat(False, nodes0.len())
		var $done_groups = List.repeat(False, groups0.len())
		for e in 0..<edges.len() {
			points = (edges.get(e) ?? { points: [], label: None }).points
			(from, to) = ends.get(e) ?? (Node(0), Node(0))
			for pair in [{ end: from, anchor: points.first() }, { end: to, anchor: points.last() }] {
				end = pair.end
				match pair.anchor {
					Ok(p) => {
						(r, done) = match end {
							Node(i) => ($nodes.get(i) ?? FlowLayoutAdjust.no_rect, $done_nodes.get(i) ?? True)
							Group(g) => ($groups.get(g) ?? FlowLayoutAdjust.no_rect, $done_groups.get(g) ?? True)
						}
						along_width = (p.y - r.y).abs() <= 0.5 or (p.y - (r.y + r.height)).abs() <= 0.5
						small = (if (along_width) r.width else r.height) < 2 * FlowLayoutAdjust.ports_surrounding
						if small and !done {
							delta = if (along_width) p.x - (r.x + r.width / 2) else p.y - (r.y + r.height / 2)
							moved0 = if (delta.abs() < 0.01) r else if (along_width) { ..r, x: r.x + delta } else { ..r, y: r.y + delta }
							(drawn, anchors) = match end {
								Node(i) => (moved0, node_anchors.get(i) ?? [])
								Group(g) => {
									width = moved0.width.max(titles.get(g) ?? 0)
									({ ..moved0, x: moved0.x + moved0.width / 2 - width / 2, width }, group_anchors.get(g) ?? [])
								}
							}
							moved = if (anchors.all(|a| FlowLayoutAdjust.on_border(drawn, a, 0.01))) moved0 else r
							match end {
								Node(i) => {
									$done_nodes = $done_nodes.set(i, True) ?? []
									$nodes = $nodes.set(i, moved) ?? []
								}
								Group(g) => {
									$done_groups = $done_groups.set(g, True) ?? []
									$groups = $groups.set(g, moved) ?? []
								}
							}
						}
					}
					Err(_) => {}
				}
			}
		}
		{ nodes: $nodes, groups: $groups }
	}

	# ---------------------------------------------------------------- clipping

	Terminal : { bounds : Rect, shape : [None, Some(Flowchart.Shape)] }

	centre : Rect -> Point
	centre = |r| { x: r.x + r.width / 2, y: r.y + r.height / 2 }

	on_border : Rect, Point, F64 -> Bool
	on_border = |r, p, tol| {
		left = r.x
		right = r.x + r.width
		top = r.y
		bottom = r.y + r.height
		within_y = p.y >= top - tol and p.y <= bottom + tol
		within_x = p.x >= left - tol and p.x <= right + tol
		((p.x - left).abs() <= tol and within_y) or ((p.x - right).abs() <= tol and within_y) or ((p.y - top).abs() <= tol and within_x) or ((p.y - bottom).abs() <= tol and within_x)
	}

	outside : Rect, Point -> Bool
	outside = |r, p| {
		c = FlowLayoutAdjust.centre(r)
		# Points on the box count as outside, with room for rounding.
		(p.x - c.x).abs() >= r.width / 2 - 0.000001 or (p.y - c.y).abs() >= r.height / 2 - 0.000001
	}

	## Cut an edge's route where it meets the outlines at its ends. `points`
	## runs from port to port on the engine's boxes.
	clip : List(Point), FlowLayoutAdjust.Terminal, FlowLayoutAdjust.Terminal -> List(Point)
	clip = |route, start, stop| {
		if route.is_empty() {
			FlowLayoutAdjust.dedupe([FlowLayoutAdjust.centre(start.bounds), FlowLayoutAdjust.centre(stop.bounds)])
		} else {
			start_group = start.shape == None
			stop_group = stop.shape == None
			first = route.first() ?? { x: 0, y: 0 }
			last = route.last() ?? { x: 0, y: 0 }
			# A port already on a subgraph's frame is where the edge ends.
			skip_start0 = start_group and FlowLayoutAdjust.on_border(start.bounds, first, 0.5)
			skip_stop0 = stop_group and FlowLayoutAdjust.on_border(stop.bounds, last, 0.5)
			with_start = if (skip_start0) route else [FlowLayoutAdjust.centre(start.bounds)].concat(route)
			with_both = if (skip_stop0) with_start else with_start.append(FlowLayoutAdjust.centre(stop.bounds))
			(after_start, skip_start) = if start_group and !skip_start0 {
				FlowLayoutAdjust.clip_group(with_both, start.bounds)
			} else {
				(with_both, skip_start0)
			}
			(after_stop, skip_stop) = if stop_group and !skip_stop0 {
				reversed = FlowLayoutAdjust.clip_group(after_start.rev(), stop.bounds)
				(reversed.0.rev(), reversed.1)
			} else {
				(after_start, skip_stop0)
			}
			result = if skip_start or skip_stop {
				s = if (skip_start) after_stop else FlowLayoutAdjust.attach_start(after_stop, start)
				if (skip_stop) s else FlowLayoutAdjust.attach_start(s.rev(), stop).rev()
			} else {
				s = FlowLayoutAdjust.attach_start(after_stop, start)
				e = FlowLayoutAdjust.attach_start(s.rev(), stop).rev()
				# A last step under two pixels is dropped.
				n = e.len()
				if n > 1 {
					a = e.get(n - 2) ?? { x: 0, y: 0 }
					b = e.get(n - 1) ?? { x: 0, y: 0 }
					if (((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).sqrt() < 2) e.drop_last(1) else e
				} else {
					e
				}
			}
			FlowLayoutAdjust.dedupe(result)
		}
	}

	## Cut a route that starts at a subgraph's centre where it leaves the
	## frame; false when the route never leaves it, or starts outside.
	clip_group : List(Point), Rect -> (List(Point), Bool)
	clip_group = |points, bounds| {
		var $index = 0
		var $going = True
		while $going and $index < points.len() {
			if FlowLayoutAdjust.outside(bounds, points.get($index) ?? { x: 0, y: 0 }) {
				$going = False
			} else {
				$index = $index + 1
			}
		}
		if $index == 0 or $index >= points.len() {
			(points, False)
		} else {
			out = points.get($index) ?? { x: 0, y: 0 }
			inside = points.get($index - 1) ?? { x: 0, y: 0 }
			c = FlowLayoutAdjust.centre(bounds)
			dx = out.x - inside.x
			dy = out.y - inside.y
			sign = |v| if (v > 0) 1.0 else if (v < 0) -1.0 else 0.0
			tx = if (dx == 0) F64.infinity else (c.x + sign(dx) * bounds.width / 2 - inside.x) / dx
			ty = if (dy == 0) F64.infinity else (c.y + sign(dy) * bounds.height / 2 - inside.y) / dy
			t = tx.min(ty)
			crossing = if (F64.is_finite(t)) { x: inside.x + t * dx, y: inside.y + t * dy } else inside
			([crossing].concat(points.drop_first($index)), True)
		}
	}

	## Replace a route's first point, the centre of its start, with where the
	## route crosses the start's outline: along the direction the route
	## leaves its port when that is straight, else on the line from the
	## centre.
	attach_start : List(Point), FlowLayoutAdjust.Terminal -> List(Point)
	attach_start = |points, terminal| {
		bounds = terminal.bounds
		var $index = 0
		var $going = True
		while $going and $index < points.len() {
			if FlowLayoutAdjust.outside(bounds, points.get($index) ?? { x: 0, y: 0 }) {
				$going = False
			} else {
				$index = $index + 1
			}
		}
		if $index >= points.len() or points.is_empty() {
			points
		} else {
			port = points.get($index) ?? { x: 0, y: 0 }
			attach = match terminal.shape {
				Some(shape) =>
					match points.get($index + 1) {
						Ok(next) => if ($index == 1) FlowLayoutAdjust.outline_point(port, next, shape, bounds) else FlowLayoutAdjust.ray_point(bounds, port)
						Err(_) => FlowLayoutAdjust.ray_point(bounds, port)
					}
				None => FlowLayoutAdjust.ray_point(bounds, port)
			}
			first = points.first() ?? attach
			if (first.x - attach.x).abs() < 0.1 and (first.y - attach.y).abs() < 0.1 {
				points.drop_first(1)
			} else {
				[attach].concat(points.drop_first(1))
			}
		}
	}

	## Where the line from a box's centre to a point outside it crosses the
	## box.
	ray_point : Rect, Point -> Point
	ray_point = |r, p| {
		c = FlowLayoutAdjust.centre(r)
		dx = p.x - c.x
		dy = p.y - c.y
		w = r.width / 2
		h = r.height / 2
		tx = if (dx == 0) F64.infinity else w / dx.abs()
		ty = if (dy == 0) F64.infinity else h / dy.abs()
		t = tx.min(ty).min(1)
		if (F64.is_finite(t)) { x: c.x + t * dx, y: c.y + t * dy } else p
	}

	## Where a port on a node's box meets the node's outline, moving along
	## the direction its route leaves (inwards from the box).
	outline_point : Point, Point, Flowchart.Shape, Rect -> Point
	outline_point = |port, next, shape, rect| {
		dx = next.x - port.x
		dy = next.y - port.y
		straight = dx.abs() <= 0.000001 or dy.abs() <= 0.000001
		if !straight or (dx == 0 and dy == 0) {
			FlowLayoutAdjust.ray_point(rect, port)
		} else {
			w = rect.width / 2
			h = rect.height / 2
			cx = rect.x + w
			cy = rect.y + h
			horizontal = dx.abs() > dy.abs()
			raw_depth = if w <= 0 or h <= 0 {
				0
			} else if !horizontal {
				across = ((port.x - cx).abs() / w).min(1)
				match shape {
					Diamond => h * across
					Circle | DoubleCircle | Ellipse => h * (1 - (1 - across * across).max(0).sqrt())
					Hexagon => {
						m = rect.height / 4
						inset = (w - m).max(0)
						if ((port.x - cx).abs() <= inset or m <= 0) 0 else h * (((port.x - cx).abs() - inset) / m).min(1)
					}
					Cylinder => FlowLayoutAdjust.cylinder_depth((port.x - cx).abs(), rect.width, rect.height)
					_ => 0
				}
			} else {
				along = ((port.y - cy).abs() / h).min(1)
				# How far down the side the port is, from 0 at the top to 1 at the
				# bottom, for the slanted sides.
				t = ((port.y - rect.y) / rect.height).max(0).min(1)
				west = port.x < cx
				slant = rect.height / 2
				match shape {
					Diamond => w * along
					Circle | DoubleCircle | Ellipse => w * (1 - (1 - along * along).max(0).sqrt())
					Hexagon => (rect.height / 4).min(w) * along
					Stadium => h * (1 - (1 - along * along).max(0).sqrt())
					LeanRight => slant * (if (west) 1 - t else t)
					LeanLeft => slant * (if (west) t else 1 - t)
					Trapezoid => slant * (1 - t)
					InverseTrapezoid => slant * t
					Asymmetric => if (west) (rect.height / 4) * (1 - along) else 0
					_ => 0
				}
			}
			if horizontal {
				depth = raw_depth.min(w).min((port.x - cx).abs())
				inward = if (port.x < cx) depth else 0 - depth
				{ x: port.x + inward, y: port.y }
			} else {
				depth = raw_depth.min(h).min((port.y - cy).abs())
				inward = if (port.y < cy) depth else 0 - depth
				{ x: port.x, y: port.y + inward }
			}
		}
	}

	## How far inside its box a cylinder's cap is met, by a route leaving
	## straight up or down at `dx` from the middle. Mermaid finds the point by
	## halving: a point counts as inside when it is no farther from the centre
	## than where the ray through it meets the outline, which Mermaid takes
	## as the box's crossing lowered by the cap's ellipse at that crossing.
	cylinder_depth : F64, F64, F64 -> F64
	cylinder_depth = |dx, width, height| {
		rx = width / 2
		ry = rx / (2.5 + width / 50)
		hh = height / 2
		if rx <= 0 or hh <= 0 or dx >= rx {
			0
		} else {
			inside = |t| {
				# The probe (dx, -t); where the ray from the centre through it
				# leaves the box, then the cap correction there.
				(sx, sy) = if t * rx > dx * hh {
					(hh * dx / t, 0 - hh)
				} else {
					(rx, 0 - rx * t / dx)
				}
				cap = if sx.abs() < rx {
					e = ry * ry * (1 - sx * sx / (rx * rx))
					ry - (if (e > 0) e.sqrt() else e)
				} else {
					0
				}
				cross_y = sy + cap
				(dx * dx + t * t).sqrt() <= (sx * sx + cross_y * cross_y).sqrt() + 0.000000001
			}
			var $inner = 0.0
			var $outer = hh
			if inside(hh) {
				0
			} else {
				for _ in 0..<20 {
					mid = ($inner + $outer) / 2
					if inside(mid) {
						$inner = mid
					} else {
						$outer = mid
					}
				}
				hh - $inner
			}
		}
	}

	dedupe : List(Point) -> List(Point)
	dedupe = |points|
		points.fold(
			[],
			|acc, p|
				match acc.last() {
					Ok(q) => if ((p.x - q.x).abs() > 0.000001 or (p.y - q.y).abs() > 0.000001) acc.append(p) else acc
					Err(_) => acc.append(p)
				},
		)

	## How far an end marker reaches back along its edge.
	marker_offset : Flowchart.Arrowhead -> F64
	marker_offset = |head|
		match head {
			None => 0
			Arrow => 4
			Circle => 12.5
			Cross => 12.5
		}

	min_marker_segment : F64
	min_marker_segment = 8

	## Drop the point before a marked end when the last step is too short to
	## hold the marker and that point sits on the end's frame.
	shorten_end : List(Point), Rect, F64 -> List(Point)
	shorten_end = |points, bounds, offset| {
		n = points.len()
		if offset <= 0 or n < 3 {
			points
		} else {
			end = points.get(n - 1) ?? { x: 0, y: 0 }
			entry = points.get(n - 2) ?? { x: 0, y: 0 }
			length = ((end.x - entry.x) * (end.x - entry.x) + (end.y - entry.y) * (end.y - entry.y)).sqrt()
			if length >= FlowLayoutAdjust.min_marker_segment.max(offset * 2) or !FlowLayoutAdjust.on_border(bounds, entry, 1) {
				points
			} else {
				points.drop_last(2).append(end)
			}
		}
	}

	shorten_start : List(Point), Rect, F64 -> List(Point)
	shorten_start = |points, bounds, offset| FlowLayoutAdjust.shorten_end(points.rev(), bounds, offset).rev()

	# ---------------------------------------------------------------- straightening

	Axis : [H, V, Neither]

	axis_of : Point, Point -> FlowLayoutAdjust.Axis
	axis_of = |a, b| {
		dx = (b.x - a.x).abs()
		dy = (b.y - a.y).abs()
		if dx > FlowLayoutAdjust.jog_eps and dy <= FlowLayoutAdjust.jog_eps {
			H
		} else if dy > FlowLayoutAdjust.jog_eps and dx <= FlowLayoutAdjust.jog_eps {
			V
		} else {
			Neither
		}
	}

	Run : { old_a : Point, old_b : Point, new_a : Point, new_b : Point }

	sign : F64 -> F64
	sign = |v| if (v > 0) 1 else if (v < 0) -1 else 0

	## Straighten a short jog right after a route's start: the first run is
	## short, the jog small, and the route carries on the same way.
	straighten_front : List(Point) -> [None, Some((List(Point), FlowLayoutAdjust.Run))]
	straighten_front = |pts| {
		if pts.len() < 5 {
			None
		} else {
			p0 = pts.get(0) ?? { x: 0, y: 0 }
			p1 = pts.get(1) ?? { x: 0, y: 0 }
			p2 = pts.get(2) ?? { x: 0, y: 0 }
			p3 = pts.get(3) ?? { x: 0, y: 0 }
			axis = FlowLayoutAdjust.axis_of(p0, p1)
			across = if (axis == H) V else H
			jog = if (axis == H) (p2.y - p1.y).abs() else (p2.x - p1.x).abs()
			forward = if (axis == H) FlowLayoutAdjust.sign(p1.x - p0.x) == FlowLayoutAdjust.sign(p3.x - p2.x) else FlowLayoutAdjust.sign(p1.y - p0.y) == FlowLayoutAdjust.sign(p3.y - p2.y)
			run_length = ((p1.x - p0.x) * (p1.x - p0.x) + (p1.y - p0.y) * (p1.y - p0.y)).sqrt()
			if axis == Neither or FlowLayoutAdjust.axis_of(p2, p3) != axis or FlowLayoutAdjust.axis_of(p1, p2) != across or run_length > FlowLayoutAdjust.terminal_run_max or jog < FlowLayoutAdjust.jog_eps or jog > FlowLayoutAdjust.terminal_jog_max or !forward {
				None
			} else {
				var $last = 3
				while $last + 1 < pts.len() and FlowLayoutAdjust.axis_of(pts.get($last) ?? p0, pts.get($last + 1) ?? p0) == axis {
					$last = $last + 1
				}
				if $last == pts.len() - 1 {
					None
				} else {
					last = $last
					moved = pts.map_with_index(
						|p, i|
							if i >= 2 and i <= last {
								if (axis == H) { x: p.x, y: p0.y } else { x: p0.x, y: p.y }
							} else {
								p
							},
					)
					run = { old_a: p2, old_b: pts.get(last) ?? p2, new_a: moved.get(2) ?? p2, new_b: moved.get(last) ?? p2 }
					Some(([p0].concat(moved.drop_first(3)), run))
				}
			}
		}
	}

	straighten_route : List(Point) -> { points : List(Point), runs : List(FlowLayoutAdjust.Run), changed : Bool }
	straighten_route = |points| {
		(front, runs1) = match FlowLayoutAdjust.straighten_front(points) {
			Some((p, run)) => (p, [run])
			None => (points, [])
		}
		match FlowLayoutAdjust.straighten_front(front.rev()) {
			Some((p, run)) => { points: p.rev(), runs: runs1.append(run), changed: True }
			None => { points: front, runs: runs1, changed: !runs1.is_empty() }
		}
	}

	cross_strict : Point, Point, Point, Point -> Bool
	cross_strict = |a1, a2, b1, b2| {
		side = |o, p, q| (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x)
		d1 = side(b1, b2, a1)
		d2 = side(b1, b2, a2)
		d3 = side(a1, a2, b1)
		d4 = side(a1, a2, b2)
		((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
	}

	crossings : List(Point), List(Point) -> U64
	crossings = |a, b| {
		var $n = 0
		for i in 0..<(a.len().max(1) - 1) {
			for j in 0..<(b.len().max(1) - 1) {
				if FlowLayoutAdjust.cross_strict(a.get(i) ?? { x: 0, y: 0 }, a.get(i + 1) ?? { x: 0, y: 0 }, b.get(j) ?? { x: 0, y: 0 }, b.get(j + 1) ?? { x: 0, y: 0 }) {
					$n = $n + 1
				}
			}
		}
		$n
	}

	Box : { x1 : F64, y1 : F64, x2 : F64, y2 : F64 }

	segment_hits_box : Point, Point, { x1 : F64, y1 : F64, x2 : F64, y2 : F64 } -> Bool
	segment_hits_box = |a, b, box| {
		dx = b.x - a.x
		dy = b.y - a.y
		var $t0 = 0.0.F64
		var $t1 = 1.0
		var $miss = False
		for (p, q) in [(0 - dx, a.x - box.x1), (dx, box.x2 - a.x), (0 - dy, a.y - box.y1), (dy, box.y2 - a.y)] {
			if p == 0 {
				if q < 0 {
					$miss = True
				}
			} else if p < 0 {
				$t0 = $t0.max(q / p)
			} else {
				$t1 = $t1.min(q / p)
			}
		}
		!$miss and $t0 < $t1
	}

	covers : List(Point), [None, Some({ centre : Point, size : Size })] -> Bool
	covers = |route, label|
		match label {
			None => False
			Some(l) => {
				box = { x1: l.centre.x - l.size.width / 2, y1: l.centre.y - l.size.height / 2, x2: l.centre.x + l.size.width / 2, y2: l.centre.y + l.size.height / 2 }
				FlowLayoutAdjust.upto(route.len().max(1) - 1).any(|i| FlowLayoutAdjust.segment_hits_box(route.get(i) ?? { x: 0, y: 0 }, route.get(i + 1) ?? { x: 0, y: 0 }, box))
			}
		}

	## Where a label on a straightened run goes: the same fraction along the
	## nearest moved run.
	project : Point, List(FlowLayoutAdjust.Run) -> [None, Some(Point)]
	project = |label, runs| {
		param = |p, a, b| {
			abx = b.x - a.x
			aby = b.y - a.y
			len_sq = abx * abx + aby * aby
			if (len_sq == 0) 0 else (((p.x - a.x) * abx + (p.y - a.y) * aby) / len_sq).max(0).min(1)
		}
		at = |a, b, t| { x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) }
		best = runs.fold(
			None,
			|acc, run| {
				t = param(label, run.old_a, run.old_b)
				old = at(run.old_a, run.old_b, t)
				dist = (old.x - label.x) * (old.x - label.x) + (old.y - label.y) * (old.y - label.y)
				match acc {
					Some((d, _)) => if (d <= dist) acc else Some((dist, at(run.new_a, run.new_b, t)))
					None => Some((dist, at(run.new_a, run.new_b, t)))
				}
			},
		)
		match best {
			Some((_, p)) => Some(p)
			None => None
		}
	}

	## Straighten terminal jogs, edge by edge in order, when that adds no
	## crossing and covers no more labels.
	straighten : List({ points : List(Point), label : [None, Some(Point)] }), List([None, Some(Size)]) -> List({ points : List(Point), label : [None, Some(Point)] })
	straighten = |edges0, sizes| {
		label_of = |edge, e|
			match (edge.label, sizes.get(e) ?? None) {
				(Some(c), Some(size)) => Some({ centre: c, size })
				_ => None
			}
		var $edges = edges0
		for e in 0..<edges0.len() {
			edge = $edges.get(e) ?? { points: [], label: None }
			original = edge.points
			if original.len() >= 5 {
				s = FlowLayoutAdjust.straighten_route(original)
				if s.changed {
					label = label_of(edge, e)
					moved = match edge.label {
						Some(c) => FlowLayoutAdjust.project(c, s.runs)
						None => None
					}
					candidate_label = match (label, moved) {
						(Some(l), Some(m)) => Some({ ..l, centre: m })
						_ => label
					}
					var $before = 0
					var $after = 0
					var $covered_before = 0
					var $covered_after = 0
					for other in 0..<$edges.len() {
						o = $edges.get(other) ?? { points: [], label: None }
						if other != e and o.points.len() >= 2 {
							$before = $before + FlowLayoutAdjust.crossings(original, o.points)
							$after = $after + FlowLayoutAdjust.crossings(s.points, o.points)
							other_label = label_of(o, other)
							count = |b| if (b) 1 else 0
							$covered_before = $covered_before + count(FlowLayoutAdjust.covers(o.points, label)) + count(FlowLayoutAdjust.covers(original, other_label))
							$covered_after = $covered_after + count(FlowLayoutAdjust.covers(o.points, candidate_label)) + count(FlowLayoutAdjust.covers(s.points, other_label))
						}
					}
					if $after <= $before and $covered_after <= $covered_before {
						new_label = match moved {
							Some(m) => Some(m)
							None => edge.label
						}
						$edges = $edges.set(e, { points: s.points, label: new_label }) ?? []
					}
				}
			}
		}
		$edges
	}

	## Push apart the labels of exactly two labelled edges between the same
	## pair of ends when they sit side by side and overlap.
	separate_labels : List({ points : List(Point), label : [None, Some(Point)] }), List((End, End)), List([None, Some(Size)]) -> List({ points : List(Point), label : [None, Some(Point)] })
	separate_labels = |edges0, ends, sizes| {
		key = |e| {
			(a, b) = ends.get(e) ?? (Node(0), Node(0))
			code = |end|
				match end {
					Node(i) => i * 2
					Group(g) => g * 2 + 1
				}
			(code(a).min(code(b)), code(a).max(code(b)))
		}
		labelled = FlowLayoutAdjust.upto(edges0.len()).keep_if(
			|e|
				match ((edges0.get(e) ?? { points: [], label: None }).label, sizes.get(e) ?? None) {
					(Some(_), Some(_)) => True
					_ => False
				},
		)
		var $edges = edges0
		for e in labelled {
			k = key(e)
			bucket = labelled.keep_if(|f| key(f) == k)
			if bucket.len() == 2 and (bucket.first() ?? e) == e {
				f = bucket.get(1) ?? e
				ea = $edges.get(e) ?? { points: [], label: None }
				eb = $edges.get(f) ?? { points: [], label: None }
				sa = (sizes.get(e) ?? None)
				sb = (sizes.get(f) ?? None)
				match (ea.label, eb.label, sa, sb) {
					(Some(a), Some(b), Some(za), Some(zb)) =>
						if (a.y - b.y).abs() <= za.height.max(zb.height) {
							required = za.width / 2 + zb.width / 2 + FlowLayoutAdjust.opposite_label_gap
							current = b.x - a.x
							deficit = required - current.abs()
							if deficit > 0 {
								s = if (current > 0) 1.0 else if (current < 0) -1.0 else 1.0
								$edges = $edges.set(e, { ..ea, label: Some({ x: a.x - s * deficit / 2, y: a.y }) }) ?? []
								$edges = $edges.set(f, { ..eb, label: Some({ x: b.x + s * deficit / 2, y: b.y }) }) ?? []
							}
						}
					_ => {}
				}
			}
		}
		$edges
	}
}

## An edge into the flat top of a cylinder ends at its port.
expect {
	route = [{ x: 557, y: 1878 }, { x: 557, y: 1898 }, { x: 381, y: 1898 }, { x: 381, y: 1938 }]
	start = { bounds: { x: 480, y: 1837, width: 154, height: 41 }, shape: Some(Rectangle) }
	stop = { bounds: { x: 288, y: 1938, width: 144, height: 81 }, shape: Some(Cylinder) }
	clipped = FlowLayoutAdjust.clip(route, start, stop)
	clipped == route
}

## A cylinder's cap is met a little inside its box, more towards its sides.
## Recorded: Mermaid starts edges from a 144 by 81.15 cylinder 1.051 inside
## the box 36.72 from its middle, and 0.180 inside 12.24 from it.
expect {
	near = |a, b| (a - b).abs() < 0.005
	near(FlowLayoutAdjust.cylinder_depth(36.72, 144, 81.14869689941406), 1.0508)
		and near(FlowLayoutAdjust.cylinder_depth(12.24, 144, 81.14869689941406), 0.18)
		and FlowLayoutAdjust.cylinder_depth(0, 144, 81.14869689941406) == 0
}

## Slanted sides are met inside the box. Recorded (Mermaid, nodes 32 or 47
## high): an edge leaves a lean-right node 8 inside its right side, enters
## a lean-left node 8 inside its left side, leaves an inverse trapezoid
## 11.75 inside, and enters a flag 10.25 inside its notched side.
expect {
	near = |p, q| (p.x - q.x).abs() < 0.001 and (p.y - q.y).abs() < 0.001
	lean_right = { x: 279, y: 297, width: 182, height: 32 }
	lean_left = { x: 501, y: 297, width: 182, height: 32 }
	inverse = { x: 12, y: 417.73834228515625, width: 227, height: 47 }
	flag = { x: 505.875, y: 153, width: 172.25, height: 41 }
	near(FlowLayoutAdjust.outline_point({ x: 461, y: 313 }, { x: 501, y: 313 }, LeanRight, lean_right), { x: 453, y: 313 })
		and near(FlowLayoutAdjust.outline_point({ x: 501, y: 313 }, { x: 461, y: 313 }, LeanLeft, lean_left), { x: 509, y: 313 })
		and near(FlowLayoutAdjust.outline_point({ x: 239, y: 441.23834228515625 }, { x: 279, y: 441.23834228515625 }, InverseTrapezoid, inverse), { x: 227.25, y: 441.23834228515625 })
		and near(FlowLayoutAdjust.outline_point({ x: 505.875, y: 173.5 }, { x: 406.9, y: 173.5 }, Asymmetric, flag), { x: 516.125, y: 173.5 })
}

## A box too small for its ports' margins is centred where its first edge
## meets it, unless that would strand another edge. Recorded: Mermaid
## moves an empty subgraph from x 350 to centre it on its edge's end at x
## 360.
expect {
	edges = [{ points: [{ x: 295, y: 134 }, { x: 295, y: 154 }, { x: 360, y: 154 }, { x: 360, y: 184 }], label: None }]
	moved = FlowLayoutAdjust.align_degenerate([{ x: 197, y: 93, width: 152, height: 41 }], [{ x: 350, y: 184, width: 0, height: 0 }], edges, [(Node(0), Group(0))], [93.640625])
	kept = FlowLayoutAdjust.align_degenerate(
		[],
		[{ x: 350, y: 184, width: 0, height: 0 }],
		edges.concat([{ points: [{ x: 200, y: 100 }, { x: 330, y: 184 }], label: None }]),
		[(Node(0), Group(0)), (Node(0), Group(0))],
		[10],
	)
	moved.groups == [{ x: 360, y: 184, width: 0, height: 0 }] and moved.nodes == [{ x: 197, y: 93, width: 152, height: 41 }] and kept.groups == [{ x: 350, y: 184, width: 0, height: 0 }]
}

## A short jog next to an end is straightened. Expected values from
## Mermaid's own `straightenTerminalJogsWithRuns` on the same routes.
expect {
	one = FlowLayoutAdjust.straighten_route([{ x: 0, y: 0 }, { x: 20, y: 0 }, { x: 20, y: 10 }, { x: 60, y: 10 }, { x: 60, y: 50 }])
	both = FlowLayoutAdjust.straighten_route([{ x: 0, y: 0 }, { x: 0, y: 20 }, { x: 12, y: 20 }, { x: 12, y: 80 }, { x: 90, y: 80 }, { x: 90, y: 100 }, { x: 96, y: 100 }, { x: 96, y: 130 }])
	one.points == [{ x: 0, y: 0 }, { x: 60, y: 0 }, { x: 60, y: 50 }]
		and both.points == [{ x: 0, y: 0 }, { x: 0, y: 80 }, { x: 96, y: 80 }, { x: 96, y: 130 }]
		and both.runs.len() == 2
}

## A jog is kept when straightening would cross another edge.
expect {
	route = [{ x: 0, y: 0 }, { x: 20, y: 0 }, { x: 20, y: 10 }, { x: 60, y: 10 }, { x: 60, y: 50 }]
	blocker = [{ x: 40, y: -5 }, { x: 40, y: 5 }]
	result = FlowLayoutAdjust.straighten([{ points: route, label: None }, { points: blocker, label: None }], [None, None])
	(result.first() ?? { points: [], label: None }).points == route
}
