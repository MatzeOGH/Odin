#+build windows
package hot_reload

// Live++-style in-process hot reload for Odin (Windows / x64).
//
// Recompile with SEPARATE modules to a directory of COFF objects (one per package):
//
//     odin build <pkg> -build-mode:obj -hot-reload -hot-reload-manifest:<path> -out:<dir>/hot.obj
//
// then call `apply_dir("<dir>")` from the running process (or `apply_many({...})` with an
// explicit list; `apply("one.obj")` still works for a single object). The objects are loaded
// directly into the process (no DLL), relocated against the exe AND each other, and the
// prologue of each running hot procedure whose code changed is overwritten with a jump to the
// fresh code. Existing direct calls reach the new code; the process never restarts and its
// state is untouched.
//
// The reload set is small: the standard-library collections (base/core/vendor) are NOT
// emitted on a reload build — that code is already in the running exe and is resolved from its
// PDB — and an UNCHANGED user package is not re-emitted either. So a reload typically produces
// just the default/metadata object plus the package(s) actually edited. The loader maps every
// object before relocating, so a new procedure/global defined in one object is reachable from
// another (a cross-object reference beyond signed-32-bit REL32 range goes through a near
// trampoline, like any far external).
//
// Relocations against *external* symbols (other procedures, runtime helpers, and
// globals) are resolved against the addresses in the already-running process by
// looking each name up in the exe's PDB (DbgHelp `SymFromNameW`) — no symbol table
// is baked into the exe. A relocation to an existing global resolves to the exe's
// copy, so global state is preserved. The set of `@(hot_reload)` procedures to
// patch is recovered structurally: a hot procedure's running entry is the 2-byte
// MSVC hot-patch slot preceded by a 16-byte patchable-function-prefix pad (see
// `hr_is_hot_entry`), which ordinary prologues never look like.
//
// New symbols across a reload:
//   - New *procedures* called from hot code link automatically (their code lives
//     in the loaded object; callers reach them via relocations).
//   - New *globals* are placed by the compiler into a reserved arena
//     (`__odin_hot_reload_global_arena`) that lives in the exe, so references
//     resolve to stable in-image storage and their state persists across every
//     subsequent reload. New globals are zero-initialized.
//
// Build the exe with `-hot-reload -debug` (and the same `-hot-reload-manifest`) so
// the arena exists and a PDB is present next to the exe; the loader needs the PDB
// to resolve the running exe's symbols. `-hot-reload` requires `-debug`.
//
// The object's `.pdata`/`.xdata` unwind info is registered with `RtlAddFunctionTable`
// (with the loaded block as the image base), so Windows x64 stack walking works through
// hot code: `panic`/`assert` backtraces, the runtime's hardware-fault handler, and a
// debugger's call stack all unwind correctly across hot frames. This is about stack
// *unwinding* (Odin has no exceptions); it does not make hot code source-debuggable.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

// --- COFF on-disk structures (x64) -----------------------------------------

Coff_File_Header :: struct #packed {
	machine:                 u16le,
	number_of_sections:      u16le,
	time_date_stamp:         u32le,
	pointer_to_symbol_table: u32le,
	number_of_symbols:       u32le,
	size_of_optional_header: u16le,
	characteristics:         u16le,
}

Coff_Section_Header :: struct #packed {
	name:                    [8]u8,
	virtual_size:            u32le,
	virtual_address:         u32le,
	size_of_raw_data:        u32le,
	pointer_to_raw_data:     u32le,
	pointer_to_relocations:  u32le,
	pointer_to_line_numbers: u32le,
	number_of_relocations:   u16le,
	number_of_line_numbers:  u16le,
	characteristics:         u32le,
}

Coff_Symbol :: struct #packed {
	name:                  [8]u8,
	value:                 u32le,
	section_number:        i16le,
	type:                  u16le,
	storage_class:         u8,
	number_of_aux_symbols: u8,
}

Coff_Reloc :: struct #packed {
	virtual_address:    u32le,
	symbol_table_index: u32le,
	type:               u16le,
}

IMAGE_FILE_MACHINE_AMD64 :: 0x8664
IMAGE_SCN_MEM_EXECUTE    :: 0x20000000 // section characteristic: executable (code)
IMAGE_SCN_MEM_WRITE      :: 0x80000000 // section characteristic: writable (.data/.bss)

// x64 relocation kinds we handle.
IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_ADDR32NB :: 0x03 // 32-bit image-base-relative RVA (.pdata/.xdata unwind)
IMAGE_REL_AMD64_REL32    :: 0x04 // ..= 0x09 for REL32_1 .. REL32_5
IMAGE_REL_AMD64_SECREL :: 0x0B // 32-bit offset of a symbol from the start of its section (TLS access)

COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

// One entry of the compiler-emitted `__odin_hot_reload_new_global_inits` table: a
// new global's compile-time constant initializer. The loader copies `size` bytes
// from `blob` into the exe arena at `arena_offset`, once, gated by the arena byte
// at `flag_offset`. Layout must match the C++ emitter in src/llvm_backend.cpp.
New_Global_Init :: struct {
	arena_offset: i64,
	flag_offset:  i64,
	size:         i64,
	blob:         rawptr,
}

// One layout change discovered by diffing the exe's baked type-info (old) against
// the reload object's freshly emitted type-info (new). `old` is the layout the
// running program was built with (also what `type_info_of` returns in hot code);
// `new` is the reloaded layout. A `@(post_patch_hook)` MUST reflect via `new`,
// because `type_info_of` in hot code still resolves to the exe's old table.
Type_Change :: struct {
	old: ^runtime.Type_Info,
	new: ^runtime.Type_Info,
}

// A `@(pre_patch_hook)` / `@(post_patch_hook)` procedure. Called by the loader with
// the set of types whose layout changed this reload. Signature enforced by the
// compiler (see check_decl.cpp). A hook runs inside the reload call, so its
// `context.temp_allocator` is the loader's private per-reload arena (freed when the
// reload returns) — do not stash temp allocations expected to outlive the call.
Patch_Hook :: #type proc(changed: []Type_Change)

// One entry of the compiler-emitted `__odin_hot_reload_{pre,post}_patch_hooks` table
// (src/llvm_backend.cpp): the exported SYMBOL NAME of a hook procedure. The loader
// resolves the name itself — pre hooks against the exe (old code), post hooks against
// the reloaded object (new code) — so a post hook need not be a patchable/hot proc.
Patch_Hook_Entry :: struct {
	name:     [^]u8,
	name_len: i64,
}

// Layout of `__odin_hot_reload_{pre,post}_patch_hooks`: a count followed by that many
// name entries.
Patch_Hook_Table :: struct {
	count:   i64,
	entries: [0]Patch_Hook_Entry, // variable-length; `count` entries follow inline
}

// Number of hooks in the table at `tbl_addr` (nil = none).
@(private)
hr_hook_count :: proc(tbl_addr: rawptr) -> int {
	if tbl_addr == nil {
		return 0
	}
	return int((^Patch_Hook_Table)(tbl_addr).count)
}

// Call every hook named in the table at `tbl_addr` (nil = none) with `changed`,
// resolving each name to a procedure address via `resolve` (PDB for pre hooks,
// object-local for post hooks). A name that fails to resolve is skipped with a warning.
@(private)
hr_call_patch_hooks :: proc(tbl_addr: rawptr, changed: []Type_Change, resolve: proc(name: string, ctx: rawptr) -> rawptr, ctx: rawptr) {
	if tbl_addr == nil {
		return
	}
	tbl := (^Patch_Hook_Table)(tbl_addr)
	entries := ([^]Patch_Hook_Entry)(uintptr(tbl_addr) + size_of(i64))
	for i in 0 ..< int(tbl.count) {
		e := entries[i]
		name := string(e.name[:e.name_len])
		addr := resolve(name, ctx)
		if addr == nil {
			fmt.eprintfln("[hot] could not resolve patch hook %q; skipping", name)
			continue
		}
		hook := (Patch_Hook)(addr)
		hook(changed)
	}
}

// The compiler publishes `[]^runtime.Type_Info` under this name in both the exe and
// every reload object (src/llvm_backend_type.cpp) — the same backing giant array the
// runtime `type_table` slices, but externally named so the loader can resolve the
// exe's copy (old layouts, via the PDB) and the object's copy (new layouts).
HR_TYPE_INFOS_SYM :: "__odin_hot_reload_type_infos"

// True iff `a` (old) and `b` (new) describe the same NAMED type but a changed layout.
// Catches: size change; struct field add / remove / reorder / rename (compares each
// field's name + offset); enum constant add / remove / reorder / rename / re-value
// (compares each name + value); and a kind change (e.g. struct -> enum) at the same
// size. // ponytail: unions/bit-sets still fall back to size only — extend if needed.
@(private)
hr_layout_differs :: proc(a, b: ^runtime.Type_Info) -> bool {
	ba := runtime.type_info_base(a)
	bb := runtime.type_info_base(b)
	if ba == nil || bb == nil {
		return false
	}
	if ba.size != bb.size {
		return true
	}

	sa, a_struct := ba.variant.(runtime.Type_Info_Struct)
	sb, b_struct := bb.variant.(runtime.Type_Info_Struct)
	if a_struct != b_struct { // one is a struct, the other isn't: incompatible kind
		return true
	}
	if a_struct && b_struct {
		if sa.field_count != sb.field_count {
			return true
		}
		for i in 0 ..< int(sa.field_count) {
			if sa.names[i] != sb.names[i] || sa.offsets[i] != sb.offsets[i] {
				return true
			}
		}
		return false
	}

	ea, a_enum := ba.variant.(runtime.Type_Info_Enum)
	eb, b_enum := bb.variant.(runtime.Type_Info_Enum)
	if a_enum != b_enum {
		return true
	}
	if a_enum && b_enum {
		if len(ea.names) != len(eb.names) {
			return true
		}
		for i in 0 ..< len(ea.names) {
			if ea.names[i] != eb.names[i] || ea.values[i] != eb.values[i] {
				return true
			}
		}
		return false
	}

	ua, a_union := ba.variant.(runtime.Type_Info_Union)
	ub, b_union := bb.variant.(runtime.Type_Info_Union)
	if a_union != b_union {
		return true
	}
	if a_union && b_union {
		if len(ua.variants) != len(ub.variants) || ua.tag_offset != ub.tag_offset {
			return true
		}
		// Variant identity by name, order-sensitive: catches reorder / add / remove /
		// replace (any of which shifts the tag value a live union stores).
		for i in 0 ..< len(ua.variants) {
			na, _ := ua.variants[i].variant.(runtime.Type_Info_Named)
			nb, _ := ub.variants[i].variant.(runtime.Type_Info_Named)
			if hr_qualified_name(na) != hr_qualified_name(nb) {
				return true
			}
		}
		return false
	}

	return false // same size, same (other) kind: treat as unchanged for the first pass
}

// Read a `[]^runtime.Type_Info` published at `tbl_addr` (nil = none).
@(private)
hr_read_type_infos :: proc(tbl_addr: rawptr) -> []^runtime.Type_Info {
	if tbl_addr == nil {
		return nil
	}
	return (^[]^runtime.Type_Info)(tbl_addr)^
}

@(private)
hr_qualified_name :: proc(named: runtime.Type_Info_Named) -> string {
	return fmt.tprintf("%s.%s", named.pkg, named.name)
}

// The exe's named types indexed by package-qualified name. The exe never changes across
// reloads, so this is built once and reused (the map + its keys live for the process).
@(private) hr_exe_types_cache: map[string]^runtime.Type_Info
@(private) hr_exe_types_built: bool

@(private)
hr_exe_types_by_name :: proc() -> map[string]^runtime.Type_Info {
	if hr_exe_types_built {
		return hr_exe_types_cache
	}
	hr_exe_types_built = true
	old_tis := hr_read_type_infos(hr_resolve_pdb(HR_TYPE_INFOS_SYM))
	// Process-lifetime map + keys: pin to the OS heap so they never alias the caller's
	// (possibly scoped/temporary) allocator — see the allocator note on `apply`.
	hr_exe_types_cache = make(map[string]^runtime.Type_Info, runtime.heap_allocator())
	for ti in old_tis {
		if ti == nil { continue }
		if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
			key := strings.clone(hr_qualified_name(named), runtime.heap_allocator())
			hr_exe_types_cache[key] = ti
		}
	}
	return hr_exe_types_cache
}

// Diff the reloaded object's freshly emitted type-info (new layout) against the exe's
// baked type-info (old layout) and return one `Type_Change` per NAMED type whose layout
// differs. `old` comes from the exe (also what hot-code `type_info_of` returns); `new`
// comes from the object, so a post-patch hook can reflect the real new layout. The slice
// is allocated with `context.allocator` (it must outlive the user's pre-patch hook); the
// caller deletes it.
@(private)
hr_build_type_changes :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr) -> []Type_Change {
	new_addr, _ := find_symbol_address(data, sym_off, n_syms, strtab_off, section_bases, HR_TYPE_INFOS_SYM)
	new_tis := hr_read_type_infos(new_addr)
	if len(new_tis) == 0 {
		return nil
	}
	old_by_name := hr_exe_types_by_name()
	if len(old_by_name) == 0 {
		return nil
	}

	// Pass 1: the DIRECTLY changed set — every new named type whose OWN layout differs.
	direct := make(map[string]bool, context.temp_allocator)
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		q := hr_qualified_name(named)
		if old_ti, found := old_by_name[q]; found && hr_layout_differs(old_ti, ti) {
			direct[q] = true
		}
	}

	// Pass 2: flag a type if it, or anything it embeds BY VALUE, changed — so a struct
	// holding a nested enum/union that changed in place (its own size/offsets unchanged)
	// is still migrated. `memo` avoids re-walking shared subgraphs.
	memo := make(map[rawptr]bool, context.temp_allocator)
	changes := make([dynamic]Type_Change, context.allocator)
	for ti in new_tis {
		if ti == nil { continue }
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok { continue }
		old_ti, found := old_by_name[hr_qualified_name(named)]
		if !found { continue } // brand-new type: nothing to migrate from
		if hr_contains_changed(ti, direct, &memo) {
			append(&changes, Type_Change{old = old_ti, new = ti})
		}
	}
	return changes[:]
}

// True if `ti` (when named) is itself directly changed, or if any type it embeds BY
// VALUE (struct fields, array/enumerated-array elements, union variants) transitively is.
// Indirections (pointers, slices, dynamic arrays, maps) are NOT followed — their bytes
// are a fixed-size handle, so a change behind them does not shift `ti`'s layout. By-value
// embedding is acyclic in Odin, so this terminates; `memo` just prevents rework.
@(private)
hr_contains_changed :: proc(ti: ^runtime.Type_Info, direct: map[string]bool, memo: ^map[rawptr]bool) -> bool {
	if ti == nil {
		return false
	}
	if v, ok := memo[ti]; ok {
		return v
	}
	memo[ti] = false // guard (by-value graph is acyclic; this is just belt-and-suspenders)

	result := false
	if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
		if direct[hr_qualified_name(named)] {
			result = true
		}
	}

	base := runtime.type_info_base(ti)
	#partial switch b in base.variant {
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(b.field_count) {
			if hr_contains_changed(b.types[i], direct, memo) { result = true }
		}
	case runtime.Type_Info_Array:
		if hr_contains_changed(b.elem, direct, memo) { result = true }
	case runtime.Type_Info_Enumerated_Array:
		if hr_contains_changed(b.elem, direct, memo) { result = true }
	case runtime.Type_Info_Union:
		for variant in b.variants {
			if hr_contains_changed(variant, direct, memo) { result = true }
		}
	}

	memo[ti] = result
	return result
}

@(private)
hr_resolve_pre_hook :: proc(name: string, ctx: rawptr) -> rawptr {
	return hr_resolve_pdb(name)
}

@(private)
hr_resolve_post_hook :: proc(name: string, ctx: rawptr) -> rawptr {
	// `ctx` points at the whole reload set's object-local symbol map (see `apply_many`),
	// so a post-hook body may live in ANY of the reload objects, not just one.
	defs := (^map[string]rawptr)(ctx)
	if addr, ok := defs^[name]; ok {
		return addr
	}
	return nil
}

// One entry of the compiler-emitted `__odin_hot_reload_func_hashes` table: a procedure's
// change-detection hashes. `name_hash` is FNV-1a-64 of the link name (see `hr_fnv64`);
// `content_hash` is a debug-normalized hash of the procedure's code. The loader patches a
// hot procedure only when its `content_hash` differs from the currently-live one. Layout
// must match the C++ emitter (`lb_hot_reload_emit_func_hashes`) in src/llvm_backend.cpp.
Func_Hash :: struct {
	name_hash:    u64,
	content_hash: u64,
}

// FNV-1a-64 over `s` — must match the compiler's `fnv64a` used for `Func_Hash.name_hash`.
@(private)
hr_fnv64 :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(s) {
		h = (h ~ u64(s[i])) * 0x100000001b3
	}
	return h
}

// name_hash -> content_hash of every hot procedure currently LIVE in the process. Seeded
// once from the exe's baseline `__odin_hot_reload_func_hashes` and updated after each
// successful reload, so a reload patches only procedures whose content hash changed.
@(private)
_hr_cur: map[u64]u64
@(private)
_hr_cur_ready: bool

// Read a `__odin_hot_reload_func_hashes` table (layout { i64 count; Func_Hash[count] })
// at `addr` into `dst`. The entries are plain integers (no relocations), so this is valid
// on both the exe's copy (PDB address) and the reload object's mapped copy.
@(private)
hr_read_func_hashes :: proc(addr: rawptr, dst: ^map[u64]u64) {
	if addr == nil {
		return
	}
	count := (^i64)(addr)^
	entries := ([^]Func_Hash)(rawptr(uintptr(addr) + 8))
	for k in 0 ..< int(count) {
		e := entries[k]
		dst[e.name_hash] = e.content_hash
	}
}

// Whether hot procedure `name` should be patched: true iff its incoming content hash
// differs from the currently-live one. Missing hashes (older object, or a name not yet
// tracked) are treated as changed, which is always safe (at worst re-patches unchanged code).
@(private)
hr_proc_changed :: proc(name: string, obj_hashes: map[u64]u64, have_obj_hashes: bool) -> bool {
	if !have_obj_hashes {
		return true
	}
	nh := hr_fnv64(name)
	obj_ch, has_obj := obj_hashes[nh]
	cur, has_cur := _hr_cur[nh]
	if has_obj && has_cur {
		return obj_ch != cur
	}
	return true
}

// Guards against a concurrent or nested reload. `apply`/`load_and_patch` are NOT
// re-entrant or thread-safe: they mutate process-lifetime state (`_hr_syms`, `_hr_cur`,
// the DbgHelp session) with no synchronization. The guard makes a second overlapping
// reload fail loudly instead of corrupting that state (finding F14).
@(private) _hr_busy: b32

// --- reload generations (deferred free of previously mapped blocks) -----------
//
// Each reload maps fresh code/data into VirtualAlloc'd blocks (the per-object block
// plus trampoline/import-cell "near" pages) and registers its `.pdata` with
// RtlAddFunctionTable. The old body stays mapped so in-flight calls in it finish on
// old code; new calls take the patched jump. So the block can only be released once NO
// thread has any frame inside it — which we test by stack-walking every (suspended)
// thread. We record each reload's allocations as a "generation" and, at the start of
// the next reload while the world is stopped, free every older generation that no thread
// still touches (retrying the rest next time — old frames drain as threads return).
// Without this, every reload leaked one block + one function-table registration.
Hr_Range :: struct {
	lo, hi: uintptr, // [lo, hi) address range of a mapped block
}
Hr_Generation :: struct {
	serial: int,                            // identity; also stored in `_hr_owner` for live-reference tracking
	blocks: [dynamic]rawptr,                // VirtualFree(MEM_RELEASE): object blocks + near pages
	pdata:  [dynamic]win.PRUNTIME_FUNCTION, // RtlDeleteFunctionTable: registered unwind tables
	ranges: [dynamic]Hr_Range,              // membership test for the stack walk (blocks + near pages)
	owned:  [dynamic]uintptr,               // exe addresses (patched proc entries + refreshed globals) that reference this gen's blocks
}
// Process-lifetime; pinned to the OS heap (caller-independent), like `_hr_syms`.
@(private) _hr_generations: [dynamic]Hr_Generation
@(private) _hr_serial: int

// Number of reload generations whose mapped blocks are still held (not yet reclaimed).
// Bounded in steady state — old generations are freed once superseded and no thread is
// inside them. Exposed for tests/diagnostics; not part of the reload contract.
live_generations :: proc() -> int {
	return len(_hr_generations)
}
// Each exe pointer that references a mapped block — a patched hot-proc entry, or a
// refreshed @(rodata)/#load header — maps to the serial of the generation it currently
// references. A generation is reclaimable only once NONE of its owned pointers still name
// it (every one re-patched/re-refreshed by a newer generation). This is what makes freeing
// safe under change detection: a proc edited in gen K and not since keeps its entry pointing
// into gen K's block, so gen K must be kept even when no thread is currently inside it.
@(private) _hr_owner: map[uintptr]int

// True iff any suspended thread has a frame whose instruction pointer lies in `ranges`.
// Conservative: if a thread's context/stack cannot be walked cleanly, returns true (keep
// the generation) rather than risk freeing a block a thread is still executing in. The
// standard x64 table-driven unwind loop (works through hot frames because their `.pdata`
// is still registered until we free them).
@(private)
hr_thread_touches :: proc(h: win.HANDLE, ranges: [dynamic]Hr_Range) -> bool {
	ctx: win.CONTEXT
	ctx.ContextFlags = win.CONTEXT_FULL
	if !win.GetThreadContext(h, &ctx) {
		return true // cannot read the context -> assume it might be inside
	}
	MAX_FRAMES :: 256
	for _ in 0 ..< MAX_FRAMES {
		pc := uintptr(ctx.Rip)
		if pc == 0 {
			return false // reached the top of the stack, clean
		}
		for r in ranges {
			if pc >= r.lo && pc < r.hi {
				return true
			}
		}
		image_base: win.DWORD64
		fe := win.RtlLookupFunctionEntry(win.DWORD64(pc), &image_base, nil)
		if fe == nil {
			// Leaf function (no unwind info): the return address sits at [RSP].
			sp := uintptr(ctx.Rsp)
			if sp == 0 {
				return true // cannot step -> conservative
			}
			ctx.Rip = win.DWORD64((^uintptr)(sp)^)
			ctx.Rsp = win.DWORD64(sp + 8)
		} else {
			handler_data: rawptr
			establisher:  win.DWORD64
			win.RtlVirtualUnwind(0, image_base, win.DWORD64(pc), fe, &ctx, &handler_data, &establisher, nil)
		}
	}
	return true // walk too deep -> conservative
}

// Free every stored generation no suspended thread still touches; keep the rest for the
// next reload. Must be called with the world stopped (contexts stable) — see the suspend
// loop in `load_and_patch`. `handles` are the suspended threads (the loader thread itself
// is excluded, and it holds no frame inside a hot block at this point).
@(private)
hr_try_free_old_generations :: proc(handles: [dynamic]win.HANDLE) {
	if len(_hr_generations) == 0 {
		return
	}
	kept := make([dynamic]Hr_Generation, 0, len(_hr_generations), runtime.heap_allocator())
	freed := 0
	for gen in _hr_generations {
		// (1) Still referenced? A patched entry or refreshed header that still names this
		// generation means the exe jumps/points into its block regardless of any thread — keep it.
		referenced := false
		for e in gen.owned {
			if _hr_owner[e] == gen.serial {
				referenced = true
				break
			}
		}
		if referenced {
			append(&kept, gen)
			continue
		}
		// (2) No live reference, but a thread may still be mid-call inside the old body — keep
		// it until the stack walk shows every thread has left.
		in_use := false
		for h in handles {
			if hr_thread_touches(h, gen.ranges) {
				in_use = true
				break
			}
		}
		if in_use {
			append(&kept, gen)
			continue
		}
		for p in gen.pdata {
			win.RtlDeleteFunctionTable(p)
		}
		for b in gen.blocks {
			win.VirtualFree(b, 0, win.MEM_RELEASE)
		}
		delete(gen.blocks)
		delete(gen.pdata)
		delete(gen.ranges)
		delete(gen.owned)
		freed += 1
	}
	delete(_hr_generations)
	_hr_generations = kept
	if freed > 0 {
		fmt.printfln("[hot] freed %d stale reload generation(s); %d still in use", freed, len(kept))
	}
}

// Reload `obj_path` into this running process, patching every `@(hot_reload)`
// procedure to its fresh implementation. The set of procedures to patch is
// discovered structurally from the running exe (see `hr_is_hot_entry`), so the
// caller does not have to list them. Returns true if every hot procedure was
// patched. The exe must have been built with `-hot-reload -debug` (a PDB next to
// the exe), which the loader uses to resolve the running exe's symbols.
//
// Call from a SINGLE thread, one reload at a time (not re-entrant — see `_hr_busy`).
// The loader is self-contained w.r.t. the caller's allocators: its process-lifetime
// state is pinned to the OS heap (independent of `context.allocator`), and all of its
// per-call scratch runs on a private arena, so it never touches the app's
// `context.temp_allocator`.
apply :: proc(obj_path: string) -> bool {
	return apply_many({obj_path})
}

// Convenience: reload every `*.obj` in `dir` as ONE multi-object set. A separate-modules
// `-build-mode:obj -hot-reload` build emits one object per (non-empty) package, so the
// caller does not have to enumerate them — point this at the output directory. Works for a
// single-object build too (one match). Order is irrelevant: the objects are all mapped
// before any relocation (see `apply_many`), so cross-object references resolve regardless.
apply_dir :: proc(dir := "hot_objs") -> bool {
	pattern := fmt.tprintf("%s/*.obj", dir)
	matches, err := filepath.glob(pattern, context.temp_allocator)
	if err != nil || len(matches) == 0 {
		fmt.eprintfln("[hot] apply_dir: no .obj files found in %q", dir)
		return false
	}
	return apply_many(matches)
}

// Self-contained rebuild: recompile the reload PATCH from inside the running program (no
// external terminal, no hand-typed `odin build`). `build_patch` shells out to
//
//     odin build <pkg_dir> -hot-reload-patch
//
// where `<pkg_dir>` is the base package directory the `-hot-reload` exe build recorded in the
// manifest. On success the reload objects are in `<pkg_dir>/hot_objs/`. `apply_patch` runs
// that and, only if it succeeds, loads them — so a compile error leaves the running code
// untouched (it just prints the compiler's diagnostics and returns false), never taking the
// session down. Typical use, from the program's own reload trigger:
//
//     if hot_reload.apply_patch() { /* new code is live */ }
//
// `odin` defaults to "odin" on PATH — pass an explicit path if it is not there. `manifest`
// defaults to "odin-hot-reload.manifest" in the working directory (where the base build writes
// it when run from the package dir) — pass the path if the app runs elsewhere. `env` is passed
// to the build process verbatim; when nil (the default) the child inherits THIS process's
// environment, so launch the app from the same shell/dev-prompt the base build used (the full
// build environment is deliberately NOT baked into the manifest — it would bloat the file and
// leak machine-specific secrets). Provide `env` only to override that.
build_patch :: proc(odin := "odin", manifest := "odin-hot-reload.manifest", env: []string = nil) -> bool {
	pkg_dir, ok := hr_manifest_pkg_dir(manifest)
	if !ok {
		fmt.eprintfln("[hot] build_patch: no pkg_dir in manifest %q (build the exe with -hot-reload first)", manifest)
		return false
	}
	return hr_run_patch_build(odin, pkg_dir, env)
}

// Rebuild the patch (see `build_patch`) and, if it succeeds, load it from
// `<pkg_dir>/hot_objs/`. Holds on a failed build (returns false without touching running code).
apply_patch :: proc(odin := "odin", manifest := "odin-hot-reload.manifest", env: []string = nil) -> bool {
	pkg_dir, ok := hr_manifest_pkg_dir(manifest)
	if !ok {
		fmt.eprintfln("[hot] apply_patch: no pkg_dir in manifest %q (build the exe with -hot-reload first)", manifest)
		return false
	}
	if !hr_run_patch_build(odin, pkg_dir, env) {
		return false
	}
	objs_dir, _ := filepath.join({pkg_dir, "hot_objs"}, context.temp_allocator)
	return apply_dir(objs_dir)
}

@(private)
hr_run_patch_build :: proc(odin: string, pkg_dir: string, env: []string) -> bool {
	cmd := []string{odin, "build", pkg_dir, "-hot-reload-patch"}
	fmt.printfln("[hot] rebuilding patch: %s build %q -hot-reload-patch", odin, pkg_dir)
	state, sout, serr, err := os.process_exec({command = cmd, env = env}, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("[hot] build failed to launch %q (is it on PATH?): %v", odin, err)
		return false
	}
	if len(sout) > 0 { fmt.print(string(sout)) }
	if len(serr) > 0 { fmt.eprint(string(serr)) }
	if state.exit_code != 0 {
		fmt.eprintfln("[hot] patch build failed (exit %d) — not reloading, running code left as-is", state.exit_code)
		return false
	}
	return true
}

// Read the base package directory the exe build recorded in the manifest.
@(private)
hr_manifest_pkg_dir :: proc(manifest_path: string) -> (string, bool) {
	data, err := os.read_entire_file(manifest_path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "pkg_dir ") {
			pd := strings.trim_space(l[len("pkg_dir "):])
			if len(pd) > 0 {
				return pd, true
			}
		}
	}
	return "", false
}

// Load a SET of COFF objects produced by a separate-modules `-build-mode:obj -hot-reload`
// build (one per user package, plus the default/metadata object), relocate them against
// the running process AND against each other, and replace every changed hot procedure with
// its fresh implementation. Symbols the objects leave undefined — chiefly the whole
// standard library, whose bodies a reload build omits — resolve from the running exe's PDB.
// Returns true if every discovered hot procedure was patched.
//
// A single-object reload is just `apply_many({one_path})`. Loading multiple objects is what
// lets a new procedure/global defined in one object be referenced from another (resolved via
// the cross-object `all_syms` map below, through a near trampoline when out of REL32 range).
apply_many :: proc(obj_paths: []string) -> bool {
	// Refuse a concurrent/nested reload rather than corrupt the shared loader state.
	if _, swapped := intrinsics.atomic_compare_exchange_strong(&_hr_busy, false, true); !swapped {
		fmt.eprintln("[hot] a reload is already in progress; apply()/apply_many() must be called from one thread, one reload at a time")
		return false
	}
	defer intrinsics.atomic_store(&_hr_busy, false)

	// Run ALL per-call scratch on a private, heap-backed arena instead of the app's
	// `context.temp_allocator`, so a whole-program reload never spikes (or on a fixed
	// `mem.Scratch_Allocator`, overflows) the application's temp arena. `context` is
	// per-call, so this override reaches every callee below and auto-restores on return;
	// `arena_destroy` frees this reload's scratch back to the heap. NOTE: user pre/post-
	// patch hooks run within this extent and thus inherit this arena as their temp
	// allocator — a hook must not rely on temp memory surviving past the reload call.
	scratch: runtime.Arena
	_ = runtime.arena_init(&scratch, 0, runtime.heap_allocator())
	context.temp_allocator = runtime.arena_allocator(&scratch)
	defer runtime.arena_destroy(&scratch)

	if len(obj_paths) == 0 {
		fmt.eprintln("[hot] apply_many: no objects given")
		return false
	}

	// Every running-exe address is resolved on demand from the exe's PDB (see
	// `hr_resolve_pdb`, which caches). `tls_cache` memoizes each thread-local's exe
	// TLS-block offset, computed lazily via its accessor when a SECREL relocation first
	// references it (shared across objects; offsets are thread- and object-independent).
	if !hr_dbghelp_ensure() {
		fmt.eprintln("[hot] could not initialize DbgHelp; is the exe built with -debug (a PDB next to it)?")
		return false
	}

	// Change detection: seed the live-hash baseline from the exe's func-hash table once,
	// then diff each reload object's hashes against it so only procedures whose code
	// changed are patched (unchanged procs — including the whole runtime and this loader —
	// are skipped). If either table is missing (older exe/object), every eligible procedure
	// is treated as changed, matching the pre-change-detection behaviour.
	if !_hr_cur_ready {
		_hr_cur = make(map[u64]u64, runtime.heap_allocator()) // process-lifetime: pin to the OS heap
		hr_read_func_hashes(hr_resolve_pdb("__odin_hot_reload_func_hashes"), &_hr_cur)
		_hr_cur_ready = true
	}

	section_header :: proc(data: []byte, sec_off, i: int) -> ^Coff_Section_Header {
		return (^Coff_Section_Header)(raw_data(data[sec_off + i*SECTION_HDR_SIZE:]))
	}

	// One reload object, mapped into its own near-exe block. Each object relocates against
	// the exe, against the other objects (via `all_syms`), and internally; a far target
	// (cross-object beyond REL32 range) is reached through this object's near trampolines.
	Obj :: struct {
		path:          string,
		data:          []byte,
		sec_off:       int,
		sym_off:       int,
		n_syms:        int,
		strtab_off:    int,
		n_sections:    int,
		section_bases: []rawptr,
		offsets:       []int,
		block:         rawptr,
		total:         int,
		text_base:     rawptr,
		text_size:     int,
		near_arena:    Near_Arena,
		resolved:      []rawptr,
		pdata_regs:    [dynamic]win.PRUNTIME_FUNCTION, // .pdata registered via RtlAddFunctionTable (for later RtlDeleteFunctionTable)
	}
	PAGE :: 0x1000

	objs := make([dynamic]Obj, 0, len(obj_paths), context.temp_allocator)

	// PASS 1a) Parse each object and lay every section out inside ONE contiguous block per
	//    object, mapped within +/-2GB of the exe. This is essential: RIP-relative (REL32)
	//    references from the loaded code to the exe's procedures/globals must fit in a
	//    signed 32-bit displacement, and inter-section REL32 references must reach across
	//    the block too. A cross-OBJECT REL32 that overflows is routed through a trampoline.
	for path in obj_paths {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintln("[hot] could not read object:", path, err)
			return false
		}
		if len(data) < FILE_HDR_SIZE {
			fmt.eprintln("[hot] object too small:", path)
			return false
		}
		hdr := (^Coff_File_Header)(raw_data(data))
		if int(hdr.machine) != IMAGE_FILE_MACHINE_AMD64 {
			fmt.eprintfln("[hot] %s: unexpected machine 0x%x (need AMD64)", path, int(hdr.machine))
			return false
		}

		o: Obj
		o.path       = path
		o.data       = data
		o.n_sections = int(hdr.number_of_sections)
		o.sec_off    = FILE_HDR_SIZE + int(hdr.size_of_optional_header)
		o.sym_off    = int(hdr.pointer_to_symbol_table)
		o.n_syms     = int(hdr.number_of_symbols)
		o.strtab_off = o.sym_off + o.n_syms*COFF_SYMBOL_SIZE

		o.section_bases = make([]rawptr, o.n_sections + 1, context.temp_allocator)
		o.offsets = make([]int, o.n_sections + 1, context.temp_allocator)
		total := 0
		for i in 0 ..< o.n_sections {
			sh := section_header(data, o.sec_off, i)
			size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
			if size == 0 {
				o.offsets[i + 1] = -1
				continue
			}
			total = ((total + PAGE - 1) / PAGE) * PAGE
			o.offsets[i + 1] = total
			total += size
		}
		total = ((total + PAGE - 1) / PAGE) * PAGE
		o.total = total

		o.block = alloc_near_exe(total)
		if o.block == nil {
			fmt.eprintln("[hot] could not reserve memory within 2GB of the exe for", path)
			return false
		}
		for i in 0 ..< o.n_sections {
			if o.offsets[i + 1] < 0 {
				continue
			}
			sh := section_header(data, o.sec_off, i)
			base := rawptr(uintptr(o.block) + uintptr(o.offsets[i + 1]))
			o.section_bases[i + 1] = base
			if int(sh.size_of_raw_data) > 0 && int(sh.pointer_to_raw_data) != 0 {
				intrinsics.mem_copy(base, raw_data(data[int(sh.pointer_to_raw_data):]), int(sh.size_of_raw_data))
			}
			if section_name(sh) == ".text" {
				o.text_base = base
				o.text_size = int(sh.size_of_raw_data)
			}
		}
		// Near-block scratch for trampolines (far REL32 targets, incl. cross-object) and
		// import cells (`__imp_X` slots), allocated near this object's block so a REL32 reaches them.
		o.near_arena = Near_Arena{
			near   = uintptr(o.block),
			tramps = make(map[uintptr]rawptr, context.temp_allocator),
			cells  = make(map[uintptr]rawptr, context.temp_allocator),
		}
		o.resolved = make([]rawptr, o.n_syms, context.temp_allocator)
		o.pdata_regs = make([dynamic]win.PRUNTIME_FUNCTION, context.temp_allocator)
		append(&objs, o)
	}

	// PASS 1b) Read the per-procedure content-hash table for change detection. It is emitted
	//    once, into the default/metadata object; find it in whichever object carries it.
	obj_hashes := make(map[u64]u64, context.temp_allocator)
	have_obj_hashes := false
	for &o in objs {
		if tbl, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_hot_reload_func_hashes"); ok {
			hr_read_func_hashes(tbl, &obj_hashes)
			have_obj_hashes = len(obj_hashes) > 0
			break
		}
	}

	// Build-identity guard (F6): refuse a reload set built against a different exe layout.
	// A stale object (base exe rebuilt, arena relaid) would resolve names and write const-init
	// blobs at now-wrong arena offsets -> silent corruption. The compiler bakes the same
	// `__odin_hot_reload_build_id` into the exe and every object built against it; mismatch
	// here means "rebuild the reload objects". Skipped if either symbol is absent (older
	// exe/object without the id), matching the func-hash "missing -> lenient" policy.
	if exe_bid := hr_resolve_pdb("__odin_hot_reload_build_id"); exe_bid != nil {
		for &o in objs {
			if obj_bid, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_hot_reload_build_id"); ok {
				exe_id := (^u64)(exe_bid)^
				obj_id := (^u64)(obj_bid)^
				if exe_id != obj_id {
					fmt.eprintfln("[hot] build-id mismatch: reload object %s (%d) was not built against the running exe (%d). Rebuild the reload objects against the current exe.", o.path, obj_id, exe_id)
					return false
				}
				break
			}
		}
	}

	// PASS 1c) Decide each DEFINED symbol's canonical runtime address across the WHOLE object
	//    set, into `all_syms` (name -> decided address; the resolution policy from the old
	//    single-object loader, now applied once per name, first-defined-wins):
	//    - defined & hot (patchable prologue in exe) & CHANGED -> the object's fresh copy (patch the entry)
	//    - defined & present in the exe (via PDB)               -> the exe's address (reuse / preserve globals)
	//    - defined & object-local                               -> the object's loaded copy (new procs/globals/constants)
	//    `all_defs` keeps the OBJECT-LOCAL address of every defined symbol (regardless of the
	//    decision) so refresh (@(rodata)/#load fresh copy) and post-patch-hook bodies resolve
	//    to the fresh code in whichever object defines them.
	all_syms := make(map[string]rawptr, context.temp_allocator)
	all_defs := make(map[string]rawptr, context.temp_allocator)
	Hot :: struct { name: string, obj: int }
	hot_names := make([dynamic]Hot, context.temp_allocator)
	for &o, oi in objs {
		i := 0
		for i < o.n_syms {
			sym := coff_symbol(o.data, o.sym_off, i)
			name := symbol_name(sym, o.data, o.strtab_off)
			sn := int(sym.section_number)
			if sn > 0 && o.section_bases[sn] != nil {
				obj_addr := rawptr(uintptr(o.section_bases[sn]) + uintptr(sym.value))
				if _, seen := all_defs[name]; !seen {
					all_defs[name] = obj_addr
				}
				if _, seen := all_syms[name]; !seen {
					exe_addr := hr_resolve_pdb(name)
					// Only a symbol defined in an executable section can be a hot procedure.
					// Restricting the (byte-reading) hot check to code symbols also avoids
					// dereferencing a data global that happens to sit next to an unmapped page.
					sh := section_header(o.data, o.sec_off, sn - 1)
					is_code := (u32(sh.characteristics) & IMAGE_SCN_MEM_EXECUTE) != 0
					if exe_addr != nil && is_code && hr_is_hot_entry(exe_addr) && hr_proc_changed(name, obj_hashes, have_obj_hashes) {
						all_syms[name] = obj_addr
						append(&hot_names, Hot{name, oi})
					} else if exe_addr != nil {
						all_syms[name] = exe_addr
					} else {
						all_syms[name] = obj_addr
					}
				}
			}
			i += 1 + int(sym.number_of_aux_symbols)
		}
	}

	// PASS 2) Resolve each object's symbol slots, then apply its relocations.
	//    A DEFINED slot takes its whole-set decision from `all_syms`. An UNDEFINED slot
	//    resolves to another reload object (via `all_syms`) if present — this is what makes
	//    a new proc/global in one object reachable from another — else to the running process
	//    (exe PDB / export / __imp_ cell) via `hr_resolve`.
	unresolved, unsupported := 0, 0
	unresolved_text := 0 // unresolved relocations that land in executable code -> fatal
	tls_cache := make(map[string]uintptr, context.temp_allocator)
	for &o in objs {
		{
			i := 0
			for i < o.n_syms {
				sym := coff_symbol(o.data, o.sym_off, i)
				name := symbol_name(sym, o.data, o.strtab_off)
				sn := int(sym.section_number)
				if sn > 0 && o.section_bases[sn] != nil {
					o.resolved[i] = all_syms[name] // decided in PASS 1c
				} else if sn == 0 {
					if a, ok := all_syms[name]; ok {
						o.resolved[i] = a // defined in another reload object
					} else {
						o.resolved[i] = hr_resolve(name, &o.near_arena)
					}
				}
				i += 1 + int(sym.number_of_aux_symbols)
			}
		}

		for si in 0 ..< o.n_sections {
			sh := section_header(o.data, o.sec_off, si)
			base := o.section_bases[si + 1]
			if base == nil {
				continue
			}
			is_text := section_name(sh) == ".text"
			nreloc := int(sh.number_of_relocations)
			roff := int(sh.pointer_to_relocations)
			for r in 0 ..< nreloc {
				rel := (^Coff_Reloc)(raw_data(o.data[roff + r*RELOC_SIZE:]))

				// Thread-local access: rewrite the per-variable SECREL offset to the
				// variable's offset in the EXE's TLS block (the object's own .tls$
				// layout differs), so hot code reads the running threads' real slots.
				if int(rel.type) == IMAGE_REL_AMD64_SECREL {
					site := uintptr(base) + uintptr(rel.virtual_address)
					usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
					sname := symbol_name(usym, o.data, o.strtab_off)
					if off, ok := hr_tls_offset(sname, &tls_cache); ok {
						// Absolute 32-bit section offset + any per-site addend already
						// present (e.g. an array-element index within the variable).
						(^u32)(site)^ = u32(off) + (^u32)(site)^
					} else {
						unresolved += 1
						if is_text {
							unresolved_text += 1
							fmt.eprintfln("[hot] thread-local not resolvable in exe (its accessor __odin_hrtls$%s is not in the exe/PDB): %s", sname, sname)
						}
					}
					continue
				}

				target := o.resolved[int(rel.symbol_table_index)]
				if target == nil {
					unresolved += 1
					if is_text {
						unresolved_text += 1
						usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
						uname := symbol_name(usym, o.data, o.strtab_off)
						fmt.eprintfln("[hot] unresolved symbol in executable code: %s", uname)
						fmt.eprintfln("[hot]   (if this is a foreign-library function: its code is not present in the running image. Reference it once in the base build, or link the archive whole, e.g. /WHOLEARCHIVE. Adding a library not linked into the base build is not supported. A base build without -debug also has no PDB to resolve non-exported symbols.)")
					}
					continue
				}
				site := uintptr(base) + uintptr(rel.virtual_address)
				switch int(rel.type) {
				case IMAGE_REL_AMD64_ADDR64:
					(^u64)(site)^ = (^u64)(site)^ + u64(uintptr(target))
				case IMAGE_REL_AMD64_REL32 ..= IMAGE_REL_AMD64_REL32 + 5:
					extra := i64(int(rel.type) - IMAGE_REL_AMD64_REL32) // REL32_1..5 bias
					addend := i64((^i32)(site)^)
					next := i64(site) + 4 + extra
					disp := i64(uintptr(target)) + addend - next
					if disp < -0x8000_0000 || disp > 0x7FFF_FFFF {
						// Target out of REL32 range (a CRT/DLL export, or a symbol in ANOTHER
						// reload object whose block landed >2GB away): route the reference
						// through a near trampoline that jumps the full 64 bits.
						final := u64(i64(uintptr(target)) + addend)
						if th := hr_trampoline_for(&o.near_arena, uintptr(final)); th != nil {
							disp = i64(uintptr(th)) - next
						} else if is_text {
							unresolved_text += 1
							fmt.eprintln("[hot] could not allocate trampoline for out-of-range target")
						}
					}
					(^i32)(site)^ = i32(disp)
				case IMAGE_REL_AMD64_ADDR32NB:
					// 32-bit image-relative RVA (fills .pdata RUNTIME_FUNCTION fields and
					// .xdata handler/chain pointers). This object lives in `o.block`, which
					// we pass to RtlAddFunctionTable as the image base, so the RVA is
					// `target - o.block` plus any inline addend (e.g. an .pdata EndAddress that
					// points at func+size). Assumes the target is in-block (always true for
					// unwind data); an external target would wrap to a bogus RVA.
					// .pdata/.xdata unwind data references THIS object's own .text/.xdata,
					// almost always via a SECTION symbol (`.text` + inline addend). Resolve
					// such a reference to the object-local section address, NOT the whole-set
					// symbol decision: a section symbol name like `.text`/`.xdata` otherwise
					// resolves against the EXE's identically-named section (PASS 1c), pushing
					// the RVA >2GB out of block so the entry is refused — leaving new/patched
					// hot procs with no usable unwind info (stack walks through them derail).
					local_target := target
					usym := coff_symbol(o.data, o.sym_off, int(rel.symbol_table_index))
					tsn := int(usym.section_number)
					if tsn > 0 && o.section_bases[tsn] != nil {
						local_target = rawptr(uintptr(o.section_bases[tsn]) + uintptr(usym.value))
					}
					addend := i64((^i32)(site)^)
					off := i64(uintptr(local_target)) - i64(uintptr(o.block))
					if off < 0 || off + addend < 0 || off + addend > i64(o.total) {
						// Target genuinely outside this object's block: the RVA would wrap.
						// Refuse rather than corrupt the unwind tables.
						unresolved += 1
						if is_text { unresolved_text += 1 }
						fmt.eprintln("[hot] ADDR32NB target out of block (RVA would wrap)")
					} else {
						(^u32)(site)^ = u32(off + addend)
					}
				case:
					unsupported += 1
				}
			}
		}

		// Freshly written executable code — make the instruction cache coherent.
		if o.text_base != nil {
			win.FlushInstructionCache(win.GetCurrentProcess(), o.text_base, win.SIZE_T(o.text_size))
		}

		// Register this object's .pdata so the OS unwinder can find unwind info for RIPs in
		// its hot code. Odin has no language exceptions, but Windows x64 stack walking is
		// table-driven (no frame-pointer chain), so these tables are what a `panic`/`assert`
		// backtrace, the runtime's hardware-fault handler (a segfault/div0 in a hot proc
		// raises SEH even without `try`), and a debugger's call-stack window all rely on.
		// The .pdata RVAs were fixed up above (ADDR32NB) relative to `o.block`, so `o.block`
		// is this object's image base. NOTE: this only fixes UNWINDING; it does not make hot
		// code source-debuggable (no PDB/module is registered for the mapped block).
		for si in 0 ..< o.n_sections {
			sh := section_header(o.data, o.sec_off, si)
			if section_name(sh) != ".pdata" {
				continue
			}
			pbase := o.section_bases[si + 1]
			if pbase == nil {
				continue
			}
			size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
			count := u32(size / size_of(win.RUNTIME_FUNCTION))
			if count > 0 {
				if !win.RtlAddFunctionTable(win.PRUNTIME_FUNCTION(pbase), win.DWORD(count), win.DWORD64(uintptr(o.block))) {
					fmt.eprintln("[hot] RtlAddFunctionTable failed; stack traces through hot code may be wrong")
				} else {
					append(&o.pdata_regs, win.PRUNTIME_FUNCTION(pbase)) // remember it so a later free can RtlDeleteFunctionTable
				}
			}
		}
	}
	if unresolved > 0 || unsupported > 0 {
		fmt.eprintfln("[hot] note: %d unresolved and %d unsupported relocations (fine if only in code you don't call)", unresolved, unsupported)
	}
	// An unresolved relocation inside executable code is a landmine: calling it jumps
	// to a bogus address and crashes. Fail loudly instead of patching in broken code.
	if unresolved_text > 0 {
		fmt.eprintfln("[hot] aborting reload: %d unresolved relocation(s) in executable code (see names above)", unresolved_text)
		return false
	}

	// PASS 3) Whole-set metadata, then patch. The metadata tables (new_global_inits,
	//    refresh_syms, pre/post patch-hook tables, type_infos) are emitted once, into the
	//    default/metadata object; locate it (it carries the func-hash table).
	meta_i := -1
	for &o, oi in objs {
		if _, ok := find_symbol_address(o.data, o.sym_off, o.n_syms, o.strtab_off, o.section_bases, "__odin_hot_reload_func_hashes"); ok {
			meta_i = oi
			break
		}
	}

	// 3.5) Apply once-only constant initializers for brand-new globals (all routed into the
	//      metadata object). Each entry copies its constant blob into the exe's arena at
	//      `arena_offset` iff the `flag` byte is still 0, then sets the flag — so re-applying
	//      never clobbers state the running program accumulated. `blob` pointers were
	//      relocated in PASS 2.
	if meta_i >= 0 {
		mo := &objs[meta_i]
		if tbl_addr, ok := find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_hot_reload_new_global_inits"); ok {
			if arena_addr := hr_resolve_pdb("__odin_hot_reload_global_arena"); arena_addr != nil {
				count := (^i64)(tbl_addr)^
				entries := ([^]New_Global_Init)(rawptr(uintptr(tbl_addr) + 8))
				for k in 0 ..< int(count) {
					e := entries[k]
					flag := (^u8)(uintptr(arena_addr) + uintptr(e.flag_offset))
					if flag^ == 0 {
						dst := rawptr(uintptr(arena_addr) + uintptr(e.arena_offset))
						intrinsics.mem_copy(dst, e.blob, int(e.size))
						flag^ = 1
					}
				}
			}
		}
	}

	// 3.6) If any pre/post-patch hook exists, diff the reload set's freshly emitted type-info
	//      (in the metadata object) against the exe's baked type_table to find every type
	//      whose layout changed, then fire the autowired pre-patch hooks — OLD code (resolved
	//      from the exe by name), while the running state is still laid out the old way, so a
	//      hook can serialize it. Skip the diff entirely when there are no hooks.
	pre_tbl := hr_resolve_pdb("__odin_hot_reload_pre_patch_hooks")
	post_tbl: rawptr
	changed: []Type_Change
	if meta_i >= 0 {
		mo := &objs[meta_i]
		post_tbl, _ = find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_hot_reload_post_patch_hooks")
		if hr_hook_count(pre_tbl) > 0 || hr_hook_count(post_tbl) > 0 {
			changed = hr_build_type_changes(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases)
		}
	}
	defer delete(changed) // outlives the pre hook; freed after the post hook
	hr_call_patch_hooks(pre_tbl, changed, hr_resolve_pre_hook, nil)

	// 3.7) Immutable-data ("refresh") globals — @(rodata) / #load — listed in the metadata
	//      object's self-contained {size, link name} blob. For every one that also exists in
	//      the exe, repoint the exe's copy at THIS reload's fresh copy (its OBJECT-LOCAL
	//      address in whichever object defines it, via `all_defs`): overwrite `size` bytes
	//      exe<-object. For a slice/string/#load global that size is the 16-byte header, so
	//      the exe header comes to point at the object's fresh blob (a data size change is
	//      free); a value-type @(rodata) is overwritten in place. Written under the
	//      stop-the-world below so a reader never sees a torn value.
	Refresh_Target :: struct {
		exe, obj: rawptr,
		size:     int,
	}
	refresh_targets := make([dynamic]Refresh_Target, context.temp_allocator)
	if meta_i >= 0 {
		mo := &objs[meta_i]
		if tbl, ok := find_symbol_address(mo.data, mo.sym_off, mo.n_syms, mo.strtab_off, mo.section_bases, "__odin_hot_reload_refresh_syms"); ok {
			p := uintptr(tbl)
			count := (^i64)(p)^
			p += 8
			for _ in 0 ..< int(count) {
				size := int((^i64)(p)^); p += 8
				nlen := int((^i64)(p)^); p += 8
				name := string(([^]u8)(rawptr(p))[:nlen]); p += uintptr(nlen)
				exe := hr_resolve_pdb(name)
				obj, found := all_defs[name]
				if exe != nil && found && size > 0 {
					append(&refresh_targets, Refresh_Target{exe, obj, size})
				}
			}
		}
	}

	// 4) Patch each discovered hot procedure's running entry to jump to its fresh code.
	//    `hot_names` were collected in PASS 1c (an exe symbol whose entry is the patchable
	//    hot-patch prologue, across ALL objects). Resolve every original (exe, via the PDB)
	//    and fresh (object) address first, then patch the whole batch with all other threads
	//    suspended and only once no thread is parked in a region we overwrite.
	if len(hot_names) == 0 && len(refresh_targets) == 0 {
		// Nothing will jump into or point at this reload's freshly-mapped blocks, and no thread
		// is inside them (nothing was patched), so free them immediately instead of leaking — a
		// no-op reload (the common change-detection case) otherwise leaked one block per reload.
		for &o in objs {
			for p in o.pdata_regs {
				win.RtlDeleteFunctionTable(p)
			}
			if o.block != nil {
				win.VirtualFree(o.block, 0, win.MEM_RELEASE)
			}
			if o.near_arena.block != nil {
				win.VirtualFree(o.near_arena.block, 0, win.MEM_RELEASE)
			}
		}
		if have_obj_hashes {
			// Change detection: no procedure's code changed since the currently-live version
			// and no immutable data to repoint — a valid no-op reload. Refresh the baseline.
			for k, v in obj_hashes {
				_hr_cur[k] = v
			}
			fmt.println("[hot] no changed procedures to patch")
			return true
		}
		fmt.eprintln("[hot] no hot-reloadable procedures found in the running exe (build it with -hot-reload -debug)")
		return false
	}
	Target :: struct {
		name:            string,
		original, fresh: rawptr,
	}
	// Resolve and validate EVERY hot target before writing a single byte: patching is
	// not transactional, so a failure discovered mid-batch would leave the program
	// half-patched. If any target cannot be resolved, abort with nothing applied.
	targets := make([dynamic]Target, context.temp_allocator)
	for h in hot_names {
		original := hr_resolve_pdb(h.name) // cached; found in PASS 1c
		fresh, found := all_syms[h.name]   // its decided (object-fresh) address
		if original == nil || !found {
			fmt.eprintfln("[hot] aborting reload: could not resolve hot procedure %q (original=%v, fresh_found=%v); nothing patched", h.name, original != nil, found)
			return false
		}
		// A proc with a usable 16-byte pad is patched atomically (writes only into its own
		// pad) and is always safe. Without a pad the fallback overwrites PATCH_LEN bytes AT
		// the entry, which would spill into the next symbol if the proc is shorter than that.
		// Validate the gap here so an unsafe overwrite aborts the whole batch before any byte
		// is written, rather than corrupting a neighbor mid-batch.
		if !hr_has_patch_pad(original) {
			gap := hr_next_symbol_after(uintptr(original)) - uintptr(original)
			if gap < PATCH_LEN {
				fmt.eprintfln("[hot] aborting reload: hot procedure %q has no patch pad and only %d bytes to its next symbol (need %d); nothing patched", h.name, gap, PATCH_LEN)
				return false
			}
		}
		append(&targets, Target{h.name, original, fresh})
	}
	// (A reload with only immutable-data changes has no proc targets but non-empty
	// refresh_targets; the empty-both case already returned above.)

	// Guard the whole region each patch may touch: the atomic path writes the 16-byte
	// pad BELOW the entry and flips the 2-byte entry; the fallback overwrites PATCH_LEN
	// bytes AT the entry. Cover [entry - PAD_LEN, entry + PATCH_LEN) so a thread parked
	// anywhere the patch writes forces a retry instead of executing a half-written byte.
	regions := make([]Patch_Region, len(targets), context.temp_allocator)
	for t, i in targets {
		lo := uintptr(t.original)
		lo = lo >= PAD_LEN ? lo - PAD_LEN : 0
		regions[i] = Patch_Region{lo, uintptr(t.original) + PATCH_LEN}
	}

	// Suspend the world; if a thread is parked in a prologue we must overwrite, let it
	// run and retry rather than corrupt it.
	MAX_ATTEMPTS :: 100
	handles: [dynamic]win.HANDLE
	for attempt := 0; ; attempt += 1 {
		handles = hr_suspend_others()
		if !hr_ip_conflicts(handles, regions) {
			break
		}
		hr_resume(handles)
		if attempt + 1 >= MAX_ATTEMPTS {
			fmt.eprintfln("[hot] aborting reload: a thread stayed inside a procedure prologue for %d attempts", MAX_ATTEMPTS)
			return false
		}
		win.Sleep(1)
	}

	// The world is stopped and contexts are stable: reclaim any earlier reload's blocks
	// that no thread still executes in (stack-walked), pairing RtlDeleteFunctionTable +
	// VirtualFree. Generations still in use are retried next reload. Done here (before the
	// patch) so a just-freed range could even be reused for the next mapping.
	hr_try_free_old_generations(handles)

	// This reload's generation identity. Every exe pointer we make reference this reload's
	// blocks (a refreshed @(rodata)/#load header, a patched proc entry) is stamped into
	// `_hr_owner` with this serial, so a later reload knows when those references have all
	// moved on and the block is reclaimable. `owned` (heap-pinned) is that pointer set.
	_hr_serial += 1
	gen_serial := _hr_serial
	gen_owned := make([dynamic]uintptr, runtime.heap_allocator())

	// Repoint immutable-data globals now that the world is stopped (no torn reads). Each
	// copy is `size` bytes exe<-object: a slice/string/#load header (16 bytes) starts
	// pointing at the object's fresh blob; a value-type @(rodata) is overwritten in place.
	for r in refresh_targets {
		old: win.DWORD
		if win.VirtualProtect(r.exe, win.SIZE_T(r.size), win.PAGE_READWRITE, &old) {
			intrinsics.mem_copy(r.exe, r.obj, r.size)
			restored: win.DWORD
			win.VirtualProtect(r.exe, win.SIZE_T(r.size), old, &restored)
			// The exe copy now references this reload's block (header -> object blob, or an
			// in-place value that lives with the block's generation); track it so the block
			// this refresh points into is not freed until a later reload re-refreshes it.
			_hr_owner[uintptr(r.exe)] = gen_serial
			append(&gen_owned, uintptr(r.exe))
		} else {
			fmt.eprintfln("[hot] could not make @(rodata)/#load copy writable to refresh it (%d bytes @ %p)", r.size, r.exe)
		}
	}
	if len(refresh_targets) > 0 {
		fmt.printfln("[hot] refreshed %d @(rodata)/#load global(s)", len(refresh_targets))
	}

	patched := 0
	for t in targets {
		ok, atomic := patch_jump(t.original, t.fresh)
		if ok {
			fmt.printfln("[hot] patched %s: %p -> %p (%s)", t.name, t.original, t.fresh, atomic ? "atomic" : "overwrite")
			patched += 1
			// This entry now jumps into this reload's block; record the ownership so the block
			// is kept alive until every proc it provides has been re-patched by a later reload.
			_hr_owner[uintptr(t.original)] = gen_serial
			append(&gen_owned, uintptr(t.original))
		}
	}
	hr_resume(handles)
	// 5) Tighten every object's block from RWX to per-section protections now that all
	//    relocations, refresh copies, and patches are done: executable code -> execute+read;
	//    read-only data (@(rodata)/#load payloads, unwind tables) -> read-only so a stray
	//    write faults as in a normal build; real data (.data/.bss) -> read+write.
	for &o in objs {
		for i in 0 ..< o.n_sections {
			if o.offsets[i + 1] < 0 {
				continue
			}
			sh := section_header(o.data, o.sec_off, i)
			base := o.section_bases[i + 1]
			size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
			if size <= 0 || base == nil {
				continue
			}
			psize := win.SIZE_T(((size + PAGE - 1) / PAGE) * PAGE)
			ch := u32(sh.characteristics)
			prot: win.DWORD = win.PAGE_READONLY
			if (ch & IMAGE_SCN_MEM_EXECUTE) != 0 {
				prot = win.PAGE_EXECUTE_READ
			} else if (ch & IMAGE_SCN_MEM_WRITE) != 0 {
				prot = win.PAGE_READWRITE
			}
			old: win.DWORD
			win.VirtualProtect(base, psize, prot, &old)
		}
	}

	if patched != len(targets) {
		return false
	}

	// The reload set is now the live version: update the change-detection baseline so the
	// next reload diffs against it (patched procs get their new hash; unchanged procs keep
	// theirs; newly added procs are recorded).
	for k, v in obj_hashes {
		_hr_cur[k] = v
	}

	// 6) Fire the autowired post-patch hooks — NEW code: each is resolved to its OBJECT-LOCAL
	//    (fresh) copy by name across the whole reload set (via `all_defs`), so a hook body may
	//    live in any object. A hook allocates the new layout and deserializes what a pre-patch
	//    hook saved. Reflecting the new layout requires `change.new` (not `type_info_of`).
	hr_call_patch_hooks(post_tbl, changed, hr_resolve_post_hook, &all_defs)

	// Record this reload's allocations as a generation so the NEXT reload can free them once
	// no thread executes in them (see hr_try_free_old_generations). Pinned to the OS heap —
	// process-lifetime, caller-allocator-independent, like `_hr_syms`.
	{
		gen: Hr_Generation
		gen.serial = gen_serial
		gen.owned  = gen_owned
		gen.blocks = make([dynamic]rawptr, runtime.heap_allocator())
		gen.pdata  = make([dynamic]win.PRUNTIME_FUNCTION, runtime.heap_allocator())
		gen.ranges = make([dynamic]Hr_Range, runtime.heap_allocator())
		for &o in objs {
			if o.block != nil {
				append(&gen.blocks, o.block)
				append(&gen.ranges, Hr_Range{uintptr(o.block), uintptr(o.block) + uintptr(o.total)})
			}
			// The near arena's final page (trampolines + import cells) is jumped-to/read by
			// the patched code, so a thread can be parked in a trampoline: track + free it too.
			// ponytail: only the LAST near page is captured; if the arena overflowed >4 KiB of
			// thunks in one reload it already orphaned earlier pages (a pre-existing rare leak).
			if o.near_arena.block != nil {
				append(&gen.blocks, o.near_arena.block)
				append(&gen.ranges, Hr_Range{uintptr(o.near_arena.block), uintptr(o.near_arena.block) + uintptr(o.near_arena.cap)})
			}
			for p in o.pdata_regs {
				append(&gen.pdata, p)
			}
		}
		if _hr_generations == nil {
			_hr_generations = make([dynamic]Hr_Generation, runtime.heap_allocator())
		}
		append(&_hr_generations, gen)
	}
	return true
}

// Find a defined function symbol by name and return its runtime address in the
// freshly mapped code.
find_symbol_address :: proc(data: []byte, sym_off, n_syms, strtab_off: int, section_bases: []rawptr, name: string) -> (addr: rawptr, ok: bool) {
	i := 0
	for i < n_syms {
		sym := coff_symbol(data, sym_off, i)
		sn := int(sym.section_number)
		if sn > 0 && section_bases[sn] != nil && symbol_name(sym, data, strtab_off) == name {
			return rawptr(uintptr(section_bases[sn]) + uintptr(sym.value)), true
		}
		i += 1 + int(sym.number_of_aux_symbols)
	}
	return nil, false
}

PATCH_LEN :: 14 // bytes of a `FF 25` RIP-relative absolute indirect jump
PAD_LEN   :: 16 // pre-function pad reserved by `/FUNCTIONPADMIN:16` (see -hot-reload linker flags)

HR_DEBUG_PAD :: #config(HR_DEBUG_PAD, false) // dump pad + entry bytes on each patch

// True iff the 16-byte pad immediately before `entry` is a usable patch pad: still
// the compiler-emitted `patchable-function-prefix` filler (0x90 NOP, or 0xCC if a
// linker also padded), or already holding our own jump (FF 25 ...) from a previous
// reload. `entry` must be at least PAD_LEN into the image.
@(private)
hr_has_patch_pad :: proc(entry: rawptr) -> bool {
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 {
		return true
	}
	for i in 0 ..< PATCH_LEN {
		if pb[i] != 0x90 && pb[i] != 0xCC {
			return false
		}
	}
	return true
}

// True iff the running procedure at `entry` is an `@(hot_reload)` procedure. Such a
// procedure is emitted with the compiler's 16-byte `patchable-function-prefix`
// immediately before its entry, filled with NOPs (0x90). `prologue-short-redirect`
// keeps the entry a normal (>=2 byte) prologue; the redirect lives in that pad. So the
// structural signal is the pad, not the entry bytes: 16 bytes of 0x90 (fresh), or —
// after a previous reload — our own far jump (starts FF 25) written into it. Ordinary
// procedures carry no such 16-byte NOP prefix, and data symbols aren't 0x90-filled, so
// this recovers the hot set from the running exe with no baked table or metadata
// section. Reads only; `entry` is a running-exe address from the PDB (or an object
// copy). NOTE: this is the contract with the compiler (src/llvm_backend_proc.cpp): if
// the prefix size or fill byte changes, update PAD_LEN / this check to match.
@(private)
hr_is_hot_entry :: proc(entry: rawptr) -> bool {
	if uintptr(entry) < PAD_LEN {
		return false
	}
	pb := ([^]u8)(rawptr(uintptr(entry) - PAD_LEN))
	if pb[0] == 0xFF && pb[1] == 0x25 { // already redirected by a previous reload
		return true
	}
	for i in 0 ..< PAD_LEN { // fresh: the compiler-emitted NOP prefix
		if pb[i] != 0x90 {
			return false
		}
	}
	return true
}

// Write a RIP-relative absolute indirect jump at `dst`:
//   FF 25 00 00 00 00   <qword target>
// (disp32 = 0, so the 64-bit target sits inline right after the 6-byte opcode).
// `dst` must already be writable. Shared by the pad/prologue patchers and the
// far-call trampoline.
@(private)
hr_write_abs_jump :: proc(dst: [^]u8, target: rawptr) {
	dst[0] = 0xFF; dst[1] = 0x25
	dst[2] = 0x00; dst[3] = 0x00; dst[4] = 0x00; dst[5] = 0x00
	(^u64)(&dst[6])^ = u64(uintptr(target))
}

// Redirect the running procedure at `original` to `target`. Prefers the atomic
// short-jump publish (Layer 2) and falls back to the 14-byte prologue overwrite.
// Must be called with all other threads suspended (see `hr_suspend_others`) so the
// pad write and any fallback overwrite cannot race a concurrently executing thread.
// Returns whether the patch succeeded and which path was taken.
patch_jump :: proc(original: rawptr, target: rawptr) -> (ok: bool, atomic: bool) {
	if hr_patch_atomic(original, target) {
		return true, true
	}
	return hr_patch_overwrite(original, target), false
}

// Atomic publish via the MSVC-style hotpatch prologue + `/FUNCTIONPADMIN` pad:
//   1. write the full 14-byte far jump into the 16-byte pad ahead of the function
//      (nobody executes the pad, so this write is invisible to running code);
//   2. flip the 2-byte hotpatch entry (`mov edi,edi` = 8B FF) to `EB EE`
//      (jmp -18, i.e. back to the pad) with ONE aligned 16-bit store.
// The entry is 16-byte aligned, so the 2-byte store is atomic and single-cacheline:
// every core observes either the old valid 2-byte instruction or the new valid short
// jump, never a torn mix. Returns false (so the caller falls back) if there is no
// usable pad — e.g. the exe was not built with the `-hot-reload` linker flags.
@(private)
hr_patch_atomic :: proc(original: rawptr, target: rawptr) -> bool {
	if uintptr(original) < PAD_LEN {
		return false
	}
	pad := rawptr(uintptr(original) - PAD_LEN)
	pb := ([^]u8)(pad)
	when HR_DEBUG_PAD {
		eb := ([^]u8)(original)
		fmt.eprintfln("[hot] pad@%p: % x | entry: %02x %02x", pad,
			pb[0:PAD_LEN], eb[0], eb[1])
	}
	// Usable iff the pad ahead of the entry is the compiler-emitted
	// `patchable-function-prefix` filler or already holds our own jump from a previous
	// reload; otherwise there is no pad here and we fall back to the prologue overwrite.
	if !hr_has_patch_pad(original) {
		return false
	}

	// Cover the pad through the 2-byte entry (they may straddle a page boundary).
	region_len := win.SIZE_T(PAD_LEN + 2)
	old: win.DWORD
	if !win.VirtualProtect(pad, region_len, win.PAGE_EXECUTE_READWRITE, &old) {
		return false
	}

	hr_write_abs_jump(pb, target)
	win.FlushInstructionCache(win.GetCurrentProcess(), pad, win.SIZE_T(PATCH_LEN))

	// EB EE == jmp rel8 -18: from the end of the 2-byte entry (original+2) back to
	// the pad (original-16). One atomic store; then flush the two entry bytes.
	intrinsics.atomic_store((^u16)(original), u16(0xEEEB))
	win.FlushInstructionCache(win.GetCurrentProcess(), original, 2)

	restored: win.DWORD
	win.VirtualProtect(pad, region_len, old, &restored)
	return true
}

// Fallback: overwrite the first 14 bytes of `original` with the far jump. Safe only
// because the caller has suspended every other thread (a concurrent thread could
// otherwise execute the half-written prologue). Relies on 16-byte proc alignment.
@(private)
hr_patch_overwrite :: proc(original: rawptr, target: rawptr) -> bool {
	// Belt-and-suspenders: the batch already refuses an unsafe overwrite before any write
	// (see load_and_patch's resolve-first loop), but guard here too so a direct caller can
	// never spill PATCH_LEN bytes into the next symbol.
	if gap := hr_next_symbol_after(uintptr(original)) - uintptr(original); gap < PATCH_LEN {
		fmt.eprintfln("[hot] refusing overwrite patch: only %d bytes to next symbol (need %d)", gap, PATCH_LEN)
		return false
	}
	old_protect: win.DWORD
	if !win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), win.PAGE_EXECUTE_READWRITE, &old_protect) {
		fmt.eprintln("[hot] VirtualProtect failed")
		return false
	}
	hr_write_abs_jump(([^]u8)(original), target)
	restored: win.DWORD
	win.VirtualProtect(original, win.SIZE_T(PATCH_LEN), old_protect, &restored)
	win.FlushInstructionCache(win.GetCurrentProcess(), original, win.SIZE_T(PATCH_LEN))
	return true
}

// --- thread coordination (stop-the-world patching) --------------------------
//
// Overwriting a running procedure is only safe if no other thread is executing the
// bytes being changed. We suspend every other thread in the process, verify none is
// parked in a region we will overwrite, patch, then resume. The atomic publish above
// shrinks the unsafe region to the 2-byte entry, but the pad write and the 14-byte
// fallback still need the world stopped.

Patch_Region :: struct {
	lo, hi: uintptr,
}

// Suspend every thread in this process except the caller. Returns the OpenThread
// handles of the suspended threads; pass them to `hr_resume`.
@(private)
hr_suspend_others :: proc() -> [dynamic]win.HANDLE {
	handles := make([dynamic]win.HANDLE, context.temp_allocator)
	me_pid := win.GetCurrentProcessId()
	me_tid := win.GetCurrentThreadId()
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snap == win.INVALID_HANDLE_VALUE {
		return handles
	}
	defer win.CloseHandle(snap)

	te: win.THREADENTRY32
	te.dwSize = size_of(win.THREADENTRY32)
	ok := win.Thread32First(snap, &te)
	for ok {
		if te.th32OwnerProcessID == me_pid && te.th32ThreadID != me_tid {
			h := win.OpenThread(
				win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_SET_CONTEXT,
				win.FALSE, te.th32ThreadID,
			)
			if h != nil {
				if win.SuspendThread(h) != ~win.DWORD(0) { // (DWORD)-1 on failure
					append(&handles, h)
				} else {
					win.CloseHandle(h)
				}
			}
		}
		te.dwSize = size_of(win.THREADENTRY32)
		ok = win.Thread32Next(snap, &te)
	}
	return handles
}

@(private)
hr_resume :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
}

// True if any suspended thread's instruction pointer sits inside a region we are
// about to overwrite (so patching would corrupt the instruction it will execute).
@(private)
hr_ip_conflicts :: proc(handles: [dynamic]win.HANDLE, regions: []Patch_Region) -> bool {
	for h in handles {
		ctx: win.CONTEXT
		ctx.ContextFlags = win.CONTEXT_CONTROL
		if !win.GetThreadContext(h, &ctx) {
			continue // cannot read; best-effort
		}
		rip := uintptr(ctx.Rip)
		for reg in regions {
			if rip >= reg.lo && rip < reg.hi {
				return true
			}
		}
	}
	return false
}

// --- helpers ----------------------------------------------------------------

// Reserve `size` bytes within +/-2GB of the exe's image base, so RIP-relative
// references from the loaded code to the exe resolve within a 32-bit range.
alloc_near_exe :: proc(size: int) -> rawptr {
	return alloc_near(uintptr(win.GetModuleHandleW(nil)), size)
}

// Reserve `size` bytes within +/-2GB of `near`, so a RIP-relative (REL32)
// reference from code near `near` to this block fits in a signed 32-bit range.
alloc_near :: proc(near: uintptr, size: int) -> rawptr {
	sz := win.SIZE_T(size)
	step :: uintptr(0x0010_0000) // 1 MiB (a multiple of the 64 KiB allocation granularity)
	limit :: uintptr(0x6000_0000) // stay well inside 2 GiB
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

// --- general external-symbol resolution -------------------------------------
//
// A reload object references symbols that are neither defined in the object nor
// resolvable via the exe's PDB (Odin procs/globals): C runtime helpers the backend
// synthesises (`memcpy`/`memset`/`memmove`/`memcmp`), the TLS index `_tls_index`,
// and any Windows-API import. These must resolve to an address
// in the running process, or a call through them faults. We resolve them in two
// ways, by how they can be found at runtime:
//   - exported by a loaded module  -> GetProcAddress across the process's modules
//   - non-exported but in-image     -> referenced here by exact link name

// `_tls_index` is not exported, so it can only be reached by referencing the exe's
// own copy by link name. Its VALUE names the TLS slot the running threads set up;
// reloaded code must read THIS one or it lands in the wrong slot (garbage context).
foreign {
	@(link_name="_tls_index") _hr_tls_index: u32
}

// The exe's TLS block base for the current thread: TEB.ThreadLocalStoragePointer
// (gs:[0x58], an array of per-module TLS block bases) indexed by the exe's
// `_tls_index`. Reloaded code accesses a thread-local as `base + <exe SECREL
// offset>`; the loader computes each offset relative to THIS base (offsets are
// thread-independent, so computing on the loader thread is valid for all threads).
@(private)
hr_tls_block_base :: proc "contextless" () -> uintptr {
	read_teb_tls :: asm() -> (r: u64) { mov r, [%gs:0x58]; }
	teb_tls := uintptr(read_teb_tls())
	if teb_tls == 0 {
		return 0
	}
	arr := cast([^]uintptr)teb_tls
	return arr[_hr_tls_index]
}


// Resolve an undefined-external symbol referenced by the reload object to an address
// in the running process, or nil. Handles three forms:
//   - direct Odin symbol      -> the exe's PDB (via `hr_resolve_external`)
//   - direct C/OS symbol       -> export lookup, then non-exported in-image set
//   - `__imp_X` (import cell)  -> a synthesised pointer cell holding the address of X
@(private)
hr_resolve :: proc(name: string, na: ^Near_Arena) -> rawptr {
	if p := hr_resolve_external(name); p != nil {
		return p
	}
	// `__imp_X` is an indirection slot the object reads to get X's address. There is
	// no such slot for an in-image/static symbol, so synthesise one near the block.
	IMP :: "__imp_"
	if strings.has_prefix(name, IMP) {
		real := name[len(IMP):]
		if a := hr_resolve_external(real); a != nil {
			return hr_imp_cell(na, uintptr(a))
		}
	}
	return nil
}

// Resolve `name` to an address in the running process, or nil. First an export
// lookup (covers memcpy/memset/memmove/memcmp and every Windows-API/CRT export),
// then the small set of non-exported in-image symbols, then a PDB lookup (finds
// non-exported, in-image symbols such as statically-linked foreign-library
// functions the base build linked but this source had not referenced before).
@(private)
hr_resolve_external :: proc(name: string) -> rawptr {
	if p := hr_resolve_exported(name); p != nil {
		return p
	}
	switch name {
	case "_tls_index": return &_hr_tls_index
	}
	if p := hr_resolve_pdb(name); p != nil {
		return p
	}
	return nil
}

// GetProcAddress over the always-loaded modules that carry the C-runtime surface,
// plus the exe itself. ntdll exports memcpy/memset/memmove/memcmp, so it comes first.
@(private)
hr_resolve_exported :: proc(name: string) -> rawptr {
	cname, err := strings.clone_to_cstring(name, context.temp_allocator)
	if err != nil {
		return nil
	}
	if h := win.GetModuleHandleW(nil); h != nil { // the exe
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

// Whether DbgHelp has been initialized for this process. SymInitialize with
// fInvadeProcess loads symbols for every currently-loaded module, including the
// exe's PDB — kept warm across reloads (never SymCleanup'd).
@(private)
_hr_dbghelp_ready: bool

// name -> address for every symbol in the running exe, built once by enumerating the
// exe's PDB (see `hr_dbghelp_ensure`). Exact-match lookups here, NOT `SymFromNameW`:
// Odin link names contain `[file.odin]` brackets, which DbgHelp's by-name lookup
// mis-parses as a wildcard character class and fails to match. Addresses are stable
// within a process run, so this is populated once and kept across reloads.
@(private)
_hr_syms: map[string]rawptr

// State threaded through the SymEnumSymbolsW callback: the map to fill and the Odin
// context to install (the callback is a `proc "system"` with no context of its own).
@(private)
Hr_Enum_State :: struct {
	syms: ^map[string]rawptr,
	ctx:  runtime.Context,
}

@(private)
hr_enum_cb :: proc "system" (pSym: win.PSYMBOL_INFOW, size: win.ULONG, user: win.PVOID) -> win.BOOL {
	st := (^Hr_Enum_State)(user)
	context = st.ctx
	// `Address` is only a virtual address for functions and plain data. For a
	// thread-local it is a TLS-block-relative offset, for register/frame/value
	// symbols it is not an address at all — storing those would poison the map with a
	// small integer masquerading as a pointer. Skip them (thread-locals are resolved
	// via their `__odin_hrtls$<name>` accessor, not by this direct entry).
	NON_ADDR :: win.SYMFLAG_TLSREL | win.SYMFLAG_REGISTER | win.SYMFLAG_REGREL |
	            win.SYMFLAG_FRAMEREL | win.SYMFLAG_VALUEPRESENT | win.SYMFLAG_CONSTANT
	if (u32(pSym.Flags) & NON_ADDR) != 0 {
		return win.TRUE
	}
	n := int(pSym.NameLen)
	if n > 0 {
		wname := ([^]u16)(&pSym.Name[0])
		// Keys live for the process lifetime alongside `_hr_syms`: pin to the OS heap.
		if name, err := win.utf16_to_utf8(wname[:n], runtime.heap_allocator()); err == nil && len(name) > 0 {
			// Keep the first address seen for a name; ignore later duplicates.
			if _, exists := st.syms[name]; !exists {
				st.syms[name] = rawptr(uintptr(pSym.Address))
			}
		}
	}
	return win.TRUE
}

// Initialize DbgHelp and enumerate the running exe's PDB symbols into `_hr_syms`.
// SymInitialize with fInvadeProcess loads symbols for every currently-loaded module,
// including the exe's PDB. Done once and kept warm across reloads (never SymCleanup'd).
// Returns false if there is no PDB (exe not built with -debug).
@(private)
hr_dbghelp_ensure :: proc() -> bool {
	if _hr_dbghelp_ready {
		// Success is defined as "the exe module's symbols enumerated": a missing or
		// public-only PDB yields an empty map, which must be treated as failure so the
		// loader does not silently resolve everything to fresh object-local copies.
		return len(_hr_syms) > 0
	}
	_hr_dbghelp_ready = true // attempt exactly once; a missing PDB will not appear later
	if !win.SymInitialize(win.GetCurrentProcess(), nil, true) {
		return false
	}
	win.SymSetOptions(win.SYMOPT_DEFERRED_LOADS)
	_hr_syms = make(map[string]rawptr, runtime.heap_allocator()) // process-lifetime: pin to the OS heap
	base := win.ULONG64(uintptr(win.GetModuleHandleW(nil))) // the exe's image base
	st := Hr_Enum_State{syms = &_hr_syms, ctx = context}
	// Mask nil -> every symbol in the exe module. Exact names go into the map.
	ok := win.SymEnumSymbolsW(win.GetCurrentProcess(), base, nil, hr_enum_cb, &st)
	if !ok || len(_hr_syms) == 0 {
		// No usable PDB next to the exe (or it carries no private symbols). Every
		// pre-existing symbol would otherwise fail to resolve and be silently
		// duplicated, losing state — so fail loudly instead.
		fmt.eprintfln("[hot] could not enumerate the exe's PDB symbols (SymEnumSymbolsW ok=%v, %d symbols). Build the exe with -hot-reload -debug and keep the .pdb next to it.", ok, len(_hr_syms))
		return false
	}
	return true
}

// Resolve `name` to its address in the running process via the exe's PDB. This is the
// loader's primary symbol resolver: every running procedure and global — Odin symbols,
// preserved globals, the hot procedures being patched, the new-global arena, the
// per-thread-local accessors, and non-exported statically-linked foreign functions —
// is found this way. Requires the exe to have been built with `-debug` (a PDB next to
// it); returns nil otherwise. Lookups are exact against the enumerated symbol map.
@(private)
hr_resolve_pdb :: proc(name: string) -> rawptr {
	if !hr_dbghelp_ensure() {
		return nil
	}
	return _hr_syms[name]
}

// Address of the nearest enumerated exe symbol strictly above `addr`, or max(uintptr)
// if none. Used to bound how many bytes the non-atomic prologue overwrite may safely
// write before it would spill into the next procedure/symbol (see hr_patch_overwrite).
// ponytail: O(n) scan over the symbol map; the overwrite fallback is rare, so sorting
// the addresses is unwarranted until it shows up hot.
@(private)
hr_next_symbol_after :: proc(addr: uintptr) -> uintptr {
	best := max(uintptr)
	for _, v in _hr_syms {
		a := uintptr(v)
		if a > addr && a < best {
			best = a
		}
	}
	return best
}

// The exe TLS-block offset of the thread-local named `varname`, memoized in `cache`.
// A pre-existing thread-local has no plain address; the compiler emits an accessor
// `__odin_hrtls$<varname>() -> rawptr { return &var }` whose body lowers to the exe's
// TLS access sequence. We find that accessor in the exe's PDB by its (source-stable)
// name, call it to get the variable's per-thread address, and subtract this thread's
// TLS block base — the offset is thread-independent, so computing it on the loader
// thread is valid for every thread. Returns false if the accessor is not in the exe.
@(private)
hr_tls_offset :: proc(varname: string, cache: ^map[string]uintptr) -> (uintptr, bool) {
	if off, ok := cache[varname]; ok {
		return off, true
	}
	base := hr_tls_block_base()
	if base == 0 {
		return 0, false
	}
	acc_name := strings.concatenate({"__odin_hrtls$", varname}, context.temp_allocator)
	acc := hr_resolve_pdb(acc_name)
	if acc == nil {
		return 0, false
	}
	addr := (transmute(proc "c" () -> rawptr) acc)()
	off := uintptr(addr) - base
	cache[varname] = off
	return off, true
}

// --- near-block scratch: trampolines + import cells --------------------------
//
// Both live within +/-2GB of the loaded block so a REL32 from the loaded code can
// reach them:
//   - trampoline: a resolved external (e.g. ntdll!memcpy) may sit farther than a
//     signed 32-bit displacement from the call site; we route the call through a
//     14-byte absolute jump (`FF 25 00000000; .quad target`).
//   - import cell: a `__imp_X` reference needs a pointer-sized slot holding X's
//     address; there is no such slot for an in-image symbol, so we mint one.
Near_Arena :: struct {
	near:   uintptr,            // allocate within +/-2GB of this (the loaded block)
	block:  rawptr,
	cap:    int,
	used:   int,
	tramps: map[uintptr]rawptr, // target  -> trampoline
	cells:  map[uintptr]rawptr, // address -> import cell holding it
}

@(private)
hr_near_bump :: proc(na: ^Near_Arena, n: int) -> rawptr {
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

@(private)
hr_trampoline_for :: proc(na: ^Near_Arena, target: uintptr) -> rawptr {
	if t, ok := na.tramps[target]; ok {
		return t
	}
	thunk := hr_near_bump(na, 16) // 14 bytes rounded up
	if thunk == nil {
		return nil
	}
	hr_write_abs_jump(([^]u8)(thunk), rawptr(target)) // jmp qword ptr [rip+0]; .quad target
	na.tramps[target] = thunk
	return thunk
}

@(private)
hr_imp_cell :: proc(na: ^Near_Arena, addr: uintptr) -> rawptr {
	if c, ok := na.cells[addr]; ok {
		return c
	}
	cell := hr_near_bump(na, 8)
	if cell == nil {
		return nil
	}
	(^u64)(cell)^ = u64(addr)
	na.cells[addr] = cell
	return cell
}

coff_symbol :: proc(data: []byte, sym_off, i: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[sym_off + i*COFF_SYMBOL_SIZE:]))
}

section_name :: proc(sh: ^Coff_Section_Header) -> string {
	n := 0
	for n < 8 && sh.name[n] != 0 {
		n += 1
	}
	return string(sh.name[:n])
}

symbol_name :: proc(sym: ^Coff_Symbol, data: []byte, strtab_off: int) -> string {
	// If the first 4 bytes are zero, the name is an offset into the string table.
	if sym.name[0] == 0 && sym.name[1] == 0 && sym.name[2] == 0 && sym.name[3] == 0 {
		off := int((^u32le)(&sym.name[4])^)
		p := strtab_off + off
		n := 0
		for p + n < len(data) && data[p + n] != 0 {
			n += 1
		}
		return string(data[p : p + n])
	}
	n := 0
	for n < 8 && sym.name[n] != 0 {
		n += 1
	}
	return string(sym.name[:n])
}
