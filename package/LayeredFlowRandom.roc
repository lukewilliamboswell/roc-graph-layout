## The pseudo-random sequence the layered solver draws from: a 48-bit
## linear congruential generator, seeded the same way, so that ties it breaks
## at random are broken the same way here. A generator is a plain value;
## each draw returns the next generator with the number drawn.
LayeredFlowRandom :: {}.{

	Random : { seed : U64 }

	mask : U64
	mask = 281474976710655

	multiplier : U64
	multiplier = 25214903917

	## A generator started from `seed`, as `new Random(seed)` starts one.
	from_seed : I64 -> Random
	from_seed = |seed| { seed: seed.to_u64_wrap().bitwise_xor(LayeredFlowRandom.multiplier).bitwise_and(LayeredFlowRandom.mask) }

	## The next `bits` bits, at most 32, as a non-negative number below 2^bits.
	next_bits : Random, U64 -> (Random, U64)
	next_bits = |random, bits| {
		seed = random.seed.times_wrap(LayeredFlowRandom.multiplier).plus_wrap(11).bitwise_and(LayeredFlowRandom.mask)
		({ seed: seed }, seed.shr_zf_wrap((48 - bits).to_u8_wrap()))
	}

	next_bool : Random -> (Random, Bool)
	next_bool = |random| {
		(r, v) = LayeredFlowRandom.next_bits(random, 1)
		(r, v != 0)
	}

	## A float in [0, 1) with 24 random bits.
	next_float : Random -> (Random, F64)
	next_float = |random| {
		(r, v) = LayeredFlowRandom.next_bits(random, 24)
		(r, v.to_f64() / 16777216.0)
	}

	## A double in [0, 1) with 53 random bits.
	next_double : Random -> (Random, F64)
	next_double = |random| {
		(r1, a) = LayeredFlowRandom.next_bits(random, 26)
		(r2, b) = LayeredFlowRandom.next_bits(r1, 27)
		(r2, a.to_f64() * 1.4901161193847656e-8 + b.to_f64() * 1.1102230246251565e-16)
	}

	## A signed 64-bit number from two 32-bit draws, as `nextLong` makes one.
	next_long : Random -> (Random, I64)
	next_long = |random| {
		(r1, a) = LayeredFlowRandom.next_bits(random, 32)
		(r2, b) = LayeredFlowRandom.next_bits(r1, 32)
		high = LayeredFlowRandom.signed32(a)
		low = LayeredFlowRandom.signed32(b)
		(r2, high.shl_wrap(32).plus_wrap(low))
	}

	## A number in [0, bound) for a positive bound.
	next_int : Random, U64 -> (Random, U64)
	next_int = |random, bound|
		if bound == 0 {
			(random, 0)
		} else if bound.bitwise_and(bound.bitwise_xor(18446744073709551615).plus_wrap(1)) == bound {
			(r, v) = LayeredFlowRandom.next_bits(random, 31)
			(r, bound.times_wrap(v).shr_zf_wrap(31))
		} else {
			var $r = random
			var $result = 0
			var $searching = True
			var $guard = 0
			while $searching and $guard < 64 {
				(r, bits) = LayeredFlowRandom.next_bits($r, 31)
				$r = r
				value = bits % bound
				# Java rejects a draw whose bucket would overflow 31 bits.
				if bits - value + (bound - 1) < 2147483648 {
					$result = value
					$searching = False
				}
				$guard = $guard + 1
			}
			($r, $result)
		}

	signed32 : U64 -> I64
	signed32 = |v| if (v >= 2147483648) v.to_i64_wrap() - 4294967296 else v.to_i64_wrap()
}

## The first draws from seed 1 match Java's `new Random(1)`.
expect {
	r = LayeredFlowRandom.from_seed(1)
	(r1, a) = LayeredFlowRandom.next_bits(r, 32)
	(_, b) = LayeredFlowRandom.next_bits(r1, 32)
	LayeredFlowRandom.signed32(a) == -1155869325 and LayeredFlowRandom.signed32(b) == 431529176
}

expect {
	(_, d) = LayeredFlowRandom.next_double(LayeredFlowRandom.from_seed(1))
	(d - 0.7308781907032909).abs() < 1e-15
}

expect {
	(_, l) = LayeredFlowRandom.next_long(LayeredFlowRandom.from_seed(1))
	l == -4964420948893066024
}
