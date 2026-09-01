#+build windows
package livepatch

import "base:runtime"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"

foreign {
	@(link_name="_tls_index") _lp_tls_index: u32
}

@(private)
_lp_dbghelp_ready: bool

@(private)
_lp_syms: map[string]rawptr

@(private)
Lp_Enum_State :: struct {
	syms: ^map[string]rawptr,
	ctx:  runtime.Context,
}

// A small executable arena placed within 2GB of the exe, backing the import
// cells and out-of-range trampolines a relocation may need.
Near_Arena :: struct {
	near:   uintptr,
	block:  rawptr,
	cap:    int,
	used:   int,
	tramps: map[uintptr]rawptr,
	cells:  map[uintptr]rawptr,
}

// Process-lifetime arena and registry backing the stable trampoline each
// newly-added procedure is reached through. Never freed per generation: a
// trampoline is a proc's identity across reloads, so it must outlive any single
// reload's block. (Procedures that exist in the exe already have such a cell —
// their 16-byte patch pad — so they need no entry here.)
@(private) _lp_new_arena:  Near_Arena
@(private) _lp_new_tramps: map[string]rawptr

// Returns the stable trampoline for a newly-added procedure, creating a 16-byte
// slot in the persistent near arena on first sighting. The slot's bytes (a
// 14-byte absolute jump to the current body) are written later by apply_many,
// once the reload's body address is known.
@(private)
lp_new_proc_trampoline :: proc(name: string) -> rawptr {
	if t, ok := _lp_new_tramps[name]; ok {
		return t
	}
	if _lp_new_arena.near == 0 {
		_lp_new_arena.near = uintptr(win.GetModuleHandleW(nil))
		_lp_new_tramps = make(map[string]rawptr, runtime.heap_allocator())
	}
	t := lp_near_bump(&_lp_new_arena, 16)
	if t == nil {
		return nil
	}
	_lp_new_tramps[strings.clone(name, runtime.heap_allocator())] = t
	return t
}

// Reserves executable memory within 2GB of the running exe.
alloc_near_exe :: proc(size: int) -> rawptr {
	return alloc_near(uintptr(win.GetModuleHandleW(nil)), size)
}

// Reserves size bytes of executable memory within 2GB of the given address (for x64 rel32 reach).
alloc_near :: proc(near: uintptr, size: int) -> rawptr {
	sz := win.SIZE_T(size)
	step :: uintptr(0x0010_0000)
	limit :: uintptr(0x6000_0000)
	for off := step; off <= limit; off += step {
		if near > off {
			if m := win.VirtualAlloc(rawptr(near - off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
				return m
			}
		}
		if m := win.VirtualAlloc(rawptr(near + off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
			return m
		}
	}
	return nil
}

// Returns the base of this thread's TLS block for the exe's TLS index.
@(private)
lp_tls_block_base :: proc "contextless" () -> uintptr {
	read_teb_tls :: asm() -> (r: u64) { mov r, [%gs:0x58]; }
	teb_tls := uintptr(read_teb_tls())
	if teb_tls == 0 {
		return 0
	}
	arr := cast([^]uintptr)teb_tls
	return arr[_lp_tls_index]
}

// Resolves an external symbol, routing __imp_ imports through a near indirection cell.
@(private)
lp_resolve :: proc(name: string, na: ^Near_Arena) -> rawptr {
	if p := lp_resolve_external(name); p != nil {
		return p
	}
	IMP :: "__imp_"
	if strings.has_prefix(name, IMP) {
		real := name[len(IMP):]
		if a := lp_resolve_external(real); a != nil {
			return lp_imp_cell(na, uintptr(a))
		}
	}
	return nil
}

// Resolves a symbol from the exe's exports, known specials, or the PDB.
@(private)
lp_resolve_external :: proc(name: string) -> rawptr {
	if p := lp_resolve_exported(name); p != nil {
		return p
	}
	switch name {
	case "_tls_index": return &_lp_tls_index
	}
	if p := lp_resolve_pdb(name); p != nil {
		return p
	}
	return nil
}

// Resolves a symbol exported by the exe or the common system DLLs.
@(private)
lp_resolve_exported :: proc(name: string) -> rawptr {
	cname, err := strings.clone_to_cstring(name, context.temp_allocator)
	if err != nil {
		return nil
	}
	if h := win.GetModuleHandleW(nil); h != nil {
		if p := win.GetProcAddress(h, cname); p != nil { return p }
	}
	mods := [?]win.wstring{ win.L("ntdll.dll"), win.L("ucrtbase.dll"), win.L("kernel32.dll") }
	for mn in mods {
		if h := win.GetModuleHandleW(mn); h != nil {
			if p := win.GetProcAddress(h, cname); p != nil { return p }
		}
	}
	return nil
}

// SymEnumSymbolsW callback: records each address-bearing PDB symbol into the symbol map.
@(private)
lp_enum_cb :: proc "system" (pSym: win.PSYMBOL_INFOW, size: win.ULONG, user: win.PVOID) -> win.BOOL {
	st := (^Lp_Enum_State)(user)
	context = st.ctx
	NON_ADDR :: win.SYMFLAG_TLSREL | win.SYMFLAG_REGISTER | win.SYMFLAG_REGREL |
	            win.SYMFLAG_FRAMEREL | win.SYMFLAG_VALUEPRESENT | win.SYMFLAG_CONSTANT
	if (u32(pSym.Flags) & NON_ADDR) != 0 {
		return win.TRUE
	}
	n := int(pSym.NameLen)
	if n > 0 {
		wname := ([^]u16)(&pSym.Name[0])
		if name, err := win.utf16_to_utf8(wname[:n], runtime.heap_allocator()); err == nil && len(name) > 0 {
			if _, exists := st.syms[name]; !exists {
				st.syms[name] = rawptr(uintptr(pSym.Address))
			}
		}
	}
	return win.TRUE
}

// Initializes DbgHelp and enumerates the exe's PDB symbols once; returns whether any were found.
@(private)
lp_dbghelp_ensure :: proc() -> bool {
	if _lp_dbghelp_ready {
		return len(_lp_syms) > 0
	}
	_lp_dbghelp_ready = true
	if !win.SymInitialize(win.GetCurrentProcess(), nil, true) {
		return false
	}
	win.SymSetOptions(win.SYMOPT_DEFERRED_LOADS)
	_lp_syms = make(map[string]rawptr, runtime.heap_allocator())
	base := win.ULONG64(uintptr(win.GetModuleHandleW(nil)))
	st := Lp_Enum_State{syms = &_lp_syms, ctx = context}
	ok := win.SymEnumSymbolsW(win.GetCurrentProcess(), base, nil, lp_enum_cb, &st)
	if !ok || len(_lp_syms) == 0 {
		fmt.eprintfln("[livepatch] could not enumerate the exe's PDB symbols (SymEnumSymbolsW ok=%v, %d symbols). Build the exe with -livepatch -debug and keep the .pdb next to it.", ok, len(_lp_syms))
		return false
	}
	return true
}

// Looks a symbol up in the exe's PDB symbol map.
@(private)
lp_resolve_pdb :: proc(name: string) -> rawptr {
	if !lp_dbghelp_ensure() {
		return nil
	}
	return _lp_syms[name]
}

// Returns the address of the nearest PDB symbol after addr (max(uintptr) if none), to bound a proc's extent.
@(private)
lp_next_symbol_after :: proc(addr: uintptr) -> uintptr {
	best := max(uintptr)
	for _, v in _lp_syms {
		a := uintptr(v)
		if a > addr && a < best {
			best = a
		}
	}
	return best
}

// Resolves a thread-local's offset within the TLS block via its generated accessor (cached).
@(private)
lp_tls_offset :: proc(varname: string, cache: ^map[string]uintptr) -> (uintptr, bool) {
	if off, ok := cache[varname]; ok {
		return off, true
	}
	base := lp_tls_block_base()
	if base == 0 {
		return 0, false
	}
	acc_name := strings.concatenate({"__odin_lptls$", varname}, context.temp_allocator)
	acc := lp_resolve_pdb(acc_name)
	if acc == nil {
		return 0, false
	}
	addr := (transmute(proc "c" () -> rawptr) acc)()
	off := uintptr(addr) - base
	cache[varname] = off
	return off, true
}

// Bump-allocates n bytes from the near arena, reserving a new near block if needed.
@(private)
lp_near_bump :: proc(na: ^Near_Arena, n: int) -> rawptr {
	if na.block == nil || na.used + n > na.cap {
		blk := alloc_near(na.near, 0x1000)
		if blk == nil {
			return nil
		}
		na.block = blk
		na.cap = 0x1000
		na.used = 0
	}
	p := rawptr(uintptr(na.block) + uintptr(na.used))
	na.used += n
	return p
}

// Returns (creating if needed) a near trampoline that absolute-jumps to an out-of-rel32-range target.
@(private)
lp_trampoline_for :: proc(na: ^Near_Arena, target: uintptr) -> rawptr {
	if t, ok := na.tramps[target]; ok {
		return t
	}
	thunk := lp_near_bump(na, 16)
	if thunk == nil {
		return nil
	}
	lp_write_abs_jump(([^]u8)(thunk), rawptr(target))
	na.tramps[target] = thunk
	return thunk
}

// Returns (creating if needed) a near indirection cell holding an imported symbol's address.
@(private)
lp_imp_cell :: proc(na: ^Near_Arena, addr: uintptr) -> rawptr {
	if c, ok := na.cells[addr]; ok {
		return c
	}
	cell := lp_near_bump(na, 8)
	if cell == nil {
		return nil
	}
	(^u64)(cell)^ = u64(addr)
	na.cells[addr] = cell
	return cell
}
