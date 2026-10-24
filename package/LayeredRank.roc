## Internal layer assignment for the layered family: cycle breaking by a
## greedy vertex ordering, then exact weighted ranking by network simplex.
##
## Both phases reproduce the original reference definitions exactly (same
## tie-breaking, same pivot sequence, same result bits) while keeping every
## step near-linear: flat edge-index adjacency tables, binary heaps with lazy
## deletion, postorder subtree numbering for tree-side tests, and subtree
## sums for cut values.
LayeredRank :: {}.{

	## Edge indices grouped by one endpoint: the edges of node `v` are
	## `items[offsets[v] ..< offsets[v + 1]]`, in ascending edge index.
	Adjacency : { offsets : List(U64), items : List(U64) }

	## A binary-heap entry ordered by `key`, then by `item`.
	Entry : { key : I64, item : U64 }

	## Adjacency of `edges` grouped by source (`by_from`) or target. Edges
	## with an endpoint outside `0 ..< node_count` are left out.
	adjacency : U64, List({ from : U64, to : U64 }), Bool -> Adjacency
	adjacency = |node_count, edges, by_from| {
		var $offsets = List.repeat(0, node_count + 1)
		for e in edges {
			key = if by_from {
				e.from
			} else {
				e.to
			}
			if key < node_count and e.from < node_count and e.to < node_count {
				$offsets = $offsets.set(key + 1, ($offsets.get(key + 1) ?? 0) + 1) ?? []
			}
		}
		for i in 0..<node_count {
			$offsets = $offsets.set(i + 1, ($offsets.get(i + 1) ?? 0) + ($offsets.get(i) ?? 0)) ?? []
		}
		offsets = $offsets
		var $fill = offsets
		var $items = List.repeat(0, offsets.get(node_count) ?? 0)
		for i in 0..<edges.len() {
			e = edges.get(i) ?? { from: 0, to: 0 }
			key = if by_from {
				e.from
			} else {
				e.to
			}
			if key < node_count and e.from < node_count and e.to < node_count {
				at = $fill.get(key) ?? 0
				$items = $items.set(at, i) ?? []
				$fill = $fill.set(key, at + 1) ?? []
			}
		}
		{ offsets, items: $items }
	}

	## The edge indices of node `v` in an adjacency table.
	edges_of : Adjacency, U64 -> List(U64)
	edges_of = |adj, v| {
		start = adj.offsets.get(v) ?? 0
		end = adj.offsets.get(v + 1) ?? start
		adj.items.sublist({ start, len: end - start })
	}

	entry_before : Entry, Entry -> Bool
	entry_before = |a, b| a.key < b.key or (a.key == b.key and a.item < b.item)

	heap_push : List(Entry), Entry -> List(Entry)
	heap_push = |heap, entry| {
		var $h = heap.append(entry)
		var $i = $h.len() - 1
		var $moving = True
		while $moving and $i > 0 {
			parent = ($i - 1) // 2
			child_entry = $h.get($i) ?? entry
			parent_entry = $h.get(parent) ?? entry
			if LayeredRank.entry_before(child_entry, parent_entry) {
				$h = ($h.set($i, parent_entry) ?? []).set(parent, child_entry) ?? []
				$i = parent
			} else {
				$moving = False
			}
		}
		$h
	}

	## Remove the least entry. An empty heap stays empty.
	heap_pop : List(Entry) -> List(Entry)
	heap_pop = |heap| {
		count = heap.len()
		if count <= 1 {
			[]
		} else {
			last = heap.get(count - 1) ?? { key: 0, item: 0 }
			var $h = (heap.set(0, last) ?? []).drop_last(1)
			size = count - 1
			var $i = 0
			var $moving = True
			while $moving {
				left = 2 * $i + 1
				right = left + 1
				current = $h.get($i) ?? last
				smallest = if left < size and LayeredRank.entry_before($h.get(left) ?? last, current) {
					left
				} else {
					$i
				}
				smallest_entry = $h.get(smallest) ?? last
				best = if right < size and LayeredRank.entry_before($h.get(right) ?? last, smallest_entry) {
					right
				} else {
					smallest
				}
				if best == $i {
					$moving = False
				} else {
					best_entry = $h.get(best) ?? last
					$h = ($h.set($i, best_entry) ?? []).set(best, current) ?? []
					$i = best
				}
			}
			$h
		}
	}

	## Kahn's topological order of the non-loop edges, or `Err(Cyclic)`.
	topological_order : U64, List({ from : U64, to : U64 }), Adjacency -> [Ok(List(U64)), Err([Cyclic])]
	topological_order = |node_count, edges, outgoing| {
		var $indegree = List.repeat(0, node_count)
		for e in edges {
			if e.from != e.to and e.to < node_count and e.from < node_count {
				$indegree = $indegree.set(e.to, ($indegree.get(e.to) ?? 0) + 1) ?? []
			}
		}
		var $order = List.with_capacity(node_count)
		for v in 0..<node_count {
			if ($indegree.get(v) ?? 0) == 0 {
				$order = $order.append(v)
			}
		}
		var $head = 0
		while $head < $order.len() {
			u = $order.get($head) ?? 0
			$head = $head + 1
			for i in LayeredRank.edges_of(outgoing, u) {
				e = edges.get(i) ?? { from: 0, to: 0 }
				if e.from != e.to {
					left = ($indegree.get(e.to) ?? 1) - 1
					$indegree = $indegree.set(e.to, left) ?? []
					if left == 0 {
						$order = $order.append(e.to)
					}
				}
			}
		}
		if $order.len() == node_count {
			Ok($order)
		} else {
			Err(Cyclic)
		}
	}

	## Orient every edge forward along the greedy (Eades-Lin-Smyth) vertex
	## ordering: repeatedly take the lowest-index sink to the right end, else
	## the lowest-index source to the left end, else the lowest-index vertex
	## with the largest outdegree minus indegree to the left end. Edges that
	## point backward in that ordering are reversed. An acyclic graph keeps
	## every edge as given.
	orient : U64, List({ from : U64, to : U64 }) -> { edges : List({ from : U64, to : U64 }), reversed : List(U64), reversed_flags : List(Bool) }
	orient = |node_count, edges| {
		outgoing = LayeredRank.adjacency(node_count, edges, True)
		match LayeredRank.topological_order(node_count, edges, outgoing) {
			Ok(_) => { edges, reversed: [], reversed_flags: List.repeat(False, edges.len()) }
			Err(Cyclic) => {
				incoming = LayeredRank.adjacency(node_count, edges, False)
				var $outdeg = List.repeat(0, node_count)
				var $indeg = List.repeat(0, node_count)
				for e in edges {
					if e.from != e.to and e.from < node_count and e.to < node_count {
						$outdeg = $outdeg.set(e.from, ($outdeg.get(e.from) ?? 0) + 1) ?? []
						$indeg = $indeg.set(e.to, ($indeg.get(e.to) ?? 0) + 1) ?? []
					}
				}
				score = |out, inn| out.to_i64_wrap() - inn.to_i64_wrap()
				var $sinks = []
				var $sources = []
				var $best = []
				for v in 0..<node_count {
					out = $outdeg.get(v) ?? 0
					inn = $indeg.get(v) ?? 0
					if out == 0 {
						$sinks = LayeredRank.heap_push($sinks, { key: 0, item: v })
					}
					if inn == 0 {
						$sources = LayeredRank.heap_push($sources, { key: 0, item: v })
					}
					$best = LayeredRank.heap_push($best, { key: 0 - score(out, inn), item: v })
				}
				var $remaining = List.repeat(True, node_count)
				var $left = []
				var $right = []
				for _ in 0..<node_count {
					# Drop stale heap tops.
					while !$sinks.is_empty() and !($remaining.get(($sinks.get(0) ?? { key: 0, item: 0 }).item) ?? False) {
						$sinks = LayeredRank.heap_pop($sinks)
					}
					while !$sources.is_empty() and !($remaining.get(($sources.get(0) ?? { key: 0, item: 0 }).item) ?? False) {
						$sources = LayeredRank.heap_pop($sources)
					}
					var $chosen = node_count
					match $sinks.get(0) {
						Ok(top) => {
							$chosen = top.item
							$right = $right.append(top.item)
							$sinks = LayeredRank.heap_pop($sinks)
						}
						Err(_) =>
							match $sources.get(0) {
								Ok(top) => {
									$chosen = top.item
									$left = $left.append(top.item)
									$sources = LayeredRank.heap_pop($sources)
								}
								Err(_) => {
									var $searching = True
									while $searching and !$best.is_empty() {
										top = $best.get(0) ?? { key: 0, item: 0 }
										current = 0 - score($outdeg.get(top.item) ?? 0, $indeg.get(top.item) ?? 0)
										if ($remaining.get(top.item) ?? False) and current == top.key {
											$searching = False
										} else {
											$best = LayeredRank.heap_pop($best)
										}
									}
									match $best.get(0) {
										Ok(top) => {
											$chosen = top.item
											$left = $left.append(top.item)
											$best = LayeredRank.heap_pop($best)
										}
										Err(_) => {}
									}
								}
							}
					}
					v = $chosen
					if v < node_count {
						$remaining = $remaining.set(v, False) ?? []
						for i in LayeredRank.edges_of(outgoing, v) {
							w = (edges.get(i) ?? { from: 0, to: 0 }).to
							if w != v and ($remaining.get(w) ?? False) {
								left_in = ($indeg.get(w) ?? 1) - 1
								$indeg = $indeg.set(w, left_in) ?? []
								if left_in == 0 {
									$sources = LayeredRank.heap_push($sources, { key: 0, item: w })
								}
								$best = LayeredRank.heap_push($best, { key: 0 - score($outdeg.get(w) ?? 0, left_in), item: w })
							}
						}
						for i in LayeredRank.edges_of(incoming, v) {
							u = (edges.get(i) ?? { from: 0, to: 0 }).from
							if u != v and ($remaining.get(u) ?? False) {
								left_out = ($outdeg.get(u) ?? 1) - 1
								$outdeg = $outdeg.set(u, left_out) ?? []
								if left_out == 0 {
									$sinks = LayeredRank.heap_push($sinks, { key: 0, item: u })
								}
								$best = LayeredRank.heap_push($best, { key: 0 - score(left_out, $indeg.get(u) ?? 0), item: u })
							}
						}
					}
				}
				# Sinks were conceptually prepended to the right-hand sequence, so
				# their removal order reverses into final order.
				var $position = List.repeat(0.U64, node_count)
				var $next = 0.U64
				for v in $left {
					$position = $position.set(v, $next) ?? []
					$next = $next + 1
				}
				for k in 0..<$right.len() {
					v = $right.get($right.len() - 1 - k) ?? 0
					$position = $position.set(v, $next) ?? []
					$next = $next + 1
				}
				position = $position
				var $oriented = List.with_capacity(edges.len())
				var $reversed = []
				var $flags = List.with_capacity(edges.len())
				for i in 0..<edges.len() {
					e = edges.get(i) ?? { from: 0, to: 0 }
					backward = (position.get(e.from) ?? 0) > (position.get(e.to) ?? 0)
					if backward {
						$oriented = $oriented.append({ from: e.to, to: e.from })
						$reversed = $reversed.append(i)
					} else {
						$oriented = $oriented.append(e)
					}
					$flags = $flags.append(backward)
				}
				{ edges: $oriented, reversed: $reversed, reversed_flags: $flags }
			}
		}
	}

	## Longest-path ranks honoring per-edge minimum spans: sources rank 0,
	## every other node the largest predecessor rank plus that edge's span.
	## For cyclic input this is the bounded node-count-pass relaxation the
	## reference definition specifies.
	initial_ranks : U64, List({ from : U64, to : U64 }), List(U64) -> List(U64)
	initial_ranks = |node_count, edges, spans| {
		outgoing = LayeredRank.adjacency(node_count, edges, True)
		match LayeredRank.topological_order(node_count, edges, outgoing) {
			Ok(order) => {
				var $ranks = List.repeat(0, node_count)
				for u in order {
					base = $ranks.get(u) ?? 0
					for i in LayeredRank.edges_of(outgoing, u) {
						e = edges.get(i) ?? { from: 0, to: 0 }
						if e.from != e.to {
							wanted = base + (spans.get(i) ?? 1)
							if wanted > ($ranks.get(e.to) ?? 0) {
								$ranks = $ranks.set(e.to, wanted) ?? []
							}
						}
					}
				}
				$ranks
			}
			Err(Cyclic) => {
				var $ranks = List.repeat(0, node_count)
				for _ in 0..<node_count {
					for i in 0..<edges.len() {
						e = edges.get(i) ?? { from: 0, to: 0 }
						if e.from != e.to and e.from < node_count and e.to < node_count {
							wanted = ($ranks.get(e.from) ?? 0) + (spans.get(i) ?? 1)
							if wanted > ($ranks.get(e.to) ?? 0) {
								$ranks = $ranks.set(e.to, wanted) ?? []
							}
						}
					}
				}
				$ranks
			}
		}
	}

	## A spanning forest of tight edges, one tree per weakly connected
	## component, grown from the lowest unvisited node: repeatedly add the
	## incident edge of least slack (lowest index on ties), shifting the
	## partial tree so that edge becomes tight. Every edge must have distinct
	## endpoints inside `0 ..< node_count`.
	tight_forest : U64, List({ from : U64, to : U64 }), List(U64), List(I64) -> { ranks : List(I64), tree : List(Bool) }
	tight_forest = |node_count, edges, spans, init| {
		outgoing = LayeredRank.adjacency(node_count, edges, True)
		incoming = LayeredRank.adjacency(node_count, edges, False)
		span_of = |i| (spans.get(i) ?? 1).to_i64_wrap()
		var $ranks = init
		var $stored = init
		var $joined = List.repeat(False, node_count)
		var $tree = List.repeat(False, edges.len())
		for start in 0..<node_count {
			if !($joined.get(start) ?? True) {
				var $offset = 0
				var $members = []
				# Edges leaving the tree, keyed by slack plus offset; edges
				# entering it, keyed by slack minus offset.
				var $leaving = []
				var $entering = []
				var $next = start
				var $growing = True
				while $growing {
					v = $next
					$joined = $joined.set(v, True) ?? []
					$members = $members.append(v)
					stored_v = ($ranks.get(v) ?? 0) - $offset
					$stored = $stored.set(v, stored_v) ?? []
					for i in LayeredRank.edges_of(outgoing, v) {
						e = edges.get(i) ?? { from: 0, to: 0 }
						if !($joined.get(e.to) ?? True) {
							key = ($ranks.get(e.to) ?? 0) - stored_v - span_of(i)
							$leaving = LayeredRank.heap_push($leaving, { key, item: i })
						}
					}
					for i in LayeredRank.edges_of(incoming, v) {
						e = edges.get(i) ?? { from: 0, to: 0 }
						if !($joined.get(e.from) ?? True) {
							key = stored_v - ($ranks.get(e.from) ?? 0) - span_of(i)
							$entering = LayeredRank.heap_push($entering, { key, item: i })
						}
					}
					# Discard edges whose far end has joined since.
					var $cleaning = True
					while $cleaning {
						match $leaving.get(0) {
							Ok(top) if ($joined.get((edges.get(top.item) ?? { from: 0, to: 0 }).to) ?? False) => {
								$leaving = LayeredRank.heap_pop($leaving)
							}
							_ => {
								$cleaning = False
							}
						}
					}
					$cleaning = True
					while $cleaning {
						match $entering.get(0) {
							Ok(top) if ($joined.get((edges.get(top.item) ?? { from: 0, to: 0 }).from) ?? False) => {
								$entering = LayeredRank.heap_pop($entering)
							}
							_ => {
								$cleaning = False
							}
						}
					}
					choice = match ($leaving.get(0), $entering.get(0)) {
						(Ok(out), Ok(inn)) => {
							out_slack = out.key - $offset
							in_slack = inn.key + $offset
							if out_slack < in_slack or (out_slack == in_slack and out.item < inn.item) {
								Leave(out.item, out_slack)
							} else {
								Enter(inn.item, in_slack)
							}
						}
						(Ok(out), Err(_)) => Leave(out.item, out.key - $offset)
						(Err(_), Ok(inn)) => Enter(inn.item, inn.key + $offset)
						(Err(_), Err(_)) => Done
					}
					match choice {
						Leave(i, slack) => {
							$leaving = LayeredRank.heap_pop($leaving)
							$offset = $offset + slack
							$tree = $tree.set(i, True) ?? []
							$next = (edges.get(i) ?? { from: 0, to: 0 }).to
						}
						Enter(i, slack) => {
							$entering = LayeredRank.heap_pop($entering)
							$offset = $offset - slack
							$tree = $tree.set(i, True) ?? []
							$next = (edges.get(i) ?? { from: 0, to: 0 }).from
						}
						Done => {
							$growing = False
						}
					}
				}
				for m in $members {
					$ranks = $ranks.set(m, ($stored.get(m) ?? 0) + $offset) ?? []
				}
			}
		}
		{ ranks: $ranks, tree: $tree }
	}

	## Network-simplex refinement with weighted cut values: while some tree
	## edge (lowest index first) has a negative cut value, exchange it for the
	## least-slack non-tree edge (lowest index on ties) crossing the cut the
	## other way, and shift the head side so that edge becomes tight. At most
	## `8 + 4 * (node_count + edge_count)` exchanges.
	improve : U64, List({ from : U64, to : U64 }), List(F64), List(U64), List(I64), List(Bool) -> List(I64)
	improve = |node_count, edges, weights, spans, init_ranks, init_tree| {
		edge_count = edges.len()
		cap = 8 + 4 * (node_count + edge_count)
		outgoing = LayeredRank.adjacency(node_count, edges, True)
		incoming = LayeredRank.adjacency(node_count, edges, False)
		weight_of = |i| weights.get(i) ?? 1
		span_of = |i| (spans.get(i) ?? 1).to_i64_wrap()
		# Net inflow weight of every node; a side's cut value is the sum of
		# its members' net inflows.
		var $net = List.repeat(0.F64, node_count)
		var $total = 0.F64
		var $whole = True
		for i in 0..<edge_count {
			e = edges.get(i) ?? { from: 0, to: 0 }
			w = weight_of(i)
			$net = $net.set(e.to, ($net.get(e.to) ?? 0) + w) ?? []
			$net = $net.set(e.from, ($net.get(e.from) ?? 0) - w) ?? []
			$total = $total + w.abs()
			if !(w.abs() < 1.0e15 and w.to_i64_wrap().to_f64() == w) {
				$whole = False
			}
		}
		net = $net
		# Whole weights below 2^52 in total sum exactly in any order, so the
		# subtree sums equal the reference fold bit for bit. Otherwise a cut
		# value within the rounding bound of zero is recomputed in reference
		# order.
		exact = $whole and $total < 4.0e15
		bound = (5 * edge_count + 2 * node_count + 4).to_f64() * 2.3e-16 * $total
		var $ranks = init_ranks
		var $tree = init_tree
		var $pivots = 0
		var $done = False
		var $low = List.repeat(0, node_count)
		var $lim = List.repeat(0, node_count)
		var $component = List.repeat(0, node_count)
		var $parent_edge = List.repeat(edge_count, node_count)
		var $sums = net
		# Work lists reused by every exchange, so an exchange allocates nothing.
		var $visited = List.repeat(False, node_count)
		var $stack = List.with_capacity(node_count)
		while !$done and $pivots < cap {
			# Postorder numbering of every tree: the subtree of `v` is exactly
			# the nodes numbered `low[v] ..= lim[v]`.
			for v in 0..<node_count {
				$visited = $visited.set(v, False) ?? []
				$sums = $sums.set(v, net.get(v) ?? 0) ?? []
			}
			var $counter = 0
			for root in 0..<node_count {
				if !($visited.get(root) ?? True) {
					$visited = $visited.set(root, True) ?? []
					$parent_edge = $parent_edge.set(root, edge_count) ?? []
					$component = $component.set(root, root) ?? []
					$low = $low.set(root, $counter) ?? []
					$stack = $stack.append({ node: root, cursor: 0 })
					while !$stack.is_empty() {
						top = $stack.last() ?? { node: 0, cursor: 0 }
						v = top.node
						out_start = outgoing.offsets.get(v) ?? 0
						out_count = (outgoing.offsets.get(v + 1) ?? 0) - out_start
						in_start = incoming.offsets.get(v) ?? 0
						in_count = (incoming.offsets.get(v + 1) ?? 0) - in_start
						if top.cursor < out_count + in_count {
							$stack = $stack.set($stack.len() - 1, { node: v, cursor: top.cursor + 1 }) ?? []
							i = if top.cursor < out_count {
								outgoing.items.get(out_start + top.cursor) ?? 0
							} else {
								incoming.items.get(in_start + top.cursor - out_count) ?? 0
							}
							if $tree.get(i) ?? False {
								e = edges.get(i) ?? { from: 0, to: 0 }
								w = if e.from == v {
									e.to
								} else {
									e.from
								}
								if !($visited.get(w) ?? True) {
									$visited = $visited.set(w, True) ?? []
									$parent_edge = $parent_edge.set(w, i) ?? []
									$component = $component.set(w, root) ?? []
									$low = $low.set(w, $counter) ?? []
									$stack = $stack.append({ node: w, cursor: 0 })
								}
							}
						} else {
							$lim = $lim.set(v, $counter) ?? []
							$counter = $counter + 1
							$stack = $stack.drop_last(1)
							p = $parent_edge.get(v) ?? edge_count
							if p < edge_count {
								pe = edges.get(p) ?? { from: 0, to: 0 }
								parent = if pe.from == v {
									pe.to
								} else {
									pe.from
								}
								$sums = $sums.set(parent, ($sums.get(parent) ?? 0) + ($sums.get(v) ?? 0)) ?? []
							}
						}
					}
				}
			}
			low = $low
			lim = $lim
			component = $component
			parent_edge = $parent_edge
			sums = $sums
			in_subtree = |x, c| {
				n = lim.get(x) ?? 0
				n >= (low.get(c) ?? 0) and n <= (lim.get(c) ?? 0)
			}
			# The head side of tree edge `i`: the nodes still joined to its
			# `to` end once `i` is removed.
			side_test = |i| {
				e = edges.get(i) ?? { from: 0, to: 0 }
				if (parent_edge.get(e.to) ?? edge_count) == i {
					Subtree(e.to)
				} else {
					Rest(e.from)
				}
			}
			in_side = |x, side| match side {
				Subtree(c) => in_subtree(x, c)
				Rest(c) => (component.get(x) ?? 0) == (component.get(c) ?? 0) and !in_subtree(x, c)
			}
			reference_cut = |side| {
				var $cut = 0.F64
				for j in 0..<edge_count {
					e = edges.get(j) ?? { from: 0, to: 0 }
					from_in = in_side(e.from, side)
					to_in = in_side(e.to, side)
					if to_in and !from_in {
						$cut = $cut + weight_of(j)
					} else if from_in and !to_in {
						$cut = $cut - weight_of(j)
					}
				}
				$cut
			}
			var $leaving = None
			var $i = 0
			while $i < edge_count and $leaving == None {
				if $tree.get($i) ?? False {
					side = side_test($i)
					fast = match side {
						Subtree(c) => sums.get(c) ?? 0
						Rest(c) => 0 - (sums.get(c) ?? 0)
					}
					cut = if exact or fast.abs() > bound {
						fast
					} else {
						reference_cut(side)
					}
					if cut < 0 {
						$leaving = Some({ index: $i, side })
					}
				}
				$i = $i + 1
			}
			match $leaving {
				None => {
					$done = True
				}
				Some(out) => {
					var $entering = None
					for j in 0..<edge_count {
						if !($tree.get(j) ?? False) {
							e = edges.get(j) ?? { from: 0, to: 0 }
							if in_side(e.from, out.side) and !in_side(e.to, out.side) {
								slack = ($ranks.get(e.to) ?? 0) - ($ranks.get(e.from) ?? 0) - span_of(j)
								match $entering {
									None => {
										$entering = Some({ index: j, slack })
									}
									Some(best) => if slack < best.slack {
										$entering = Some({ index: j, slack })
									}
								}
							}
						}
					}
					match $entering {
						None => {
							$done = True
						}
						Some(hit) => {
							$tree = ($tree.set(out.index, False) ?? []).set(hit.index, True) ?? []
							if hit.slack != 0 {
								for v in 0..<node_count {
									if in_side(v, out.side) {
										$ranks = $ranks.set(v, ($ranks.get(v) ?? 0) + hit.slack) ?? []
									}
								}
							}
							$pivots = $pivots + 1
						}
					}
				}
			}
		}
		$ranks
	}

	## Shift every weakly connected component so its lowest rank is 0.
	normalize : U64, List({ from : U64, to : U64 }), List(I64) -> List(U64)
	normalize = |node_count, edges, ranks| {
		outgoing = LayeredRank.adjacency(node_count, edges, True)
		incoming = LayeredRank.adjacency(node_count, edges, False)
		var $label = List.repeat(node_count, node_count)
		var $lowest = List.repeat(0, node_count)
		for start in 0..<node_count {
			if ($label.get(start) ?? 0) == node_count {
				$label = $label.set(start, start) ?? []
				var $queue = [start]
				var $head = 0
				var $low = ranks.get(start) ?? 0
				while $head < $queue.len() {
					v = $queue.get($head) ?? 0
					$head = $head + 1
					$low = $low.min(ranks.get(v) ?? 0)
					for i in LayeredRank.edges_of(outgoing, v).concat(LayeredRank.edges_of(incoming, v)) {
						e = edges.get(i) ?? { from: 0, to: 0 }
						w = if e.from == v {
							e.to
						} else {
							e.from
						}
						if ($label.get(w) ?? 0) == node_count {
							$label = $label.set(w, start) ?? []
							$queue = $queue.append(w)
						}
					}
				}
				$lowest = $lowest.set(start, $low) ?? []
			}
		}
		label = $label
		lowest = $lowest
		ranks.map_with_index(
			|rank, v| {
				shifted = rank - (lowest.get(label.get(v) ?? 0) ?? 0)
				if shifted < 0 {
					0
				} else {
					shifted.to_u64_wrap()
				}
			},
		)
	}

	## Exact weighted ranking: every edge spans at least its minimum, and the
	## total of weight times span is minimal. Self-loops are ignored; each
	## weakly connected component starts at rank 0. Input should be acyclic
	## (see `orient`); bounded iteration keeps any input total.
	rank : U64, List({ from : U64, to : U64 }), List(F64), List(U64) -> List(U64)
	rank = |node_count, edges, weights, spans| {
		if node_count == 0 {
			[]
		} else {
			init = LayeredRank.initial_ranks(node_count, edges, spans).map(|r| r.to_i64_wrap())
			var $spanning = []
			var $spanning_weights = []
			var $spanning_spans = []
			for i in 0..<edges.len() {
				e = edges.get(i) ?? { from: 0, to: 0 }
				if e.from != e.to {
					$spanning = $spanning.append(e)
					$spanning_weights = $spanning_weights.append(weights.get(i) ?? 1)
					$spanning_spans = $spanning_spans.append(spans.get(i) ?? 1)
				}
			}
			forest = LayeredRank.tight_forest(node_count, $spanning, $spanning_spans, init)
			refined = LayeredRank.improve(node_count, $spanning, $spanning_weights, $spanning_spans, forest.ranks, forest.tree)
			LayeredRank.normalize(node_count, edges, refined)
		}
	}
}

expect {
	heap = [{ key: 5, item: 0 }, { key: 1, item: 4 }, { key: 3, item: 2 }, { key: 1, item: 1 }].fold([], |h, e| LayeredRank.heap_push(h, e))
	first = heap.get(0) ?? { key: 0, item: 0 }
	rest = LayeredRank.heap_pop(heap)
	second = rest.get(0) ?? { key: 0, item: 0 }
	first == { key: 1, item: 1 } and second == { key: 1, item: 4 } and LayeredRank.heap_pop(LayeredRank.heap_pop(LayeredRank.heap_pop(rest))) == []
}

## Acyclic input keeps every edge as given, whatever its index order.
expect {
	edges = [{ from: 3, to: 1 }, { from: 1, to: 0 }, { from: 3, to: 0 }, { from: 2, to: 3 }, { from: 2, to: 2 }]
	LayeredRank.orient(4, edges) == { edges, reversed: [], reversed_flags: [False, False, False, False, False] }
}

## A three-cycle reverses exactly one edge.
expect {
	oriented = LayeredRank.orient(3, [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }])
	oriented.reversed.len() == 1
}

## A diamond ranks by longest path; a lone node ranks 0; empty input is empty.
expect LayeredRank.rank(4, [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 2, to: 3 }], [], []) == [0, 1, 1, 2]
expect LayeredRank.rank(1, [], [], []) == [0]
expect LayeredRank.rank(0, [], [], []) == []

## A heavy edge stays short at the cost of light ones.
expect {
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 0, to: 3 }, { from: 4, to: 3 }]
	LayeredRank.rank(5, edges, [1, 1, 1, 1, 1], [1, 1, 1, 1, 1]) == [0, 1, 2, 3, 2]
}

## Minimum spans hold, disconnected components each start at rank 0, and
## self-loops are ignored.
expect {
	ranks = LayeredRank.rank(5, [{ from: 0, to: 1 }, { from: 1, to: 1 }, { from: 2, to: 3 }, { from: 3, to: 4 }], [1, 1, 1, 1], [3, 1, 1, 2])
	ranks == [0, 3, 0, 1, 3]
}
