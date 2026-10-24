## Number formatting and arithmetic for the benchmark summaries.
##
## The summaries print ratios and durations with a fixed number of decimals.
## These are formatted from the exact binary value of each `F64`, rounding
## half to even, which is what `"%.3f"` prints in C and Python, so a summary
## does not depend on the language that wrote it.
BenchFormat := [].{

	## `value` with exactly `decimals` digits after the point, as `%.Nf`
	## prints it: negative values, including those that round to zero, keep
	## their sign.
	fixed : F64, U64 -> Str
	fixed = |value, decimals| {
		bits = value.to_bits()
		negative = bits.shr_zf_wrap(63) == 1
		sign = if (negative) "-" else ""
		match magnitude(bits) {
			Finite({ mantissa, exponent }) => "${sign}${with_point(scaled(mantissa, exponent, decimals), decimals)}"
			Infinite => "${sign}inf"
			NotANumber => "nan"
		}
	}

	## Like `fixed`, with a leading `+` on values that are not negative, as
	## `%+.Nf` prints them.
	signed : F64, U64 -> Str
	signed = |value, decimals| {
		text = BenchFormat.fixed(value, decimals)
		if (text.starts_with("-") or text == "nan") text else "+${text}"
	}

	## The natural logarithm of a positive, finite `value`.
	ln : F64 -> F64
	ln = |value| {
		bits = value.to_bits()
		exponent_bits = bits.shr_zf_wrap(52).bitwise_and(0x7FF)
		if exponent_bits == 0 {
			# Subnormal: scale into the normal range first.
			BenchFormat.ln(value * 18014398509481984.0) - 54.0 * ln2
		} else {
			# value = mantissa * 2^power, with mantissa in [1, 2).
			mantissa = F64.from_bits(bits.bitwise_and(0x000F_FFFF_FFFF_FFFF).bitwise_or(0x3FF0_0000_0000_0000))
			power = exponent_bits.to_i64_wrap() - 1023
			# Centre the mantissa on 1 so the series below converges quickly.
			{ m, p } = if (mantissa > 1.4142135623730951) { m: mantissa / 2.0, p: power + 1 } else { m: mantissa, p: power }
			s = (m - 1.0) / (m + 1.0)
			2.0 * atanh_series(s, s * s) + p.to_f64() * ln2
		}
	}

	## The median of `values`, truncated to an integer as `int(median(...))`
	## does: the mean of the two middle values when there is an even number.
	median : List(U64) -> U64
	median = |values| {
		sorted = List.sort_with(values, |a, b| if (a < b) Before else if (a > b) After else Same)
		count = sorted.len()
		if count == 0 {
			0
		} else if count % 2 == 1 {
			sorted.get(count // 2) ?? 0
		} else {
			low = sorted.get(count // 2 - 1) ?? 0
			high = sorted.get(count // 2) ?? 0
			(low.to_u128() + high.to_u128()).div_trunc_by(2).to_u64_wrap()
		}
	}

	## One CSV record, quoting a field only when it must be, followed by the
	## CRLF that CSV records end with.
	csv_record : List(Str) -> Str
	csv_record = |fields| "${Str.join_with(fields.map(csv_field), ",")}\r\n"

	## A list of names as Python prints a list of strings, for messages that
	## name fields.
	python_list : List(Str) -> Str
	python_list = |names| "[${Str.join_with(names.map(|name| "'${name}'"), ", ")}]"
}

ln2 : F64
ln2 = 0.6931471805599453

# s + s^3/3 + s^5/5 + ... for |s| <= 0.172, which is atanh(s).
atanh_series : F64, F64 -> F64
atanh_series = |s, s2| {
	var $term = s
	var $sum = 0.0
	var $n = 1.0
	for _ in 0.U64..<40 {
		$sum = $sum + $term / $n
		$term = $term * s2
		$n = $n + 2.0
	}
	$sum
}

magnitude : U64 -> [Finite({ mantissa : U128, exponent : I64 }), Infinite, NotANumber]
magnitude = |bits| {
	exponent_bits = bits.shr_zf_wrap(52).bitwise_and(0x7FF)
	fraction = bits.bitwise_and(0x000F_FFFF_FFFF_FFFF)
	if exponent_bits == 0x7FF {
		if (fraction == 0) Infinite else NotANumber
	} else if exponent_bits == 0 {
		Finite({ mantissa: fraction.to_u128(), exponent: -1074 })
	} else {
		Finite({ mantissa: fraction.bitwise_or(0x0010_0000_0000_0000).to_u128(), exponent: exponent_bits.to_i64_wrap() - 1075 })
	}
}

# round_half_even(mantissa * 2^exponent * 10^decimals), exactly.
scaled : U128, I64, U64 -> U128
scaled = |mantissa, exponent, decimals| {
	numerator = mantissa * (10.U128).pow(decimals.to_u128())
	if exponent >= 0 {
		numerator.shl_wrap(exponent.to_u64_wrap().to_u8_wrap())
	} else {
		shift = (0 - exponent).to_u64_wrap()
		if shift >= 120 {
			# The numerator is below 2^74, far under half of 2^shift.
			0
		} else {
			k = shift.to_u8_wrap()
			quotient = numerator.shr_zf_wrap(k)
			remainder = numerator - quotient.shl_wrap(k)
			half = (1.U128).shl_wrap(k - 1)
			if (remainder > half or (remainder == half and quotient % 2 == 1)) quotient + 1 else quotient
		}
	}
}

# The digits of `scaled` with a point `decimals` places from the right.
with_point : U128, U64 -> Str
with_point = |value, decimals| {
	digits = value.to_str()
	padded = Str.concat(Str.repeat("0", (decimals + 1) - Str.count_utf8_bytes(digits).min(decimals + 1)), digits)
	if decimals == 0 {
		padded
	} else {
		bytes = Str.to_utf8(padded)
		split = bytes.len() - decimals
		whole = Str.from_utf8_lossy(bytes.take_first(split))
		fraction = Str.from_utf8_lossy(bytes.drop_first(split))
		"${whole}.${fraction}"
	}
}

csv_field : Str -> Str
csv_field = |field|
	if field.contains(",") or field.contains("\"") or field.contains("\n") or field.contains("\r") {
		"\"${Str.replace_each(field, "\"", "\"\"")}\""
	} else {
		field
	}

expect BenchFormat.fixed(1.5, 3) == "1.500"
expect BenchFormat.fixed(0.0005, 3) == "0.001"
expect BenchFormat.fixed(0.0625, 3) == "0.062"
expect BenchFormat.fixed(0.0675, 1) == "0.1"
expect BenchFormat.fixed(2.675, 2) == "2.67"
expect BenchFormat.fixed(123456.0, 3) == "123456.000"
expect BenchFormat.fixed(-0.0001, 3) == "-0.000"
expect BenchFormat.fixed(-2.5, 0) == "-2"
expect BenchFormat.fixed(338006.0 / 1000000.0, 3) == "0.338"
expect BenchFormat.fixed(40696.0 / 1048576.0, 3) == "0.039"
expect BenchFormat.fixed(1.0 / 3.0, 3) == "0.333"
expect BenchFormat.signed(0.0, 1) == "+0.0"
expect BenchFormat.signed(12.34, 1) == "+12.3"
expect BenchFormat.signed(-12.36, 1) == "-12.4"
expect BenchFormat.fixed(F64.infinity, 3) == "inf"
expect (BenchFormat.ln(1.0)).abs() < 1e-15
expect (BenchFormat.ln(F64.e) - 1.0).abs() < 1e-15
expect (BenchFormat.ln(1000.0) - 6.907755278982137).abs() < 1e-12
expect (BenchFormat.ln(0.001) + 6.907755278982137).abs() < 1e-12
expect BenchFormat.fixed(BenchFormat.ln(4.0) / BenchFormat.ln(2.0), 3) == "2.000"
expect BenchFormat.median([5, 1, 3]) == 3
expect BenchFormat.median([338006, 181647]) == 259826
expect BenchFormat.median([]) == 0
expect BenchFormat.csv_record(["a", "b,c", "d\"e"]) == "a,\"b,c\",\"d\"\"e\"\r\n"
expect BenchFormat.python_list(["a", "b"]) == "['a', 'b']"
