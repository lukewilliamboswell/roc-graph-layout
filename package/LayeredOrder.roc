import LayeredRank

## Internal layer construction and crossing reduction for the layered
## family: grouping nodes by rank, splitting long edges into chains of
## unit edges, and ordering each layer by scored sweeps.
##
## Ordering works on one flat, layer-major node list with a node-indexed
## position table and edge-index adjacency, so a sweep costs time
## proportional to the edges it reads, and a crossing count costs
## `e log e` per layer pair. Every choice reproduces the reference
## definitions in `Layered` exactly, including their tie-breaking.
LayeredOrder :: {}.{

	## `[0, 1, .., n - 1]`.
	indices : U64 -> List(U64)
	indices = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## A stable merge sort of `items`: `before(a, b)` says `a` must precede
	## `b`; items that are not strictly ordered keep their input order.
	sort_by : List(U64), (U64, U64 -> Bool) -> List(U64)
	sort_by = |items, before| {
		n = items.len()
		var $sorted = items
		var $width = 1
		while $width < n {
			$sorted = LayeredOrder.merge_pass($sorted, $width, before)
			$width = $width * 2
		}
		$sorted
	}

	## One bottom-up merge pass: every pair of adjacent sorted runs of
	## `width` items becomes one sorted run, left run first on ties. Each
	## pass builds a fresh list rather than swapping two buffers, which the
	## 2026-10-23 nightly leaked one allocation for.
	merge_pass : List(U64), U64, (U64, U64 -> Bool) -> List(U64)
	merge_pass = |src, width, before| {
		n = src.len()
		var $dst = List.with_capacity(n)
		var $lo = 0
		while $lo < n {
			mid = ($lo + width).min(n)
			hi = ($lo + 2 * width).min(n)
			var $i = $lo
			var $j = mid
			while $i < mid or $j < hi {
				take_right = if $i >= mid {
					True
				} else if $j >= hi {
					False
				} else {
					before(src.get($j) ?? 0, src.get($i) ?? 0)
				}
				if take_right {
					$dst = $dst.append(src.get($j) ?? 0)
					$j = $j + 1
				} else {
					$dst = $dst.append(src.get($i) ?? 0)
					$i = $i + 1
				}
			}
			$lo = hi
		}
		$dst
	}

	## Ascending copy of a list of numbers.
	sort_values : List(U64) -> List(U64)
	sort_values = |values| {
		ascending = values.fold_with_index(True, |ok, v, i| ok and (i == 0 or (values.get(i - 1) ?? 0) <= v))
		if ascending {
			values
		} else {
			order = LayeredOrder.sort_by(LayeredOrder.indices(values.len()), |a, b| (values.get(a) ?? 0) < (values.get(b) ?? 0))
			order.map(|i| values.get(i) ?? 0)
		}
	}

	## Node indices grouped by rank: ascending rank, then ascending index.
	group_by_rank : List(U64) -> List(List(U64))
	group_by_rank = |ranks| {
		layer_count = ranks.fold(
			0,
			|acc, r| if r + 1 > acc {
				r + 1
			} else {
				acc
			},
		)
		var $starts = List.repeat(0, layer_count + 1)
		for r in ranks {
			$starts = $starts.set(r + 1, ($starts.get(r + 1) ?? 0) + 1) ?? []
		}
		for i in 0..<layer_count {
			$starts = $starts.set(i + 1, ($starts.get(i + 1) ?? 0) + ($starts.get(i) ?? 0)) ?? []
		}
		starts = $starts
		var $fill = starts
		var $flat = List.repeat(0, ranks.len())
		for v in 0..<ranks.len() {
			r = ranks.get(v) ?? 0
			at = $fill.get(r) ?? 0
			$flat = $flat.set(at, v) ?? []
			$fill = $fill.set(r, at + 1) ?? []
		}
		flat = $flat
		LayeredOrder.indices(layer_count).map(
			|i| {
				start = starts.get(i) ?? 0
				flat.sublist({ start, len: (starts.get(i + 1) ?? start) - start })
			},
		)
	}

	## Split every edge spanning more than one rank into a chain of unit
	## edges through new zero-size nodes numbered after the real ones.
	## Returns the extended ranks, the unit edges, and each edge's chain of
	## node indices from `from` to `to`.
	insert_virtual_chains : List(U64), List({ from : U64, to : U64 }) -> { ranks : List(U64), unit_edges : List({ from : U64, to : U64 }), chains : List(List(U64)) }
	insert_virtual_chains = |real_ranks, edges| {
		var $ranks = real_ranks
		var $unit_edges = List.with_capacity(edges.len())
		var $chains = List.with_capacity(edges.len())
		for edge in edges {
			from_rank = $ranks.get(edge.from) ?? 0
			to_rank = $ranks.get(edge.to) ?? 0
			span = if to_rank > from_rank {
				to_rank - from_rank
			} else {
				1
			}
			if span <= 1 {
				$unit_edges = $unit_edges.append(edge)
				$chains = $chains.append([edge.from, edge.to])
			} else {
				first_virtual = $ranks.len()
				var $chain = List.with_capacity(span + 1)
				$chain = $chain.append(edge.from)
				var $previous = edge.from
				for i in 0..<(span - 1) {
					v = first_virtual + i
					$ranks = $ranks.append(from_rank + 1 + i)
					$chain = $chain.append(v)
					$unit_edges = $unit_edges.append({ from: $previous, to: v })
					$previous = v
				}
				$unit_edges = $unit_edges.append({ from: $previous, to: edge.to })
				$chains = $chains.append($chain.append(edge.to))
			}
		}
		{ ranks: $ranks, unit_edges: $unit_edges, chains: $chains }
	}

	## The fixed shape of a layering: where each layer starts in the flat
	## node list, each node's layer (the layer count for none), and the
	## table size covering every node and edge end.
	Shape : { starts : List(U64), layer_of : List(U64), size : U64 }

	## A layering's current order: every layer's nodes back to back, and each
	## node's position within its layer. Threaded through the phases as two
	## uniquely owned lists so each update happens in place.
	Order : { flat : List(U64), pos : List(U64) }

	flatten : List(List(U64)), List({ from : U64, to : U64 }) -> { shape : Shape, order : Order }
	flatten = |layers, edges| {
		biggest = layers.fold(0, |acc, layer| layer.fold(acc, |inner, v| inner.max(v + 1)))
		size = edges.fold(biggest, |acc, e| acc.max(e.from + 1).max(e.to + 1))
		none = layers.len()
		var $flat = []
		var $starts = List.with_capacity(layers.len() + 1)
		var $layer_of = List.repeat(none, size)
		var $pos = List.repeat(0, size)
		for i in 0..<layers.len() {
			$starts = $starts.append($flat.len())
			layer = layers.get(i) ?? []
			for p in 0..<layer.len() {
				v = layer.get(p) ?? 0
				$flat = $flat.append(v)
				$layer_of = $layer_of.set(v, i) ?? []
				$pos = $pos.set(v, p) ?? []
			}
		}
		$starts = $starts.append($flat.len())
		{ shape: { starts: $starts, layer_of: $layer_of, size }, order: { flat: $flat, pos: $pos } }
	}

	## A fresh copy of layer `i`, so later in-place writes to `flat` never
	## share storage with it.
	copy_layer : Shape, List(U64), U64 -> List(U64)
	copy_layer = |shape, flat, i| {
		start = shape.starts.get(i) ?? 0
		end = shape.starts.get(i + 1) ?? start
		var $out = List.with_capacity(end - start)
		for k in start..<end {
			$out = $out.append(flat.get(k) ?? 0)
		}
		$out
	}

	unflatten : Shape, List(U64) -> List(List(U64))
	unflatten = |shape, flat| LayeredOrder.indices(shape.starts.len() - 1).map(|i| LayeredOrder.copy_layer(shape, flat, i))

	## Crossings between layer `i` and layer `i + 1`: pairs of edges from the
	## upper layer to the lower one whose endpoint orders strictly invert.
	gap_crossings : Shape, Order, LayeredRank.Adjacency, List({ from : U64, to : U64 }), U64 -> U64
	gap_crossings = |shape, current, outgoing, edges, i| {
		start = shape.starts.get(i) ?? 0
		end = shape.starts.get(i + 1) ?? start
		lower_count = (shape.starts.get(i + 2) ?? 0) - end
		# Fenwick tree over lower positions of edges already seen from
		# strictly earlier upper positions.
		var $tree = List.repeat(0, lower_count + 1)
		var $seen = 0
		var $total = 0
		var $ends = []
		for k in start..<end {
			u = current.flat.get(k) ?? 0
			$ends = []
			for e in LayeredRank.edges_of(outgoing, u) {
				to = (edges.get(e) ?? { from: 0, to: 0 }).to
				if (shape.layer_of.get(to) ?? 0) == i + 1 {
					$ends = $ends.append(current.pos.get(to) ?? 0)
				}
			}
			for b in $ends {
				# Seen edges ending at or left of b.
				var $j = b + 1
				var $at_most = 0
				while $j > 0 {
					$at_most = $at_most + ($tree.get($j) ?? 0)
					$j = $j - $j.bitwise_and($j.bitwise_xor($j - 1))
				}
				$total = $total + $seen - $at_most
			}
			for b in $ends {
				var $j = b + 1
				while $j <= lower_count {
					$tree = $tree.set($j, ($tree.get($j) ?? 0) + 1) ?? []
					$j = $j + $j.bitwise_and($j.bitwise_xor($j - 1))
				}
				$seen = $seen + 1
			}
		}
		$total
	}

	total_flat : Shape, Order, LayeredRank.Adjacency, List({ from : U64, to : U64 }) -> U64
	total_flat = |shape, current, outgoing, edges| {
		layer_count = shape.starts.len() - 1
		if layer_count < 2 {
			0
		} else {
			LayeredOrder.indices(layer_count - 1).fold(0, |acc, i| acc + LayeredOrder.gap_crossings(shape, current, outgoing, edges, i))
		}
	}

	## Total crossings of a complete ordering.
	total_crossings : List(List(U64)), List({ from : U64, to : U64 }) -> U64
	total_crossings = |layers, edges| {
		start = LayeredOrder.flatten(layers, edges)
		LayeredOrder.total_flat(start.shape, start.order, LayeredRank.adjacency(start.shape.size, edges, True), edges)
	}

	## The median of a non-empty list of positions.
	median : List(U64) -> F64
	median = |values| {
		sorted = LayeredOrder.sort_values(values)
		n = sorted.len()
		mid = n // 2
		if n % 2 == 1 {
			(sorted.get(mid) ?? 0).to_f64()
		} else {
			((sorted.get(mid - 1) ?? 0).to_f64() + (sorted.get(mid) ?? 0).to_f64()) / 2
		}
	}

	## Write `layer` (a permutation of layer `i`) into the order.
	write_layer : Shape, List(U64), List(U64), U64, List(U64) -> Order
	write_layer = |shape, flat, pos, i, layer| {
		start = shape.starts.get(i) ?? 0
		var $flat = flat
		var $pos = pos
		for p in 0..<layer.len() {
			v = layer.get(p) ?? 0
			$flat = $flat.set(start + p, v) ?? []
			$pos = $pos.set(v, p) ?? []
		}
		{ flat: $flat, pos: $pos }
	}

	## One median sweep. `Down` reorders every layer but the first by the
	## median position of its neighbors in the layer above, `Up` every layer
	## but the last by the layer below. A node without neighbors keeps its
	## position as its key; equal keys keep their current order.
	##
	## `Median` keys reproduce the reference reading: neighbor positions come
	## from a table indexed up to the largest node of the neighbor layer, so a
	## neighbor elsewhere with a smaller index counts as position 0. `Average`
	## keys are the mean position of the neighbors in the adjacent layer.
	sweep : Shape, Order, LayeredRank.Adjacency, LayeredRank.Adjacency, List({ from : U64, to : U64 }), [Down, Up], [Median, Average] -> Order
	sweep = |shape, initial, outgoing, incoming, edges, direction, method| {
		layer_count = shape.starts.len() - 1
		var $flat = initial.flat
		var $pos = initial.pos
		for step in 0..<layer_count {
			i = match direction {
				Down => step
				Up => layer_count - 1 - step
			}
			neighbor = match direction {
				Down => if i == 0 {
					Err({})
				} else {
					Ok(i - 1)
				}
				Up => if i + 1 >= layer_count {
					Err({})
				} else {
					Ok(i + 1)
				}
			}
			match neighbor {
				Err({}) => {}
				Ok(j) => {
					largest = LayeredOrder.copy_layer(shape, $flat, j).fold(0, |acc, v| acc.max(v))
					layer = LayeredOrder.copy_layer(shape, $flat, i)
					var $keys = List.with_capacity(layer.len())
					var $values = []
					for p in 0..<layer.len() {
						v = layer.get(p) ?? 0
						adjacent = match direction {
							Down => LayeredRank.edges_of(incoming, v)
							Up => LayeredRank.edges_of(outgoing, v)
						}
						$values = []
						for e in adjacent {
							edge = edges.get(e) ?? { from: 0, to: 0 }
							u = match direction {
								Down => edge.from
								Up => edge.to
							}
							if (shape.layer_of.get(u) ?? 0) == j {
								$values = $values.append($pos.get(u) ?? 0)
							} else if method == Median and u <= largest {
								$values = $values.append(0)
							}
						}
						key = if $values.is_empty() {
							p.to_f64()
						} else {
							match method {
								Median => LayeredOrder.median($values)
								Average => $values.fold(0.F64, |sum, at| sum + at.to_f64()) / $values.len().to_f64()
							}
						}
						$keys = $keys.append(key)
					}
					keys = $keys
					moved = LayeredOrder.sort_by(LayeredOrder.indices(layer.len()), |a, b| (keys.get(a) ?? 0) < (keys.get(b) ?? 0))
					written = LayeredOrder.write_layer(shape, $flat, $pos, i, moved.map(|p| layer.get(p) ?? 0))
					$flat = written.flat
					$pos = written.pos
				}
			}
		}
		{ flat: $flat, pos: $pos }
	}

	## One median sweep over list-of-layers input; see `sweep`.
	sweep_layers : List(List(U64)), List({ from : U64, to : U64 }), [Down, Up] -> List(List(U64))
	sweep_layers = |layers, edges, direction| {
		start = LayeredOrder.flatten(layers, edges)
		outgoing = LayeredRank.adjacency(start.shape.size, edges, True)
		incoming = LayeredRank.adjacency(start.shape.size, edges, False)
		LayeredOrder.unflatten(start.shape, LayeredOrder.sweep(start.shape, start.order, outgoing, incoming, edges, direction, Median).flat)
	}

	## Neighbor positions of `v` in layer `j`, sorted.
	positions_in : Shape, List(U64), LayeredRank.Adjacency, List({ from : U64, to : U64 }), U64, U64, Bool -> List(U64)
	positions_in = |shape, pos, adjacency, edges, v, j, use_from| {
		var $values = []
		for e in LayeredRank.edges_of(adjacency, v) {
			edge = edges.get(e) ?? { from: 0, to: 0 }
			u = if use_from {
				edge.from
			} else {
				edge.to
			}
			if (shape.layer_of.get(u) ?? 0) == j {
				$values = $values.append(pos.get(u) ?? 0)
			}
		}
		LayeredOrder.sort_values($values)
	}

	## Pairs `(a, b)` from two sorted lists with `a > b` (`before`) and with
	## `a < b` (`after`).
	pair_order : List(U64), List(U64) -> { before : U64, after : U64 }
	pair_order = |us, vs| {
		var $less = 0
		var $at_most = 0
		var $before = 0
		var $after = 0
		count = vs.len()
		for a in us {
			while $less < count and (vs.get($less) ?? 0) < a {
				$less = $less + 1
			}
			while $at_most < count and (vs.get($at_most) ?? 0) <= a {
				$at_most = $at_most + 1
			}
			$before = $before + $less
			$after = $after + count - $at_most
		}
		{ before: $before, after: $after }
	}

	## One adjacent-swap pass over every layer, top to bottom: a swap is kept
	## only when it strictly reduces crossings with both neighboring layers.
	transpose : Shape, Order, LayeredRank.Adjacency, LayeredRank.Adjacency, List({ from : U64, to : U64 }) -> Order
	transpose = |shape, initial, outgoing, incoming, edges| {
		layer_count = shape.starts.len() - 1
		var $flat = initial.flat
		var $pos = initial.pos
		for i in 0..<layer_count {
			layer = LayeredOrder.copy_layer(shape, $flat, i)
			if layer.len() >= 2 {
				pos = $pos
				ups = layer.map(
					|v| if i == 0 {
						[]
					} else {
						LayeredOrder.positions_in(shape, pos, incoming, edges, v, i - 1, True)
					},
				)
				downs = layer.map(
					|v| if i + 1 >= layer_count {
						[]
					} else {
						LayeredOrder.positions_in(shape, pos, outgoing, edges, v, i + 1, False)
					},
				)
				# Work on initial positions so the neighbor lists stay addressable.
				var $cur = LayeredOrder.indices(layer.len())
				for p in 0..<(layer.len() - 1) {
					a = $cur.get(p) ?? 0
					b = $cur.get(p + 1) ?? 0
					incoming_pairs = LayeredOrder.pair_order(ups.get(a) ?? [], ups.get(b) ?? [])
					outgoing_pairs = LayeredOrder.pair_order(downs.get(a) ?? [], downs.get(b) ?? [])
					if incoming_pairs.after + outgoing_pairs.after < incoming_pairs.before + outgoing_pairs.before {
						$cur = ($cur.set(p, b) ?? []).set(p + 1, a) ?? []
					}
				}
				moved = $cur.map(|p| layer.get(p) ?? 0)
				written = LayeredOrder.write_layer(shape, $flat, pos, i, moved)
				$flat = written.flat
				$pos = written.pos
			}
		}
		{ flat: $flat, pos: $pos }
	}

	## Orders every layer to reduce edge crossings: rounds of a down then up
	## sweep, each round scored by total crossings. `Median` sweeps key nodes
	## by the median neighbor position and follow each round with an
	## adjacent-swap polish; `Average` sweeps key nodes by the mean neighbor
	## position and do not swap. The best ordering seen is kept; the search
	## stops when a round fails to improve it, at zero crossings, or after
	## `rounds`.
	order : List(List(U64)), List({ from : U64, to : U64 }), U64, [Median, Average] -> List(List(U64))
	order = |layers, edges, rounds, method| {
		start = LayeredOrder.flatten(layers, edges)
		shape = start.shape
		outgoing = LayeredRank.adjacency(shape.size, edges, True)
		incoming = LayeredRank.adjacency(shape.size, edges, False)
		var $best_score = LayeredOrder.total_flat(shape, start.order, outgoing, edges)
		var $best = start.order.flat
		var $current = start.order
		var $stalled = False
		var $round = 0
		while $round < rounds and !$stalled and $best_score != 0 {
			down = LayeredOrder.sweep(shape, $current, outgoing, incoming, edges, Down, method)
			up = LayeredOrder.sweep(shape, down, outgoing, incoming, edges, Up, method)
			polished = match method {
				Median => LayeredOrder.transpose(shape, up, outgoing, incoming, edges)
				Average => up
			}
			score = LayeredOrder.total_flat(shape, polished, outgoing, edges)
			if score < $best_score {
				$best = polished.flat
				$best_score = score
			} else {
				$stalled = True
			}
			$current = polished
			$round = $round + 1
		}
		LayeredOrder.unflatten(shape, $best)
	}
}

expect LayeredOrder.sort_by([5, 3, 9, 1, 3], |a, b| a < b) == [1, 3, 3, 5, 9]
expect LayeredOrder.sort_values([4, 1, 4, 0, 2, 7, 1]) == [0, 1, 1, 2, 4, 4, 7]
expect LayeredOrder.sort_values([]) == []

## Stability: equal keys keep their input order.
expect {
	keys = [2, 1, 2, 1, 0]
	LayeredOrder.sort_by([0, 1, 2, 3, 4], |a, b| (keys.get(a) ?? 0) < (keys.get(b) ?? 0)) == [4, 1, 3, 0, 2]
}

expect LayeredOrder.group_by_rank([1, 0, 1, 2, 0]) == [[1, 4], [0, 2], [3]]
expect LayeredOrder.group_by_rank([]) == []

expect LayeredOrder.insert_virtual_chains([0, 2], [{ from: 0, to: 1 }]) == { ranks: [0, 2, 1], unit_edges: [{ from: 0, to: 2 }, { from: 2, to: 1 }], chains: [[0, 2, 1]] }

## Crossings count strict inversions only: a shared endpoint never crosses.
expect LayeredOrder.total_crossings([[0, 1], [2, 3]], [{ from: 0, to: 3 }, { from: 1, to: 2 }]) == 1
expect LayeredOrder.total_crossings([[0, 1], [2, 3]], [{ from: 0, to: 3 }, { from: 1, to: 2 }, { from: 1, to: 3 }, { from: 0, to: 3 }]) == 2
expect LayeredOrder.total_crossings([[0, 1, 2], [3]], [{ from: 0, to: 3 }, { from: 2, to: 3 }]) == 0

expect LayeredOrder.pair_order([1, 3], [0, 2, 3]) == { before: 3, after: 2 }

## Average sweeps key by the mean neighbor position: node 4's neighbors sit
## at positions 0 and 2 (mean 1), node 3's at position 1 (mean 1), so equal
## keys keep their order; node 5 (mean 2) goes last.
expect LayeredOrder.order([[0, 1, 2], [5, 4, 3]], [{ from: 0, to: 4 }, { from: 2, to: 4 }, { from: 1, to: 3 }, { from: 2, to: 5 }], 4, Average) == [[0, 1, 2], [4, 3, 5]]
