import Sfnt
import Bytes

## The maximum profile (`maxp`): how many glyphs the font has.
##
## Internal. A font with no glyphs is refused.
TableMaxp :: {}.{

	from_tables : List(U8), List(Sfnt.Table) -> Try(U64, [MissingTable(Str), BadTable({ table : Str, offset : U32 })])
	from_tables = |bytes, tables| {
		found = Sfnt.required(bytes, tables, "maxp", 6)?
		count = Bytes.u16(found.data, 4)
		if (count == 0) Err(Sfnt.bad("maxp", found.offset + 4)) else Ok(count)
	}
}
