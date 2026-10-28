## A flat Fenwick table shared by node-order and port-order crossing counts.
## Positions are zero-based; `before` excludes its upper bound. Signed
## increments support both insertion and removal of open edge ends.
PrefixCounts :: {}.{
	create : U64 -> List(I64)
	create = |size| List.repeat(0.I64, size + 1)
	before : List(I64), U64 -> I64
	before = |table, limit| {
		var $index = limit
		var $sum = 0.I64
		while $index > 0 {
			$sum = $sum + (table.get($index) ?? 0)
			$index = $index - PrefixCounts.low_bit($index)
		}
		$sum
	}
	add : List(I64), U64, I64 -> List(I64)
	add = |table, position, amount| {
		var $table = table
		var $index = position + 1
		while $index < $table.len() {
			# The loop proves this write is in bounds. Retaining the old table
			# in the fallback would force a full copy for every Fenwick update.
			$table = $table.set($index, ($table.get($index) ?? 0) + amount) ?? []
			$index = $index + PrefixCounts.low_bit($index)
		}
		$table
	}
	low_bit : U64 -> U64
	low_bit = |value| value.bitwise_and(value.bitwise_xor(18446744073709551615).plus_wrap(1))
}

expect {
	table = PrefixCounts.add(PrefixCounts.add(PrefixCounts.create(4), 1, 2), 3, 1)
	PrefixCounts.before(table, 0) == 0 and PrefixCounts.before(table, 1) == 0
		and PrefixCounts.before(table, 2) == 2 and PrefixCounts.before(table, 4) == 3
		and PrefixCounts.before(PrefixCounts.add(table, 1, -2), 4) == 1
}
