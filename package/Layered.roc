import Geom

## Layered layouts for directed graphs read as flow — a complete
## Sugiyama-style pipeline: break cycles with a greedy vertex-ordering
## heuristic that preserves the caller's acyclic structure, rank nodes to the
## exact minimum total edge span by network simplex, insert virtual chains,
## order layers by scored median sweeps with transpose polishing, assign
## coordinates by the Brandes-Kopf four-alignment median extended for node
## widths, and route edges as lines, polylines, or smooth curve chains whose
## endpoints clip to the node boundaries. A branch-and-bound layer ordering
## with lower-bound pruning under an explicit effort budget backs the exact
## variant of the public API; every other phase is shared with the sweep.
##
## The public API has a build/run witness and reports edges drawn against the
## flow. Each phase below is a pure helper with bounded iteration and
## deterministic tie-breaking, and is independently tested.
LayeredInternals :: {}.{

	## `[0, 1, .., n - 1]`, the shared building block for every phase below
	## that needs to walk a bounded range of indices.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Longest-path-from-sources ranking, the feasible starting point for the
	## exact ranking below. Nodes with no incoming edges rank 0; every other
	## node ranks one more than its deepest predecessor. Iterates to a fixed
	## point, bounded by node count, so cycles cannot hang it (an edge that
	## would push a rank past the bound is simply not applied again).
	longest_path_ranks : U64, List({ from : U64, to : U64 }) -> List(U64)
	longest_path_ranks = |node_count, edges| {
		initial = List.repeat(0, node_count)

		LayeredInternals.indices_up_to(node_count).fold(
			initial,
			|ranks, _pass| {
				edges.fold(
					ranks,
					|acc, edge| {
						if edge.from == edge.to {
							acc
						} else {
							from_rank = acc.get(edge.from) ?? 0
							to_rank = acc.get(edge.to) ?? 0
							wanted = from_rank + 1
							if wanted > to_rank {
								acc.set(edge.to, wanted) ?? acc
							} else {
								acc
							}
						}
					},
				)
			},
		)
	}

	## How many layers an edge could shrink by: rank(to) - rank(from) - 1.
	## Zero means the edge is tight (spans exactly one layer).
	rank_slack : List(I64), { from : U64, to : U64 } -> I64
	rank_slack = |ranks, edge| (ranks.get(edge.to) ?? 0) - (ranks.get(edge.from) ?? 0) - 1

	## The minimum-slack edge with exactly one endpoint inside the growing
	## tight tree, or `None` when no edge touches it. Ties break by lowest
	## edge index, so tree construction is deterministic.
	tightest_incident : List({ from : U64, to : U64 }), List(Bool), List(I64) -> [Some({ index : U64, slack : I64 }), None]
	tightest_incident = |edges, in_tree, ranks|
		edges.fold_with_index(
			None,
			|acc, edge, index| {
				from_in = in_tree.get(edge.from) ?? False
				to_in = in_tree.get(edge.to) ?? False
				if from_in == to_in {
					acc
				} else {
					slack = LayeredInternals.rank_slack(ranks, edge)
					match acc {
						None => Some({ index, slack })
						Some(best) => if slack < best.slack {
							Some({ index, slack })
						} else {
							Some(best)
						}
					}
				}
			},
		)

	## Builds a spanning forest of tight edges (slack 0), one tree per weakly
	## connected component: grow from the lowest unvisited node, and whenever
	## no incident edge is tight, shift the whole partial tree by the minimum
	## incident slack so one becomes tight. Shifting by the minimum keeps every
	## other edge feasible. Returns the adjusted ranks and a per-edge tree flag.
	grow_tight_forest : U64, List({ from : U64, to : U64 }), List(I64) -> { ranks : List(I64), tree_flags : List(Bool) }
	grow_tight_forest = |node_count, edges, init_ranks| {
		empty_flags = List.repeat(False, node_count)

		grown = LayeredInternals.indices_up_to(node_count).fold(
			{ ranks: init_ranks, tree_flags: List.repeat(False, edges.len()), in_forest: empty_flags },
			|state, start| {
				if state.in_forest.get(start) ?? False {
					state
				} else {
					tree = LayeredInternals.indices_up_to(node_count).fold(
						{ ranks: state.ranks, tree_flags: state.tree_flags, cur: empty_flags.set(start, True) ?? empty_flags },
						|inner, _step| {
							match LayeredInternals.tightest_incident(edges, inner.cur, inner.ranks) {
								None => inner
								Some(found) => {
									edge = edges.get(found.index) ?? { from: 0, to: 0 }
									from_in = inner.cur.get(edge.from) ?? False
									delta = if from_in {
										found.slack
									} else {
										0 - found.slack
									}
									shifted = if delta == 0 {
										inner.ranks
									} else {
										inner.ranks.map_with_index(
											|rank, node| if inner.cur.get(node) ?? False {
												rank + delta
											} else {
												rank
											},
										)
									}
									joined = if from_in {
										edge.to
									} else {
										edge.from
									}
									{
										ranks: shifted,
										tree_flags: inner.tree_flags.set(found.index, True) ?? inner.tree_flags,
										cur: inner.cur.set(joined, True) ?? inner.cur,
									}
								}
							}
						},
					)

					{
						ranks: tree.ranks,
						tree_flags: tree.tree_flags,
						in_forest: state.in_forest.map_with_index(|flag, node| flag or (tree.cur.get(node) ?? False)),
					}
				}
			},
		)

		{ ranks: grown.ranks, tree_flags: grown.tree_flags }
	}

	## The nodes on the head side of a tree edge: everything reachable from
	## `start` through tree edges other than the excluded one, ignoring edge
	## direction. Bounded label propagation, node-count passes.
	tree_side : U64, U64, U64, List({ from : U64, to : U64 }), List(Bool) -> List(Bool)
	tree_side = |node_count, start, excluded, edges, tree_flags| {
		empty_flags = List.repeat(False, node_count)
		LayeredInternals.indices_up_to(node_count).fold(
			empty_flags.set(start, True) ?? empty_flags,
			|side, _pass|
				edges.fold_with_index(
					side,
					|acc, edge, index| {
						if (tree_flags.get(index) ?? False) and index != excluded {
							from_in = acc.get(edge.from) ?? False
							to_in = acc.get(edge.to) ?? False
							if from_in and !to_in {
								acc.set(edge.to, True) ?? acc
							} else if to_in and !from_in {
								acc.set(edge.from, True) ?? acc
							} else {
								acc
							}
						} else {
							acc
						}
					},
				),
		)
	}

	## Cut value of a tree edge whose head side is given: edges crossing from
	## the tail side to the head side count plus one, edges crossing back count
	## minus one. A negative total means re-hanging the head side shortens the
	## layout, which is exactly when the simplex loop below pivots.
	cut_value : List({ from : U64, to : U64 }), List(Bool) -> I64
	cut_value = |edges, head_side|
		edges.fold(
			0,
			|acc, edge| {
				from_head = head_side.get(edge.from) ?? False
				to_head = head_side.get(edge.to) ?? False
				if to_head and !from_head {
					acc + 1
				} else if from_head and !to_head {
					acc - 1
				} else {
					acc
				}
			},
		)

	## Network-simplex refinement (Gansner-Koutsofios-North-Vo ranking): while
	## some tree edge has a negative cut value, exchange it for the
	## minimum-slack non-tree edge crossing the cut the other way and shift the
	## head side to keep the entering edge tight. Every exchange keeps the
	## ranking feasible and never lengthens the total span; a hard iteration
	## cap makes termination structural rather than convergence-dependent.
	## Choices scan in ascending edge index, so refinement is deterministic.
	improve_ranks : U64, List({ from : U64, to : U64 }), List(I64), List(Bool) -> List(I64)
	improve_ranks = |node_count, edges, init_ranks, init_tree| {
		pivot_cap = 8 + 4 * (node_count + edges.len())

		LayeredInternals.indices_up_to(pivot_cap).fold(
			{ ranks: init_ranks, tree_flags: init_tree, done: False },
			|state, _pivot| {
				if state.done {
					state
				} else {
					leaving = edges.fold_with_index(
						None,
						|acc, edge, index| {
							match acc {
								Some(found) => Some(found)
								None => if state.tree_flags.get(index) ?? False {
									head_side = LayeredInternals.tree_side(node_count, edge.to, index, edges, state.tree_flags)
									if LayeredInternals.cut_value(edges, head_side) < 0 {
										Some({ index, head_side })
									} else {
										None
									}
								} else {
									None
								}
							}
						},
					)

					match leaving {
						None => { ..state, done: True }
						Some(out_edge) => {
							entering = edges.fold_with_index(
								None,
								|acc, edge, index| {
									in_tree = state.tree_flags.get(index) ?? False
									crosses_back = (out_edge.head_side.get(edge.from) ?? False) and !(out_edge.head_side.get(edge.to) ?? False)
									if in_tree or !crosses_back {
										acc
									} else {
										slack = LayeredInternals.rank_slack(state.ranks, edge)
										match acc {
											None => Some({ index, slack })
											Some(best) => if slack < best.slack {
												Some({ index, slack })
											} else {
												Some(best)
											}
										}
									}
								},
							)

							match entering {
								None => { ..state, done: True }
								Some(in_edge) => {
									swapped = state.tree_flags.set(out_edge.index, False) ?? state.tree_flags
									new_tree = swapped.set(in_edge.index, True) ?? swapped
									new_ranks = if in_edge.slack == 0 {
										state.ranks
									} else {
										state.ranks.map_with_index(
											|rank, node| if out_edge.head_side.get(node) ?? False {
												rank + in_edge.slack
											} else {
												rank
											},
										)
									}
									{ ranks: new_ranks, tree_flags: new_tree, done: False }
								}
							}
						}
					}
				}
			},
		).ranks
	}

	## Shifts each weakly connected component so its lowest rank is 0 and
	## converts back to unsigned layer numbers. Component labels come from
	## bounded min-index propagation over the edges.
	normalize_ranks : U64, List({ from : U64, to : U64 }), List(I64) -> List(U64)
	normalize_ranks = |node_count, edges, ranks| {
		components = LayeredInternals.indices_up_to(node_count).fold(
			LayeredInternals.indices_up_to(node_count),
			|labels, _pass|
				edges.fold(
					labels,
					|acc, edge| {
						from_label = acc.get(edge.from) ?? 0
						to_label = acc.get(edge.to) ?? 0
						low = from_label.min(to_label)
						with_from = acc.set(edge.from, low) ?? acc
						with_from.set(edge.to, low) ?? with_from
					},
				),
		)

		# Slot `label` of the table holds that component's minimum rank; the
		# label node's own rank is a valid starting value because a component's
		# label is always one of its members.
		min_table = ranks.fold_with_index(
			ranks,
			|acc, rank, node| {
				label = components.get(node) ?? 0
				lowest = acc.get(label) ?? 0
				if rank < lowest {
					acc.set(label, rank) ?? acc
				} else {
					acc
				}
			},
		)

		ranks.map_with_index(
			|rank, node| {
				label = components.get(node) ?? 0
				lowest = min_table.get(label) ?? 0
				shifted = rank - lowest
				# Non-negative by construction; the guard keeps the wrapping
				# conversion total even if that invariant were ever broken.
				if shifted < 0 {
					0
				} else {
					shifted.to_u64_wrap()
				}
			},
		)
	}

	## Exact ranking: assign each node an integer layer minimizing the total
	## number of layers all edges span, with every edge spanning at least one
	## layer. Feasible longest-path ranks seed a tight spanning forest, and
	## network-simplex pivots with cut values walk to the optimum (see
	## `improve_ranks`); each component then normalizes to start at layer 0.
	## Self-loops are ignored. Input must be acyclic — `orient_edges` runs
	## first in the pipeline — though bounded iteration keeps even bad input
	## from hanging.
	rank_nodes : U64, List({ from : U64, to : U64 }) -> List(U64)
	rank_nodes = |node_count, edges| {
		if node_count == 0 {
			[]
		} else {
			init = LayeredInternals.longest_path_ranks(node_count, edges).map(|rank| rank.to_i64_wrap())
			spanning_edges = edges.keep_if(|edge| edge.from != edge.to)
			forest = LayeredInternals.grow_tight_forest(node_count, spanning_edges, init)
			refined = LayeredInternals.improve_ranks(node_count, spanning_edges, forest.ranks, forest.tree_flags)
			LayeredInternals.normalize_ranks(node_count, edges, refined)
		}
	}

	## The total number of layers all edges span under a ranking, self-loops
	## ignored — the quantity `rank_nodes` minimizes.
	total_span : List(U64), List({ from : U64, to : U64 }) -> U64
	total_span = |ranks, edges|
		edges.fold(
			0,
			|acc, edge| if edge.from == edge.to {
				acc
			} else {
				acc + (ranks.get(edge.to) ?? 0) - (ranks.get(edge.from) ?? 0)
			},
		)

	## Test oracle only: the smallest total edge span over every rank
	## assignment with ranks below `depth`, or `None` when none is feasible.
	## Exponential enumeration — the expects below run it on tiny graphs to
	## verify that `rank_nodes` is exact.
	brute_force_min_span : U64, U64, List({ from : U64, to : U64 }) -> [Some(U64), None]
	brute_force_min_span = |node_count, depth, edges| {
		combo_count = LayeredInternals.indices_up_to(node_count).fold(1, |acc, _i| acc * depth)

		LayeredInternals.indices_up_to(combo_count).fold(
			None,
			|best, code| {
				ranks = LayeredInternals.indices_up_to(node_count).fold(
					{ rest: code, out: [] },
					|state, _i| { rest: state.rest // depth, out: state.out.append(state.rest % depth) },
				).out
				feasible = edges.all(|edge| edge.from == edge.to or (ranks.get(edge.to) ?? 0) > (ranks.get(edge.from) ?? 0))
				if !feasible {
					best
				} else {
					total = LayeredInternals.total_span(ranks, edges)
					match best {
						None => Some(total)
						Some(low) => if total < low {
							Some(total)
						} else {
							Some(low)
						}
					}
				}
			},
		)
	}

	## Splits every edge spanning more than one rank into a chain of unit-span
	## edges through virtual waypoint nodes (zero size), appended after the
	## real nodes. Returns the extended per-node rank list (real ++ virtual),
	## the unit-span edge list over the extended index space, and — index
	## aligned to the original `edges` list — each original edge's full chain
	## of node indices from `from` to `to` inclusive.
	insert_virtual_chains : List(U64),
	List({ from : U64, to : U64 }) -> {
		ranks : List(U64),
		unit_edges : List({ from : U64, to : U64 }),
		chains : List(List(U64)),
	}
	insert_virtual_chains = |real_ranks, edges| {
		real_count = real_ranks.len()

		result = edges.fold(
			{ ranks: real_ranks, unit_edges: [], chains: [], next_virtual: real_count },
			|state, edge| {
				from_rank = state.ranks.get(edge.from) ?? 0
				to_rank = state.ranks.get(edge.to) ?? 0
				span = if to_rank > from_rank {
					to_rank - from_rank
				} else {
					1
				}

				if span <= 1 {
					{
						ranks: state.ranks,
						unit_edges: state.unit_edges.append(edge),
						chains: state.chains.append([edge.from, edge.to]),
						next_virtual: state.next_virtual,
					}
				} else {
					intermediate_count = span - 1
					virtual_indices = LayeredInternals.indices_up_to(intermediate_count).map(|i| state.next_virtual + i)

					chain = [edge.from].concat(virtual_indices).append(edge.to)

					new_ranks = virtual_indices.fold_with_index(
						state.ranks,
						|acc, _virtual_index, i| acc.append(from_rank + 1 + i),
					)

					new_edges = LayeredInternals.indices_up_to(chain.len() - 1).fold(
						state.unit_edges,
						|acc, i| {
							a = chain.get(i) ?? 0
							b = chain.get(i + 1) ?? 0
							acc.append({ from: a, to: b })
						},
					)

					{
						ranks: new_ranks,
						unit_edges: new_edges,
						chains: state.chains.append(chain),
						next_virtual: state.next_virtual + intermediate_count,
					}
				}
			},
		)

		{ ranks: result.ranks, unit_edges: result.unit_edges, chains: result.chains }
	}

	## Groups node indices by rank, in ascending rank then ascending index
	## order — the deterministic initial ordering before median sweeps run.
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

		LayeredInternals.indices_up_to(layer_count).map(
			|layer| ranks.fold_with_index(
				[],
				|acc, r, i| if r == layer {
					acc.append(i)
				} else {
					acc
				},
			),
		)
	}

	## Position of every node inside one layer, or `None` for nodes that live
	## elsewhere — the lookup table the crossing counter needs.
	layer_positions : U64, List(U64) -> List([Some(U64), None])
	layer_positions = |node_total, layer| {
		base = List.repeat(None, node_total)
		layer.fold_with_index(base, |acc, node, pos| acc.set(node, Some(pos)) ?? acc)
	}

	## Counts edge crossings between one adjacent layer pair: two edges from
	## `upper` to `lower` cross exactly when their endpoint orders invert.
	## O(e^2) over the bilayer's edges — deterministic and cheap at this scale.
	crossings_between : U64, List(U64), List(U64), List({ from : U64, to : U64 }) -> U64
	crossings_between = |node_total, upper, lower, unit_edges| {
		upper_pos = LayeredInternals.layer_positions(node_total, upper)
		lower_pos = LayeredInternals.layer_positions(node_total, lower)

		pairs = unit_edges.fold(
			[],
			|acc, edge|
				match upper_pos.get(edge.from) ?? None {
					None => acc
					Some(a) =>
						match lower_pos.get(edge.to) ?? None {
							None => acc
							Some(b) => acc.append({ a, b })
						}
					},
		)

		pairs.fold_with_index(
			0,
			|acc, p, i|
				pairs.drop_first(i + 1).fold(
					acc,
					|inner, q| if (p.a < q.a and p.b > q.b) or (p.a > q.a and p.b < q.b) {
						inner + 1
					} else {
						inner
					},
				),
		)
	}

	## Total crossings of a complete ordering — the score the ordering phase
	## minimizes and reports its best against.
	total_crossings : U64, List(List(U64)), List({ from : U64, to : U64 }) -> U64
	total_crossings = |node_total, layers, unit_edges| {
		if layers.len() < 2 {
			0
		} else {
			LayeredInternals.indices_up_to(layers.len() - 1).fold(
				0,
				|acc, i| acc + LayeredInternals.crossings_between(node_total, layers.get(i) ?? [], layers.get(i + 1) ?? [], unit_edges),
			)
		}
	}

	## One left-to-right adjacent-swap sweep over a single layer: each swap is
	## kept only when it strictly reduces the layer's crossings counted against
	## both neighboring layers together. Pass an empty list for a missing
	## neighbor.
	transpose_layer : U64, List(U64), List(U64), List(U64), List({ from : U64, to : U64 }) -> List(U64)
	transpose_layer = |node_total, above, layer, below, unit_edges| {
		if layer.len() < 2 {
			layer
		} else {
			LayeredInternals.indices_up_to(layer.len() - 1).fold(
				layer,
				|cur, p| {
					u = cur.get(p) ?? 0
					v = cur.get(p + 1) ?? 0
					with_v = cur.set(p, v) ?? cur
					swapped = with_v.set(p + 1, u) ?? with_v
					before = LayeredInternals.crossings_between(node_total, above, cur, unit_edges)
						+ LayeredInternals.crossings_between(node_total, cur, below, unit_edges)
					after = LayeredInternals.crossings_between(node_total, above, swapped, unit_edges)
						+ LayeredInternals.crossings_between(node_total, swapped, below, unit_edges)
					if after < before {
						swapped
					} else {
						cur
					}
				},
			)
		}
	}

	## Adjacent-swap polish over every layer, top to bottom — the transpose
	## step that mops up crossings the independent median assignments leave
	## behind (equal medians are common, and the median never weighs both
	## neighbor layers at once).
	transpose_pass : U64, List(List(U64)), List({ from : U64, to : U64 }) -> List(List(U64))
	transpose_pass = |node_total, layers, unit_edges|
		LayeredInternals.indices_up_to(layers.len()).fold(
			layers,
			|acc, i| {
				above = if i == 0 {
					[]
				} else {
					acc.get(i - 1) ?? []
				}
				layer = acc.get(i) ?? []
				below = acc.get(i + 1) ?? []
				acc.set(i, LayeredInternals.transpose_layer(node_total, above, layer, below, unit_edges)) ?? acc
			},
		)

	## Orders every layer to reduce edge crossings: rounds of a down then up
	## median sweep followed by an adjacent-swap transpose polish, each round
	## scored by total crossings. The best-scoring ordering seen is kept, and
	## the search stops early when a round fails to improve it, at a perfect
	## score of zero, or at the round cap. Every choice inside is
	## deterministic, so the result is too.
	order_layers : List(List(U64)), List({ from : U64, to : U64 }) -> List(List(U64))
	order_layers = |layers, unit_edges| {
		rounds = 4
		node_total = layers.fold(0, |acc, layer| acc + layer.len())
		initial_score = LayeredInternals.total_crossings(node_total, layers, unit_edges)

		LayeredInternals.indices_up_to(rounds).fold(
			{ current: layers, best: layers, best_score: initial_score, stalled: False },
			|state, _round| {
				if state.stalled or state.best_score == 0 {
					state
				} else {
					down = LayeredInternals.sweep_median(state.current, unit_edges, Down)
					up = LayeredInternals.sweep_median(down, unit_edges, Up)
					polished = LayeredInternals.transpose_pass(node_total, up, unit_edges)
					score = LayeredInternals.total_crossings(node_total, polished, unit_edges)
					if score < state.best_score {
						{ current: polished, best: polished, best_score: score, stalled: False }
					} else {
						{ ..state, current: polished, stalled: True }
					}
				}
			},
		).best
	}

	## Deterministic ascending copy of one layer's node indices — the
	## canonical first permutation, so the exact search below enumerates each
	## layer's orderings in lexicographic index order.
	ascending_indices : List(U64) -> List(U64)
	ascending_indices = |values|
		values.sort_with(
			|a, b| if a < b {
				LT
			} else if a > b {
				GT
			} else {
				EQ
			},
		)

	## Exact crossing minimization by branch and bound: minimizes the total
	## number of edge crossings between adjacent layers over every per-layer
	## ordering. The scored sweep above provides the incumbent ordering and
	## its crossing count; layers are then fixed top to bottom, each layer's
	## permutations enumerated lexicographically over node indices, and a
	## branch is pruned once the crossings among its fully fixed layer pairs
	## reach the incumbent's count. Every permutation step tried spends one
	## unit of `effort_cap`, so a cap of 0 returns the sweep's ordering
	## unsearched. `proven_optimal` is `True` when the search space was
	## exhausted within the cap or the best ordering reached zero crossings
	## (trivially optimal), and `False` when the cap ended the search first —
	## the best ordering seen, never worse than the sweep's, is still
	## returned. Fixed enumeration order and no randomness keep the search
	## deterministic.
	exact_order_layers : List(List(U64)), List({ from : U64, to : U64 }), U64 -> { layers : List(List(U64)), proven_optimal : Bool }
	exact_order_layers = |layers, unit_edges, effort_cap| {
		node_total = layers.fold(0, |acc, layer| acc + layer.len())
		incumbent = LayeredInternals.order_layers(layers, unit_edges)
		incumbent_cost = LayeredInternals.total_crossings(node_total, incumbent, unit_edges)

		searched = LayeredInternals.search_layer(
			node_total,
			unit_edges,
			layers,
			0,
			[],
			0,
			{ effort_left: effort_cap, capped: False, best_layers: incumbent, best_cost: incumbent_cost },
		)

		{ layers: searched.best_layers, proven_optimal: searched.best_cost == 0 or !searched.capped }
	}

	## One layer of the branch-and-bound search: abandon the branch when the
	## budget is already spent, the incumbent is already perfect, or the fixed
	## pairs' crossings reach the incumbent's count; adopt a completed
	## ordering (all layers fixed) as the new incumbent; otherwise permute the
	## next layer's nodes.
	search_layer : U64, List({ from : U64, to : U64 }), List(List(U64)), U64, List(List(U64)), U64, { effort_left : U64, capped : Bool, best_layers : List(List(U64)), best_cost : U64 } -> { effort_left : U64, capped : Bool, best_layers : List(List(U64)), best_cost : U64 }
	search_layer = |node_total, unit_edges, layers, depth, fixed, cost, state| {
		if state.capped or state.best_cost == 0 or cost >= state.best_cost {
			state
		} else if depth == layers.len() {
			{ ..state, best_layers: fixed, best_cost: cost }
		} else {
			LayeredInternals.search_permutations(
				node_total,
				unit_edges,
				layers,
				depth,
				fixed,
				cost,
				[],
				LayeredInternals.ascending_indices(layers.get(depth) ?? []),
				state,
			)
		}
	}

	## Lexicographic permutation enumeration for one layer, recursing on the
	## list of remaining choices: each choice expanded spends one unit of
	## effort (checked before every expansion, so exhaustion stops the search
	## mid-layer), and a finished permutation adds its crossings against the
	## layer fixed above it before the search descends to the next layer.
	search_permutations : U64, List({ from : U64, to : U64 }), List(List(U64)), U64, List(List(U64)), U64, List(U64), List(U64), { effort_left : U64, capped : Bool, best_layers : List(List(U64)), best_cost : U64 } -> { effort_left : U64, capped : Bool, best_layers : List(List(U64)), best_cost : U64 }
	search_permutations = |node_total, unit_edges, layers, depth, fixed, cost, prefix, remaining, state| {
		if state.capped or state.best_cost == 0 {
			state
		} else if remaining.is_empty() {
			pair_cost = if depth == 0 {
				0
			} else {
				LayeredInternals.crossings_between(node_total, fixed.get(depth - 1) ?? [], prefix, unit_edges)
			}
			LayeredInternals.search_layer(node_total, unit_edges, layers, depth + 1, fixed.append(prefix), cost + pair_cost, state)
		} else {
			remaining.fold_with_index(
				state,
				|acc, choice, i| {
					if acc.capped or acc.best_cost == 0 {
						acc
					} else if acc.effort_left == 0 {
						{ ..acc, capped: True }
					} else {
						LayeredInternals.search_permutations(
							node_total,
							unit_edges,
							layers,
							depth,
							fixed,
							cost,
							prefix.append(choice),
							remaining.take_first(i).concat(remaining.drop_first(i + 1)),
							{ ..acc, effort_left: acc.effort_left - 1 },
						)
					}
				},
			)
		}
	}

	## One median sweep: reorders every layer but the first by the median
	## position of its neighbors in the previous layer (`Down`), or every
	## layer but the last by the median position in the next layer (`Up`).
	## Ties break by current position, then node index, so a sweep is
	## deterministic and leaves tied nodes where they are.
	sweep_median : List(List(U64)), List({ from : U64, to : U64 }), [Down, Up] -> List(List(U64))
	sweep_median = |layers, unit_edges, direction| {
		layer_count = layers.len()
		ordered_indices = match direction {
			Down => LayeredInternals.indices_up_to(layer_count)
			Up => LayeredInternals.indices_up_to(layer_count).rev()
		}

		ordered_indices.fold(
			layers,
			|acc, layer_index| {
				neighbor_index = match direction {
					Down => if layer_index == 0 {
						Err({})
					} else {
						Ok(layer_index - 1)
					}
					Up => if layer_index + 1 == layer_count {
						Err({})
					} else {
						Ok(layer_index + 1)
					}
				}

				match neighbor_index {
					Err({}) => acc
					Ok(n_idx) => {
						neighbor_layer = acc.get(n_idx) ?? []
						neighbor_pos = LayeredInternals.index_positions(neighbor_layer)
						current_layer = acc.get(layer_index) ?? []

						old_positions = LayeredInternals.index_positions(current_layer)

						scored = current_layer.map_with_index(
							|node, pos| {
								medians = match direction {
									Down => unit_edges.keep_if(|e| e.to == node).keep_oks(|e| neighbor_pos.get(e.from))
									Up => unit_edges.keep_if(|e| e.from == node).keep_oks(|e| neighbor_pos.get(e.to))
								}
								fallback = (old_positions.get(node) ?? 0).to_f64()
								key = match LayeredInternals.median_of(medians) {
									Some(m) => m
									None => fallback
								}
								{ node, pos, key }
							},
						)

						reordered = scored.sort_with(
							|a, b|
								if a.key < b.key {
									LT
								} else if a.key > b.key {
									GT
								} else if a.pos < b.pos {
									LT
								} else if a.pos > b.pos {
									GT
								} else if a.node < b.node {
									LT
								} else if a.node > b.node {
									GT
								} else {
									EQ
								},
						).map(|s| s.node)

						acc.set(layer_index, reordered) ?? acc
					}
				}
			},
		)
	}

	index_positions : List(U64) -> List(U64)
	index_positions = |layer| {
		max_index = layer.fold(
			0,
			|acc, n| if n > acc {
				n
			} else {
				acc
			},
		)
		table = List.repeat(0, max_index + 1)
		layer.fold_with_index(table, |acc, node, pos| acc.set(node, pos) ?? acc)
	}

	median_of : List(U64) -> [Some(F64), None]
	median_of = |values| {
		if values.is_empty() {
			None
		} else {
			sorted = values.sort_with(
				|a, b| if a < b {
					LT
				} else if a > b {
					GT
				} else {
					EQ
				},
			)
			n = sorted.len()
			mid = n // 2
			if n % 2 == 1 {
				Some((sorted.get(mid) ?? 0).to_f64())
			} else {
				lo = (sorted.get(mid - 1) ?? 0).to_f64()
				hi = (sorted.get(mid) ?? 0).to_f64()
				Some((lo + hi) / 2)
			}
		}
	}

	layer_max_height : List(U64), List(F64) -> F64
	layer_max_height = |layer, heights|
		layer.fold(
			0,
			|acc, node| {
				h = heights.get(node) ?? 0
				if h > acc {
					h
				} else {
					acc
				}
			},
		)

	## Type-1 conflicts for the alignment passes: ordinary segments that cross
	## an inner segment (one joining two virtual waypoints of a long edge).
	## Inner segments must run straight, so alignment refuses to align across
	## a marked segment. Returns the conflicting `{ upper, lower }` node pairs
	## for the given layer orders.
	mark_conflicts : U64, List(List(U64)), U64, List({ from : U64, to : U64 }) -> List({ upper : U64, lower : U64 })
	mark_conflicts = |node_total, layers, real_count, unit_edges| {
		if layers.len() < 2 {
			[]
		} else {
			LayeredInternals.indices_up_to(layers.len() - 1).fold(
				[],
				|acc, i| {
					upper_pos = LayeredInternals.layer_positions(node_total, layers.get(i) ?? [])
					lower_pos = LayeredInternals.layer_positions(node_total, layers.get(i + 1) ?? [])

					segments = unit_edges.fold(
						[],
						|segs, edge| {
							ends = match upper_pos.get(edge.from) ?? None {
								Some(up) =>
									match lower_pos.get(edge.to) ?? None {
										Some(lp) => Some({ upper: edge.from, up, lower: edge.to, lp })
										None => None
									}
								None =>
									match upper_pos.get(edge.to) ?? None {
										Some(up) =>
											match lower_pos.get(edge.from) ?? None {
												Some(lp) => Some({ upper: edge.to, up, lower: edge.from, lp })
												None => None
											}
										None => None
									}
								}
							match ends {
								None => segs
								Some(seg) =>
									segs.append({
										upper: seg.upper,
										up: seg.up,
										lower: seg.lower,
										lp: seg.lp,
										inner: seg.upper >= real_count and seg.lower >= real_count,
									})
								}
						},
					)

					segments.fold(
						acc,
						|found, seg| {
							crosses_inner = segments.count_if(
								|other| other.inner and ((seg.up < other.up and seg.lp > other.lp) or (seg.up > other.up and seg.lp < other.lp)),
							)
							if !seg.inner and crosses_inner > 0 {
								found.append({ upper: seg.upper, lower: seg.lower })
							} else {
								found
							}
						},
					)
				},
			)
		}
	}

	## Nodes in the previous layer adjacent to `v` through any unit edge, in
	## left-to-right position order — the neighbor list whose median the
	## alignment passes follow.
	upper_neighbors : List(U64), U64, List({ from : U64, to : U64 }) -> List({ node : U64, pos : U64 })
	upper_neighbors = |upper_layer, v, unit_edges|
		upper_layer.fold_with_index(
			[],
			|acc, u, pos| {
				connected = unit_edges.count_if(|e| (e.from == u and e.to == v) or (e.from == v and e.to == u))
				if connected > 0 {
					acc.append({ node: u, pos })
				} else {
					acc
				}
			},
		)

	## One Brandes-Kopf vertical alignment in transformed space: layers arrive
	## top to bottom with nodes ordered left to right for the favored corner.
	## Each node aligns to the median of its upper neighbors when that segment
	## is unmarked and alignment stays left-to-right monotone within the
	## layer, chaining nodes into vertical blocks. Returns each node's block
	## root (the block's topmost node in transformed space).
	block_roots : U64, List(List(U64)), U64, List({ from : U64, to : U64 }) -> List(U64)
	block_roots = |node_total, layers, real_count, unit_edges| {
		marked = LayeredInternals.mark_conflicts(node_total, layers, real_count, unit_edges)
		identity = LayeredInternals.indices_up_to(node_total)

		LayeredInternals.indices_up_to(layers.len()).fold(
			{ root: identity, align: identity },
			|state, layer_index| {
				if layer_index == 0 {
					state
				} else {
					upper_layer = layers.get(layer_index - 1) ?? []
					layer = layers.get(layer_index) ?? []

					aligned = layer.fold(
						{ root: state.root, align: state.align, r: None },
						|ls, v| {
							nbrs = LayeredInternals.upper_neighbors(upper_layer, v, unit_edges)
							if nbrs.is_empty() {
								ls
							} else {
								d = nbrs.len()
								[(d - 1) // 2, d // 2].fold(
									ls,
									|ms, m| {
										if (ms.align.get(v) ?? v) != v {
											ms
										} else {
											nbr = nbrs.get(m) ?? { node: 0, pos: 0 }
											is_marked = marked.count_if(|c| c.upper == nbr.node and c.lower == v) > 0
											monotone = match ms.r {
												None => True
												Some(taken) => taken < nbr.pos
											}
											if is_marked or !monotone {
												ms
											} else {
												with_u = ms.align.set(nbr.node, v) ?? ms.align
												block = ms.root.get(nbr.node) ?? nbr.node
												{
													root: ms.root.set(v, block) ?? ms.root,
													align: with_u.set(v, block) ?? with_u,
													r: Some(nbr.pos),
												}
											}
										}
									},
								)
							}
						},
					)

					{ root: aligned.root, align: aligned.align }
				}
			},
		).root
	}

	## Left-compacts one alignment: every block sits as far left as the
	## separation constraints between horizontally adjacent nodes allow —
	## centers at least (width_u + width_v) / 2 + node_gap apart — via
	## bounded longest-path relaxation over the block ordering, which is
	## acyclic because aligned blocks never cross.
	compact_blocks : U64, List(List(U64)), List(U64), List(F64), F64 -> List(F64)
	compact_blocks = |node_total, layers, roots, widths, node_gap| {
		constraints = layers.fold(
			[],
			|acc, layer| {
				if layer.len() < 2 {
					acc
				} else {
					LayeredInternals.indices_up_to(layer.len() - 1).fold(
						acc,
						|cs, p| {
							u = layer.get(p) ?? 0
							v = layer.get(p + 1) ?? 0
							sep = ((widths.get(u) ?? 0) + (widths.get(v) ?? 0)) / 2 + node_gap
							cs.append({ left: roots.get(u) ?? u, right: roots.get(v) ?? v, sep })
						},
					)
				}
			},
		)

		block_x = LayeredInternals.indices_up_to(node_total).fold(
			List.repeat(0, node_total),
			|xs, _pass|
				constraints.fold(
					xs,
					|acc, c| {
						pushed = (acc.get(c.left) ?? 0) + c.sep
						if pushed > (acc.get(c.right) ?? 0) {
							acc.set(c.right, pushed) ?? acc
						} else {
							acc
						}
					},
				),
		)

		LayeredInternals.indices_up_to(node_total).map(|v| block_x.get(roots.get(v) ?? v) ?? 0)
	}

	## One of the four alignment candidates. Mirrored layer orders reuse the
	## same upper-left core: reversing each layer favors the right corner
	## (flip x back by negation), reversing the layer list favors the lower
	## one.
	alignment_candidate : U64, List(List(U64)), U64, List({ from : U64, to : U64 }), List(F64), F64, [UpperLeft, UpperRight, LowerLeft, LowerRight] -> List(F64)
	alignment_candidate = |node_total, layers, real_count, unit_edges, widths, node_gap, corner| {
		transformed = match corner {
			UpperLeft => layers
			UpperRight => layers.map(|layer| layer.rev())
			LowerLeft => layers.rev()
			LowerRight => layers.rev().map(|layer| layer.rev())
		}
		roots = LayeredInternals.block_roots(node_total, transformed, real_count, unit_edges)
		xs = LayeredInternals.compact_blocks(node_total, transformed, roots, widths, node_gap)
		match corner {
			UpperLeft => xs
			LowerLeft => xs
			UpperRight => xs.map(|x| 0 - x)
			LowerRight => xs.map(|x| 0 - x)
		}
	}

	## Horizontal extent of a candidate assignment, node widths included.
	candidate_extent : U64, List(F64), List(F64) -> { lo : F64, hi : F64 }
	candidate_extent = |node_total, xs, widths|
		match LayeredInternals.indices_up_to(node_total).fold(
			None,
			|acc, v| {
				x = xs.get(v) ?? 0
				w = widths.get(v) ?? 0
				left = x - w / 2
				right = x + w / 2
				match acc {
					None => Some({ lo: left, hi: right })
					Some(e) => Some({ lo: e.lo.min(left), hi: e.hi.max(right) })
				}
			},
		) {
			None => { lo: 0, hi: 0 }
			Some(extent) => extent
		}

	## Balanced per-node median of the four alignment candidates: candidates
	## align on the narrowest one — left-favoring candidates by left edge,
	## right-favoring by right edge — then every node takes the average of
	## its two middle values. Separation survives the median because every
	## candidate satisfies it.
	balanced_median_x : U64, List(List(U64)), U64, List({ from : U64, to : U64 }), List(F64), F64 -> List(F64)
	balanced_median_x = |node_total, layers, real_count, unit_edges, widths, node_gap| {
		ul = LayeredInternals.alignment_candidate(node_total, layers, real_count, unit_edges, widths, node_gap, UpperLeft)
		ur = LayeredInternals.alignment_candidate(node_total, layers, real_count, unit_edges, widths, node_gap, UpperRight)
		ll = LayeredInternals.alignment_candidate(node_total, layers, real_count, unit_edges, widths, node_gap, LowerLeft)
		lr = LayeredInternals.alignment_candidate(node_total, layers, real_count, unit_edges, widths, node_gap, LowerRight)

		extents = [ul, ur, ll, lr].map(|xs| LayeredInternals.candidate_extent(node_total, xs, widths))
		first_extent = extents.get(0) ?? { lo: 0, hi: 0 }
		narrowest = extents.fold_with_index(
			{ index: 0, width: first_extent.hi - first_extent.lo },
			|acc, extent, i| {
				width = extent.hi - extent.lo
				if width < acc.width {
					{ index: i, width }
				} else {
					acc
				}
			},
		)
		target = extents.get(narrowest.index) ?? { lo: 0, hi: 0 }

		shifts = extents.map_with_index(
			|extent, i| if i == 0 or i == 2 {
				target.lo - extent.lo
			} else {
				target.hi - extent.hi
			},
		)

		LayeredInternals.indices_up_to(node_total).map(
			|v| {
				values = [ul, ur, ll, lr].map_with_index(|xs, i| (xs.get(v) ?? 0) + (shifts.get(i) ?? 0))
				sorted = values.sort_with(
					|a, b| if a < b {
						LT
					} else if a > b {
						GT
					} else {
						EQ
					},
				)
				((sorted.get(1) ?? 0) + (sorted.get(2) ?? 0)) / 2
			},
		)
	}

	## Brandes-Kopf coordinate assignment, extended for real node widths:
	## mark type-1 conflicts, run the four direction-favoring alignment and
	## compaction passes, take the balanced per-node median, then shift so the
	## leftmost node box starts at x = 0. Layer tops stack by cumulative
	## per-layer maximum height plus `layer_gap`, exactly as before. Chains of
	## virtual waypoints align vertically, so long edges run straight.
	assign_coordinates : List(List(U64)), List({ from : U64, to : U64 }), U64, List(F64), List(F64), F64, F64 -> List({ x : F64, y : F64 })
	assign_coordinates = |layers, unit_edges, real_count, widths, heights, node_gap, layer_gap| {
		node_total = widths.len()
		xs = LayeredInternals.balanced_median_x(node_total, layers, real_count, unit_edges, widths, node_gap)
		left_edge = LayeredInternals.candidate_extent(node_total, xs, widths).lo
		positions = List.repeat(Geom.point(0, 0), node_total)

		layers.fold(
			{ positions, y_cursor: 0 },
			|state, layer| {
				max_height = LayeredInternals.layer_max_height(layer, heights)
				placed = layer.fold(
					state.positions,
					|acc, node| {
						x = (xs.get(node) ?? 0) - left_edge
						h = heights.get(node) ?? 0
						acc.set(node, Geom.point(x, state.y_cursor + h / 2)) ?? acc
					},
				)

				{ positions: placed, y_cursor: state.y_cursor + max_height + layer_gap }
			},
		).positions
	}

	distance : { x : F64, y : F64 }, { x : F64, y : F64 } -> F64
	distance = |a, b| {
		dx = b.x - a.x
		dy = b.y - a.y
		(dx * dx + dy * dy).sqrt()
	}

	## Clips a source-to-target point list's two endpoints to the source and
	## target node boxes, so arrowheads land on the boundary rather than
	## inside it. Interior waypoints are untouched; a route shorter than two
	## points passes through unchanged.
	clip_route_ends : List({ x : F64, y : F64 }), { width : F64, height : F64 }, { width : F64, height : F64 } -> List({ x : F64, y : F64 })
	clip_route_ends = |points, source_size, target_size| {
		count = points.len()
		if count < 2 {
			points
		} else {
			first = points.get(0) ?? Geom.point(0, 0)
			second = points.get(1) ?? Geom.point(0, 0)
			second_last = points.get(count - 2) ?? Geom.point(0, 0)
			last = points.get(count - 1) ?? Geom.point(0, 0)

			clipped_first = Geom.clip_to_node(first, source_size, second)
			clipped_last = Geom.clip_to_node(last, target_size, second_last)

			with_first = points.set(0, clipped_first) ?? points
			with_first.set(count - 1, clipped_last) ?? with_first
		}
	}

	## One tangent vector per point of a smooth curve through `points`: an
	## interior tangent follows the direction between its two neighbors,
	## scaled to a third of the shorter adjacent segment (so the curve never
	## overshoots past a neighboring waypoint); an endpoint tangent follows
	## its one adjacent segment, scaled to a third of that segment's length.
	## Coincident points produce a zero tangent, keeping the curve finite.
	curve_tangents : List({ x : F64, y : F64 }) -> List({ x : F64, y : F64 })
	curve_tangents = |points| {
		count = points.len()
		if count < 2 {
			points.map(|_point| Geom.point(0, 0))
		} else {
			points.map_with_index(
				|point, i| {
					if i == 0 {
						next = points.get(1) ?? point
						Geom.point((next.x - point.x) / 3, (next.y - point.y) / 3)
					} else if i == count - 1 {
						prev = points.get(i - 1) ?? point
						Geom.point((point.x - prev.x) / 3, (point.y - prev.y) / 3)
					} else {
						prev = points.get(i - 1) ?? point
						next = points.get(i + 1) ?? point
						dx = next.x - prev.x
						dy = next.y - prev.y
						len = (dx * dx + dy * dy).sqrt()
						if len == 0 {
							Geom.point(0, 0)
						} else {
							scale = LayeredInternals.distance(prev, point).min(LayeredInternals.distance(point, next)) / 3
							Geom.point(dx / len * scale, dy / len * scale)
						}
					}
				},
			)
		}
	}

	## A cubic segment per consecutive point pair, control points one tangent
	## along from each end — a deterministic smooth path through every
	## waypoint.
	curve_through : List({ x : F64, y : F64 }) -> List(
		{
			from : { x : F64, y : F64 },
			ctl_a : { x : F64, y : F64 },
			ctl_b : { x : F64, y : F64 },
			to : { x : F64, y : F64 },
		},
	)
	curve_through = |points| {
		tangents = LayeredInternals.curve_tangents(points)
		segment_count = if points.len() < 2 {
			0
		} else {
			points.len() - 1
		}

		LayeredInternals.indices_up_to(segment_count).map(
			|i| {
				from = points.get(i) ?? Geom.point(0, 0)
				to = points.get(i + 1) ?? Geom.point(0, 0)
				from_tangent = tangents.get(i) ?? Geom.point(0, 0)
				to_tangent = tangents.get(i + 1) ?? Geom.point(0, 0)
				{
					from,
					ctl_a: Geom.point(from.x + from_tangent.x, from.y + from_tangent.y),
					ctl_b: Geom.point(to.x - to_tangent.x, to.y - to_tangent.y),
					to,
				}
			},
		)
	}

	## Builds one route from an already clipped source-to-target point list.
	## Two points always draw a straight `Line`; longer chains keep their
	## bends as a `Polyline` or smooth them into a `Curves` chain, per the
	## requested style.
	make_route : List({ x : F64, y : F64 }), [Straight, Curved] -> Geom.Route
	make_route = |points, route_style|
		match points {
			[a, b] => Line(a, b)
			_ =>
				match route_style {
					Straight => Polyline(points)
					Curved => Curves(LayeredInternals.curve_through(points))
				}
			}

	## Every point a route can reach, control points included — the set a
	## bounding box must cover.
	route_extent_points : Geom.Route -> List({ x : F64, y : F64 })
	route_extent_points = |route|
		match route {
			Line(a, b) => [a, b]
			Polyline(points) => points
			Curves(segments) =>
				segments.fold(
					[],
					|acc, segment| acc.append(segment.from).append(segment.ctl_a).append(segment.ctl_b).append(segment.to),
				)
			}

	translate_route : Geom.Route, F64, F64 -> Geom.Route
	translate_route = |route, dx, dy| {
		shift = |p| Geom.point(p.x + dx, p.y + dy)
		match route {
			Line(a, b) => Line(shift(a), shift(b))
			Polyline(points) => Polyline(points.map(shift))
			Curves(segments) =>
				Curves(
					segments.map(
						|segment| {
							from: shift(segment.from),
							ctl_a: shift(segment.ctl_a),
							ctl_b: shift(segment.ctl_b),
							to: shift(segment.to),
						},
					),
				)
			}
	}

	## Full minimal Sugiyama pipeline: rank, split long edges into virtual
	## chains, order layers by median sweeps, assign coordinates, then route
	## each original edge as a `Line` (unit span) or `Polyline` (through its
	## chain's virtual waypoints). Output `positions`/`routes` are index
	## aligned to the input `nodes`/`edges`; virtual nodes never escape.
	sugiyama : List({ width : F64, height : F64 }),
	List({ from : U64, to : U64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List(Geom.Route),
	}
	sugiyama = |nodes, edges, node_gap, layer_gap| {
		if nodes.is_empty() {
			{ positions: [], bounds: Geom.empty_bounds, routes: [] }
		} else {
			real_ranks = LayeredInternals.rank_nodes(nodes.len(), edges)
			extended = LayeredInternals.insert_virtual_chains(real_ranks, edges)

			virtual_count = extended.ranks.len() - nodes.len()
			widths = nodes.map(|n| n.width).concat(List.repeat(0, virtual_count))
			heights = nodes.map(|n| n.height).concat(List.repeat(0, virtual_count))

			layers = LayeredInternals.group_by_rank(extended.ranks)
			ordered = LayeredInternals.order_layers(layers, extended.unit_edges)
			all_positions = LayeredInternals.assign_coordinates(ordered, extended.unit_edges, nodes.len(), widths, heights, node_gap, layer_gap)

			positions = all_positions.take_first(nodes.len())

			routes = extended.chains.map(
				|chain|
					match chain {
						[a, b] => Line(all_positions.get(a) ?? Geom.point(0, 0), all_positions.get(b) ?? Geom.point(0, 0))
						_ => Polyline(chain.keep_oks(|idx| all_positions.get(idx)))
					},
			)

			max_right = positions.fold_with_index(
				0,
				|acc, p, i| {
					w = (nodes.get(i) ?? { width: 0, height: 0 }).width
					right = p.x + w / 2
					if right > acc {
						right
					} else {
						acc
					}
				},
			)
			max_bottom = positions.fold_with_index(
				0,
				|acc, p, i| {
					h = (nodes.get(i) ?? { width: 0, height: 0 }).height
					bottom = p.y + h / 2
					if bottom > acc {
						bottom
					} else {
						acc
					}
				},
			)

			{
				positions,
				bounds: { ..Geom.empty_bounds, width: max_right, height: max_bottom },
				routes,
			}
		}
	}

	## `Layered.Sweep`: the bounded-effort Sugiyama pipeline above.
	sweep : List({ width : F64, height : F64 }),
	List({ from : U64, to : U64 }),
	F64,
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
		routes : List(Geom.Route),
	}
	sweep = |nodes, edges, node_gap, layer_gap| LayeredInternals.sugiyama(nodes, edges, node_gap, layer_gap)

	## One step of the greedy vertex-ordering below: among the vertices still
	## unplaced, find the first sink (no outgoing edge to another unplaced
	## vertex), the first source (no incoming edge), and the vertex whose
	## outdegree-minus-indegree is largest. Self-loops never count toward
	## degrees. All ties break toward the lowest vertex index because the scan
	## ascends and only strict improvements replace the incumbent.
	ordering_candidates : U64,
	List({ from : U64, to : U64 }),
	List(Bool) -> {
		sink : [Some(U64), None],
		source : [Some(U64), None],
		best : [Some({ vertex : U64, score : I64 }), None],
	}
	ordering_candidates = |node_count, edges, remaining|
		LayeredInternals.indices_up_to(node_count).fold(
			{ sink: None, source: None, best: None },
			|acc, v| {
				if !(remaining.get(v) ?? False) {
					acc
				} else {
					outdeg = edges.count_if(|e| e.from == v and e.to != v and (remaining.get(e.to) ?? False))
					indeg = edges.count_if(|e| e.to == v and e.from != v and (remaining.get(e.from) ?? False))
					score = outdeg.to_i64_wrap() - indeg.to_i64_wrap()

					{
						sink: match acc.sink {
							Some(s) => Some(s)
							None => if outdeg == 0 {
								Some(v)
							} else {
								None
							}
						},
						source: match acc.source {
							Some(s) => Some(s)
							None => if indeg == 0 {
								Some(v)
							} else {
								None
							}
						},
						best: match acc.best {
							Some(b) => if score > b.score {
								Some({ vertex: v, score })
							} else {
								Some(b)
							}
							None => Some({ vertex: v, score })
						},
					}
				}
			},
		)

	## Orient every edge forward along a greedy vertex ordering (the
	## Eades-Lin-Smyth feedback-arc heuristic): repeatedly move a sink to the
	## right end of the ordering, else a source to the left end, else the
	## vertex maximizing outdegree minus indegree to the left end; edges that
	## point backward in the finished ordering are reversed. An acyclic graph
	## always yields an ordering with no backward edge — whatever its index
	## order — so callers' orientations survive untouched, and on cyclic
	## graphs fewer than half of all edges are ever reversed. Ties break by
	## lowest vertex index, keeping the orientation deterministic.
	orient_edges : U64,
	List({ from : U64, to : U64 }) -> {
		edges : List({ from : U64, to : U64 }),
		reversed : List(U64),
		reversed_flags : List(Bool),
	}
	orient_edges = |node_count, edges| {
		placed = LayeredInternals.indices_up_to(node_count).fold(
			{ remaining: List.repeat(True, node_count), left: [], right_in_removal_order: [] },
			|state, _step| {
				found = LayeredInternals.ordering_candidates(node_count, edges, state.remaining)
				match found.sink {
					Some(v) => {
						remaining: state.remaining.set(v, False) ?? state.remaining,
						left: state.left,
						right_in_removal_order: state.right_in_removal_order.append(v),
					}
					None =>
						match found.source {
							Some(v) => {
								remaining: state.remaining.set(v, False) ?? state.remaining,
								left: state.left.append(v),
								right_in_removal_order: state.right_in_removal_order,
							}
							None =>
								match found.best {
									Some(b) => {
										remaining: state.remaining.set(b.vertex, False) ?? state.remaining,
										left: state.left.append(b.vertex),
										right_in_removal_order: state.right_in_removal_order,
									}
									None => state
								}
							}
					}
			},
		)

		# Sinks were conceptually prepended to the right-hand sequence, so the
		# removal order reverses into final order.
		ordering = placed.left.concat(placed.right_in_removal_order.rev())
		position_of = LayeredInternals.index_positions(ordering)

		edges.fold_with_index(
			{ edges: [], reversed: [], reversed_flags: [] },
			|state, edge, edge_index| {
				from_pos = position_of.get(edge.from) ?? 0
				to_pos = position_of.get(edge.to) ?? 0
				is_reversed = from_pos > to_pos
				oriented = if is_reversed {
					{ from: edge.to, to: edge.from }
				} else {
					edge
				}
				{
					edges: state.edges.append(oriented),
					reversed: if is_reversed {
						state.reversed.append(edge_index)
					} else {
						state.reversed
					},
					reversed_flags: state.reversed_flags.append(is_reversed),
				}
			},
		)
	}

	## Everything downstream of layer ordering, shared by the sweep and exact
	## witnesses: assign coordinates to the ordered layers, route every
	## original edge through its chain (re-reversing routes for edges drawn
	## against the flow), and normalize positions, routes, and bounds so the
	## drawing starts at the origin.
	finish_layout : {
		nodes : List({ width : F64, height : F64 }),
		edges : List({ from : U64, to : U64 }),
		reversed : List(U64),
		reversed_flags : List(Bool),
		real_ranks : List(U64),
		extended_ranks : List(U64),
		chains : List(List(U64)),
		unit_edges : List({ from : U64, to : U64 }),
		ordered_layers : List(List(U64)),
		node_gap : F64,
		layer_gap : F64,
		route_style : [Straight, Curved],
	} -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
	}
	finish_layout = |prepared| {
		virtual_count = prepared.extended_ranks.len() - prepared.nodes.len()
		widths = prepared.nodes.map(|node| node.width).concat(List.repeat(0, virtual_count))
		heights = prepared.nodes.map(|node| node.height).concat(List.repeat(0, virtual_count))
		all_positions = LayeredInternals.assign_coordinates(prepared.ordered_layers, prepared.unit_edges, prepared.nodes.len(), widths, heights, prepared.node_gap, prepared.layer_gap)
		positions = all_positions.take_first(prepared.nodes.len())

		routes = prepared.chains.map_with_index(
			|chain, edge_index| {
				points = chain.keep_oks(|index| all_positions.get(index))
				oriented_points = if prepared.reversed_flags.get(edge_index) ?? False {
					points.rev()
				} else {
					points
				}
				edge = prepared.edges.get(edge_index) ?? { from: 0, to: 0 }
				source_size = prepared.nodes.get(edge.from) ?? { width: 0, height: 0 }
				target_size = prepared.nodes.get(edge.to) ?? { width: 0, height: 0 }
				clipped = LayeredInternals.clip_route_ends(oriented_points, source_size, target_size)
				LayeredInternals.make_route(clipped, prepared.route_style)
			},
		)

		max_right = positions.fold_with_index(
			0,
			|acc, point, index| {
				width = (prepared.nodes.get(index) ?? { width: 0, height: 0 }).width
				right = point.x + width / 2
				if right > acc {
					right
				} else {
					acc
				}
			},
		)
		max_bottom = positions.fold_with_index(
			0,
			|acc, point, index| {
				height = (prepared.nodes.get(index) ?? { width: 0, height: 0 }).height
				bottom = point.y + height / 2
				if bottom > acc {
					bottom
				} else {
					acc
				}
			},
		)

		# Node boxes are anchored at the origin, but route points — virtual
		# waypoints have zero size, and curve control points extend past their
		# anchors — may lie outside every node box. Extend the bounds to cover
		# them, and translate everything back to the origin if any escaped
		# above or to the left.
		extent = routes.fold(
			{ min_x: 0, min_y: 0, max_x: max_right, max_y: max_bottom },
			|acc, route|
				LayeredInternals.route_extent_points(route).fold(
					acc,
					|inner, point| {
						min_x: if point.x < inner.min_x {
							point.x
						} else {
							inner.min_x
						},
						min_y: if point.y < inner.min_y {
							point.y
						} else {
							inner.min_y
						},
						max_x: if point.x > inner.max_x {
							point.x
						} else {
							inner.max_x
						},
						max_y: if point.y > inner.max_y {
							point.y
						} else {
							inner.max_y
						},
					},
				),
		)

		shift_x = 0 - extent.min_x
		shift_y = 0 - extent.min_y
		final_positions = if shift_x == 0 and shift_y == 0 {
			positions
		} else {
			positions.map(|point| Geom.point(point.x + shift_x, point.y + shift_y))
		}
		final_routes = if shift_x == 0 and shift_y == 0 {
			routes
		} else {
			routes.map(|route| LayeredInternals.translate_route(route, shift_x, shift_y))
		}

		{
			layout: {
				positions: final_positions,
				bounds: { ..Geom.empty_bounds, width: extent.max_x - extent.min_x, height: extent.max_y - extent.min_y },
				routes: final_routes,
			},
			layers: prepared.real_ranks,
			backward_edges: prepared.reversed,
		}
	}

	validation_problems = |spec, config| {
		node_problems = spec.graph.nodes.fold_with_index(
			[],
			|problems, node, index| {
				width_problems = if !F64.is_finite(node.width) or node.width < 0 {
					problems.append(InvalidNodeWidth(index))
				} else {
					problems
				}

				if !F64.is_finite(node.height) or node.height < 0 {
					width_problems.append(InvalidNodeHeight(index))
				} else {
					width_problems
				}
			},
		)

		edge_problems = spec.graph.edges.fold_with_index(
			node_problems,
			|problems, edge, index| {
				from_problems = if edge.from >= spec.graph.nodes.len() {
					problems.append(MissingEdgeStart(index, edge.from))
				} else {
					problems
				}

				if edge.to >= spec.graph.nodes.len() {
					from_problems.append(MissingEdgeEnd(index, edge.to))
				} else {
					from_problems
				}
			},
		)

		gap_problems = if !F64.is_finite(config.node_gap) or config.node_gap < 0 {
			edge_problems.append(InvalidNodeGap)
		} else {
			edge_problems
		}

		if !F64.is_finite(config.layer_gap) or config.layer_gap < 0 {
			gap_problems.append(InvalidLayerGap)
		} else {
			gap_problems
		}
	}
}

## A validated and precomputed bounded-effort layered layout.
##
## `Sweep.build` is the only fallible boundary. The opaque value contains a
## canonical acyclic reading plus ranks, virtual chains, and layer order, so
## `Sweep.run` performs geometry only and is total.
Prepared := {
	nodes : List({ width : F64, height : F64 }),
	edges : List({ from : U64, to : U64 }),
	reversed : List(U64),
	reversed_flags : List(Bool),
	real_ranks : List(U64),
	extended_ranks : List(U64),
	chains : List(List(U64)),
	unit_edges : List({ from : U64, to : U64 }),
	ordered_layers : List(List(U64)),
	node_gap : F64,
	layer_gap : F64,
	route_style : [Straight, Curved],
}.{
	Config : { node_gap : F64, layer_gap : F64, route_style : [Straight, Curved] }
	Spec : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
	}
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
	]

	defaults : Config
	defaults = { node_gap: 24, layer_gap: 70, route_style: Curved }

	default_spec : Spec
	default_spec = { graph: { nodes: [], edges: [] } }

	build : Spec, Config -> [Ok(Prepared), Err(List(Problem))]
	build = |spec, config| {
		problems = LayeredInternals.validation_problems(spec, config)
		if !problems.is_empty() {
			Err(problems)
		} else {
			oriented = LayeredInternals.orient_edges(spec.graph.nodes.len(), spec.graph.edges)
			real_ranks = LayeredInternals.rank_nodes(spec.graph.nodes.len(), oriented.edges)
			extended = LayeredInternals.insert_virtual_chains(real_ranks, oriented.edges)
			ordered_layers = LayeredInternals.order_layers(LayeredInternals.group_by_rank(extended.ranks), extended.unit_edges)

			Ok({
				nodes: spec.graph.nodes,
				edges: spec.graph.edges,
				reversed: oriented.reversed,
				reversed_flags: oriented.reversed_flags,
				real_ranks,
				extended_ranks: extended.ranks,
				chains: extended.chains,
				unit_edges: extended.unit_edges,
				ordered_layers,
				node_gap: config.node_gap,
				layer_gap: config.layer_gap,
				route_style: config.route_style,
			})
		}
	}

	run : Prepared -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
	}
	run = |sweep|
		LayeredInternals.finish_layout({
			nodes: sweep.nodes,
			edges: sweep.edges,
			reversed: sweep.reversed,
			reversed_flags: sweep.reversed_flags,
			real_ranks: sweep.real_ranks,
			extended_ranks: sweep.extended_ranks,
			chains: sweep.chains,
			unit_edges: sweep.unit_edges,
			ordered_layers: sweep.ordered_layers,
			node_gap: sweep.node_gap,
			layer_gap: sweep.layer_gap,
			route_style: sweep.route_style,
		})

	layout : Spec,
	Config -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				layers : List(U64),
				backward_edges : List(U64),
			},
		),
		Err(List(Problem)),
	]
	layout = |spec, config|
		match Prepared.build(spec, config) {
			Ok(sweep) => Ok(sweep.run())
			Err(problems) => Err(problems)
		}
}

## A validated and precomputed exact-ordering layered layout.
##
## Same canonical acyclic reading, ranks, and virtual chains as `Prepared`,
## but the layer ordering comes from the bounded branch-and-bound crossing
## search, and the witness records whether that search proved its ordering
## optimal. `ExactPrepared.run` performs geometry only and is total.
ExactPrepared := {
	nodes : List({ width : F64, height : F64 }),
	edges : List({ from : U64, to : U64 }),
	reversed : List(U64),
	reversed_flags : List(Bool),
	real_ranks : List(U64),
	extended_ranks : List(U64),
	chains : List(List(U64)),
	unit_edges : List({ from : U64, to : U64 }),
	ordered_layers : List(List(U64)),
	proven_optimal : Bool,
	node_gap : F64,
	layer_gap : F64,
	route_style : [Straight, Curved],
}.{
	Config : { node_gap : F64, layer_gap : F64, route_style : [Straight, Curved], effort_cap : U64 }
	Spec : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
	}
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
	]

	defaults : Config
	defaults = { node_gap: 24, layer_gap: 70, route_style: Curved, effort_cap: 100_000 }

	build : Spec, Config -> [Ok(ExactPrepared), Err(List(Problem))]
	build = |spec, config| {
		problems = LayeredInternals.validation_problems(spec, { node_gap: config.node_gap, layer_gap: config.layer_gap, route_style: config.route_style })
		if !problems.is_empty() {
			Err(problems)
		} else {
			oriented = LayeredInternals.orient_edges(spec.graph.nodes.len(), spec.graph.edges)
			real_ranks = LayeredInternals.rank_nodes(spec.graph.nodes.len(), oriented.edges)
			extended = LayeredInternals.insert_virtual_chains(real_ranks, oriented.edges)
			searched = LayeredInternals.exact_order_layers(LayeredInternals.group_by_rank(extended.ranks), extended.unit_edges, config.effort_cap)

			Ok({
				nodes: spec.graph.nodes,
				edges: spec.graph.edges,
				reversed: oriented.reversed,
				reversed_flags: oriented.reversed_flags,
				real_ranks,
				extended_ranks: extended.ranks,
				chains: extended.chains,
				unit_edges: extended.unit_edges,
				ordered_layers: searched.layers,
				proven_optimal: searched.proven_optimal,
				node_gap: config.node_gap,
				layer_gap: config.layer_gap,
				route_style: config.route_style,
			})
		}
	}

	run : ExactPrepared -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
		proven_optimal : Bool,
	}
	run = |exact| {
		finished = LayeredInternals.finish_layout({
			nodes: exact.nodes,
			edges: exact.edges,
			reversed: exact.reversed,
			reversed_flags: exact.reversed_flags,
			real_ranks: exact.real_ranks,
			extended_ranks: exact.extended_ranks,
			chains: exact.chains,
			unit_edges: exact.unit_edges,
			ordered_layers: exact.ordered_layers,
			node_gap: exact.node_gap,
			layer_gap: exact.layer_gap,
			route_style: exact.route_style,
		})

		{
			layout: finished.layout,
			layers: finished.layers,
			backward_edges: finished.backward_edges,
			proven_optimal: exact.proven_optimal,
		}
	}

	layout : Spec,
	Config -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				layers : List(U64),
				backward_edges : List(U64),
				proven_optimal : Bool,
			},
		),
		Err(List(Problem)),
	]
	layout = |spec, config|
		match ExactPrepared.build(spec, config) {
			Ok(exact) => Ok(exact.run())
			Err(problems) => Err(problems)
		}
}

## Directed graph layout read as flow.
##
## `layout` is the usual entry point. For repeated layouts of unchanged input,
## call `prepare` once and pass the result to `layout_prepared`. For small,
## important drawings, `layout_exact` searches for the layer orderings with
## the fewest edge crossings under an explicit effort cap and reports whether
## optimality was proven.
Layered := [].{

	## Directed flow input for the current exemplar. Edge identity is its index.
	Input : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
	}

	## Space between nodes on the same layer and between adjacent layers,
	## plus how edges through intermediate layers are drawn: `Curved` (the
	## default) smooths their bends into cubic curve chains, `Straight`
	## keeps them as polylines. Edges between adjacent layers are always
	## straight lines.
	Settings : { node_gap : F64, layer_gap : F64, route_style : [Straight, Curved] }

	## Invalid sizes, spacing, or edge endpoints found while checking input.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
	]

	## Geometry plus each node's layer and any edges drawn against the flow.
	## Positions hold node centers; route endpoints lie on the source and
	## target node boundaries.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
	}

	## Empty flow input. Replace `graph` by record update.
	default_input : Input
	default_input = Prepared.default_spec

	## Settings that produce a readable top-to-bottom layout in common cases.
	default_settings : Settings
	default_settings = Prepared.defaults

	## Check the input and settings, then cache work reusable across layouts.
	prepare : Input, Settings -> [Ok(Prepared), Err(List(Problem))]
	prepare = |input, settings| Prepared.build(input, settings)

	## Lay out previously prepared input. This operation cannot fail.
	layout_prepared : Prepared -> Result
	layout_prepared = |prepared| prepared.run()

	## Check and lay out input in one call. This is the usual entry point.
	layout : Input, Settings -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings| Prepared.layout(input, settings)

	## Settings for `layout_exact`: spacing and route style exactly as in
	## `Settings`, plus `effort_cap` — the most ordering choices the crossing
	## search may try before stopping with the best ordering found so far.
	## Higher caps prove optimality on wider layers at higher cost; a cap of
	## `0` skips the search entirely and keeps the ordering `layout` would
	## produce.
	ExactSettings : { node_gap : F64, layer_gap : F64, route_style : [Straight, Curved], effort_cap : U64 }

	## Everything `Result` reports, plus whether the crossing search proved
	## its ordering has the fewest crossings any ordering can achieve:
	## `True` when the search finished within the effort cap or the ordering
	## is crossing-free, `False` when the cap stopped the search early.
	ExactResult : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
		proven_optimal : Bool,
	}

	## Default spacing and route style with an effort cap of 100,000 ordering
	## choices — enough to prove optimality for small drawings.
	default_exact_settings : ExactSettings
	default_exact_settings = ExactPrepared.defaults

	## Check the input and settings, run the crossing search, and cache the
	## chosen ordering with everything else reusable across layouts.
	prepare_exact : Input, ExactSettings -> [Ok(ExactPrepared), Err(List(Problem))]
	prepare_exact = |input, settings| ExactPrepared.build(input, settings)

	## Lay out previously prepared exact input. This operation cannot fail.
	layout_exact_prepared : ExactPrepared -> ExactResult
	layout_exact_prepared = |prepared| prepared.run()

	## Check and lay out input with the fewest edge crossings the effort cap
	## allows, in one call. Direction handling, layer assignment, spacing,
	## and routes are exactly as in `layout`; only the ordering of nodes
	## within each layer differs, chosen by exhaustive search rather than
	## heuristic sweeps. The search cost grows steeply with layer width, so
	## the effort cap bounds it: at the cap the best ordering found — never
	## worse than `layout`'s — is returned with `proven_optimal: False`.
	layout_exact : Input, ExactSettings -> [Ok(ExactResult), Err(List(Problem))]
	layout_exact = |input, settings| ExactPrepared.layout(input, settings)
}

## Ranking: a diamond DAG (0 -> 1, 0 -> 2, 1 -> 3, 2 -> 3) ranks by longest path.
expect LayeredInternals.rank_nodes(4, [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 2, to: 3 }]) == [0, 1, 1, 2]

## Ranking: an isolated node with no edges ranks 0.
expect LayeredInternals.rank_nodes(1, []) == [0]

## Ranking is exact where longest path is not: a source feeding both a long
## chain and the chain's end should sit at a middle rank, not rank 0. Node 4
## lands on rank 2, and the total span matches the brute-force optimum.
expect {
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 4, to: 3 }]
	ranks = LayeredInternals.rank_nodes(5, edges)
	total = LayeredInternals.total_span(ranks, edges)
	ranks == [0, 1, 2, 3, 2] and Some(total) == LayeredInternals.brute_force_min_span(5, 4, edges)
}

## Ranking: parallel edges outweigh a single edge, forcing a simplex pivot —
## node 4 hangs from the chain's end (two edges pulling) rather than from the
## source (one edge). Exactness verified against brute force.
expect {
	edges = [
		{ from: 0, to: 1 },
		{ from: 1, to: 2 },
		{ from: 2, to: 3 },
		{ from: 0, to: 4 },
		{ from: 4, to: 3 },
		{ from: 4, to: 3 },
	]
	ranks = LayeredInternals.rank_nodes(5, edges)
	total = LayeredInternals.total_span(ranks, edges)
	ranks == [0, 1, 2, 3, 2] and Some(total) == LayeredInternals.brute_force_min_span(5, 4, edges)
}

## Ranking matches the brute-force optimum on a DAG with merging branches,
## and the result is feasible: every non-loop edge spans at least one layer
## and the lowest rank is 0.
expect {
	edges = [
		{ from: 0, to: 1 },
		{ from: 0, to: 2 },
		{ from: 1, to: 3 },
		{ from: 2, to: 3 },
		{ from: 3, to: 4 },
		{ from: 0, to: 5 },
		{ from: 5, to: 4 },
	]
	ranks = LayeredInternals.rank_nodes(6, edges)
	total = LayeredInternals.total_span(ranks, edges)
	feasible = edges.all(|edge| (ranks.get(edge.to) ?? 0) > (ranks.get(edge.from) ?? 0))
	has_zero = ranks.count_if(|rank| rank == 0) > 0
	feasible and has_zero and Some(total) == LayeredInternals.brute_force_min_span(6, 4, edges)
}

## Ranking: each disconnected component starts at layer 0, isolated nodes
## included.
expect LayeredInternals.rank_nodes(6, [{ from: 0, to: 1 }, { from: 3, to: 4 }, { from: 4, to: 5 }]) == [0, 1, 0, 0, 1, 2]

## Virtual chains: a 2-node, 2-span edge gets one virtual waypoint.
expect {
	result = LayeredInternals.insert_virtual_chains([0, 2], [{ from: 0, to: 1 }])
	result == {
		ranks: [0, 2, 1],
		unit_edges: [{ from: 0, to: 2 }, { from: 2, to: 1 }],
		chains: [[0, 2, 1]],
	}
}

## Virtual chains: a unit-span edge passes through unchanged.
expect {
	result = LayeredInternals.insert_virtual_chains([0, 1], [{ from: 0, to: 1 }])
	result == {
		ranks: [0, 1],
		unit_edges: [{ from: 0, to: 1 }],
		chains: [[0, 1]],
	}
}

## Grouping: ranks bucket into ascending-rank, ascending-index layers.
expect LayeredInternals.group_by_rank([0, 1, 1, 2]) == [[0], [1, 2], [3]]

## Crossing counter: the classic two-edge X counts one crossing, and parallel
## (non-inverting) edges count none.
expect {
	x_layers = [[0, 1], [2, 3]]
	crossed = LayeredInternals.crossings_between(4, [0, 1], [2, 3], [{ from: 0, to: 3 }, { from: 1, to: 2 }])
	parallel = LayeredInternals.crossings_between(4, [0, 1], [2, 3], [{ from: 0, to: 2 }, { from: 1, to: 3 }])
	total = LayeredInternals.total_crossings(4, x_layers, [{ from: 0, to: 3 }, { from: 1, to: 2 }])
	crossed == 1 and parallel == 0 and total == 1
}

## Ordering: with tied medians the sweeps alone leave a crossing — node 3
## has two edges up to node 1 and one to node 0, so swapping it before node 2
## helps, but both share median position 1 — and the transpose polish removes
## it. `order_layers` therefore ends crossing-free.
expect {
	layers = [[0, 1], [2, 3]]
	unit_edges = [{ from: 1, to: 2 }, { from: 0, to: 3 }, { from: 1, to: 3 }, { from: 1, to: 3 }]
	down = LayeredInternals.sweep_median(layers, unit_edges, Down)
	swept = LayeredInternals.sweep_median(down, unit_edges, Up)
	swept_score = LayeredInternals.total_crossings(4, swept, unit_edges)
	final = LayeredInternals.order_layers(layers, unit_edges)
	final_score = LayeredInternals.total_crossings(4, final, unit_edges)
	swept_score == 1 and final_score == 0
}

## Ordering never ends worse than it started, and is deterministic.
expect {
	layers = [[0, 1, 2], [3, 4, 5], [6, 7]]
	unit_edges = [
		{ from: 0, to: 5 },
		{ from: 1, to: 4 },
		{ from: 2, to: 3 },
		{ from: 2, to: 4 },
		{ from: 3, to: 7 },
		{ from: 4, to: 6 },
		{ from: 5, to: 6 },
	]
	initial = LayeredInternals.total_crossings(8, layers, unit_edges)
	ordered = LayeredInternals.order_layers(layers, unit_edges)
	final = LayeredInternals.total_crossings(8, ordered, unit_edges)
	final <= initial and ordered == LayeredInternals.order_layers(layers, unit_edges)
}

## Full pipeline: a 5-node diamond-plus-tail places every node without overlap
## and reports a tight bounds.
expect {
	nodes = [
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
	]
	edges = [
		{ from: 0, to: 1 },
		{ from: 0, to: 2 },
		{ from: 1, to: 3 },
		{ from: 2, to: 3 },
		{ from: 3, to: 4 },
	]
	result = LayeredInternals.sugiyama(nodes, edges, 10, 30)

	result.positions.len() == 5 and result.routes.len() == 5 and result.bounds.width > 0 and result.bounds.height > 0
}

## Full pipeline: the empty graph yields an empty layout at the origin.
expect LayeredInternals.sugiyama([], [], 10, 30) == { positions: [], bounds: Geom.empty_bounds, routes: [] }

## Full pipeline: a single node with no edges sits at its own center.
expect {
	result = LayeredInternals.sugiyama([{ width: 10, height: 6 }], [], 4, 20)
	result == {
		positions: [{ x: 5, y: 3 }],
		bounds: { x: 0, y: 0, width: 10, height: 6 },
		routes: [],
	}
}

## Exemplar contract: build reports every independent boundary problem.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: -1, height: -2 }],
			edges: [{ from: 0, to: 3 }],
		},
	}
	config = { ..Prepared.defaults, node_gap: -4 }
	Prepared.build(spec, config) == Err([
		InvalidNodeWidth(0),
		InvalidNodeHeight(0),
		MissingEdgeEnd(0, 3),
		InvalidNodeGap,
	])
}

## Orientation: a lone edge from a higher index to a lower one is acyclic, so
## nothing is reversed — the caller's direction survives, node 1 simply ranks
## above node 0, and the route runs with the flow from node 1's bottom edge to
## node 0's top edge.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 1, to: 0 }],
		},
	}
	match Prepared.build(spec, Prepared.defaults) {
		Err(_) => False
		Ok(sweep) => {
			result = sweep.run()
			result.backward_edges == [] and result.layers == [1, 0] and result.layout.routes == [Line({ x: 5, y: 6 }, { x: 5, y: 76 })]
		}
	}
}

## Orientation: an acyclic graph given in scrambled index order reverses no
## edge at all — every caller edge keeps its direction.
expect {
	oriented = LayeredInternals.orient_edges(4, [{ from: 3, to: 1 }, { from: 1, to: 0 }, { from: 3, to: 0 }, { from: 2, to: 3 }])
	oriented.reversed == [] and oriented.edges == [{ from: 3, to: 1 }, { from: 1, to: 0 }, { from: 3, to: 0 }, { from: 2, to: 3 }]
}

## Orientation: a 2-cycle reverses exactly one of its two edges, the run stays
## total, and the reversed edge's route still runs in the caller's direction —
## from node 1's top boundary back up to node 0's bottom boundary.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 0 }],
		},
	}
	match Prepared.build(spec, Prepared.defaults) {
		Err(_) => False
		Ok(sweep) => {
			result = sweep.run()
			result.backward_edges == [1] and result.layers == [0, 1] and result.layout.routes == [Line({ x: 5, y: 6 }, { x: 5, y: 76 }), Line({ x: 5, y: 76 }, { x: 5, y: 6 })]
		}
	}
}

## Orientation: a 3-cycle reverses exactly one edge.
expect {
	oriented = LayeredInternals.orient_edges(3, [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }])
	oriented.reversed == [2] and oriented.edges.get(2) == Ok({ from: 0, to: 2 })
}

## Orientation: even on a graph of overlapping cycles, fewer than half of all
## edges are reversed, and reversing them leaves the caller's other edges
## untouched.
expect {
	edges = [
		{ from: 0, to: 1 },
		{ from: 1, to: 2 },
		{ from: 2, to: 0 },
		{ from: 1, to: 3 },
		{ from: 3, to: 0 },
	]
	oriented = LayeredInternals.orient_edges(4, edges)
	oriented.reversed.len() * 2 < edges.len()
}

## The one-shot API is exactly build followed by run.
expect {
	spec = { ..Prepared.default_spec, graph: { nodes: [{ width: 8, height: 4 }], edges: [] } }
	match Prepared.build(spec, Prepared.defaults) {
		Err(_) => False
		Ok(prepared) => Prepared.layout(spec, Prepared.defaults) == Ok(prepared.run())
	}
}

## A unit-span route's endpoints lie exactly on the two nodes' facing edges:
## the source's bottom edge and the target's top edge.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }],
		},
	}
	match Prepared.layout(spec, Prepared.defaults) {
		Err(_) => False
		Ok(result) => result.layout.routes == [Line({ x: 5, y: 6 }, { x: 5, y: 76 })]
	}
}

## With the default `Curved` style, an edge spanning two layers becomes a
## cubic curve chain through its virtual waypoint: the chain starts on the
## source's boundary aimed at the waypoint, passes through the waypoint, and
## ends on the target's boundary, while the unit-span edges stay straight
## lines.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	match Prepared.layout(spec, Prepared.defaults) {
		Err(_) => False
		Ok(result) => {
			source_center = result.layout.positions.get(0) ?? Geom.point(0, 0)
			target_center = result.layout.positions.get(2) ?? Geom.point(0, 0)
			unit_is_line = match result.layout.routes.get(0) ?? Polyline([]) {
				Line(_, _) => True
				_ => False
			}
			long_is_curve = match result.layout.routes.get(2) ?? Polyline([]) {
				Curves([first, last]) => {
					waypoint = first.to
					starts_on_source = first.from == Geom.clip_to_node(source_center, { width: 10, height: 6 }, waypoint)
					ends_on_target = last.from == waypoint and last.to == Geom.clip_to_node(target_center, { width: 10, height: 6 }, waypoint)
					starts_on_source and ends_on_target
				}
				_ => False
			}
			unit_is_line and long_is_curve
		}
	}
}

## `route_style: Straight` keeps the same long edge as a polyline through the
## waypoint, still clipped to the node boundaries at both ends.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	match Prepared.layout(spec, { ..Prepared.defaults, route_style: Straight }) {
		Err(_) => False
		Ok(result) => {
			source_center = result.layout.positions.get(0) ?? Geom.point(0, 0)
			target_center = result.layout.positions.get(2) ?? Geom.point(0, 0)
			match result.layout.routes.get(2) ?? Polyline([]) {
				Polyline([start, waypoint, end]) => {
					start == Geom.clip_to_node(source_center, { width: 10, height: 6 }, waypoint)
						and end == Geom.clip_to_node(target_center, { width: 10, height: 6 }, waypoint)
				}
				_ => False
			}
		}
	}
}

## Coordinates: a symmetric diamond centers the source and the sink at the
## same x, midway between its two equal-width branches, which sit a full
## separation apart. No two nodes in a layer overlap.
expect {
	nodes = [
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
		{ width: 20, height: 10 },
	]
	edges = [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 2, to: 3 }]
	result = LayeredInternals.sugiyama(nodes, edges, 10, 30)
	x0 = (result.positions.get(0) ?? Geom.point(0, 0)).x
	x1 = (result.positions.get(1) ?? Geom.point(0, 0)).x
	x2 = (result.positions.get(2) ?? Geom.point(0, 0)).x
	x3 = (result.positions.get(3) ?? Geom.point(0, 0)).x
	x0 == x3 and x0 == (x1 + x2) / 2 and (x1 - x2).abs() >= 30
}

## Coordinates: nodes sharing a layer never overlap, whatever their widths —
## centers stay at least half their widths plus the node gap apart.
expect {
	nodes = [
		{ width: 40, height: 10 },
		{ width: 30, height: 10 },
		{ width: 10, height: 10 },
		{ width: 50, height: 10 },
	]
	edges = [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 0, to: 3 }]
	result = LayeredInternals.sugiyama(nodes, edges, 12, 30)
	ranks = LayeredInternals.rank_nodes(4, edges)
	violations = LayeredInternals.indices_up_to(4).fold(
		0,
		|acc, i|
			LayeredInternals.indices_up_to(4).fold(
				acc,
				|inner, j| {
					same_layer = i < j and (ranks.get(i) ?? 0) == (ranks.get(j) ?? 0)
					if !same_layer {
						inner
					} else {
						xi = (result.positions.get(i) ?? Geom.point(0, 0)).x
						xj = (result.positions.get(j) ?? Geom.point(0, 0)).x
						wi = (nodes.get(i) ?? { width: 0, height: 0 }).width
						wj = (nodes.get(j) ?? { width: 0, height: 0 }).width
						if (xi - xj).abs() + 0.000001 >= (wi + wj) / 2 + 12 {
							inner
						} else {
							inner + 1
						}
					}
				},
			),
	)
	violations == 0
}

## Coordinates: the inner segments of a long edge's virtual chain lie on one
## straight vertical line, so the routed polyline bends only at its ends.
expect {
	nodes = [
		{ width: 10, height: 6 },
		{ width: 10, height: 6 },
		{ width: 10, height: 6 },
		{ width: 10, height: 6 },
	]
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 0, to: 3 }]
	result = LayeredInternals.sugiyama(nodes, edges, 8, 24)
	match result.routes.get(3) ?? Polyline([]) {
		Polyline([_start, way_a, way_b, _end]) => way_a.x == way_b.x
		_ => False
	}
}

## Coordinates: the same input always produces bit-identical geometry.
expect {
	nodes = [
		{ width: 20, height: 10 },
		{ width: 12, height: 10 },
		{ width: 28, height: 10 },
		{ width: 20, height: 10 },
		{ width: 16, height: 10 },
	]
	edges = [
		{ from: 0, to: 1 },
		{ from: 0, to: 2 },
		{ from: 1, to: 3 },
		{ from: 2, to: 3 },
		{ from: 0, to: 4 },
		{ from: 4, to: 3 },
	]
	LayeredInternals.sugiyama(nodes, edges, 10, 30) == LayeredInternals.sugiyama(nodes, edges, 10, 30)
}

## Determinism: laying out the same input twice produces identical results.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	Layered.layout(input, Layered.default_settings) == Layered.layout(input, Layered.default_settings)
}

## Exact ordering beats the sweep: on this two-layer graph the median sweeps
## and transpose polish stall at one crossing, but a crossing-free ordering
## exists and the exact search finds it and proves it optimal.
expect {
	edges = [{ from: 0, to: 3 }, { from: 0, to: 5 }, { from: 1, to: 4 }, { from: 2, to: 5 }]
	layers = LayeredInternals.group_by_rank(LayeredInternals.rank_nodes(6, edges))
	swept = LayeredInternals.order_layers(layers, edges)
	sweep_score = LayeredInternals.total_crossings(6, swept, edges)
	searched = LayeredInternals.exact_order_layers(layers, edges, 100_000)
	exact_score = LayeredInternals.total_crossings(6, searched.layers, edges)
	sweep_score == 1 and exact_score == 0 and searched.proven_optimal
}

## The public exact layout proves optimality on the sweep-beating graph with
## the default effort cap, and its shared phases agree with the sweep's.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: List.repeat({ width: 10, height: 6 }, 6),
			edges: [{ from: 0, to: 3 }, { from: 0, to: 5 }, { from: 1, to: 4 }, { from: 2, to: 5 }],
		},
	}
	match Layered.layout(input, Layered.default_settings) {
		Err(_) => False
		Ok(sweep_result) =>
			match Layered.layout_exact(input, Layered.default_exact_settings) {
				Err(_) => False
				Ok(exact_result) =>
					exact_result.proven_optimal
						and exact_result.layout.positions.len() == 6
							and exact_result.layout.routes.len() == 4
								and exact_result.layers == sweep_result.layers
									and exact_result.backward_edges == sweep_result.backward_edges
				}
		}
}

## The exact layout is proven optimal on a trivially small graph.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	match Layered.layout_exact(input, Layered.default_exact_settings) {
		Err(_) => False
		Ok(result) => result.proven_optimal and result.layout.positions.len() == 3 and result.layout.routes.len() == 3
	}
}

## An effort cap of 0 skips the search: on a graph where the sweep leaves a
## crossing, the exact layout equals the sweep's layout exactly and does not
## claim optimality.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: List.repeat({ width: 10, height: 6 }, 6),
			edges: [{ from: 0, to: 3 }, { from: 0, to: 5 }, { from: 1, to: 4 }, { from: 2, to: 5 }],
		},
	}
	match Layered.layout(input, Layered.default_settings) {
		Err(_) => False
		Ok(sweep_result) =>
			match Layered.layout_exact(input, { ..Layered.default_exact_settings, effort_cap: 0 }) {
				Err(_) => False
				Ok(exact_result) =>
					!exact_result.proven_optimal
						and exact_result.layout == sweep_result.layout
							and exact_result.layers == sweep_result.layers
								and exact_result.backward_edges == sweep_result.backward_edges
				}
		}
}

## A tiny effort cap on a wider instance stops the search unproven, yet the
## returned ordering never crosses more than the sweep's and the public
## layout stays complete.
expect {
	edges = [{ from: 0, to: 4 }, { from: 1, to: 3 }, { from: 1, to: 5 }, { from: 2, to: 4 }, { from: 2, to: 5 }]
	layers = LayeredInternals.group_by_rank(LayeredInternals.rank_nodes(6, edges))
	swept = LayeredInternals.order_layers(layers, edges)
	sweep_score = LayeredInternals.total_crossings(6, swept, edges)
	searched = LayeredInternals.exact_order_layers(layers, edges, 3)
	exact_score = LayeredInternals.total_crossings(6, searched.layers, edges)

	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 6), edges },
	}
	layout_ok = match Layered.layout_exact(input, { ..Layered.default_exact_settings, effort_cap: 3 }) {
		Err(_) => False
		Ok(result) => !result.proven_optimal and result.layout.positions.len() == 6 and result.layout.routes.len() == 5
	}

	sweep_score == 2 and !searched.proven_optimal and exact_score <= sweep_score and layout_ok
}

## When every ordering crosses — the complete two-by-two bipartite graph —
## the exhausted search proves the single unavoidable crossing optimal.
expect {
	edges = [{ from: 0, to: 2 }, { from: 0, to: 3 }, { from: 1, to: 2 }, { from: 1, to: 3 }]
	layers = LayeredInternals.group_by_rank(LayeredInternals.rank_nodes(4, edges))
	searched = LayeredInternals.exact_order_layers(layers, edges, 100_000)
	LayeredInternals.total_crossings(4, searched.layers, edges) == 1 and searched.proven_optimal
}

## Exact and sweep share every phase but ordering: on a cycle both report the
## same layers and the same edge drawn against the flow.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: List.repeat({ width: 10, height: 6 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }],
		},
	}
	match Layered.layout(input, Layered.default_settings) {
		Err(_) => False
		Ok(sweep_result) =>
			match Layered.layout_exact(input, Layered.default_exact_settings) {
				Err(_) => False
				Ok(exact_result) => exact_result.layers == sweep_result.layers and exact_result.backward_edges == sweep_result.backward_edges
			}
		}
}

## Exact layout is deterministic, and the one-shot operation is exactly
## prepare followed by layout.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: List.repeat({ width: 10, height: 6 }, 6),
			edges: [{ from: 0, to: 3 }, { from: 0, to: 5 }, { from: 1, to: 4 }, { from: 2, to: 5 }],
		},
	}
	repeated = Layered.layout_exact(input, Layered.default_exact_settings) == Layered.layout_exact(input, Layered.default_exact_settings)
	staged = match Layered.prepare_exact(input, Layered.default_exact_settings) {
		Err(_) => False
		Ok(prepared) => Layered.layout_exact(input, Layered.default_exact_settings) == Ok(Layered.layout_exact_prepared(prepared))
	}
	repeated and staged
}

## The exact path validates jointly through the same checks as the sweep,
## reporting every independent boundary problem.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: [{ width: -1, height: -2 }],
			edges: [{ from: 0, to: 3 }],
		},
	}
	settings = { ..Layered.default_exact_settings, node_gap: -4 }
	Layered.prepare_exact(input, settings) == Err([
		InvalidNodeWidth(0),
		InvalidNodeHeight(0),
		MissingEdgeEnd(0, 3),
		InvalidNodeGap,
	])
}
