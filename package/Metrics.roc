import Geom

## Shared internal helpers for the public layout metrics: segment
## extraction from routes, the orientation predicate behind crossing
## detection, the bend test, and an inline breadth-first search for the
## stress metric. Nothing here is part of the public vocabulary.
MetricsInternals :: {}.{

	## `[0, 1, .., n - 1]`, the shared building block for walking a bounded
	## range of indices without a loop construct.
	indices_up_to : U64 -> List(U64)
	indices_up_to = |n| List.repeat(0, n).map_with_index(|_, i| i)

	## Consecutive point pairs of a polyline as straight segments. A list
	## with fewer than two points yields no segments.
	polyline_segments : List({ x : F64, y : F64 }) -> List({ a : { x : F64, y : F64 }, b : { x : F64, y : F64 } })
	polyline_segments = |pts|
		pts.fold_with_index(
			[],
			|acc, p, i| {
				if i == 0 {
					acc
				} else {
					prev = pts.get(i - 1) ?? p
					acc.append({ a: prev, b: p })
				}
			},
		)

	## Every route straightened to segments: a line is one segment, a
	## polyline its consecutive pairs, and a curve chain one chord per
	## cubic segment (`from` to `to`).
	route_segments : Geom.Route -> List({ a : { x : F64, y : F64 }, b : { x : F64, y : F64 } })
	route_segments = |route|
		match route {
			Line(a, b) => [{ a, b }]
			Polyline(pts) => MetricsInternals.polyline_segments(pts)
			Curves(segs) => segs.map(|s| { a: s.from, b: s.to })
		}

	## Twice the signed area of the triangle `a`, `b`, `c` — positive when
	## `c` lies to one side of the directed line `a -> b`, negative on the
	## other, zero when collinear.
	orient : { x : F64, y : F64 }, { x : F64, y : F64 }, { x : F64, y : F64 } -> F64
	orient = |a, b, c| (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)

	## Whether segment `p1 -> p2` and segment `p3 -> p4` cross at a single
	## interior point of both. Strict orientation signs on both sides mean
	## collinear overlaps and any touching at an endpoint (including
	## segments sharing an endpoint exactly) are excluded.
	proper_crossing : { x : F64, y : F64 }, { x : F64, y : F64 }, { x : F64, y : F64 }, { x : F64, y : F64 } -> Bool
	proper_crossing = |p1, p2, p3, p4| {
		d1 = MetricsInternals.orient(p3, p4, p1)
		d2 = MetricsInternals.orient(p3, p4, p2)
		d3 = MetricsInternals.orient(p1, p2, p3)
		d4 = MetricsInternals.orient(p1, p2, p4)
		((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0))
	}

	## Whether the incoming direction `din` and outgoing direction `dout`
	## differ enough to read as a bend: the cross-product magnitude exceeds
	## `1e-9` scaled by both lengths, or the directions reverse (negative
	## dot product, which the cross test alone cannot see). A zero-length
	## direction never turns.
	turns : { x : F64, y : F64 }, { x : F64, y : F64 } -> Bool
	turns = |din, dout| {
		cross = din.x * dout.y - din.y * dout.x
		dot = din.x * dout.x + din.y * dout.y
		len_in = Geom.hypot(din.x, din.y)
		len_out = Geom.hypot(dout.x, dout.y)
		cross.abs() > 1.0e-9 * len_in * len_out or dot < 0
	}

	## Bends within one route: none for a line; for a polyline, interior
	## vertices where consecutive segment directions turn; for a curve
	## chain, joints where the incoming tangent (`to - ctl_b`) and the next
	## segment's outgoing tangent (`ctl_a - from`) turn.
	route_bends : Geom.Route -> U64
	route_bends = |route| {
		dirs = match route {
			Line(_, _) => []
			Polyline(pts) =>
				MetricsInternals.polyline_segments(pts).map(
					|s| {
						d = { x: s.b.x - s.a.x, y: s.b.y - s.a.y }
						{ start_dir: d, end_dir: d }
					},
				)
			Curves(segs) =>
				segs.map(
					|s| {
						start_dir: { x: s.ctl_a.x - s.from.x, y: s.ctl_a.y - s.from.y },
						end_dir: { x: s.to.x - s.ctl_b.x, y: s.to.y - s.ctl_b.y },
					},
				)
			}

		dirs.fold_with_index(
			0,
			|count, d, i| {
				if i == 0 {
					count
				} else {
					prev = dirs.get(i - 1) ?? d
					if MetricsInternals.turns(prev.end_dir, d.start_dir) {
						count + 1
					} else {
						count
					}
				}
			},
		)
	}

	## Undirected adjacency lists over `n` nodes. Self-loops and edges with
	## out-of-range endpoints are skipped, so any edge list is accepted.
	adjacency : U64, List({ from : U64, to : U64 }) -> List(List(U64))
	adjacency = |n, edges|
		edges.fold(
			List.repeat([], n),
			|adj, edge| {
				if edge.from == edge.to or edge.from >= n or edge.to >= n {
					adj
				} else {
					forward = adj.set(edge.from, (adj.get(edge.from) ?? []).append(edge.to)) ?? adj
					forward.set(edge.to, (forward.get(edge.to) ?? []).append(edge.from)) ?? forward
				}
			},
		)

	## Unweighted hop counts from `source` to every node, with `n` (an
	## impossible distance in an `n`-node graph) marking unreachable nodes.
	## Level-by-level frontier expansion, bounded by `n` rounds so it
	## terminates on any input.
	##
	## NOTE: this duplicates breadth-first search planned for a shared
	## internal Paths module; consolidate there once it lands.
	bfs_hops : U64, List(List(U64)), U64 -> List(U64)
	bfs_hops = |n, adj, source| {
		unreachable = List.repeat(n, n)
		start = unreachable.set(source, 0) ?? unreachable

		final = MetricsInternals.indices_up_to(n).fold(
			{ dist: start, frontier: [source], level: 1 },
			|state, _round| {
				if state.frontier.is_empty() {
					state
				} else {
					stepped = state.frontier.fold(
						{ dist: state.dist, next: [] },
						|acc, u|
							(adj.get(u) ?? []).fold(
								acc,
								|inner, v| {
									if (inner.dist.get(v) ?? 0) == n {
										{
											dist: inner.dist.set(v, state.level) ?? inner.dist,
											next: inner.next.append(v),
										}
									} else {
										inner
									}
								},
							),
					)
					{ dist: stepped.dist, frontier: stepped.next, level: state.level + 1 }
				}
			},
		)

		final.dist
	}
}

## Public measurements for comparing layout quality. Every metric is
## algorithm-independent — it scores positions, routes, or bounds in the
## shared output vocabulary — so consumers and regression tests can compare
## any two layouts with the same numbers. All metrics are total and
## deterministic: any well-typed input has a defined, finite result.
Metrics :: {}.{

	## Area of the layout bounds — the amount of page the drawing claims.
	## Smaller is denser. Constant time.
	area : { x : F64, y : F64, width : F64, height : F64 } -> F64
	area = |bounds| bounds.width * bounds.height

	## How many times edges visually cross each other — the strongest
	## single predictor of how tangled a drawing reads. Counts transverse
	## intersections between segments of different routes; segments within
	## one route never count against each other, and two segments that only
	## touch at a point (for example routes attaching to the same node
	## boundary) or overlap collinearly are not crossings. Routes are
	## straightened first: lines and polyline pieces score as themselves,
	## and curve chains are scored by their chords (`from` to `to` of each
	## cubic segment), an approximation that keeps the count exact for the
	## polyline skeleton a curve smooths. O(s^2) over all segments; a
	## sweep-based version for large drawings is future work.
	crossings : List(Geom.Route) -> U64
	crossings = |routes| {
		segments = routes.fold_with_index(
			[],
			|acc, route, route_index|
				MetricsInternals.route_segments(route).fold(
					acc,
					|inner, s| inner.append({ route: route_index, a: s.a, b: s.b }),
				),
		)

		segments.fold_with_index(
			0,
			|total, s1, i|
				segments.fold_with_index(
					total,
					|acc, s2, j| {
						if j > i and s1.route != s2.route and MetricsInternals.proper_crossing(s1.a, s1.b, s2.a, s2.b) {
							acc + 1
						} else {
							acc
						}
					},
				),
		)
	}

	## How many corners the reader's eye must follow along the edges.
	## Lines have none; a polyline bends at each interior vertex where the
	## incoming and outgoing directions differ; a curve chain bends at each
	## joint where the incoming tangent (`to - ctl_b`) and outgoing tangent
	## (`ctl_a - from`) differ — smooth chains with matching tangents add
	## nothing. Directions differ when the cross-product magnitude exceeds
	## `1e-9` relative to both segment lengths, or when they reverse
	## outright. Linear in the total number of route pieces.
	bends : List(Geom.Route) -> U64
	bends = |routes| routes.fold(0, |total, route| total + MetricsInternals.route_bends(route))

	## The drawing's shape as width over height — near 1 is roughly square,
	## large is a wide banner, small is a tall column. Degenerate rule,
	## chosen to stay finite: a zero-height bounds with zero width (a point
	## or empty layout) reports 1, and a zero-height bounds with positive
	## width (a fully flat layout) reports its width, which still grows the
	## flatter and wider the drawing gets. Constant time.
	aspect_ratio : { x : F64, y : F64, width : F64, height : F64 } -> F64
	aspect_ratio = |bounds| {
		if bounds.height > 0 {
			bounds.width / bounds.height
		} else if bounds.width == 0 {
			1
		} else {
			bounds.width
		}
	}

	## How many node pairs sit closer than the required clearance — pairs a
	## reader sees as colliding or crowded. Each node's box is centered on
	## its position and expanded by `gap / 2` on every side; a pair counts
	## when the expanded boxes strictly overlap on both axes, so boxes that
	## exactly touch are allowed. Positions and sizes are index-aligned;
	## indices present in only one list are ignored. O(n^2) over node
	## pairs.
	separation_violations : List({ x : F64, y : F64 }), List({ width : F64, height : F64 }), F64 -> U64
	separation_violations = |positions, sizes, gap| {
		n = positions.len().min(sizes.len())

		MetricsInternals.indices_up_to(n).fold(
			0,
			|total, i|
				MetricsInternals.indices_up_to(n).fold(
					total,
					|acc, j| {
						if j > i {
							pi = positions.get(i) ?? { x: 0, y: 0 }
							pj = positions.get(j) ?? { x: 0, y: 0 }
							si = sizes.get(i) ?? { width: 0, height: 0 }
							sj = sizes.get(j) ?? { width: 0, height: 0 }
							overlap_x = (pi.x - pj.x).abs() < (si.width + sj.width) / 2 + gap
							overlap_y = (pi.y - pj.y).abs() < (si.height + sj.height) / 2 + gap
							if overlap_x and overlap_y {
								acc + 1
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

	## How far the drawing moved between two layouts of the same nodes —
	## the stability measure (F7): small numbers mean a reader's mental map
	## survives a re-layout. Distances are between index-aligned position
	## pairs; indices present in only one list are ignored, and no pairs at
	## all reports `{ mean: 0, max: 0 }`. Linear in the number of pairs.
	displacement : List({ x : F64, y : F64 }), List({ x : F64, y : F64 }) -> { mean : F64, max : F64 }
	displacement = |before, after| {
		n = before.len().min(after.len())

		totals = MetricsInternals.indices_up_to(n).fold(
			{ sum: 0.0, max: 0.0 },
			|acc, i| {
				a = before.get(i) ?? { x: 0, y: 0 }
				b = after.get(i) ?? { x: 0, y: 0 }
				d = Geom.hypot(b.x - a.x, b.y - a.y)
				{ sum: acc.sum + d, max: acc.max.max(d) }
			},
		)

		if n == 0 {
			{ mean: 0, max: 0 }
		} else {
			{ mean: totals.sum / n.to_f64(), max: totals.max }
		}
	}

	## How faithfully drawn distances reflect graph distances — 0 means
	## every reachable pair sits exactly where the graph structure says it
	## should; larger values mean the drawing compresses or stretches
	## relationships. For every unordered pair of mutually reachable nodes,
	## the ideal distance is the unweighted hop count times `unit`, and the
	## pair contributes the squared relative error `((drawn - ideal) /
	## ideal)^2` (the classic 1/ideal^2 stress weighting). Self pairs,
	## unreachable pairs, pairs without a position, and pairs whose ideal
	## distance is not positive and finite contribute nothing, so the
	## result is defined and finite for any input — this is a metric, not a
	## validator, and self-loops or out-of-range edge endpoints are simply
	## skipped. Fewer than two nodes scores 0. O(n * (n + m)) for the
	## per-node breadth-first searches plus O(n^2) pair summation.
	stress : { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }, List({ x : F64, y : F64 }), F64 -> F64
	stress = |graph, positions, unit| {
		n = graph.nodes.len()

		if n < 2 {
			0
		} else {
			adj = MetricsInternals.adjacency(n, graph.edges)

			MetricsInternals.indices_up_to(n).fold(
				0.0,
				|total, s| {
					dist = MetricsInternals.bfs_hops(n, adj, s)
					MetricsInternals.indices_up_to(n).fold(
						total,
						|acc, t| {
							hops = dist.get(t) ?? n
							if t <= s or hops == n {
								acc
							} else {
								ideal = hops.to_f64() * unit
								if F64.is_finite(ideal) and ideal > 0 {
									match positions.get(s) {
										Err(_) => acc
										Ok(ps) =>
											match positions.get(t) {
												Err(_) => acc
												Ok(pt) => {
													drawn = Geom.hypot(pt.x - ps.x, pt.y - ps.y)
													relative = (drawn - ideal) / ideal
													acc + relative * relative
												}
											}
										}
								} else {
									acc
								}
							}
						},
					)
				},
			)
		}
	}
}

## Area multiplies the normalized bounding-box extents.
expect Metrics.area({ x: 0, y: 0, width: 8, height: 5 }) == 40

## Two lines that cross transversally count one crossing.
expect Metrics.crossings([Line({ x: 0, y: 0 }, { x: 10, y: 10 }), Line({ x: 0, y: 10 }, { x: 10, y: 0 })]) == 1

## Two parallel lines never cross.
expect Metrics.crossings([Line({ x: 0, y: 0 }, { x: 10, y: 0 }), Line({ x: 0, y: 5 }, { x: 10, y: 5 })]) == 0

## Routes sharing an attachment point touch, not cross.
expect Metrics.crossings([Line({ x: 0, y: 0 }, { x: 10, y: 10 }), Line({ x: 10, y: 10 }, { x: 20, y: 0 })]) == 0

## Two polylines forming an X cross exactly once.
expect
	Metrics.crossings([
		Polyline([{ x: 0, y: 0 }, { x: 4, y: 4 }, { x: 10, y: 10 }]),
		Polyline([{ x: 0, y: 10 }, { x: 6, y: 4 }, { x: 10, y: 0 }]),
	])
		== 1

## Curve routes are scored by their chords, which here cross once.
expect
	Metrics.crossings([
		Curves([{ from: { x: 0, y: 0 }, ctl_a: { x: 3, y: 0 }, ctl_b: { x: 7, y: 10 }, to: { x: 10, y: 10 } }]),
		Curves([{ from: { x: 0, y: 10 }, ctl_a: { x: 3, y: 10 }, ctl_b: { x: 7, y: 0 }, to: { x: 10, y: 0 } }]),
	])
		== 1

## No routes means no crossings.
expect Metrics.crossings([]) == 0

## A polyline through collinear points has no bends.
expect Metrics.bends([Polyline([{ x: 0, y: 0 }, { x: 5, y: 0 }, { x: 10, y: 0 }])]) == 0

## A right-angle polyline bends once.
expect Metrics.bends([Polyline([{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }])]) == 1

## A smooth curve chain with matching tangents at the joint has no bends.
expect
	Metrics.bends([
		Curves([
			{ from: { x: 0, y: 0 }, ctl_a: { x: 3, y: 2 }, ctl_b: { x: 7, y: 0 }, to: { x: 10, y: 0 } },
			{ from: { x: 10, y: 0 }, ctl_a: { x: 13, y: 0 }, ctl_b: { x: 17, y: 2 }, to: { x: 20, y: 0 } },
		]),
	])
		== 0

## A single line has no bends, and no routes have none.
expect Metrics.bends([Line({ x: 0, y: 0 }, { x: 9, y: 9 })]) == 0
expect Metrics.bends([]) == 0

## Aspect ratio is width over height for a positive-height bounds.
expect Metrics.aspect_ratio({ x: 0, y: 0, width: 8, height: 4 }) == 2

## A zero-size bounds is treated as square: ratio 1.
expect Metrics.aspect_ratio({ x: 0, y: 0, width: 0, height: 0 }) == 1

## A flat zero-height bounds reports its width instead of infinity.
expect Metrics.aspect_ratio({ x: 0, y: 0, width: 7, height: 0 }) == 7

## Boxes overlapping on both axes violate separation once per pair.
expect
	Metrics.separation_violations(
		[{ x: 0, y: 0 }, { x: 5, y: 0 }],
		[{ width: 10, height: 10 }, { width: 10, height: 10 }],
		0,
	)
		== 1

## Boxes that exactly touch are allowed.
expect
	Metrics.separation_violations(
		[{ x: 0, y: 0 }, { x: 10, y: 0 }],
		[{ width: 10, height: 10 }, { width: 10, height: 10 }],
		0,
	)
		== 0

## Boxes that clear each other but not the required gap still violate.
expect
	Metrics.separation_violations(
		[{ x: 0, y: 0 }, { x: 12, y: 0 }],
		[{ width: 10, height: 10 }, { width: 10, height: 10 }],
		4,
	)
		== 1

## No nodes means no separation violations.
expect Metrics.separation_violations([], [], 5) == 0

## A single node moved along a 3-4-5 triangle displaces by exactly 5.
expect Metrics.displacement([{ x: 0, y: 0 }], [{ x: 3, y: 4 }]) == { mean: 5, max: 5 }

## One moved and one still node average half the single displacement.
expect Metrics.displacement([{ x: 0, y: 0 }, { x: 1, y: 1 }], [{ x: 3, y: 4 }, { x: 1, y: 1 }]) == { mean: 2.5, max: 5 }

## No position pairs means no displacement.
expect Metrics.displacement([], []) == { mean: 0, max: 0 }

## A path graph drawn at exactly its ideal spacing has zero stress.
expect
	Metrics.stress(
		{
			nodes: [{ width: 1, height: 1 }, { width: 1, height: 1 }, { width: 1, height: 1 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		[{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 20, y: 0 }],
		10,
	)
		== 0

## The same path compressed to half its ideal spacing has positive stress.
expect
	Metrics.stress(
		{
			nodes: [{ width: 1, height: 1 }, { width: 1, height: 1 }, { width: 1, height: 1 }],
			edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }],
		},
		[{ x: 0, y: 0 }, { x: 5, y: 0 }, { x: 10, y: 0 }],
		10,
	)
		> 0

## Unreachable pairs contribute nothing: an isolated third node leaves an
## ideally spaced pair at zero stress.
expect
	Metrics.stress(
		{
			nodes: [{ width: 1, height: 1 }, { width: 1, height: 1 }, { width: 1, height: 1 }],
			edges: [{ from: 0, to: 1 }],
		},
		[{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 100, y: 100 }],
		10,
	)
		== 0

## An empty graph and a single node both score zero stress.
expect Metrics.stress({ nodes: [], edges: [] }, [], 10) == 0
expect Metrics.stress({ nodes: [{ width: 2, height: 2 }], edges: [] }, [{ x: 3, y: 4 }], 10) == 0

## Metrics are deterministic: the same nontrivial input scores the same bits.
expect {
	routes = [
		Polyline([{ x: 0, y: 0 }, { x: 4, y: 4 }, { x: 10, y: 10 }]),
		Polyline([{ x: 0, y: 10 }, { x: 6, y: 4 }, { x: 10, y: 0 }]),
		Line({ x: 2, y: 9 }, { x: 9, y: 2 }),
	]
	graph = {
		nodes: [{ width: 1, height: 1 }, { width: 1, height: 1 }, { width: 1, height: 1 }, { width: 1, height: 1 }],
		edges: [{ from: 0, to: 1 }, { from: 1, to: 2 }, { from: 2, to: 3 }, { from: 3, to: 0 }],
	}
	positions = [{ x: 0, y: 0 }, { x: 7, y: 1 }, { x: 8, y: 9 }, { x: 1, y: 8 }]
	Metrics.crossings(routes) == Metrics.crossings(routes)
		and Metrics.bends(routes) == Metrics.bends(routes)
			and Metrics.stress(graph, positions, 10) == Metrics.stress(graph, positions, 10)
}
