import Geom
import Paths
import Rand
import Solver
import EdgeRoutes

## Pure helpers behind `Constrained`: joint validation over the graph, the
## settings, and the constraint list; the scaled all-pairs distance table the
## witness carries; and the alternating solve — one stress-majorization step,
## then projection of the drawing onto the rules, every iteration.
ConstrainedInternals :: {}.{

	## Per-node pin slot: a pinned node keeps its pin through every phase.
	PinSlot : [Pin({ x : F64, y : F64 }), Free]

	## The rule structures projection consumes every iteration, assembled at
	## build time from the same per-axis analysis the feasibility check runs,
	## so the solve never re-reads the constraint list.
	Rules : {
		pin_at : List(ConstrainedInternals.PinSlot),
		axis_x : ConstrainedInternals.AxisRules,
		axis_y : ConstrainedInternals.AxisRules,
	}

	## One axis's unified projection data, over alignment-merged variables so
	## every rule kind is satisfied by one minimal-movement projection.
	## `root_of` maps each node to its merged variable (itself when
	## unaligned); `member_count` holds each variable's member count at its
	## root index (zero elsewhere); `intervals` holds each variable's
	## band-and-pin interval at its root index (open elsewhere); and
	## `constraints` are the axis's separations over merged variables
	## followed by each variable's interval bounds, encoded as edges through
	## one extra anchor variable at index `node_count`. The anchor is held at
	## coordinate 0 with weight 1e18 — effectively immovable against member
	## weights, so interval bounds hold to double precision — and
	## `project_axis` re-appends it every call.
	AxisRules : {
		root_of : List(U64),
		member_count : List(F64),
		intervals : List({ lo : F64, hi : F64 }),
		constraints : List({ left : U64, right : U64, gap : F64 }),
	}

	## What one axis's rule analysis produces: the union-find parents of the
	## alignment merge, the merged separations (constraint order, intra-group
	## entries dropped after the fused check), each merged variable's
	## band-and-pin interval, and every rule conflict the analysis can prove.
	## `build` rejects input whose `problems` is non-empty and assembles the
	## run-time projection from the rest via `axis_rules_of`, so build and
	## run share one analysis and the run projects onto exactly the intervals
	## and separations the feasibility check proved consistent.
	AxisAnalysis : {
		parents : List(U64),
		separations : List({ index : U64, left : U64, right : U64, gap : F64 }),
		intervals : List({ lo : F64, hi : F64 }),
		problems : List(Constrained.Problem),
	}

	validation_problems : Constrained.Input, Constrained.Settings -> List(Constrained.Problem)
	validation_problems = |input, settings| {
		node_count = input.graph.nodes.len()

		node_problems = input.graph.nodes.fold_with_index(
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

		edge_problems = input.graph.edges.fold_with_index(
			node_problems,
			|problems, edge, index| {
				from_problems = if edge.from >= node_count {
					problems.append(MissingEdgeStart(index, edge.from))
				} else {
					problems
				}

				if edge.to >= node_count {
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

		tolerance_problems = if F64.is_finite(settings.tolerance) and settings.tolerance > 0 {
			gap_problems
		} else {
			gap_problems.append(InvalidTolerance)
		}

		# Both pin problems carry the pin's index in the pins list, and one
		# pin can raise both independently.
		pin_problems = settings.pins.fold_with_index(
			tolerance_problems,
			|problems, pin, index| {
				reference_problems = if pin.node >= node_count {
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

		# Constraint problems carry the constraint's index in the constraints
		# list; one constraint can raise several independently.
		input.constraints.fold_with_index(
			pin_problems,
			|problems, constraint, index|
				match constraint {
					Separate(rule) => {
						first_problems = if rule.first >= node_count {
							problems.append(MissingConstraintNode(index, rule.first))
						} else {
							problems
						}
						second_problems = if rule.second >= node_count {
							first_problems.append(MissingConstraintNode(index, rule.second))
						} else {
							first_problems
						}

						if F64.is_finite(rule.gap) {
							second_problems
						} else {
							second_problems.append(InvalidConstraintGap(index))
						}
					}

					Align(rule) =>
						rule.nodes.fold(
							problems,
							|acc, node|
								if node >= node_count {
									acc.append(MissingConstraintNode(index, node))
								} else {
									acc
								},
						)

					Inside(rule) => {
						member_problems = rule.nodes.fold(
							problems,
							|acc, node|
								if node >= node_count {
									acc.append(MissingConstraintNode(index, node))
								} else {
									acc
								},
						)

						if F64.is_finite(rule.low) and F64.is_finite(rule.high) and rule.low <= rule.high {
							member_problems
						} else {
							member_problems.append(InvalidConstraintBand(index))
						}
					}
				},
		)
	}

	## True when two axis tags name the same axis.
	same_axis : [X, Y], [X, Y] -> Bool
	same_axis = |a, b|
		match (a, b) {
			(X, X) => True
			(Y, Y) => True
			_ => False
		}

	## The root of `index`'s union-find tree. The fuel is the variable
	## count — no parent chain is longer — so the walk always terminates.
	find_root : List(U64), U64, U64 -> U64
	find_root = |parents, index, fuel| {
		parent = parents.get(index) ?? index
		if parent == index or fuel == 0 {
			index
		} else {
			ConstrainedInternals.find_root(parents, parent, fuel - 1)
		}
	}

	## Union by root relabeling: the second argument's root hangs under the
	## first argument's root.
	union_roots : List(U64), U64, U64 -> List(U64)
	union_roots = |parents, a, b| {
		fuel = parents.len()
		root_a = ConstrainedInternals.find_root(parents, a, fuel)
		root_b = ConstrainedInternals.find_root(parents, b, fuel)
		if root_a == root_b {
			parents
		} else {
			parents.set(root_b, root_a) ?? parents
		}
	}

	## Union-find parents after merging every Align group on one axis:
	## aligned nodes must share one coordinate there, so the feasibility
	## analysis treats each group as a single merged variable.
	align_parents : List(Constrained.Constraint), U64, [X, Y] -> List(U64)
	align_parents = |constraints, node_count, axis|
		constraints.fold(
			Paths.indices_up_to(node_count),
			|parents, constraint|
				match constraint {
					Align(rule) =>
						if ConstrainedInternals.same_axis(rule.axis, axis) {
							match rule.nodes.get(0) {
								Ok(first) => rule.nodes.fold(parents, |acc, member| ConstrainedInternals.union_roots(acc, first, member))
								Err(_) => parents
							}
						} else {
							parents
						}

					Separate(_) => parents
					Inside(_) => parents
				},
		)

	## The axis's separations with both endpoints replaced by their merged
	## variables, each carrying its constraint index for problem reports.
	merged_separations : List(Constrained.Constraint), List(U64), [X, Y] -> List({ index : U64, left : U64, right : U64, gap : F64 })
	merged_separations = |constraints, parents, axis| {
		fuel = parents.len()
		constraints.fold_with_index(
			[],
			|acc, constraint, index|
				match constraint {
					Separate(rule) =>
						if ConstrainedInternals.same_axis(rule.axis, axis) {
							acc.append({
								index,
								left: ConstrainedInternals.find_root(parents, rule.first, fuel),
								right: ConstrainedInternals.find_root(parents, rule.second, fuel),
								gap: rule.gap,
							})
						} else {
							acc
						}

					Align(_) => acc
					Inside(_) => acc
				},
		)
	}

	## Separations whose endpoints alignment fused into one merged variable:
	## a positive gap between a variable and itself is unsatisfiable.
	fused_separation_problems : List({ index : U64, left : U64, right : U64, gap : F64 }) -> List(Constrained.Problem)
	fused_separation_problems = |separations|
		separations.fold(
			[],
			|acc, sep|
				if sep.left == sep.right and sep.gap > 0 {
					acc.append(UnsatisfiableSeparation(sep.index))
				} else {
					acc
				},
		)

	## One longest-path relaxation pass over the merged separation digraph,
	## reporting the last relaxation that fired.
	relaxation_pass : List(F64), List({ index : U64, left : U64, right : U64, gap : F64 }) -> { dist : List(F64), fired : [NoFire, Fired(U64)] }
	relaxation_pass = |dist, separations|
		separations.fold(
			{ dist, fired: NoFire },
			|acc, sep| {
				candidate = (acc.dist.get(sep.left) ?? 0) + sep.gap
				if candidate > (acc.dist.get(sep.right) ?? 0) {
					{ dist: acc.dist.set(sep.right, candidate) ?? acc.dist, fired: Fired(sep.index) }
				} else {
					acc
				}
			},
		)

	## Positive-cycle detection over the merged separation digraph. The
	## difference constraints `x_right - x_left >= gap` admit positions iff
	## no cycle has positive total gap, and Bellman-Ford longest-path
	## relaxation from an all-zero start settles within variable-count
	## passes when no such cycle exists — so a relaxation that still fires
	## in the extra pass proves one. The reported index is the constraint
	## whose relaxation fired last in that extra pass: always an edge of an
	## unsatisfiable cycle, and a deterministic choice.
	positive_cycle_problems : List({ index : U64, left : U64, right : U64, gap : F64 }), U64 -> List(Constrained.Problem)
	positive_cycle_problems = |edges, variable_count| {
		settled = Paths.indices_up_to(variable_count).fold(
			List.repeat(0.0, variable_count),
			|dist, _round| ConstrainedInternals.relaxation_pass(dist, edges).dist,
		)
		match ConstrainedInternals.relaxation_pass(settled, edges).fired {
			Fired(index) => [UnsatisfiableSeparation(index)]
			NoFire => []
		}
	}

	## Each merged variable's feasible interval on one axis, with the
	## problem for whatever emptied an intersection. Bands intersect first:
	## `ConflictingInside` names the band whose intersection emptied. Pins
	## then intersect as one-point intervals: `ConflictingPin` names the pin
	## that lies outside its variable's interval or disagrees with an
	## earlier pin in the same merged variable. A node pinned more than once
	## keeps only its last pin — the documented pin semantics — so
	## overridden pins do not participate.
	rule_intervals : List(Constrained.Constraint), List({ node : U64, x : F64, y : F64 }), List(U64), [X, Y] -> { intervals : List({ lo : F64, hi : F64 }), problems : List(Constrained.Problem) }
	rule_intervals = |constraints, pins, parents, axis| {
		fuel = parents.len()
		open = { lo: 0.0 - F64.infinity, hi: F64.infinity }

		banded = constraints.fold_with_index(
			{ intervals: List.repeat(open, fuel), problems: [] },
			|acc, constraint, index|
				match constraint {
					Inside(rule) =>
						if ConstrainedInternals.same_axis(rule.axis, axis) {
							rule.nodes.fold(
								acc,
								|inner, member| {
									root = ConstrainedInternals.find_root(parents, member, fuel)
									current = inner.intervals.get(root) ?? open
									next = { lo: current.lo.max(rule.low), hi: current.hi.min(rule.high) }
									problems = if current.lo <= current.hi and next.lo > next.hi {
										inner.problems.append(ConflictingInside(index))
									} else {
										inner.problems
									}
									{ intervals: inner.intervals.set(root, next) ?? inner.intervals, problems }
								},
							)
						} else {
							acc
						}

					Separate(_) => acc
					Align(_) => acc
				},
		)

		last_pin = pins.fold_with_index(
			List.repeat(NoPin, fuel),
			|acc, pin, index| acc.set(pin.node, LastPin(index)) ?? acc,
		)

		pins.fold_with_index(
			banded,
			|acc, pin, index| {
				effective = match last_pin.get(pin.node) ?? NoPin {
					LastPin(winner) => winner == index
					NoPin => False
				}
				if effective == False {
					acc
				} else {
					coordinate = match axis {
						X => pin.x
						Y => pin.y
					}
					root = ConstrainedInternals.find_root(parents, pin.node, fuel)
					current = acc.intervals.get(root) ?? open
					next = { lo: current.lo.max(coordinate), hi: current.hi.min(coordinate) }
					problems = if current.lo <= current.hi and next.lo > next.hi {
						acc.problems.append(ConflictingPin(index))
					} else {
						acc.problems
					}
					{ intervals: acc.intervals.set(root, next) ?? acc.intervals, problems }
				}
			},
		)
	}

	## One interval-tightening pass: each separation raises its right
	## variable's lower bound to at least the left's plus the gap, and
	## lowers its left variable's upper bound to at most the right's minus
	## the gap. An interval that empties names the separation that emptied
	## it, and the pass stops there.
	tightening_pass : List({ lo : F64, hi : F64 }), List({ index : U64, left : U64, right : U64, gap : F64 }) -> { intervals : List({ lo : F64, hi : F64 }), changed : Bool, emptied : [NotEmptied, Emptied(U64)] }
	tightening_pass = |intervals, separations|
		separations.fold(
			{ intervals, changed: False, emptied: NotEmptied },
			|acc, sep|
				match acc.emptied {
					Emptied(_) => acc
					NotEmptied => {
						open = { lo: 0.0 - F64.infinity, hi: F64.infinity }
						left = acc.intervals.get(sep.left) ?? open
						right = acc.intervals.get(sep.right) ?? open
						new_right_lo = right.lo.max(left.lo + sep.gap)
						new_left_hi = left.hi.min(right.hi - sep.gap)
						changed = acc.changed or new_right_lo > right.lo or new_left_hi < left.hi
						with_right = acc.intervals.set(sep.right, { ..right, lo: new_right_lo }) ?? acc.intervals
						with_left = with_right.set(sep.left, { lo: left.lo, hi: new_left_hi }) ?? with_right
						emptied = if new_right_lo > right.hi or left.lo > new_left_hi {
							Emptied(sep.index)
						} else {
							NotEmptied
						}
						{ intervals: with_left, changed, emptied }
					}
				},
		)

	## Bounded propagation of separations against the band-and-pin
	## intervals: tightening passes until nothing changes or the round
	## budget — the variable count — runs out. Sound but not complete: any
	## interval this empties proves the named separation unsatisfiable, but
	## a conflict needing deeper propagation than the budget allows is not
	## found here and surfaces in the result's `unsatisfied` list instead.
	tightened_problems : List({ lo : F64, hi : F64 }), List({ index : U64, left : U64, right : U64, gap : F64 }), U64 -> List(Constrained.Problem)
	tightened_problems = |intervals, separations, rounds_left| {
		pass = ConstrainedInternals.tightening_pass(intervals, separations)
		match pass.emptied {
			Emptied(index) => [UnsatisfiableSeparation(index)]
			NotEmptied =>
				if pass.changed and rounds_left > 0 {
					ConstrainedInternals.tightened_problems(pass.intervals, separations, rounds_left - 1)
				} else {
					[]
				}
			}
	}

	## One axis's full rule analysis, shared by build and run. Its `problems`
	## are every conflict the analysis can prove, in a fixed order:
	## separations fused by alignment, positive separation cycles, emptied
	## band-and-pin intervals, then separations propagated against those
	## intervals (the propagation runs only when the earlier steps found
	## nothing, so its reports are not noise from an already-reported
	## conflict). The analysis is sound — every reported conflict is real, up
	## to F64 rounding at extreme magnitudes — but not complete; whatever it
	## cannot prove is reported per run in the result's `unsatisfied` list.
	## Runs only on input whose references and values already validated.
	axis_analysis : List(Constrained.Constraint), List({ node : U64, x : F64, y : F64 }), U64, [X, Y] -> ConstrainedInternals.AxisAnalysis
	axis_analysis = |constraints, pins, node_count, axis| {
		parents = ConstrainedInternals.align_parents(constraints, node_count, axis)
		separations = ConstrainedInternals.merged_separations(constraints, parents, axis)
		edges = separations.fold(
			[],
			|acc, sep|
				if sep.left == sep.right {
					acc
				} else {
					acc.append(sep)
				},
		)

		fused = ConstrainedInternals.fused_separation_problems(separations)
		cycles = ConstrainedInternals.positive_cycle_problems(edges, node_count)
		ruled = ConstrainedInternals.rule_intervals(constraints, pins, parents, axis)

		direct = fused.concat(cycles).concat(ruled.problems)
		problems = if direct.is_empty() {
			ConstrainedInternals.tightened_problems(ruled.intervals, edges, node_count)
		} else {
			direct
		}
		{ parents, separations: edges, intervals: ruled.intervals, problems }
	}

	## The run-time projection data for one axis, from the axis's analysis:
	## resolved roots and member counts of the alignment merge, then the
	## unified constraint list — the merged separations in constraint order
	## (intra-group ones already dropped: the analysis rejected positive
	## intra-group gaps, and non-positive ones are vacuous), followed by
	## anchor edges in variable-index order, a finite lower bound `lo` as
	## `anchor -> variable, gap: lo` and a finite upper bound `hi` as
	## `variable -> anchor, gap: 0 - hi`. The solver enforces
	## `position[right] - position[left] >= gap` and the anchor sits at 0,
	## so those edges read `variable >= lo` and `variable <= hi`. The
	## two-cycles they form through the anchor are feasible whenever
	## `lo <= hi` — which the analysis guaranteed — and the block-merge
	## solver handles them: a violated bound merges the variable into the
	## anchor block at exactly its bound.
	axis_rules_of : ConstrainedInternals.AxisAnalysis, U64 -> ConstrainedInternals.AxisRules
	axis_rules_of = |analysis, node_count| {
		root_of = Paths.indices_up_to(node_count).map(|i| ConstrainedInternals.find_root(analysis.parents, i, node_count))
		member_count = root_of.fold(
			List.repeat(0.0, node_count),
			|acc, root| acc.set(root, (acc.get(root) ?? 0) + 1) ?? acc,
		)
		separations = analysis.separations.map(|sep| { left: sep.left, right: sep.right, gap: sep.gap })
		anchor = node_count
		constraints = analysis.intervals.fold_with_index(
			separations,
			|acc, interval, i| {
				with_lo = if F64.is_finite(interval.lo) {
					acc.append({ left: anchor, right: i, gap: interval.lo })
				} else {
					acc
				}
				if F64.is_finite(interval.hi) {
					with_lo.append({ left: i, right: anchor, gap: 0.0 - interval.hi })
				} else {
					with_lo
				}
			},
		)
		{ root_of, member_count, intervals: analysis.intervals, constraints }
	}

	## One node's coordinate on one axis.
	axis_coordinate : List({ x : F64, y : F64 }), U64, [X, Y] -> F64
	axis_coordinate = |positions, node, axis| {
		p = positions.get(node) ?? { x: 0, y: 0 }
		match axis {
			X => p.x
			Y => p.y
		}
	}

	## The indices of constraints the finished drawing violates beyond a
	## 1e-9 tolerance, checked directly against the returned positions: a
	## separation's gap shortfall, an alignment's coordinate spread, or a
	## coordinate escaping its band. Empty when the drawing satisfies every
	## rule.
	unsatisfied_of : List(Constrained.Constraint), List({ x : F64, y : F64 }) -> List(U64)
	unsatisfied_of = |constraints, positions|
		constraints.fold_with_index(
			[],
			|acc, constraint, index|
				match constraint {
					Separate(rule) => {
						first = ConstrainedInternals.axis_coordinate(positions, rule.first, rule.axis)
						second = ConstrainedInternals.axis_coordinate(positions, rule.second, rule.axis)
						if second - first >= rule.gap - 1e-9 {
							acc
						} else {
							acc.append(index)
						}
					}

					Align(rule) => {
						spread = rule.nodes.fold(
							{ started: False, low: 0.0, high: 0.0 },
							|state, member| {
								v = ConstrainedInternals.axis_coordinate(positions, member, rule.axis)
								if state.started {
									{ started: True, low: state.low.min(v), high: state.high.max(v) }
								} else {
									{ started: True, low: v, high: v }
								}
							},
						)
						if spread.started and spread.high - spread.low > 1e-9 {
							acc.append(index)
						} else {
							acc
						}
					}

					Inside(rule) => {
						escaped = rule.nodes.fold(
							False,
							|state, member| {
								v = ConstrainedInternals.axis_coordinate(positions, member, rule.axis)
								state or v < rule.low - 1e-9 or v > rule.high + 1e-9
							},
						)
						if escaped {
							acc.append(index)
						} else {
							acc
						}
					}
				},
		)

	## The per-hop unit distance: the mean over edges of the endpoint
	## diagonals' average, plus the gap — or the gap alone for an edgeless
	## graph, which has no pairs at graph distance anyway. The mean is an
	## incremental running mean over halved diagonals, so near-maximum node
	## sizes or arbitrarily long edge lists cannot overflow an accumulator;
	## if adding the gap still overflows, the unit saturates at
	## `F64.highest` — finite accepted input must produce finite derived
	## geometry.
	unit_length_of : List({ width : F64, height : F64 }), List({ from : U64, to : U64 }), F64 -> F64
	unit_length_of = |nodes, edges, node_gap| {
		if edges.is_empty() {
			node_gap
		} else {
			folded = edges.fold(
				{ mean: 0.0, count: 0.0 },
				|acc, edge| {
					a = EdgeRoutes.diagonal(nodes.get(edge.from) ?? { width: 0, height: 0 })
					b = EdgeRoutes.diagonal(nodes.get(edge.to) ?? { width: 0, height: 0 })
					half_sum = a / 2 + b / 2
					count = acc.count + 1
					{ mean: acc.mean + (half_sum - acc.mean) / count, count }
				},
			)
			unit = folded.mean + node_gap
			if F64.is_finite(unit) {
				unit
			} else {
				# The running mean of finite halved diagonals stays finite,
				# so only the gap addition can overflow; saturate rather
				# than let an infinity into the derived geometry.
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

	## The flat row-major all-pairs table, in O(n * (n + m)): entry
	## `i * n + j` is the scaled hop distance from `i` to `j`, `0` on the
	## diagonal, `F64.infinity` between components.
	all_pairs_distances : Paths.Adjacency, F64 -> List(F64)
	all_pairs_distances = |adj, unit| {
		n = Paths.node_count_of(adj)
		Paths.indices_up_to(n).fold(
			[],
			|acc, source| acc.concat(ConstrainedInternals.scale_row(Paths.bfs_distances(adj, source), unit)),
		)
	}

	# The majorization core below (fallback_dir, pulled_target, update_step,
	# stress_of, stress_terms_of) intentionally mirrors `StressInternals` in
	# StressLayout.roc, restricted to the exact all-pairs table; consolidate
	# the two into one shared internal module once the layering settles.

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
			ConstrainedInternals.fallback_dir(i, j)
		}
		{ x: other.x + ideal * dir.x, y: other.y + ideal * dir.y }
	}

	## One majorization step with the simultaneous update: every new
	## position is a weighted (`1 / d^2`) average of pulled targets computed
	## from the old positions only, then all are applied at once, so the
	## result is independent of node order. Pairs without a finite positive
	## distance are skipped; a node with no participating pair (or a
	## non-finite candidate from extreme magnitudes) keeps its old position;
	## pinned nodes keep their pin.
	update_step : List({ x : F64, y : F64 }), List(F64), List(ConstrainedInternals.PinSlot) -> List({ x : F64, y : F64 })
	update_step = |positions, flat, pin_at| {
		n = positions.len()
		all = Paths.indices_up_to(n)
		positions.map_with_index(
			|at, i|
				match pin_at.get(i) ?? Free {
					Pin(pin) => pin
					Free => {
						sums = all.fold(
							{ x: 0.0, y: 0.0, weight: 0.0 },
							|acc, j| {
								d = flat.get(i * n + j) ?? F64.infinity
								if j == i or !F64.is_finite(d) or d <= 0 {
									acc
								} else {
									w = 1.0 / (d * d)
									other = positions.get(j) ?? at
									t = ConstrainedInternals.pulled_target(at, other, d, i, j)
									{ x: acc.x + w * t.x, y: acc.y + w * t.y, weight: acc.weight + w }
								}
							},
						)

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
	## unordered pairs with finite positive distance.
	stress_of : List({ x : F64, y : F64 }), List(F64) -> F64
	stress_of = |positions, flat| {
		n = positions.len()
		all = Paths.indices_up_to(n)
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
	}

	## How many pair terms the stress sums — the scale that turns the stress
	## into a mean squared relative pair error. Never below one, so the
	## floor test in `descend` stays meaningful on degenerate inputs.
	stress_terms_of : List(F64), U64 -> F64
	stress_terms_of = |flat, node_count| {
		all = Paths.indices_up_to(node_count)

		zero : F64
		zero = 0.0

		total = all.fold(
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
		total.max(1)
	}

	## Seeded initial scatter: two unit doubles per node in index order,
	## scaled by the unit length times the square root of the node count, so
	## the drawing starts spread near its final scale. Disconnected
	## components are not split apart afterwards — constraints may span them
	## — so their relative placement comes from this scatter (or the run's
	## hints) and whatever the rules impose.
	scatter : U64, U32, F64 -> List({ x : F64, y : F64 })
	scatter = |node_count, seed, unit| {
		raw_scale = unit * node_count.to_f64().sqrt()
		# A saturated unit times the node-count factor can overflow even
		# though the unit itself is finite; keep the scatter finite too.
		scale = if F64.is_finite(raw_scale) {
			raw_scale
		} else {
			F64.highest
		}
		Paths.indices_up_to(node_count).fold(
			{ state: Rand.seed(seed), points: [] },
			|acc, _i| {
				sx = Rand.step_unit_f64(acc.state)
				sy = Rand.step_unit_f64(sx.state)
				{
					state: sy.state,
					points: acc.points.append({ x: sx.value * scale, y: sy.value * scale }),
				}
			},
		).points
	}

	## Project one axis of the drawing onto all of its rules at once, through
	## a single minimal-movement solve over the alignment-merged variables.
	##
	## Each merged variable's desired position is the mean of its members'
	## current coordinates, projected into the variable's own band-and-pin
	## interval, and its weight is its member count — so an alignment group
	## moves as one point with the mass of its members, and a variable
	## nothing constrains passes through bit-exactly. The appended anchor
	## variable (coordinate 0, weight 1e18) turns the interval bounds into
	## ordinary separations, so separations, alignments, bands, and pin
	## coordinates are satisfied simultaneously — no later step can disturb
	## an earlier one, which a sequential projection would allow. Every
	## member then takes its variable's projected coordinate, so aligned
	## nodes share it bit-exactly.
	##
	## The desired-position clamp and the anchor edges work together, and
	## neither may stand alone. The clamp conditions the objective so every
	## desired point already satisfies its own bounds; without it, a
	## separation violated at the desired point can fuse its endpoints into
	## one rigid block before a member's bound is checked, and the
	## block-merge solver never splits a block to fix an intra-block bound.
	## The anchor edges then enforce the bounds inside the solve itself;
	## without them, a separation could push a variable back out of its band
	## — the exact sequential-projection bug this projection replaces.
	##
	## Pinned coordinates participate as one-point intervals; the caller
	## re-asserts pins exactly afterward, which cannot break another rule
	## because the pin's coordinate was already inside the projection (the
	## anchor holds the variable within ~1e-18 relative error of the pin).
	project_axis : List(F64), ConstrainedInternals.AxisRules -> List(F64)
	project_axis = |coords, axis_rules| {
		node_count = coords.len()
		open = { lo: 0.0 - F64.infinity, hi: F64.infinity }
		sums = coords.fold_with_index(
			List.repeat(0.0, node_count),
			|acc, coord, i| {
				root = axis_rules.root_of.get(i) ?? i
				acc.set(root, (acc.get(root) ?? 0) + coord) ?? acc
			},
		)
		variables = Paths.indices_up_to(node_count).map(
			|i| {
				count = axis_rules.member_count.get(i) ?? 0
				if count > 0 {
					interval = axis_rules.intervals.get(i) ?? open
					mean = (sums.get(i) ?? 0) / count
					{ position: mean.max(interval.lo).min(interval.hi), weight: count }
				} else {
					# A non-root index is referenced by no constraint; this
					# entry only keeps the solver's lists index-aligned.
					{ position: 0.0, weight: 1.0 }
				}
			},
		)
		projected = Solver.project(variables.append({ position: 0.0, weight: 1e18 }), axis_rules.constraints)
		coords.map_with_index(|_coord, i| projected.get(axis_rules.root_of.get(i) ?? i) ?? 0)
	}

	## The full projection: each axis through the unified `project_axis`,
	## then pins re-asserted bit-exactly — the drawing leaving here satisfies
	## every rule simultaneously (to the documented epsilons) whenever the
	## rules are feasible.
	apply_rules : List({ x : F64, y : F64 }), ConstrainedInternals.Rules -> List({ x : F64, y : F64 })
	apply_rules = |positions, rules| {
		xs = ConstrainedInternals.project_axis(positions.map(|p| p.x), rules.axis_x)
		ys = ConstrainedInternals.project_axis(positions.map(|p| p.y), rules.axis_y)
		positions.map_with_index(
			|_p, i|
				match rules.pin_at.get(i) ?? Free {
					Pin(pin) => pin
					Free => { x: xs.get(i) ?? 0, y: ys.get(i) ?? 0 }
				},
		)
	}

	## Bounded alternation: one majorization step, then projection onto the
	## rules, until convergence or until the fuel — the iteration cap — runs
	## out (not converged). Convergence is either stop condition: the
	## relative stress change of a step falls below tolerance (the descent
	## has flattened against the rules), or the stress drops below `floor` —
	## tolerance times the summed pair count, i.e. a mean squared relative
	## pair error below tolerance — which catches exactly-embeddable inputs
	## whose stress decays toward zero with a near-constant relative change
	## that would otherwise stall the first test. Both report converged.
	## `done` counts the alternation steps actually applied, and stress is
	## always measured after projection, so what converged is the feasible
	## drawing itself.
	descend : List({ x : F64, y : F64 }), List(F64), ConstrainedInternals.Rules, F64, F64, F64, U64, U64 -> { positions : List({ x : F64, y : F64 }), iterations : U64, converged : Bool }
	descend = |positions, flat, rules, tolerance, floor, prev_stress, done, fuel|
		if fuel == 0 {
			{ positions, iterations: done, converged: False }
		} else {
			stepped = ConstrainedInternals.update_step(positions, flat, rules.pin_at)
			next = ConstrainedInternals.apply_rules(stepped, rules)
			stress = ConstrainedInternals.stress_of(next, flat)
			relative = (prev_stress - stress).abs() / prev_stress.max(1e-12)
			if stress < floor or relative < tolerance {
				{ positions: next, iterations: done + 1, converged: True }
			} else {
				ConstrainedInternals.descend(next, flat, rules, tolerance, floor, stress, done + 1, fuel - 1)
			}
		}

	## Per-node outward direction for self-loop routing: the unit vector
	## from the drawing's centroid toward the node, pointing up for a node
	## at the centroid itself.
	outward_directions : List({ x : F64, y : F64 }) -> List({ x : F64, y : F64 })
	outward_directions = |positions| {
		count = positions.len().to_f64()
		if count == 0 {
			[]
		} else {
			sum = positions.fold({ x: 0.0, y: 0.0 }, |acc, p| { x: acc.x + p.x, y: acc.y + p.y })
			cx = sum.x / count
			cy = sum.y / count
			positions.map(
				|p| {
					dx = p.x - cx
					dy = p.y - cy
					d = Geom.hypot(dx, dy)
					if d > 0 {
						{ x: dx / d, y: dy / d }
					} else {
						{ x: 0.0, y: 0.0 - 1.0 }
					}
				},
			)
		}
	}
}

## A validated constrained layout: stress optimization — drawn distances
## tracking graph distances — subject to the input's rules, solved by
## alternating one stress-descent step with a projection of the drawing onto
## the feasible region every iteration.
##
## `build` validates the graph, the settings, and every constraint jointly —
## reporting every independent problem and rejecting every rule conflict its
## per-axis feasibility analysis can prove — and precomputes what repeated
## runs reuse: the scaled all-pairs graph-distance table and the per-axis
## rule structures. `run` then only solves: initialization comes from full-length
## finite position hints (index-aligned; a partial or non-finite hint list is
## treated as absent) or a seeded scatter, with pins overriding either, and
## the start is projected onto the rules before the first step, so even a
## zero-iteration run is feasible.
##
## Pins hold exactly: pinned nodes never move, and a drawing with pins — or
## with containment bands, whose `[low, high]` limits are absolute
## coordinates — keeps its absolute coordinates instead of being translated
## to the origin (its bounds record where it actually sits).
##
## Disconnected input is not split into separately packed components,
## because constraints may span components: their relative placement comes
## from the seeded start (or hints) and whatever the rules impose.
ConstrainedPrepared := {
	nodes : List({ width : F64, height : F64 }),
	edges : List({ from : U64, to : U64 }),
	constraints : List(Constrained.Constraint),
	unit_length : F64,
	distances : List(F64),
	stress_terms : F64,
	rules : ConstrainedInternals.Rules,
	anchored : Bool,
	node_gap : F64,
	max_iterations : U64,
	tolerance : F64,
}.{

	## Check the input and settings jointly — reporting every independent
	## problem — then, on validated input, reject every rule conflict the
	## per-axis feasibility analysis can prove, and finally precompute the
	## scaled distance table and the per-axis rule structures the solve
	## reuses across runs.
	build : Constrained.Input, Constrained.Settings -> [Ok(ConstrainedPrepared), Err(List(Constrained.Problem))]
	build = |input, settings| {
		problems = ConstrainedInternals.validation_problems(input, settings)
		if !problems.is_empty() {
			Err(problems)
		} else {
			node_count = input.graph.nodes.len()
			# The per-axis analysis both proves feasibility and carries the
			# structures the run-time projection is assembled from, so build
			# and run agree on exactly one reading of the rules. It runs only
			# on input whose references and values already validated.
			analysis_x = ConstrainedInternals.axis_analysis(input.constraints, settings.pins, node_count, X)
			analysis_y = ConstrainedInternals.axis_analysis(input.constraints, settings.pins, node_count, Y)
			conflicts = analysis_x.problems.concat(analysis_y.problems)
			if !conflicts.is_empty() {
				Err(conflicts)
			} else {
				nodes = input.graph.nodes
				edges = input.graph.edges
				adj = Paths.adjacency(node_count, edges)
				unit = ConstrainedInternals.unit_length_of(nodes, edges, settings.node_gap)
				flat = ConstrainedInternals.all_pairs_distances(adj, unit)

				pin_at = settings.pins.fold(
					List.repeat(Free, node_count),
					|acc, pin| acc.set(pin.node, Pin({ x: pin.x, y: pin.y })) ?? acc,
				)
				rules = {
					pin_at,
					axis_x: ConstrainedInternals.axis_rules_of(analysis_x, node_count),
					axis_y: ConstrainedInternals.axis_rules_of(analysis_y, node_count),
				}
				has_band = input.constraints.fold(
					False,
					|acc, constraint|
						match constraint {
							Inside(_) => True
							Separate(_) => acc
							Align(_) => acc
						},
				)
				anchored = !settings.pins.is_empty() or has_band

				prepared : ConstrainedPrepared
				prepared = {
					nodes,
					edges,
					constraints: input.constraints,
					unit_length: unit,
					distances: flat,
					stress_terms: ConstrainedInternals.stress_terms_of(flat, node_count),
					rules,
					anchored,
					node_gap: settings.node_gap,
					max_iterations: settings.max_iterations,
					tolerance: settings.tolerance,
				}
				Ok(prepared)
			}
		}
	}

	## The full drawing: initialize, alternate descent and projection, then
	## shared edge routing (self-loops point away from the drawing's
	## centroid) and normalization to the origin — unless pins or containment
	## bands are present, in which case the drawing keeps its absolute
	## coordinates and the bounds record where it sits.
	run : ConstrainedPrepared, Constrained.RunArgs -> Constrained.Result
	run = |prepared, args| {
		node_count = prepared.nodes.len()
		hints_usable =
			args.hints.len() == node_count
				and args.hints.all(|h| F64.is_finite(h.x) and F64.is_finite(h.y))
		base = if hints_usable {
			args.hints
		} else {
			ConstrainedInternals.scatter(node_count, args.seed, prepared.unit_length)
		}

		# Projecting the start (pins included) keeps even a zero-iteration
		# run inside the feasible region.
		start = ConstrainedInternals.apply_rules(base, prepared.rules)
		initial_stress = ConstrainedInternals.stress_of(start, prepared.distances)
		floor = prepared.tolerance * prepared.stress_terms
		solved = ConstrainedInternals.descend(start, prepared.distances, prepared.rules, prepared.tolerance, floor, initial_stress, 0, prepared.max_iterations)

		outwards = ConstrainedInternals.outward_directions(solved.positions)
		routes = EdgeRoutes.route_edges(prepared.edges, solved.positions, outwards, prepared.nodes, prepared.node_gap)
		normalized = EdgeRoutes.normalize(solved.positions, prepared.nodes, routes)

		layout = if prepared.anchored {
			# Normalizing would move the pins and the banded coordinates;
			# keep the raw coordinates and recover the tight box's corner
			# from the shift normalize applied.
			first_raw = solved.positions.get(0) ?? { x: 0, y: 0 }
			first_norm = normalized.positions.get(0) ?? { x: 0, y: 0 }
			{
				positions: solved.positions,
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

		{
			layout,
			convergence: { iterations: solved.iterations, converged: solved.converged },
			unsatisfied: ConstrainedInternals.unsatisfied_of(prepared.constraints, layout.positions),
		}
	}

	## Check and lay out in one call: exactly `build` followed by `run`.
	layout : Constrained.Input, Constrained.Settings, Constrained.RunArgs -> [Ok(Constrained.Result), Err(List(Constrained.Problem))]
	layout = |input, settings, args|
		match ConstrainedPrepared.build(input, settings) {
			Ok(prepared) => Ok(prepared.run(args))
			Err(problems) => Err(problems)
		}
}

## Layouts for graphs that must obey domain rules. The drawing optimizes
## stress — drawn distances tracking graph-theoretic distances — while
## satisfying the given rules: minimum separations, alignments, and
## containment bands over node coordinates, each on one axis.
##
## Every iteration alternates a stress-descent step with a projection of the
## drawing onto the rules, so the result satisfies the rules while staying
## as faithful to graph distances as the rules allow. Each axis's rules are
## projected together in one minimal-movement solve — alignments merge nodes
## into a single variable, bands and pins bound it, and separations order
## the variables — so satisfying one rule never disturbs another; pins are
## re-asserted exactly afterward.
##
## Conflicting rules are not silently resolved: `prepare` rejects every
## conflict its feasibility analysis can prove — a separation made
## impossible by alignment or by other separations, containment bands with
## an empty intersection, a pin outside a band, or disagreeing pins in one
## aligned group — and the result's `unsatisfied` field lists any rule the
## finished drawing still violates, which is empty whenever the rules are
## feasible.
##
## `layout` checks input and produces the drawing in one call. For repeated
## layouts of unchanged input, call `prepare` once and pass the result to
## `layout_prepared`.
Constrained := [].{

	## A rule the drawing must obey, over node indices, on one axis.
	##
	## `Separate` keeps the second node's coordinate at least `gap` beyond
	## the first's on the axis (`gap` may be negative to allow bounded
	## reordering). `Align` gives all listed nodes the same coordinate on
	## the axis. `Inside` keeps every listed node's coordinate within
	## `[low, high]` — absolute coordinates, which anchor the drawing in
	## place of origin normalization.
	Constraint : [
		Separate({ axis : [X, Y], first : U64, second : U64, gap : F64 }),
		Align({ axis : [X, Y], nodes : List(U64) }),
		Inside({ axis : [X, Y], nodes : List(U64), low : F64, high : F64 }),
	]

	## Sized nodes, the edges between them, and the rules the drawing must
	## obey. A node is identified by its index in `nodes`, an edge by its
	## index in `edges`, and a constraint by its index in `constraints`;
	## every output list and every reported problem aligns to those orders.
	Input : {
		graph : {
			nodes : List({ width : F64, height : F64 }),
			edges : List({ from : U64, to : U64 }),
		},
		constraints : List(Constrained.Constraint),
	}

	## `node_gap` sets the per-hop unit distance: the mean over edges of the
	## endpoint diagonals' average plus the gap (the gap alone if edgeless).
	## Iteration stops when the relative stress change of a step drops below
	## `tolerance`, when the stress itself becomes negligible (a mean
	## squared relative pair error below `tolerance`), or at
	## `max_iterations`. Pinned nodes keep exactly the given position; a
	## node pinned twice keeps the last pin in the list.
	Settings : {
		node_gap : F64,
		max_iterations : U64,
		tolerance : F64,
		pins : List({ node : U64, x : F64, y : F64 }),
	}

	## Invalid sizes, edge endpoints, spacing, tolerance, pins, or
	## constraints found while checking input. `MissingPin` and `InvalidPin`
	## carry the pin's index in the pins list. The constraint problems carry
	## the constraint's index in the constraints list:
	## `MissingConstraintNode` adds the missing node index, an
	## `InvalidConstraintGap` is a non-finite separation gap, and an
	## `InvalidConstraintBand` is a band without finite `low <= high`.
	##
	## On otherwise valid input, `prepare` also reports every rule conflict
	## its feasibility analysis can prove. `UnsatisfiableSeparation` is a
	## separation no positions can satisfy together with the alignments and
	## the other rules on its axis — a positive gap inside one aligned
	## group, a member of a positive-total cycle of separations, or a
	## separation that empties a variable's band-and-pin interval.
	## `ConflictingInside` is a band whose intersection with the other bands
	## on its (alignment-merged) nodes is empty. `ConflictingPin` — indexed
	## into the pins list — is a pin outside its node's band interval, or
	## one of two disagreeing pins inside one aligned group.
	Problem : [
		InvalidNodeWidth(U64),
		InvalidNodeHeight(U64),
		MissingEdgeStart(U64, U64),
		MissingEdgeEnd(U64, U64),
		InvalidNodeGap,
		InvalidTolerance,
		MissingPin(U64),
		InvalidPin(U64),
		MissingConstraintNode(U64, U64),
		InvalidConstraintGap(U64),
		InvalidConstraintBand(U64),
		UnsatisfiableSeparation(U64),
		ConflictingInside(U64),
		ConflictingPin(U64),
	]

	## Per-run inputs that select a particular solve: the scatter seed, and
	## optional starting positions — index-aligned, one per node — such as a
	## previous result's positions, which makes a re-run cost only its few
	## iterations.
	RunArgs : { seed : U32, hints : List({ x : F64, y : F64 }) }

	## Geometry plus the convergence record — how many alternation steps ran
	## and whether the stress settled before the iteration cap — plus the
	## honest rule report. `prepare` rejects every rule conflict its
	## feasibility analysis can prove; `unsatisfied` lists the indices (into
	## the input's constraints) of any rule the finished drawing still
	## violates beyond a 1e-9 tolerance, checked directly against the
	## returned positions — a separation's gap shortfall, an alignment's
	## coordinate spread, or a coordinate escaping its band. The unified
	## per-axis projection satisfies every rule kind simultaneously, so it is
	## empty whenever the rules are feasible; only a genuinely infeasible
	## conflict the bounded analysis could not prove leaves it populated.
	Result : {
		layout : {
			positions : List({ x : F64, y : F64 }),
			bounds : { x : F64, y : F64, width : F64, height : F64 },
			routes : List(Geom.Route),
		},
		convergence : { iterations : U64, converged : Bool },
		unsatisfied : List(U64),
	}

	## The empty graph with no constraints. Replace by record update.
	default_input : Input
	default_input = { graph: { nodes: [], edges: [] }, constraints: [] }

	## Settings that produce a readable drawing in common cases.
	default_settings : Settings
	default_settings = { node_gap: 24, max_iterations: 200, tolerance: 0.0001, pins: [] }

	## The fixed default seed and no position hints.
	default_run : RunArgs
	default_run = { seed: 0, hints: [] }

	## Check the input and settings jointly — reporting every independent
	## problem, and rejecting every rule conflict the feasibility analysis
	## can prove — and precompute what repeated runs reuse.
	prepare : Input, Settings -> [Ok(ConstrainedPrepared), Err(List(Problem))]
	prepare = |input, settings| ConstrainedPrepared.build(input, settings)

	## Lay out previously prepared input. This operation cannot fail; the
	## result's `unsatisfied` field lists any rule the finished drawing
	## violates, and is empty whenever the rules are feasible.
	layout_prepared : ConstrainedPrepared, RunArgs -> Result
	layout_prepared = |prepared, args| prepared.run(args)

	## Check and lay out input in one call: exactly `prepare` followed by
	## `layout_prepared`.
	layout : Input, Settings, RunArgs -> [Ok(Result), Err(List(Problem))]
	layout = |input, settings, args| ConstrainedPrepared.layout(input, settings, args)
}

## A separation wider than stress would choose is enforced: on a four-node
## path, the last node ends at least 200 beyond the first on the x axis, and
## the alternating solve still converges.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 4),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }],
		},
		constraints: [Separate({ axis: X, first: 0, second: 3, gap: 200 })],
	}
	settings = { ..Constrained.default_settings, max_iterations: 1000 }
	match Constrained.layout(input, settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			p3 = result.layout.positions.get(3) ?? { x: 0, y: 0 }
			p3.x - p0.x >= 200 - 1e-9
				and result.convergence.converged
					and result.unsatisfied == []
		}
	}
}

## The separation also holds when hints start the nodes in violating order:
## projection pulls the drawing into the feasible region regardless of the
## start.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 4),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }],
		},
		constraints: [Separate({ axis: X, first: 0, second: 3, gap: 200 })],
	}
	args = {
		seed: 0,
		hints: [{ x: 230, y: 0 }, { x: 150, y: 10 }, { x: 80, y: 20 }, { x: 0, y: 30 }],
	}
	match Constrained.layout(input, Constrained.default_settings, args) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			p3 = result.layout.positions.get(3) ?? { x: 0, y: 0 }
			p3.x - p0.x >= 200 - 1e-9 and result.unsatisfied == []
		}
	}
}

## Aligned nodes share a coordinate: the three listed nodes end on one
## horizontal line.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 4),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }],
		},
		constraints: [Align({ axis: Y, nodes: [0, 1, 2] })],
	}
	match Constrained.layout(input, Constrained.default_settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p2 = result.layout.positions.get(2) ?? { x: 0, y: 0 }
			(p0.y - p1.y).abs() <= 1e-9
				and (p1.y - p2.y).abs() <= 1e-9
					and result.unsatisfied == []
		}
	}
}

## A band is honored in absolute coordinates: the listed node's x stays
## within [40, 60], and the drawing is not translated away from the band.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		constraints: [Inside({ axis: X, nodes: [1], low: 40, high: 60 })],
	}
	match Constrained.layout(input, Constrained.default_settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p1.x >= 40 - 1e-9 and p1.x <= 60 + 1e-9 and result.unsatisfied == []
		}
	}
}

## All three rule kinds hold simultaneously on a five-node path: the
## separation, the alignment, and the band are each satisfied in the same
## drawing.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 5),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }],
		},
		constraints: [
			Separate({ axis: X, first: 0, second: 4, gap: 300 }),
			Align({ axis: Y, nodes: [0, 1, 2] }),
			Inside({ axis: X, nodes: [2], low: 100, high: 140 }),
		],
	}
	match Constrained.layout(input, Constrained.default_settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p2 = result.layout.positions.get(2) ?? { x: 0, y: 0 }
			p4 = result.layout.positions.get(4) ?? { x: 0, y: 0 }
			p4.x - p0.x >= 300 - 1e-9
				and (p0.y - p1.y).abs() <= 1e-9
					and (p1.y - p2.y).abs() <= 1e-9
						and p2.x >= 100 - 1e-9
							and p2.x <= 140 + 1e-9
								and result.unsatisfied == []
		}
	}
}

## Pins hold bit-exactly with constraints active: the pinned node keeps its
## pin, and the separation against it still holds (to within the solver's
## near-immovable pin weight).
expect {
	input = {
		graph: {
			nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [Separate({ axis: X, first: 0, second: 1, gap: 50 })],
	}
	settings = { ..Constrained.default_settings, pins: [{ node: 0, x: 5, y: 7 }] }
	match Constrained.layout(input, settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			result.layout.positions.get(0) == Ok({ x: 5, y: 7 })
				and p1.x - 5 >= 50 - 1e-6
					and result.unsatisfied == []
		}
	}
}

## Prepare reports every independent problem in one result: a missing
## constraint node, a non-finite separation gap, an inverted band, and a
## missing pin together.
expect {
	input = {
		graph: { nodes: [{ width: 4, height: 4 }], edges: [] },
		constraints: [
			Separate({ axis: X, first: 0, second: 9, gap: F64.infinity }),
			Inside({ axis: Y, nodes: [0], low: 5, high: 1 }),
		],
	}
	settings = { ..Constrained.default_settings, pins: [{ node: 3, x: 1, y: 2 }] }
	Constrained.prepare(input, settings) == Err([
		MissingPin(0),
		MissingConstraintNode(0, 9),
		InvalidConstraintGap(0),
		InvalidConstraintBand(1),
	])
}

## Identical input, settings, and run arguments produce identical output,
## bit for bit.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 5),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }],
		},
		constraints: [
			Separate({ axis: X, first: 0, second: 4, gap: 300 }),
			Align({ axis: Y, nodes: [0, 1, 2] }),
			Inside({ axis: X, nodes: [2], low: 100, high: 140 }),
		],
	}
	Constrained.layout(input, Constrained.default_settings, Constrained.default_run) == Constrained.layout(input, Constrained.default_settings, Constrained.default_run)
}

## Different seeds are different, equally valid solves: an unconstrained
## pair lands differently.
expect {
	input = {
		graph: {
			nodes: [{ width: 10, height: 10 }, { width: 10, height: 10 }],
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [],
	}
	match Constrained.prepare(input, Constrained.default_settings) {
		Err(_) => False
		Ok(prepared) => {
			a = Constrained.layout_prepared(prepared, { seed: 0, hints: [] })
			b = Constrained.layout_prepared(prepared, { seed: 99, hints: [] })
			a.layout.positions != b.layout.positions
		}
	}
}

## The one-shot layout is exactly prepare followed by layout_prepared.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 5),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 4 }],
		},
		constraints: [
			Separate({ axis: X, first: 0, second: 4, gap: 300 }),
			Align({ axis: Y, nodes: [0, 1, 2] }),
		],
	}
	match Constrained.prepare(input, Constrained.default_settings) {
		Err(_) => False
		Ok(prepared) =>
			Constrained.layout(input, Constrained.default_settings, Constrained.default_run) == Ok(Constrained.layout_prepared(prepared, Constrained.default_run))
		}
}

## The empty graph with no constraints has a defined layout: no positions,
## no routes, zero-size bounds at the origin.
expect {
	match Constrained.layout(Constrained.default_input, Constrained.default_settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) =>
			result.layout.positions == []
				and result.layout.routes == []
					and result.layout.bounds == { x: 0, y: 0, width: 0, height: 0 }
						and result.unsatisfied == []
		}
}

## With no constraints the solve behaves like plain stress: a path of three
## equal nodes settles with drawn distances within 15% of the
## graph-theoretic ideal.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		constraints: [],
	}
	settings = { ..Constrained.default_settings, tolerance: 1e-7, max_iterations: 2000 }
	match Constrained.layout(input, settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			unit = Geom.hypot(10, 10) + 24
			p0 = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p2 = result.layout.positions.get(2) ?? { x: 0, y: 0 }
			d01 = Geom.hypot(p1.x - p0.x, p1.y - p0.y)
			d12 = Geom.hypot(p2.x - p1.x, p2.y - p1.y)
			d02 = Geom.hypot(p2.x - p0.x, p2.y - p0.y)
			(d01 - unit).abs() < unit * 0.15
				and (d12 - unit).abs() < unit * 0.15
					and (d02 - 2 * unit).abs() < 2 * unit * 0.15
		}
	}
}

## The convergence record is populated: a zero iteration cap reports zero
## iterations and no convergence, while an ample cap reports the steps used
## and convergence.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		constraints: [],
	}
	capped = { ..Constrained.default_settings, max_iterations: 0 }
	match (Constrained.prepare(input, capped), Constrained.prepare(input, Constrained.default_settings)) {
		(Ok(stopped), Ok(free)) => {
			none = Constrained.layout_prepared(stopped, Constrained.default_run)
			full = Constrained.layout_prepared(free, Constrained.default_run)
			none.convergence == { iterations: 0, converged: False }
				and full.convergence.converged
					and full.convergence.iterations >= 1
						and full.convergence.iterations <= 200
		}

		_ => False
	}
}

## Contradictory separations are rejected at prepare: a two-cycle of
## positive x gaps admits no positions, and the report names a separation on
## the cycle — the one whose relaxation fired last in the proving pass.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 2),
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [
			Separate({ axis: X, first: 0, second: 1, gap: 10 }),
			Separate({ axis: X, first: 1, second: 0, gap: 10 }),
		],
	}
	Constrained.prepare(input, Constrained.default_settings) == Err([UnsatisfiableSeparation(1)])
}

## A three-cycle of positive separations is likewise rejected.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		constraints: [
			Separate({ axis: X, first: 0, second: 1, gap: 10 }),
			Separate({ axis: X, first: 1, second: 2, gap: 10 }),
			Separate({ axis: X, first: 2, second: 0, gap: 10 }),
		],
	}
	Constrained.prepare(input, Constrained.default_settings) == Err([UnsatisfiableSeparation(2)])
}

## A positive separation between two nodes an alignment fuses onto one
## coordinate is unsatisfiable, and the report names the separation.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 2),
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [
			Align({ axis: X, nodes: [0, 1] }),
			Separate({ axis: X, first: 0, second: 1, gap: 5 }),
		],
	}
	Constrained.prepare(input, Constrained.default_settings) == Err([UnsatisfiableSeparation(1)])
}

## Two disjoint containment bands on one node and axis have an empty
## intersection; the report names the band that emptied it.
expect {
	input = {
		graph: { nodes: [{ width: 10, height: 10 }], edges: [] },
		constraints: [
			Inside({ axis: X, nodes: [0], low: 0, high: 10 }),
			Inside({ axis: X, nodes: [0], low: 20, high: 30 }),
		],
	}
	Constrained.prepare(input, Constrained.default_settings) == Err([ConflictingInside(1)])
}

## A pin outside its node's containment band is a conflict reported at
## prepare — not silently resolved in the pin's favor.
expect {
	input = {
		graph: { nodes: [{ width: 10, height: 10 }], edges: [] },
		constraints: [Inside({ axis: X, nodes: [0], low: 0, high: 10 })],
	}
	settings = { ..Constrained.default_settings, pins: [{ node: 0, x: 100, y: 0 }] }
	Constrained.prepare(input, settings) == Err([ConflictingPin(0)])
}

## Disagreeing pins on two nodes an alignment fuses are a conflict reported
## at prepare — no pin silently outranks the other.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 2),
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [Align({ axis: X, nodes: [0, 1] })],
	}
	settings = { ..Constrained.default_settings, pins: [{ node: 0, x: 0, y: 0 }, { node: 1, x: 50, y: 0 }] }
	Constrained.prepare(input, settings) == Err([ConflictingPin(1)])
}

## A satisfiable chain of separations — no positive cycle — still prepares,
## the drawing honors both gaps, and no rule is left unsatisfied.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		constraints: [
			Separate({ axis: X, first: 0, second: 1, gap: 30 }),
			Separate({ axis: X, first: 1, second: 2, gap: 30 }),
		],
	}
	match Constrained.layout(input, Constrained.default_settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 0, y: 0 }
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p2 = result.layout.positions.get(2) ?? { x: 0, y: 0 }
			p1.x - p0.x >= 30 - 1e-9
				and p2.x - p1.x >= 30 - 1e-9
					and result.unsatisfied == []
		}
	}
}

## Huge but finite node sizes stay finite end to end: the derived unit
## saturates instead of overflowing, and every position and bound in the
## result is finite.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 1.0e308, height: 1.0e308 }, 3),
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		constraints: [],
	}
	args = { seed: 0, hints: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 20, y: 0 }] }
	match Constrained.layout(input, Constrained.default_settings, args) {
		Err(_) => False
		Ok(result) => {
			bounds = result.layout.bounds
			result.layout.positions.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
				and F64.is_finite(bounds.x)
					and F64.is_finite(bounds.y)
						and F64.is_finite(bounds.width)
							and F64.is_finite(bounds.height)
		}
	}
}

## fuzz regression: two 1x1 nodes on an edge, node 0 held at x = 0 by a
## one-point band, both nodes aligned on y, and an x separation of 1. The
## old sequential projection let the band clamp move node 0 after the
## separation solve had already satisfied the pair, breaking the separation
## in the returned drawing. The unified per-axis projection satisfies all
## three rules at once: the separation holds, the y coordinates agree, node
## 0 sits at its band (coordinates are absolute — the band anchors the
## drawing), and nothing is left unsatisfied.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 1, height: 1 }, 2),
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [
			Inside({ axis: X, nodes: [0], low: 0, high: 0 }),
			Align({ axis: Y, nodes: [0, 1] }),
			Separate({ axis: X, first: 0, second: 1, gap: 1 }),
		],
	}
	match Constrained.layout(input, Constrained.default_settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 1, y: 1 }
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p1.x - p0.x >= 1 - 1e-9
				and (p0.y - p1.y).abs() <= 1e-9
					and p0.x.abs() <= 1e-9
						and result.unsatisfied == []
		}
	}
}

## A pin, a band on another node, and a separation chaining them hold
## simultaneously: node 0 keeps its pin bit-exactly, node 1 stays inside
## its band, the separation between them holds, and nothing is left
## unsatisfied.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 10, height: 10 }, 2),
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [
			Inside({ axis: X, nodes: [1], low: 80, high: 90 }),
			Separate({ axis: X, first: 0, second: 1, gap: 60 }),
		],
	}
	settings = { ..Constrained.default_settings, pins: [{ node: 0, x: 0, y: 0 }] }
	match Constrained.layout(input, settings, Constrained.default_run) {
		Err(_) => False
		Ok(result) => {
			p0 = result.layout.positions.get(0) ?? { x: 1, y: 1 }
			p1 = result.layout.positions.get(1) ?? { x: 0, y: 0 }
			p0 == { x: 0, y: 0 }
				and p1.x >= 80 - 1e-9
					and p1.x <= 90 + 1e-9
						and p1.x - p0.x >= 60 - 1e-9
							and result.unsatisfied == []
		}
	}
}

## Ordering stress on the fuzz shape with a band on the RIGHT node too:
## node 0 held at x = 0, node 1 banded to [0, 5], and a separation
## demanding x1 - x0 >= 10 — infeasible. The build-time tightening pass
## proves it (the separation raises node 1's lower bound past its band's
## upper bound), so prepare rejects it naming the separation; were the
## bounded analysis unable to prove this one, the run's `unsatisfied` would
## have to list the separation instead.
expect {
	input = {
		graph: {
			nodes: List.repeat({ width: 1, height: 1 }, 2),
			edges: [{ from: 0, to: 1 }],
		},
		constraints: [
			Inside({ axis: X, nodes: [0], low: 0, high: 0 }),
			Inside({ axis: X, nodes: [1], low: 0, high: 5 }),
			Separate({ axis: X, first: 0, second: 1, gap: 10 }),
		],
	}
	Constrained.prepare(input, Constrained.default_settings) == Err([UnsatisfiableSeparation(2)])
}
