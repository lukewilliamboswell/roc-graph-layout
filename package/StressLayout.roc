import Geom
import Paths
import Pack
import Rand
import EdgeRoutes
import Overlap

## Pure helpers behind `Graph.Stress`: joint validation, the scaled
## graph-theoretic distance tables the witness carries, and stress
## majorization with a simultaneous (order-independent) update rule, so
## determinism is structural rather than disciplined.
StressInternals :: {}.{

	## The distance structure a built witness carries, so repeated runs
	## never recompute BFS work.
	##
	## `AllPairs` is a flat row-major `n * n` table of scaled distances:
	## entry `i * n + j` is the hop count from `i` to `j` times the unit
	## length, `0` on the diagonal, and `F64.infinity` between components.
	## Exact mode is meant for at most a few thousand nodes, where the
	## table is affordable and every pair constrains the drawing.
	##
	## `PivotRows` is the k-pivot approximation: the pivot node indices in
	## selection order, one scaled BFS distance row per pivot, each node's
	## closest pivot by scaled distance with ties toward the earlier pivot
	## (`pivot_nodes.len()` as a sentinel when no pivot is reachable), and
	## each pivot's region size — how many nodes it is closest to. The
	## region size adapts the weights so each pivot stands in for the
	## nodes it covers.
	Distances : [
		AllPairs(List(F64)),
		PivotRows(
			{
				pivot_nodes : List(U64),
				rows : List(List(F64)),
				region_of : List(U64),
				region_sizes : List(U64),
			},
		),
	]

	## Per-node pin slot: a pinned node keeps its pin through every phase.
	PinSlot : [Pin({ x : F64, y : F64 }), Free]

	validation_problems : StressPrepared.Spec, StressPrepared.Settings -> List(StressPrepared.Problem)
	validation_problems = |spec, settings| {
		node_problems = spec.nodes.fold_with_index(
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

		edge_problems = spec.edges.fold_with_index(
			node_problems,
			|problems, edge, index| {
				from_problems = if edge.from >= spec.nodes.len() {
					problems.append(MissingEdgeStart(index, edge.from))
				} else {
					problems
				}

				if edge.to >= spec.nodes.len() {
					from_problems.append(MissingEdgeEnd(index, edge.to))
				} else {
					from_problems
				}
			},
		)

		gap_problems = if !F64.is_finite(settings.node_gap) or settings.node_gap < 0 {
			edge_problems.append(InvalidNodeGap)
		} else {
			edge_problems
		}

		mode_problems = match settings.mode {
			Exact => gap_problems
			Pivots(k) =>
				if k == 0 {
					gap_problems.append(InvalidPivotCount)
				} else {
					gap_problems
				}
			}

		tolerance_problems = if F64.is_finite(settings.tolerance) and settings.tolerance > 0 {
			mode_problems
		} else {
			mode_problems.append(InvalidTolerance)
		}

		# Both pin problems carry the pin's index in the pins list, and one
		# pin can raise both independently.
		settings.pins.fold_with_index(
			tolerance_problems,
			|problems, pin, index| {
				reference_problems = if pin.node >= spec.nodes.len() {
					problems.append(MissingPin(index))
				} else {
					problems
				}

				if F64.is_finite(pin.x) and F64.is_finite(pin.y) {
					reference_problems
				} else {
					reference_problems.append(InvalidPin(index))
				}
			},
		)
	}

	## The per-hop unit distance: the mean over edges of the endpoint
	## diagonals' average, plus the gap — or the gap alone for an edgeless
	## graph, which has no pairs at graph distance anyway. The mean is
	## computed incrementally so the accumulator stays within the range of
	## the finite inputs however many edges there are, and the final sum
	## saturates at the largest finite value rather than overflowing —
	## finite accepted input must produce finite derived geometry.
	unit_length_of : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), F64 -> F64
	unit_length_of = |nodes, edges, node_gap| {
		if edges.is_empty() {
			node_gap
		} else {
			mean = edges.fold_with_index(
				0.0,
				|acc, edge, index| {
					a = EdgeRoutes.diagonal(nodes.get(edge.from) ?? { width: 0, height: 0 })
					b = EdgeRoutes.diagonal(nodes.get(edge.to) ?? { width: 0, height: 0 })
					acc + (a / 2 + b / 2 - acc) / (index + 1).to_f64()
				},
			)
			unit = mean + node_gap
			if F64.is_finite(unit) {
				unit
			} else {
				F64.highest
			}
		}
	}

	## Hop counts scaled to drawing units. Infinite hops stay exactly
	## infinite — never multiplied, so a zero unit length cannot produce NaN.
	scale_row : List(F64), F64 -> List(F64)
	scale_row = |hops, unit|
		hops.map(
			|h|
				if F64.is_finite(h) {
					h * unit
				} else {
					F64.infinity
				},
		)

	## The flat row-major all-pairs table for `AllPairs`, in O(n * (n + m)).
	all_pairs_distances : Paths.Adjacency, F64 -> List(F64)
	all_pairs_distances = |adj, unit| {
		n = Paths.node_count_of(adj)
		Paths.indices_up_to(n).fold(
			[],
			|acc, source| acc.concat(StressInternals.scale_row(Paths.bfs_distances(adj, source), unit)),
		)
	}

	## Each node's closest pivot (as an index into `rows`), ties toward the
	## earlier pivot; `rows.len()` when no pivot is reachable from the node.
	closest_pivots : List(List(F64)), U64 -> List(U64)
	closest_pivots = |rows, node_count|
		Paths.indices_up_to(node_count).map(
			|i|
				rows.fold_with_index(
					{ best: rows.len(), dist: F64.infinity },
					|acc, row, pi| {
						d = row.get(i) ?? F64.infinity
						if d < acc.dist {
							{ best: pi, dist: d }
						} else {
							acc
						}
					},
				).best,
		)

	## How many nodes each pivot is closest to. Every pivot covers at least
	## itself (its own distance is zero), so no region is empty.
	region_sizes_of : List(U64), U64 -> List(U64)
	region_sizes_of = |region_of, pivot_count|
		region_of.fold(
			List.repeat(0, pivot_count),
			|acc, r|
				if r < pivot_count {
					acc.set(r, (acc.get(r) ?? 0) + 1) ?? acc
				} else {
					acc
				},
		)

	## How many nodes each component contains, from the component labels.
	component_sizes_of : List(U64), U64 -> List(U64)
	component_sizes_of = |labels, count|
		labels.fold(
			List.repeat(0, count),
			|acc, c| acc.set(c, (acc.get(c) ?? 0) + 1) ?? acc,
		)

	## Deterministic direction for coincident points: a unit vector chosen
	## from a fixed table of the eight 45-degree directions by
	## `(i + j) mod 8`, so two nodes that land on the same point separate
	## along a direction derived from their indices — never a division by
	## the zero distance between them.
	fallback_dir : U64, U64 -> { x : F64, y : F64 }
	fallback_dir = |i, j| {
		s = 0.7071067811865476
		k = (i + j) % 8
		if k == 0 {
			{ x: 1.0, y: 0.0 }
		} else if k == 1 {
			{ x: s, y: s }
		} else if k == 2 {
			{ x: 0.0, y: 1.0 }
		} else if k == 3 {
			{ x: 0.0 - s, y: s }
		} else if k == 4 {
			{ x: 0.0 - 1.0, y: 0.0 }
		} else if k == 5 {
			{ x: 0.0 - s, y: 0.0 - s }
		} else if k == 6 {
			{ x: 0.0, y: 0.0 - 1.0 }
		} else {
			{ x: s, y: 0.0 - s }
		}
	}

	## Where the pair `(i, j)` wants node `i` to sit: `ideal` away from
	## `other` along the current direction from `other` to `at`, with the
	## coincident fallback when that direction is undefined.
	pulled_target : { x : F64, y : F64 }, { x : F64, y : F64 }, F64, U64, U64 -> { x : F64, y : F64 }
	pulled_target = |at, other, ideal, i, j| {
		dx = at.x - other.x
		dy = at.y - other.y
		dist = Geom.hypot(dx, dy)
		dir = if dist > 0 {
			{ x: dx / dist, y: dy / dist }
		} else {
			StressInternals.fallback_dir(i, j)
		}
		{ x: other.x + ideal * dir.x, y: other.y + ideal * dir.y }
	}

	## One majorization step with the simultaneous update: every new
	## position is a weighted average of pulled targets computed from the
	## old positions only, then all are applied at once, so the result is
	## independent of node order. Pairs without a finite positive distance
	## are skipped; a node with no participating pair (or a non-finite
	## candidate from extreme magnitudes) keeps its old position; pinned
	## nodes keep their pin.
	##
	## Exact weights are `1 / d^2`. Pivot weights are `|region| / d^2` —
	## each pivot stands in for every node it is closest to, so its pull
	## is scaled by the size of that region — and a node that is itself a
	## pivot skips its own zero-distance term.
	update_step : List({ x : F64, y : F64 }), StressInternals.Distances, List(StressInternals.PinSlot) -> List({ x : F64, y : F64 })
	update_step = |positions, distances, pin_at| {
		n = positions.len()
		all = Paths.indices_up_to(n)
		positions.map_with_index(
			|at, i|
				match pin_at.get(i) ?? Free {
					Pin(pin) => pin
					Free => {
						sums = match distances {
							AllPairs(flat) =>
								all.fold(
									{ x: 0.0, y: 0.0, weight: 0.0 },
									|acc, j| {
										d = flat.get(i * n + j) ?? F64.infinity
										if j == i or !F64.is_finite(d) or d <= 0 {
											acc
										} else {
											w = 1.0 / (d * d)
											other = positions.get(j) ?? at
											t = StressInternals.pulled_target(at, other, d, i, j)
											{ x: acc.x + w * t.x, y: acc.y + w * t.y, weight: acc.weight + w }
										}
									},
								)

							PivotRows(data) =>
								data.pivot_nodes.fold_with_index(
									{ x: 0.0, y: 0.0, weight: 0.0 },
									|acc, p_node, pi| {
										d = (data.rows.get(pi) ?? []).get(i) ?? F64.infinity
										if p_node == i or !F64.is_finite(d) or d <= 0 {
											acc
										} else {
											w = (data.region_sizes.get(pi) ?? 1).to_f64() / (d * d)
											other = positions.get(p_node) ?? at
											t = StressInternals.pulled_target(at, other, d, i, p_node)
											{ x: acc.x + w * t.x, y: acc.y + w * t.y, weight: acc.weight + w }
										}
									},
								)
							}

						if sums.weight > 0 and F64.is_finite(sums.x / sums.weight) and F64.is_finite(sums.y / sums.weight) {
							{ x: sums.x / sums.weight, y: sums.y / sums.weight }
						} else {
							at
						}
					}
				},
		)
	}

	## The stress of a layout over exactly the pairs the update sums:
	## unordered pairs with finite positive distance in exact mode, and
	## (node, pivot) pairs with the region-adapted weights in pivot mode.
	stress_of : List({ x : F64, y : F64 }), StressInternals.Distances -> F64
	stress_of = |positions, distances| {
		n = positions.len()
		all = Paths.indices_up_to(n)
		match distances {
			AllPairs(flat) =>
				positions.fold_with_index(
					0.0,
					|acc, at, i|
						all.fold(
							acc,
							|inner, j|
								if j <= i {
									inner
								} else {
									d = flat.get(i * n + j) ?? F64.infinity
									if !F64.is_finite(d) or d <= 0 {
										inner
									} else {
										other = positions.get(j) ?? at
										err = Geom.hypot(at.x - other.x, at.y - other.y) - d
										inner + err * err / (d * d)
									}
								},
						),
				)

			PivotRows(data) =>
				positions.fold_with_index(
					0.0,
					|acc, at, i|
						data.pivot_nodes.fold_with_index(
							acc,
							|inner, p_node, pi| {
								d = (data.rows.get(pi) ?? []).get(i) ?? F64.infinity
								if p_node == i or !F64.is_finite(d) or d <= 0 {
									inner
								} else {
									other = positions.get(p_node) ?? at
									err = Geom.hypot(at.x - other.x, at.y - other.y) - d
									inner + (data.region_sizes.get(pi) ?? 1).to_f64() * err * err / (d * d)
								}
							},
						),
				)
			}
	}

	## How many pair terms the stress sums, with pivot terms counted at
	## their region multiplicity — the scale that turns the stress into a
	## mean squared relative pair error. Never below one, so the floor test
	## in `descend` stays meaningful on degenerate inputs.
	stress_terms_of : StressInternals.Distances, U64 -> F64
	stress_terms_of = |distances, node_count| {
		all = Paths.indices_up_to(node_count)

		zero : F64
		zero = 0.0

		total = match distances {
			AllPairs(flat) =>
				all.fold(
					zero,
					|acc, i|
						all.fold(
							acc,
							|inner, j| {
								d = flat.get(i * node_count + j) ?? F64.infinity
								if j <= i or !F64.is_finite(d) or d <= 0 {
									inner
								} else {
									inner + 1
								}
							},
						),
				)

			PivotRows(data) =>
				all.fold(
					zero,
					|acc, i|
						data.pivot_nodes.fold_with_index(
							acc,
							|inner, p_node, pi| {
								d = (data.rows.get(pi) ?? []).get(i) ?? F64.infinity
								if p_node == i or !F64.is_finite(d) or d <= 0 {
									inner
								} else {
									inner + (data.region_sizes.get(pi) ?? 1).to_f64()
								}
							},
						),
				)
			}
		total.max(1)
	}

	## Bounded majorization descent: apply updates until convergence or
	## until the fuel — the iteration cap — runs out (not converged).
	## Convergence is either stop condition: the relative stress change of
	## a step falls below tolerance (the descent has flattened), or the
	## stress drops below `floor` — tolerance times the summed term count,
	## i.e. a mean squared relative pair error below tolerance — which
	## catches exactly-embeddable graphs whose stress decays toward zero
	## with a near-constant relative change that would otherwise stall the
	## first test. `done` counts the updates actually applied.
	descend : List({ x : F64, y : F64 }), StressInternals.Distances, List(StressInternals.PinSlot), F64, F64, F64, U64, U64 -> { positions : List({ x : F64, y : F64 }), iterations : U64, converged : Bool }
	descend = |positions, distances, pin_at, tolerance, floor, prev_stress, done, fuel|
		if fuel == 0 {
			{ positions, iterations: done, converged: False }
		} else {
			next = StressInternals.update_step(positions, distances, pin_at)
			stress = StressInternals.stress_of(next, distances)
			relative = (prev_stress - stress).abs() / prev_stress.max(1e-12)
			if stress < floor or relative < tolerance {
				{ positions: next, iterations: done + 1, converged: True }
			} else {
				StressInternals.descend(next, distances, pin_at, tolerance, floor, stress, done + 1, fuel - 1)
			}
		}

	## Seeded initial scatter: two unit doubles per node in index order,
	## scaled by the unit length times the square root of the node's
	## component size, so each component starts spread near its final scale.
	scatter : U64, U32, List(U64), List(U64), F64 -> List({ x : F64, y : F64 })
	scatter = |node_count, seed, component_of, component_sizes, unit| {
		Paths.indices_up_to(node_count).fold(
			{ state: Rand.seed(seed), points: [] },
			|acc, i| {
				sx = Rand.step_unit_f64(acc.state)
				sy = Rand.step_unit_f64(sx.state)
				size = component_sizes.get(component_of.get(i) ?? 0) ?? 1
				raw_scale = unit * size.to_f64().sqrt()
				# derived scale saturates rather than overflowing to infinity
				scale = if F64.is_finite(raw_scale) {
					raw_scale
				} else {
					F64.highest
				}
				{
					state: sy.state,
					points: acc.points.append({ x: sx.value * scale, y: sy.value * scale }),
				}
			},
		).points
	}

	## Pack the solved components: each pin-free component's tight box goes
	## through the shared shelf packer and the component is translated
	## rigidly onto its packed center. Components holding a pin are exempt
	## — their pins anchor them in absolute coordinates — and the packed
	## group of free components sits to the right of the pinned drawing's
	## extent, level with its top.
	pack_components : List({ x : F64, y : F64 }), List({ width : F64, height : F64 }), List(U64), U64, List(StressInternals.PinSlot), F64 -> List({ x : F64, y : F64 })
	pack_components = |positions, nodes, component_of, component_count, pin_at, node_gap| {
		if component_count < 1 {
			positions
		} else {
			empty_box = { min_x: F64.infinity, min_y: F64.infinity, max_x: 0.0 - F64.infinity, max_y: 0.0 - F64.infinity }
			boxes = positions.fold_with_index(
				List.repeat(empty_box, component_count),
				|acc, p, i| {
					size = nodes.get(i) ?? { width: 0, height: 0 }
					c = component_of.get(i) ?? 0
					box = acc.get(c) ?? empty_box
					acc.set(
						c,
						{
							min_x: box.min_x.min(p.x - size.width / 2),
							min_y: box.min_y.min(p.y - size.height / 2),
							max_x: box.max_x.max(p.x + size.width / 2),
							max_y: box.max_y.max(p.y + size.height / 2),
						},
					)
						?? acc
				},
			)

			anchored = pin_at.fold_with_index(
				List.repeat(False, component_count),
				|acc, slot, i|
					match slot {
						Pin(_) => acc.set(component_of.get(i) ?? 0, True) ?? acc
						Free => acc
					},
			)

			free_components = Paths.indices_up_to(component_count).fold(
				[],
				|acc, c|
					if anchored.get(c) ?? False {
						acc
					} else {
						acc.append(c)
					},
			)
			free_boxes = free_components.map(
				|c| {
					box = boxes.get(c) ?? empty_box
					{ width: (box.max_x - box.min_x).max(0), height: (box.max_y - box.min_y).max(0) }
				},
			)
			packed = Pack.pack(free_boxes, { gap: node_gap * 2, target_aspect: 1.0 })

			anchor = if free_components.len() == component_count {
				{ x: 0.0, y: 0.0 }
			} else {
				pinned = Paths.indices_up_to(component_count).fold(
					{ max_x: 0.0, min_y: 0.0, found: False },
					|acc, c|
						if anchored.get(c) ?? False {
							box = boxes.get(c) ?? empty_box
							if acc.found {
								{ max_x: acc.max_x.max(box.max_x), min_y: acc.min_y.min(box.min_y), found: True }
							} else {
								{ max_x: box.max_x, min_y: box.min_y, found: True }
							}
						} else {
							acc
						},
				)
				{ x: pinned.max_x + node_gap * 2, y: pinned.min_y }
			}

			deltas = free_components.fold_with_index(
				List.repeat({ x: 0.0, y: 0.0 }, component_count),
				|acc, c, k| {
					box = boxes.get(c) ?? empty_box
					center = packed.positions.get(k) ?? { x: 0, y: 0 }
					acc.set(
						c,
						{
							x: anchor.x + center.x - (box.min_x + box.max_x) / 2,
							y: anchor.y + center.y - (box.min_y + box.max_y) / 2,
						},
					)
						?? acc
				},
			)

			positions.map_with_index(
				|p, i| {
					delta = deltas.get(component_of.get(i) ?? 0) ?? { x: 0, y: 0 }
					{ x: p.x + delta.x, y: p.y + delta.y }
				},
			)
		}
	}

	## Per-node outward direction for self-loop routing: from the node's
	## component centroid toward the node. The zero vector (a node at its
	## own centroid) is legal — routing falls back to pointing up.
	outward_directions : List({ x : F64, y : F64 }), List(U64), U64 -> List({ x : F64, y : F64 })
	outward_directions = |positions, component_of, component_count| {
		sums = positions.fold_with_index(
			List.repeat({ x: 0.0, y: 0.0, count: 0.0 }, component_count),
			|acc, p, i| {
				c = component_of.get(i) ?? 0
				s = acc.get(c) ?? { x: 0, y: 0, count: 0 }
				acc.set(c, { x: s.x + p.x, y: s.y + p.y, count: s.count + 1 }) ?? acc
			},
		)
		positions.map_with_index(
			|p, i| {
				s = sums.get(component_of.get(i) ?? 0) ?? { x: 0, y: 0, count: 0 }
				if s.count > 0 {
					{ x: p.x - s.x / s.count, y: p.y - s.y / s.count }
				} else {
					{ x: 0.0, y: 0.0 }
				}
			},
		)
	}
}

## A validated stress layout: distances mean something, so the drawn
## distance between nodes is optimized to track their graph-theoretic
## distance (stress majorization with a simultaneous update).
##
## `build` validates jointly, reporting every independent problem, and
## precomputes what repeated runs reuse: adjacency-derived component labels
## and the scaled distance structure (all-pairs in exact mode, pivot rows
## with region-adapted weights in pivot mode). `place` and `run` then only
## descend: initialization comes from full-length finite position hints
## (index-aligned; a partial or non-finite hint list is treated as absent)
## or a seeded scatter, with pins overriding either.
##
## Pins hold exactly: pinned nodes never move, components containing a pin
## are exempt from component packing, and a drawing with pins keeps its
## absolute coordinates instead of being translated to the origin (its
## bounds record where it actually sits).
StressPrepared := {
	nodes : List({ width : F64, height : F64 }),
	edges : List({ from : U64, to : U64 }),
	component_of : List(U64),
	component_count : U64,
	component_sizes : List(U64),
	unit_length : F64,
	distances : StressInternals.Distances,
	stress_terms : F64,
	pin_at : List(StressInternals.PinSlot),
	node_gap : F64,
	max_iterations : U64,
	tolerance : F64,
}.{
	Spec : {
		nodes : List({ width : F64, height : F64 }),
		edges : List({ from : U64, to : U64 }),
	}

	## `node_gap` sets the per-hop unit distance: the mean over edges of the
	## endpoint diagonals' average plus the gap (the gap alone if edgeless).
	## `mode` picks the distance table: `Exact` all-pairs (a few thousand
	## nodes at most), or `Pivots(k)` with k farthest-point-sampled pivots;
	## `Pivots(0)` is a problem. Iteration stops when the relative stress
	## change of a step drops below `tolerance`, when the stress itself
	## becomes negligible (a mean squared relative pair error below
	## `tolerance`), or at `max_iterations`. Pinned nodes keep exactly the
	## given position; a node pinned twice keeps the last pin in the list.
	Settings : {
		node_gap : F64,
		mode : [Exact, Pivots(U64)],
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	}

	## Invalid sizes, edge endpoints, spacing, pivot count, tolerance, or
	## pins found while checking input. `MissingPin` and `InvalidPin` carry
	## the pin's index in the pins list.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidPivotCount,
		InvalidTolerance,
		MissingPin(U64),
		InvalidPin(U64),
	]

	## Per-run inputs that select a particular solve: the scatter seed, and
	## optional starting positions — index-aligned, one per node — such as
	## a previous result's positions, which makes a re-run cost only its
	## few iterations.
	RunArgs : { seed : U32, hints : List({ x : F64, y : F64 }) }

	defaults : Settings
	defaults = { node_gap: 24, mode: Exact, max_iterations: 200, tolerance: 0.0001, pins: [] }

	default_run : RunArgs
	default_run = { seed: 0, hints: [] }

	## Check input and settings jointly — reporting every independent
	## problem — then precompute the component labels and the scaled
	## distance structure the descent reuses across runs.
	build : Spec, Settings -> [Ok(StressPrepared), Err(List(Problem))]
	build = |spec, settings| {
		problems = StressInternals.validation_problems(spec, settings)
		if !problems.is_empty() {
			Err(problems)
		} else {
			node_count = spec.nodes.len()
			adj = Paths.adjacency(node_count, spec.edges)
			comps = Paths.components(adj)
			unit = StressInternals.unit_length_of(spec.nodes, spec.edges, settings.node_gap)

			distances = match settings.mode {
				Exact => AllPairs(StressInternals.all_pairs_distances(adj, unit))
				Pivots(k) => {
					pivot_nodes = Paths.pivots(adj, k)
					rows = pivot_nodes.map(|p| StressInternals.scale_row(Paths.bfs_distances(adj, p), unit))
					region_of = StressInternals.closest_pivots(rows, node_count)
					region_sizes = StressInternals.region_sizes_of(region_of, pivot_nodes.len())
					PivotRows({ pivot_nodes, rows, region_of, region_sizes })
				}
			}

			pin_at = settings.pins.fold(
				List.repeat(Free, node_count),
				|acc, pin| acc.set(pin.node, Pin({ x: pin.x, y: pin.y })) ?? acc,
			)

			prepared : StressPrepared
			prepared = {
				nodes: spec.nodes,
				edges: spec.edges,
				component_of: comps.labels,
				component_count: comps.count,
				component_sizes: StressInternals.component_sizes_of(comps.labels, comps.count),
				unit_length: unit,
				distances,
				stress_terms: StressInternals.stress_terms_of(distances, node_count),
				pin_at,
				node_gap: settings.node_gap,
				max_iterations: settings.max_iterations,
				tolerance: settings.tolerance,
			}
			Ok(prepared)
		}
	}

	## Positions only: initialize from hints or seeded scatter (pins
	## overriding either), descend, then pack the components. `iterations`
	## counts majorization updates applied; `converged` reports whether the
	## relative stress change fell below tolerance before the cap.
	place : StressPrepared,
	RunArgs -> {
		positions : List({ x : F64, y : F64 }),
		components : List(U64),
		convergence : { iterations : U64, converged : Bool },
	}
	place = |prepared, args| {
		node_count = prepared.nodes.len()
		hints_usable =
			args.hints.len() == node_count
				and args.hints.all(|h| F64.is_finite(h.x) and F64.is_finite(h.y))
		base = if hints_usable {
			args.hints
		} else {
			StressInternals.scatter(node_count, args.seed, prepared.component_of, prepared.component_sizes, prepared.unit_length)
		}
		start = base.map_with_index(
			|p, i|
				match prepared.pin_at.get(i) ?? Free {
					Pin(pin) => pin
					Free => p
				},
		)

		initial_stress = StressInternals.stress_of(start, prepared.distances)
		floor = prepared.tolerance * prepared.stress_terms
		solved = StressInternals.descend(start, prepared.distances, prepared.pin_at, prepared.tolerance, floor, initial_stress, 0, prepared.max_iterations)
		# Full finite hints carry the caller's component arrangement — a
		# previous drawing already placed its components — so packing is
		# skipped and the hinted placement is preserved (with zero
		# iterations, bit-exactly). Packing exists for fresh seeded scatters,
		# where components would otherwise start on top of each other.
		packed = if hints_usable {
			solved.positions
		} else {
			StressInternals.pack_components(solved.positions, prepared.nodes, prepared.component_of, prepared.component_count, prepared.pin_at, prepared.node_gap)
		}

		{
			positions: packed,
			components: prepared.component_of,
			convergence: { iterations: solved.iterations, converged: solved.converged },
		}
	}

	## The full drawing: `place`, then shared edge routing (self-loops point
	## away from each component's centroid) and normalization to the origin
	## — unless pins are present, in which case the drawing keeps its
	## pin-anchored coordinates and the bounds record where it sits.
	run : StressPrepared,
	RunArgs -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		components : List(U64),
		convergence : { iterations : U64, converged : Bool },
	}
	run = |prepared, args| {
		placed = prepared.place(args)
		has_pins = !prepared.pin_at.all(
			|slot|
				match slot {
					Pin(_) => False
					Free => True
				},
		)
		# The shared overlap pass cleans residual box overlaps from the
		# descent with minimal movement before routing. Pinned drawings
		# skip it — the pass cannot yet hold a pin exactly — and keep
		# their raw positions.
		positions = if has_pins {
			placed.positions
		} else {
			Overlap.remove(placed.positions, prepared.nodes, 0)
		}
		outwards = StressInternals.outward_directions(positions, prepared.component_of, prepared.component_count)
		routes = EdgeRoutes.route_edges(prepared.edges, positions, outwards, prepared.nodes, prepared.node_gap)
		normalized = EdgeRoutes.normalize(positions, prepared.nodes, routes)

		layout = if has_pins {
			# Normalizing would move the pins; keep the raw coordinates and
			# recover the tight box's corner from the shift normalize applied.
			first_raw = positions.get(0) ?? { x: 0, y: 0 }
			first_norm = normalized.positions.get(0) ?? { x: 0, y: 0 }
			{
				positions,
				bounds: {
					x: first_raw.x - first_norm.x,
					y: first_raw.y - first_norm.y,
					width: normalized.bounds.width,
					height: normalized.bounds.height,
				},
				routes,
			}
		} else {
			normalized
		}

		{ layout, components: placed.components, convergence: placed.convergence }
	}

	## Check and lay out in one call: exactly `build` followed by `run`.
	layout : Spec,
	Settings,
	RunArgs -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				components : List(U64),
				convergence : { iterations : U64, converged : Bool },
			},
		),
		Err(List(Problem)),
	]
	layout = |spec, settings, args|
		match StressPrepared.build(spec, settings) {
			Ok(prepared) => Ok(prepared.run(args))
			Err(problems) => Err(problems)
		}
}

## Cross-module face: on this compiler nightly, static calls from another
## module must go through a module's namesake nominal (calling a
## non-namesake nominal's statics cross-module crashes at runtime), so the
## public wiring uses these delegations.
StressLayout := [].{
	stress_defaults : StressPrepared.Settings
	stress_defaults = StressPrepared.defaults

	stress_default_run : StressPrepared.RunArgs
	stress_default_run = StressPrepared.default_run

	prepare_stress : StressPrepared.Spec, StressPrepared.Settings -> [Ok(StressPrepared), Err(List(StressPrepared.Problem))]
	prepare_stress = |spec, settings| StressPrepared.build(spec, settings)

	place_stress : StressPrepared,
	StressPrepared.RunArgs -> {
		positions : List({ x : F64, y : F64 }),
		components : List(U64),
		convergence : { iterations : U64, converged : Bool },
	}
	place_stress = |prepared, args| prepared.place(args)

	run_stress : StressPrepared,
	StressPrepared.RunArgs -> {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		components : List(U64),
		convergence : { iterations : U64, converged : Bool },
	}
	run_stress = |prepared, args| prepared.run(args)

	layout_stress : StressPrepared.Spec,
	StressPrepared.Settings,
	StressPrepared.RunArgs -> [
		Ok(
			{
				layout : {
					positions : List({ x : F64, y : F64 }),
					bounds : { x : F64, y : F64, width : F64, height : F64 },
					routes : List(Geom.Route),
				},
				components : List(U64),
				convergence : { iterations : U64, converged : Bool },
			},
		),
		Err(List(StressPrepared.Problem)),
	]
	layout_stress = |spec, settings, args| StressPrepared.layout(spec, settings, args)
}

## The empty graph has a defined stress layout: no positions, no routes,
## zero-size bounds at the origin, no components.
expect {
	match StressPrepared.layout({ nodes: [], edges: [] }, StressPrepared.defaults, StressPrepared.default_run) {
		Err(_) => False
		Ok(result) =>
			result.layout.positions == []
				and result.layout.routes == []
					and result.layout.bounds == { x: 0, y: 0, width: 0, height: 0 }
						and result.components == []
		}
}

## A single node sits centered at half its size.
expect {
	spec = { nodes: [{ width: 8, height: 6 }], edges: [] }
	match StressPrepared.layout(spec, StressPrepared.defaults, StressPrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			p = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			(p.x - 4).abs() < 1e-6 and (p.y - 3).abs() < 1e-6
		}
	}
}

## A path of three equal nodes settles with adjacent pairs about one unit
## apart and the endpoints about two units apart — drawn distances within
## 15% of the graph-theoretic ideal — and converges.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 3)
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }]
	settings = { ..StressPrepared.defaults, tolerance: 1e-7, max_iterations: 2000 }
	match StressPrepared.build({ nodes, edges }, settings) {
		Err(_) => False
		Ok(prepared) => {
			result = prepared.place(StressPrepared.default_run)
			unit = Geom.hypot(10, 10) + 24
			p0 = result.positions.get(0) ?? { x: 0, y: 0 }
			p1 = result.positions.get(1) ?? { x: 0, y: 0 }
			p2 = result.positions.get(2) ?? { x: 0, y: 0 }
			d01 = Geom.hypot(p1.x - p0.x, p1.y - p0.y)
			d12 = Geom.hypot(p2.x - p1.x, p2.y - p1.y)
			d02 = Geom.hypot(p2.x - p0.x, p2.y - p0.y)
			(d01 - unit).abs() < unit * 0.15
				and (d12 - unit).abs() < unit * 0.15
					and (d02 - 2 * unit).abs() < 2 * unit * 0.15
						and result.convergence.converged
		}
	}
}

## A four-cycle lays out with all four edge lengths within 20% of each
## other.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 4)
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 0 }]
	settings = { ..StressPrepared.defaults, tolerance: 1e-7, max_iterations: 2000 }
	match StressPrepared.build({ nodes, edges }, settings) {
		Err(_) => False
		Ok(prepared) => {
			result = prepared.place(StressPrepared.default_run)
			lengths = edges.map(
				|edge| {
					a = result.positions.get(edge.from) ?? { x: 0, y: 0 }
					b = result.positions.get(edge.to) ?? { x: 0, y: 0 }
					Geom.hypot(b.x - a.x, b.y - a.y)
				},
			)
			shortest = lengths.fold(F64.infinity, |acc, l| acc.min(l))
			longest = lengths.fold(0, |acc, l| acc.max(l))
			shortest > 0 and longest <= shortest * 1.2
		}
	}
}

## Identical input, settings, and run arguments produce identical output,
## bit for bit.
expect {
	spec = {
		nodes: List.repeat({ width: 12, height: 8 }, 5),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }, { from: 4, to: 0 }],
	}
	StressPrepared.layout(spec, StressPrepared.defaults, StressPrepared.default_run) == StressPrepared.layout(spec, StressPrepared.defaults, StressPrepared.default_run)
}

## Different seeds are different, equally valid solves: the positions
## differ.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 3)
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }]
	match StressPrepared.build({ nodes, edges }, StressPrepared.defaults) {
		Err(_) => False
		Ok(prepared) => {
			a = prepared.place({ seed: 0, hints: [] })
			b = prepared.place({ seed: 99, hints: [] })
			a.positions != b.positions
		}
	}
}

## Pins are held exactly, in both `place` and `run`: the pinned node keeps
## its pin bit for bit, and the drawing is not translated away from it.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	settings = { ..StressPrepared.defaults, pins: [{ node: 0, x: 5, y: 7 }] }
	match StressPrepared.build(spec, settings) {
		Err(_) => False
		Ok(prepared) => {
			placed = prepared.place(StressPrepared.default_run)
			full = prepared.run(StressPrepared.default_run)
			placed.positions.get(0) == Ok({ x: 5, y: 7 })
				and full.layout.positions.get(0) == Ok({ x: 5, y: 7 })
		}
	}
}

## Position hints make a re-run cheap: starting from a previous result's
## positions converges in fewer iterations than from scratch and stays
## near the hints.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 4)
	edges = [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }]
	match StressPrepared.build({ nodes, edges }, StressPrepared.defaults) {
		Err(_) => False
		Ok(prepared) => {
			from_scratch = prepared.place(StressPrepared.default_run)
			hinted = prepared.place({ seed: 0, hints: from_scratch.positions })
			unit = Geom.hypot(10, 10) + 24
			near = hinted.positions.fold_with_index(
				True,
				|ok, p, i| {
					h = from_scratch.positions.get(i) ?? { x: 0, y: 0 }
					ok and Geom.hypot(p.x - h.x, p.y - h.y) < unit / 4
				},
			)
			hinted.convergence.iterations < from_scratch.convergence.iterations and near
		}
	}
}

## Pivot mode on a ten-node path produces sane output: every position is
## finite and no two nodes coincide.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 10)
	edges = Paths.indices_up_to(9).map(|i| { from: i, to: i + 1 })
	settings = { ..StressPrepared.defaults, mode: Pivots(2) }
	match StressPrepared.build({ nodes, edges }, settings) {
		Err(_) => False
		Ok(prepared) => {
			result = prepared.place(StressPrepared.default_run)
			finite = result.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
			distinct = result.positions.fold_with_index(
				True,
				|ok, a, i|
					ok
						and result.positions.fold_with_index(
							True,
							|inner, b, j| inner and (i == j or a != b),
						),
			)
			finite and distinct
		}
	}
}

## Build reports every independent problem in one result, `Pivots(0)`
## among them.
expect {
	spec = {
		nodes: [{ width: -1, height: 3 }],
		edges: [{ from: 0, to: 5 }],
	}
	settings = {
		node_gap: -4,
		mode: Pivots(0),
		max_iterations: 200,
		tolerance: 0.0,
		pins: [{ node: 9, x: 1, y: 2 }, { node: 0, x: F64.infinity, y: 0 }],
	}
	StressPrepared.build(spec, settings) == Err([
		InvalidNodeWidth(0),
		MissingEdgeEnd(0, 5),
		InvalidNodeGap,
		InvalidPivotCount,
		InvalidTolerance,
		MissingPin(0),
		InvalidPin(1),
	])
}

## Disconnected components are labeled and packed without overlap: the two
## triangles' tight boxes do not intersect.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 6)
	edges = [
		{ from: 0, to: 1 },
		{ from: 1, to: 2 },
		{ from: 2, to: 0 },
		{ from: 3, to: 4 },
		{ from: 4, to: 5 },
		{ from: 5, to: 3 },
	]
	match StressPrepared.build({ nodes, edges }, StressPrepared.defaults) {
		Err(_) => False
		Ok(prepared) => {
			result = prepared.place(StressPrepared.default_run)
			box_of = |first, second, third| {
				corners = [first, second, third].map(|i| result.positions.get(i) ?? { x: 0, y: 0 })
				start = corners.get(0) ?? { x: 0, y: 0 }
				corners.fold(
					{ min_x: start.x, min_y: start.y, max_x: start.x, max_y: start.y },
					|acc, p| {
						min_x: acc.min_x.min(p.x - 5),
						min_y: acc.min_y.min(p.y - 5),
						max_x: acc.max_x.max(p.x + 5),
						max_y: acc.max_y.max(p.y + 5),
					},
				)
			}
			a = box_of(0, 1, 2)
			b = box_of(3, 4, 5)
			separated =
				a.max_x <= b.min_x
					or b.max_x <= a.min_x
						or a.max_y <= b.min_y
							or b.max_y <= a.min_y
			separated and result.components == [0, 0, 0, 1, 1, 1]
		}
	}
}

## The one-shot layout is exactly build followed by run.
expect {
	spec = {
		nodes: List.repeat({ width: 8, height: 4 }, 3),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
	}
	match StressPrepared.build(spec, StressPrepared.defaults) {
		Err(_) => False
		Ok(prepared) =>
			StressPrepared.layout(spec, StressPrepared.defaults, StressPrepared.default_run) == Ok(prepared.run(StressPrepared.default_run))
		}
}

## The convergence record is populated: a zero iteration cap reports zero
## iterations and no convergence, while an ample cap reports the updates
## used and convergence.
expect {
	spec = {
		nodes: List.repeat({ width: 10, height: 10 }, 3),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
	}
	capped = { ..StressPrepared.defaults, max_iterations: 0 }
	match (StressPrepared.build(spec, capped), StressPrepared.build(spec, StressPrepared.defaults)) {
		(Ok(stopped), Ok(free)) => {
			none = stopped.place(StressPrepared.default_run)
			full = free.place(StressPrepared.default_run)
			none.convergence == { iterations: 0, converged: False }
				and full.convergence.converged
					and full.convergence.iterations >= 1
						and full.convergence.iterations <= 200
		}

		_ => False
	}
}

## Near-maximum finite sizes still produce fully finite geometry: unit
## length, scatter scale, packing, and normalization all saturate instead
## of overflowing.
expect {
	spec = {
		nodes: [{ width: 1.7e308, height: 1.7e308 }, { width: 1.7e308, height: 1.7e308 }],
		edges: [{ from: 0, to: 1 }],
	}
	match StressPrepared.layout(spec, StressPrepared.defaults, StressPrepared.default_run) {
		Err(_) => False
		Ok(result) =>
			result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
				and F64.is_finite(result.layout.bounds.width)
					and F64.is_finite(result.layout.bounds.height)
		}
}

## `run` removes residual box overlaps before routing: even a
## zero-iteration placement comes back with no two node boxes strictly
## overlapping.
expect {
	spec = {
		nodes: List.repeat({ width: 40, height: 40 }, 5),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }],
	}
	settings = { ..StressPrepared.defaults, max_iterations: 0 }
	match StressPrepared.build(spec, settings) {
		Err(_) => False
		Ok(prepared) => {
			result = prepared.run(StressPrepared.default_run)
			positions = result.layout.positions
			positions.fold_with_index(
				True,
				|acc, p, i|
					positions.fold_with_index(
						acc,
						|inner, q, j|
							if j <= i {
								inner
							} else {
								dx = (p.x - q.x).abs()
								dy = (p.y - q.y).abs()
								inner and !(dx + 1e-9 < 40 and dy + 1e-9 < 40)
							},
					),
			)
		}
	}
}

## fuzz regression: full finite hints with zero iterations come back
## verbatim — pin override only, no component packing, no perturbation —
## even when every node is its own component (an edgeless graph, where
## packing used to relocate the pin-free singletons).
expect {
	spec = { nodes: List.repeat({ width: 1.0, height: 1.0 }, 4), edges: [] }
	settings = { ..StressPrepared.defaults, max_iterations: 0, pins: [{ node: 0, x: 0 - 128.0, y: 0 - 128.0 }] }
	hints = List.repeat({ x: 0.0, y: 0.0 }, 4)
	match StressPrepared.build(spec, settings) {
		Err(_) => False
		Ok(prepared) => {
			placed = prepared.place({ seed: 0, hints })
			placed.positions == [{ x: 0 - 128.0, y: 0 - 128.0 }, { x: 0.0, y: 0.0 }, { x: 0.0, y: 0.0 }, { x: 0.0, y: 0.0 }]
		}
	}
}
