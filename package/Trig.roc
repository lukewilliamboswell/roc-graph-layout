## Internal fixed implementations of sine and cosine.
##
## Determinism is bit-exact across platforms, but platform math libraries
## differ in the last bits of their transcendental functions — so the package
## ships its own: argument reduction plus a Taylor kernel, using only basic
## arithmetic, which the floating-point standard specifies exactly.
Trig :: {}.{
	tau : F64
	tau = 6.283185307179586

	## Nearest integer as an F64, halves toward positive infinity — used only
	## for argument reduction, where the tie direction merely picks which of
	## two equivalent reductions runs.
	round_to_nearest : F64 -> F64
	round_to_nearest = |x| (x + 0.5).div_floor_by(1)

	## Taylor kernel for sine on roughly [-pi/2, pi/2], through the x^21
	## term, which is below one part in 10^16 of the result on that range.
	sin_kernel : F64 -> F64
	sin_kernel = |x| {
		x2 = x * x
		term = |acc, denom| 1 - x2 * acc / denom
		# Horner evaluation of 1 - x^2/(2*3) * (1 - x^2/(4*5) * (...))
		inner = term(term(term(term(term(term(term(term(term(1, 420), 342), 272), 210), 156), 110), 72), 42), 20)
		x * (1 - x2 * inner / 6)
	}

	## Taylor kernel for cosine on roughly [0, pi/2], through the x^20 term,
	## which is below one part in 10^16 of full scale on that range. Exactly 1
	## at 0.
	cos_kernel : F64 -> F64
	cos_kernel = |x| {
		x2 = x * x
		term = |acc, denom| 1 - x2 * acc / denom
		# Horner evaluation of 1 - x^2/(1*2) * (1 - x^2/(3*4) * (...))
		inner = term(term(term(term(term(term(term(term(term(1, 380), 306), 240), 182), 132), 90), 56), 30), 12)
		1 - x2 * inner / 2
	}

	## Reduce an angle in radians to [-pi, pi] by subtracting whole turns.
	reduce_turn : F64 -> F64
	reduce_turn = |theta| theta - Trig.round_to_nearest(theta / Trig.tau) * Trig.tau

	## Sine of an angle in radians. Finite input produces finite output;
	## non-finite input is the caller's bug and still returns a defined NaN.
	sin : F64 -> F64
	sin = |theta| {
		t = Trig.reduce_turn(theta)
		half_pi = Trig.tau / 4
		# Fold [-pi, pi] onto [-pi/2, pi/2]: sine is symmetric about pi/2.
		folded = if t > half_pi {
			2 * half_pi - t
		} else if t < 0 - half_pi {
			0 - 2 * half_pi - t
		} else {
			t
		}
		Trig.sin_kernel(folded)
	}

	## Cosine of an angle in radians, under the same guarantees as `sin`.
	cos : F64 -> F64
	cos = |theta| {
		t = Trig.reduce_turn(theta).abs()
		half_pi = Trig.tau / 4
		# Fold [0, pi] onto [0, pi/2]: cosine is antisymmetric about pi/2.
		if t > half_pi {
			0 - Trig.cos_kernel(2 * half_pi - t)
		} else {
			Trig.cos_kernel(t)
		}
	}
}

## The kernel reproduces exact anchor values.
expect Trig.sin(0) == 0
expect Trig.cos(0) == 1

## A quarter turn is exact to within one part in 10^15.
expect (Trig.sin(Trig.tau / 4) - 1).abs() < 1e-15
expect Trig.cos(Trig.tau / 2) + 1 < 1e-15 and Trig.cos(Trig.tau / 2) + 1 > -1e-15

## Reduction handles angles beyond one turn and negative angles.
expect (Trig.sin(Trig.tau + 1) - Trig.sin(1)).abs() < 1e-15
expect (Trig.sin(0 - 1) + Trig.sin(1)).abs() < 1e-15
