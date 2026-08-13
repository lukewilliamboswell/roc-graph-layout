app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Route

byte_at = |bytes, i| bytes.get(i) ?? 0

orthogonal = |route| match route {
	Line(a, b) => a.x == b.x or a.y == b.y
	Polyline(points) => points.fold_with_index(
		True,
		|ok, a, i| match points.get(i + 1) {
			Ok(b) => ok and (a.x == b.x or a.y == b.y)
			Err(_) => ok
		},
	)
	Curves(_) => False
}

finite_route = |route| match route {
	Line(a, b) => F64.is_finite(a.x) and F64.is_finite(a.y) and F64.is_finite(b.x) and F64.is_finite(b.y)
	Polyline(points) => points.all(|p| F64.is_finite(p.x) and F64.is_finite(p.y))
	Curves(_) => False
}

test = |bytes| {
	n = (byte_at(bytes, 0) % 8).to_u64()
	nodes = List.repeat({ width: 0.0, height: 0.0 }, n).map_with_index(|_, i| { width: (byte_at(bytes, 1 + i) % 31).to_f64(), height: (byte_at(bytes, 9 + i) % 31).to_f64() })
	positions = List.repeat({ x: 0.0, y: 0.0 }, n).map_with_index(|_, i| { x: (byte_at(bytes, 17 + i) % 101).to_f64(), y: (byte_at(bytes, 25 + i) % 101).to_f64() })
	edge_count = if n == 0 {
		0
	} else {
		(byte_at(bytes, 33) % 12).to_u64()
	}
	edges = List.repeat({ from: 0, to: 0 }, edge_count).map_with_index(|_, i| { from: byte_at(bytes, 34 + i * 2).to_u64() % n, to: byte_at(bytes, 35 + i * 2).to_u64() % n })
	input = { ..Route.default_input, graph: { nodes, edges }, positions }
	match (Route.orthogonal(input, Route.default_settings), Route.prepare(input, Route.default_settings)) {
		(Ok(a), Ok(prepared)) => {
			b = Route.orthogonal_prepared(prepared)
			if a == b and a.layout.routes.len() == edges.len() and a.layout.routes.all(|r| orthogonal(r) and finite_route(r)) and Route.orthogonal(input, Route.default_settings) == Ok(a) {
				Fuzz.keep
			} else {
				crash "orthogonal route contract failed"
			}
		}
		_ => crash "valid generated routing input was rejected"
	}
}

target = Fuzz.target_with({ name: "graph-layout-route", generator: Fuzz.list(Fuzz.u8, 64), test, show: |input| Str.inspect(input) })
