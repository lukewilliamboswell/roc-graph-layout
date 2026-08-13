app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Geom
import Metrics

byte_at = |bytes, i| bytes.get(i) ?? 0

test = |bytes| {
	n = (byte_at(bytes, 0) % 9).to_u64()
	points = List.repeat({}, n).map_with_index(
		|_, i| {
			x: (byte_at(bytes, 1 + i * 2) % 41).to_f64() - 20,
			y: (byte_at(bytes, 2 + i * 2) % 41).to_f64() - 20,
		},
	)
	sizes = List.repeat({}, n).map_with_index(
		|_, i| {
			width: (byte_at(bytes, 20 + i * 2) % 13).to_f64(),
			height: (byte_at(bytes, 21 + i * 2) % 13).to_f64(),
		},
	)
	dx = (byte_at(bytes, 40) % 21).to_f64() - 10
	dy = (byte_at(bytes, 41) % 21).to_f64() - 10
	shifted = points.map(|p| { x: p.x + dx, y: p.y + dy })
	routes : List(Geom.Route)
	routes = points.map_with_index(|p, i| Line(p, points.get((i + 1) % n.max(1)) ?? p))
	shifted_routes : List(Geom.Route)
	shifted_routes = shifted.map_with_index(|p, i| Line(p, shifted.get((i + 1) % n.max(1)) ?? p))
	gap = (byte_at(bytes, 42) % 7).to_f64()
	d0 = Metrics.displacement(points, points)
	dshift = Metrics.displacement(points, shifted)
	translation_length = ((dx * dx) + (dy * dy)).sqrt()
	ok = d0 == { mean: 0, max: 0 }
		and Metrics.separation_violations(points, sizes, gap) == Metrics.separation_violations(shifted, sizes, gap)
			and Metrics.crossings(routes) == Metrics.crossings(shifted_routes)
				and Metrics.bends(routes) == 0
					and (n == 0 or ((dshift.mean - translation_length).abs() <= 0.000000001 and (dshift.max - translation_length).abs() <= 0.000000001))
	if ok {
		Fuzz.keep
	} else {
		crash "metrics violated a translation or trivial-layout identity"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-metrics",
	generator: Fuzz.list(Fuzz.u8, 44),
	test,
	show: |input| Str.inspect(input),
})
