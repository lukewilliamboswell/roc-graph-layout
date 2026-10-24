import Sfnt
import Bytes

## Horizontal metrics (`hmtx`): each glyph's advance width.
##
## Internal. As the format defines, a glyph past the last long metric takes
## the advance of the last one. Left side bearings are not kept.
TableHmtx :: {}.{

	## One advance per glyph, for `count_of_glyphs` glyphs (from `maxp`) of
	## which `metric_count` (from `hhea`) have long metrics.
	from_tables : List(U8), List(Sfnt.Table), U64, U64 -> Try(List(U16), [MissingTable(Str), BadTable({ table : Str, offset : U32 })])
	from_tables = |bytes, tables, metric_count, count_of_glyphs| {
		long = metric_count.min(count_of_glyphs)
		hmtx = Sfnt.required(bytes, tables, "hmtx", 4 * long)?.data
		var $advances = List.with_capacity(count_of_glyphs)
		for g in 0..<count_of_glyphs {
			at = 4 * g.min(long - 1)
			$advances = $advances.append(Bytes.u16(hmtx, at).to_u16_wrap())
		}
		Ok($advances)
	}
}
