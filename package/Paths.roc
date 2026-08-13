## Internal graph-traversal kit shared by the stress, radial, and force
## layouts: BFS hop distances, connected components, and farthest-point
## pivot sampling. Everything is deterministic, flat, and index-addressed —
## adjacency is compressed once at build time and passed to every traversal.
Paths :: {}.{

	## Compressed adjacency in deterministic edge order, both directions,
	## self-loops skipped: `offsets.len()` equals node count plus one, and
	## the neighbors of node `i` are `neighbors[offsets[i] .. offsets[i + 1]]`.
	## (The slot list is named `neighbors` because `targets` is a reserved
	## word in Roc.)
	Adjacency : { offsets : List(U64), neighbors : List(U64) }

	## `[0, 1, .., n - 1]`, the building block for walking a bounded range.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Build compressed adjacency from an edge list in O(n + m). Each kept
	## edge contributes both directions, placed in edge order per endpoint.
	## Self-loops and edges with out-of-range endpoints are skipped
	## defensively so every well-typed input yields a valid structure.
	adjacency : U64, List({ from : U64, to : U64 }) -> Paths.Adjacency
	adjacency = |node_count, edges| {
		kept = edges.fold(
			[],
			|acc, edge| {
				if edge.from < node_count and edge.to < node_count and edge.from != edge.to {
					acc.append(edge)
				} else {
					acc
				}
			},
		)

		degrees = kept.fold(
			List.repeat(0, node_count),
			|acc, edge| {
				from_degree = (acc.get(edge.from) ?? 0) + 1
				bumped = acc.set(edge.from, from_degree) ?? []
				to_degree = (bumped.get(edge.to) ?? 0) + 1
				bumped.set(edge.to, to_degree) ?? []
			},
		)

		offsets = degrees.fold(
			{ list: [0], total: 0 },
			|acc, degree| {
				total = acc.total + degree
				{ list: acc.list.append(total), total: total }
			},
		).list

		# Cursors start at each node's offset and advance as its slots fill.
		start_cursors = Paths.indices_up_to(node_count).map(|i| offsets.get(i) ?? 0)
		total_slots = offsets.get(node_count) ?? 0

		filled = kept.fold(
			{ slots: List.repeat(0, total_slots), cursors: start_cursors },
			|state, edge| {
				from_slot = state.cursors.get(edge.from) ?? 0
				slots_a = state.slots.set(from_slot, edge.to) ?? []
				cursors_a = state.cursors.set(edge.from, from_slot + 1) ?? []
				to_slot = cursors_a.get(edge.to) ?? 0
				slots_b = slots_a.set(to_slot, edge.from) ?? []
				cursors_b = cursors_a.set(edge.to, to_slot + 1) ?? []
				{ slots: slots_b, cursors: cursors_b }
			},
		)

		{ offsets: offsets, neighbors: filled.slots }
	}

	## Node count recovered from the offsets list, tolerating an empty list.
	node_count_of : Paths.Adjacency -> U64
	node_count_of = |adj| {
		if adj.offsets.is_empty() {
			0
		} else {
			adj.offsets.len() - 1
		}
	}

	## The neighbors of one node in deterministic edge order.
	neighbors_of : Paths.Adjacency, U64 -> List(U64)
	neighbors_of = |adj, node| {
		start = adj.offsets.get(node) ?? 0
		stop = adj.offsets.get(node + 1) ?? start
		Paths.indices_up_to(stop - start).map(|j| adj.neighbors.get(start + j) ?? 0)
	}

	## Unweighted hop distance from `source` to every node in O(n + m):
	## `F64.infinity` for unreachable nodes, 0 for the source itself. An
	## out-of-range source yields all infinity.
	bfs_distances : Paths.Adjacency, U64 -> List(F64)
	bfs_distances = |adj, source| {
		node_count = Paths.node_count_of(adj)
		unreached = List.repeat(F64.infinity, node_count)
		if source >= node_count {
			unreached
		} else {
			sentinel = node_count
			entries0 = List.repeat({ distance: F64.infinity, next: sentinel }, node_count)
			var $entries = entries0.set(source, { distance: 0, next: sentinel }) ?? []
			var $current = source
			var $tail = source
			var $done = False
			for _ in Paths.indices_up_to(node_count) {
				if $done == False {
					node = $current
					level = ($entries.get(node) ?? { distance: 0, next: sentinel }).distance + 1
					for neighbor in Paths.neighbors_of(adj, node) {
						if ($entries.get(neighbor) ?? { distance: 0, next: sentinel }).distance == F64.infinity {
							$entries = $entries.set(neighbor, { distance: level, next: sentinel }) ?? []
							tail_entry = $entries.get($tail) ?? { distance: 0, next: sentinel }
							$entries = $entries.set($tail, { ..tail_entry, next: neighbor }) ?? []
							$tail = neighbor
						}
					}
					next = ($entries.get(node) ?? { distance: 0, next: sentinel }).next
					$current = next
					$done = next == sentinel
				}
			}
			$entries.map(|entry| entry.distance)
		}
	}

	## Flood one component label outward from a frontier, marking only
	## nodes still carrying the sentinel. Fuel bounds the recursion by the
	## node count.
	flood_label : Paths.Adjacency, List(U64), List(U64), U64, U64, U64 -> List(U64)
	flood_label = |adj, labels, frontier, label, sentinel, fuel| {
		if frontier.is_empty() or fuel == 0 {
			labels
		} else {
			queue0 = List.repeat(0, fuel)
			seeded_queue = frontier.fold_with_index(queue0, |queue, node, index| queue.set(index, node) ?? [])
			Paths.indices_up_to(fuel).fold(
				{ labels, queue: seeded_queue, tail: frontier.len() },
				|state, cursor| if cursor >= state.tail {
					state
				} else {
					node = state.queue.get(cursor) ?? 0
					Paths.neighbors_of(adj, node).fold(
						state,
						|inner, neighbor| if (inner.labels.get(neighbor) ?? 0) == sentinel {
							{
								labels: inner.labels.set(neighbor, label) ?? [],
								queue: inner.queue.set(inner.tail, neighbor) ?? [],
								tail: inner.tail + 1,
							}
						} else {
							inner
						},
					)
				},
			).labels
		}
	}

	## Connected-component labels under the undirected reading, in O(n + m).
	## Labels are assigned 0, 1, 2, .. in order of each component's lowest
	## node index, so the labeling is deterministic for a given adjacency.
	components : Paths.Adjacency -> { labels : List(U64), count : U64 }
	components = |adj| {
		node_count = Paths.node_count_of(adj)
		# Real labels are always below the component count, which is at
		# most the node count, so the node count itself is a safe sentinel.
		sentinel = node_count
		Paths.indices_up_to(node_count).fold(
			{ labels: List.repeat(sentinel, node_count), count: 0 },
			|state, node| {
				if (state.labels.get(node) ?? 0) != sentinel {
					state
				} else {
					seeded = state.labels.set(node, state.count) ?? state.labels
					{
						labels: Paths.flood_label(adj, seeded, [node], state.count, sentinel, node_count),
						count: state.count + 1,
					}
				}
			},
		)
	}

	## `min(k, node_count)` pivots by farthest-point sampling in
	## O(k * (n + m)). Pivot 0 is node 0 — the design fixes the start for
	## determinism — and each next pivot is the node maximizing its minimum
	## BFS distance to all chosen pivots, ties broken toward the lowest
	## index. Unreachable (infinite) distances count as farthest, so later
	## pivots reach into disconnected components.
	pivots : Paths.Adjacency, U64 -> List(U64)
	pivots = |adj, k| {
		node_count = Paths.node_count_of(adj)
		target = if k < node_count {
			k
		} else {
			node_count
		}
		if target == 0 {
			[]
		} else {
			result = Paths.indices_up_to(target - 1).fold(
				{ chosen: [0], min_distances: Paths.bfs_distances(adj, 0) },
				|state, _| {
					best = state.min_distances.fold_with_index(
						{ index: 0, value: 0 - 1.0 },
						|acc, distance, index| {
							if distance > acc.value {
								{ index: index, value: distance }
							} else {
								acc
							}
						},
					)
					fresh = Paths.bfs_distances(adj, best.index)
					merged = state.min_distances.map_with_index(
						|distance, index| {
							alternative = fresh.get(index) ?? F64.infinity
							if alternative < distance {
								alternative
							} else {
								distance
							}
						},
					)
					{ chosen: state.chosen.append(best.index), min_distances: merged }
				},
			)
			result.chosen
		}
	}
}

## A triangle yields symmetric neighbor lists in edge order.
expect {
	adj = Paths.adjacency(3, [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }])
	adj.offsets == [0, 2, 4, 6]
		and adj.neighbors == [1, 2, 0, 2, 1, 0]
}

## Self-loops are skipped; parallel edges appear twice per endpoint.
expect {
	adj = Paths.adjacency(2, [{ from: 0, to: 0 }, { from: 0, to: 1 }, { from: 0, to: 1 }])
	adj.offsets == [0, 2, 4]
		and adj.neighbors == [1, 1, 0, 0]
}

## Edges with out-of-range endpoints are skipped defensively.
expect {
	adj = Paths.adjacency(2, [{ from: 0, to: 5 }, { from: 7, to: 1 }, { from: 1, to: 0 }])
	adj.offsets == [0, 1, 2]
		and adj.neighbors == [1, 0]
}

## The empty graph builds a valid, empty adjacency.
expect {
	adj = Paths.adjacency(0, [])
	adj.offsets == [0]
		and adj.neighbors == []
			and Paths.bfs_distances(adj, 0) == []
				and Paths.components(adj) == { labels: [], count: 0 }
					and Paths.pivots(adj, 3) == []
}

## BFS on a path graph counts hops from the source.
expect {
	adj = Paths.adjacency(4, [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }])
	Paths.bfs_distances(adj, 0) == [0, 1, 2, 3]
}

## A disconnected node is at infinite distance.
expect {
	adj = Paths.adjacency(3, [{ from: 0, to: 1 }])
	distances = Paths.bfs_distances(adj, 0)
	distances.get(0) == Ok(0)
		and distances.get(1) == Ok(1)
			and distances.get(2) == Ok(F64.infinity)
}

## An out-of-range source yields all infinity.
expect {
	adj = Paths.adjacency(2, [{ from: 0, to: 1 }])
	Paths.bfs_distances(adj, 9) == [F64.infinity, F64.infinity]
}

## BFS is deterministic: the same adjacency gives the same distances.
expect {
	adj = Paths.adjacency(4, [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }])
	Paths.bfs_distances(adj, 2) == Paths.bfs_distances(adj, 2)
}

## Two triangles and an isolated node form three components, labeled in
## order of each component's lowest node index.
expect {
	edges = [
		{ from: 0, to: 1 },
		{ from: 1, to: 2 },
		{ from: 2, to: 0 },
		{ from: 4, to: 5 },
		{ from: 5, to: 6 },
		{ from: 6, to: 4 },
	]
	adj = Paths.adjacency(7, edges)
	Paths.components(adj) == { labels: [0, 0, 0, 1, 2, 2, 2], count: 3 }
}

## Farthest-point sampling on a path graph picks the far end second.
expect {
	adj = Paths.adjacency(5, [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }])
	Paths.pivots(adj, 2) == [0, 4]
}

## Requesting more pivots than nodes returns one pivot per node, and zero
## pivots returns none.
expect {
	adj = Paths.adjacency(3, [{ from: 0, to: 1 }, { from: 1, to: 2 }])
	Paths.pivots(adj, 10).len() == 3
		and Paths.pivots(adj, 0) == []
}

## On a disconnected graph the second pivot lands in the unreachable
## component, because infinite min-distance counts as farthest.
expect {
	adj = Paths.adjacency(4, [{ from: 0, to: 1 }, { from: 2, to: 3 }])
	Paths.pivots(adj, 2) == [0, 2]
}

## Pivot selection is deterministic, with ties toward the lowest index.
expect {
	adj = Paths.adjacency(3, [{ from: 0, to: 1 }, { from: 0, to: 2 }])
	Paths.pivots(adj, 2) == Paths.pivots(adj, 2)
		and Paths.pivots(adj, 2) == [0, 1]
}
