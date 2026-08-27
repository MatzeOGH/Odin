#+build windows
package livepatch_migrate_twice

// v1 — the layout the EXE is built with (app start). See app.odin for the test.

VER :: 1

Kind :: enum u8 { A, B, C }

// The migrated host state. A field is added at each version, so its size strictly grows
// v1 < v2 < v3 — which is what lets the test tell "old == app start" (bug) from
// "old == last reload" (fixed).
State :: struct {
	n:    i64,
	tag:  Kind,
	vals: [3]i64,
}

// Changes ONLY at v2 (a field is added there), then stays fixed v2 -> v3. On reload 2 it
// must NOT be re-flagged as changed — proving the diff runs against the current-live (v2)
// layout, not the frozen app-start (v1) one.
OnlyV2 :: struct {
	a: i64,
}

// NewV2 does not exist in v1 (introduced at v2, changed again at v3).
