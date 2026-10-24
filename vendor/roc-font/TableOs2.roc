import Sfnt
import Bytes

## The OS/2 and Windows metrics table (`OS/2`): the typographic and Windows
## ascent, descent and line gap, whether the font asks for the typographic
## ones (`USE_TYPO_METRICS`), the strikeout's size and position, and, from
## version 2, the x height and cap height. The table is optional.
##
## Internal.
TableOs2 :: {}.{

	## `heights` is `Absent` before version 2 (or in a table too short for
	## the version 2 fields), where the font stores neither height.
	Metrics : {
		use_typo : Bool,
		typo_ascent : I32,
		typo_descent : I32,
		typo_line_gap : I32,
		win_ascent : I32,
		win_descent : I32,
		strikeout_size : I32,
		strikeout_position : I32,
		heights : [Present({ x_height : I32, cap_height : I32 }), Absent],
	}

	from_tables : List(U8), List(Sfnt.Table) -> Try([Present(Metrics), Absent], [BadTable({ table : Str, offset : U32 })])
	from_tables = |bytes, tables|
		match Sfnt.located(bytes, tables, "OS/2", 78) {
			Missing => Ok(Absent)
			Bad(at) => Err(Sfnt.bad("OS/2", at))
			Found({ data: os2, offset: _ }) => {
				i16 = |at| Bytes.i16(os2, at).to_i32_wrap()
				heights = if Bytes.u16(os2, 0) >= 2 and os2.len() >= 90 {
					Present({ x_height: i16(86), cap_height: i16(88) })
				} else {
					Absent
				}
				Ok(
					Present({
						use_typo: Bytes.u16(os2, 62).bitwise_and(0x80) != 0,
						typo_ascent: i16(68),
						typo_descent: i16(70),
						typo_line_gap: i16(72),
						win_ascent: Bytes.u16(os2, 74).to_i32_wrap(),
						win_descent: Bytes.u16(os2, 76).to_i32_wrap(),
						strikeout_size: i16(26),
						strikeout_position: i16(28),
						heights,
					}),
				)
			}
		}

	## The Windows 3.1 font page of a version 0 table (the high byte of
	## `fsSelection`), or 0 for any other table or none. It selects how a
	## symbol character map is encoded.
	font_page : List(U8), List(Sfnt.Table) -> U64
	font_page = |bytes, tables|
		match Sfnt.table(bytes, tables, "OS/2", 78) {
			Found(os2) if Bytes.u16(os2, 0) == 0 => Bytes.u16(os2, 62).bitwise_and(0xFF00)
			_ => 0
		}
}
