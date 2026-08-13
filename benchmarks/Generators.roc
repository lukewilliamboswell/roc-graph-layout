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
		} else {
			Generators.indices(n - 1).map(|i| { from: i, to: i + 1 })
		}
		{ nodes, edges }
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
