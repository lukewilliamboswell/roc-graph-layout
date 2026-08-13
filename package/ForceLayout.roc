import Geom
import Rand
import Quadtree
import Paths
import Pack
import EdgeRoutes
import Overlap

## Internal machinery behind `Graph.Force`: joint validation, derived ideal
## edge lengths, deterministic greedy coarsening for multilevel refinement,
## seeded scatter and prolongation, the Barnes-Hut spring iteration, and
## component packing.
##
## Everything here is deterministic: nodes, edges, levels, and components
## are walked in index order, all randomness flows through one `Rand.State`
## threaded in a fixed order, and every division has a guarded denominator
## so no NaN or infinity escapes.
ForceInternals :: {}.{

	## `[0, 1, .., n - 1]`, the building block for walking a bounded range.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Fraction of the spring error `(distance - ideal)` each endpoint moves
	## per iteration, before the temperature cap.
	spring_strength : F64
	spring_strength = 0.5

	## Internal multiplier on the caller's `repulsion * k^2` repulsion
	## scaling. 0.1 is chosen so a single connected pair at default settings
	## settles about 9% above its ideal length ((1 + sqrt(1.4)) / 2 of it),
	## keeping edge lengths near their ideals while still spreading
	## non-adjacent nodes.
	repulsion_strength : F64
	repulsion_strength = 0.1

	## Geometric cooling per refinement iteration: each level's temperature
	## starts at the global scale `k` and shrinks by this factor.
	cooling : F64
	cooling = 0.95

	## Coarsening stops once a level has at most this many nodes.
	coarsest_size : U64
	coarsest_size = 8

	## Prolongation jitter, as a fraction of `k`: children of a merged
	## coarse node start at their parent's position plus this much seeded
	## offset, so they never start exactly coincident.
	prolong_jitter : F64
	prolong_jitter = 0.02

	## Escape jitter, as a fraction of `k`: applied when a node's net force
	## is exactly zero while it coincides with another node, so coincident
	## nodes always separate. Deliberately larger than the default movement
	## tolerance so a separating step is not mistaken for convergence.
	escape_jitter : F64
	escape_jitter = 0.2

	## Joint validation: every independent problem in one pass, in input
	## order — node sizes, then edge endpoints, then each settings field,
	## then pins (a pin can be both missing and invalid; both are reported).
	validation_problems : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), ForceInternals.Settings -> List(ForcePrepared.Problem)
	validation_problems = |nodes, edges, settings| {
		node_problems = nodes.fold_with_index(
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

		edge_problems = edges.fold_with_index(
			node_problems,
			|problems, edge, index| {
				from_problems = if edge.from >= nodes.len() {
					problems.append(MissingEdgeStart(index, edge.from))
				} else {
					problems
				}

				if edge.to >= nodes.len() {
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
		repulsion_problems = if !F64.is_finite(settings.repulsion) or settings.repulsion <= 0 {
			gap_problems.append(InvalidRepulsion)
		} else {
			gap_problems
		}
		gravity_problems = if !F64.is_finite(settings.gravity) or settings.gravity < 0 {
			repulsion_problems.append(InvalidGravity)
		} else {
			repulsion_problems
		}
		angle_problems = if !F64.is_finite(settings.opening_angle) or settings.opening_angle < 0 {
			gravity_problems.append(InvalidOpeningAngle)
		} else {
			gravity_problems
		}
		tolerance_problems = if !F64.is_finite(settings.tolerance) or settings.tolerance <= 0 {
			angle_problems.append(InvalidTolerance)
		} else {
			angle_problems
		}

		settings.pins.fold_with_index(
			tolerance_problems,
			|problems, pin, index| {
				missing_problems = if pin.node >= nodes.len() {
					problems.append(MissingPin(index))
				} else {
					problems
				}

				if !F64.is_finite(pin.x) or !F64.is_finite(pin.y) {
					missing_problems.append(InvalidPin(index))
				} else {
					missing_problems
				}
			},
		)
	}

	## Per-edge ideal length: the mean of the endpoint diagonals plus the
	## configured gap. Zero-size endpoints contribute nothing, so point
	## nodes get pure `node_gap` spacing.
	ideal_lengths : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), F64 -> List(F64)
	ideal_lengths = |nodes, edges, node_gap|
		edges.map(
			|edge| {
				from = nodes.get(edge.from) ?? { width: 0, height: 0 }
				to = nodes.get(edge.to) ?? { width: 0, height: 0 }
				ideal = EdgeRoutes.diagonal(from) / 2 + EdgeRoutes.diagonal(to) / 2 + node_gap
				# derived geometry saturates rather than overflowing to
				# infinity: finite accepted input produces finite output
				if F64.is_finite(ideal) {
					ideal
				} else {
					F64.highest
				}
			},
		)

	## The simulation's global length scale `k`: the running mean of the
	## ideal lengths (computed incrementally, so it cannot overflow), or
	## `node_gap` for an edgeless graph, with a floor of 1 so temperatures
	## and thresholds stay meaningful even when every size and gap is zero.
	scale_of : List(F64), F64 -> F64
	scale_of = |ideals, node_gap| {
		raw = if ideals.is_empty() {
			node_gap
		} else {
			ideals.fold_with_index(
				0.0,
				|mean, ideal, index| mean + (ideal - mean) / (index + 1).to_f64(),
			)
		}

		if raw > 0 {
			raw
		} else {
			1
		}
	}

	## Per-node pin lookup from the pin list. A node pinned more than once
	## takes its last pin.
	pin_map_of : U64, List({ node : U64, x : F64, y : F64 }) -> List([Pin({ x : F64, y : F64 }), Free])
	pin_map_of = |node_count, pins|
		pins.fold(
			List.repeat(Free, node_count),
			|acc, pin| acc.set(pin.node, Pin({ x: pin.x, y: pin.y })) ?? acc,
		)

	is_pinned : List([Pin({ x : F64, y : F64 }), Free]), U64 -> Bool
	is_pinned = |pins, index|
		match pins.get(index) ?? Free {
			Pin(_) => True
			Free => False
		}

	## One multilevel graph level: sizes, springs (attraction edges with
	## ideal lengths), pins, and — on coarse levels — `parent_of`, mapping
	## each node of the next finer level to its node here. The finest level
	## carries an empty `parent_of`.
	Level : {
		sizes : List({ width : F64, height : F64 }),
		springs : List({ u : U64, v : U64, ideal : F64 }),
		pins : List([Pin({ x : F64, y : F64 }), Free]),
		parent_of : List(U64),
	}

	## One deterministic coarsening round by greedy matching: walk nodes by
	## index and match each unmatched, unpinned node with its first
	## unmatched, unpinned neighbor in adjacency order; everything else
	## carries over solo. A merged pair becomes the square of equivalent
	## area (side `sqrt(area_a + area_b)`); solo nodes keep their rectangle.
	## Pinned nodes are never merged, so pins map one-to-one through every
	## level. Coarse springs are the fine springs with both endpoints
	## mapped, intra-pair springs dropped, and ideals recomputed from the
	## coarse sizes. Returns `Stop` when the round shrinks the level by
	## less than 10%.
	coarsen_once : ForceInternals.Level, F64 -> [Coarser(ForceInternals.Level), Stop]
	coarsen_once = |level, node_gap| {
		n = level.sizes.len()
		none = U64.highest
		adj = Paths.adjacency(n, level.springs.map(|s| { from: s.u, to: s.v }))

		mates = ForceInternals.indices_up_to(n).fold(
			List.repeat(none, n),
			|acc, i| {
				if (acc.get(i) ?? none) != none or ForceInternals.is_pinned(level.pins, i) {
					acc
				} else {
					pick = Paths.neighbors_of(adj, i).fold(
						none,
						|found, j|
							if found != none {
								found
							} else if j != i and (acc.get(j) ?? none) == none and !ForceInternals.is_pinned(level.pins, j) {
								j
							} else {
								none
							},
					)
					if pick == none {
						acc
					} else {
						(acc.set(i, pick) ?? acc).set(pick, i) ?? acc
					}
				}
			},
		)

		grouped = ForceInternals.indices_up_to(n).fold(
			{ parent_of: List.repeat(0, n), count: 0 },
			|acc, i| {
				mate = mates.get(i) ?? none
				if mate != none and mate < i {
					# already assigned alongside its lower-index mate
					acc
				} else {
					with_self = acc.parent_of.set(i, acc.count) ?? acc.parent_of
					parent_of = if mate == none {
						with_self
					} else {
						with_self.set(mate, acc.count) ?? with_self
					}
					{ parent_of, count: acc.count + 1 }
				}
			},
		)

		if grouped.count * 10 > n * 9 {
			Stop
		} else {
			members = ForceInternals.indices_up_to(n).fold(
				List.repeat({ first: none, second: none }, grouped.count),
				|acc, i| {
					cid = grouped.parent_of.get(i) ?? 0
					entry = acc.get(cid) ?? { first: none, second: none }
					updated = if entry.first == none {
						{ ..entry, first: i }
					} else {
						{ ..entry, second: i }
					}
					acc.set(cid, updated) ?? acc
				},
			)

			sizes = members.map(
				|entry| {
					a = level.sizes.get(entry.first) ?? { width: 0, height: 0 }
					if entry.second == none {
						a
					} else {
						b = level.sizes.get(entry.second) ?? { width: 0, height: 0 }
						side = (a.width * a.height + b.width * b.height).sqrt()
						{ width: side, height: side }
					}
				},
			)
			pins = members.map(
				|entry|
					if entry.second == none {
						level.pins.get(entry.first) ?? Free
					} else {
						Free
					},
			)
			springs = level.springs.fold(
				[],
				|acc, s| {
					cu = grouped.parent_of.get(s.u) ?? 0
					cv = grouped.parent_of.get(s.v) ?? 0
					if cu == cv {
						acc
					} else {
						size_u = sizes.get(cu) ?? { width: 0, height: 0 }
						size_v = sizes.get(cv) ?? { width: 0, height: 0 }
						acc.append({ u: cu, v: cv, ideal: (EdgeRoutes.diagonal(size_u) + EdgeRoutes.diagonal(size_v)) / 2 + node_gap })
					}
				},
			)

			Coarser({ sizes, springs, pins, parent_of: grouped.parent_of })
		}
	}

	## The multilevel hierarchy, finest first, coarsest last. Fuel bounds
	## the recursion; every accepted round shrinks the level by at least
	## 10%, so the chain is logarithmic in practice.
	build_levels : ForceInternals.Level, F64, U64 -> List(ForceInternals.Level)
	build_levels = |level, node_gap, fuel|
		if fuel == 0 or level.sizes.len() <= ForceInternals.coarsest_size {
			[level]
		} else {
			match ForceInternals.coarsen_once(level, node_gap) {
				Stop => [level]
				Coarser(next) => [level].concat(ForceInternals.build_levels(next, node_gap, fuel - 1))
			}
		}

	## Where a fresh component's seeded scatter is centered: the centroid
	## of its pinned positions, or the origin when nothing is pinned.
	pin_anchor : List([Pin({ x : F64, y : F64 }), Free]) -> { x : F64, y : F64 }
	pin_anchor = |pins| {
		total = pins.fold(
			{ x: 0.0, y: 0.0, count: 0.0 },
			|acc, slot|
				match slot {
					Pin(p) => { x: acc.x + p.x, y: acc.y + p.y, count: acc.count + 1 }
					Free => acc
				},
		)
		if total.count > 0 {
			{ x: total.x / total.count, y: total.y / total.count }
		} else {
			{ x: 0, y: 0 }
		}
	}

	## Seeded scatter for the coarsest level: each free node draws two unit
	## doubles, in index order, and lands uniformly in a square of half
	## side `k * sqrt(count)` around the anchor. Pinned nodes sit at their
	## pins and draw nothing.
	scatter : U64, List([Pin({ x : F64, y : F64 }), Free]), F64, { x : F64, y : F64 }, Rand.State -> { positions : List({ x : F64, y : F64 }), rand : Rand.State }
	scatter = |count, pins, k, anchor, rand0| {
		raw_radius = k * count.to_f64().sqrt()
		# derived scale saturates rather than overflowing to infinity
		radius = if F64.is_finite(raw_radius) {
			raw_radius
		} else {
			F64.highest
		}
		ForceInternals.indices_up_to(count).fold(
			{ positions: [], rand: rand0 },
			|st, i|
				match pins.get(i) ?? Free {
					Pin(p) => { positions: st.positions.append({ x: p.x, y: p.y }), rand: st.rand }
					Free => {
						a = Rand.step_unit_f64(st.rand)
						b = Rand.step_unit_f64(a.state)
						{
							positions: st.positions.append({
								x: anchor.x + (a.value - 0.5) * 2 * radius,
								y: anchor.y + (b.value - 0.5) * 2 * radius,
							}),
							rand: b.state,
						}
					}
				},
		)
	}

	## Positions for a finer level from its coarser parents': pinned nodes
	## sit at their pins; every other node starts at its parent's position
	## plus a tiny seeded jitter (two unit doubles, index order) so the two
	## children of a merged pair never start exactly coincident.
	prolong : List({ x : F64, y : F64 }), List(U64), List([Pin({ x : F64, y : F64 }), Free]), F64, Rand.State -> { positions : List({ x : F64, y : F64 }), rand : Rand.State }
	prolong = |coarse_positions, parent_of, pins, k, rand0|
		parent_of.fold_with_index(
			{ positions: [], rand: rand0 },
			|st, cid, i|
				match pins.get(i) ?? Free {
					Pin(p) => { positions: st.positions.append({ x: p.x, y: p.y }), rand: st.rand }
					Free => {
						parent = coarse_positions.get(cid) ?? { x: 0, y: 0 }
						a = Rand.step_unit_f64(st.rand)
						b = Rand.step_unit_f64(a.state)
						jitter = k * ForceInternals.prolong_jitter
						{
							positions: st.positions.append({
								x: parent.x + (a.value - 0.5) * jitter,
								y: parent.y + (b.value - 0.5) * jitter,
							}),
							rand: b.state,
						}
					}
				},
		)

	## Overwrite pinned slots with their pin positions, leaving free nodes
	## where they are — how a hinted start still holds pins exactly.
	apply_pins : List({ x : F64, y : F64 }), List([Pin({ x : F64, y : F64 }), Free]) -> List({ x : F64, y : F64 })
	apply_pins = |positions, pins|
		positions.map_with_index(
			|p, i|
				match pins.get(i) ?? Free {
					Pin(q) => { x: q.x, y: q.y }
					Free => p
				},
		)

	## Replace a non-finite force component with a bounded stand-in: the
	## temperature with the overflowing force's sign, or zero for NaN. The
	## temperature cap then keeps the move finite, so extreme-but-valid
	## inputs cannot leak NaN or infinity into positions.
	sanitize : F64, F64 -> F64
	sanitize = |value, temp|
		if F64.is_finite(value) {
			value
		} else if value > 0 {
			temp
		} else if value < 0 {
			0 - temp
		} else {
			0
		}

	## Whether any other node sits at exactly the same position.
	coincides : List({ x : F64, y : F64 }), U64, { x : F64, y : F64 } -> Bool
	coincides = |positions, index, p|
		positions.fold_with_index(
			False,
			|acc, q, j| acc or (j != index and q.x == p.x and q.y == p.y),
		)

	## Per-component iteration configuration, derived once: the global
	## scale, the combined repulsion factor, gravity, the Barnes-Hut
	## opening angle, and the absolute movement threshold `tolerance * k`.
	Config : { k : F64, repulsion_scale : F64, gravity : F64, theta : F64, threshold : F64 }

	## One synchronous refinement iteration: spring, repulsion (Barnes-Hut),
	## and gravity forces are computed for every node from the same starting
	## positions, then all free nodes move at once, each move capped by the
	## temperature. Pinned nodes are excluded entirely. A free node whose
	## net force is exactly zero while it coincides with another node takes
	## a seeded escape jitter instead. Returns the new positions, the
	## largest single move, and the advanced random state (consumed only by
	## escape jitter, in node index order).
	one_iteration : List({ x : F64, y : F64 }), List({ u : U64, v : U64, ideal : F64 }), List([Pin({ x : F64, y : F64 }), Free]), ForceInternals.Config, F64, Rand.State -> { positions : List({ x : F64, y : F64 }), max_move : F64, rand : Rand.State }
	one_iteration = |positions, springs, pins, cfg, temp, rand0| {
		n = positions.len()
		zero = { x: 0.0, y: 0.0 }
		tree = Quadtree.build(positions)
		total = positions.fold({ x: 0.0, y: 0.0 }, |acc, p| { x: acc.x + p.x, y: acc.y + p.y })
		divisor = if n == 0 {
			1.0
		} else {
			n.to_f64()
		}
		centroid = { x: total.x / divisor, y: total.y / divisor }

		spring_disp = springs.fold(
			List.repeat(zero, n),
			|acc, s| {
				pu = positions.get(s.u) ?? zero
				pv = positions.get(s.v) ?? zero
				dx = pv.x - pu.x
				dy = pv.y - pu.y
				d = Geom.hypot(dx, dy)
				if d > 0 {
					f = ForceInternals.spring_strength * (d - s.ideal) / d
					du = acc.get(s.u) ?? zero
					with_u = acc.set(s.u, { x: du.x + dx * f, y: du.y + dy * f }) ?? acc
					dv = with_u.get(s.v) ?? zero
					with_u.set(s.v, { x: dv.x - dx * f, y: dv.y - dy * f }) ?? with_u
				} else {
					# coincident endpoints: repulsion or escape jitter separates them
					acc
				}
			},
		)

		ForceInternals.indices_up_to(n).fold(
			{ positions, max_move: 0.0, rand: rand0 },
			|st, i|
				if ForceInternals.is_pinned(pins, i) {
					st
				} else {
					p = positions.get(i) ?? zero
					rep = Quadtree.repulsion_at(tree, p, cfg.theta)
					sd = spring_disp.get(i) ?? zero
					fx = ForceInternals.sanitize(sd.x + rep.x * cfg.repulsion_scale + (centroid.x - p.x) * cfg.gravity, temp)
					fy = ForceInternals.sanitize(sd.y + rep.y * cfg.repulsion_scale + (centroid.y - p.y) * cfg.gravity, temp)
					pushed = if fx == 0 and fy == 0 and ForceInternals.coincides(positions, i, p) {
						a = Rand.step_unit_f64(st.rand)
						b = Rand.step_unit_f64(a.state)
						jitter = cfg.k * ForceInternals.escape_jitter
						{ x: (a.value - 0.5) * jitter, y: (b.value - 0.5) * jitter, rand: b.state }
					} else {
						{ x: fx, y: fy, rand: st.rand }
					}
					magnitude = Geom.hypot(pushed.x, pushed.y)
					factor = if magnitude > temp {
						temp / magnitude
					} else {
						1.0
					}
					move_x = pushed.x * factor
					move_y = pushed.y * factor
					{
						positions: st.positions.set(i, { x: p.x + move_x, y: p.y + move_y }) ?? st.positions,
						max_move: st.max_move.max(Geom.hypot(move_x, move_y)),
						rand: pushed.rand,
					}
				},
		)
	}

	## Refine one level until the largest move in an iteration drops under
	## the threshold or the budget is spent. The temperature starts at `k`
	## and cools geometrically each iteration. `converged` reports whether
	## the threshold — not the budget — ended the loop.
	refine : List({ x : F64, y : F64 }), List({ u : U64, v : U64, ideal : F64 }), List([Pin({ x : F64, y : F64 }), Free]), ForceInternals.Config, U64, Rand.State -> { positions : List({ x : F64, y : F64 }), temp : F64, iterations : U64, converged : Bool, rand : Rand.State }
	refine = |start, springs, pins, cfg, budget, rand0|
		ForceInternals.indices_up_to(budget).fold(
			{ positions: start, temp: cfg.k, iterations: 0, converged: False, rand: rand0 },
			|st, _|
				if st.converged {
					st
				} else {
					step = ForceInternals.one_iteration(st.positions, springs, pins, cfg, st.temp, st.rand)
					{
						positions: step.positions,
						temp: st.temp * ForceInternals.cooling,
						iterations: st.iterations + 1,
						converged: step.max_move < cfg.threshold,
						rand: step.rand,
					}
				},
		)

	pow2 : U64 -> U64
	pow2 = |exponent|
		ForceInternals.indices_up_to(exponent.min(62)).fold(1, |acc, _| acc * 2)

	## The iteration budget for level `index` (0 = finest) of `count`
	## levels: a single level takes the whole cap; otherwise the finest
	## level gets half the cap and each coarser level half of the next
	## finer level's share, never dropping to zero while the cap is
	## positive. Coarse levels are small, so shorting them is cheap; the
	## finest level does the visible polishing.
	level_budget : U64, U64, U64 -> U64
	level_budget = |max_iterations, index, count|
		if count <= 1 {
			max_iterations
		} else if max_iterations == 0 {
			0
		} else {
			(max_iterations / ForceInternals.pow2(index + 1)).max(1)
		}

	## Lay out one connected component: multilevel from a seeded scatter,
	## or a single full-budget refinement from hinted positions (a hinted
	## run refines the previous drawing, so coarsening is skipped).
	simulate_component : {
		sizes : List({ width : F64, height : F64 }),
		springs : List({ u : U64, v : U64, ideal : F64 }),
		pins : List([Pin({ x : F64, y : F64 }), Free]),
		start : [Hinted(List({ x : F64, y : F64 })), Fresh],
		k : F64,
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		theta : F64,
		tolerance : F64,
		max_iterations : U64,
		rand : Rand.State,
	} -> { positions : List({ x : F64, y : F64 }), iterations : U64, converged : Bool, rand : Rand.State }
	simulate_component = |input| {
		cfg = {
			k: input.k,
			repulsion_scale: input.repulsion * ForceInternals.repulsion_strength * input.k * input.k,
			gravity: input.gravity,
			theta: input.theta,
			threshold: input.tolerance * input.k,
		}
		match input.start {
			Hinted(hinted) => {
				start = ForceInternals.apply_pins(hinted, input.pins)
				refined = ForceInternals.refine(start, input.springs, input.pins, cfg, input.max_iterations, input.rand)
				{ positions: refined.positions, iterations: refined.iterations, converged: refined.converged, rand: refined.rand }
			}

			Fresh => {
				finest = { sizes: input.sizes, springs: input.springs, pins: input.pins, parent_of: [] }
				levels = ForceInternals.build_levels(finest, input.node_gap, input.sizes.len())
				level_count = levels.len()
				coarsest = levels.get(level_count - 1) ?? finest
				anchor = ForceInternals.pin_anchor(coarsest.pins)
				scattered = ForceInternals.scatter(coarsest.sizes.len(), coarsest.pins, input.k, anchor, input.rand)

				ForceInternals.indices_up_to(level_count).fold(
					{ positions: scattered.positions, iterations: 0, converged: False, rand: scattered.rand },
					|st, step| {
						index = level_count - 1 - step
						level = levels.get(index) ?? finest
						started = if index == level_count - 1 {
							{ positions: st.positions, rand: st.rand }
						} else {
							coarser_parent_of = (levels.get(index + 1) ?? finest).parent_of
							ForceInternals.prolong(st.positions, coarser_parent_of, level.pins, input.k, st.rand)
						}
						budget = ForceInternals.level_budget(input.max_iterations, index, level_count)
						refined = ForceInternals.refine(started.positions, level.springs, level.pins, cfg, budget, started.rand)
						{
							positions: refined.positions,
							iterations: st.iterations + refined.iterations,
							converged: refined.converged,
							rand: refined.rand,
						}
					},
				)
			}
		}
	}

	## Simulate every component in label order, threading one random state
	## through scatter, prolongation, and refinement in that fixed order,
	## and writing each component's local positions back to the global
	## index space. `converged` holds only when every component's finest
	## level stopped by tolerance; `iterations` totals every refinement
	## iteration across all levels and components.
	simulate_all : {
		nodes : List({ width : F64, height : F64 }),
		edges : List({ from : U64, to : U64 }),
		ideals : List(F64),
		labels : List(U64),
		component_count : U64,
		pin_map : List([Pin({ x : F64, y : F64 }), Free]),
		k : F64,
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		theta : F64,
		tolerance : F64,
		max_iterations : U64,
		hints : [Full(List({ x : F64, y : F64 })), Absent],
		seed : U32,
	} -> { positions : List({ x : F64, y : F64 }), iterations : U64, converged : Bool }
	simulate_all = |input| {
		n = input.nodes.len()
		zero = { x: 0.0, y: 0.0 }
		result = ForceInternals.indices_up_to(input.component_count).fold(
			{ positions: List.repeat(zero, n), iterations: 0, converged: True, rand: Rand.seed(input.seed) },
			|st, component| {
				members = ForceInternals.indices_up_to(n).fold(
					[],
					|acc, i|
						if (input.labels.get(i) ?? 0) == component {
							acc.append(i)
						} else {
							acc
						},
				)
				local_of = members.fold_with_index(
					List.repeat(0, n),
					|acc, global, local| acc.set(global, local) ?? acc,
				)
				sizes = members.map(|global| input.nodes.get(global) ?? { width: 0, height: 0 })
				pins = members.map(|global| input.pin_map.get(global) ?? Free)
				springs = input.edges.fold_with_index(
					[],
					|acc, edge, index|
						if edge.from != edge.to and (input.labels.get(edge.from) ?? 0) == component {
							acc.append({
								u: local_of.get(edge.from) ?? 0,
								v: local_of.get(edge.to) ?? 0,
								ideal: input.ideals.get(index) ?? input.node_gap,
							})
						} else {
							acc
						},
				)
				start = match input.hints {
					Full(hinted) => Hinted(members.map(|global| hinted.get(global) ?? zero))
					Absent => Fresh
				}
				sim = ForceInternals.simulate_component({
					sizes,
					springs,
					pins,
					start,
					k: input.k,
					node_gap: input.node_gap,
					repulsion: input.repulsion,
					gravity: input.gravity,
					theta: input.theta,
					tolerance: input.tolerance,
					max_iterations: input.max_iterations,
					rand: st.rand,
				})
				# `global` came from indices_up_to(n), and the destination has
				# length n. The fallback is unreachable and must not retain `acc`:
				# doing so makes every write copy the whole global position list.
				positions = members.fold_with_index(
					st.positions,
					|acc, global, local| acc.set(global, sim.positions.get(local) ?? zero) ?? [],
				)
				{
					positions,
					iterations: st.iterations + sim.iterations,
					converged: st.converged and sim.converged,
					rand: sim.rand,
				}
			},
		)
		{ positions: result.positions, iterations: result.iterations, converged: result.converged }
	}

	## Assemble components into one drawing. Each component's tight node
	## box (positions plus half extents) becomes one box; the boxes of
	## components without pins go through the shared shelf packer with
	## `gap = node_gap * 2` and a square target, and each such component is
	## translated to its packed slot. A component holding at least one pin
	## is anchored: it keeps its absolute coordinates exactly, and the
	## packed block of free components is placed to the right of the
	## anchored drawing, top-aligned, a double gap away.
	pack_components : {
		positions : List({ x : F64, y : F64 }),
		nodes : List({ width : F64, height : F64 }),
		labels : List(U64),
		component_count : U64,
		pin_map : List([Pin({ x : F64, y : F64 }), Free]),
		node_gap : F64,
	} -> List({ x : F64, y : F64 })
	pack_components = |input| {
		count = input.component_count
		if count == 0 {
			input.positions
		} else {
			huge = F64.infinity
			empty_box = { min_x: huge, min_y: huge, max_x: 0 - huge, max_y: 0 - huge }
			boxes = ForceInternals.indices_up_to(input.positions.len()).fold(
				List.repeat(empty_box, count),
				|acc, i| {
					component = input.labels.get(i) ?? 0
					p = input.positions.get(i) ?? { x: 0, y: 0 }
					size = input.nodes.get(i) ?? { width: 0, height: 0 }
					box = acc.get(component) ?? empty_box
					acc.set(
						component,
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
			dims = boxes.map(|b| { width: Geom.saturate(b.max_x - b.min_x), height: Geom.saturate(b.max_y - b.min_y) })
			centers = boxes.map(|b| { x: (b.min_x + b.max_x) / 2, y: (b.min_y + b.max_y) / 2 })
			pack_settings = { gap: input.node_gap * 2, target_aspect: 1.0 }

			anchored = ForceInternals.indices_up_to(input.positions.len()).fold(
				List.repeat(False, count),
				|acc, i|
					if ForceInternals.is_pinned(input.pin_map, i) {
						acc.set(input.labels.get(i) ?? 0, True) ?? acc
					} else {
						acc
					},
			)
			has_anchor = anchored.fold(False, |acc, flag| acc or flag)

			offsets = if !has_anchor {
				packed = Pack.pack(dims, pack_settings)
				ForceInternals.indices_up_to(count).map(
					|component| {
						slot = packed.positions.get(component) ?? { x: 0, y: 0 }
						center = centers.get(component) ?? { x: 0, y: 0 }
						{ x: Geom.saturate(slot.x - center.x), y: Geom.saturate(slot.y - center.y) }
					},
				)
			} else {
				free_ids = ForceInternals.indices_up_to(count).fold(
					[],
					|acc, component|
						if anchored.get(component) ?? False {
							acc
						} else {
							acc.append(component)
						},
				)
				anchored_box = ForceInternals.indices_up_to(count).fold(
					empty_box,
					|acc, component|
						if anchored.get(component) ?? False {
							box = boxes.get(component) ?? empty_box
							{
								min_x: acc.min_x.min(box.min_x),
								min_y: acc.min_y.min(box.min_y),
								max_x: acc.max_x.max(box.max_x),
								max_y: acc.max_y.max(box.max_y),
							}
						} else {
							acc
						},
				)
				packed = Pack.pack(free_ids.map(|component| dims.get(component) ?? { width: 0, height: 0 }), pack_settings)
				base = { x: anchored_box.max_x + input.node_gap * 2, y: anchored_box.min_y }
				free_ids.fold_with_index(
					List.repeat({ x: 0.0, y: 0.0 }, count),
					|acc, component, rank| {
						slot = packed.positions.get(rank) ?? { x: 0, y: 0 }
						center = centers.get(component) ?? { x: 0, y: 0 }
						acc.set(component, { x: base.x + slot.x - center.x, y: base.y + slot.y - center.y }) ?? acc
					},
				)
			}

			input.positions.map_with_index(
				|p, i| {
					offset = offsets.get(input.labels.get(i) ?? 0) ?? { x: 0, y: 0 }
					# packed translation saturates so extreme-but-finite
					# drawings stay finite
					{ x: Geom.saturate(p.x + offset.x), y: Geom.saturate(p.y + offset.y) }
				},
			)
		}
	}

	## Per-node outward unit direction for self-loop routing: away from the
	## node's component centroid, or straight up when the node sits exactly
	## on it.
	outward_directions : List({ x : F64, y : F64 }), List(U64), U64 -> List({ x : F64, y : F64 })
	outward_directions = |positions, labels, component_count| {
		sums = positions.fold_with_index(
			List.repeat({ x: 0.0, y: 0.0, count: 0.0 }, component_count),
			|acc, p, i| {
				component = labels.get(i) ?? 0
				entry = acc.get(component) ?? { x: 0.0, y: 0.0, count: 0.0 }
				acc.set(component, { x: entry.x + p.x, y: entry.y + p.y, count: entry.count + 1 }) ?? acc
			},
		)
		centroids = sums.map(
			|s|
				if s.count > 0 {
					{ x: s.x / s.count, y: s.y / s.count }
				} else {
					{ x: 0, y: 0 }
				},
		)
		positions.map_with_index(
			|p, i| {
				centroid = centroids.get(labels.get(i) ?? 0) ?? { x: 0, y: 0 }
				dx = p.x - centroid.x
				dy = p.y - centroid.y
				length = Geom.hypot(dx, dy)
				if length > 0 {
					{ x: dx / length, y: dy / length }
				} else {
					{ x: 0, y: 0 - 1.0 }
				}
			},
		)
	}

	## Tight box over node extents and every route point (curve controls
	## included), without moving anything — the pinned-run replacement for
	## the shared normalization, which would translate pinned nodes off
	## their pins.
	tight_bounds : List({ x : F64, y : F64 }), List({ width : F64, height : F64 }), List(Geom.Route) -> { x : F64, y : F64, width : F64, height : F64 }
	tight_bounds = |positions, nodes, routes| {
		box0 = match positions.get(0) {
			Ok(p) => {
				node = nodes.get(0) ?? { width: 0, height: 0 }
				{ min_x: p.x - node.width / 2, min_y: p.y - node.height / 2, max_x: p.x + node.width / 2, max_y: p.y + node.height / 2 }
			}

			Err(_) => { min_x: 0, min_y: 0, max_x: 0, max_y: 0 }
		}

		node_box = positions.fold_with_index(
			box0,
			|acc, p, index| {
				node = nodes.get(index) ?? { width: 0, height: 0 }
				{
					min_x: acc.min_x.min(p.x - node.width / 2),
					min_y: acc.min_y.min(p.y - node.height / 2),
					max_x: acc.max_x.max(p.x + node.width / 2),
					max_y: acc.max_y.max(p.y + node.height / 2),
				}
			},
		)

		extend = |acc, p| {
			min_x: acc.min_x.min(p.x),
			min_y: acc.min_y.min(p.y),
			max_x: acc.max_x.max(p.x),
			max_y: acc.max_y.max(p.y),
		}
		box = routes.fold(
			node_box,
			|acc, route|
				match route {
					Line(from, to) => extend(extend(acc, from), to)
					Polyline(points) => points.fold(acc, extend)
					Curves(segments) =>
						segments.fold(
							acc,
							|inner, seg| extend(extend(extend(extend(inner, seg.from), seg.ctl_a), seg.ctl_b), seg.to),
						)
					},
		)

		{ x: box.min_x, y: box.min_y, width: Geom.saturate(box.max_x - box.min_x), height: Geom.saturate(box.max_y - box.min_y) }
	}

	## Settings shape shared with the public alias; internals take it
	## structurally so they never depend on the witness.
	Settings : {
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		opening_angle : F64,
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	}
}

## A validated force-directed layout: seeded, multilevel, Barnes-Hut
## approximated spring placement for general graphs.
##
## `build` is the only fallible boundary: it checks the input and settings
## jointly (reporting every independent problem) and caches the adjacency
## reading — component labels, per-edge ideal lengths, and the global length
## scale — so `place`, `run`, and every reroll from a different seed are
## total. `place` returns packed center positions only (the public wiring
## inserts overlap removal between placement and routing); `run` adds the
## shared edge routing and normalization.
##
## Determinism: identical spec, settings, seed, and hints produce identical
## bits. All randomness derives from the run seed through one generator
## state, consumed in a fixed order — per component in label order: coarsest
## scatter, then per level prolongation jitter and any escape jitter, all in
## node index order.
##
## Position hints (`RunArgs.hints`) must be index-aligned with the spec and
## either empty or full length with finite coordinates; anything else is
## treated as absent. A full hint list skips the multilevel start entirely
## and refines the hinted drawing with the whole iteration budget.
##
## Pinned nodes are held exactly by exclusion from every update. A drawing
## with pins is anchored to the caller's coordinates: pinned components are
## not repositioned by component packing, and `run` reports the drawing's
## true bounding box instead of translating the drawing to the origin.
ForcePrepared := {
	nodes : List({ width : F64, height : F64 }),
	edges : List({ from : U64, to : U64 }),
	settings : {
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		opening_angle : F64,
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	},
	labels : List(U64),
	component_count : U64,
	ideals : List(F64),
	scale : F64,
	pin_map : List([Pin({ x : F64, y : F64 }), Free]),
}.{

	## Sized nodes and the edges between them; a node is its index in
	## `nodes`, an edge its index in `edges`, and every output list aligns
	## to those orders.
	Spec : {
		nodes : List({ width : F64, height : F64 }),
		edges : List({ from : U64, to : U64 }),
	}

	## How the simulation reads the graph. `node_gap` drives the per-edge
	## ideal lengths (mean endpoint diagonal plus the gap); `repulsion`
	## scales how strongly non-adjacent nodes spread; `gravity` pulls each
	## node toward its component's centroid; `opening_angle` is the
	## Barnes-Hut accuracy dial (0 is exact, values near 1 are fast);
	## `max_iterations` bounds total work; `tolerance` is the relative
	## movement threshold that ends refinement early; `pins` holds the
	## listed nodes exactly at the given positions.
	Settings : {
		node_gap : F64,
		repulsion : F64,
		gravity : F64,
		opening_angle : F64,
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	}

	## Invalid sizes, edge endpoints, settings, or pins found while
	## checking input. Pin problems carry the pin's index in the pin list.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidRepulsion,
		InvalidGravity,
		InvalidOpeningAngle,
		InvalidTolerance,
		MissingPin(U64),
		InvalidPin(U64),
	]

	## Per-run inputs that select a particular solve: the random seed, and
	## optional position hints — index-aligned with the spec, either empty
	## or one finite position per node — that make the run refine a
	## previous drawing instead of starting fresh.
	RunArgs : { seed : U32, hints : List({ x : F64, y : F64 }) }

	## Geometry plus each node's connected-component label (assigned 0, 1,
	## 2, .. in order of each component's lowest node index) and how the
	## iteration ended: total refinement iterations used, and whether the
	## final refinement stopped under the movement tolerance rather than at
	## the iteration cap.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		components : List(U64),
		convergence : { iterations : U64, converged : Bool },
	}

	defaults : Settings
	defaults = { node_gap: 24, repulsion: 1.0, gravity: 0.05, opening_angle: 0.9, max_iterations: 300, tolerance: 0.01, pins: [] }

	default_run : RunArgs
	default_run = { seed: 0, hints: [] }

	## Check the spec and settings jointly — every independent problem is
	## reported in one pass — and cache the reusable reading: component
	## labels, per-edge ideal lengths, the global length scale, and the
	## per-node pin lookup.
	build : Spec, Settings -> [Ok(ForcePrepared), Err(List(Problem))]
	build = |spec, settings| {
		problems = ForceInternals.validation_problems(spec.nodes, spec.edges, settings)
		if !problems.is_empty() {
			Err(problems)
		} else {
			ideals = ForceInternals.ideal_lengths(spec.nodes, spec.edges, settings.node_gap)
			components = Paths.components(Paths.adjacency(spec.nodes.len(), spec.edges))

			prepared : ForcePrepared
			prepared = {
				nodes: spec.nodes,
				edges: spec.edges,
				settings,
				labels: components.labels,
				component_count: components.count,
				ideals,
				scale: ForceInternals.scale_of(ideals, settings.node_gap),
				pin_map: ForceInternals.pin_map_of(spec.nodes.len(), settings.pins),
			}
			Ok(prepared)
		}
	}

	## Placement only — final packed center positions, no routes and no
	## overlap pass (`run` applies the shared overlap removal before
	## routing; callers composing their own pipeline from `place` insert
	## `Overlap.remove` themselves). Components are simulated independently
	## and packed side by side; components holding pins keep their absolute
	## coordinates.
	place : ForcePrepared, RunArgs -> { positions : List({ x : F64, y : F64 }), components : List(U64), convergence : { iterations : U64, converged : Bool } }
	place = |prepared, args| {
		n = prepared.nodes.len()
		hints_ok =
			args.hints.len() == n
				and n > 0
					and args.hints.all(|h| F64.is_finite(h.x) and F64.is_finite(h.y))

		simulated = ForceInternals.simulate_all({
			nodes: prepared.nodes,
			edges: prepared.edges,
			ideals: prepared.ideals,
			labels: prepared.labels,
			component_count: prepared.component_count,
			pin_map: prepared.pin_map,
			k: prepared.scale,
			node_gap: prepared.settings.node_gap,
			repulsion: prepared.settings.repulsion,
			gravity: prepared.settings.gravity,
			theta: prepared.settings.opening_angle,
			tolerance: prepared.settings.tolerance,
			max_iterations: prepared.settings.max_iterations,
			hints: if hints_ok {
				Full(args.hints)
			} else {
				Absent
			},
			seed: args.seed,
		})

		# Full finite hints carry the caller's component arrangement — a
		# previous drawing already placed its components — so packing is
		# skipped and the hinted placement is refined in place. Packing
		# exists for fresh seeded scatters, where components would otherwise
		# start on top of each other.
		positions = if hints_ok {
			simulated.positions
		} else {
			ForceInternals.pack_components({
				positions: simulated.positions,
				nodes: prepared.nodes,
				labels: prepared.labels,
				component_count: prepared.component_count,
				pin_map: prepared.pin_map,
				node_gap: prepared.settings.node_gap,
			})
		}

		{
			positions,
			components: prepared.labels,
			convergence: { iterations: simulated.iterations, converged: simulated.converged },
		}
	}

	## Place, remove residual box overlaps with the shared minimal-movement
	## pass, then route every edge with the shared rules (clipped lines,
	## canonical parallel-edge fans, self-loop teardrops pointing away from
	## the component centroid) and normalize the drawing to the origin.
	## When pins exist the drawing is not translated and the overlap pass
	## is skipped — pins hold exactly — and `bounds` reports the drawing's
	## true box instead.
	run : ForcePrepared, RunArgs -> Result
	run = |prepared, args| {
		placed = ForcePrepared.place(prepared, args)
		# The shared overlap pass cleans residual box overlaps from the
		# simulation with minimal movement before routing. Pinned drawings
		# skip it — the pass cannot yet hold a pin exactly — and keep
		# their raw positions.
		positions = if prepared.settings.pins.is_empty() {
			Overlap.remove(placed.positions, prepared.nodes, 0)
		} else {
			placed.positions
		}
		outwards = ForceInternals.outward_directions(positions, prepared.labels, prepared.component_count)
		routes = EdgeRoutes.route_edges(prepared.edges, positions, outwards, prepared.nodes, prepared.settings.node_gap)

		layout = if prepared.settings.pins.is_empty() {
			EdgeRoutes.normalize(positions, prepared.nodes, routes)
		} else {
			{
				positions,
				bounds: ForceInternals.tight_bounds(positions, prepared.nodes, routes),
				routes,
			}
		}

		{ layout, components: placed.components, convergence: placed.convergence }
	}

	## Check and lay out in one call: exactly `build` followed by `run`.
	layout : Spec, Settings, RunArgs -> [Ok(Result), Err(List(Problem))]
	layout = |spec, settings, args|
		match ForcePrepared.build(spec, settings) {
			Ok(prepared) => Ok(prepared.run(args))
			Err(problems) => Err(problems)
		}
}

## The seeded, multilevel, Barnes-Hut force-directed placement behind
## `Graph.Force`. `ForcePrepared` is the algorithm's witness — `build` is
## the only fallible boundary, and a successfully built value proves that
## `place` and `run` are total. This face re-exports the witness surface
## under the module's name for the wiring layer.
ForceLayout := [].{

	force_defaults : ForcePrepared.Settings
	force_defaults = ForcePrepared.defaults

	force_default_run : ForcePrepared.RunArgs
	force_default_run = ForcePrepared.default_run

	## Check the spec and settings jointly and cache the reusable reading.
	prepare_force : ForcePrepared.Spec, ForcePrepared.Settings -> [Ok(ForcePrepared), Err(List(ForcePrepared.Problem))]
	prepare_force = |spec, settings| ForcePrepared.build(spec, settings)

	## Placement only — final packed center positions, no routes.
	place_force : ForcePrepared, ForcePrepared.RunArgs -> { positions : List({ x : F64, y : F64 }), components : List(U64), convergence : { iterations : U64, converged : Bool } }
	place_force = |prepared, args| ForcePrepared.place(prepared, args)

	## Placement plus shared routing and normalization.
	run_force : ForcePrepared, ForcePrepared.RunArgs -> ForcePrepared.Result
	run_force = |prepared, args| ForcePrepared.run(prepared, args)

	## Check and lay out in one call: exactly `build` followed by `run`.
	layout_force : ForcePrepared.Spec, ForcePrepared.Settings, ForcePrepared.RunArgs -> [Ok(ForcePrepared.Result), Err(List(ForcePrepared.Problem))]
	layout_force = |spec, settings, args| ForcePrepared.layout(spec, settings, args)
}

## The empty graph has a defined force layout: no positions, no routes,
## zero-size bounds at the origin, an empty component list, and a trivially
## converged zero-iteration record.
expect ForcePrepared.layout({ nodes: [], edges: [] }, ForcePrepared.defaults, ForcePrepared.default_run) == Ok({
	layout: { positions: [], bounds: Geom.empty_bounds, routes: [] },
	components: [],
	convergence: { iterations: 0, converged: True },
})

## A single node normalizes to its half-size center, and the convergence
## record is populated: at least one iteration ran and it converged.
expect {
	spec = { nodes: [{ width: 10, height: 6 }], edges: [] }
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			p = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			(p.x - 5).abs() < 1e-9
				and (p.y - 3).abs() < 1e-9
					and result.convergence.iterations >= 1
						and result.convergence.converged
							and result.components == [0]
		}
	}
}

## Two connected nodes settle near their ideal length: within 30% after the
## default iteration budget.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	ideal = Geom.hypot(10, 10) + 24
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			a = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			b = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			distance = Geom.hypot(b.x - a.x, b.y - a.y)
			(distance - ideal).abs() < 0.3 * ideal
				and result.convergence.iterations >= 1
		}
	}
}

## A triangle's pairwise distances stay within a factor of 2 of the ideal
## edge length — a sanity bound on shape, not a precision claim.
expect {
	spec = {
		nodes: List.repeat({ width: 10, height: 10 }, 3),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }],
	}
	ideal = Geom.hypot(10, 10) + 24
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) =>
			[(0, 1), (1, 2), (2, 0)].all(
				|pair| {
					(i, j) = pair
					a = result.layout.positions.get(i) ?? { x: 0, y: 0 }
					b = result.layout.positions.get(j) ?? { x: 0, y: 0 }
					distance = Geom.hypot(b.x - a.x, b.y - a.y)
					distance > ideal / 2 and distance < ideal * 2
				},
			)
		}
}

## Two disconnected triangles form two components, packed without any
## pairwise node-box overlap across the whole drawing.
expect {
	spec = {
		nodes: List.repeat({ width: 10, height: 10 }, 6),
		edges: [
			{ from: 0, to: 1 },
			{ from: 1, to: 2 },
			{ from: 2, to: 0 },
			{ from: 3, to: 4 },
			{ from: 4, to: 5 },
			{ from: 5, to: 3 },
		],
	}
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			positions = result.layout.positions
			separated = positions.fold_with_index(
				True,
				|all_ok, a, i|
					all_ok
						and positions.fold_with_index(
							True,
							|pair_ok, b, j|
								pair_ok
									and (i == j
										or (a.x - b.x).abs() * 2 >= 10 + 10
											or (a.y - b.y).abs() * 2 >= 10 + 10),
						),
			)
			result.components == [0, 0, 0, 1, 1, 1] and separated
		}
	}
}

## A pinned node stays exactly at its pin across a full run: excluded from
## every update, never repositioned by packing, and never translated by
## normalization.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	settings = { ..ForcePrepared.defaults, pins: [{ node: 0, x: 100, y: 200 }] }
	match ForcePrepared.layout(spec, settings, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			pinned = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			free = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			pinned == { x: 100, y: 200 }
				and F64.is_finite(free.x)
					and F64.is_finite(free.y)
						and Geom.hypot(free.x - pinned.x, free.y - pinned.y) > 0
		}
	}
}

## Identical spec, settings, and run arguments produce identical results,
## bit for bit.
expect {
	spec = {
		nodes: List.repeat({ width: 12, height: 8 }, 6),
		edges: [
			{ from: 0, to: 1 },
			{ from: 1, to: 2 },
			{ from: 2, to: 0 },
			{ from: 3, to: 4 },
			{ from: 4, to: 5 },
			{ from: 5, to: 3 },
		],
	}
	ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run)
		== ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run)
}

## Different seeds produce different positions: distinct, equally valid
## equilibria.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	first = ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run)
	second = ForcePrepared.layout(spec, ForcePrepared.defaults, { seed: 1, hints: [] })
	match (first, second) {
		(Ok(a), Ok(b)) => a.layout.positions != b.layout.positions
		_ => False
	}
}

## Hinting a run with a previous run's positions refines it in place: the
## drawing stays near the hint and settles quickly.
expect {
	spec = {
		nodes: List.repeat({ width: 10, height: 10 }, 3),
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 0 }],
	}
	k = Geom.hypot(10, 10) + 24
	match ForcePrepared.build(spec, ForcePrepared.defaults) {
		Err(_) => False
		Ok(prepared) => {
			first = prepared.run(ForcePrepared.default_run)
			second = prepared.run({ seed: 0, hints: first.layout.positions })
			moved = first.layout.positions.fold_with_index(
				0.0,
				|acc, p, i| {
					q = second.layout.positions.get(i) ?? { x: 0, y: 0 }
					acc.max(Geom.hypot(q.x - p.x, q.y - p.y))
				},
			)
			moved < 0.25 * k
				and second.convergence.converged
					and second.convergence.iterations <= 50
		}
	}
}

## `build` reports every independent problem in one result, across nodes,
## edges, each settings field, and pins — a pin can be both missing and
## invalid.
expect {
	spec = {
		nodes: [{ width: 0 - 1.0, height: 5 }],
		edges: [{ from: 0, to: 3 }],
	}
	settings = {
		node_gap: 0 - 1.0,
		repulsion: 0.0,
		gravity: 0 - 1.0,
		opening_angle: F64.infinity,
		max_iterations: 300,
		tolerance: 0.0,
		pins: [{ node: 9, x: 0, y: 0 }, { node: 0, x: F64.infinity, y: 0 }],
	}
	ForcePrepared.build(spec, settings) == Err([
		InvalidNodeWidth(0),
		MissingEdgeEnd(0, 3),
		InvalidNodeGap,
		InvalidRepulsion,
		InvalidGravity,
		InvalidOpeningAngle,
		InvalidTolerance,
		MissingPin(0),
		InvalidPin(1),
	])
}

## The one-shot layout is exactly build followed by run.
expect {
	spec = {
		nodes: [{ width: 8, height: 4 }, { width: 8, height: 4 }],
		edges: [{ from: 0, to: 1 }],
	}
	match ForcePrepared.build(spec, ForcePrepared.defaults) {
		Err(_) => False
		Ok(prepared) =>
			ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run)
				== Ok(prepared.run(ForcePrepared.default_run))
		}
}

## A twelve-node cycle exercises the multilevel path (coarsening, seeded
## coarsest placement, prolongation): every position is finite and every
## edge settles within a factor of 3 of its ideal length.
expect {
	nodes = List.repeat({ width: 10, height: 10 }, 12)
	edges = List.repeat(0, 12).map_with_index(|_, i| { from: i, to: (i + 1) % 12 })
	ideal = Geom.hypot(10, 10) + 24
	match ForcePrepared.layout({ nodes, edges }, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			finite = result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
			lengths_ok = edges.all(
				|edge| {
					a = result.layout.positions.get(edge.from) ?? { x: 0, y: 0 }
					b = result.layout.positions.get(edge.to) ?? { x: 0, y: 0 }
					distance = Geom.hypot(b.x - a.x, b.y - a.y)
					distance > ideal / 3 and distance < ideal * 3
				},
			)
			finite and lengths_ok
		}
	}
}

## Self-loops and parallel edges route safely: the loop is a finite closed
## teardrop and the parallel pair fans into distinct curves.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 0 }, { from: 0, to: 1 }, { from: 1, to: 0 }],
	}
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) =>
			match (result.layout.routes.get(0), result.layout.routes.get(1), result.layout.routes.get(2)) {
				(Ok(Curves(loop_segments)), Ok(Curves(a)), Ok(Curves(b))) => {
					finite_loop = loop_segments.all(
						|seg| [seg.from, seg.ctl_a, seg.ctl_b, seg.to].all(
							|p| F64.is_finite(p.x) and F64.is_finite(p.y),
						),
					)
					finite_loop and a != b
				}

				_ => False
			}
		}
}

## `place` returns packed centers without routing, holds pins exactly, and
## agrees with `run` on positions when no pins force an anchored drawing.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	settings = { ..ForcePrepared.defaults, pins: [{ node: 0, x: 50, y: 60 }] }
	match ForcePrepared.build(spec, settings) {
		Err(_) => False
		Ok(prepared) => {
			placed = prepared.place(ForcePrepared.default_run)
			ran = prepared.run(ForcePrepared.default_run)
			(placed.positions.get(0) ?? { x: 0, y: 0 }) == { x: 50, y: 60 }
				and placed.positions == ran.layout.positions
					and placed.convergence == ran.convergence
		}
	}
}

## The pair equilibrium is seed-independent: across several seeds, two
## connected nodes always settle within 30% of their ideal length, and the
## run always converges.
expect {
	spec = {
		nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
		edges: [{ from: 0, to: 1 }],
	}
	ideal = Geom.hypot(10, 10) + 24
	[0, 1, 2, 3, 4].all(
		|seed|
			match ForcePrepared.layout(spec, ForcePrepared.defaults, { seed, hints: [] }) {
				Err(_) => False
				Ok(result) => {
					a = result.layout.positions.get(0) ?? { x: 0, y: 0 }
					b = result.layout.positions.get(1) ?? { x: 0, y: 0 }
					distance = Geom.hypot(b.x - a.x, b.y - a.y)
					(distance - ideal).abs() < 0.3 * ideal and result.convergence.converged
				}
			},
	)
}

## Isolated nodes each form their own component and pack apart: two point
## components sit at distinct positions.
expect {
	spec = { nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }], edges: [] }
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) => {
			a = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			b = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			result.components == [0, 1]
				and ((a.x - b.x).abs() * 2 >= 20 or (a.y - b.y).abs() * 2 >= 20)
		}
	}
}

## `run` removes residual box overlaps before routing: even a zero-iteration
## placement (raw packed scatter) comes back with no two node boxes
## strictly overlapping.
expect {
	spec = {
		nodes: List.repeat({ width: 40, height: 40 }, 6),
		edges: [
			{ from: 0, to: 1 },
			{ from: 0, to: 2 },
			{ from: 0, to: 3 },
			{ from: 0, to: 4 },
			{ from: 0, to: 5 },
		],
	}
	settings = { ..ForcePrepared.defaults, max_iterations: 0 }
	match ForcePrepared.build(spec, settings) {
		Err(_) => False
		Ok(prepared) => {
			result = prepared.run(ForcePrepared.default_run)
			positions = result.layout.positions
			sizes = spec.nodes
			no_overlap = positions.fold_with_index(
				True,
				|acc, p, i|
					positions.fold_with_index(
						acc,
						|inner, q, j|
							if j <= i {
								inner
							} else {
								a = sizes.get(i) ?? { width: 0, height: 0 }
								b = sizes.get(j) ?? { width: 0, height: 0 }
								dx = (p.x - q.x).abs()
								dy = (p.y - q.y).abs()
								overlap_x = dx + 1e-9 < (a.width + b.width) / 2
								overlap_y = dy + 1e-9 < (a.height + b.height) / 2
								inner and !(overlap_x and overlap_y)
							},
					),
			)
			no_overlap
		}
	}
}

## Near-maximum finite sizes still produce fully finite geometry: the
## diagonal, ideal lengths, and scatter scale all saturate instead of
## overflowing.
expect {
	spec = {
		nodes: [{ width: 1.7e308, height: 1.7e308 }, { width: 1.7e308, height: 1.7e308 }],
		edges: [{ from: 0, to: 1 }],
	}
	match ForcePrepared.layout(spec, ForcePrepared.defaults, ForcePrepared.default_run) {
		Err(_) => False
		Ok(result) =>
			result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
				and F64.is_finite(result.layout.bounds.width)
					and F64.is_finite(result.layout.bounds.height)
		}
}
