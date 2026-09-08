#+build windows
package livepatch

import "base:intrinsics"
import "core:fmt"
import win "core:sys/windows"

PATCH_LEN :: 14
PAD_LEN   :: 16

// Returns the byte length of the NOP instruction at p, or 0 if it is not a NOP.
@(private)
lp_nop_len :: proc(p: [^]u8, max: int) -> int {
	i := 0
	for i < max && p[i] == 0x66 { // operand-size prefixes pad out the longer NOP forms
		i += 1
	}
	if i >= max {
		return 0
	}
	if p[i] == 0x90 { // 1-byte NOP (with any leading 0x66 prefixes)
		return i + 1
	}
	if i + 2 < max && p[i] == 0x0F && p[i + 1] == 0x1F { // multi-byte NOP: 0F 1F /0 r/m
		modrm := p[i + 2]
		n := i + 3
		mod := modrm >> 6
		rm  := modrm & 0x7
		if rm == 0x4 { // SIB byte follows
			n += 1
		}
		switch mod {
		case 1: n += 1 // disp8
		case 2: n += 4 // disp32
		case 0:
			if rm == 0x5 { n += 4 } // disp32
		}
		if n <= max {
			return n
		}
	}
	return 0
}

// Reports whether the n bytes at pb are entirely NOP instructions.
@(private)
lp_is_nop_sled :: proc(pb: [^]u8, n: int) -> bool {
	i := 0
	for i < n {
		l := lp_nop_len(([^]u8)(&pb[i]), n - i)
		if l <= 0 {
			return false
		}
		i += l
	}
	return i == n
}

// Reports whether the bytes before an entry point hold a patch pad (a NOP sled or an already-installed jump).
@(private)
lp_has_patch_pad :: proc(entry: rawptr) -> bool {
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 { // an abs jump we already installed
		return true
	}
	return lp_is_nop_sled(pb, PAD_LEN)
}

// Reports whether an entry point is livepatchable (sits above PAD_LEN and has a patch pad).
@(private)
lp_is_hot_entry :: proc(entry: rawptr) -> bool {
	if uintptr(entry) < PAD_LEN {
		return false
	}
	return lp_has_patch_pad(entry)
}

// Writes a 14-byte absolute indirect jump to target at dst.
@(private)
lp_write_abs_jump :: proc(dst: [^]u8, target: rawptr) {
	dst[0] = 0xFF; dst[1] = 0x25
	dst[2] = 0x00; dst[3] = 0x00; dst[4] = 0x00; dst[5] = 0x00
	(^u64)(&dst[6])^ = u64(uintptr(target))
}

// A prepared patch: the destination page has been made writable and the redirect
// strategy chosen, but no bytes are written yet, so it can still be abandoned (via
// lp_patch_restore) with the running code untouched. Committing it is pure memory
// writes and cannot fail. This split lets apply_many pre-flight every patch so the
// write phase is all-or-nothing — no thread ever sees a partially applied reload.
@(private)
Patch_Plan :: struct {
	original, target: rawptr,
	atomic:           bool,   // true: pad jump + 2-byte publish; false: full entry overwrite
	prot_base:        rawptr, // the region made writable (pad base, or the entry itself)
	prot_len:         win.SIZE_T,
	old_prot:         win.DWORD,
}

// Chooses how `original` will be redirected to `target` and makes the bytes the commit
// will write to writable, WITHOUT writing anything. Returns ok=false (having changed no
// protection) when the entry has no usable pad and too little room to overwrite, or the
// page cannot be made writable — so the caller can abort before any patch is applied.
@(private)
lp_patch_prepare :: proc(original, target: rawptr) -> (plan: Patch_Plan, ok: bool) {
	plan.original = original
	plan.target   = target
	if uintptr(original) >= PAD_LEN && lp_has_patch_pad(original) {
		plan.atomic    = true
		plan.prot_base = rawptr(uintptr(original) - PAD_LEN)
		plan.prot_len  = win.SIZE_T(PAD_LEN + 2)
	} else {
		if gap := lp_next_symbol_after(uintptr(original)) - uintptr(original); gap < PATCH_LEN {
			fmt.eprintfln("[livepatch] refusing overwrite patch: only %d bytes to next symbol (need %d)", gap, PATCH_LEN)
			return {}, false
		}
		plan.atomic    = false
		plan.prot_base = original
		plan.prot_len  = win.SIZE_T(PATCH_LEN)
	}
	if !win.VirtualProtect(plan.prot_base, plan.prot_len, win.PAGE_EXECUTE_READWRITE, &plan.old_prot) {
		fmt.eprintln("[livepatch] VirtualProtect failed")
		return {}, false
	}
	return plan, true
}

// Writes the redirect into the already-writable region and flushes the icache. Pure
// memory writes — cannot fail. Returns whether the safe 2-byte atomic publish was used
// (vs a full 14-byte entry overwrite). The atomic path installs the 14-byte absolute
// jump into the pad, then atomically flips the entry's first 2 bytes to a self-jump back
// into the pad, so a concurrently-resumed thread sees either the old entry or the
// complete redirect, never a half-written instruction.
@(private)
lp_patch_commit :: proc(plan: Patch_Plan) -> (atomic: bool) {
	if plan.atomic {
		lp_write_abs_jump(([^]u8)(plan.prot_base), plan.target) // prot_base == original - PAD_LEN
		win.FlushInstructionCache(win.GetCurrentProcess(), plan.prot_base, win.SIZE_T(PATCH_LEN))
		intrinsics.atomic_store((^u16)(plan.original), u16(0xEEEB))
		win.FlushInstructionCache(win.GetCurrentProcess(), plan.original, 2)
		return true
	}
	lp_write_abs_jump(([^]u8)(plan.original), plan.target)
	win.FlushInstructionCache(win.GetCurrentProcess(), plan.original, win.SIZE_T(PATCH_LEN))
	return false
}

// Restores a prepared region's original page protection, after committing or when the
// pre-flight is abandoned.
@(private)
lp_patch_restore :: proc(plan: Patch_Plan) {
	if plan.prot_base == nil {
		return
	}
	restored: win.DWORD
	win.VirtualProtect(plan.prot_base, plan.prot_len, plan.old_prot, &restored)
}

// A data region a reload overwrites in place (an @(rodata)/#load refresh copy, or the
// runtime type_table slice header): its destination page has been made writable and is
// ready for an unfailing memcpy. Same pre-flight/commit split as Patch_Plan.
@(private)
Wr_Prep :: struct {
	dst, src: rawptr,
	size:     int,
	old:      win.DWORD,
	ok:       bool,
}

// Makes [dst, dst+size) writable (read/write, non-executable) without copying anything.
// Returns ok=false (having changed no protection) if the page cannot be made writable.
@(private)
lp_make_writable :: proc(dst, src: rawptr, size: int) -> (Wr_Prep, bool) {
	w := Wr_Prep{dst = dst, src = src, size = size}
	if size <= 0 {
		return {}, false
	}
	if !win.VirtualProtect(dst, win.SIZE_T(size), win.PAGE_READWRITE, &w.old) {
		return {}, false
	}
	w.ok = true
	return w, true
}

// Copies the region's bytes into its already-writable destination. Cannot fail.
@(private)
lp_write_region :: proc(w: Wr_Prep) {
	intrinsics.mem_copy(w.dst, w.src, w.size)
}

// Restores a data region's original page protection (no-op if it was never prepared).
@(private)
lp_restore_writable :: proc(w: Wr_Prep) {
	if !w.ok {
		return
	}
	restored: win.DWORD
	win.VirtualProtect(w.dst, win.SIZE_T(w.size), w.old, &restored)
}
