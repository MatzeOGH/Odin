#+build windows
package livepatch

// Image-section mapping for reload blocks.
//
// A reload block is brought into the process by mapping a real SEC_IMAGE section
// (NtCreateSection + NtMapViewOfSection) built from the on-disk lp_%p.dll, rather
// than by VirtualAlloc + hand-copy. Mapping an image section into a process that
// has a debug port makes the kernel fire a genuine LOAD_DLL_DEBUG_EVENT (the
// DbgkMapViewOfSection path — the same one LoadLibrary takes), so a debugger that
// is attached *from the start* is notified of every reload automatically, with no
// PEB polling. This is the discovery mechanism Live++ gets for free by loading
// each patch as a DLL; we get it while keeping our shared-globals manual map,
// because the kernel neither runs the loader/DllMain nor relinks our symbols.
//
// The synthetic PE has no .reloc, so the kernel cannot relocate it: it is mapped
// only at its own ImageBase. We therefore pick a free base near the exe first,
// bake that base into the image, and map there; a base conflict simply retries at
// the next candidate. After mapping, the view's pages are made writable
// (VirtualProtect → copy-on-write) so the loader can relocate, resolve externals
// and patch in place exactly as it does for a VirtualAlloc block.

import win "core:sys/windows"

SEC_IMAGE           :: 0x0100_0000
SECTION_QUERY       :: 0x0001
SECTION_MAP_WRITE   :: 0x0002
SECTION_MAP_READ    :: 0x0004
SECTION_MAP_EXECUTE :: 0x0008
LP_PAGE_READONLY    :: 0x02
LP_VIEW_UNMAP       :: 2 // SECTION_INHERIT.ViewUnmap

foreign import lp_nt "system:ntdll.lib"
@(default_calling_convention="system")
foreign lp_nt {
	NtCreateSection :: proc(SectionHandle: ^win.HANDLE, DesiredAccess: win.DWORD,
		ObjectAttributes: rawptr, MaximumSize: ^i64,
		SectionPageProtection: win.ULONG, AllocationAttributes: win.ULONG, FileHandle: win.HANDLE) -> win.NTSTATUS ---
	NtMapViewOfSection :: proc(SectionHandle, ProcessHandle: win.HANDLE, BaseAddress: ^rawptr,
		ZeroBits: uintptr, CommitSize: win.SIZE_T, SectionOffset: ^i64, ViewSize: ^win.SIZE_T,
		InheritDisposition: win.DWORD, AllocationType: win.ULONG, Win32Protect: win.ULONG) -> win.NTSTATUS ---
	NtUnmapViewOfSection :: proc(ProcessHandle: win.HANDLE, BaseAddress: rawptr) -> win.NTSTATUS ---
}

// NTSTATUS success covers 0 (STATUS_SUCCESS) and the informational 0x4xxxxxxx codes
// (e.g. STATUS_IMAGE_NOT_AT_BASE 0x40000003, which an image map returns while still
// mapping correctly at the requested base).
@(private)
lp_nt_success :: proc "contextless" (st: win.NTSTATUS) -> bool { return i32(st) >= 0 }

// Finds a 64KB-aligned base near `near` where `size` bytes are free, so a SEC_IMAGE
// view can be mapped there. Mirrors alloc_near_prot's ±1.5GB probe (inside x64 REL32
// reach) but only queries — it must NOT commit, since a committed range blocks the map.
@(private)
lp_find_free_near :: proc(near: uintptr, size: int, skip_below: uintptr = 0) -> uintptr {
	sz := uintptr(size)
	step :: uintptr(0x0010_0000)
	limit :: uintptr(0x6000_0000)
	is_free :: proc "contextless" (addr, size: uintptr) -> bool {
		mbi: win.MEMORY_BASIC_INFORMATION
		if win.VirtualQuery(rawptr(addr), &mbi, size_of(mbi)) == 0 { return false }
		if mbi.State != win.MEM_FREE { return false }
		region_end := uintptr(mbi.BaseAddress) + uintptr(mbi.RegionSize)
		return addr + size <= region_end
	}
	for off := step; off <= limit; off += step {
		if near > off {
			cand := near - off
			if cand > skip_below && is_free(cand, sz) { return cand }
		}
		if near + off > skip_below && is_free(near + off, sz) { return near + off }
	}
	return 0
}

// Maps the image at `path` as a SEC_IMAGE view, requesting base `want`. Returns the
// actual mapped base (which must equal `want`, since the image has no .reloc). The
// section and file handles are transient: once mapped, the view outlives them, and
// teardown only needs the base for NtUnmapViewOfSection.
@(private)
lp_section_map :: proc(path: string, want: uintptr) -> (base: rawptr, ok: bool) {
	wpath := win.utf8_to_wstring(path)
	hFile := win.CreateFileW(wpath,
		win.GENERIC_READ | win.GENERIC_EXECUTE,
		win.FILE_SHARE_READ | win.FILE_SHARE_DELETE, nil,
		win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	if hFile == win.INVALID_HANDLE_VALUE { return nil, false }
	defer win.CloseHandle(hFile)

	sec: win.HANDLE
	st := NtCreateSection(&sec,
		SECTION_MAP_READ | SECTION_MAP_EXECUTE | SECTION_QUERY,
		nil, nil, LP_PAGE_READONLY, SEC_IMAGE, hFile)
	if !lp_nt_success(st) { return nil, false }
	defer win.CloseHandle(sec)

	b := rawptr(want)
	vsize: win.SIZE_T = 0
	st2 := NtMapViewOfSection(sec, win.GetCurrentProcess(), &b, 0, 0, nil, &vsize, LP_VIEW_UNMAP, 0, LP_PAGE_READONLY)
	if !lp_nt_success(st2) { return nil, false }
	if uintptr(b) != want {
		// Mapped somewhere else (should not happen without .reloc); reject so the
		// baked ImageBase/RVAs stay correct.
		NtUnmapViewOfSection(win.GetCurrentProcess(), b)
		return nil, false
	}
	return b, true
}

@(private)
lp_section_unmap :: proc "contextless" (base: rawptr) {
	if base != nil { NtUnmapViewOfSection(win.GetCurrentProcess(), base) }
}
