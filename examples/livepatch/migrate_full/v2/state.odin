#+build windows
package livepatch_migrate_full

// v2 layout (the reload object is built from this). Relative to v1:
//   * `mana` added at the front (shifts every following offset),
//   * `health` renamed to `hp` (kept by the `fs:"health"` alias),
//   * `scores` moved ahead of `color` (reorder),
//   * `dead` removed,
//   * `Color`'s constants reordered (so .Green's numeric value changes),
//   * `Shape`'s variants reordered (so the union tag value for Square changes).

Color :: enum { Blue, Red, Green } // reordered: Blue=0, Red=1, Green=2

Circle :: struct { r: i64 }
Square :: struct { s: i64 }
Shape  :: union { Square, Circle } // reordered vs v1 -> Square's tag is now 1, was 2

State :: struct {
	mana:   i64,
	hp:     i64 `fs:"health"`,
	scores: [3]i64,
	color:  Color,
	shape:  Shape,
}

init_state :: proc(p: rawptr) {
	s := (^State)(p)
	s.hp = 99
	s.mana = 0
	s.color = .Green
	s.scores = {5, 6, 7}
	s.shape = Square{7}
}

report :: proc(p: rawptr) -> Report {
	s := (^State)(p)
	sq, is_sq := s.shape.(Square)
	return Report{
		hp = s.hp, mana = s.mana, color = i64(s.color), s0 = s.scores[0], s2 = s.scores[2],
		shape_is_square = is_sq ? 1 : 0, shape_val = is_sq ? sq.s : 0,
	}
}
