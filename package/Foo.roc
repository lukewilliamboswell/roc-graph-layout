## Placeholder type, to be replaced once the real API is designed.
Foo :: {}.{
	empty : Foo
	empty = {}

	is_eq : Foo, Foo -> Bool
	is_eq = |_left, _right| Bool.True
}

expect Foo.empty == Foo.empty
