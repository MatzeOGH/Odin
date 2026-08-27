#+build windows
package hot_reload_rodata_test

// Automated regression test for @(rodata) and #load hot reload (Windows / x64).
//
// Like mt_test, this program drives itself and exits 0 on success / non-zero on failure
// (see run_rodata_test.ps1). It verifies that IMMUTABLE embedded data is re-provided
// fresh after a reload, while ordinary mutable global state is still preserved:
//
//   * PALETTE   — a value-type @(rodata) global (edited in place by the loader).
//   * BLOB      — a mutable global initialized by #load (its header is repointed at the
//                 reload object's fresh, edited blob; the payload is immutable either way).
//   * counter   — an ordinary mutable global; its RUNTIME value must survive the reload.
//
// run_rodata_test.ps1 builds the reload object from an edited copy in which PALETTE[0] and
// asset.txt have changed but NO procedure body changed — so this also exercises the
// data-only reload path (no hot procedure is patched; only the data is refreshed).

import "core:fmt"
import "core:os"
import "core:strings"
import hr "core:sys/hot_reload"

// BASELINE values. run_rodata_test.ps1 rewrites PALETTE[0] (0x11111111 -> 0xAAAAAAAA)
// and asset.txt for the reload object.
@(rodata)
PALETTE := [4]u32{0x11111111, 0x22222222, 0x33333333, 0x44444444}

// A plain mutable global whose initializer is #load: immutable payload, refreshed on reload.
BLOB := #load("asset.txt")

// A #load_directory global: []Load_Directory_File, each file's `data` is immutable. Also refreshed.
ASSETS := #load_directory("assets")

// #hash (of a string literal) and #load_hash (of a file) yield constant integers. As mutable
// globals they are refreshed like #load; run_rodata_test.ps1 edits the literal and the file so
// both hashes change.
HASH     := #hash("interesting-string", "fnv32a")
LOADHASH := #load_hash("asset.txt", "crc32")

// An ordinary mutable global — NOT @(rodata)/#load — so its runtime value must be preserved.
counter: i64

// Readers. Under -hot-reload every procedure is hot-reloadable automatically.
read_palette0 :: proc() -> u32    { return PALETTE[0] }
read_blob     :: proc() -> string { return string(BLOB) }
read_asset0   :: proc() -> string { return len(ASSETS) > 0 ? string(ASSETS[0].data) : "" }
read_hash     :: proc() -> int    { return HASH }
read_loadhash :: proc() -> int    { return LOADHASH }

OBJ_PATH :: "rodata_hot.obj"

fail :: proc(reason: string) -> ! {
	fmt.printfln("RODATA-TEST: FAIL: %s", reason)
	os.exit(1)
}

main :: proc() {
	counter = 42 // runtime state that must survive the reload

	p0 := read_palette0()
	blob0 := read_blob()
	asset0 := read_asset0()
	hash0 := read_hash()
	lhash0 := read_loadhash()
	fmt.printfln("before: palette0=0x%08x blob=%q asset0=%q hash=%d loadhash=%d counter=%d", p0, blob0, asset0, hash0, lhash0, counter)

	if !hr.apply(OBJ_PATH) {
		fail("reload did not apply (is rodata_hot.obj present, built with the same manifest?)")
	}

	p1 := read_palette0()
	blob1 := read_blob()
	asset1 := read_asset0()
	hash1 := read_hash()
	lhash1 := read_loadhash()
	fmt.printfln("after:  palette0=0x%08x blob=%q asset0=%q hash=%d loadhash=%d counter=%d", p1, blob1, asset1, hash1, lhash1, counter)

	// @(rodata) value edited in place.
	if p1 == p0 {
		fail("@(rodata) PALETTE[0] did not refresh")
	}
	if p1 != 0xAAAAAAAA {
		fail(fmt.tprintf("PALETTE[0] wrong after reload: got 0x%08x, want 0xAAAAAAAA", p1))
	}
	// #load header repointed at the reload object's fresh blob.
	if !strings.contains(blob0, "BASELINE") {
		fail(fmt.tprintf("baseline blob unexpected: %q", blob0))
	}
	if !strings.contains(blob1, "RELOADED") {
		fail(fmt.tprintf("#load BLOB did not refresh: %q", blob1))
	}
	// #load_directory slice header repointed at the reload object's fresh backing data.
	if !strings.contains(asset0, "DIR_BASELINE") {
		fail(fmt.tprintf("baseline asset unexpected: %q", asset0))
	}
	if !strings.contains(asset1, "DIR_RELOADED") {
		fail(fmt.tprintf("#load_directory ASSETS did not refresh: %q", asset1))
	}
	// #hash (string literal changed) and #load_hash (file changed) recomputed.
	if hash0 == 0 || hash1 == 0 || hash1 == hash0 {
		fail(fmt.tprintf("#hash HASH did not refresh: before=%d after=%d", hash0, hash1))
	}
	if lhash0 == 0 || lhash1 == 0 || lhash1 == lhash0 {
		fail(fmt.tprintf("#load_hash LOADHASH did not refresh: before=%d after=%d", lhash0, lhash1))
	}
	// Ordinary mutable global state preserved.
	if counter != 42 {
		fail(fmt.tprintf("ordinary global 'counter' not preserved: got %d, want 42", counter))
	}

	fmt.printfln("RODATA-TEST: PASS (palette0 0x%08x->0x%08x, blob refreshed, counter=%d)", p0, p1, counter)
	os.exit(0)
}
