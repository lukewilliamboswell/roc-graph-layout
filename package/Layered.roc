import CompoundRouting
import Geom
import LayeredOrder
import LayeredPlace
import LayeredRank
import Route
import Solver

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

	## `count` flags, set at each index of `items` below `count`.
	membership_flags : U64, List(U64) -> List(Bool)
	membership_flags = |count, items| items.fold(
		List.repeat(False, count),
		|acc, i| if i < count {
			acc.set(i, True) ?? []
		} else {
			acc
		},
	)

	## Weighted, constrained ranking used by the public Spec surface: the
	## GKNV network simplex with per-edge minimum spans and weighted cut
	## values, so a completed pivot sequence minimizes sum(weight * span).
	rank_nodes_spec : U64, List({ from : U64, to : U64 }), List(F64), List(U64) -> List(U64)
	rank_nodes_spec = |node_count, edges, weights, min_spans| LayeredRank.rank(node_count, edges, weights, min_spans)

	## Exact ranking: assign each node an integer layer minimizing the total
	## number of layers all edges span, with every edge spanning at least one
	## layer. Feasible longest-path ranks seed a tight spanning forest, and
	## network-simplex pivots with cut values walk to the optimum; each
	## component then normalizes to start at layer 0. Self-loops are ignored.
	## Input must be acyclic — `orient_edges` runs first in the pipeline —
	## though bounded iteration keeps even bad input from hanging.
	rank_nodes : U64, List({ from : U64, to : U64 }) -> List(U64)
	rank_nodes = |node_count, edges| LayeredRank.rank(node_count, edges, [], [])

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
	insert_virtual_chains : List(U64), List({ from : U64, to : U64 }) -> { ranks : List(U64), unit_edges : List({ from : U64, to : U64 }), chains : List(List(U64)) }
	insert_virtual_chains = |real_ranks, edges| LayeredOrder.insert_virtual_chains(real_ranks, edges)

	## Groups node indices by rank, in ascending rank then ascending index
	## order — the deterministic initial ordering before median sweeps run.
	group_by_rank : List(U64) -> List(List(U64))
	group_by_rank = |ranks| LayeredOrder.group_by_rank(ranks)

	## Seeds real-node order from a finite node-indexed hint table. Virtual waypoints
	## interpolate their owning edge's endpoints before each layer is sorted.
	hinted_layers : List(List(U64)), List(List(U64)), List({ x : F64, y : F64 }), List(Bool) -> List(List(U64))
	hinted_layers = |layers, chains, hints, reversed_flags| {
		real_count = hints.len()
		virtual_keys = chains.fold_with_index(
			List.repeat(0, layers.fold(0, |n, layer| n + layer.len())),
			|keys, chain, edge_index| {
				oriented = if reversed_flags.get(edge_index) ?? False {
					chain.rev()
				} else {
					chain
				}
				start = hints.get(oriented.first() ?? 0) ?? Geom.point(0, 0)
				end = hints.get(oriented.last() ?? 0) ?? start
				denom = (oriented.len() - 1).to_f64()
				oriented.fold_with_index(
					keys,
					|acc, node, i| if node < real_count {
						acc.set(node, (hints.get(node) ?? Geom.point(0, 0)).x) ?? acc
					} else {
						fraction = i.to_f64() / denom
						acc.set(node, start.x + (end.x - start.x) * fraction) ?? acc
					},
				)
			},
		)
		layers.map(
			|layer| layer.sort_with(
				|a, b| {
					ak = virtual_keys.get(a) ?? 0
					bk = virtual_keys.get(b) ?? 0
					if ak < bk {
						Before
					} else if ak > bk {
						After
					} else if a < b {
						Before
					} else if a > b {
						After
					} else {
						Same
					}
				},
			),
		)
	}

	canonical_hints : List({ node : U64, x : F64, y : F64 }), U64, [Down, Up, Left, Right] -> [Some({ points : List({ x : F64, y : F64 }), nodes : List(U64) }), None]
	canonical_hints = |hints, node_count, direction| {
		base = LayeredInternals.indices_up_to(node_count).map(|node| Geom.point(node.to_f64(), 0))
		valid = hints.keep_if(|hint| hint.node < node_count and F64.is_finite(hint.x) and F64.is_finite(hint.y))
		if valid.is_empty() {
			None
		} else {
			canonical = valid.fold(
				base,
				|points, hint| {
					point = match direction {
						Down => Geom.point(hint.x, hint.y)
						Up => Geom.point(hint.x, 0 - hint.y)
						Right => Geom.point(hint.y, hint.x)
						Left => Geom.point(hint.y, 0 - hint.x)
					}
					points.set(hint.node, point) ?? []
				},
			)
			nodes = valid.fold(
				[],
				|found, hint| if found.contains(hint.node) {
					found
				} else {
					found.append(hint.node)
				},
			)
			Some({ points: canonical, nodes })
		}
	}

	## Applies caller-facing layer relationships as bounded lower-bound
	## relaxations. Graph edges and `BeforeLayer` rules establish flow; same,
	## first, and last rules add zero-span relationships. Passes repeat until
	## one changes nothing, at most `(node_count + rules + 1) * (node_count + 1)`
	## times. The caller-facing validation below rejects a result that cannot
	## satisfy every rule.
	constrain_ranks = |node_count, edges, min_spans, initial, constraints| {
		cap = (node_count + constraints.len() + 1) * (node_count + 1)
		var $ranks = initial
		var $pass = 0
		var $changed = True
		while $changed and $pass < cap {
			previous = $ranks
			with_edges = edges.fold_with_index(
				previous,
				|acc, edge, i| if edge.from == edge.to {
					acc
				} else {
					wanted = (acc.get(edge.from) ?? 0) + (min_spans.get(i) ?? 1)
					if wanted > (acc.get(edge.to) ?? 0) {
						acc.set(edge.to, wanted) ?? []
					} else {
						acc
					}
				},
			)
			$ranks = constraints.fold(
				with_edges,
				|acc, rule| match rule {
					SameLayer(pair) => {
						value = (acc.get(pair.first) ?? 0).max(acc.get(pair.second) ?? 0)
						(acc.set(pair.first, value) ?? []).set(pair.second, value) ?? []
					}
					BeforeLayer(item) => {
						wanted = (acc.get(item.first) ?? 0) + item.minimum_span
						if wanted > (acc.get(item.second) ?? 0) {
							acc.set(item.second, wanted) ?? []
						} else {
							acc
						}
					}
					FirstLayer(node) => {
						base = acc.get(node) ?? 0
						acc.map(|rank| rank.max(base))
					}
					LastLayer(node) => {
						last = acc.fold(0, |highest, rank| highest.max(rank))
						if last > (acc.get(node) ?? 0) {
							acc.set(node, last) ?? []
						} else {
							acc
						}
					}
				},
			)
			$changed = $ranks != previous
			$pass = $pass + 1
		}
		raw = $ranks
		lowest = raw.fold(raw.first() ?? 0, |acc, rank| acc.min(rank))
		raw.map(|rank| rank - lowest)
	}

	layer_constraints_hold = |ranks, constraints| constraints.all(
		|rule| match rule {
			SameLayer(pair) => (ranks.get(pair.first) ?? 0) == (ranks.get(pair.second) ?? 0)
			BeforeLayer(item) => (ranks.get(item.second) ?? 0) >= (ranks.get(item.first) ?? 0) + item.minimum_span
			FirstLayer(node) => (ranks.get(node) ?? 0) == (ranks.fold(ranks.first() ?? 0, |acc, rank| acc.min(rank)))
			LastLayer(node) => (ranks.get(node) ?? 0) == (ranks.fold(0, |acc, rank| acc.max(rank)))
		},
	)

	ranking_holds = |ranks, edges, min_spans| edges.fold_with_index(True, |valid, edge, i| valid and (edge.from == edge.to or (ranks.get(edge.to) ?? 0) >= (ranks.get(edge.from) ?? 0) + (min_spans.get(i) ?? 1)))

	explicit_precedences = |rules| rules.map(|rule| { before: rule.before, after: rule.after })

	## Public ordering follows the displayed cross-axis, which is the canonical
	## x axis for every direction transform.
	canonical_precedences = |rules, direction| match direction {
		Down | Up | Right | Left => rules
	}

	precedences_hold = |layers, precedences| precedences.all(
		|rule| layers.all(
			|layer| {
				before = layer.find_first_index(|node| node == rule.before)
				after = layer.find_first_index(|node| node == rule.after)
				match (before, after) {
					(Ok(a), Ok(b)) => a < b
					_ => True
				}
			},
		),
	)

	## Whether `to` is reachable from `from` in the precedence graph. The
	## node-sized bound is sufficient for a simple path and makes malformed
	## cyclic input total.
	precedence_reaches = |node_count, precedences, from, to| {
		walked = LayeredInternals.indices_up_to(node_count).fold(
			{ reached: [from], found: from == to },
			|state, _| if state.found {
				state
			} else {
				next = precedences.fold(
					state.reached,
					|seen, rule| if seen.contains(rule.before) and !seen.contains(rule.after) {
						seen.append(rule.after)
					} else {
						seen
					},
				)
				{ reached: next, found: next.contains(to) }
			},
		)
		walked.found
	}

	## Stability is best-effort. Add each hint-derived relationship only when
	## it cannot contradict the hard relationships proven during preparation.
	compatible_precedences = |node_count, hard, preferred| preferred.fold(
		hard,
		|accepted, rule| if rule.before == rule.after or LayeredInternals.precedence_reaches(node_count, accepted, rule.after, rule.before) {
			accepted
		} else {
			accepted.append(rule)
		},
	)

	## Hard ordering constraints induced by attachment-rule declaration order. For two
	## consecutive rules on one node, their opposite endpoints must appear
	## in the same order whenever they share a layer. Repeated stable adjacent
	## swaps compute the deterministic closure; crossings are optimized only
	## inside the remaining unconstrained choices.
	attachment_precedences = |graph, attachments| graph.nodes.fold_with_index(
		[],
		|all, _node, node| {
			ordered = attachments.keep_if(
				|rule| match graph.edges.get(rule.edge) {
					Ok(edge) => match rule.endpoint {
						From => edge.from == node
						To => edge.to == node
					}
					Err(_) => False
				},
			)
			if ordered.len() < 2 {
				all
			} else {
				LayeredInternals.indices_up_to(ordered.len() - 1).fold(
					all,
					|acc, i| {
						a = ordered.get(i) ?? { edge: 0, endpoint: From, attachment: Automatic }
						b = ordered.get(i + 1) ?? a
						ea = graph.edges.get(a.edge) ?? { from: 0, to: 0 }
						eb = graph.edges.get(b.edge) ?? { from: 0, to: 0 }
						before = if ea.from == node {
							ea.to
						} else {
							ea.from
						}
						after = if eb.from == node {
							eb.to
						} else {
							eb.from
						}
						if before == after {
							acc
						} else {
							acc.append({ before, after })
						}
					},
				)
			}
		},
	)

	## Moves nodes within each layer until every precedence rule whose two
	## nodes share that layer holds: repeated passes over the rules in order,
	## each moving a misplaced `before` node to just ahead of its `after`
	## node, at most `len * len` passes and stopping once a pass changes
	## nothing. Rules between other layers leave a layer untouched.
	enforce_precedences = |layers, precedences| {
		if precedences.is_empty() {
			layers
		} else {
			size = layers.fold(0, |acc, layer| layer.fold(acc, |inner, v| inner.max(v + 1)))
			layer_of = layers.fold_with_index(List.repeat(layers.len(), size), |table, layer, i| layer.fold(table, |acc, v| acc.set(v, i) ?? []))
			layers.map_with_index(
				|layer, i| {
					relevant = precedences.keep_if(|rule| (layer_of.get(rule.before) ?? layers.len()) == i and (layer_of.get(rule.after) ?? layers.len()) == i)
					if relevant.is_empty() {
						layer
					} else {
						passes = layer.len() * layer.len()
						var $cur = layer
						var $pass = 0
						var $changed = True
						while $changed and $pass < passes {
							previous = $cur
							$cur = relevant.fold(
								previous,
								|acc, rule| {
									before_pos = acc.find_first_index(|n| n == rule.before)
									after_pos = acc.find_first_index(|n| n == rule.after)
									match (before_pos, after_pos) {
										(Ok(a), Ok(b)) => if a > b {
											value = acc.get(a) ?? rule.before
											without = acc.take_first(a).concat(acc.drop_first(a + 1))
											without.take_first(b).append(value).concat(without.drop_first(b))
										} else {
											acc
										}
										_ => acc
									}
								},
							)
							$changed = $cur != previous
							$pass = $pass + 1
						}
						$cur
					}
				},
			)
		}
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
	## minimizes and reports its best against. Nodes at or beyond
	## `node_total` belong to no layer.
	total_crossings : U64, List(List(U64)), List({ from : U64, to : U64 }) -> U64
	total_crossings = |_node_total, layers, unit_edges| LayeredOrder.total_crossings(layers, unit_edges)

	## Orders every layer to reduce edge crossings: rounds of a down then up
	## median sweep followed by an adjacent-swap transpose polish, each round
	## scored by total crossings. The best-scoring ordering seen is kept, and
	## the search stops early when a round fails to improve it, at a perfect
	## score of zero, or at the round cap. Every choice inside is
	## deterministic, so the result is too.
	order_layers : List(List(U64)), List({ from : U64, to : U64 }), U64 -> List(List(U64))
	order_layers = |layers, unit_edges, rounds| LayeredOrder.order(layers, unit_edges, rounds, Median)

	## `order_layers` with a choice of sweep: `Median` as above, or `Average`
	## sweeps keyed by mean neighbor position without the swap polish.
	order_layers_by : List(List(U64)), List({ from : U64, to : U64 }), U64, [Median, Average] -> List(List(U64))
	order_layers_by = |layers, unit_edges, rounds, method| LayeredOrder.order(layers, unit_edges, rounds, method)

	## Deterministic ascending copy of one layer's node indices — the
	## canonical first permutation, so the exact search below enumerates each
	## layer's orderings in lexicographic index order.
	ascending_indices : List(U64) -> List(U64)
	ascending_indices = |values|
		values.sort_with(
			|a, b| if a < b {
				Before
			} else if a > b {
				After
			} else {
				Same
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
		incumbent = LayeredInternals.order_layers(layers, unit_edges, 4)
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
	## Ties keep their current order, so a sweep is deterministic.
	sweep_median : List(List(U64)), List({ from : U64, to : U64 }), [Down, Up] -> List(List(U64))
	sweep_median = |layers, unit_edges, direction| LayeredOrder.sweep_layers(layers, unit_edges, direction)

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

	## One Brandes-Kopf vertical alignment in transformed space: layers arrive
	## top to bottom with nodes ordered left to right for the favored corner.
	## Each node aligns to the median of its upper neighbors when that segment
	## is not a type-1 conflict (an ordinary segment crossing an inner segment
	## between two virtual waypoints) and alignment stays left-to-right
	## monotone within the layer, chaining nodes into vertical blocks. Returns
	## each node's block root (the block's topmost node in transformed space).
	block_roots : U64, List(List(U64)), U64, List({ from : U64, to : U64 }) -> List(U64)
	block_roots = |node_total, layers, real_count, unit_edges| LayeredPlace.block_roots(node_total, layers, real_count, unit_edges)

	## Left-compacts one alignment: every block sits as far left as the
	## separation constraints between horizontally adjacent nodes allow —
	## centers at least (width_u + width_v) / 2 + node_gap apart — the
	## longest-path solution over the block ordering, which is acyclic
	## because aligned blocks never cross.
	compact_blocks : U64, List(List(U64)), List(U64), List(F64), F64 -> List(F64)
	compact_blocks = |node_total, layers, roots, widths, node_gap| LayeredPlace.compact_blocks(node_total, layers, roots, widths, node_gap)

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
						Before
					} else if a > b {
						After
					} else {
						Same
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
	## per-layer maximum height plus `layer_gap`. Chains of virtual
	## waypoints align vertically, so long edges run straight.
	assign_coordinates : List(List(U64)), List({ from : U64, to : U64 }), U64, List(F64), List(F64), F64, F64 -> List({ x : F64, y : F64 })
	assign_coordinates = |layers, unit_edges, real_count, widths, heights, node_gap, layer_gap| {
		node_total = widths.len()
		xs = LayeredInternals.balanced_median_x(node_total, layers, real_count, unit_edges, widths, node_gap)
		left_edge = LayeredInternals.candidate_extent(node_total, xs, widths).lo
		var $positions = List.repeat(Geom.point(0, 0), node_total)
		var $y_cursor = 0
		for layer in layers {
			max_height = LayeredInternals.layer_max_height(layer, heights)
			for node in layer {
				if node < node_total {
					x = (xs.get(node) ?? 0) - left_edge
					h = heights.get(node) ?? 0
					$positions = $positions.set(node, Geom.point(x, $y_cursor + h / 2)) ?? []
				}
			}
			$y_cursor = $y_cursor + max_height + layer_gap
		}
		$positions
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

	transform_point = |point, direction| match direction {
		Down => point
		Up => Geom.point(point.x, 0 - point.y)
		Right => Geom.point(point.y, point.x)
		Left => Geom.point(0 - point.y, point.x)
	}

	transform_route = |route, direction| {
		shift = |p| LayeredInternals.transform_point(p, direction)
		match route {
			Line(a, b) => Line(shift(a), shift(b))
			Polyline(points) => Polyline(points.map(shift))
			Curves(segments) => Curves(segments.map(|s| { from: shift(s.from), ctl_a: shift(s.ctl_a), ctl_b: shift(s.ctl_b), to: shift(s.to) }))
		}
	}

	## The placement router needs the interior virtual-chain points, without
	## the clipped node-boundary endpoints of the provisional route.
	interior_route_points = |candidate_route| match candidate_route {
		Polyline(points) if points.len() > 2 => points.drop_first(1).drop_last(1)
		_ => []
	}

	flow_coordinate = |point, direction| match direction {
		Down | Up => point.y
		Left | Right => point.x
	}

	cross_coordinate = |point, direction| match direction {
		Down | Up => point.x
		Left | Right => point.y
	}

	with_flow = |point, value, direction| match direction {
		Down | Up => { ..point, y: value }
		Left | Right => { ..point, x: value }
	}

	with_cross = |point, value, direction| match direction {
		Down | Up => { ..point, x: value }
		Left | Right => { ..point, y: value }
	}

	apply_pins = |positions, ranks, pins, direction| positions.map_with_index(
		|position, node| {
			rank = ranks.get(node) ?? 0
			flow_pin = pins.find_first(|pin| (ranks.get(pin.node) ?? 0) == rank)
			flowed = match flow_pin {
				Ok(pin) => LayeredInternals.with_flow(position, LayeredInternals.flow_coordinate(pin, direction), direction)
				Err(_) => position
			}
			match pins.find_first(|pin| pin.node == node) {
				Ok(pin) => LayeredInternals.with_cross(flowed, LayeredInternals.cross_coordinate(pin, direction), direction)
				Err(_) => flowed
			}
		},
	)

	valid_hint_for = |hints, node| hints.rev().find_first(|hint| hint.node == node and F64.is_finite(hint.x) and F64.is_finite(hint.y))

	apply_hints = |positions, ordered_layers, nodes, hints, direction, node_gap, layer_gap| {
		real_layers = ordered_layers.map(|layer| layer.keep_if(|node| node < nodes.len())).keep_if(|layer| !layer.is_empty())
		crossed = real_layers.fold(
			positions,
			|placed, layer| {
				variables = layer.map(
					|node| match LayeredInternals.valid_hint_for(hints, node) {
						Ok(hint) => { position: LayeredInternals.cross_coordinate(hint, direction), weight: 4 }
						Err(_) => { position: LayeredInternals.cross_coordinate(placed.get(node) ?? Geom.point(0, 0), direction), weight: 1 }
					},
				)
				constraints = if layer.len() < 2 {
					[]
				} else {
					LayeredInternals.indices_up_to(layer.len() - 1).map(
						|i| {
							left_node = nodes.get(layer.get(i) ?? 0) ?? { width: 0, height: 0 }
							right_node = nodes.get(layer.get(i + 1) ?? 0) ?? { width: 0, height: 0 }
							left_size = match direction {
								Down | Up => left_node.width
								Left | Right => left_node.height
							}
							right_size = match direction {
								Down | Up => right_node.width
								Left | Right => right_node.height
							}
							{ left: i, right: i + 1, gap: left_size / 2 + right_size / 2 + node_gap }
						},
					)
				}
				solved = Solver.project(variables, constraints)
				layer.fold_with_index(placed, |updated, node, i| updated.set(node, LayeredInternals.with_cross(updated.get(node) ?? Geom.point(0, 0), solved.get(i) ?? 0, direction)) ?? [])
			},
		)
		flow_variables = real_layers.map(
			|layer| {
				hinted = layer.keep_oks(|node| LayeredInternals.valid_hint_for(hints, node))
				base = LayeredInternals.flow_coordinate(crossed.get(layer.first() ?? 0) ?? Geom.point(0, 0), direction)
				target = if hinted.is_empty() {
					base
				} else {
					hinted.map(|hint| LayeredInternals.flow_coordinate(hint, direction)).sum() / hinted.len().to_f64()
				}
				signed = match direction {
					Down | Right => target
					Up | Left => 0 - target
				}
				{
					position: signed,
					weight: if hinted.is_empty() {
						1
					} else {
						4
					},
				}
			},
		)
		flow_constraints = if real_layers.len() < 2 {
			[]
		} else {
			LayeredInternals.indices_up_to(real_layers.len() - 1).map(
				|i| {
					layer_size = |layer| layer.fold(
						0,
						|largest, node| {
							item = nodes.get(node) ?? { width: 0, height: 0 }
							size = match direction {
								Down | Up => item.height
								Left | Right => item.width
							}
							largest.max(size)
						},
					)
					left_size = layer_size(real_layers.get(i) ?? [])
					right_size = layer_size(real_layers.get(i + 1) ?? [])
					{ left: i, right: i + 1, gap: left_size / 2 + right_size / 2 + layer_gap }
				},
			)
		}
		flow_solved = Solver.project(flow_variables, flow_constraints)
		real_layers.fold_with_index(
			crossed,
			|placed, layer, i| {
				signed = flow_solved.get(i) ?? 0
				flow = match direction {
					Down | Right => signed
					Up | Left => 0 - signed
				}
				layer.fold(placed, |updated, node| updated.set(node, LayeredInternals.with_flow(updated.get(node) ?? Geom.point(0, 0), flow, direction)) ?? [])
			},
		)
	}

	pin_geometry_conflict = |ranks, layers, nodes, pins, direction, node_gap, layer_gap| {
		pins.fold_with_index(
			False,
			|conflict, pin, i| pins.take_first(i).fold(
				conflict,
				|found, other| {
					pin_rank = ranks.get(pin.node) ?? 0
					other_rank = ranks.get(other.node) ?? 0
					if pin_rank == other_rank {
						flow_conflict = LayeredInternals.flow_coordinate(pin, direction) != LayeredInternals.flow_coordinate(other, direction)
						layer = layers.find_first(|item| item.contains(pin.node)) ?? []
						pin_before = (layer.find_first_index(|node| node == pin.node) ?? 0) < (layer.find_first_index(|node| node == other.node) ?? 0)
						first = if pin_before {
							pin
						} else {
							other
						}
						second = if pin_before {
							other
						} else {
							pin
						}
						first_node = nodes.get(first.node) ?? { width: 0, height: 0 }
						second_node = nodes.get(second.node) ?? { width: 0, height: 0 }
						first_size = match direction {
							Down | Up => first_node.width
							Left | Right => first_node.height
						}
						second_size = match direction {
							Down | Up => second_node.width
							Left | Right => second_node.height
						}
						cross_gap = LayeredInternals.cross_coordinate(second, direction) - LayeredInternals.cross_coordinate(first, direction)
						found or flow_conflict or cross_gap < first_size / 2 + second_size / 2 + node_gap
					} else {
						first = if pin_rank < other_rank {
							pin
						} else {
							other
						}
						second = if pin_rank < other_rank {
							other
						} else {
							pin
						}
						delta = LayeredInternals.flow_coordinate(second, direction) - LayeredInternals.flow_coordinate(first, direction)
						actual = match direction {
							Down | Right => delta
							Up | Left => 0 - delta
						}
						found or actual < layer_gap
					}
				},
			),
		)
	}

	move_waypoints = |routes, old_positions, new_positions, edges, direction| routes.map_with_index(
		|candidate, edge_index| {
			old = LayeredInternals.interior_route_points(candidate)
			edge = edges.get(edge_index) ?? { from: 0, to: 0 }
			from_old = old_positions.get(edge.from) ?? Geom.point(0, 0)
			to_old = old_positions.get(edge.to) ?? from_old
			from_new = new_positions.get(edge.from) ?? from_old
			to_new = new_positions.get(edge.to) ?? to_old
			count = old.len() + 1
			old.map_with_index(
				|point, i| {
					fraction = (i + 1).to_f64() / count.to_f64()
					from_delta = LayeredInternals.flow_coordinate(from_new, direction) - LayeredInternals.flow_coordinate(from_old, direction)
					to_delta = LayeredInternals.flow_coordinate(to_new, direction) - LayeredInternals.flow_coordinate(to_old, direction)
					delta = from_delta * (1 - fraction) + to_delta * fraction
					flowed = LayeredInternals.with_flow(point, LayeredInternals.flow_coordinate(point, direction) + delta, direction)
					from_cross = LayeredInternals.cross_coordinate(from_new, direction)
					to_cross = LayeredInternals.cross_coordinate(to_new, direction)
					cross = LayeredInternals.cross_coordinate(flowed, direction)
					bounded_cross = if from_cross == to_cross {
						cross
					} else {
						cross.max(from_cross.min(to_cross)).min(from_cross.max(to_cross))
					}
					LayeredInternals.with_cross(flowed, bounded_cross, direction)
				},
			)
		},
	)

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
			ordered = LayeredInternals.order_layers(layers, extended.unit_edges, 4)
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
	orient_edges = |node_count, edges| LayeredRank.orient(node_count, edges)

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
		direction : [Down, Up, Left, Right],
		edge_labels : List(Route.EdgeLabel),
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
		# Coordinate assignment always works in the canonical downward
		# orientation. Horizontal output rotates that geometry, so its canonical
		# cross-axis width is the displayed height and its canonical layer-axis
		# height is the displayed width.
		canonical_nodes = match prepared.direction {
			Down | Up => prepared.nodes
			Left | Right => prepared.nodes.map(|node| { width: node.height, height: node.width })
		}
		base_widths = canonical_nodes.map(|node| node.width).concat(List.repeat(0, virtual_count))
		base_heights = canonical_nodes.map(|node| node.height).concat(List.repeat(0, virtual_count))
		label_sizes = prepared.edge_labels.fold(
			{ widths: base_widths, heights: base_heights },
			|state, label| match label.placement {
				Near(_) => state
				Center => {
					chain = prepared.chains.get(label.edge) ?? []
					middle = chain.get(chain.len() // 2) ?? 0
					canonical_label = match prepared.direction {
						Down | Up => { width: label.width, height: label.height }
						Left | Right => { width: label.height, height: label.width }
					}
					width = (state.widths.get(middle) ?? 0).max(canonical_label.width)
					height = (state.heights.get(middle) ?? 0).max(canonical_label.height)
					{ widths: state.widths.set(middle, width) ?? [], heights: state.heights.set(middle, height) ?? [] }
				}
			},
		)
		widths = label_sizes.widths
		heights = label_sizes.heights
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
				source_size = canonical_nodes.get(edge.from) ?? { width: 0, height: 0 }
				target_size = canonical_nodes.get(edge.to) ?? { width: 0, height: 0 }
				clipped = LayeredInternals.clip_route_ends(oriented_points, source_size, target_size)
				LayeredInternals.make_route(clipped, prepared.route_style)
			},
		)

		max_right = positions.fold_with_index(
			0,
			|acc, point, index| {
				width = (canonical_nodes.get(index) ?? { width: 0, height: 0 }).width
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
				height = (canonical_nodes.get(index) ?? { width: 0, height: 0 }).height
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

		canonical = {
			layout: {
				positions: final_positions,
				bounds: { ..Geom.empty_bounds, width: extent.max_x - extent.min_x, height: extent.max_y - extent.min_y },
				routes: final_routes,
			},
			layers: prepared.real_ranks,
			backward_edges: prepared.reversed,
		}

		transformed_positions = canonical.layout.positions.map(|p| LayeredInternals.transform_point(p, prepared.direction))
		transformed_routes = canonical.layout.routes.map(|r| LayeredInternals.transform_route(r, prepared.direction))
		label_points = prepared.edge_labels.map(
			|label| {
				chain = prepared.chains.get(label.edge) ?? []
				middle = chain.get(chain.len() // 2) ?? 0
				point = all_positions.get(middle) ?? Geom.point(0, 0)
				LayeredInternals.transform_point(Geom.point(point.x + shift_x, point.y + shift_y), prepared.direction)
			},
		)
		node_extent = transformed_positions.fold_with_index(
			{ min_x: 0, min_y: 0, max_x: 0, max_y: 0 },
			|acc, p, i| {
				node = prepared.nodes.get(i) ?? { width: 0, height: 0 }
				size = node
				{
					min_x: acc.min_x.min(p.x - size.width / 2),
					min_y: acc.min_y.min(p.y - size.height / 2),
					max_x: acc.max_x.max(p.x + size.width / 2),
					max_y: acc.max_y.max(p.y + size.height / 2),
				}
			},
		)
		extent2 = transformed_routes.fold(
			node_extent,
			|acc, route| LayeredInternals.route_extent_points(route).fold(
				acc,
				|inner, p| {
					min_x: inner.min_x.min(p.x),
					min_y: inner.min_y.min(p.y),
					max_x: inner.max_x.max(p.x),
					max_y: inner.max_y.max(p.y),
				},
			),
		)
		label_extent = prepared.edge_labels.fold_with_index(
			extent2,
			|acc, label, i| {
				p = label_points.get(i) ?? Geom.point(0, 0)
				{ min_x: acc.min_x.min(p.x - label.width / 2), min_y: acc.min_y.min(p.y - label.height / 2), max_x: acc.max_x.max(p.x + label.width / 2), max_y: acc.max_y.max(p.y + label.height / 2) }
			},
		)
		dx = 0 - label_extent.min_x
		dy = 0 - label_extent.min_y
		{
			..canonical,
			layout: {
				positions: transformed_positions.map(|p| Geom.point(p.x + dx, p.y + dy)),
				routes: transformed_routes.map(|r| LayeredInternals.translate_route(r, dx, dy)),
				bounds: { ..Geom.empty_bounds, width: label_extent.max_x - label_extent.min_x, height: label_extent.max_y - label_extent.min_y },
			},
		}
	}

	## The finished drawing's edges: the points each edge passes on the layers
	## between its ends (moved with any hinted or pinned nodes), then either
	## straight routes through those points or orthogonal routes the router
	## guides through them.
	deliver = |spec, finished, positions| {
		layer_points = LayeredInternals.move_waypoints(finished.routes, finished.positions, positions, spec.edges, spec.direction)
		match spec.routing {
			Straight => LayeredInternals.straight_delivery(spec, positions, layer_points)
			Orthogonal(settings) => {
				guides = layer_points.map_with_index(|points, edge| { edge, points })
				base = { ..Route.default_input, graph: { nodes: spec.nodes, edges: spec.edges }, positions, attachments: spec.attachments, boundaries: spec.boundaries, edge_labels: spec.edge_labels }
				match Route.layout({ ..base, guides }, settings) {
					Ok(value) => { layout: value.layout, label_anchors: value.label_anchors, attachments: value.attachments, layer_points }
					Err(_) =>
						match Route.layout(base, settings) {
							Ok(value) => { layout: value.layout, label_anchors: value.label_anchors, attachments: value.attachments, layer_points }
							Err(_) => {
								pinned = { ..finished, positions }
								{ layout: pinned, label_anchors: LayeredInternals.label_anchors(spec.edge_labels, pinned.routes), attachments: [], layer_points }
							}
						}
				}
			}
		}
	}

	## Straight routes: each edge runs from its source's boundary through its
	## layer points to its target's boundary. A centered label sits on the
	## layer point reserved for it; any other label sits on its route.
	straight_delivery = |spec, positions, layer_points| {
		zero = { width: 0, height: 0 }
		routes = spec.edges.map_with_index(
			|edge, i| {
				from = positions.get(edge.from) ?? Geom.point(0, 0)
				to = positions.get(edge.to) ?? from
				points = [from].concat(layer_points.get(i) ?? []).append(to)
				LayeredInternals.make_route(LayeredInternals.clip_route_ends(points, spec.nodes.get(edge.from) ?? zero, spec.nodes.get(edge.to) ?? zero), Straight)
			},
		)
		anchors = spec.edge_labels.map(
			|label| {
				route = routes.get(label.edge) ?? Polyline([])
				count = (spec.chains.get(label.edge) ?? []).len()
				middle = count // 2
				match label.placement {
					Center if count >= 3 => {
						k = if spec.reversed_flags.get(label.edge) ?? False {
							count - 2 - middle
						} else {
							middle - 1
						}
						(layer_points.get(label.edge) ?? []).get(k) ?? CompoundRouting.route_anchor(route, Center)
					}
					placement => CompoundRouting.route_anchor(route, placement)
				}
			},
		)
		grow = |box, min_x, min_y, max_x, max_y| match box {
			None => Some({ min_x, min_y, max_x, max_y })
			Some(b) => Some({ min_x: b.min_x.min(min_x), min_y: b.min_y.min(min_y), max_x: b.max_x.max(max_x), max_y: b.max_y.max(max_y) })
		}
		with_nodes = positions.fold_with_index(
			None,
			|box, p, i| {
				n = spec.nodes.get(i) ?? zero
				grow(box, p.x - n.width / 2, p.y - n.height / 2, p.x + n.width / 2, p.y + n.height / 2)
			},
		)
		with_routes = routes.fold(with_nodes, |box, route| LayeredInternals.route_extent_points(route).fold(box, |inner, p| grow(inner, p.x, p.y, p.x, p.y)))
		with_labels = spec.edge_labels.fold_with_index(
			with_routes,
			|box, label, i| {
				p = anchors.get(i) ?? Geom.point(0, 0)
				grow(box, p.x - label.width / 2, p.y - label.height / 2, p.x + label.width / 2, p.y + label.height / 2)
			},
		)
		bounds = match with_labels {
			None => Geom.empty_bounds
			Some(b) => { x: b.min_x, y: b.min_y, width: Geom.saturate(b.max_x - b.min_x), height: Geom.saturate(b.max_y - b.min_y) }
		}
		{ layout: { positions, routes, bounds }, label_anchors: anchors, attachments: [], layer_points }
	}

	attachment_order_violations = |input, positions| {
		input.graph.nodes.fold_with_index(
			[],
			|all, _node, node_index| {
				incident = input.attachments.keep_if(
					|rule| match input.graph.edges.get(rule.edge) {
						Ok(edge) => match rule.endpoint {
							From => edge.from == node_index
							To => edge.to == node_index
						}
						Err(_) => False
					},
				)
				if incident.len() < 2 {
					all
				} else {
					LayeredInternals.indices_up_to(incident.len() - 1).fold(
						all,
						|acc, i| {
							a = incident.get(i) ?? { edge: 0, endpoint: From, attachment: Automatic }
							b = incident.get(i + 1) ?? a
							ea = input.graph.edges.get(a.edge) ?? { from: 0, to: 0 }
							eb = input.graph.edges.get(b.edge) ?? { from: 0, to: 0 }
							oa = if ea.from == node_index {
								ea.to
							} else {
								ea.from
							}
							ob = if eb.from == node_index {
								eb.to
							} else {
								eb.from
							}
							pa = positions.get(oa) ?? Geom.point(0, 0)
							pb = positions.get(ob) ?? Geom.point(0, 0)
							if pa.x > pb.x {
								acc.append({ node: node_index, before_edge: a.edge, after_edge: b.edge })
							} else {
								acc
							}
						},
					)
				}
			},
		)
	}

	label_anchors = |labels, routes| labels.map(
		|label| {
			route = routes.get(label.edge) ?? Polyline([])
			points = LayeredInternals.route_extent_points(route)
			if points.is_empty() {
				Geom.point(0, 0)
			} else {
				first = points.get(0) ?? Geom.point(0, 0)
				last = points.get(points.len() - 1) ?? first
				Geom.point((first.x + last.x) / 2, (first.y + last.y) / 2)
			}
		},
	)

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
			metadata = spec.attachments.fold_with_index(
				gap_problems,
				|acc, rule, i| if rule.edge >= spec.graph.edges.len() {
					acc.append(InvalidAttachmentEdge(i))
				} else {
					valid = match rule.attachment {
						Fixed(payload) => F64.is_finite(payload.offset) and payload.offset >= 0 and payload.offset <= 1
						_ => True
					}
					duplicate = spec.attachments.take_first(i).count_if(|other| other.edge == rule.edge and other.endpoint == rule.endpoint) > 0
					if !valid {
						acc.append(InvalidAttachmentOffset(i))
					} else if duplicate {
						acc.append(DuplicateAttachment(i))
					} else {
						acc
					}
				},
			)
			labels = spec.edge_labels.fold_with_index(
				metadata,
				|acc, label, i| if label.edge >= spec.graph.edges.len() {
					acc.append(InvalidEdgeLabelEdge(i))
				} else if !F64.is_finite(label.width) or label.width < 0 {
					acc.append(InvalidEdgeLabelWidth(i))
				} else if !F64.is_finite(label.height) or label.height < 0 {
					acc.append(InvalidEdgeLabelHeight(i))
				} else {
					acc
				},
			)
			boundaries = spec.boundaries.fold_with_index(
				labels,
				|acc, rule, i| if rule.node >= spec.graph.nodes.len() {
					acc.append(InvalidBoundaryNode(i))
				} else if spec.boundaries.take_first(i).count_if(|other| other.node == rule.node) > 0 {
					acc.append(DuplicateBoundary(i))
				} else {
					acc
				},
			)
			pin_problems = config.pins.fold_with_index(
				boundaries,
				|acc, pin, i| if pin.node >= spec.graph.nodes.len() {
					acc.append(MissingPinNode(i, pin.node))
				} else if !F64.is_finite(pin.x) or !F64.is_finite(pin.y) {
					acc.append(InvalidPin(i))
				} else if config.pins.take_first(i).any(|other| other.node == pin.node) {
					acc.append(DuplicatePin(i))
				} else {
					acc
				},
			)
			layer_rules = spec.layer_constraints.fold_with_index(
				pin_problems,
				|acc, rule, i| match rule {
					SameLayer(pair) => if pair.first >= spec.graph.nodes.len() {
						acc.append(MissingLayerConstraintNode(i, pair.first))
					} else if pair.second >= spec.graph.nodes.len() {
						acc.append(MissingLayerConstraintNode(i, pair.second))
					} else {
						acc
					}
					BeforeLayer(item) => if item.minimum_span < 1 {
						acc.append(InvalidLayerConstraintSpan(i))
					} else if item.first >= spec.graph.nodes.len() {
						acc.append(MissingLayerConstraintNode(i, item.first))
					} else if item.second >= spec.graph.nodes.len() {
						acc.append(MissingLayerConstraintNode(i, item.second))
					} else {
						acc
					}
					FirstLayer(node) => if node >= spec.graph.nodes.len() {
						acc.append(MissingLayerConstraintNode(i, node))
					} else {
						acc
					}
					LastLayer(node) => if node >= spec.graph.nodes.len() {
						acc.append(MissingLayerConstraintNode(i, node))
					} else {
						acc
					}
				},
			)
			order_rules = spec.order_constraints.fold_with_index(
				layer_rules,
				|acc, rule, i| if rule.before >= spec.graph.nodes.len() {
					acc.append(MissingOrderConstraintNode(i, rule.before))
				} else if rule.after >= spec.graph.nodes.len() {
					acc.append(MissingOrderConstraintNode(i, rule.after))
				} else {
					acc
				},
			)
			non_ranking = spec.non_ranking_edges.fold_with_index(
				order_rules,
				|acc, edge, i| if edge >= spec.graph.edges.len() {
					acc.append(MissingNonRankingEdge(i, edge))
				} else if spec.non_ranking_edges.take_first(i).contains(edge) {
					acc.append(DuplicateNonRankingEdge(i))
				} else {
					acc
				},
			)
			spec.edge_weights.fold_with_index(
				non_ranking,
				|acc, item, index| if item.edge >= spec.graph.edges.len() {
					acc.append(MissingEdgeWeightEdge(item.edge))
				} else if !F64.is_finite(item.weight) or item.weight < 0 {
					acc.append(InvalidEdgeWeight(item.edge))
				} else if spec.non_ranking_edges.contains(item.edge) {
					acc.append(NonRankingEdgeWeight(index, item.edge))
				} else {
					acc
				},
			).concat(
				spec.min_spans.fold_with_index(
					[],
					|acc, item, index| if item.edge >= spec.graph.edges.len() {
						acc.append(MissingMinimumSpanEdge(item.edge))
					} else if item.span < 1 {
						acc.append(InvalidMinimumSpan(item.edge))
					} else if spec.non_ranking_edges.contains(item.edge) {
						acc.append(NonRankingMinimumSpan(index, item.edge))
					} else {
						acc
					},
				),
			)
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
	direction : [Down, Up, Left, Right],
	max_sweeps : U64,
	ordering : [Median, Average],
	node_gap : F64,
	layer_gap : F64,
	routing : [Straight, Orthogonal(Route.Settings)],
	attachments : List(Route.AttachmentRule),
	boundaries : List(Route.BoundaryRule),
	edge_labels : List(Route.EdgeLabel),
	pins : List({ node : U64, x : F64, y : F64 }),
	precedences : List({ before : U64, after : U64 }),
}.{
	Config : { node_gap : F64, layer_gap : F64, routing : [Straight, Orthogonal(Route.Settings)], direction : [Down, Up, Left, Right], max_sweeps : U64, ordering : [Median, Average], pins : List({ node : U64, x : F64, y : F64 }) }
	Spec : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
		edge_weights : List({ edge : U64, weight : F64 }),
		min_spans : List({ edge : U64, span : U64 }),
		attachments : List(Route.AttachmentRule),
		boundaries : List(Route.BoundaryRule),
		edge_labels : List(Route.EdgeLabel),
		layer_constraints : List(Layered.LayerConstraint),
		order_constraints : List({ before : U64, after : U64 }),
		non_ranking_edges : List(U64),
	}
	Problem := [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
		MissingEdgeWeightEdge(U64),
		InvalidEdgeWeight(U64),
		NonRankingEdgeWeight(U64, U64),
		MissingMinimumSpanEdge(U64),
		InvalidMinimumSpan(U64),
		NonRankingMinimumSpan(U64, U64),
		InvalidAttachmentEdge(U64),
		InvalidAttachmentOffset(U64),
		DuplicateAttachment(U64),
		InvalidBoundaryNode(U64),
		DuplicateBoundary(U64),
		MissingPinNode(U64, U64),
		InvalidPin(U64),
		DuplicatePin(U64),
		ConflictingPins,
		InvalidEdgeLabelEdge(U64),
		InvalidEdgeLabelWidth(U64),
		InvalidEdgeLabelHeight(U64),
		MissingLayerConstraintNode(U64, U64),
		InvalidLayerConstraintSpan(U64),
		ConflictingLayerConstraints,
		MissingOrderConstraintNode(U64, U64),
		OrderConstraintAcrossLayers(U64),
		ConflictingOrderConstraints,
		MissingNonRankingEdge(U64, U64),
		DuplicateNonRankingEdge(U64),
		InvalidRouting(Route.Problem),
	].{
		is_eq : _

		## Turn one typed problem into a short explanation for a person reading a
		## log or error message. List positions and referenced values start at zero.
		to_str : Problem -> Str
		to_str = |problem| match problem {
			InvalidNodeWidth(node) => "Node ${node.to_str()} has a width that is negative or not a finite number."
			InvalidNodeHeight(node) => "Node ${node.to_str()} has a height that is negative or not a finite number."
			MissingEdgeStart(edge, node) => "Edge ${edge.to_str()} refers to source node ${node.to_str()}, which does not exist."
			MissingEdgeEnd(edge, node) => "Edge ${edge.to_str()} refers to target node ${node.to_str()}, which does not exist."
			InvalidNodeGap => "The node gap must be a finite number that is zero or greater."
			InvalidLayerGap => "The layer gap must be a finite number that is zero or greater."
			MissingEdgeWeightEdge(edge) => "An edge-weight setting refers to edge ${edge.to_str()}, which does not exist."
			InvalidEdgeWeight(edge) => "The weight for edge ${edge.to_str()} must be a finite number that is zero or greater."
			NonRankingEdgeWeight(item, edge) => "Edge-weight setting ${item.to_str()} refers to non-ranking edge ${edge.to_str()}, so it cannot affect layer assignment."
			MissingMinimumSpanEdge(edge) => "A minimum-span setting refers to edge ${edge.to_str()}, which does not exist."
			InvalidMinimumSpan(edge) => "The minimum span for edge ${edge.to_str()} must be at least one layer."
			NonRankingMinimumSpan(item, edge) => "Minimum-span setting ${item.to_str()} refers to non-ranking edge ${edge.to_str()}, so it cannot affect layer assignment."
			InvalidAttachmentEdge(item) => "Attachment rule ${item.to_str()} refers to an edge that does not exist."
			InvalidAttachmentOffset(item) => "Attachment rule ${item.to_str()} has an offset outside the range from 0 to 1."
			DuplicateAttachment(item) => "Attachment rule ${item.to_str()} repeats a rule for the same end of an edge."
			InvalidBoundaryNode(item) => "Boundary rule ${item.to_str()} refers to a node that does not exist."
			DuplicateBoundary(item) => "Boundary rule ${item.to_str()} repeats a rule for the same node."
			MissingPinNode(item, node) => "Pin ${item.to_str()} refers to node ${node.to_str()}, which does not exist."
			InvalidPin(item) => "Pin ${item.to_str()} has a coordinate that is not finite."
			DuplicatePin(item) => "Pin ${item.to_str()} repeats a pin for the same node."
			ConflictingPins => "The exact pins cannot coexist with aligned layers and the configured node and layer gaps."
			InvalidEdgeLabelEdge(item) => "Edge label ${item.to_str()} refers to an edge that does not exist."
			InvalidEdgeLabelWidth(item) => "Edge label ${item.to_str()} has a width that is negative or not finite."
			InvalidEdgeLabelHeight(item) => "Edge label ${item.to_str()} has a height that is negative or not finite."
			MissingLayerConstraintNode(item, node) => "Layer constraint ${item.to_str()} refers to node ${node.to_str()}, which does not exist."
			InvalidLayerConstraintSpan(item) => "Layer constraint ${item.to_str()} has a minimum span smaller than one."
			ConflictingLayerConstraints => "The layer constraints conflict with each other or with the graph's directed flow."
			MissingOrderConstraintNode(item, node) => "Order constraint ${item.to_str()} refers to node ${node.to_str()}, which does not exist."
			OrderConstraintAcrossLayers(item) => "Order constraint ${item.to_str()} names nodes that do not share a layer."
			ConflictingOrderConstraints => "The order constraints conflict with each other or with endpoint attachment order."
			MissingNonRankingEdge(item, edge) => "Non-ranking edge entry ${item.to_str()} refers to edge ${edge.to_str()}, which does not exist."
			DuplicateNonRankingEdge(item) => "Non-ranking edge entry ${item.to_str()} repeats an earlier edge."
			InvalidRouting(route_problem) => "Routing settings are invalid: ${route_problem.to_str()}"
		}
	}

	defaults : Config
	defaults = { node_gap: 24, layer_gap: 70, routing: Orthogonal(Route.default_settings), direction: Down, max_sweeps: 4, ordering: Median, pins: [] }

	default_spec : Spec
	default_spec = { graph: { nodes: [], edges: [] }, edge_weights: [], min_spans: [], attachments: [], boundaries: [], edge_labels: [], layer_constraints: [], order_constraints: [], non_ranking_edges: [] }

	build : Spec, Config -> [Ok(Prepared), Err(List(Problem))]
	build = |spec, config| {
		routing_problems = match config.routing {
			Straight => []
			Orthogonal(settings) =>
				match Route.layout(Route.default_input, settings) {
					Ok(_) => []
					Err(items) => items.map(|item| InvalidRouting(item))
				}
		}
		problems = LayeredInternals.validation_problems(spec, { node_gap: config.node_gap, layer_gap: config.layer_gap, route_style: Straight, direction: config.direction, max_sweeps: config.max_sweeps, pins: config.pins }).concat(routing_problems)
		if !problems.is_empty() {
			Err(problems)
		} else {
			non_ranking_flags = LayeredInternals.membership_flags(spec.graph.edges.len(), spec.non_ranking_edges)
			active_indices = LayeredInternals.indices_up_to(spec.graph.edges.len()).keep_if(|i| !(non_ranking_flags.get(i) ?? False))
			active_edges = active_indices.map(|i| spec.graph.edges.get(i) ?? { from: 0, to: 0 })
			active_oriented = LayeredInternals.orient_edges(spec.graph.nodes.len(), active_edges)
			active_reversed = active_indices.fold_with_index(
				[],
				|acc, edge, i| if active_oriented.reversed_flags.get(i) ?? False {
					acc.append(edge)
				} else {
					acc
				},
			)
			active_flags = LayeredInternals.membership_flags(spec.graph.edges.len(), active_reversed)
			oriented_edges = spec.graph.edges.map_with_index(
				|edge, i| if active_flags.get(i) ?? False {
					{ from: edge.to, to: edge.from }
				} else {
					edge
				},
			)
			weights = spec.edge_weights.fold(List.repeat(1, spec.graph.edges.len()), |acc, item| acc.set(item.edge, item.weight) ?? acc)
			base_spans = spec.min_spans.fold(List.repeat(1, spec.graph.edges.len()), |acc, item| acc.set(item.edge, item.span) ?? acc)
			spans = spec.edge_labels.fold(
				base_spans,
				|acc, label| match label.placement {
					Center => acc.set(label.edge, (acc.get(label.edge) ?? 1).max(2)) ?? []
					Near(_) => acc
				},
			)
			active_weights = active_indices.map(|i| weights.get(i) ?? 1)
			active_spans = active_indices.map(|i| spans.get(i) ?? 1)
			base_ranks = LayeredInternals.rank_nodes_spec(spec.graph.nodes.len(), active_oriented.edges, active_weights, active_spans)
			real_ranks = LayeredInternals.constrain_ranks(spec.graph.nodes.len(), active_oriented.edges, active_spans, base_ranks, spec.layer_constraints)
			if !LayeredInternals.layer_constraints_hold(real_ranks, spec.layer_constraints) or !LayeredInternals.ranking_holds(real_ranks, active_oriented.edges, active_spans) {
				Err([ConflictingLayerConstraints])
			} else {
				extended = LayeredInternals.insert_virtual_chains(real_ranks, oriented_edges)
				ordered_layers = LayeredInternals.order_layers_by(LayeredInternals.group_by_rank(extended.ranks), extended.unit_edges, config.max_sweeps, config.ordering)
				precedences = LayeredInternals.canonical_precedences(LayeredInternals.attachment_precedences(spec.graph, spec.attachments).concat(LayeredInternals.explicit_precedences(spec.order_constraints)), config.direction)
				order_problems = spec.order_constraints.fold_with_index(
					[],
					|acc, rule, i| if (real_ranks.get(rule.before) ?? 0) != (real_ranks.get(rule.after) ?? 0) {
						acc.append(OrderConstraintAcrossLayers(i))
					} else {
						acc
					},
				)
				legal_layers = LayeredInternals.enforce_precedences(ordered_layers, precedences)
				if !order_problems.is_empty() {
					Err(order_problems)
				} else if !LayeredInternals.precedences_hold(legal_layers, precedences) {
					Err([ConflictingOrderConstraints])
				} else {
					candidate = {
						nodes: spec.graph.nodes,
						edges: spec.graph.edges,
						reversed: active_reversed,
						reversed_flags: active_flags,
						real_ranks,
						extended_ranks: extended.ranks,
						chains: extended.chains,
						unit_edges: extended.unit_edges,
						ordered_layers,
						precedences,
						direction: config.direction,
						max_sweeps: config.max_sweeps,
						ordering: config.ordering,
						node_gap: config.node_gap,
						layer_gap: config.layer_gap,
						routing: config.routing,
						attachments: spec.attachments,
						boundaries: spec.boundaries,
						edge_labels: spec.edge_labels,
						pins: config.pins,
					}
					real_layers = candidate.ordered_layers.map(|layer| layer.keep_if(|node| node < candidate.nodes.len())).keep_if(|layer| !layer.is_empty())
					if LayeredInternals.pin_geometry_conflict(candidate.real_ranks, real_layers, candidate.nodes, candidate.pins, candidate.direction, candidate.node_gap, candidate.layer_gap) {
						Err([ConflictingPins])
					} else {
						Ok(candidate)
					}
				}
			}
		}
	}

	RunArgs : { hints : List({ node : U64, x : F64, y : F64 }), stability : [Reflow, PreserveOrder] }

	## Reflow for best layout quality without previous-position hints.
	default_run : RunArgs
	default_run = { hints: [], stability: Reflow }

	run : Prepared,
	RunArgs -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
		label_anchors : List({ x : F64, y : F64 }),
		attachments : List(Route.EdgeAttachments),
		layer_points : List(List({ x : F64, y : F64 })),
	}
	run = |sweep, args| {
		canonical = LayeredInternals.canonical_hints(args.hints, sweep.nodes.len(), sweep.direction)
		seeded = match canonical {
			None => LayeredInternals.group_by_rank(sweep.extended_ranks)
			Some(hints) => LayeredInternals.hinted_layers(LayeredInternals.group_by_rank(sweep.extended_ranks), sweep.chains, hints.points, sweep.reversed_flags)
		}
		stable = match (args.stability, canonical) {
			(PreserveOrder, Some(hints)) => seeded.map(
				|layer| {
					hinted = layer.keep_if(|node| hints.nodes.contains(node))
					if hinted.len() < 2 {
						[]
					} else {
						LayeredInternals.indices_up_to(hinted.len() - 1).map(|i| { before: hinted.get(i) ?? 0, after: hinted.get(i + 1) ?? 0 })
					}
				},
			).join()
			_ => []
		}
		precedences = LayeredInternals.compatible_precedences(sweep.extended_ranks.len(), sweep.precedences, stable)
		# Without hints or ordering rules, the ordering is exactly the one
		# preparation already computed from the same rank grouping.
		ordered = match canonical {
			None if precedences.is_empty() => sweep.ordered_layers
			_ => LayeredInternals.enforce_precedences(LayeredInternals.order_layers_by(LayeredInternals.enforce_precedences(seeded, precedences), sweep.unit_edges, sweep.max_sweeps, sweep.ordering), precedences)
		}
		finished = LayeredInternals.finish_layout({
			nodes: sweep.nodes,
			edges: sweep.edges,
			reversed: sweep.reversed,
			reversed_flags: sweep.reversed_flags,
			real_ranks: sweep.real_ranks,
			extended_ranks: sweep.extended_ranks,
			chains: sweep.chains,
			unit_edges: sweep.unit_edges,
			ordered_layers: ordered,
			direction: sweep.direction,
			edge_labels: sweep.edge_labels,
			node_gap: sweep.node_gap,
			layer_gap: sweep.layer_gap,
			route_style: Straight,
		})
		hinted_positions = LayeredInternals.apply_hints(finished.layout.positions, ordered, sweep.nodes, args.hints, sweep.direction, sweep.node_gap, sweep.layer_gap)
		positions = LayeredInternals.apply_pins(hinted_positions, sweep.real_ranks, sweep.pins, sweep.direction)
		delivered = LayeredInternals.deliver(
			{ nodes: sweep.nodes, edges: sweep.edges, chains: sweep.chains, reversed_flags: sweep.reversed_flags, attachments: sweep.attachments, boundaries: sweep.boundaries, edge_labels: sweep.edge_labels, direction: sweep.direction, routing: sweep.routing },
			finished.layout,
			positions,
		)
		{ layout: delivered.layout, layers: finished.layers, backward_edges: finished.backward_edges, label_anchors: delivered.label_anchors, attachments: delivered.attachments, layer_points: delivered.layer_points }
	}

	layout : Spec,
	Config,
	RunArgs -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				layers : List(U64),
				backward_edges : List(U64),
				label_anchors : List({ x : F64, y : F64 }),
				attachments : List(Route.EdgeAttachments),
				layer_points : List(List({ x : F64, y : F64 })),
			},
		),
		Err(List(Problem)),
	]
	layout = |spec, config, args|
		match Prepared.build(spec, config) {
			Ok(sweep) => Ok(sweep.run(args))
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
	direction : [Down, Up, Left, Right],
	proven_optimal : Bool,
	node_gap : F64,
	layer_gap : F64,
	routing : [Straight, Orthogonal(Route.Settings)],
	attachments : List(Route.AttachmentRule),
	boundaries : List(Route.BoundaryRule),
	edge_labels : List(Route.EdgeLabel),
	precedences : List({ before : U64, after : U64 }),
	pins : List({ node : U64, x : F64, y : F64 }),
}.{
	Config : { node_gap : F64, layer_gap : F64, routing : [Straight, Orthogonal(Route.Settings)], effort_cap : U64, direction : [Down, Up, Left, Right], pins : List({ node : U64, x : F64, y : F64 }) }
	Spec : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
		edge_weights : List({ edge : U64, weight : F64 }),
		min_spans : List({ edge : U64, span : U64 }),
		attachments : List(Route.AttachmentRule),
		boundaries : List(Route.BoundaryRule),
		edge_labels : List(Route.EdgeLabel),
		layer_constraints : List(Layered.LayerConstraint),
		order_constraints : List({ before : U64, after : U64 }),
		non_ranking_edges : List(U64),
	}
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
		MissingEdgeWeightEdge(U64),
		InvalidEdgeWeight(U64),
		NonRankingEdgeWeight(U64, U64),
		MissingMinimumSpanEdge(U64),
		InvalidMinimumSpan(U64),
		NonRankingMinimumSpan(U64, U64),
		InvalidAttachmentEdge(U64),
		InvalidAttachmentOffset(U64),
		DuplicateAttachment(U64),
		InvalidBoundaryNode(U64),
		DuplicateBoundary(U64),
		MissingPinNode(U64, U64),
		InvalidPin(U64),
		DuplicatePin(U64),
		ConflictingPins,
		InvalidEdgeLabelEdge(U64),
		InvalidEdgeLabelWidth(U64),
		InvalidEdgeLabelHeight(U64),
		MissingLayerConstraintNode(U64, U64),
		InvalidLayerConstraintSpan(U64),
		ConflictingLayerConstraints,
		MissingOrderConstraintNode(U64, U64),
		OrderConstraintAcrossLayers(U64),
		ConflictingOrderConstraints,
		MissingNonRankingEdge(U64, U64),
		DuplicateNonRankingEdge(U64),
		InvalidRouting(Route.Problem),
	]

	## Turn one typed problem into a short explanation for a person reading a
	## log or error message. List positions and referenced values start at zero.
	problem_to_str : Problem -> Str
	problem_to_str = |problem| match problem {
		InvalidNodeWidth(node) => "Node ${node.to_str()} has a width that is negative or not a finite number."
		InvalidNodeHeight(node) => "Node ${node.to_str()} has a height that is negative or not a finite number."
		MissingEdgeStart(edge, node) => "Edge ${edge.to_str()} refers to source node ${node.to_str()}, which does not exist."
		MissingEdgeEnd(edge, node) => "Edge ${edge.to_str()} refers to target node ${node.to_str()}, which does not exist."
		InvalidNodeGap => "The node gap must be a finite number that is zero or greater."
		InvalidLayerGap => "The layer gap must be a finite number that is zero or greater."
		MissingEdgeWeightEdge(edge) => "An edge-weight setting refers to edge ${edge.to_str()}, which does not exist."
		InvalidEdgeWeight(edge) => "The weight for edge ${edge.to_str()} must be a finite number that is zero or greater."
		NonRankingEdgeWeight(item, edge) => "Edge-weight setting ${item.to_str()} refers to non-ranking edge ${edge.to_str()}, so it cannot affect layer assignment."
		MissingMinimumSpanEdge(edge) => "A minimum-span setting refers to edge ${edge.to_str()}, which does not exist."
		InvalidMinimumSpan(edge) => "The minimum span for edge ${edge.to_str()} must be at least one layer."
		NonRankingMinimumSpan(item, edge) => "Minimum-span setting ${item.to_str()} refers to non-ranking edge ${edge.to_str()}, so it cannot affect layer assignment."
		InvalidAttachmentEdge(item) => "Attachment rule ${item.to_str()} refers to an edge that does not exist."
		InvalidAttachmentOffset(item) => "Attachment rule ${item.to_str()} has an offset outside the range from 0 to 1."
		DuplicateAttachment(item) => "Attachment rule ${item.to_str()} repeats a rule for the same end of an edge."
		InvalidBoundaryNode(item) => "Boundary rule ${item.to_str()} refers to a node that does not exist."
		DuplicateBoundary(item) => "Boundary rule ${item.to_str()} repeats a rule for the same node."
		MissingPinNode(item, node) => "Pin ${item.to_str()} refers to node ${node.to_str()}, which does not exist."
		InvalidPin(item) => "Pin ${item.to_str()} has a coordinate that is not finite."
		DuplicatePin(item) => "Pin ${item.to_str()} repeats a pin for the same node."
		ConflictingPins => "The exact pins cannot coexist with aligned layers and the configured node and layer gaps."
		InvalidEdgeLabelEdge(item) => "Edge label ${item.to_str()} refers to an edge that does not exist."
		InvalidEdgeLabelWidth(item) => "Edge label ${item.to_str()} has a width that is negative or not finite."
		InvalidEdgeLabelHeight(item) => "Edge label ${item.to_str()} has a height that is negative or not finite."
		MissingLayerConstraintNode(item, node) => "Layer constraint ${item.to_str()} refers to node ${node.to_str()}, which does not exist."
		InvalidLayerConstraintSpan(item) => "Layer constraint ${item.to_str()} has a minimum span smaller than one."
		ConflictingLayerConstraints => "The layer constraints conflict with each other or with the graph's directed flow."
		MissingOrderConstraintNode(item, node) => "Order constraint ${item.to_str()} refers to node ${node.to_str()}, which does not exist."
		OrderConstraintAcrossLayers(item) => "Order constraint ${item.to_str()} names nodes that do not share a layer."
		ConflictingOrderConstraints => "The order constraints conflict with each other or with endpoint attachment order."
		MissingNonRankingEdge(item, edge) => "Non-ranking edge entry ${item.to_str()} refers to edge ${edge.to_str()}, which does not exist."
		DuplicateNonRankingEdge(item) => "Non-ranking edge entry ${item.to_str()} repeats an earlier edge."
		InvalidRouting(route_problem) => "Routing settings are invalid: ${route_problem.to_str()}"
	}

	defaults : Config
	defaults = { node_gap: 24, layer_gap: 70, routing: Orthogonal(Route.default_settings), effort_cap: 100_000, direction: Down, pins: [] }

	build : Spec, Config -> [Ok(ExactPrepared), Err(List(Problem))]
	build = |spec, config| {
		routing_problems = match config.routing {
			Straight => []
			Orthogonal(settings) =>
				match Route.layout(Route.default_input, settings) {
					Ok(_) => []
					Err(items) => items.map(|item| InvalidRouting(item))
				}
		}
		problems = LayeredInternals.validation_problems(spec, { node_gap: config.node_gap, layer_gap: config.layer_gap, route_style: Straight, direction: config.direction, max_sweeps: 4, pins: config.pins }).concat(routing_problems)
		if !problems.is_empty() {
			Err(problems)
		} else {
			non_ranking_flags = LayeredInternals.membership_flags(spec.graph.edges.len(), spec.non_ranking_edges)
			active_indices = LayeredInternals.indices_up_to(spec.graph.edges.len()).keep_if(|i| !(non_ranking_flags.get(i) ?? False))
			active_edges = active_indices.map(|i| spec.graph.edges.get(i) ?? { from: 0, to: 0 })
			active_oriented = LayeredInternals.orient_edges(spec.graph.nodes.len(), active_edges)
			active_reversed = active_indices.fold_with_index(
				[],
				|acc, edge, i| if active_oriented.reversed_flags.get(i) ?? False {
					acc.append(edge)
				} else {
					acc
				},
			)
			active_flags = LayeredInternals.membership_flags(spec.graph.edges.len(), active_reversed)
			oriented_edges = spec.graph.edges.map_with_index(
				|edge, i| if active_flags.get(i) ?? False {
					{ from: edge.to, to: edge.from }
				} else {
					edge
				},
			)
			weights = spec.edge_weights.fold(List.repeat(1, spec.graph.edges.len()), |acc, item| acc.set(item.edge, item.weight) ?? acc)
			base_spans = spec.min_spans.fold(List.repeat(1, spec.graph.edges.len()), |acc, item| acc.set(item.edge, item.span) ?? acc)
			spans = spec.edge_labels.fold(
				base_spans,
				|acc, label| match label.placement {
					Center => acc.set(label.edge, (acc.get(label.edge) ?? 1).max(2)) ?? []
					Near(_) => acc
				},
			)
			active_weights = active_indices.map(|i| weights.get(i) ?? 1)
			active_spans = active_indices.map(|i| spans.get(i) ?? 1)
			base_ranks = LayeredInternals.rank_nodes_spec(spec.graph.nodes.len(), active_oriented.edges, active_weights, active_spans)
			real_ranks = LayeredInternals.constrain_ranks(spec.graph.nodes.len(), active_oriented.edges, active_spans, base_ranks, spec.layer_constraints)
			if !LayeredInternals.layer_constraints_hold(real_ranks, spec.layer_constraints) or !LayeredInternals.ranking_holds(real_ranks, active_oriented.edges, active_spans) {
				Err([ConflictingLayerConstraints])
			} else {
				extended = LayeredInternals.insert_virtual_chains(real_ranks, oriented_edges)
				precedences = LayeredInternals.canonical_precedences(LayeredInternals.attachment_precedences(spec.graph, spec.attachments).concat(LayeredInternals.explicit_precedences(spec.order_constraints)), config.direction)
				order_problems = spec.order_constraints.fold_with_index(
					[],
					|acc, rule, i| if (real_ranks.get(rule.before) ?? 0) != (real_ranks.get(rule.after) ?? 0) {
						acc.append(OrderConstraintAcrossLayers(i))
					} else {
						acc
					},
				)
				legal_layers = LayeredInternals.enforce_precedences(LayeredInternals.group_by_rank(extended.ranks), precedences)
				if !order_problems.is_empty() {
					Err(order_problems)
				} else if !LayeredInternals.precedences_hold(legal_layers, precedences) {
					Err([ConflictingOrderConstraints])
				} else {
					constrained_layers = legal_layers
					searched = LayeredInternals.exact_order_layers(constrained_layers, extended.unit_edges, config.effort_cap)
					exact_legal = LayeredInternals.enforce_precedences(searched.layers, precedences)
					sweep_legal = LayeredInternals.enforce_precedences(LayeredInternals.order_layers(constrained_layers, extended.unit_edges, 4), precedences)
					exact_cost = LayeredInternals.total_crossings(extended.ranks.len(), exact_legal, extended.unit_edges)
					sweep_cost = LayeredInternals.total_crossings(extended.ranks.len(), sweep_legal, extended.unit_edges)
					chosen = if exact_cost <= sweep_cost {
						exact_legal
					} else {
						sweep_legal
					}

					candidate = {
						nodes: spec.graph.nodes,
						edges: spec.graph.edges,
						reversed: active_reversed,
						reversed_flags: active_flags,
						real_ranks,
						extended_ranks: extended.ranks,
						chains: extended.chains,
						unit_edges: extended.unit_edges,
						ordered_layers: chosen,
						precedences,
						direction: config.direction,
						# The current exhaustive search enumerates unconstrained permutations;
						# post-enforcement is deterministic but cannot certify constrained
						# optimality until the search enumerates linear extensions directly.
						proven_optimal: searched.proven_optimal and precedences.is_empty(),
						node_gap: config.node_gap,
						layer_gap: config.layer_gap,
						routing: config.routing,
						attachments: spec.attachments,
						boundaries: spec.boundaries,
						edge_labels: spec.edge_labels,
						pins: config.pins,
					}
					real_layers = candidate.ordered_layers.map(|layer| layer.keep_if(|node| node < candidate.nodes.len())).keep_if(|layer| !layer.is_empty())
					if LayeredInternals.pin_geometry_conflict(candidate.real_ranks, real_layers, candidate.nodes, candidate.pins, candidate.direction, candidate.node_gap, candidate.layer_gap) {
						Err([ConflictingPins])
					} else {
						Ok(candidate)
					}
				}
			}
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
		label_anchors : List({ x : F64, y : F64 }),
		attachments : List(Route.EdgeAttachments),
		layer_points : List(List({ x : F64, y : F64 })),
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
			direction: exact.direction,
			edge_labels: exact.edge_labels,
			node_gap: exact.node_gap,
			layer_gap: exact.layer_gap,
			route_style: Straight,
		})

		positions = LayeredInternals.apply_pins(finished.layout.positions, exact.real_ranks, exact.pins, exact.direction)
		delivered = LayeredInternals.deliver(
			{ nodes: exact.nodes, edges: exact.edges, chains: exact.chains, reversed_flags: exact.reversed_flags, attachments: exact.attachments, boundaries: exact.boundaries, edge_labels: exact.edge_labels, direction: exact.direction, routing: exact.routing },
			finished.layout,
			positions,
		)
		{
			layout: delivered.layout,
			layers: finished.layers,
			backward_edges: finished.backward_edges,
			proven_optimal: exact.proven_optimal,
			label_anchors: delivered.label_anchors,
			attachments: delivered.attachments,
			layer_points: delivered.layer_points,
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
				label_anchors : List({ x : F64, y : F64 }),
				attachments : List(Route.EdgeAttachments),
				layer_points : List(List({ x : F64, y : F64 })),
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

	## Hard relationships between node layers. `BeforeLayer` follows the
	## selected flow direction, so it has the same meaning for every direction.
	LayerConstraint : [SameLayer({ first : U64, second : U64 }), BeforeLayer({ first : U64, second : U64, minimum_span : U64 }), FirstLayer(U64), LastLayer(U64)]

	## Directed flow input. Edge identity is its index. Most callers only set
	## `graph`; the sparse lists add labels, endpoint geometry, or authored
	## placement. Layer constraints describe flow-relative rows, order
	## constraints arrange nodes that share a row, and non-ranking edges are
	## routed without influencing rows or cycle breaking. In an order
	## constraint, `before` means visually left of `after` for vertical flow and
	## visually above it for horizontal flow, regardless of direction.
	Input : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
		edge_weights : List({ edge : U64, weight : F64 }),
		min_spans : List({ edge : U64, span : U64 }),
		attachments : List(Route.AttachmentRule),
		boundaries : List(Route.BoundaryRule),
		edge_labels : List(Route.EdgeLabel),
		layer_constraints : List(LayerConstraint),
		order_constraints : List({ before : U64, after : U64 }),
		non_ranking_edges : List(U64),
	}

	## How edges are drawn once nodes are placed.
	##
	## `Orthogonal` routes every edge with right-angled segments clear of all
	## node boxes, guided through its `layer_points`. Its settings set
	## clearance, edge separation, and path preferences exactly as for
	## `Route.layout`.
	##
	## `Straight` draws each edge as straight segments from its source's
	## boundary through its layer points to its target's boundary. It skips
	## routing, which is most of the cost of laying out a large graph, and
	## suits callers that draw edges themselves from `layer_points`. A
	## self-loop has no straight route: it is a zero-length line at its node's
	## center. Straight drawings report no `attachments`.
	Routing : [Straight, Orthogonal(Route.Settings)]

	## Space between nodes on the same layer (`node_gap`) and between adjacent
	## layers (`layer_gap`), the way the flow runs, how layers are ordered,
	## and how edges are drawn (`routing`).
	##
	## `max_sweeps` caps the rounds of crossing reduction. `ordering` chooses
	## how each round orders a layer from its neighbors in the adjacent one:
	##
	## - `Median` moves each node toward the median position of its
	##   neighbors, then swaps adjacent nodes wherever that removes crossings.
	##   It usually draws the fewest crossings, and is the default.
	## - `Average` moves each node toward the average position of its
	##   neighbors, keeps nodes that tie in their current order (at first,
	##   the input order), and makes no swaps. Drawings follow the input
	##   order more closely, as ELK's layered layouts (used by Mermaid) do,
	##   at the cost of some crossings `Median` would remove.
	##
	## Sparse pins hold node centers exactly; preparation reports pins that
	## cannot coexist with strict layer alignment and configured gaps.
	Settings : { node_gap : F64, layer_gap : F64, routing : Routing, direction : [Down, Up, Left, Right], max_sweeps : U64, ordering : [Median, Average], pins : List({ node : U64, x : F64, y : F64 }) }

	## Per-layout choices. Hints are sparse and addressed by node index; invalid
	## run-time entries are ignored and the final valid duplicate wins.
	## `PreserveOrder` keeps the mutual within-layer order of hinted nodes while
	## allowing unhinted nodes to be inserted. Authored constraints take priority.
	RunArgs : { hints : List({ node : U64, x : F64, y : F64 }), stability : [Reflow, PreserveOrder] }

	## Invalid sizes, spacing, references, or authored relationships found while
	## checking input. `NonRankingEdgeWeight` and
	## `NonRankingMinimumSpan` report the sparse setting index followed by its
	## edge index.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidLayerGap,
		MissingEdgeWeightEdge(U64),
		InvalidEdgeWeight(U64),
		NonRankingEdgeWeight(U64, U64),
		MissingMinimumSpanEdge(U64),
		InvalidMinimumSpan(U64),
		NonRankingMinimumSpan(U64, U64),
		InvalidAttachmentEdge(U64),
		InvalidAttachmentOffset(U64),
		DuplicateAttachment(U64),
		InvalidBoundaryNode(U64),
		DuplicateBoundary(U64),
		MissingPinNode(U64, U64),
		InvalidPin(U64),
		DuplicatePin(U64),
		ConflictingPins,
		InvalidEdgeLabelEdge(U64),
		InvalidEdgeLabelWidth(U64),
		InvalidEdgeLabelHeight(U64),
		MissingLayerConstraintNode(U64, U64),
		InvalidLayerConstraintSpan(U64),
		ConflictingLayerConstraints,
		MissingOrderConstraintNode(U64, U64),
		OrderConstraintAcrossLayers(U64),
		ConflictingOrderConstraints,
		MissingNonRankingEdge(U64, U64),
		DuplicateNonRankingEdge(U64),
		InvalidRouting(Route.Problem),
	]

	## Explain one validation problem in plain language. Numbers identify
	## zero-based positions or referenced values as stated in each message.
	problem_to_str : Problem -> Str
	problem_to_str = |problem| ExactPrepared.problem_to_str(problem)

	## Geometry plus each node's layer and any edges drawn against the flow.
	## Positions hold node centers; route endpoints lie on the source and
	## target node boundaries.
	##
	## `layer_points` holds, for each edge, one point on every layer strictly
	## between its two nodes, in order from source to target; an edge between
	## adjacent layers has none. Along the flow each point lies on the side of
	## its layer that the flow reaches first; across the flow it is spaced
	## from its neighbors like a node of zero width. A centered edge label
	## takes its edge's middle point, which is then the center of the space
	## reserved for the label. Straight routes pass through exactly these
	## points; orthogonal routes are guided by them.
	##
	## `attachments` reports where each orthogonal route meets its two nodes.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
		label_anchors : List({ x : F64, y : F64 }),
		attachments : List(Route.EdgeAttachments),
		layer_points : List(List({ x : F64, y : F64 })),
	}

	## Empty flow input. Replace `graph` by record update.
	default_input : Input
	default_input = Prepared.default_spec

	## Settings that produce a readable top-to-bottom layout in common cases.
	default_settings : Settings
	default_settings = Prepared.defaults

	## Reflow for best layout quality without previous-position hints.
	default_run : RunArgs
	default_run = Prepared.default_run

	## Check the input and settings, then cache work reusable across layouts.
	prepare : Input, Settings -> [Ok(Prepared), Err(List(Problem))]
	prepare = |input, settings| Prepared.build(input, settings)

	## Lay out previously prepared input. This operation cannot fail.
	layout_prepared : Prepared, RunArgs -> Result
	layout_prepared = |prepared, args| prepared.run(args)

	## Check and lay out input in one call. This is the usual entry point.
	layout : Input, Settings, RunArgs -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings, args| Prepared.layout(input, settings, args)

	## Settings for `layout_exact`: spacing and routing exactly as in
	## `Settings`, plus `effort_cap` — the most ordering choices the crossing
	## search may try before stopping with the best ordering found so far.
	## Higher caps prove optimality on wider layers at higher cost; a cap of
	## zero still returns a deterministic best-known order. Pins have the same
	## exact-coordinate and preparation-conflict behavior as `Settings`.
	## `0` skips the search entirely and keeps the ordering `layout` would
	## produce.
	ExactSettings : { node_gap : F64, layer_gap : F64, routing : Routing, effort_cap : U64, direction : [Down, Up, Left, Right], pins : List({ node : U64, x : F64, y : F64 }) }

	## Everything `Result` reports, plus whether the crossing search proved
	## its ordering has the fewest crossings any ordering can achieve:
	## `True` when the search finished within the effort cap or the ordering
	## is crossing-free, `False` when the cap stopped the search early or hard
	## ordering rules were applied after the unconstrained search.
	ExactResult : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		layers : List(U64),
		backward_edges : List(U64),
		proven_optimal : Bool,
		label_anchors : List({ x : F64, y : F64 }),
		attachments : List(Route.EdgeAttachments),
		layer_points : List(List({ x : F64, y : F64 })),
	}

	## Default spacing and routing with an effort cap of 100,000 ordering
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
	final = LayeredInternals.order_layers(layers, unit_edges, 4)
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
	ordered = LayeredInternals.order_layers(layers, unit_edges, 4)
	final = LayeredInternals.total_crossings(8, ordered, unit_edges)
	final <= initial and ordered == LayeredInternals.order_layers(layers, unit_edges, 4)
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
	match Prepared.build(spec, config) {
		Ok(_) => False
		Err(problems) => problems == [
			InvalidNodeWidth(0),
			InvalidNodeHeight(0),
			MissingEdgeEnd(0, 3),
			InvalidNodeGap,
		]
	}
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
			result = sweep.run(Prepared.default_run)
			result.backward_edges == [] and result.layers == [1, 0] and result.layout.routes.len() == 1 and result.attachments.len() == 1
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
			result = sweep.run(Prepared.default_run)
			result.backward_edges == [1] and result.layers == [0, 1] and result.layout.routes.len() == 2 and result.attachments.len() == 2
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
		Ok(prepared) => Prepared.layout(spec, Prepared.defaults, Prepared.default_run) == Ok(prepared.run(Prepared.default_run))
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
	match Prepared.layout(spec, Prepared.defaults, Prepared.default_run) {
		Err(_) => False
		Ok(result) => match result.attachments.first() {
			Ok(ends) => ends.from.side == Bottom and ends.to.side == Top
			Err(_) => False
		}
	}
}

## The default routes every span through the shared orthogonal solver.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	match Prepared.layout(spec, Prepared.defaults, Prepared.default_run) {
		Err(_) => False
		Ok(result) => result.layout.routes.len() == 3 and result.layout.routes.all(
			|route| match route {
				Polyline(points) => points.len() >= 2
				_ => False
			},
		)
	}
}

## The default router keeps the same long edge as an orthogonal polyline.
expect {
	spec = {
		..Prepared.default_spec,
		graph: {
			nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }, { width: 10, height: 6 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }],
		},
	}
	match Prepared.layout(spec, Prepared.defaults, Prepared.default_run) {
		Err(_) => False
		Ok(result) => match result.layout.routes.get(2) ?? Polyline([]) {
			Polyline(points) => points.len() >= 2
			_ => False
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
	Layered.layout(input, Layered.default_settings, Layered.default_run) == Layered.layout(input, Layered.default_settings, Layered.default_run)
}

## Caller constraints use flow-relative language and remain hard through the
## crossing sweeps: nodes 0 and 1 share the first layer in the requested order.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 3), edges: [{ from: 0, to: 2 }, { from: 1, to: 2 }] },
		layer_constraints: [SameLayer({ first: 0, second: 1 }), FirstLayer(0)],
		order_constraints: [{ before: 1, after: 0 }],
	}
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
		Ok(result) => result.layers == [0, 0, 1] and (result.layout.positions.get(1) ?? Geom.point(0, 0)).x <= (result.layout.positions.get(0) ?? Geom.point(0, 0)).x
		Err(_) => False
	}
}

## A non-ranking relationship is still routed in source order but does not
## make the active flow cyclic or appear among the reversed edges.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 3), edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }] },
		non_ranking_edges: [2],
	}
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
		Ok(result) => result.layers == [0, 1, 2] and result.backward_edges == [] and result.layout.routes.len() == 3
		Err(_) => False
	}
}

## Authored order is stronger than edit-to-edit stability. Reversed previous
## positions cannot overturn the prepared rule.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 2), edges: [] },
		layer_constraints: [SameLayer({ first: 0, second: 1 })],
		order_constraints: [{ before: 0, after: 1 }],
	}
	args = { hints: [{ node: 0, x: 100, y: 0 }, { node: 1, x: 0, y: 0 }], stability: PreserveOrder }
	match Layered.layout(input, Layered.default_settings, args) {
		Ok(result) => (result.layout.positions.get(0) ?? Geom.point(0, 0)).x < (result.layout.positions.get(1) ?? Geom.point(0, 0)).x
		Err(_) => False
	}
}

## `before` always follows the visible cross-axis: left-to-right for vertical
## flow and top-to-bottom for horizontal flow.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 2), edges: [] },
		layer_constraints: [SameLayer({ first: 0, second: 1 })],
		order_constraints: [{ before: 0, after: 1 }],
	}
	[Down, Up, Right, Left].all(
		|direction| match Layered.layout(input, { ..Layered.default_settings, direction }, Layered.default_run) {
			Err(_) => False
			Ok(result) => {
				a = result.layout.positions.get(0) ?? Geom.point(0, 0)
				b = result.layout.positions.get(1) ?? Geom.point(0, 0)
				match direction {
					Down | Up => a.x < b.x
					Right | Left => a.y < b.y
				}
			}
		},
	)
}

## Ranking settings on a non-ranking edge are contradictory and identify both
## the sparse-list item and the edge.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 2), edges: [{ from: 0, to: 1 }] },
		non_ranking_edges: [0],
		edge_weights: [{ edge: 0, weight: 2 }],
		min_spans: [{ edge: 0, span: 2 }],
	}
	match Layered.prepare(input, Layered.default_settings) {
		Ok(_) => False
		Err(problems) => problems == [NonRankingEdgeWeight(0, 0), NonRankingMinimumSpan(0, 0)]
	}
}

## Public problem text distinguishes a sparse-list position from the node or
## edge value it references and delegates nested routing details.
expect Layered.problem_to_str(MissingLayerConstraintNode(3, 12)) == "Layer constraint 3 refers to node 12, which does not exist."
expect Layered.problem_to_str(NonRankingMinimumSpan(2, 7)) == "Minimum-span setting 2 refers to non-ranking edge 7, so it cannot affect layer assignment."
expect Layered.problem_to_str(InvalidRouting(InvalidEdgeGap)) == "Routing settings are invalid: The edge gap must be a finite number that is zero or greater."

## Relationship names and endpoint roles may coexist on one edge. Only the
## center label reserves a layer; anchors stay label-input aligned.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 2), edges: [{ from: 0, to: 1 }] },
		edge_labels: [{ edge: 0, width: 50, height: 12, placement: Center }, { edge: 0, width: 10, height: 6, placement: Near(To) }],
	}
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
		Ok(result) => result.layers == [0, 2] and result.label_anchors.len() == 2
		Err(_) => False
	}
}

## Port declaration order is a hard priority for both ordering paths. Even
## when the initial node order is reversed, the two targets follow their attachment
## order and no residual violation is reported.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: List.repeat({ width: 10, height: 6 }, 3), edges: [{ from: 0, to: 2 }, { from: 0, to: 1 }] },
		attachments: [{ edge: 0, endpoint: From, attachment: Fixed({ side: Bottom, offset: 0.25 }) }, { edge: 1, endpoint: From, attachment: Fixed({ side: Bottom, offset: 0.75 }) }],
	}
	sweep = Layered.layout(input, Layered.default_settings, { hints: [{ node: 0, x: 0, y: 0 }, { node: 1, x: 0, y: 20 }, { node: 2, x: 0, y: 0 }], stability: Reflow })
	exact = Layered.layout_exact(input, Layered.default_exact_settings)
	match (sweep, exact) {
		(Ok(a), Ok(b)) => a.attachments.len() == 2 and b.attachments.len() == 2 and (a.layout.positions.get(2) ?? Geom.point(0, 0)).x <= (a.layout.positions.get(1) ?? Geom.point(0, 0)).x
		_ => False
	}
}

## A label reserves a middle virtual layer and its box contributes to bounds.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: [{ width: 10, height: 6 }, { width: 10, height: 6 }], edges: [{ from: 0, to: 1 }] },
		edge_labels: [{ edge: 0, width: 120, height: 30, placement: Center }],
	}
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
		Ok(result) => result.layers == [0, 2] and result.label_anchors.len() == 1 and result.layout.bounds.width >= 120
		Err(_) => False
	}
}

## Direction normalization keeps complete node rectangles inside bounds,
## including non-square nodes whose width and height swap after rotation.
expect {
	input = {
		..Layered.default_input,
		graph: { nodes: [{ width: 90, height: 40 }, { width: 30, height: 70 }], edges: [{ from: 0, to: 1 }] },
	}
	[Down, Up, Left, Right].all(
		|direction| match Layered.layout(input, { ..Layered.default_settings, direction }, Layered.default_run) {
			Err(_) => False
			Ok(result) => result.layout.positions.fold_with_index(
				True,
				|inside, p, i| {
					node = input.graph.nodes.get(i) ?? { width: 0, height: 0 }
					size = node
					inside and p.x - size.width / 2 >= 0 and p.y - size.height / 2 >= 0 and p.x + size.width / 2 <= result.layout.bounds.width and p.y + size.height / 2 <= result.layout.bounds.height
				},
			)
		},
	)
}

## Horizontal directions reserve displayed widths between layers and displayed
## heights within a layer. Unequal rectangles therefore keep the requested
## gaps after canonical coordinates are rotated in either direction.
expect {
	input = {
		..Layered.default_input,
		graph: {
			nodes: [{ width: 140, height: 24 }, { width: 70, height: 80 }, { width: 110, height: 36 }],
			edges: [{ from: 0, to: 2 }, { from: 1, to: 2 }],
		},
	}
	settings = { ..Layered.default_settings, node_gap: 30, layer_gap: 60 }
	[Right, Left].all(
		|direction| match Layered.layout(input, { ..settings, direction }, Layered.default_run) {
			Err(_) => False
			Ok(result) => {
				a = result.layout.positions.get(0) ?? Geom.point(0, 0)
				b = result.layout.positions.get(1) ?? Geom.point(0, 0)
				c = result.layout.positions.get(2) ?? Geom.point(0, 0)
				within_gap = (a.y - b.y).abs() >= (24 + 80) / 2 + settings.node_gap
				layer_gap = match direction {
					Right => c.x - 110 / 2 - (a.x + 140 / 2) >= settings.layer_gap and c.x - 110 / 2 - (b.x + 70 / 2) >= settings.layer_gap
					Left => a.x - 140 / 2 - (c.x + 110 / 2) >= settings.layer_gap and b.x - 70 / 2 - (c.x + 110 / 2) >= settings.layer_gap
					_ => False
				}
				within_gap and layer_gap
			}
		},
	)
}

## Exact ordering beats the sweep: on this two-layer graph the median sweeps
## and transpose polish stall at one crossing, but a crossing-free ordering
## exists and the exact search finds it and proves it optimal.
expect {
	edges = [{ from: 0, to: 3 }, { from: 0, to: 5 }, { from: 1, to: 4 }, { from: 2, to: 5 }]
	layers = LayeredInternals.group_by_rank(LayeredInternals.rank_nodes(6, edges))
	swept = LayeredInternals.order_layers(layers, edges, 4)
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
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
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
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
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
	swept = LayeredInternals.order_layers(layers, edges, 4)
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
	match Layered.layout(input, Layered.default_settings, Layered.default_run) {
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
	match Layered.prepare_exact(input, settings) {
		Ok(_) => False
		Err(problems) => problems == [
			InvalidNodeWidth(0),
			InvalidNodeHeight(0),
			MissingEdgeEnd(0, 3),
			InvalidNodeGap,
		]
	}
}

## Exact pins retain their caller-space coordinates while preserving strict
## layer alignment and routing through the pinned placement.
expect {
	input = { ..Layered.default_input, graph: { nodes: [{ width: 20, height: 12 }, { width: 20, height: 12 }], edges: [{ from: 0, to: 1 }] } }
	settings = { ..Layered.default_settings, pins: [{ node: 0, x: 100, y: 100 }, { node: 1, x: 100, y: 200 }] }
	match Layered.layout(input, settings, Layered.default_run) {
		Ok(result) => result.layout.positions == [Geom.point(100, 100), Geom.point(100, 200)]
		Err(_) => False
	}
}

## Sparse soft hints influence both placement axes while separation remains
## enforced. Nodes without a hint retain the deterministic base target.
expect {
	input = { ..Layered.default_input, graph: { nodes: [{ width: 20, height: 10 }, { width: 20, height: 10 }], edges: [] }, layer_constraints: [SameLayer({ first: 0, second: 1 })] }
	args = { hints: [{ node: 0, x: 100, y: 50 }, { node: 1, x: 300, y: 50 }], stability: PreserveOrder }
	match Layered.layout(input, Layered.default_settings, args) {
		Ok(result) => result.layout.positions == [Geom.point(100, 50), Geom.point(300, 50)]
		Err(_) => False
	}
}

## Moving a horizontal layout's real nodes across the flow must not drag a
## long edge's virtual guide into an unrelated node. Routing succeeds rather
## than returning new positions with provisional routes from the old geometry.
expect {
	nodes = [{ width: 160, height: 56 }, { width: 160, height: 56 }, { width: 160, height: 56 }]
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }]
	input = { ..Layered.default_input, graph: { nodes, edges } }
	args = { hints: [{ node: 0, x: 580, y: 28 }, { node: 1, x: 350, y: 154 }, { node: 2, x: 120, y: 280 }], stability: PreserveOrder }
	match Layered.layout(input, { ..Layered.default_settings, direction: Left }, args) {
		Ok(result) => result.attachments.len() == edges.len() and result.layout.routes.len() == edges.len()
		Err(_) => False
	}
}

## A preserved long-edge guide outside the new endpoint span must not force a
## collinear reversal after exact pins move the endpoints across the layer.
expect {
	nodes = [{ width: 160, height: 56 }, { width: 160, height: 56 }, { width: 160, height: 56 }]
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 0, to: 2 }]
	input = { ..Layered.default_input, graph: { nodes, edges } }
	settings = { ..Layered.default_settings, pins: [{ node: 0, x: 543, y: 108 }, { node: 2, x: 421, y: 372 }] }
	args = { hints: [{ node: 0, x: 543, y: 108 }, { node: 1, x: 80, y: 214 }, { node: 2, x: 421, y: 372 }], stability: PreserveOrder }
	match Layered.layout(input, settings, args) {
		Ok(result) => match result.layout.routes.get(2) ?? Polyline([]) {
			Polyline(points) => !points.fold_with_index(
				False,
				|reverses, a, i| match (points.get(i + 1), points.get(i + 2)) {
					(Ok(b), Ok(c)) => reverses or (a.y == b.y and b.y == c.y and (b.x - a.x) * (c.x - b.x) < 0) or (a.x == b.x and b.x == c.x and (b.y - a.y) * (c.y - b.y) < 0)
					_ => reverses
				},
			)
			_ => False
		}
		Err(_) => False
	}
}

## Pins on one strict layer must agree on its flow coordinate.
expect {
	input = { ..Layered.default_input, graph: { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [] }, layer_constraints: [SameLayer({ first: 0, second: 1 })] }
	settings = { ..Layered.default_settings, pins: [{ node: 0, x: 0, y: 10 }, { node: 1, x: 40, y: 20 }] }
	match Layered.prepare(input, settings) {
		Ok(_) => False
		Err(problems) => problems == [ConflictingPins]
	}
}

## Pin validation reports independent reference, numeric, and duplicate
## problems together at preparation.
expect {
	settings = { ..Layered.default_settings, pins: [{ node: 4, x: 0, y: 0 }, { node: 0, x: F64.nan, y: 0 }, { node: 0, x: 20, y: 0 }] }
	match Layered.prepare({ ..Layered.default_input, graph: { nodes: [{ width: 1, height: 1 }], edges: [] } }, settings) {
		Err([MissingPinNode(0, 4), InvalidPin(1), DuplicatePin(2)]) => True
		Err(_) => False
		Ok(_) => False
	}
}

## Layer points: one per layer strictly between an edge's ends, in order from
## source to target, also for an edge drawn against the flow. Straight
## routes pass through exactly those points and report no attachments.
expect {
	nodes = List.repeat({ width: 20, height: 10 }, 4)
	# 0 -> 1 -> 2 -> 3 and a long edge 0 -> 3, plus 3 -> 0 closing a cycle.
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 0, to: 3 }, { from: 3, to: 0 }]
	input = { ..Layered.default_input, graph: { nodes, edges } }
	settings = { ..Layered.default_settings, routing: Straight }
	match Layered.layout(input, settings, Layered.default_run) {
		Ok(result) => {
			long = result.layer_points.get(3) ?? []
			back = result.layer_points.get(4) ?? []
			through = result.layout.routes.map_with_index(
				|route, i| match route {
					Polyline(points) => points.drop_first(1).drop_last(1) == (result.layer_points.get(i) ?? [])
					Line(_, _) => (result.layer_points.get(i) ?? []).is_empty()
					Curves(_) => False
				},
			)
			descending = |points| points.fold_with_index(True, |ok, p, i| ok and (i == 0 or p.y > ((points.get(i - 1) ?? p).y)))
			ascending_back = back.fold_with_index(True, |ok, p, i| ok and (i == 0 or p.y < ((back.get(i - 1) ?? p).y)))
			long.len() == 2
				and back.len() == 2
				and descending(long)
				and ascending_back
				and result.backward_edges == [4]
				and through.all(|ok| ok)
				and result.attachments == []
				and result.layer_points.len() == edges.len()
		}
		Err(_) => False
	}
}

## Straight routing equals preparing then laying out, and the layer points
## are the same as with orthogonal routing: routing never moves them.
expect {
	nodes = [{ width: 30, height: 10 }, { width: 10, height: 20 }, { width: 16, height: 16 }, { width: 8, height: 8 }]
	edges = [{ from: 0, to: 1 }, { from: 0, to: 2 }, { from: 1, to: 3 }, { from: 0, to: 3 }, { from: 2, to: 2 }]
	input = { ..Layered.default_input, graph: { nodes, edges }, edge_labels: [{ edge: 3, width: 12, height: 6, placement: Center }, { edge: 0, width: 4, height: 4, placement: Near(From) }] }
	straight = { ..Layered.default_settings, routing: Straight, direction: Right }
	orthogonal = { ..Layered.default_settings, direction: Right }
	one_call = Layered.layout(input, straight, Layered.default_run)
	staged = match Layered.prepare(input, straight) {
		Ok(prepared) => Ok(Layered.layout_prepared(prepared, Layered.default_run))
		Err(problems) => Err(problems)
	}
	match (one_call, Layered.layout(input, orthogonal, Layered.default_run)) {
		(Ok(a), Ok(b)) => {
			points = a.layer_points.get(3) ?? []
			span = (a.layers.get(3) ?? 0) - (a.layers.get(0) ?? 0)
			# The chain has span + 1 nodes; its middle one is interior point
			# (span + 1) // 2 - 1.
			label_point = points.get((span + 1) // 2 - 1) ?? { x: -1, y: -1 }
			one_call == staged
				and a.layer_points == b.layer_points
				and a.layout.positions == b.layout.positions
				and span >= 2
				and points.len() == span - 1
				and a.label_anchors.get(0) == Ok(label_point)
		}
		_ => False
	}
}

## Routing settings are only checked when edges are routed orthogonally.
expect {
	bad = { ..Route.default_settings, obstacle_gap: -1 }
	input = { ..Layered.default_input, graph: { nodes: [{ width: 1, height: 1 }], edges: [] } }
	orthogonal = match Layered.prepare(input, { ..Layered.default_settings, routing: Orthogonal(bad) }) {
		Err([InvalidRouting(_)]) => True
		_ => False
	}
	straight = match Layered.prepare(input, { ..Layered.default_settings, routing: Straight }) {
		Ok(_) => True
		Err(_) => False
	}
	orthogonal and straight
}

## Average ordering keeps the input order where averages tie and is
## deterministic; both orderings produce complete, index-aligned layouts.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 6)
	edges = [{ from: 0, to: 3 }, { from: 0, to: 4 }, { from: 1, to: 5 }, { from: 2, to: 3 }, { from: 2, to: 5 }]
	input = { ..Layered.default_input, graph: { nodes, edges } }
	average = { ..Layered.default_settings, ordering: Average, routing: Straight }
	median = { ..Layered.default_settings, routing: Straight }
	match (Layered.layout(input, average, Layered.default_run), Layered.layout(input, median, Layered.default_run)) {
		(Ok(a), Ok(m)) => Layered.layout(input, average, Layered.default_run) == Ok(a) and a.layout.positions.len() == 6 and m.layout.positions.len() == 6 and a.layers == m.layers
		_ => False
	}
}

## An empty graph lays out with either routing.
expect {
	straight = Layered.layout(Layered.default_input, { ..Layered.default_settings, routing: Straight }, Layered.default_run)
	match straight {
		Ok(result) => result.layout.positions == [] and result.layer_points == [] and result.layout.bounds == Geom.empty_bounds
		Err(_) => False
	}
}
