#+build windows
package livepatch

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"

foreign import lp_ntdll "system:ntdll.lib"
foreign import lp_kernel32 "system:kernel32.lib"
@(default_calling_convention="system")
foreign lp_ntdll {
	// Enumerates the process's threads one at a time (no toolhelp snapshot needed).
	NtGetNextThread :: proc(ProcessHandle, ThreadHandle: win.HANDLE, DesiredAccess: win.ACCESS_MASK, HandleAttributes, Flags: win.ULONG, NewThreadHandle: ^win.HANDLE) -> win.NTSTATUS ---
}
@(default_calling_convention="system")
foreign lp_kernel32 {
	// Returns a thread handle's thread id (used to skip our own thread).
	GetThreadId :: proc(Thread: win.HANDLE) -> win.DWORD ---
}

// A half-open address range [lo, hi).
Lp_Range :: struct {
	lo, hi: uintptr,
}

// One applied reload's resources, retained until no thread is executing in its
// code so it can be freed safely.
Lp_Generation :: struct {
	serial: int,
	blocks: [dynamic]rawptr,
	pdata:  [dynamic]win.PRUNTIME_FUNCTION,
	ranges: [dynamic]Lp_Range,
	owned:  [dynamic]uintptr,
}
@(private) _lp_generations: [dynamic]Lp_Generation
@(private) _lp_serial: int
@(private) _lp_owner: map[uintptr]int

// Returns the number of live reload generations still tracked (0 when livepatch is disabled).
live_generations :: proc() -> int {
	when !ODIN_LIVEPATCH { return 0 }
	return len(_lp_generations)
}

@(private)
// Walks a suspended thread's call stack, reporting whether any frame lies in the given code ranges.
lp_thread_touches :: proc(h: win.HANDLE, ranges: [dynamic]Lp_Range) -> bool {
	ctx: win.CONTEXT
	ctx.ContextFlags = win.CONTEXT_FULL
	if !win.GetThreadContext(h, &ctx) {
		return true
	}
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

@(private)
// Marks which past generations are unreferenced and untouched by any thread, so they can be freed.
lp_scan_freeable :: proc(handles: [dynamic]win.HANDLE, freeable: []bool) {
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
		in_use := false
		for h in handles {
			if lp_thread_touches(h, gen.ranges) {
				in_use = true
				break
			}
		}
		freeable[i] = !in_use
	}
}

@(private)
// Frees the generations flagged freeable, releasing their memory and unwind tables.
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
			for b in gen.blocks {
				win.VirtualFree(b, 0, win.MEM_RELEASE)
			}
			delete(gen.blocks)
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

@(private)
// Suspends every thread except the caller's, returning their handles.
lp_suspend_other_threads :: proc() -> [dynamic]win.HANDLE {
	handles := make([dynamic]win.HANDLE, context.temp_allocator)
	me_tid := win.GetCurrentThreadId()
	proc_h := win.GetCurrentProcess()
	// QUERY_LIMITED_INFORMATION is needed so GetThreadId works to skip our own thread.
	ACCESS :: win.ACCESS_MASK(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_SET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION)

	// NtGetNextThread reads `cursor` only to locate the next thread; it never closes it. So a
	// handle stays valid as the cursor for exactly one more call, after which we close it unless
	// we kept it (suspended, to be resumed later). nil cursor starts the enumeration.
	cursor: win.HANDLE = nil
	cursor_keep := false
	for {
		next: win.HANDLE
		st := NtGetNextThread(proc_h, cursor, ACCESS, 0, 0, &next)
		if cursor != nil && !cursor_keep {
			win.CloseHandle(cursor)
		}
		if st != 0 { // STATUS_SUCCESS == 0; NO_MORE_ENTRIES (or any error) ends iteration
			break
		}
		keep := false
		if tid := GetThreadId(next); tid != 0 && tid != me_tid {
			if win.SuspendThread(next) != ~win.DWORD(0) {
				append(&handles, next)
				keep = true
			}
		}
		cursor = next
		cursor_keep = keep
	}
	return handles
}

@(private)
// Resumes and closes the previously suspended thread handles.
lp_resume :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
}

@(private)
// Reports whether any suspended thread's instruction pointer sits in a region about to be patched.
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
