## Internal hosted-effect boundary used by the platform wrappers.
##
## Applications should import `Stdout`, `Stderr`, and `Stdin` instead.
Host := [].{
	stderr_line! : Str => Try({}, [StderrErr(Str)])
	stdin_line! : {} => Try(Str, [StdinErr(Str)])
	measure_start! : {} => U8
	measure_finish! : U64 => Str
	stdout_line! : Str => Try({}, [StdoutErr(Str)])
}
