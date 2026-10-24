## Big-endian fields of font data, read at a byte offset. A field that runs
## past the end of the data reads as zero bytes there; readers check every
## offset with `fits` before they rely on what they read.
Bytes :: {}.{

	u8 : List(U8), U64 -> U64
	u8 = |bytes, at| (bytes.get(at) ?? 0).to_u64()

	u16 : List(U8), U64 -> U64
	u16 = |bytes, at| Bytes.u8(bytes, at) * 256 + Bytes.u8(bytes, at + 1)

	i16 : List(U8), U64 -> I64
	i16 = |bytes, at| {
		v = Bytes.u16(bytes, at).to_i64_wrap()
		if (v >= 32768) v - 65536 else v
	}

	u32 : List(U8), U64 -> U64
	u32 = |bytes, at| Bytes.u16(bytes, at) * 65536 + Bytes.u16(bytes, at + 2)

	## Whether `len` bytes from `start` lie inside data of `size` bytes.
	fits : U64, U64, U64 -> Bool
	fits = |start, len, size| start <= size and len <= size - start

	## The bytes from `start` to the end, without copying them.
	rest : List(U8), U64 -> List(U8)
	rest = |bytes, start| if (start >= bytes.len()) [] else bytes.sublist({ start, len: bytes.len() - start })
}
