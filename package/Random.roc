## VENDORED from the sibling checkout of roc-random
## (https://github.com/kili-ilo/roc-random), migrated to the new compiler
## syntax. This file is a temporary stand-in for a real package dependency:
## bare-module `roc test` cannot resolve package shorthands, and no
## new-syntax release bundle exists yet. When one ships, delete this file,
## add `rand: "<bundle-url>"` to package/main.roc, and change Rand.roc's
## import to `rand.Random` — the frozen-stream test in Rand.roc pins the
## stream, so the swap is observable-behavior neutral. Keep this file in
## sync with the sibling; do not patch it independently.
## ## PCG algorithms, constants, and wrappers
##
## For more information about PCG see [www.pcg-random.org](https://www.pcg-random.org)
##
## > PCG is a family of simple fast space-efficient statistically good algorithms for random number generation.
##
Random := [].{

	# This implementation is based on this paper [PCG: A Family of Simple Fast Space-Efficient Statistically Good Algorithms for Random Number Generation](https://www.pcg-random.org/pdf/hmc-cs-2014-0905.pdf)
	# and this C++ header: [pcg_variants.h](https://github.com/imneme/pcg-c/blob/master/include/pcg_variants.h).
	#
	# Original Roc implementation by [JanCVanB](https://github.com/JanCVanB), January 2022
	#
	# Abbreviations:
	# - M = Multiplication (see section 6.3.4 on page 45 in the paper)
	# - PCG = Permuted Congruential Generator
	# - RXS = Random XorShift (see section 5.5.1 on page 36 in the paper)
	# - XS = XorShift (see section 5.5 on page 34 in the paper)

	## A generator that produces pseudorandom `value`s using the PCG algorithm.
	##
	## ```
	## rgb_generator : Generator({ red : U8, green : U8, blue : U8 })
	## rgb_generator =
	##     Random.chain(
	##         Random.chain(Random.u8, Random.u8, |red, green| { red, green }),
	##         Random.u8,
	##         |rg, blue| { red: rg.red, green: rg.green, blue },
	##     )
	## ```
	Generator(value) : State -> Generation(value)

	## A pseudorandom value, paired with its [Generator]'s output state.
	##
	## This is required to chain multiple calls together passing the updated state.
	Generation(value) : { value : value, state : State }

	## Internal state for Generators
	State :: { s : U32, c : AlgorithmConstants }

	# only used internally
	AlgorithmConstants : {
		permute_multiplier : U32,
		permute_random_xor_shift : U32,
		permute_random_xor_shift_increment : U32,
		permute_xor_shift : U32,
		update_increment : U32,
		update_multiplier : U32,
	}

	## Construct an initial "seed" [State] for [Generator]s
	seed : U32 -> State
	seed = |s| seed_variant(s, default_u32_update_increment)

	## Construct a specific "variant" of a "seed" for more advanced use.
	##
	## A "seed" is an initial [State] for [Generator]s.
	##
	## A "variant" is a [State] that specifies a `c.updateIncrement` constant,
	## to produce a sequence of internal `value`s that shares no consecutive pairs
	## with other variants of the same [State].
	##
	## Odd numbers are recommended for the update increment,
	## to double the repetition period of sequences (by hitting odd values).
	seed_variant : U32, U32 -> State
	seed_variant = |s, u_i| {
		c = {
			permute_multiplier: default_u32_permute_multiplier,
			permute_random_xor_shift: default_u32_permute_random_xor_shift,
			permute_random_xor_shift_increment: default_u32_permute_random_xor_shift_increment,
			permute_xor_shift: default_u32_permute_xor_shift,
			update_increment: u_i,
			update_multiplier: default_u32_update_multiplier,
		}

		# Seed the way the referenced PCG C header does (`pcg_oneseq_32_srandom_r`):
		# start from zero, step once, add the seed, then step again.
		initial = update(State.({ s: 0, c }))

		update(State.({ s: initial.s.plus_wrap(s), c }))
	}

	## Generate a [Generation] from a state
	step : State, Generator(value) -> Generation(value)
	step = |s, g| g(s)

	## Generate a new [Generation] from an old [Generation]'s state
	next : Generation(a), Generator(value) -> Generation(value)
	next = |x, g| g(x.state)

	## Create a [Generator] that always returns the same thing.
	static : value -> Generator(value)
	static = |value| {
		|state| {
			{ value, state }
		}
	}

	## Map over the value of a [Generator].
	map : Generator(a), (a -> b) -> Generator(b)
	map = |generator, mapper| {
		|state| {
			{ value, state: state2 } = generator(state)

			{ value: mapper(value), state: state2 }
		}
	}

	## Compose two [Generator]s into a single [Generator].
	##
	## ```
	## date_generator =
	##     Random.chain(
	##         Random.chain(Random.bounded_i32(1, 2500), Random.bounded_i32(1, 12), |year, month| { year, month }),
	##         Random.bounded_i32(1, 31),
	##         |ym, day| { year: ym.year, month: ym.month, day },
	##     )
	## ```
	chain : Generator(a), Generator(b), (a, b -> c) -> Generator(c)
	chain = |first_generator, second_generator, combiner| {
		|state| {
			{ value: first, state: state2 } = first_generator(state)
			{ value: second, state: state3 } = second_generator(state2)

			{ value: combiner(first, second), state: state3 }
		}
	}

	## Generate a list of random values.
	## ```
	## generate_10_random_u8s : Generator(List(U8))
	## generate_10_random_u8s =
	##     Random.list(Random.u8, 10)
	## ```
	# Note: the length argument was `Int *` under the old compiler; the new
	# compiler needs a concrete type here, so it is narrowed to `U64` (the
	# compiler's list-length type).
	list : Generator(a), U64 -> Generator(List(a))
	list = |generator, length| {
		|initial_state| {
			var $state = initial_state
			var $values = List.with_capacity(length)

			for _ in 0..<length {
				generation = generator($state)
				$state = generation.state
				$values = $values.append(generation.value)
			}

			{ value: $values, state: $state }
		}
	}

	## Construct a [Generator] for 8-bit unsigned integers
	u8 : Generator(U8)
	u8 = between_u8(U8.lowest, U8.highest)

	## Construct a [Generator] for 8-bit unsigned integers between two boundaries (inclusive)
	bounded_u8 : U8, U8 -> Generator(U8)
	bounded_u8 = |x, y| between_u8(x, y)

	## Construct a [Generator] for 8-bit signed integers
	i8 : Generator(I8)
	i8 = {
		(minimum, maximum) = (I8.lowest, I8.highest)
		# TODO: Remove these `I64` dependencies.
		range = maximum.to_i64() - minimum.to_i64() + 1
		|state| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			offset = (map_to_i32(permute(state)).to_i64() - I8.lowest.to_i64()).rem_by(range)
			value = (minimum.to_i64() + offset).to_i8_wrap()
			{ value, state: update(state) }
		}
	}

	## Construct a [Generator] for 8-bit signed integers between two boundaries (inclusive)
	bounded_i8 : I8, I8 -> Generator(I8)
	bounded_i8 = |x, y| {
		(minimum, maximum) = sort(x, y)
		# TODO: Remove these `I64` dependencies.
		range = maximum.to_i64() - minimum.to_i64() + 1
		|state| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			offset = (map_to_i32(permute(state)).to_i64() - I8.lowest.to_i64()).rem_by(range)
			value = (minimum.to_i64() + offset).to_i8_wrap()
			{ value, state: update(state) }
		}
	}

	## Construct a [Generator] for 16-bit unsigned integers
	u16 : Generator(U16)
	u16 = between_u16(U16.lowest, U16.highest)

	## Construct a [Generator] for 16-bit unsigned integers between two boundaries (inclusive)
	bounded_u16 : U16, U16 -> Generator(U16)
	bounded_u16 = |x, y| between_u16(x, y)

	## Construct a [Generator] for 16-bit signed integers
	i16 : Generator(I16)
	i16 = {
		(minimum, maximum) = (I16.lowest, I16.highest)
		# TODO: Remove these `I64` dependencies.
		range = maximum.to_i64() - minimum.to_i64() + 1
		|state| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			offset = (map_to_i32(permute(state)).to_i64() - I16.lowest.to_i64()).rem_by(range)
			value = (minimum.to_i64() + offset).to_i16_wrap()
			{ value, state: update(state) }
		}
	}

	## Construct a [Generator] for 16-bit signed integers between two boundaries (inclusive)
	bounded_i16 : I16, I16 -> Generator(I16)
	bounded_i16 = |x, y| {
		(minimum, maximum) = sort(x, y)
		# TODO: Remove these `I64` dependencies.
		range = maximum.to_i64() - minimum.to_i64() + 1
		|state| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			offset = (map_to_i32(permute(state)).to_i64() - I16.lowest.to_i64()).rem_by(range)
			value = (minimum.to_i64() + offset).to_i16_wrap()
			{ value, state: update(state) }
		}
	}

	## Construct a [Generator] for 32-bit unsigned integers
	u32 : Generator(U32)
	u32 = between_u32(U32.lowest, U32.highest)

	## Construct a [Generator] for 32-bit unsigned integers between two boundaries (inclusive)
	bounded_u32 : U32, U32 -> Generator(U32)
	bounded_u32 = |x, y| between_u32(x, y)

	## Construct a [Generator] for 32-bit signed integers
	i32 : Generator(I32)
	i32 = {
		(minimum, maximum) = (I32.lowest, I32.highest)
		# TODO: Remove these `I64` dependencies.
		range = maximum.to_i64() - minimum.to_i64() + 1
		|state| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			offset = (map_to_i32(permute(state)).to_i64() - I32.lowest.to_i64()).rem_by(range)
			value = (minimum.to_i64() + offset).to_i32_wrap()
			{ value, state: update(state) }
		}
	}

	## Construct a [Generator] for 32-bit signed integers between two boundaries (inclusive)
	bounded_i32 : I32, I32 -> Generator(I32)
	bounded_i32 = |x, y| {
		(minimum, maximum) = sort(x, y)
		# TODO: Remove these `I64` dependencies.
		range = maximum.to_i64() - minimum.to_i64() + 1
		|state| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			offset = (map_to_i32(permute(state)).to_i64() - I32.lowest.to_i64()).rem_by(range)
			value = (minimum.to_i64() + offset).to_i32_wrap()
			{ value, state: update(state) }
		}
	}

	# Helpers for the above constructors -------------------------------------------

	# These were a single `between_unsigned : Int a, Int a -> Generator (Int a)`
	# under the old compiler; the new compiler needs concrete integer types, so
	# there is one helper per unsigned width. Semantics are unchanged: the
	# permuted U32 is truncated to the target width before the range is applied.
	between_u8 : U8, U8 -> Generator(U8)
	between_u8 = |x, y| {
		(minimum, maximum) = sort(x, y)
		range = (maximum - minimum).plus_try(1)

		|s| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			value = match range {
				Ok(r) => minimum + (permute(s).to_u8_wrap() % r)
				Err(_) => permute(s).to_u8_wrap()
			}
			state = update(s)

			{ value, state }
		}
	}

	between_u16 : U16, U16 -> Generator(U16)
	between_u16 = |x, y| {
		(minimum, maximum) = sort(x, y)
		range = (maximum - minimum).plus_try(1)

		|s| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			value = match range {
				Ok(r) => minimum + (permute(s).to_u16_wrap() % r)
				Err(_) => permute(s).to_u16_wrap()
			}
			state = update(s)

			{ value, state }
		}
	}

	between_u32 : U32, U32 -> Generator(U32)
	between_u32 = |x, y| {
		(minimum, maximum) = sort(x, y)
		range = (maximum - minimum).plus_try(1)

		|s| {
			# TODO: Analyze this. The mod-ing might be biased towards a smaller offset!
			value = match range {
				Ok(r) => minimum + (permute(s) % r)
				Err(_) => permute(s)
			}
			state = update(s)

			{ value, state }
		}
	}

	map_to_i32 : U32 -> I32
	map_to_i32 = |x| {
		middle = I32.highest.to_u32_wrap()
		if x <= middle {
			I32.lowest + x.to_i32_wrap()
		} else {
			(x - middle - 1).to_i32_wrap()
		}
	}

	sort = |x, y| {
		if x < y {
			(x, y)
		} else {
			(y, x)
		}
	}

	# See `RXS M XS` constants (line 168?)
	# and `_DEFAULT_` constants (line 276?)
	# in the PCG C++ header (see link above).
	default_u32_permute_multiplier = 277_803_737
	default_u32_permute_random_xor_shift = 28
	default_u32_permute_random_xor_shift_increment = 4
	default_u32_permute_xor_shift = 22
	default_u32_update_increment = 2_891_336_453
	default_u32_update_multiplier = 747_796_405

	# See `pcg_output_rxs_m_xs_8_8` (on line 170?) in the PCG C++ header (see link above).
	permute : State -> U32
	permute = |state| {
		pcg_rxs_m_xs(state.s, state.c.permute_random_xor_shift, state.c.permute_random_xor_shift_increment, state.c.permute_multiplier, state.c.permute_xor_shift)
	}

	# See section 6.3.4 on page 45 in the PCG paper (see link above).
	#
	# output = state
	#     |> xorshift by ((state >> random_xor_shift) + random_xor_shift_increment)
	#     |> multiply (wrapping) by multiplier
	#     |> xorshift by xor_shift
	pcg_rxs_m_xs : U32, U32, U32, U32, U32 -> U32
	pcg_rxs_m_xs = |state, random_xor_shift, random_xor_shift_increment, multiplier, xor_shift| {
		inner_shift =
			state
				.shr_zf_wrap(random_xor_shift.to_u8_wrap())
				.plus_wrap(random_xor_shift_increment)

		partial =
			state
				.bitwise_xor(state.shr_zf_wrap(inner_shift.to_u8_wrap()))
				.times_wrap(multiplier)

		partial.bitwise_xor(partial.shr_zf_wrap(xor_shift.to_u8_wrap()))
	}

	# See section 4.1 on page 20 in the PCG paper (see link above).
	pcg_step : U32, U32, U32 -> U32
	pcg_step = |state, multiplier, increment| {
		state
			.times_wrap(multiplier)
			.plus_wrap(increment)
	}

	# See `pcg_oneseq_8_step_r` (line 409?) in the PCG C++ header (see link above).
	update : State -> State
	update = |state| {
		s_new : U32
		s_new = pcg_step(state.s, state.c.update_multiplier, state.c.update_increment)

		State.({ s: s_new, c: state.c })
	}
}

expect {
	always_five = Random.static(5)

	var $all_five = True
	for seed_num in 0..<100 {
		generation = Random.step(Random.seed(seed_num), always_five)
		if generation.value != 5 {
			$all_five = False
		}
	}

	$all_five
}

expect {
	doubled_int = Random.map(Random.bounded_i32(-100, 100), |i| i * 2)

	var $all_match = True
	for seed_num in 0..<100 {
		next_seed = Random.seed(seed_num)
		rand_int = Random.step(next_seed, Random.bounded_i32(-100, 100)).value
		doubled_rand_int = Random.step(next_seed, doubled_int).value

		if rand_int * 2 != doubled_rand_int {
			$all_match = False
		}
	}

	$all_match
}

expect {
	color_component_gen = Random.bounded_i32(0, 255)
	rg_generator = Random.chain(color_component_gen, color_component_gen, |r, g| { r, g })
	rgb_generator = Random.chain(rg_generator, color_component_gen, |rg, b| { r: rg.r, g: rg.g, b })

	next_seed = Random.seed(123)
	rand_rgb = Random.step(next_seed, rgb_generator).value

	rand_rgb == { r: 235, g: 111, b: 133 }
}

## frozen stream check: PCG-RXS-M-XS, seed 42
expect {
	first = Random.step(Random.seed(42), Random.u32)
	second = Random.next(first, Random.u32)
	third = Random.next(second, Random.u32)

	first.value == 627_790_679 and second.value == 2_783_948_082 and third.value == 386_627_632
}

# Test U8 generation
expect {
	test_generator = Random.u8
	test_seed = Random.seed(123)
	actual = test_generator(test_seed)
	expected : U8
	expected = 235
	actual.value == expected
}

# Test U16 generation
expect {
	test_generator = Random.bounded_u16(0, 250)
	test_seed = Random.seed(123)
	actual = test_generator(test_seed)
	expected : U16
	expected = 149
	actual.value == expected
}

# Test U32 generation
expect {
	test_generator = Random.bounded_u32(0, 250)
	test_seed = Random.seed(123)
	actual = test_generator(test_seed)
	expected : U32
	expected = 86
	actual.value == expected
}

# Test I8 generation
expect {
	test_generator = Random.bounded_i8(0, 9)
	test_seed = Random.seed(6)
	actual = test_generator(test_seed)
	expected : I8
	expected = 1
	actual.value == expected
}

# Test I16 generation
expect {
	test_generator = Random.bounded_i16(0, 9)
	test_seed = Random.seed(6)
	actual = test_generator(test_seed)
	expected : I16
	expected = 1
	actual.value == expected
}

# Test I32 generation
expect {
	test_generator = Random.bounded_i32(10, 9)
	test_seed = Random.seed(6)
	actual = test_generator(test_seed)
	expected : I32
	expected = 10
	actual.value == expected
}
