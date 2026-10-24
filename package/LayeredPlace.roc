import LayeredRank

## Internal coordinate assignment steps for the layered family: the
## vertical alignment and horizontal compaction of one Brandes-Kopf
## candidate. Both reproduce the reference definitions in `Layered` exactly
## while reading each edge a constant number of times per candidate.
LayeredPlace :: {}.{

	## Each node's layer index and position in it; nodes in no layer get
	## the layer count.
	Positions : { layer_of : List(U64), pos : List(U64) }

	positions : U64, List(List(U64)) -> Positions
	positions = |size, layers| {
		var $layer_of = List.repeat(layers.len(), size)
		var $pos = List.repeat(0, size)
		for i in 0..<layers.len() {
			layer = layers.get(i) ?? []
			for p in 0..<layer.len() {
				v = layer.get(p) ?? 0
				if v < size {
					$layer_of = $layer_of.set(v, i) ?? []
					$pos = $pos.set(v, p) ?? []
				}
			}
		}
		{ layer_of: $layer_of, pos: $pos }
	}

	## Edges marked as type-1 conflicts: an ordinary segment between adjacent
	## layers that strictly crosses an inner segment (both ends virtual) of
	## the same layer pair. Alignment never follows a marked segment.
	conflicts : List(List(U64)), Positions, U64, List({ from : U64, to : U64 }), LayeredRank.Adjacency, LayeredRank.Adjacency -> List(Bool)
	conflicts = |layers, at, real_count, edges, outgoing, incoming| {
		var $marked = List.repeat(False, edges.len())
		none = layers.len()
		if layers.len() >= 2 {
			for t in 0..<(layers.len() - 1) {
				upper = layers.get(t) ?? []
				# Segments of this gap: edge, upper position, lower position, inner.
				var $segments = []
				for u in upper {
					up = at.pos.get(u) ?? 0
					for e in LayeredRank.edges_of(outgoing, u) {
						w = (edges.get(e) ?? { from: 0, to: 0 }).to
						if (at.layer_of.get(w) ?? none) == t + 1 {
							$segments = $segments.append({ edge: e, up, lp: at.pos.get(w) ?? 0, inner: u >= real_count and w >= real_count })
						}
					}
					for e in LayeredRank.edges_of(incoming, u) {
						w = (edges.get(e) ?? { from: 0, to: 0 }).from
						if (at.layer_of.get(w) ?? none) == t + 1 {
							$segments = $segments.append({ edge: e, up, lp: at.pos.get(w) ?? 0, inner: u >= real_count and w >= real_count })
						}
					}
				}
				segments = $segments
				count = upper.len()
				# Largest inner lower position strictly left of each upper
				# position, smallest strictly right.
				var $max_at = List.repeat(-1.I64, count)
				var $min_at = List.repeat(-1.I64, count)
				for s in segments {
					if s.inner {
						lp = s.lp.to_i64_wrap()
						current_max = $max_at.get(s.up) ?? -1
						if lp > current_max {
							$max_at = $max_at.set(s.up, lp) ?? []
						}
						current_min = $min_at.get(s.up) ?? -1
						if current_min < 0 or lp < current_min {
							$min_at = $min_at.set(s.up, lp) ?? []
						}
					}
				}
				var $max_before = List.repeat(-1.I64, count)
				var $running_max = -1.I64
				for x in 0..<count {
					$max_before = $max_before.set(x, $running_max) ?? []
					$running_max = $running_max.max($max_at.get(x) ?? -1)
				}
				var $min_after = List.repeat(-1.I64, count)
				var $running_min = -1.I64
				for k in 0..<count {
					x = count - 1 - k
					$min_after = $min_after.set(x, $running_min) ?? []
					here = $min_at.get(x) ?? -1
					if here >= 0 and ($running_min < 0 or here < $running_min) {
						$running_min = here
					}
				}
				max_before = $max_before
				min_after = $min_after
				for s in segments {
					if !s.inner {
						lp = s.lp.to_i64_wrap()
						left = max_before.get(s.up) ?? -1
						right = min_after.get(s.up) ?? -1
						if left > lp or (right >= 0 and right < lp) {
							$marked = $marked.set(s.edge, True) ?? []
						}
					}
				}
			}
		}
		$marked
	}

	## One Brandes-Kopf vertical alignment: each node aligns with the median
	## of its neighbors in the layer above when that segment is unmarked and
	## alignment stays left-to-right monotone within the layer. Returns each
	## node's block root (the block's topmost node).
	block_roots : U64, List(List(U64)), U64, List({ from : U64, to : U64 }) -> List(U64)
	block_roots = |node_total, layers, real_count, edges| {
		size = edges.fold(node_total, |acc, e| acc.max(e.from + 1).max(e.to + 1))
		at = LayeredPlace.positions(size, layers)
		outgoing = LayeredRank.adjacency(size, edges, True)
		incoming = LayeredRank.adjacency(size, edges, False)
		marked = LayeredPlace.conflicts(layers, at, real_count, edges, outgoing, incoming)
		none = layers.len()
		var $root = List.repeat(0, node_total).map_with_index(|_, i| i)
		var $align = $root
		# Per-node scratch: the node whose neighbor list last saw it, and
		# whether any edge from it to that node is marked.
		var $seen = List.repeat(size, size)
		var $flag = List.repeat(False, size)
		for t in 1..<layers.len().max(1) {
			layer = layers.get(t) ?? []
			var $taken = -1.I64
			for v in layer {
				var $neighbors = []
				for e in LayeredRank.edges_of(incoming, v).concat(LayeredRank.edges_of(outgoing, v)) {
					edge = edges.get(e) ?? { from: 0, to: 0 }
					u = if edge.to == v {
						edge.from
					} else {
						edge.to
					}
					if (at.layer_of.get(u) ?? none) == t - 1 {
						if ($seen.get(u) ?? size) != v {
							$seen = $seen.set(u, v) ?? []
							$flag = $flag.set(u, False) ?? []
							$neighbors = $neighbors.append(u)
						}
						if marked.get(e) ?? False {
							$flag = $flag.set(u, True) ?? []
						}
					}
				}
				neighbors = $neighbors
				if !neighbors.is_empty() {
					sorted = LayeredPlace.by_position(neighbors, at.pos)
					d = sorted.len()
					for m in [(d - 1) // 2, d // 2] {
						if ($align.get(v) ?? v) == v {
							u = sorted.get(m) ?? 0
							u_pos = (at.pos.get(u) ?? 0).to_i64_wrap()
							if !($flag.get(u) ?? False) and $taken < u_pos {
								block = $root.get(u) ?? u
								$align = $align.set(u, v) ?? []
								$root = $root.set(v, block) ?? []
								$align = $align.set(v, block) ?? []
								$taken = u_pos
							}
						}
					}
				}
			}
		}
		$root
	}

	## Nodes sorted by ascending position (positions within one layer are
	## distinct).
	by_position : List(U64), List(U64) -> List(U64)
	by_position = |nodes, pos| {
		var $sorted = nodes
		# Insertion sort: neighbor lists are short, and the common
		# already-sorted case is linear.
		for i in 1..<nodes.len().max(1) {
			var $j = i
			var $moving = True
			while $moving and $j > 0 {
				a = $sorted.get($j - 1) ?? 0
				b = $sorted.get($j) ?? 0
				if (pos.get(a) ?? 0) > (pos.get(b) ?? 0) {
					$sorted = ($sorted.set($j - 1, b) ?? []).set($j, a) ?? []
					$j = $j - 1
				} else {
					$moving = False
				}
			}
		}
		$sorted
	}

	## Left-compacts one alignment: every block sits as far left as the
	## separation constraints between horizontally adjacent nodes allow —
	## centers at least (width_u + width_v) / 2 + node_gap apart. The
	## constraints between blocks form an acyclic graph, so one pass in
	## topological order reaches the longest-path fixed point the reference
	## relaxation computes; a cyclic constraint set falls back to that
	## bounded relaxation.
	compact_blocks : U64, List(List(U64)), List(U64), List(F64), F64 -> List(F64)
	compact_blocks = |node_total, layers, roots, widths, node_gap| {
		var $constraints = []
		for layer in layers {
			if layer.len() >= 2 {
				for p in 0..<(layer.len() - 1) {
					u = layer.get(p) ?? 0
					v = layer.get(p + 1) ?? 0
					sep = ((widths.get(u) ?? 0) + (widths.get(v) ?? 0)) / 2 + node_gap
					$constraints = $constraints.append({ left: roots.get(u) ?? u, right: roots.get(v) ?? v, sep })
				}
			}
		}
		constraints = $constraints
		size = constraints.fold(node_total, |acc, c| acc.max(c.left + 1).max(c.right + 1))
		as_edges = constraints.map(|c| { from: c.left, to: c.right })
		after = LayeredRank.adjacency(size, as_edges, True)
		var $block_x = List.repeat(0.F64, node_total)
		match LayeredRank.topological_order(size, as_edges, after) {
			Ok(order) if constraints.all(|c| c.left != c.right) => {
				for u in order {
					base = $block_x.get(u) ?? 0
					for k in LayeredRank.edges_of(after, u) {
						c = constraints.get(k) ?? { left: 0, right: 0, sep: 0 }
						pushed = base + c.sep
						if c.right < node_total and pushed > ($block_x.get(c.right) ?? 0) {
							$block_x = $block_x.set(c.right, pushed) ?? []
						}
					}
				}
			}
			_ => {
				for _ in 0..<node_total {
					for c in constraints {
						pushed = ($block_x.get(c.left) ?? 0) + c.sep
						if c.right < node_total and pushed > ($block_x.get(c.right) ?? 0) {
							$block_x = $block_x.set(c.right, pushed) ?? []
						}
					}
				}
			}
		}
		block_x = $block_x
		List.repeat(0, node_total).map_with_index(|_, v| block_x.get(roots.get(v) ?? v) ?? 0)
	}
}

## A crossing ordinary segment is marked; a parallel one is not.
expect {
	# Layers [[0, 4], [5, 1]] with 4 -> 5 inner (both >= real_count 4) and
	# 0 -> 1 crossing it.
	layers = [[0, 4], [5, 1]]
	edges = [{ from: 0, to: 1 }, { from: 4, to: 5 }]
	at = LayeredPlace.positions(6, layers)
	marks = LayeredPlace.conflicts(layers, at, 4, edges, LayeredRank.adjacency(6, edges, True), LayeredRank.adjacency(6, edges, False))
	marks == [True, False]
}

expect LayeredPlace.by_position([3, 1, 2], [0, 2, 1, 0]) == [3, 2, 1]

## Compaction keeps adjacent centers apart by half widths plus the gap.
expect LayeredPlace.compact_blocks(3, [[0, 1, 2]], [0, 1, 2], [10, 20, 10], 5) == [0, 20, 40]
