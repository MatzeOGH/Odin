#+build windows
package livepatch_migrate_enum

// v1 layout. State's fields/size are identical to v2 — only `Facing`'s constants differ.

Facing :: enum u8 { N, E, S, W } // v2 reorders to { W, N, E, S }

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
