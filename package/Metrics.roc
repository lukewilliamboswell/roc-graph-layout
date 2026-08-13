## Public measurements for comparing layout quality.
Metrics :: {}.{
	## Area of normalized layout bounds.
	##
	## TODO: Add exact crossing count with a documented sampled mode at scale,
	## graph-distance stress, bend count, aspect ratio, minimum-separation
	## violations, and displacement from a reference layout. Metrics must remain
	## algorithm-independent so consumers and regression tests can compare any
	## two layouts with the same vocabulary.
	area : { x : F64, y : F64, width : F64, height : F64 } -> F64
	area = |bounds| bounds.width * bounds.height
}

## Area multiplies the normalized bounding-box extents.
expect Metrics.area({ x: 0, y: 0, width: 8, height: 5 }) == 40
