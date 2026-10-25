import layout.Geom
import layout.Tree

Generators := [].{
	indices : U64 -> List(U64)
	indices = |n| List.repeat(0, n).map_with_index(|_, i| i)

	graph : Str, U64, U64 -> { nodes : List({ width : F64, height : F64 }), edges : List({ from : U64, to : U64 }) }
	graph = |name, n, seed| {
		nodes = List.repeat({ width: 24, height: 16 }, n)
		edges = if n < 2 {
			[]
		} else if name == "star" {
			Generators.indices(n - 1).map(|i| { from: 0, to: i + 1 })
		} else if name == "cycle_chords" {
			Generators.indices(n).map(|i| { from: i, to: (i + 1) % n }).concat(
				Generators.indices(n).map(|i| { from: i, to: (i + n / 2 + seed % n) % n }),
			)
		} else if name == "disconnected" {
			Generators.indices(n - 1).keep_if(|i| i % 4 != 3).map(|i| { from: i, to: i + 1 })
		} else if name == "bands" {
			half = n / 2
			Generators.indices(half).map(|i| { from: i, to: half + (half - i - 1) })
		} else if name == "dag" or name == "dag_reversed" or name == "dag_cycles" {
			# A flowchart-like acyclic graph: every node after the first hangs
			# from a nearby earlier node, and every third node also joins from
			# a second, farther one, so edges span several layers.
			forward = Generators.indices(n - 1).fold(
				[],
				|acc, k| {
					i = k + 1
					h = Generators.mix(i, seed)
					parent = i - 1 - h % i.min(4)
					first = acc.append({ from: parent, to: i })
					if i % 3 == 0 and i > 4 {
						other = i - 2 - (h // 7) % (i - 1).min(12)
						if other == parent {
							first
						} else {
							first.append({ from: other, to: i })
						}
					} else {
						first
					}
				},
			)
			if name == "dag_reversed" {
				# The same graph with node indices reversed, so every edge runs
				# from a higher index to a lower one.
				forward.map(|e| { from: n - 1 - e.from, to: n - 1 - e.to })
			} else if name == "dag_cycles" {
				# Every tenth node also points back to an ancestor, closing cycles.
				forward.concat(Generators.indices(n / 10).keep_if(|k| k > 0).map(|k| { from: k * 10, to: k * 10 - 1 - Generators.mix(k, seed) % 6 }))
			} else {
				forward
			}
		} else if name == "deep" {
			# A chain with a skip edge every node: long edges and many layers.
			Generators.indices(n - 1).map(|i| { from: i, to: i + 1 }).concat(Generators.indices(n).keep_if(|i| i + 5 < n).map(|i| { from: i, to: i + 5 }))
		} else if name == "wide" {
			# One root fanning out to every other node, which all join one sink.
			Generators.indices(n - 2).map(|i| { from: 0, to: i + 1 }).concat(Generators.indices(n - 2).map(|i| { from: i + 1, to: n - 1 }))
		} else if name == "dense" {
			# Every node points at its next eight successors.
			Generators.indices(n).fold(
				[],
				|acc, i| Generators.indices(8).fold(
					acc,
					|inner, d| if i + d + 1 < n {
						inner.append({ from: i, to: i + d + 1 })
					} else {
						inner
					},
				),
			)
		} else {
			Generators.indices(n - 1).map(|i| { from: i, to: i + 1 })
		}
		{ nodes, edges }
	}

	## A deterministic pseudo-random value for fixture index `i`.
	mix : U64, U64 -> U64
	mix = |i, seed| {
		x = ((i + 1) * 2654435761 + seed * 40503) % 4_294_967_296
		(x.bitwise_xor(x.shr_zf_wrap(13))) % 1_000_003
	}

	tree : Str, U64 -> Tree.Input
	tree = |name, n| {
		if n <= 1 {
			{ width: 24, height: 16, children: [] }
		} else if name == "star" {
			{ width: 24, height: 16, children: List.repeat({ width: 24, height: 16, children: [] }, n - 1) }
		} else {
			# Build from the leaf upward so the fixture itself does not consume
			# one native stack frame per node before measurement begins.
			Generators.indices(n - 1).fold(
				{ width: 24, height: 16, children: [] },
				|child, _| { width: 24, height: 16, children: [child] },
			)
		}
	}

	positions : Str, U64 -> List({ x : F64, y : F64 })
	positions = |name, n| Generators.indices(n).map(
		|i| if name == "pileup" {
			Geom.point(0, 0)
		} else {
			Geom.point((i % 100).to_f64() * 40, (i / 100).to_f64() * 30)
		},
	)

	routes : Str, U64 -> List(Geom.Route)
	routes = |name, n| Generators.indices(n).map(
		|i| if name == "all_crossing" {
			Line(Geom.point(0, i.to_f64()), Geom.point(1000, (n - i).to_f64()))
		} else {
			Line(Geom.point(0, i.to_f64() * 2), Geom.point(1000, i.to_f64() * 2))
		},
	)
}
