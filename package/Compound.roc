import Pack

## Compound-graph composition for nested groups.
Compound :: {}.{

	## Naive compound baseline: treat completed child layouts as boxes and pack them.
	##
	## TODO: Define recursive groups whose interiors name a family, algorithm,
	## and configuration. Lay out innermost groups first, derive padded outer
	## sizes, compose transforms through every nesting level, and split boundary-
	## crossing routes into stable inner/outer segments. Validate membership and
	## group cycles once during build and preserve source-aligned output indices.
	pack_groups : List({ width : F64, height : F64 }),
	F64 -> {
		positions : List({ x : F64, y : F64 }),
		bounds : { x : F64, y : F64, width : F64, height : F64 },
	}
	pack_groups = |groups, gap| Pack.row(groups, gap)
}

## Compound baseline packs completed child boxes through the shared pass.
expect Compound.pack_groups([{ width: 3, height: 2 }], 4).bounds == {
	x: 0,
	y: 0,
	width: 3,
	height: 2,
}
