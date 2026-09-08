#+build windows
package livepatch

// Source-level debugging of patched code.
//
// After a reload's object is mapped, relocated and patched into the process, this
// makes the mapped block a debugger-visible module: it synthesizes a PE header at
// the block base, emits a PDB (pdb.odin) describing the patched functions with
// source lines transcribed from the object's own CodeView (`.debug$S`), writes
// both to disk, registers the module with the in-process DbgHelp (so the app's own
// backtraces and crash dumps resolve hot frames) and splices it into the PEB
// loader list (so an attached external debugger — RAD Debugger, VS Code/cppvsdbg,
// WinDbg — discovers it, loads the PDB, and binds source-line breakpoints).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

foreign import lp_dbg "system:dbghelp.lib"
@(default_calling_convention="system")
foreign lp_dbg {
	SymLoadModuleExW :: proc(hProcess: win.HANDLE, hFile: win.HANDLE, ImageName: win.wstring, ModuleName: win.wstring, BaseOfDll: win.DWORD64, DllSize: win.DWORD, Data: rawptr, Flags: win.DWORD) -> win.DWORD64 ---
	SymUnloadModule64 :: proc(hProcess: win.HANDLE, BaseOfDll: win.DWORD64) -> win.BOOL ---
}

// ---- minimal PEB loader structures (x64) ----
// Field offsets must match ntdll's real LDR_DATA_TABLE_ENTRY: the in-process loader
// walks this entry (we splice it into InLoadOrderModuleList) and reads DdagNode at
// +0x98 on every new-thread init. A null DdagNode there faults; see lp_peb_splice.
@(private) Lp_Ldr_Entry :: struct {
	InLoadOrderLinks:            win.LIST_ENTRY,     // 0x00
	InMemoryOrderLinks:          win.LIST_ENTRY,     // 0x10
	InInitializationOrderLinks:  win.LIST_ENTRY,     // 0x20
	DllBase:                     rawptr,             // 0x30
	EntryPoint:                  rawptr,             // 0x38  (left nil)
	SizeOfImage:                 u32,                // 0x40
	_pad0:                       u32,
	FullDllName:                 win.UNICODE_STRING, // 0x48
	BaseDllName:                 win.UNICODE_STRING, // 0x58
	Flags:                       u32,                // 0x68
	ObsoleteLoadCount:           u16,                // 0x6C
	TlsIndex:                    u16,                // 0x6E
	HashLinks:                   win.LIST_ENTRY,     // 0x70
	TimeDateStamp:               u32,                // 0x80
	_pad1:                       u32,
	EntryPointActivationContext: rawptr,             // 0x88
	Lock:                        rawptr,             // 0x90
	DdagNode:                    ^Lp_Ddag_Node,      // 0x98  <-- must be non-null
	_rest:                       [0x40]u8,           // remaining tail the loader may touch
	_ddag_storage:              Lp_Ddag_Node,       // backing store for DdagNode (any offset)
}

// Minimal LDR_DDAG_NODE (x64). Only State (+0x38) is read on the crashing path, but
// the leading fields keep it at their true offsets so the whole node is self-consistent.
@(private) Lp_Ddag_Node :: struct {
	Modules:                 win.LIST_ENTRY, // 0x00
	ServiceTagList:          rawptr,         // 0x10
	LoadCount:               u32,            // 0x18
	LoadWhileUnloadingCount: u32,            // 0x1C
	LowestLink:              u32,            // 0x20
	_pad:                    u32,
	Dependencies:            rawptr,         // 0x28  (_LDRP_CSLIST.Tail)
	IncomingDependencies:    rawptr,         // 0x30  (_LDRP_CSLIST.Tail)
	State:                   i32,            // 0x38  <-- read by LdrpInitializeThread
	_tail:                   [0x20]u8,       // slack past State
}

@(private)
lp_read_peb :: proc "contextless" () -> uintptr {
	read :: asm() -> (r: u64) { mov r, [%gs:0x60]; }
	return uintptr(read())
}

// Reports whether a ring-3 debugger is attached, via PEB.BeingDebugged (offset 0x02).
// Reused to time the "your debugger will stop once" heads-up on a section-mapped reload.
@(private)
lp_debugger_present :: proc "contextless" () -> bool {
	peb := lp_read_peb()
	return peb != 0 && (^u8)(peb + 0x02)^ != 0
}

@(private)
lp_list_insert_tail :: proc(head, entry: ^win.LIST_ENTRY) {
	tail := head.Blink
	entry.Flink = head
	entry.Blink = tail
	tail.Flink = entry
	head.Blink = entry
}

@(private)
lp_list_remove :: proc(e: ^win.LIST_ENTRY) {
	if e.Flink == nil || e.Blink == nil { return }
	e.Blink.Flink = e.Flink
	e.Flink.Blink = e.Blink
	e.Flink = nil; e.Blink = nil
}

@(private)
lp_make_ustr :: proc(s: string) -> win.UNICODE_STRING {
	// Must outlive the call: the spliced PEB entry is read by external debuggers
	// and by dbghelp's invade for the process lifetime, so allocate on the heap.
	w := win.utf8_to_wstring(s, runtime.heap_allocator())
	n := u16(len(s) * 2)
	return win.UNICODE_STRING{ Length = n, MaximumLength = n + 2, Buffer = transmute([^]u16)w }
}

// Fixed image identity for a generation's module. Age advances per reload; the
// serial makes each module's PDB GUID unique independently of its mapped base, so a
// base-conflict retry when section-mapping need not re-emit the PDB.
@(private) _lp_dbg_age: u32 = 1
@(private) _lp_dbg_serial: u64
// Set once per reload when the debugger heads-up has been printed, so a multi-object
// reload prints it a single time. Reset at the top of apply_many.
@(private) _lp_dbg_warned: bool

// ---- CodeView (.debug$S) extraction ----

// Reads little-endian scalars out of a byte slice.
@(private) rd_u16 :: proc(b: []u8, o: int) -> u16 { return u16((^u16le)(raw_data(b[o:]))^) if o+2 <= len(b) else 0 }
@(private) rd_u32 :: proc(b: []u8, o: int) -> u32 { return u32((^u32le)(raw_data(b[o:]))^) if o+4 <= len(b) else 0 }

// Extracts the patched functions with their source-line tables from the object's
// CodeView debug section. RVAs are relative to o.block (the image base).
@(private)
lp_extract_funcs :: proc(o: ^Obj, alloc: runtime.Allocator) -> (funcs: []Pdb_Func, files: []string) {
	// find .debug$S
	dbg_si := -1
	for i in 0 ..< o.n_sections {
		sh := section_header(o.data, o.sec_off, i)
		if section_name(sh) == ".debug$S" { dbg_si = i; break }
	}
	if dbg_si < 0 { return }
	sh := section_header(o.data, o.sec_off, dbg_si)
	raw_off := int(sh.pointer_to_raw_data)
	raw_len := int(sh.size_of_raw_data)
	if raw_off == 0 || raw_len == 0 || raw_off+raw_len > len(o.data) { return }
	ds := o.data[raw_off:raw_off+raw_len]

	// reloc map: section-offset of a SECREL field -> COFF symbol index
	rel_off := int(sh.pointer_to_relocations)
	nrel := int(sh.number_of_relocations)
	secrel := make(map[u32]u32, alloc)
	for r in 0 ..< nrel {
		ro := rel_off + r*RELOC_SIZE
		if ro+RELOC_SIZE > len(o.data) { break }
		rc := (^Coff_Reloc)(raw_data(o.data[ro:]))
		if int(rc.type) == 0x0B { // IMAGE_REL_AMD64_SECREL
			secrel[u32(rc.virtual_address)] = u32(rc.symbol_table_index)
		}
	}

	funcs_dyn := make([dynamic]Pdb_Func, alloc)
	files_dyn := make([dynamic]string, alloc)
	chk_to_file := make(map[u32]int, alloc) // checksum-entry offset -> file index

	strtab: []u8       // DEBUG_S_STRINGTABLE bytes
	chks:   []u8       // DEBUG_S_FILECHKSMS bytes
	chks_base: u32     // section-offset of chks data (for resolving relative offsets — not needed)
	_ = chks_base

	// First pass: capture string table and file checksums.
	{
		pos := 4 // after CV signature
		for pos + 8 <= len(ds) {
			kind := rd_u32(ds, pos)
			slen := int(rd_u32(ds, pos+4))
			data_off := pos + 8
			if data_off + slen > len(ds) { break }
			switch kind {
			case 0xF3: strtab = ds[data_off:data_off+slen]
			case 0xF4: chks   = ds[data_off:data_off+slen]
			}
			pos = data_off + ((slen + 3) &~ 3)
		}
	}
	// Resolve a file-checksum-entry offset to a file index (adding to files as needed).
	file_of :: proc(chk_off: u32, chks, strtab: []u8, files: ^[dynamic]string, m: ^map[u32]int, alloc: runtime.Allocator) -> int {
		if idx, ok := m[chk_off]; ok { return idx }
		name := "??"
		if int(chk_off)+4 <= len(chks) {
			name_off := rd_u32(chks, int(chk_off))
			if int(name_off) < len(strtab) {
				e := int(name_off)
				for e < len(strtab) && strtab[e] != 0 { e += 1 }
				name = strings.clone(string(strtab[int(name_off):e]), alloc)
			}
		}
		idx := len(files)
		append(files, name)
		m[chk_off] = idx
		return idx
	}

	// Second pass: for each Lines subsection, resolve its function via the SECREL
	// reloc on its header, read size + line entries.
	pos := 4
	for pos + 8 <= len(ds) {
		kind := rd_u32(ds, pos)
		slen := int(rd_u32(ds, pos+4))
		data_off := pos + 8
		if data_off + slen > len(ds) { break }
		if kind == 0xF2 { // DEBUG_S_LINES
			// header: offset(4) seg(2) flags(2) codeSize(4)
			field_va := u32(data_off) // section-offset of the offset field
			if symidx, ok := secrel[field_va]; ok {
				sym := coff_symbol(o.data, o.sym_off, int(symidx))
				sn := int(sym.section_number)
				if sn > 0 && sn < len(o.offsets) && o.offsets[sn] >= 0 {
					rva := u32(o.offsets[sn] + int(sym.value))
					name := symbol_name(sym, o.data, o.strtab_off)
					code_size := rd_u32(ds, data_off+8)
					// file block
					fb := data_off + 12
					if fb + 12 <= data_off + slen {
						chk_off := rd_u32(ds, fb)
						nlines := int(rd_u32(ds, fb+4))
						file_idx := file_of(chk_off, chks, strtab, &files_dyn, &chk_to_file, alloc)
						lines := make([dynamic]Pdb_Line, alloc)
						le := fb + 12
						for i in 0 ..< nlines {
							eo := le + i*8
							if eo + 8 > data_off + slen { break }
							loff := rd_u32(ds, eo)
							lnum := rd_u32(ds, eo+4) & 0xFFFFFF
							append(&lines, Pdb_Line{loff, lnum})
						}
						append(&funcs_dyn, Pdb_Func{
							name  = strings.clone(name, alloc),
							rva   = rva,
							size  = code_size,
							file  = file_idx,
							lines = lines[:],
						})
					}
				}
			}
		}
		pos = data_off + ((slen + 3) &~ 3)
	}
	if len(files_dyn) == 0 { append(&files_dyn, "unknown.odin") }
	return funcs_dyn[:], files_dyn[:]
}

// ---- synthetic PE header (written into o.block[0..PAGE]) ----

@(private)
lp_write_pe_header :: proc(o: ^Obj, dst: [^]u8, base: uintptr, guid: [16]u8, age: u32, pdb_path: string, base_name: string) -> (size_of_image: u32) {
	m := dst
	w16 :: proc(m: [^]u8, off: int, v: u16) { x:=v; (^u16le)(&m[off])^ = u16le(x) }
	w32 :: proc(m: [^]u8, off: int, v: u32) { x:=v; (^u32le)(&m[off])^ = u32le(x) }
	w64 :: proc(m: [^]u8, off: int, v: u64) { x:=v; (^u64le)(&m[off])^ = u64le(x) }

	// count kept sections + image size (+1 synthetic debug section at o.dbg_off)
	nsec := 1
	img_end := o.dbg_off + PAGE
	for i in 0 ..< o.n_sections {
		if o.offsets[i+1] < 0 { continue }
		sh := section_header(o.data, o.sec_off, i)
		sz := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		nsec += 1
		e := o.offsets[i+1] + mem_align(sz, PAGE)
		if e > img_end { img_end = e }
	}
	size_of_image = u32(img_end)

	m[0]='M'; m[1]='Z'; w32(m, 0x3C, 0x40)
	nt := 0x40; m[nt]='P'; m[nt+1]='E'; m[nt+2]=0; m[nt+3]=0
	fh := nt+4
	w16(m, fh+0, 0x8664); w16(m, fh+2, u16(nsec)); w16(m, fh+16, 240); w16(m, fh+18, 0x2022)
	w32(m, fh+4, 0x5a4d5a4d) // TimeDateStamp (arbitrary non-zero)
	oh := fh+20
	w16(m, oh+0, 0x20b)               // PE32+
	m[oh+2]=14; m[oh+3]=0
	w32(m, oh+4, 0x1000)              // SizeOfCode
	w32(m, oh+8, 0x1000)             // SizeOfInitializedData
	w32(m, oh+16, u32(PAGE))         // AddressOfEntryPoint = BaseOfCode (start of .text).
	                                 // Never executed (we never run DllMain), but it MUST be
	                                 // a valid code entry: with 0 here, debuggers stop binding
	                                 // `update`'s SOURCE line to this module and fall back to
	                                 // the exe's redirected (dead) copy, so breakpoints never
	                                 // hit. A debugger's entry auto-bp lands in update's unused
	                                 // 16-byte pad at .text+0 (callers enter the body at +0x10),
	                                 // so it never fires.
	w32(m, oh+20, u32(PAGE))         // BaseOfCode
	w64(m, oh+24, u64(base))         // ImageBase = the base this image is mapped at
	w32(m, oh+32, u32(PAGE))         // SectionAlignment
	w32(m, oh+36, 0x200)             // FileAlignment
	w16(m, oh+40, 6); w16(m, oh+44, 6); w16(m, oh+48, 6)
	w32(m, oh+56, size_of_image)     // SizeOfImage
	w32(m, oh+60, u32(PAGE))         // SizeOfHeaders (whole first page)
	w16(m, oh+68, 3)                 // Subsystem CONSOLE
	w16(m, oh+70, 0x160)             // DllCharacteristics
	w64(m, oh+72, 0x100000); w64(m, oh+80, 0x1000)
	w64(m, oh+88, 0x100000); w64(m, oh+96, 0x1000)
	w32(m, oh+108, 16)               // NumberOfRvaAndSizes

	// Everything below lives in the synthetic .rdata0 section at o.dbg_off:
	//   +0x00 debug directory, +0x20 RSDS, +0x100 export directory, +0x140 module name.
	dbgdir_rva := o.dbg_off
	rsds_rva   := o.dbg_off + 0x20
	exp_rva    := o.dbg_off + 0x100
	name_rva   := o.dbg_off + 0x140
	dd := oh+112
	w32(m, dd+6*8+0, u32(dbgdir_rva)) // Debug dir (index 6)
	w32(m, dd+6*8+4, 28)
	w32(m, dd+0*8+0, u32(exp_rva))    // Export dir (index 0) — gives the module a name
	w32(m, dd+0*8+4, 40)
	// IMAGE_EXPORT_DIRECTORY (name only, no exports)
	w32(m, exp_rva+12, u32(name_rva)) // Name RVA
	w32(m, exp_rva+16, 1)             // Base
	nb := transmute([]u8)base_name
	for k in 0..<len(nb) { m[name_rva+k] = nb[k] }
	m[name_rva+len(nb)] = 0

	// section table: kept object sections, then the synthetic debug section
	sh_off := oh+240
	si := 0
	for i in 0 ..< o.n_sections {
		if o.offsets[i+1] < 0 { continue }
		src := section_header(o.data, o.sec_off, i)
		sz := u32(max(int(src.virtual_size), int(src.size_of_raw_data)))
		e := sh_off + si*40
		nm := section_name(src)
		nb: [8]u8; copy(nb[:], transmute([]u8)nm)
		for k in 0..<8 { m[e+k] = nb[k] }
		w32(m, e+8,  sz)                 // VirtualSize
		w32(m, e+12, u32(o.offsets[i+1]))// VirtualAddress (RVA)
		w32(m, e+16, sz)                 // SizeOfRawData
		w32(m, e+20, u32(o.offsets[i+1]))// PointerToRawData == RVA (memory image)
		w32(m, e+36, lp_sect_chars(u32(src.characteristics)))
		si += 1
	}
	// synthetic ".rdata0" debug section
	{
		e := sh_off + si*40
		nm := ".rdata0"
		nb: [8]u8; copy(nb[:], transmute([]u8)nm)
		for k in 0..<8 { m[e+k] = nb[k] }
		w32(m, e+8,  u32(PAGE)); w32(m, e+12, u32(o.dbg_off)); w32(m, e+16, u32(PAGE)); w32(m, e+20, u32(o.dbg_off))
		w32(m, e+36, 0x40000040) // INITIALIZED_DATA | READ
	}

	// IMAGE_DEBUG_DIRECTORY at dbgdir_rva
	cvlen := u32(4 + 16 + 4 + len(pdb_path) + 1)
	w32(m, dbgdir_rva+12, 2)          // Type = CODEVIEW
	w32(m, dbgdir_rva+16, cvlen)      // SizeOfData
	w32(m, dbgdir_rva+20, u32(rsds_rva)) // AddressOfRawData (RVA)
	w32(m, dbgdir_rva+24, u32(rsds_rva)) // PointerToRawData (== RVA)
	// RSDS
	g := guid
	m[rsds_rva+0]='R'; m[rsds_rva+1]='S'; m[rsds_rva+2]='D'; m[rsds_rva+3]='S'
	for k in 0..<16 { m[rsds_rva+4+k] = g[k] }
	w32(m, rsds_rva+20, age)
	pb := transmute([]u8)pdb_path
	for k in 0..<len(pb) { m[rsds_rva+24+k] = pb[k] }
	m[rsds_rva+24+len(pb)] = 0
	return
}

@(private)
mem_align :: proc(n, a: int) -> int { return (n + a - 1) &~ (a - 1) }

// Keep only IMAGE-valid section characteristics; strip object-only flags
// (alignment, LNK_*) that dbghelp/DIA reject in an image section header.
@(private)
lp_sect_chars :: proc(c: u32) -> u32 {
	// CNT_CODE|CNT_INIT|CNT_UNINIT | MEM_EXECUTE|MEM_READ|MEM_WRITE
	return (c & 0xE00000E0) | 0x40000000
}

// Registers a reload block as a debuggable module. Best-effort: logs and returns on
// any failure without disturbing the reload. For a section-mapped block the image and
// PDB were already emitted (and the live LOAD_DLL event already fired) in
// lp_map_object, so this only does the post-commit registration that must not happen
// for an aborted reload: the in-process DbgHelp load (our own backtraces / crash
// dumps) and the PEB splice (for a debugger that attaches AFTER this reload).
@(private)
lp_debug_register :: proc(o: ^Obj) {
	if o.block == nil { return }

	when LP_SECTION_MAP {
		if o.mapped {
			lp_debug_symload(o.img_path, o.block, o.size_of_image, &o.sym_loaded)
			when #config(LP_NO_PEB, false) {
			} else {
				o.ldr = lp_peb_splice(o.block, o.size_of_image, o.img_path, o.base_name)
			}
			fmt.printfln("[livepatch] debug: module at %p (%d funcs) -> %s", o.block, o.dbg_nfuncs, o.base_name)
			return
		}
	}

	// VirtualAlloc fallback (or LP_SECTION_MAP=false): emit the module the old way —
	// PE header into the block, PDB + image to disk — then register.
	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	defer runtime.arena_destroy(&scratch)
	alloc := runtime.arena_allocator(&scratch)

	// stable guid for this generation from the block address + age
	guid: [16]u8
	b := u64(uintptr(o.block))
	for k in 0..<8 { guid[k] = u8(b >> uint(k*8)) }
	guid[8]  = u8(_lp_dbg_age); guid[9] = u8(_lp_dbg_age >> 8)
	guid[10] = 0x4c; guid[11] = 0x50 // 'LP'
	age := _lp_dbg_age
	_lp_dbg_age += 1

	dir := filepath_dir_of_exe(alloc)
	base_name := fmt.aprintf("lp_%p.dll", o.block, allocator = alloc)
	img_path  := fmt.aprintf("%s\\%s", dir, base_name, allocator = alloc)
	pdb_name  := fmt.aprintf("lp_%p.pdb", o.block, allocator = alloc)
	pdb_path  := fmt.aprintf("%s\\%s", dir, pdb_name, allocator = alloc)

	// 1. PE header into the reserved first page.
	size_of_image := lp_write_pe_header(o, ([^]u8)(o.block), uintptr(o.block), guid, age, pdb_path, base_name)

	// 2. extract functions + emit the PDB, write it to disk.
	funcs, files := lp_extract_funcs(o, alloc)
	if len(funcs) == 0 { return } // no debuggable user code in this object (e.g. builtin/metadata)
	when #config(LP_DBG_MIN, false) {
		if len(funcs) > 1 { funcs = funcs[:1] }
		if len(files) > 1 { files = files[:1] }
	}
	pdb_bytes := lp_emit_pdb(guid, age, funcs, files, lp_sections_for_pdb(o, alloc))
	if !os2_write(pdb_path, pdb_bytes) {
		fmt.eprintfln("[livepatch] debug: could not write %s", pdb_path)
		return
	}

	// 3. write the mapped image to disk (so a debugger can read the RSDS by path).
	img := (cast([^]u8)o.block)[:size_of_image]
	_ = os2_write(img_path, img)

	o.size_of_image = size_of_image
	o.dbg_nfuncs    = len(funcs)
	o.base_name     = strings.clone(base_name, runtime.heap_allocator())
	o.img_path      = strings.clone(img_path, runtime.heap_allocator())
	o.pdb_path      = strings.clone(pdb_path, runtime.heap_allocator())

	// 4. in-process DbgHelp (our own backtraces / crash dumps).
	lp_debug_symload(img_path, o.block, size_of_image, &o.sym_loaded)
	when #config(LP_DBG_SELFTEST, false) {
		if o.sym_loaded && len(funcs) > 0 {
			addr := win.DWORD64(uintptr(o.block) + uintptr(funcs[0].rva))
			fmt.printfln("[livepatch] debug self-test: %s rva=0x%x abs=0x%x", funcs[0].name, funcs[0].rva, addr)
			NM :: 256
			sbuf: [size_of(win.SYMBOL_INFOW) + NM*2]u8
			sym := (^win.SYMBOL_INFOW)(&sbuf[0]); sym.SizeOfStruct = size_of(win.SYMBOL_INFOW); sym.MaxNameLen = NM
			sd: win.DWORD64
			if win.SymFromAddrW(win.GetCurrentProcess(), addr, &sd, sym) {
				nm, _ := win.wstring_to_utf8(win.wstring(&sym.Name[0]), int(sym.NameLen), context.temp_allocator)
				fmt.printfln("[livepatch] debug self-test: SymFromAddr -> %s+0x%x", nm, sd)
			} else {
				fmt.printfln("[livepatch] debug self-test: SymFromAddr failed (%v)", win.GetLastError())
			}
		}
	}

	// 5. splice into the PEB loader list (external debuggers).
	when #config(LP_NO_PEB, false) {
	} else {
		o.ldr = lp_peb_splice(o.block, size_of_image, img_path, base_name)
	}

	fmt.printfln("[livepatch] debug: module at %p (%d funcs) -> %s", o.block, len(funcs), pdb_name)
}

// Loads an emitted lp_%p.dll into the in-process DbgHelp session so the app's own
// backtraces/crash dumps resolve hot frames to source. The loader's session enables
// deferred loads but not lines; add lines here.
@(private)
lp_debug_symload :: proc(img_path: string, base: rawptr, size: u32, loaded: ^bool) {
	if !lp_dbghelp_ensure() { return }
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	lm := SymLoadModuleExW(win.GetCurrentProcess(), nil, win.utf8_to_wstring(img_path), nil, win.DWORD64(uintptr(base)), size, nil, 0)
	loaded^ = lm != 0
	when #config(LP_DBG_SELFTEST, false) {
		fmt.printfln("[livepatch] debug self-test: SymLoadModuleExW(%s @ %p, size 0x%x) -> 0x%x (err %v)", img_path, base, size, lm, win.GetLastError())
	}
}

@(private)
lp_sections_for_pdb :: proc(o: ^Obj, alloc: runtime.Allocator) -> []Pdb_Section {
	secs := make([dynamic]Pdb_Section, alloc)
	for i in 0 ..< o.n_sections {
		if o.offsets[i+1] < 0 { continue }
		sh := section_header(o.data, o.sec_off, i)
		sz := u32(max(int(sh.virtual_size), int(sh.size_of_raw_data)))
		append(&secs, Pdb_Section{
			name = strings.clone(section_name(sh), alloc),
			rva = u32(o.offsets[i+1]),
			vsize = sz, rawsize = sz, raw_ptr = u32(o.offsets[i+1]),
			characteristics = lp_sect_chars(u32(sh.characteristics)),
		})
	}
	append(&secs, Pdb_Section{
		name = ".rdata0", rva = u32(o.dbg_off), vsize = u32(PAGE), rawsize = u32(PAGE),
		raw_ptr = u32(o.dbg_off), characteristics = 0x40000040,
	})
	return secs[:]
}

@(private)
lp_peb_splice :: proc(base: rawptr, size: u32, full, base_name: string) -> ^Lp_Ldr_Entry {
	peb := lp_read_peb()
	if peb == 0 { return nil }
	ldr := (^^u8)(peb + 0x18)^
	if ldr == nil { return nil }
	la := uintptr(ldr)
	in_load := (^win.LIST_ENTRY)(la + 0x10)
	in_mem  := (^win.LIST_ENTRY)(la + 0x20)
	in_init := (^win.LIST_ENTRY)(la + 0x30)

	e := new(Lp_Ldr_Entry, runtime.heap_allocator())
	e.DllBase = base
	e.SizeOfImage = size
	e.FullDllName = lp_make_ustr(full)
	e.BaseDllName = lp_make_ustr(base_name)
	e.ObsoleteLoadCount = 0xFFFF // pinned
	// Give the entry a valid DdagNode so ntdll's per-thread loader walk
	// (LdrpInitializeThread, which runs when a debugger spawns its break-in thread)
	// doesn't dereference a null pointer. State < LdrModulesReadyToRun(9) makes that
	// walk's `cmp State,9; jl skip` take the skip branch, so our synthetic module is
	// passed over before the loader ever touches EntryPoint / TLS. A debugger reads
	// DllBase+names and loads the PDB regardless of this internal field.
	e.DdagNode = &e._ddag_storage
	e._ddag_storage.State = 7    // LdrModulesReadyToLoad — a benign "not ready-to-run" state
	e.Flags |= 0x00040000        // LDRP_DONT_CALL_FOR_THREADS — belt-and-suspenders
	_ = in_init
	lp_list_insert_tail(in_load, &e.InLoadOrderLinks)
	lp_list_insert_tail(in_mem,  &e.InMemoryOrderLinks)

	when #config(LP_DBG_SELFTEST, false) {
		// Walk InLoadOrderModuleList to confirm integrity + our entry is present.
		n := 0; mine := false
		for p := in_load.Flink; p != in_load && n < 200; p = p.Flink {
			le := (^Lp_Ldr_Entry)(p) // InLoadOrderLinks is at offset 0
			if le.DllBase == base { mine = true }
			n += 1
		}
		fmt.printfln("[livepatch] debug self-test: PEB walk ok, %d modules, ours present=%v", n, mine)
	}
	// Deliberately not spliced into InInitializationOrderModuleList: module
	// enumerators (PSAPI/dbghelp) walk load/memory order; init order is loader-owned.
	return e
}

// Removes a previously spliced PEB loader entry and frees it. Runs at generation
// retirement, when no thread executes in the block, so the list edit is unobserved.
@(private)
lp_peb_unsplice :: proc(e: ^Lp_Ldr_Entry) {
	if e == nil { return }
	lp_list_remove(&e.InLoadOrderLinks)
	lp_list_remove(&e.InMemoryOrderLinks)
	if e.FullDllName.Buffer != nil { free(rawptr(e.FullDllName.Buffer), runtime.heap_allocator()) }
	if e.BaseDllName.Buffer != nil { free(rawptr(e.BaseDllName.Buffer), runtime.heap_allocator()) }
	free(e, runtime.heap_allocator())
}

// ---- small helpers ----
@(private)
filepath_dir_of_exe :: proc(alloc: runtime.Allocator) -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetModuleFileNameW(nil, &buf[0], win.MAX_PATH)
	s, _ := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), alloc)
	if idx := strings.last_index_any(s, "\\/"); idx >= 0 {
		return s[:idx]
	}
	return "."
}

@(private)
os2_write :: proc(path: string, data: []u8) -> bool {
	err := os.write_entire_file(path, data)
	return err == nil
}

// Deletes stale `lp_<addr>.dll` / `lp_<addr>.pdb` debug modules left next to the exe
// by earlier runs. A process that exits — or crashes — never retires its last live
// generation, so that generation's files stay on disk; because each run maps at a
// fresh base address the filenames differ, so across many dev iterations they pile
// up. Called once, before this process emits any of its own (see apply_many), so
// only prior runs' files are swept, never a still-live generation's. Best-effort: a
// file another live process still has section-mapped can't be removed and is simply
// skipped (Windows denies deleting an open image mapping), as is any other failure.
@(private)
lp_sweep_stale_debug_files :: proc() {
	dir := filepath_dir_of_exe(context.temp_allocator)
	for suffix in ([?]string{"dll", "pdb"}) {
		pattern := fmt.tprintf("%s\\lp_*.%s", dir, suffix)
		matches, err := filepath.glob(pattern, context.temp_allocator)
		if err != nil {
			continue
		}
		for m in matches {
			os.remove(m)
		}
	}
}
