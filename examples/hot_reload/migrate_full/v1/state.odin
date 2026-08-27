#+build windows
package hot_reload_migrate_full

// v1 layout (the exe is built from this).

Color :: enum { Red, Green, Blue } // int-backed (size 8); v2 reorders these

Circle :: struct { r: i64 }
Square :: struct { s: i64 }
Shape  :: union { Circle, Square } // v2 reorders the variants

State :: struct {
	health: i64,
	color:  Color,
	scores: [3]i64,
	shape:  Shape,
	dead:   bool, // removed in v2
}

@(hot_reload)
init_state :: proc(p: rawptr) {
	s := (^State)(p)
	s.health = 99
	s.color = .Green
	s.scores = {5, 6, 7}
	s.shape = Square{7}
	s.dead = true
}

@(hot_reload)
report :: proc(p: rawptr) -> Report {
	s := (^State)(p)
	sq, is_sq := s.shape.(Square)
	return Report{
		hp = s.health, mana = 0, color = i64(s.color), s0 = s.scores[0], s2 = s.scores[2],
		shape_is_square = is_sq ? 1 : 0, shape_val = is_sq ? sq.s : 0,
	}
}
