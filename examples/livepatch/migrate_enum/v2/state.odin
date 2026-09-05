#+build windows
package livepatch_migrate_enum

// v2 layout. IDENTICAL struct fields/size to v1 — the ONLY change is that `Facing`'s
// constants are re-ordered, so a live `.S` value's numeric byte changes (2 -> 3). The
// struct's own layout is unchanged, so it is flagged only transitively (B), and the u8
// enum must be remapped at its real size (A).

Facing :: enum u8 { W, N, E, S } // reordered: W=0, N=1, E=2, S=3

State :: struct {
	id:     i64,
	facing: Facing,
	label:  [4]u8,
}

init_state :: proc(p: rawptr) {
	s := (^State)(p)
	s.id = 123
	s.facing = .S
	s.label = {'a', 'b', 'c', 'd'}
}

report :: proc(p: rawptr) -> Report {
	s := (^State)(p)
	return Report{id = s.id, facing = i64(s.facing), label0 = i64(s.label[0])}
}
