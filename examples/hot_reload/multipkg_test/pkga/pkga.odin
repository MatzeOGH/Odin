package pkga

// Leaf package. `value` is edited 1 -> 2 by the reload; `hits` is per-package global
// state that must survive the reload (it lives in the exe's arena / canonical copy).
hits: int

value :: proc() -> int {
	hits += 1
	return 1
}
