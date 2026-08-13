import Host

## Benchmark-only measurement boundary. Fixture construction and result
## fingerprinting deliberately happen outside this interval.
Measure := [].{
	start! : {} => U8
	start! = |_| Host.measure_start!({})

	## Stops the active interval and returns one JSON object without its final
	## closing brace. The caller appends case metadata and the result digest.
	finish! : U64 => Str
	finish! = |observation| Host.measure_finish!(observation)
}
