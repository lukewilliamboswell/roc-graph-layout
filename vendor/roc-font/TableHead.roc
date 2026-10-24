import Sfnt
import Bytes

## The font header (`head`): the size of the em square in font units, and
## whether `loca` holds long (32-bit) or short (16-bit) offsets.
##
## Internal. A units-per-em value outside 16 to 16384, the range the
## specification allows, is refused.
TableHead :: {}.{

	from_tables : List(U8), List(Sfnt.Table) -> Try({ units_per_em : U16, long_offsets : Bool }, [MissingTable(Str), BadTable({ table : Str, offset : U32 }), BadUnitsPerEm])
	from_tables = |bytes, tables| {
		head = Sfnt.required(bytes, tables, "head", 54)?.data
		units = Bytes.u16(head, 18)
		if units < 16 or units > 16384 {
			Err(BadUnitsPerEm)
		} else {
			Ok({ units_per_em: units.to_u16_wrap(), long_offsets: Bytes.i16(head, 50) == 1 })
		}
	}
}
