import Sfnt
import Bytes

## TrueType outlines (`glyf`, located through `loca`): the bounding box of
## each glyph, from the `xMin`, `yMin`, `xMax` and `yMax` of its glyph
## header. Outlines themselves are not read.
##
## Internal. A glyph with an empty or too-short entry has no box, stored as
## `x_min` greater than `x_max`. A font without both tables (CFF outlines)
## has no boxes. A `loca` too short for every glyph, or an entry that runs
## backwards or past `glyf`, makes `loca` a bad table; the problem's offset
## is the first bad entry's.
TableGlyf :: {}.{

	Bounds : { x_min : I16, y_min : I16, x_max : I16, y_max : I16 }

	none : Bounds
	none = { x_min: 1, y_min: 0, x_max: 0, y_max: 0 }

	from_tables : List(U8), List(Sfnt.Table), Bool, U64 -> Try(List(Bounds), [BadTable({ table : Str, offset : U32 })])
	from_tables = |bytes, tables, long_offsets, count_of_glyphs| {
		match (Sfnt.located(bytes, tables, "loca", 0), Sfnt.located(bytes, tables, "glyf", 0)) {
			(Bad(at), _) => Err(Sfnt.bad("loca", at))
			(_, Bad(at)) => Err(Sfnt.bad("glyf", at))
			(Found(loca_found), Found({ data: glyf, offset: _ })) => {
				loca = loca_found.data
				size = if (long_offsets) 4 else 2
				if !Bytes.fits(0, size * (count_of_glyphs + 1), loca.len()) {
					Err(Sfnt.bad("loca", loca_found.offset))
				} else {
					offset = |g| if (long_offsets) Bytes.u32(loca, 4 * g) else 2 * Bytes.u16(loca, 2 * g)
					var $boxes = List.with_capacity(count_of_glyphs)
					var $bad_at = 0
					for g in 0..<count_of_glyphs {
						start = offset(g)
						end = offset(g + 1)
						if end < start or end > glyf.len() {
							if $bad_at == 0 {
								$bad_at = loca_found.offset + size * (g + 1)
							}
							$boxes = $boxes.append(TableGlyf.none)
						} else if end - start >= 10 {
							$boxes = $boxes.append({ x_min: Bytes.i16(glyf, start + 2).to_i16_wrap(), y_min: Bytes.i16(glyf, start + 4).to_i16_wrap(), x_max: Bytes.i16(glyf, start + 6).to_i16_wrap(), y_max: Bytes.i16(glyf, start + 8).to_i16_wrap() })
						} else {
							$boxes = $boxes.append(TableGlyf.none)
						}
					}
					# A bad entry's offset is never 0: `loca` follows the directory.
					if ($bad_at != 0) Err(Sfnt.bad("loca", $bad_at)) else Ok($boxes)
				}
			}
			_ => Ok(List.repeat(TableGlyf.none, count_of_glyphs))
		}
	}
}
