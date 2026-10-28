#!/usr/bin/env roc
app [main!] {
	layout: "../package/main.roc",
	pf: platform "platform/main.roc",
}

import pf.Stdout
import Generators
import GroupedBench

## Focused native public-API control. The full benchmark runner uses the
## same fixture and measurement operation. Build with --opt=speed.
main! = |args| {
	operation = args.get(1) ?? "one_call"
	shape = args.get(2) ?? "star"
	size = U64.from_str(args.get(3) ?? "100") ?? 100
	seed = U64.from_str(args.get(4) ?? "1") ?? 1
	graph = Generators.graph(shape, size, seed)
	telemetry = GroupedBench.run!(graph, operation, seed)
	Stdout.line!("${telemetry},\"family\":\"layered_grouped\",\"operation\":\"${operation}\",\"fixture\":\"${shape}\",\"n\":${size.to_str()},\"m\":${graph.edges.len().to_str()}}")
}
