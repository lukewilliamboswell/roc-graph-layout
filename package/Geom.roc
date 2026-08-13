## Geometry shared by every layout family.
Geom :: {}.{
	point : F64, F64 -> { x : F64, y : F64 }
	point = |x, y| { x, y }

	empty_bounds : { x : F64, y : F64, width : F64, height : F64 }
	empty_bounds = { x: 0, y: 0, width: 0, height: 0 }
}

## The empty bounding box starts at the origin.
expect Geom.empty_bounds == { x: 0, y: 0, width: 0, height: 0 }
