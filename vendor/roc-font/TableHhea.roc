import Sfnt
import Bytes

## The horizontal header (`hhea`): ascender, descender, line gap, and how
## many glyphs have their own advance width in `hmtx` (`numberOfHMetrics`).
##
## Internal. A font with no long horizontal metrics is refused, since every
## glyph's advance comes from one.
TableHhea :: {}.{

	Hhea : { ascent : I32, descent : I32, line_gap : I32, metric_count : U64 }

	from_tables : List(U8), List(Sfnt.Table) -> Try(Hhea, [MissingTable(Str), BadTable({ table : Str, offset : U32 })])
	from_tables = |bytes, tables| {
		found = Sfnt.required(bytes, tables, "hhea", 36)?
		hhea = found.data
		count = Bytes.u16(hhea, 34)
		if count == 0 {
			Err(Sfnt.bad("hhea", found.offset + 34))
		} else {
			Ok({ ascent: Bytes.i16(hhea, 4).to_i32_wrap(), descent: Bytes.i16(hhea, 6).to_i32_wrap(), line_gap: Bytes.i16(hhea, 8).to_i32_wrap(), metric_count: count })
		}
	}
}
