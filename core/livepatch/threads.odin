#+build windows
package livepatch

import "base:runtime"
import "core:fmt"
import "core:os"
import win "core:sys/windows"

foreign import lp_ntdll "system:ntdll.lib"
foreign import lp_kernel32 "system:kernel32.lib"
@(default_calling_convention="system")
foreign lp_ntdll {
	NtGetNextThread :: proc(ProcessHandle, ThreadHandle: win.HANDLE, DesiredAccess: win.ACCESS_MASK, HandleAttributes, Flags: win.ULONG, NewThreadHandle: ^win.HANDLE) -> win.NTSTATUS ---
	// The loader lock guards ntdll's PEB module lists. Taken around the post-resume PEB
	// splice (debug.odin) so a concurrent LoadLibrary/FreeLibrary/thread-start does not race
	// the list edit. MUST NOT be taken inside the thread-suspend window: a suspended thread
	// may hold it, which would deadlock.
	LdrLockLoaderLock   :: proc(Flags: win.ULONG, Disposition: ^win.ULONG, Cookie: ^uintptr) -> win.NTSTATUS ---
	LdrUnlockLoaderLock :: proc(Flags: win.ULONG, Cookie: uintptr) -> win.NTSTATUS ---
}
@(default_calling_convention="system")
foreign lp_kernel32 {
	GetThreadId :: proc(Thread: win.HANDLE) -> win.DWORD ---
}

// A half-open address range [lo, hi).
Lp_Range :: struct {
	lo, hi: uintptr,
}

// One reload object's disposable resources: its code/data block plus any debugger
// registration made for it. Freed together at generation retirement.
Lp_Obj_Res :: struct {
	block:    rawptr,        // the code/data block
	mapped:   bool,          // true: NtUnmapViewOfSection; false: VirtualFree
	ldr:      ^Lp_Ldr_Entry, // spliced PEB entry to remove (nil if none)
	sym_base: u64,           // SymUnloadModule64 base (0 if not loaded)
	img_path: string,        // emitted lp_%p.dll to delete ("" if none)
	pdb_path: string,        // emitted lp_%p.pdb to delete ("" if none)
}

// One applied reload's resources, retained until no thread is executing in its
// code so it can be freed safely.
Lp_Generation :: struct {
	serial: int,
	blocks: [dynamic]rawptr,     // plain VirtualAlloc blocks (near-arenas)
	objs:   [dynamic]Lp_Obj_Res, // object blocks + their debugger registration
	pdata:  [dynamic]win.PRUNTIME_FUNCTION,
	ranges: [dynamic]Lp_Range,
	owned:  [dynamic]uintptr,
	dbg_retired: bool,           // debugger visibility (PEB splice + DbgHelp) already dropped
}
@(private) _lp_generations: [dynamic]Lp_Generation
@(private) _lp_serial: int
@(private) _lp_owner: map[uintptr]int

// Returns the number of live reload generations still tracked (0 when livepatch is disabled).
live_generations :: proc() -> int {
	when !ODIN_LIVEPATCH { return 0 }
	return len(_lp_generations)
}

// Walks a suspended thread's call stack, reporting whether any frame lies in the given code ranges.
@(private)
lp_thread_touches :: proc(h: win.HANDLE, ranges: [dynamic]Lp_Range) -> bool {
	ctx: win.CONTEXT
	ctx.ContextFlags = win.CONTEXT_FULL
	if !win.GetThreadContext(h, &ctx) {
		return true
	}
	return lp_context_touches(ctx, ranges)
}

// Walks the call stack described by a captured context, reporting whether any
// frame lies in the given code ranges. Takes the context by value: unwinding
// mutates it.
@(private)
lp_context_touches :: proc(ctx_in: win.CONTEXT, ranges: [dynamic]Lp_Range) -> bool {
	ctx := ctx_in
	MAX_FRAMES :: 256
	for _ in 0 ..< MAX_FRAMES {
		pc := uintptr(ctx.Rip)
		if pc == 0 {
			return false
		}
		for r in ranges {
			if pc >= r.lo && pc < r.hi {
				return true
			}
		}
		image_base: win.DWORD64
		fe := win.RtlLookupFunctionEntry(win.DWORD64(pc), &image_base, nil)
		if fe == nil {
			sp := uintptr(ctx.Rsp)
			if sp == 0 {
				return true
			}
			ctx.Rip = win.DWORD64((^uintptr)(sp)^)
			ctx.Rsp = win.DWORD64(sp + 8)
		} else {
			handler_data: rawptr
			establisher:  win.DWORD64
			win.RtlVirtualUnwind(0, image_base, win.DWORD64(pc), fe, &ctx, &handler_data, &establisher, nil)
		}
	}
	return true
}

// Marks which past generations are unreferenced and untouched by any thread, so
// they can be freed. `handles` covers the suspended threads; the applying thread
// is not among them, so its own stack is captured here — a reload is very often
// driven from inside a livepatched procedure, and that frame's generation must
// not be freed out from under it.
@(private)
lp_scan_freeable :: proc(handles: [dynamic]win.HANDLE, freeable: []bool) {
	self: win.CONTEXT
	win.RtlCaptureContext(&self)
	for gen, i in _lp_generations {
		if i >= len(freeable) {
			break
		}
		referenced := false
		for e in gen.owned {
			if _lp_owner[e] == gen.serial {
				referenced = true
				break
			}
		}
		if referenced {
			continue
		}
		in_use := lp_context_touches(self, gen.ranges)
		for h in handles {
			if in_use {
				break
			}
			in_use = lp_thread_touches(h, gen.ranges)
		}
		freeable[i] = !in_use
	}
}

// Drops the debugger-visible presence of every generation this reload superseded —
// i.e. one whose every owned entry now maps to a newer serial in `_lp_owner` — without
// touching its memory. A superseded generation's body may still be executing (a thread
// parked in it, or the reload driven from inside it), so its block cannot be unmapped
// yet; but nothing new will ever call it again, so it must stop being advertised as a
// module. Left advertised, its stale `lp_%p.dll` keeps claiming the patched source
// lines: an attached debugger that discovers modules through the PEB loader list (e.g.
// RAD Debugger) accumulates one entry per reload and keeps a source breakpoint bound to
// the oldest, dead copy, so breakpoints stop hitting after the first patch. Unsplicing
// the PEB entry and unloading the in-process DbgHelp module here leaves the mapped code
// running for any in-flight thread while removing it from every module enumeration; the
// memory itself is reclaimed later by lp_free_marked once no thread is still inside it.
// Runs while other threads are suspended, so the loader-list edit is unobserved.
@(private)
lp_retire_superseded_debug :: proc() {
	for &gen in _lp_generations {
		if gen.dbg_retired {
			continue
		}
		superseded := true
		for e in gen.owned {
			if _lp_owner[e] == gen.serial {
				superseded = false
				break
			}
		}
		if !superseded {
			continue
		}
		// Under suspension do only the loader-list pointer edit (no lock, no allocation). The
		// heavy releases — SymUnloadModule64 (DbgHelp lock) and the node's heap free — are
		// deferred to lp_free_retired_debug, run after lp_resume: those locks may be held by a
		// suspended thread, so calling them here would deadlock (H2). r.ldr/r.sym_base stay set
		// so that post-resume pass can find and release them.
		for &r in gen.objs {
			if r.ldr != nil {
				lp_peb_unlink(r.ldr)
			}
		}
		gen.dbg_retired = true
	}
}

// Releases the debugger resources of every already-retired generation: the in-process
// DbgHelp module (SymUnloadModule64) and the PEB entry's heap memory (lp_peb_free). Both take
// locks a suspended thread might hold, so this runs AFTER lp_resume — the PEB entries were
// already unlinked (pointer writes) under suspension by lp_retire_superseded_debug. Idempotent
// across reloads: once released, r.sym_base/r.ldr are nil and the generation is skipped.
@(private)
lp_free_retired_debug :: proc() {
	for &gen in _lp_generations {
		if !gen.dbg_retired {
			continue
		}
		for &r in gen.objs {
			if r.sym_base != 0 {
				SymUnloadModule64(win.GetCurrentProcess(), win.DWORD64(r.sym_base))
				r.sym_base = 0
			}
			if r.ldr != nil {
				lp_peb_free(r.ldr)
				r.ldr = nil
			}
		}
	}
}

// Frees the generations flagged freeable, releasing their memory and unwind tables.
@(private)
lp_free_marked :: proc(freeable: []bool) {
	if len(_lp_generations) == 0 {
		return
	}
	kept := make([dynamic]Lp_Generation, 0, len(_lp_generations), runtime.heap_allocator())
	freed := 0
	for gen, i in _lp_generations {
		if i < len(freeable) && freeable[i] {
			for p in gen.pdata {
				win.RtlDeleteFunctionTable(p)
			}
			for r in gen.objs {
				// Debug resources (PEB entry + in-process DbgHelp module) were already
				// released by lp_free_retired_debug when this generation was retired — a
				// freeable generation is always an already-retired one — so here we only
				// reclaim the block and delete its on-disk files.
				if r.mapped {
					lp_section_unmap(r.block)
				} else {
					win.VirtualFree(r.block, 0, win.MEM_RELEASE)
				}
				if r.img_path != "" { os.remove(r.img_path); delete(r.img_path, runtime.heap_allocator()) }
				if r.pdb_path != "" { os.remove(r.pdb_path); delete(r.pdb_path, runtime.heap_allocator()) }
			}
			for b in gen.blocks {
				win.VirtualFree(b, 0, win.MEM_RELEASE)
			}
			delete(gen.blocks)
			delete(gen.objs)
			delete(gen.pdata)
			delete(gen.ranges)
			delete(gen.owned)
			freed += 1
		} else {
			append(&kept, gen)
		}
	}
	delete(_lp_generations)
	_lp_generations = kept
	if freed > 0 {
		fmt.printfln("[livepatch] freed %d stale reload generation(s); %d still in use", freed, len(kept))
	}
}

// Suspends every thread except the caller's, returning their handles.
//
// Enumeration and suspension use SEPARATE handles on purpose. NtGetNextThread advances its
// cursor only through a handle it opened with the requested access, so asking for
// suspend/context rights there makes it FAIL on the first thread that denies them and end the
// walk early — silently leaving every later thread running during the patch (H3). Instead we
// enumerate with only THREAD_QUERY_LIMITED_INFORMATION (broadly grantable, so the cursor never
// stalls) and open a distinct suspendable handle by thread id. A thread that still cannot be
// opened/suspended is counted and reported, never silently dropped.
@(private)
lp_suspend_other_threads :: proc() -> [dynamic]win.HANDLE {
	handles := make([dynamic]win.HANDLE, context.temp_allocator)
	me_tid := win.GetCurrentThreadId()
	proc_h := win.GetCurrentProcess()
	ENUM_ACCESS :: win.ACCESS_MASK(win.THREAD_QUERY_LIMITED_INFORMATION)
	OPEN_ACCESS :: win.DWORD(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_SET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION)

	missed := 0
	cursor: win.HANDLE = nil
	for {
		next: win.HANDLE
		st := NtGetNextThread(proc_h, cursor, ENUM_ACCESS, 0, 0, &next)
		if cursor != nil {
			win.CloseHandle(cursor) // the enumeration handle is only a cursor; never stored
		}
		if st != 0 { // STATUS_SUCCESS == 0; NO_MORE_ENTRIES (or any error) ends iteration
			break
		}
		cursor = next
		tid := GetThreadId(next)
		if tid == 0 || tid == me_tid {
			continue
		}
		// Open a distinct handle with the rights the patch actually needs (suspend + get/set
		// context, used later by lp_ip_conflicts / lp_scan_freeable). Re-opening by id has a
		// vanishing window where the id could be recycled, but a wrong-thread suspend is still
		// resumed, so the worst case is a needless extra suspend, never a missed real thread.
		th := win.OpenThread(OPEN_ACCESS, win.FALSE, tid)
		if th == nil {
			missed += 1
			continue
		}
		if win.SuspendThread(th) != ~win.DWORD(0) {
			append(&handles, th)
		} else {
			missed += 1
			win.CloseHandle(th)
		}
	}
	if missed > 0 {
		// Loud, not fatal: this is essentially unreachable for a process's own threads, but if
		// it happens the un-suspended threads are NOT IP-checked, so patching a procedure one of
		// them is executing could run a half-written redirect. Surfaced rather than hidden.
		fmt.eprintfln("[livepatch] WARNING: %d thread(s) could not be suspended and run during the patch; a call into a patched entry at that instant is unsafe", missed)
	}
	return handles
}

// Resumes and closes the previously suspended thread handles.
@(private)
lp_resume :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
}

// Reports whether any suspended thread's instruction pointer sits in a region about to be patched.
@(private)
lp_ip_conflicts :: proc(handles: [dynamic]win.HANDLE, regions: []Lp_Range) -> bool {
	for h in handles {
		ctx: win.CONTEXT
		ctx.ContextFlags = win.CONTEXT_CONTROL
		if !win.GetThreadContext(h, &ctx) {
			continue
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
