#+build windows
package livepatch

import "base:intrinsics"
import "core:fmt"
import win "core:sys/windows"

PATCH_LEN :: 14
PAD_LEN   :: 16

LP_DEBUG_PAD :: #config(LP_DEBUG_PAD, false)

@(private)
// Returns the byte length of the NOP instruction at p, or 0 if it is not a NOP.
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

@(private)
// Reports whether the n bytes at pb are entirely NOP instructions.
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

@(private)
// Reports whether the bytes before an entry point hold a patch pad (a NOP sled or an already-installed jump).
lp_has_patch_pad :: proc(entry: rawptr) -> bool {
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 { // an abs jump we already installed
		return true
	}
	return lp_is_nop_sled(pb, PAD_LEN)
}

@(private)
// Reports whether an entry point is livepatchable (sits above PAD_LEN and has a patch pad).
lp_is_hot_entry :: proc(entry: rawptr) -> bool {
	if uintptr(entry) < PAD_LEN {
		return false
	}
	return lp_has_patch_pad(entry)
}

@(private)
// Writes a 14-byte absolute indirect jump to target at dst.
lp_write_abs_jump :: proc(dst: [^]u8, target: rawptr) {
	dst[0] = 0xFF; dst[1] = 0x25
	dst[2] = 0x00; dst[3] = 0x00; dst[4] = 0x00; dst[5] = 0x00
	(^u64)(&dst[6])^ = u64(uintptr(target))
}

// Redirects original to target, preferring the atomic pad jump and falling back to an overwrite.
patch_jump :: proc(original: rawptr, target: rawptr) -> (ok: bool, atomic: bool) {
	if lp_patch_atomic(original, target) {
		return true, true
	}
	return lp_patch_overwrite(original, target), false
}

@(private)
// Installs the jump into the patch pad, then atomically flips the entry to a 2-byte self-jump into it.
lp_patch_atomic :: proc(original: rawptr, target: rawptr) -> bool {
	if uintptr(original) < PAD_LEN {
		return false
	}
	pad := rawptr(uintptr(original) - PAD_LEN)
	pb := ([^]u8)(pad)
	when LP_DEBUG_PAD {
		eb := ([^]u8)(original)
		fmt.eprintfln("[livepatch] pad@%p: % x | entry: %02x %02x", pad,
			pb[0:PAD_LEN], eb[0], eb[1])
	}
	if !lp_has_patch_pad(original) {
		return false
	}

	region_len := win.SIZE_T(PAD_LEN + 2)
	old: win.DWORD
	if !win.VirtualProtect(pad, region_len, win.PAGE_EXECUTE_READWRITE, &old) {
		return false
	}

	lp_write_abs_jump(pb, target)
	win.FlushInstructionCache(win.GetCurrentProcess(), pad, win.SIZE_T(PATCH_LEN))

	intrinsics.atomic_store((^u16)(original), u16(0xEEEB))
	win.FlushInstructionCache(win.GetCurrentProcess(), original, 2)

	restored: win.DWORD
	win.VirtualProtect(pad, region_len, old, &restored)
	return true
}

@(private)
// Overwrites an entry point in place with an absolute jump to target (when there is no usable pad).
lp_patch_overwrite :: proc(original: rawptr, target: rawptr) -> bool {
	if gap := lp_next_symbol_after(uintptr(original)) - uintptr(original); gap < PATCH_LEN {
		fmt.eprintfln("[livepatch] refusing overwrite patch: only %d bytes to next symbol (need %d)", gap, PATCH_LEN)
		return false
	}
	old_protect: win.DWORD
	if !win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), win.PAGE_EXECUTE_READWRITE, &old_protect) {
		fmt.eprintln("[livepatch] VirtualProtect failed")
		return false
	}
	lp_write_abs_jump(([^]u8)(original), target)
	restored: win.DWORD
	win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), old_protect, &restored)
	win.FlushInstructionCache(win.GetCurrentProcess(), original, win.SIZE_T(PATCH_LEN))
	return true
}
