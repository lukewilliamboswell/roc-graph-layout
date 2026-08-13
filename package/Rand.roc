import Random

## Internal deterministic pseudo-random number generator.
##
## All randomness in this package derives from an explicit seed threaded
## through this generator, and the output stream is frozen within a major
## version: the same seed produces the same bits in every release until the
## next major version bump.
##
## This is a thin adapter over the roc-random package
## (https://github.com/kili-ilo/roc-random) — PCG-RXS-M-XS on 32-bit state
## — currently consumed as the vendored `Random` module (see that file's
## header), to be swapped for a real dependency once a new-syntax release
## bundle ships. The frozen-stream test below pins the underlying stream,
## so the swap is observable-behavior neutral or it does not happen.
Rand :: {}.{

	State : Random.State

	## Seed the generator on roc-random's default stream.
	seed : U32 -> Random.State
	seed = |initial| Random.seed(initial)

	## One PCG step: the permuted 32-bit output and the advanced state.
	step_u32 : Random.State -> { value : U32, state : Random.State }
	step_u32 = |state| Random.step(state, Random.u32)

	## Uniform in [0, 1): a 53-bit mantissa built from two steps (the first
	## step's high 27 bits and the second step's high 26 bits), so the
	## representable doubles are dense across the unit interval.
	step_unit_f64 : Random.State -> { value : F64, state : Random.State }
	step_unit_f64 = |state| {
		first = Rand.step_u32(state)
		second = Rand.step_u32(first.state)
		high = first.value.shr_zf_wrap(5).to_u64()
		low = second.value.shr_zf_wrap(6).to_u64()
		mantissa = high.shl_wrap(26).bitwise_or(low)
		{ value: mantissa.to_f64() / 9_007_199_254_740_992, state: second.state }
	}

	## Uniform in [min, max] inclusive via one step and a rejection-free
	## scaled mapping (`output * span >> 32` in 64-bit arithmetic). The
	## mapping carries a bias of at most `span / 2^32` per value, which is
	## negligible for the small index ranges the layouts draw from. If
	## `min > max` the bounds are swapped deterministically.
	step_bounded_u32 : Random.State, U32, U32 -> { value : U32, state : Random.State }
	step_bounded_u32 = |state, min, max| {
		low = min.min(max)
		high = min.max(max)
		result = Rand.step_u32(state)
		if high - low == 4_294_967_295 {
			result
		} else {
			span = (high - low + 1).to_u64()
			offset = result.value.to_u64() * span
			{ value: low + offset.shr_zf_wrap(32).to_u32_wrap(), state: result.state }
		}
	}
}

## frozen: determinism contract — do not update these without a major version bump
expect {
	first = Rand.step_u32(Rand.seed(42))
	second = Rand.step_u32(first.state)
	third = Rand.step_u32(second.state)
	first.value == 627_790_679 and second.value == 2_783_948_082 and third.value == 386_627_632
}

## The same seed produces the same sequence: two independent runs agree on
## the first four outputs.
expect {
	run = |initial| {
		a = Rand.step_u32(Rand.seed(initial))
		b = Rand.step_u32(a.state)
		c = Rand.step_u32(b.state)
		d = Rand.step_u32(c.state)
		[a.value, b.value, c.value, d.value]
	}
	run(1234) == run(1234)
}

## Different seeds produce different first outputs.
expect Rand.step_u32(Rand.seed(42)).value != Rand.step_u32(Rand.seed(43)).value
expect Rand.step_u32(Rand.seed(0)).value != Rand.step_u32(Rand.seed(1)).value

## Unit doubles stay in [0, 1) across 20 consecutive steps from a fixed seed.
expect {
	checked = U32.range_exclusive(0, 20).fold(
		{ state: Rand.seed(99), ok: True },
		|acc, _| {
			step = Rand.step_unit_f64(acc.state)
			{ state: step.state, ok: acc.ok and step.value >= 0 and step.value < 1 }
		},
	)
	checked.ok
}

## Bounded outputs stay within [min, max] across consecutive steps.
expect {
	checked = U32.range_exclusive(0, 20).fold(
		{ state: Rand.seed(5), ok: True },
		|acc, _| {
			step = Rand.step_bounded_u32(acc.state, 3, 11)
			{ state: step.state, ok: acc.ok and step.value >= 3 and step.value <= 11 }
		},
	)
	checked.ok
}

## A collapsed range always returns its single value, and its consumed step
## advances the stream: the next full-range output is the seed's second
## output, not its first.
expect {
	step = Rand.step_bounded_u32(Rand.seed(8), 6, 6)
	fresh = Rand.step_u32(Rand.seed(8))
	after = Rand.step_u32(step.state)
	step.value == 6 and after.value != fresh.value
}

## Swapped bounds behave as if they were given in order.
expect {
	forward = Rand.step_bounded_u32(Rand.seed(21), 2, 9)
	backward = Rand.step_bounded_u32(Rand.seed(21), 9, 2)
	forward == backward
}
