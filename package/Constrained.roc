import Graph

## Layouts that optimize graph geometry subject to domain constraints.
##
## TODO: Define the sparse constraint spec over node indices: minimum axial
## separation, axial alignment, band containment, and pins. Build must report
## all invalid references and contradictory rules. The family should share
## graph-distance preprocessing with `Graph.Stress` and projection machinery
## with overlap removal rather than growing independent solvers.
Constrained :: {}.{
	## Naive `Constrained.Stress` scaffold.
	##
	## TODO: Replace unconstrained row placement with alternating stress
	## majorization and exact per-axis projection. Implement incremental block
	## merging, hold pins as immovable equalities, detect infeasible constraint
	## sets during build, and report convergence without ever returning a layout
	## that violates a successfully built witness.
	stress : List({ width : F64, height : F64 }), F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	stress = |nodes, node_gap| Graph.stress(nodes, node_gap)
}

## Constrained scaffold gives every node a finite baseline position.
expect Constrained.stress([{ width: 8, height: 4 }], 2) == {
	positions: [{ x: 4, y: 2 }],
	bounds: { x: 0, y: 0, width: 8, height: 4 },
}
