app [target] { fuzz: platform "https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.2.1/9Qpttb6LTgcMaVsSBLsnaiS2mDUrf6Bxa6dX9Rqwviz4.tar.zst" }

import fuzz.Fuzz
import Route

byte_at = |bytes, i| bytes.get(i) ?? 0

test = |bytes| {
	n = (byte_at(bytes, 0) % 13).to_u64()
	endpoints = List.repeat({}, n).map_with_index(
		|_, i| {
			from: { x: (byte_at(bytes, 1 + i * 4) % 41).to_f64() - 20, y: (byte_at(bytes, 2 + i * 4) % 41).to_f64() - 20 },
			to: { x: (byte_at(bytes, 3 + i * 4) % 41).to_f64() - 20, y: (byte_at(bytes, 4 + i * 4) % 41).to_f64() - 20 },
		},
	)
	dx = (byte_at(bytes, 54) % 21).to_f64() - 10
	dy = (byte_at(bytes, 55) % 21).to_f64() - 10
	shifted = endpoints.map(|e| { from: { x: e.from.x + dx, y: e.from.y + dy }, to: { x: e.to.x + dx, y: e.to.y + dy } })
	expected = Route.straight(endpoints).map(|e| { from: { x: e.from.x + dx, y: e.from.y + dy }, to: { x: e.to.x + dx, y: e.to.y + dy } })
	if Route.straight(endpoints) == endpoints and Route.straight(shifted) == expected {
		Fuzz.keep
	} else {
		crash "straight routing changed order, endpoints, self-loops, parallel edges, or translation"
	}
}

target = Fuzz.target_with({
	name: "graph-layout-route",
	generator: Fuzz.list(Fuzz.u8, 56),
	test,
	show: |input| Str.inspect(input),
})
