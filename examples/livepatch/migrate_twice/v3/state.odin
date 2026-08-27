#+build windows
package livepatch_migrate_twice

// v3 — the SECOND reload's layout. State grows again (added_v3); OnlyV2 is left exactly as
// in v2 (unchanged); NewV2 grows (a field). See app.odin for the assertions this drives.

VER :: 3

Kind :: enum u8 { A, B, C }

State :: struct {
	n:        i64,
	tag:      Kind,
	vals:     [3]i64,
	added_v2: i64,
	added_v3: i64, // new at v3
}

OnlyV2 :: struct {
	a: i64,
	b: i64, // identical to v2 -> must NOT be re-flagged on reload 2
}

NewV2 :: struct {
	x: i64,
	y: i64, // changed vs v2 -> must be flagged on reload 2
}
