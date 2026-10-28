import EdgeIndex

## Shared bounded network-simplex refinement. Initialization and balancing
## stay with the caller; this phase owns cut evaluation, pivot selection,
## tree exchange and rank updates for both flat and coordinated layouts.
NetworkSimplex :: {}.{
	Order : [ByIndex, Source({ nodes : List(U64), edges : List(U64), tree_edges : List(U64) })]
	Settings : { effort_cap : U64, cut_tolerance : F64, order : Order }

	refine : U64, List({ from : U64, to : U64 }), List(F64), List(U64), List(I64), List(Bool), Settings -> List(I64)
	refine = |node_count, edges, weights, spans, init_ranks, init_tree, settings| {
		edge_count = edges.len()
		cap = settings.effort_cap
		outgoing = EdgeIndex.build(node_count, edges, True)
		incoming = EdgeIndex.build(node_count, edges, False)
		weight_of = |i| weights.get(i) ?? 1
		span_of = |i| (spans.get(i) ?? 1).to_i64_wrap()
		edge_count_active = match settings.order {
			ByIndex => edge_count
			Source(order) => order.edges.len()
		}
		node_count_active = match settings.order {
			ByIndex => node_count
			Source(order) => order.nodes.len()
		}
		edge_at = |i| match settings.order {
			ByIndex => i
			Source(order) => order.edges.get(i) ?? crash "active edge index"
		}
		node_at = |i| match settings.order {
			ByIndex => i
			Source(order) => order.nodes.get(i) ?? crash "active node index"
		}
		# Net inflow weight of every node; a side's cut value is the sum of
		# its members' net inflows.
		var $net = List.repeat(0.F64, node_count)
		var $total = 0.F64
		var $whole = True
		for position in 0..<edge_count_active {
			i = edge_at(position)
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
		var $tree_order = match settings.order {
			ByIndex => []
			Source(order) => order.tree_edges
		}
		var $pivots = 0
		var $done = False
		var $low = List.repeat(0, node_count)
		var $lim = List.repeat(0.U64, node_count)
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
			for root_position in 0..<node_count_active {
				root = node_at(root_position)
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
				for position in 0..<edge_count_active {
					j = edge_at(position)
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
			leave_count = match settings.order {
				ByIndex => edge_count
				Source(_) => $tree_order.len()
			}
			while $i < leave_count and $leaving == None {
				leave_index = match settings.order {
					ByIndex => $i
					Source(_) => $tree_order.get($i) ?? crash "tree-order index"
				}
				if $tree.get(leave_index) ?? False {
					side = side_test(leave_index)
					fast = match side {
						Subtree(c) => sums.get(c) ?? 0
						Rest(c) => 0 - (sums.get(c) ?? 0)
					}
					cut = if exact or fast.abs() > bound {
						fast
					} else {
						reference_cut(side)
					}
					if cut < (0 - settings.cut_tolerance) {
						$leaving = Some({ index: leave_index, side })
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
					for position in 0..<edge_count_active {
						j = edge_at(position)
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
							match settings.order {
								ByIndex => {}
								Source(_) => {
									$tree_order = $tree_order.keep_if(|e| e != out.index).append(hit.index)
								}
							}
							if hit.slack != 0 {
								for position in 0..<node_count_active {
									v = node_at(position)
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
}
