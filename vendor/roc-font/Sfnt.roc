import Bytes

## The sfnt container: the table directory at the start of a TrueType or
## OpenType font file, collections of such fonts (`ttcf`), and checked
## access to the tables a directory lists.
##
## Internal. Every table module reads its table through `table`, `located`
## or `required`, which check that the table lies inside the file and holds
## at least the bytes its fixed header needs, and return a view of those
## bytes without copying them. Table offsets in a directory count from the
## start of the file, in a collection too, so a problem's offset is always
## a position in the file.
Sfnt :: {}.{

	## One table directory record: the table's tag as a big-endian number,
	## and its offset and length in the file.
	Table : { tag : U64, offset : U64, length : U64 }

	## A problem with a table, at a byte offset in the file.
	Bad : [BadTable({ table : Str, offset : U32 })]

	## Whether four bytes at `at` are an sfnt signature: TrueType
	## (`0x00010000` or `true`) or OpenType (`OTTO`).
	is_signature : U64 -> Bool
	is_signature = |version| version == 0x00010000 or version == 0x74727565 or version == 0x4F54544F

	## How many faces a file holds: 1 for a single font, the count of a
	## collection (`ttcf`) whose offset array fits in the file.
	face_count : List(U8) -> Try(U64, [NotAFont])
	face_count = |bytes| {
		version = Bytes.u32(bytes, 0)
		if bytes.len() >= 12 and Sfnt.is_signature(version) {
			Ok(1)
		} else if bytes.len() >= 12 and version == 0x74746366 {
			count = Bytes.u32(bytes, 8)
			if (Bytes.fits(12, 4 * count, bytes.len())) Ok(count) else Err(NotAFont)
		} else {
			Err(NotAFont)
		}
	}

	## The table records of face `face` of a file: the font itself when the
	## file is a single font (only face 0 exists), or the font a collection's
	## offset array points at.
	directory_of : List(U8), U64 -> Try(List(Table), [NotAFont, NoSuchFace({ face : U32, count : U32 })])
	directory_of = |bytes, face| {
		count = Sfnt.face_count(bytes)?
		if face >= count {
			Err(NoSuchFace({ face: face.min(0xFFFFFFFF).to_u32_wrap(), count: count.min(0xFFFFFFFF).to_u32_wrap() }))
		} else if Bytes.u32(bytes, 0) == 0x74746366 {
			Sfnt.directory_at(bytes, Bytes.u32(bytes, 12 + 4 * face))
		} else {
			Sfnt.directory_at(bytes, 0)
		}
	}

	## The table records of a single font file (not a collection).
	directory : List(U8) -> Try(List(Table), [NotAFont])
	directory = |bytes| Sfnt.directory_at(bytes, 0)

	## The table records of the font whose offset table starts at `at`.
	directory_at : List(U8), U64 -> Try(List(Table), [NotAFont])
	directory_at = |bytes, at| {
		version = Bytes.u32(bytes, at)
		count = Bytes.u16(bytes, at + 4)
		if !Bytes.fits(at, 12, bytes.len()) or !Sfnt.is_signature(version) {
			Err(NotAFont)
		} else if !Bytes.fits(at + 12, 16 * count, bytes.len()) {
			Err(NotAFont)
		} else {
			var $tables = List.with_capacity(count)
			for i in 0..<count {
				record = at + 12 + 16 * i
				$tables = $tables.append({ tag: Bytes.u32(bytes, record), offset: Bytes.u32(bytes, record + 8), length: Bytes.u32(bytes, record + 12) })
			}
			Ok($tables)
		}
	}

	## A table's bytes, checked to lie inside the file and to hold at least
	## `minimum` bytes. The first record with the tag wins.
	table : List(U8), List(Table), Str, U64 -> [Found(List(U8)), Missing, Bad]
	table = |bytes, tables, name, minimum|
		match Sfnt.located(bytes, tables, name, minimum) {
			Found(found) => Found(found.data)
			Missing => Missing
			Bad(_) => Bad
		}

	## A table's bytes and its offset in the file, checked as `table` checks
	## them; a bad table gives its offset in the file.
	located : List(U8), List(Table), Str, U64 -> [Found({ data : List(U8), offset : U64 }), Missing, Bad(U64)]
	located = |bytes, tables, name, minimum| {
		tag = Sfnt.tag_of(name)
		match tables.find_first(|t| t.tag == tag) {
			Err(_) => Missing
			Ok(t) =>
				if Bytes.fits(t.offset, t.length, bytes.len()) and t.length >= minimum {
					Found({ data: bytes.sublist({ start: t.offset, len: t.length }), offset: t.offset })
				} else {
					Bad(t.offset)
				}
		}
	}

	## A four-character table tag as the number the directory stores.
	tag_of : Str -> U64
	tag_of = |name| name.to_utf8().fold(0, |acc, b| acc * 256 + b.to_u64())

	## A problem with table `name` at byte `offset` of the file. Offsets past
	## 4 GiB (only in files larger than that) are given as the largest `U32`.
	bad : Str, U64 -> [BadTable({ table : Str, offset : U32 })]
	bad = |name, offset| BadTable({ table: name, offset: offset.min(0xFFFFFFFF).to_u32_wrap() })

	## A table the font cannot be read without, as `located` checks it.
	required : List(U8), List(Table), Str, U64 -> Try({ data : List(U8), offset : U64 }, [MissingTable(Str), BadTable({ table : Str, offset : U32 })])
	required = |bytes, tables, name, minimum|
		match Sfnt.located(bytes, tables, name, minimum) {
			Found(found) => Ok(found)
			Missing => Err(MissingTable(name))
			Bad(at) => Err(Sfnt.bad(name, at))
		}
}
