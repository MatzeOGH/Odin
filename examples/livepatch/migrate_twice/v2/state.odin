#+build windows
package livepatch_migrate_twice

// v2 — the FIRST reload's layout. State grows (added_v2), OnlyV2 grows (a field), and
// NewV2 is introduced. See app.odin.

VER :: 2

Kind :: enum u8 { A, B, C }

State :: struct {
	n:        i64,
	tag:      Kind,
	vals:     [3]i64,
	added_v2: i64, // new at v2
}

OnlyV2 :: struct {
	a: i64,
	b: i64, // new at v2; then unchanged v2 -> v3
}

// Brand-new named type introduced by reload 1. It has no counterpart in the exe, so a
// frozen app-start baseline would treat it as brand-new forever and never migrate it.
NewV2 :: struct {
	x: i64,
}
