# Hot reload — status & TODO

Live++-style in-process hot reload for the Odin compiler. Windows / x64.
Status as of this branch. See `README.md` for how to run it and how it works.

## Done

- [x] **`@(hot_reload)` procedure attribute** — marks a procedure replaceable:
      emits `noinline` + `"patchable-function"="prologue-short-redirect"` and forces
      `@(export)` (stable, unmangled symbol name).
      - `src/checker.hpp` (AttributeContext), `src/checker.cpp` (proc_decl_attribute),
        `src/entity.cpp` (Entity.Procedure.is_hot_reload), `src/check_decl.cpp`,
        `src/llvm_backend_proc.cpp`.
- [x] **`-hot-reload` build flag** — forces single module; reserves the arenas + emits the
      per-thread-local accessors; **requires `-debug`** (the loader resolves running symbols
      from the exe's PDB) and auto-adds `/OPT:NOREF,NOICF`.
      - `src/main.cpp` (BuildFlag_HotReload + the -debug check), `src/build_settings.cpp` (bool hot_reload).
- [x] **PDB-based symbol resolution** (replaced the baked `runtime.hot_reload_symbol_table`).
      The loader resolves the running exe's procedure/global addresses from the exe's PDB
      instead of a compiler-baked table, so no symbols are rooted and DCE stays enabled.
      See Tier 3 "Drop the baked table" below for the full description.
      - `core/sys/hot_reload/hot_reload.odin` (`hr_dbghelp_ensure` enumerates, `hr_resolve_pdb`),
        `core/sys/windows/dbghelp.odin` (`SymEnumSymbolsW`),
        `src/llvm_backend.cpp` (`lb_hot_reload_emit_support`).
- [x] **`FlushInstructionCache` binding** — `core/sys/windows/kernel32.odin`.
- [x] **COFF object loader / relocator / patcher** — `core/sys/hot_reload/hot_reload.odin`:
      parse COFF, map the object in one block **within ±2 GB of the exe**, apply
      `AMD64_REL32`/`REL32_1..5`/`ADDR64` relocations with the resolver policy
      (in-table & not hot → exe addr; hot → object copy; object-local → loaded copy;
      undefined external → running process via `GetProcAddress` / `_tls_index` / `__imp_`
      cell, through a trampoline if beyond REL32 range), overwrite each running
      procedure's prologue with a 14-byte `FF 25` absolute jump.
- [x] **Global state preserved across reload** — validated by the demo (`hits` keeps
      counting through a reload).
- [x] **New globals across a reload.** The compiler reserves a zero-init arena
      (`__odin_hot_reload_global_arena`) in the exe and, driven by a build-to-build
      manifest (`-hot-reload-manifest`, `-hot-reload-arena-size`), redirects
      *new* globals (ones absent from the exe) into it at stable byte offsets, so
      their state persists across every reload. Base build records original
      globals + their canonical `type_hash`; a reload build assigns/reuses arena
      offsets for new globals and **errors** if an existing global's type/layout
      changed or the arena is exhausted. Compiler: `src/llvm_backend.cpp`
      (`lb_hot_reload_arena`, `HotReloadManifest`, global-emission fork),
      `src/main.cpp`, `src/build_settings.cpp`, `base/runtime/core.odin`
      (`Hot_Reload_Symbol` gained `kind` + `type_hash`).
- [x] **Compile-time constant initializers for new globals.** A new global with a
      constant initializer (scalars, arrays, structs, strings) starts at its
      declared value instead of zero. The compiler emits the constant as a blob +
      an object-local descriptor table `__odin_hot_reload_new_global_inits`
      (`{arena_offset, flag_offset, size, blob}` per entry) and reserves a 1-byte
      once-only guard in the arena (offset recorded in the manifest). The loader
      copies each blob into the arena iff its flag byte is 0, then sets it — so the
      init runs exactly once and never clobbers accumulated state on later reloads.
      Arena is 16-byte aligned. Runtime (non-constant) initializers and new
      `@(init)` still error.
- [x] **New procedures across a reload.** A new proc called from hot code links as
      an object-local symbol and is reachable from patched and other new code.
- [x] **Loader promoted to `core:sys/hot_reload`** with `apply(obj_path)` that
      auto-discovers the `@(hot_reload)` procedures from the baked table (no more
      copy-pasting a loader into your project).
- [x] Demo + scripted repro — `game.odin`, `demo.ps1` (adds a new global + proc,
      drives two reloads to show the new global persisting).

## TODO

### Tier 1 — architectural (the real gaps to Live++)

- [ ] ~~**Incremental compilation.** Recompile only changed procedures/modules instead
      of the whole program to one object each reload. Needs compiler work to emit and
      reuse per-procedure or per-module objects (object emission is in
      `src/llvm_backend.cpp` ~`lb_llvm_object_generation`, currently temp-and-delete).~~ 
			-- needs major work on the compiler that is not yet supported 
- [x] **Thread-safe / atomic patching.** Patching is now safe while other threads run the
      hot procedures, via two composed layers (Windows/x64). Verified by an automated
      stress test: `examples/hot_reload/mt_test` spawns worker threads that hammer the hot
      proc while the main thread reloads 200× — the process survives, workers keep running,
      and the patch takes effect (`run_mt_test.ps1`, exit 0 = PASS).
  - [x] **Stop-the-world + IP check.** The loader enumerates every other thread
        (`CreateToolhelp32Snapshot`), suspends them, and checks each suspended thread's
        `RIP` (`GetThreadContext`, `CONTEXT_CONTROL`) against the bytes it is about to
        overwrite. If a thread is parked in a prologue, it resumes all and retries rather
        than corrupting it; after the batch it flushes and resumes. No IP relocation is
        needed — in-flight calls in the old body finish on old code (it stays mapped) and
        only new calls take the jump. Loader: `hr_suspend_others`/`hr_resume`/
        `hr_ip_conflicts` in `core/sys/hot_reload/hot_reload.odin`; APIs in
        `core/sys/windows` (added the native x64 `CONTEXT_*` flag constants).
  - [x] **Atomic short-jump publish.** Each `@(hot_reload)` proc gets a 16-byte NOP pad
        immediately before its entry via the compiler-emitted LLVM
        `patchable-function-prefix` (`src/llvm_backend_proc.cpp`) — linker-independent, so
        it works with lld-link/link.exe/radlink alike (an earlier `/FUNCTIONPADMIN`
        attempt was silently ignored by lld). The loader writes the full 14-byte absolute
        jump into that pad (nobody executes it) and then flips the 2-byte entry to a short
        jump into the pad with ONE aligned atomic 16-bit store — a torn-free publish; if no
        pad is present it falls back to the 14-byte overwrite (still safe under the stop-the-
        world). Loader: `hr_patch_atomic`/`hr_patch_overwrite`/`hr_write_abs_jump`.
- [x] **Unwind info for new code.** The loader now fixes up `IMAGE_REL_AMD64_ADDR32NB`
      relocations in `.pdata`/`.xdata` (RVAs relative to the loaded block) and registers
      the loaded `.pdata` with `RtlAddFunctionTable(pdata, count, block)`, so the OS
      unwinder can find unwind info for RIPs in hot code. Loader:
      `core/sys/hot_reload/hot_reload.odin` (ADDR32NB case in the relocation switch +
      the `.pdata` registration loop after `FlushInstructionCache`); binding:
      `core/sys/windows` (`RUNTIME_FUNCTION`, `RtlAddFunctionTable`,
      `RtlDeleteFunctionTable`).
      - **Odin has no language exceptions — this is about stack *unwinding*, not
        try/catch.** Windows x64 stack walking is table-driven (no frame-pointer chain),
        so `.pdata`/`.xdata` is what a `panic`/`assert` backtrace, the runtime's
        hardware-fault handler (a segfault/div0 in a hot proc raises SEH even without
        `try`), a debugger's Call Stack window, and `RtlCaptureStackBackTrace` all rely
        on. Before the fix, a stack walk crossing a hot frame recovered a wrong return
        address and corrupted; normal call/return was always fine. After it, backtraces
        and crash traces through hot code are correct.
      - **Does NOT enable source-level debugging of hot code.** `RtlAddFunctionTable`
        carries only unwind data, no symbols. The object is mapped as anonymous
        `VirtualAlloc` memory with no registered module/PDB, so a debugger cannot bind a
        source-line breakpoint inside a hot procedure and won't show it in the source
        view — hot frames appear in the (now-correct) call stack as raw addresses. Real
        break-and-step in hot code would need a different loader (a `LoadLibrary`'d DLL
        that fires a module-load event + PDB, or DbgHelp `SymLoadModuleEx` over the
        mapped range). Out of scope here.
      - **Limitation:** the ADDR32NB fixup assumes every target is in-block (always true
        for unwind data). An ADDR32NB to an out-of-block symbol (e.g. a language-EH
        personality routine in the exe) would wrap to a bogus RVA; Odin's unwind info
        carries no such handler, so this does not arise today.
- [ ] **Source-level debugging of hot code (symbols + PDB).** Follow-on to the unwind
      item: stack *unwinding* through hot code now works, but a debugger still can't set
      a source-line breakpoint in a hot procedure or show it in the source view, because
      the object is mapped as anonymous `VirtualAlloc` memory with no registered
      module/PDB — hot frames appear in the (now-correct) call stack as raw addresses.
      Live++ gets this precisely because it works with linked images + PDBs, not raw
      obj blobs. Two candidate approaches:
  - [ ] **DbgHelp virtual module.** Emit a PDB for the reload object (`odin build -debug`
        already produces debug info; needs it written for the `.obj`/its symbols) and, at
        load time, register the mapped range with the debugger via DbgHelp
        `SymLoadModuleEx` over the block + a synthesized module, mapping the PDB's
        RVA-based line/symbol info onto the block base. Lightest touch; works with
        WinDbg-family tools, less reliably with the VS debugger.
  - [ ] **Load as a real DLL instead of a raw obj.** `LoadLibrary` a linked hot DLL so the
        OS fires a module-load debug event and the debugger auto-loads its PDB — full
        source-level break/step in VS and WinDbg. But a DLL gets its own copy of globals
        and cannot relocate new code against the exe's existing globals/procs, which is
        the whole reason this loader mmaps a raw obj (see the top-of-file rationale).
        Would need the arena/symbol-table machinery extended to bridge a DLL back to the
        exe's state — a large change, arguably a different architecture.
  - Either way, needs the compiler to emit usable debug info for the reload object and a
    scheme to associate the PDB's image-base-relative addresses with the runtime block
    base (same "block is the image base" trick the unwind registration uses).
- [x] **New calls into an already-linked package/foreign library.** Reloaded code may now
      call a foreign-library procedure (e.g. a `vendor:raylib` proc) that the base source
      had **not** referenced before, as long as its library is already linked into the exe
      and its code is present in the running image. Previously such a call resolved to
      nothing and aborted the reload (`unresolved symbol in executable code`), because
      foreign symbols are excluded from the baked table and a static-lib function is not
      exported. Fix: the loader gained a **PDB-backed resolver** — a final fallback in
      `hr_resolve_external` that looks the symbol up in the running exe's PDB via DbgHelp
      `SymFromNameW` (`core/sys/hot_reload/hot_reload.odin` `hr_resolve_pdb` +
      `hr_dbghelp_ensure`; new `SymFromNameW` binding in `core/sys/windows/dbghelp.odin`).
      This finds the address of an in-image, non-exported symbol; the existing
      REL32/trampoline/`__imp_` machinery then applies. No compiler change.
      - **Requirements:** the base exe must be built with `-debug` (a PDB next to it), and
        with **`/OPT:NOREF,NOICF`** so the linker keeps functions that live in a linked
        object member but the base source never referenced (prebuilt libs like `raylib.lib`
        use function-level COMDATs, which `/OPT:REF` would otherwise strip). To reach a
        function whose object member the base never pulls at all, additionally link the
        archive whole (`/WHOLEARCHIVE:<lib>`).
      - **Verified:** `examples/hot_reload/demo_raylib.ps1` — base references
        `rl.SetRandomSeed`; a reload adds `rl.GetRandomValue(1, 100)` (never referenced by
        the base) and it resolves + runs from hot code.
- [ ] **Still TODO (a genuinely NEW, not-yet-linked package):** adding an import whose
        library is absent from the base exe. A **dynamic** lib needs `LoadLibrary`
        auto-discovery (compiler bakes the referenced foreign-lib paths into the reload
        object; loader loads the DLL + extends the export search). A **static** lib needs a
        load-time `.lib` archive linker (map + relocate the needed archive members like the
        reload object — essentially link-at-load). A function whose member was never pulled
        into the base build is likewise absent. Removing a package is already free (nothing
        references its symbols). The loader now prints a clear per-symbol hint for these.
- [x] **handle `@(rodata)`, `#load`, `#load_directory`, `#hash`, `#load_hash`.** Immutable embedded data — `@(rodata)` globals and
      globals whose initializer is directly `#load(...)` — is now re-provided fresh on every
      reload instead of preserved as stale state. Both may be *added* or *edited* across a reload
      (including a `#load` file whose size changes). Design ("handle it like other globals; repoint
      old → new"): the compiler keeps such a global a normal (never arena-backed) global and lists
      its `{link name, size}` in a self-contained `__odin_hot_reload_refresh_syms` table; the loader
      **overwrites the exe's canonical copy** with the reload object's fresh copy under the same
      stop-the-world as proc patching. For a slice/string/`#load` global that copy is the 16-byte
      header, so the exe header comes to point at the object's fresh blob (a size change is free);
      a value-type `@(rodata)` is overwritten in place. Because the exe's one copy is updated, **all
      code sees the new data** — no dependence on the referencing procedure being re-patched, so a
      pure data-only reload (no code change) works. A **new** `@(rodata)`/`#load` global is emitted
      object-local (not routed into the persist-arena) and resolves fresh each reload. Read-only
      protection is preserved: after relocations the loader tightens the mapped block from RWX to
      per-section W^X, so a stray write through refreshed data faults as in a normal build.
      Compiler: `src/llvm_backend.cpp` (`lb_is_hot_reload_refresh_global` /
      `lb_is_load_directive_expr`, the fork exemption, the `__odin_hot_reload_refresh_syms` table),
      `src/llvm_backend_stmt.cpp` (same for local `@(static)`), `src/llvm_backend.hpp`
      (`lbHotReloadRefreshSym`). Loader: `core/sys/hot_reload/hot_reload.odin` (refresh-target
      resolution, the repoint pass under suspension, the W^X tightening pass). `#load_directory` is
      also handled: it yields a runtime *value*, so a package-scope `x := #load_directory(...)` global
      would normally be built by the startup runtime (static storage left zero, unusable by the
      repoint); under `-hot-reload` the compiler instead bakes its constant `[]Load_Directory_File`
      slice as the global's initializer (`lb_const_load_directory_slice`), so the exe's 16-byte slice
      header is repointed at the reload object's fresh backing data exactly like `#load` (file-scope
      globals only; a local `@(static) := #load_directory(...)` is not baked and stays preserved).
      `#hash` (hash of a string literal) and `#load_hash` (hash of a file's contents) are covered
      too: both return a compile-time constant integer, so the documented `H :: #hash(...)` /
      `H :: #load_hash(...)` *constant* form is inlined as an immediate and refreshes automatically
      when its input changes (the referencing proc's content hash changes → it is repatched — no
      special handling); the rarer mutable-global form `x := #hash(...)` / `x := #load_hash(...)` is
      added to the refresh set and overwritten in place like any scalar `@(rodata)`.
      Verified end-to-end by `examples/hot_reload/rodata_test` (`run_rodata_test.ps1`, exit 0 = PASS):
      a data-only reload changes a `@(rodata)` value, a size-changed `#load` asset, a
      `#load_directory` file, a `#hash` string literal, and the `#load_hash` file, and all five are
      observed, while an ordinary mutable global keeps its runtime value.

### Tier 2 — correctness / capability

- [x] **General external-symbol resolution.** Undefined externals the reload object
      references but that are absent from the baked table — C-runtime helpers the backend
      synthesises (`memcpy`/`memset`/`memmove`/`memcmp`), `_tls_index`, and Windows-API
      imports — now resolve against the running process: `GetProcAddress` over the loaded
      modules (exe, ntdll, ucrtbase, kernel32) for exported symbols, an in-image reference
      by link name for the non-exported `_tls_index`, and synthesised pointer cells for
      `__imp_*` references. Targets beyond signed-32-bit REL32 range are reached through a
      near-block absolute-jump trampoline. Loader: `core/sys/hot_reload/hot_reload.odin`
      (`hr_resolve`, `hr_resolve_exported`, `hr_imp_cell`, `hr_trampoline_for`, `Near_Arena`).
      This is what unblocked calling `fmt`/stdlib from hot code without crashing.
- [x] **Import (`__imp_*`) resolution.** Done (see above) — an `__imp_X` reference gets a
      synthesised cell holding X's resolved address, so hot code can reach foreign / Win32
      functions and `_tls_index` through the IAT indirection.
- [ ] **More relocation kinds.** `ADDR32NB` (unwind `.pdata`/`.xdata`) and `SECREL`
      (thread-locals) are now handled; `ADDR32` and `SECTION` (debug) are still counted as
      *unsupported* and skipped. An
      *unresolved* relocation inside a hot procedure's `.text` is now a **hard error** (named,
      reload aborts) rather than a silent skip; unsupported *types* in `.text` are still only
      noted.
- [x] **New symbols across a reload.** Adding new globals (incl. compile-time
      constant initializers) and new procedures is done (see above). **Still TODO:**
      *runtime* (non-constant) initializers and new `@(init)` for freshly introduced
      globals — currently rejected at build time. Needs compiler work to isolate +
      invoke per-symbol init code at reload time.
- [ ] **New host-callable entry points.** A brand-new procedure is reachable only
      through the patched call graph; the frozen host cannot gain a new direct call
      site (would need a `resolve(name)`-style dispatch the host consults).
- [ ] **Hot-procedure signature/ABI guard.** Existing *globals* are protected against a
      type/layout change (rejected at build time via `type_hash`), but a `@(hot_reload)`
      *procedure* has no equivalent check: change its parameter/return types and the frozen
      host's call sites still marshal the OLD ABI into the patched-in new body → silent
      stack/register corruption. Fix: record each hot proc's canonical signature hash in the
      manifest and reject a reload that changes it. (Adversarial-review finding F8.)
- [x] **Variadic / `any` / reflection from hot code.** Both the crash (unresolved
      `memcpy`/`_tls_index`/`__imp_*`, fixed by the resolver above) and the wrong-output
      for composite/user types are fixed. `fmt.printf("%v", some_struct)`, `typeid_of(T)`,
      and `type_info_of` now print correctly from hot code (the demo's patched `update`
      prints `State{counter = .., step = .., mirror = ..}` and `typeid = State`). Two
      `-hot-reload`-gated compiler changes make it work: (1) `src/checker.cpp`
      (`generate_minimum_dependency_set`) emits type_info for **every** program type — not
      just the RTTI subset this build happens to use — so the exe's `type_table` is
      complete; (2) `src/llvm_backend_type.cpp` (`lb_type_info`) resolves compile-time
      `type_info_of`/enum reflection through the runtime `__type_info_of(typeid)` hash
      lookup instead of a build-local index, so it lands on the exe's `Type_Info` and
      matches `any` values (typeid is already the build-stable canonical hash from
      `lb_typeid`). **Limitation:** a brand-new type introduced *only* by a hot edit is
      absent from the exe's frozen `type_table` and won't reflect correctly.
- [x] **Function-local statics.** Local `@(static)` variables are now preserved the
      same way file-scope globals are: an *original* static (present in the exe)
      resolves to the exe's copy across a reload, and a *new* static introduced by a
      reload is placed in the persistent arena (const initializer applied once). This
      needed a build-stable symbol name — the old mangling used the entity id (a
      global atomic assigned during multithreaded checking, so unstable across builds);
      it is now `<proc>$static$<var>[$<occ>]`, derived purely from source, under
      `-hot-reload`. Statics are recorded in the manifest (`orig`/`new`), published in
      `runtime.hot_reload_symbol_table`, and the manifest write + new-global init table
      were moved to after procedure generation so local statics are included.
      `any`-typed *new* statics and *new* statics needing a runtime initializer
      are rejected at build time (only constant/zero-init new statics are supported,
      matching new file-scope globals).
- [x] **Thread-local variables from hot code.** Reads/writes of a *pre-existing*
      `@(thread_local)` variable (file-scope global or function-local `@(static)`) from
      reloaded code now resolve to the running threads' real TLS slots. Windows x64 TLS
      access uses an `IMAGE_REL_AMD64_SECREL` per-variable offset that the loader used to
      skip, leaving the reload object's own `.tls$` offset (which differs from the exe's
      frozen `[CRT template][Odin vars]` layout) — so a thread-local silently read the
      wrong slot. Fix: the compiler emits a per-variable accessor thunk
      (`__odin_hrtls_<i>() -> rawptr { return &var }`, whose body lowers to the exe's TLS
      sequence) and a `HOT_RELOAD_KIND_TLS` symbol-table entry; the loader reads the
      current thread's TLS block base (`gs:[0x58]` indexed by the exe's `_tls_index`),
      calls each accessor to learn the variable's exe-block offset, and rewrites every
      `SECREL` site to that offset (+ any per-site addend). Verified: a hot proc reading
      `@(thread_local) tls_v` continues `2 → 12 → 22` across reloads (was `10 → 20`), and
      `fmt`/temp-allocator TLS from hot code resolves correctly.
- [x] **New thread-locals across a reload.** A `@(thread_local)` variable introduced
      only by a reload (file-scope or function-local `@(static)`) now works. The exe
      reserves a per-thread **TLS arena** (`__odin_hot_reload_tls_arena: [N]u8`,
      `-hot-reload-tls-arena-size`, default 4 KiB) so every thread — existing and
      future — has spare TLS; a new thread-local is placed at a manifest-pinned offset
      inside it, emitted as a GEP into the arena's thread_local symbol, so its access
      compiles to `SECREL(arena)+offset` and resolves through the arena's existing
      accessor (no loader change). Verified: two new thread-locals introduced by a
      reload accumulate and persist across further reloads, and are genuinely
      per-thread — a worker thread spawned *after* the reload sees its own independent
      zeroed copy. **No initializer support is needed:** Odin forbids initializers on
      any thread-local declaration (`src/checker.cpp`, "A thread local variable
      declaration cannot have initialization values"), so new thread-locals are always
      zero-init and the per-thread arena is already zeroed. Exhausting the arena is a
      clear build error naming `-hot-reload-tls-arena-size`.
- [ ] **hot reload hooks** — After a hot reload the structure of objecst can be different.
			Add hooks so the application can handle changes to the layout of structs. Odins 
			reflection system is used for serialization and deserialization. Because the memory
			of where objects live is not visible to the hot reload function the user has to manually
			implement each remapping and handle the allocations and deallocations for that.
			A previous plan ´struct_changes.md´can be used as a starting of point. Live++ also 
			provides hooks so an application can patch its internal data to the new layout.

### Tier 3 — robustness / lifecycle
- [x] **Drop the baked table / binary bloat** — the exe no longer bakes
      `runtime.hot_reload_symbol_table` (which took the address of every proc/global and so
      disabled dead-code elimination and grew the binary). The loader now resolves every
      running-exe address from the exe's **PDB**: it enumerates the exe module's symbols once
      via DbgHelp `SymEnumSymbolsW` into a name→address map (exact-match, because
      `SymFromNameW` mis-parses Odin's `[file.odin]` link names as wildcard classes), and
      recovers the `@(hot_reload)` set **structurally** from the 16-byte patchable-function
      prefix (no table, no metadata section). LLVM-level DCE is re-enabled. `-hot-reload` now
      **requires `-debug`** (a PDB must sit next to the exe; enforced in `src/main.cpp`).
      Compiler keeps only the arena + per-thread-local accessors alive via `llvm.used` +
      external linkage; a global's debug name is set to its link name under `-hot-reload` so
      the PDB carries a resolvable name (functions already do). Files: `base/runtime/core.odin`
      (types + slice removed), `src/llvm_backend.cpp` (`lb_hot_reload_emit_support` replaces
      `lb_generate_hot_reload_symbol_table`; global debug-name change), `src/main.cpp`,
      `core/sys/windows/dbghelp.odin` (`SymEnumSymbolsW` binding), `core/sys/hot_reload/hot_reload.odin`
      (`hr_dbghelp_ensure` enumerates; `hr_resolve_pdb` is now a map lookup; `hr_is_hot_entry`;
      `hr_tls_offset`).
      - **Manifest:** still needed — it persists the arena OFFSETS a reload build assigns to
        new globals/statics/thread-locals so they stay stable across successive reloads; those
        offsets are chosen by reload builds and are not derivable from the base exe's PDB.
- [x] **`/OPT:NOREF,NOICF` when hot reloading** — `/OPT:NOICF` stops the linker folding
      identical procedures (would break per-procedure patching); `/OPT:NOREF` keeps functions
      the base source never referenced — chiefly members of already-linked static libraries
      (e.g. `vendor:raylib`) — in the image so a reload can call them and the loader can resolve
      them via the PDB. Both are now set **automatically** under `-hot-reload` (`src/linker.cpp`,
      via the `opt_ref` token so it wins over the linker templates' hardcoded `/opt:ref`), so the
      raylib whole-lib scenario works without manual `-extra-linker-flags`. (LLVM-level DCE of
      Odin procs/globals still applies; `/OPT:NOREF` only keeps linker-visible library members.
      `/WHOLEARCHIVE:<lib>` is still needed to pull a member the base never touched at all.)
- [x] **No `@(hot_reload)` attribute (tagless, Live++-style)** — the user no longer tags
      procedures. Under `-hot-reload` EVERY eligible procedure is made hot-patchable
      automatically (`lb_proc_is_hot_reloadable` in `src/llvm_backend_proc.cpp` gates the
      `noinline` + patchable-prologue emission; eligible = has a body, not foreign, not the
      entry point, not force-inlined, normal prologue, and not `@(no_hot_reload)`). The
      `@(hot_reload)` attribute is REMOVED; `@(no_hot_reload)` opts a specific proc out (keeps
      it inlinable/optimized and unpatched). No forced `@(export)` — the PDB resolves mangled
      link names. **Change detection** keeps this cheap and safe: the compiler emits a
      `{u64 name_hash, u64 content_hash}` table `__odin_hot_reload_func_hashes` (no addresses,
      DCE stays on) via `lb_hot_reload_emit_func_hashes`, where `content_hash` is a debug- and
      build-normalized hash of the procedure's LLVM IR (strips `!`/`#` metadata & attr-group
      numbers, trims trailing commas so -debug/-o:none matches non-debug, and canonicalizes
      the build-specific `$<module>$<hex>` tail of constant-global names). The loader
      (`core/sys/hot_reload/hot_reload.odin`) seeds a live `name_hash→content_hash` map from
      the exe's table and, each reload, patches ONLY procedures whose hash changed (unchanged
      procs — the whole runtime and the loader itself — are skipped, so there is no
      "patch the patcher" hazard and only edited procs relocate). `-hot-reload` now **implies
      `-debug`** (`src/main.cpp`), which also pins base and reload builds to the same
      optimization level (`-o:none`) so the hashes match. Verified: a one-proc edit patches
      exactly that proc; a no-op reload prints "no changed procedures"; `mt_test` still
      200/200. **Soundness note:** a change to a string literal's *content* at the same length
      is not detected (the content lives in a separate constant global, not in the referencing
      proc's IR); length changes and all code changes are detected.
- [ ] **Validate optimized builds** (`-o:speed`/`-o:size`) — cross-TU inlining and
      COMDAT folding can defeat patching; confirm `noinline` + single module hold up.
- [ ] **Free the previously mapped block** on the next reload (currently leaks one
      block per reload); optionally support unpatch / rewind.
- [ ] **Guard the 14-byte patch** — assert the procedure is ≥14 bytes to its next
      16-byte-aligned neighbor before overwriting (today relies on 16-byte alignment).
- [ ] **Build-identity / staleness check (safety net).** Nothing binds a reload object +
      manifest to the *running* exe. Rebuild the base exe (arena relaid) but reload a stale
      object, or `apply()` an object built for a different exe, and the loader resolves
      names, writes const-init blobs at now-wrong arena offsets, and patches — silent memory
      corruption, no diagnostic. Fix: bake a build-id (e.g. manifest-layout hash) into both
      the exe (a resolvable symbol) and the reload object; loader compares and refuses on
      mismatch. Live++ does this; highest-value missing safety net.
- [x] **Hardened PDB-resolver failure modes (from adversarial review).** (a) The loader now
      treats an empty/failed `SymEnumSymbolsW` (missing/public-only PDB) as a hard error
      instead of silently duplicating every global (`hr_dbghelp_ensure`). (b) TLS/register/
      frame/value symbols (whose `Address` is not a VA) are skipped during enumeration so
      they cannot poison the map (`hr_enum_cb`). (c) A reload aborts before writing any byte
      if *any* hot target fails to resolve (was: skip-and-partially-patch). (d) The
      stop-the-world IP-conflict region now covers the pad the atomic patcher writes
      (`[entry-PAD_LEN, entry+PATCH_LEN)`). (e) ADDR32NB refuses an out-of-block target
      rather than writing a wrapped RVA. (f) `-hot-reload` host is required to be an
      executable (the loader hardcodes the exe module). **Still open from the review:**
      first-seen-wins on duplicate enumerated names (no section/tag disambiguation); the
      hot-detection heuristic assumes the compiler's 16-byte prefix is literal `0x90` NOPs
      (a future LLVM multi-byte-NOP prefix would break detection — now at least it fails
      loudly via the empty-`hot_names` path, not silently). **Fixed since:** the loader's
      process-lifetime state (`_hr_syms`/`_hr_cur`/`hr_exe_types_cache` + their string keys) is
      pinned to `runtime.heap_allocator()` so it no longer aliases the first caller's allocator
      (F13); all per-call scratch runs on a private heap-backed `runtime.Arena` instead of the
      app's `context.temp_allocator`; and a `_hr_busy` atomic guard makes a concurrent/nested
      `apply()` fail loudly instead of corrupting shared state (F14).


### Tier 4 — workflow / reach

- [ ] **Built-in file watching + auto-rebuild** — watch sources, rebuild the object,
      and reload automatically (today: rebuild by hand, press `r`).
- [ ] **Self-contained reload** — have the running program drive the rebuild (invoke
      `odin` via `core:os/os2`) so no external terminal is needed.
- [ ] **Cross-platform** — ELF (Linux) and Mach-O (macOS) loaders; currently COFF/x64
      only. (No `.obj`/relocation parser for those formats exists in `core` yet.)
- [ ] **Multiple modules / DLL targets / multiple live processes.**
- [ ] **Tooling** — surface compile errors, hold on failed builds, logging, editor
      integration.

### Tier 5 — tests and evaluation

- [ ] **Setup test framework** — one framework for testing all hot reload features and
			edge cases. It has to be repeatable and verify each aspect of the hot reload.
- [ ] **thread_local** — all flavors of possible thread locals have to be tesed and
			verified that they work correctly over hot reloads

## Known limitations (current, by design of the PoC)

- Windows / x64 / COFF only.
- **`-hot-reload` implies `-debug`.** The loader resolves the running exe's symbols from its
  PDB, so a `.pdb` must sit next to the exe; `-hot-reload` now turns on `-debug` automatically
  (`src/main.cpp`). This also pins base and reload builds to the same optimization level
  (`-o:none`), which the change-detection content hashes rely on to match. The hot-patchable
  set is emitted for every eligible procedure and recovered structurally from the
  patchable-function prefix — see `hr_is_hot_entry`.
- Multithreaded-safe: a reload suspends the other threads, checks their instruction
  pointers, and publishes each redirect with a single atomic store (see Tier 1). The
  interactive demo still reloads between ticks for clarity; the multithreaded path is
  exercised by `mt_test/`.
- Whole-program recompile per reload; no incremental build.
- New globals and new procedures may be *added* across a reload. An existing
  global's type/layout must not change (rejected at build time); new globals may
  carry compile-time constant initializers (applied once) but not runtime
  initializers or `@(init)`; and the new-global arena is a fixed size
  (`-hot-reload-arena-size`, default 256 KiB).
- Reflection from hot code works (`fmt` of basic types, `%v` on a user struct, `typeid`) as
  long as the type already existed in the base build's `type_table`; a brand-new type
  introduced *only* by a hot edit is absent from the frozen `type_table` and won't reflect.
- Each reload leaks the mapped object block (and any trampoline / import-cell pages), and the
  loader's PDB symbol map is populated once and kept for the process lifetime. The registered
  `.pdata` (`RtlAddFunctionTable`) is never paired with `RtlDeleteFunctionTable`, so the
  function-table registry also grows across reloads (unwinding stays valid, but it is a leak).
- **Stale procedure pointers.** Only direct call sites and the patched hot-proc entries
  redirect to new code. A `proc` value stored in a global/struct/vtable that points at a
  *non-hot* proc which was recompiled is now stale; a stored pointer to a *hot* proc's entry
  keeps working (the entry is patched to jump). Keep dispatch tables pointing at `@(hot_reload)`
  procs, or rebuild them after a reload.
- **Editing an existing *mutable* global's initializer has no effect.** Ordinary globals are
  preserved (old value kept); only *new* globals get their compile-time constant initializer
  applied, once. This is by design (state preservation) but is a sharp edge. **Exception:**
  `@(rodata)` globals and `#load`-initialized globals are *immutable data*, not state — their
  edited value/bytes ARE re-provided on every reload (see the `@(rodata)`/`#load` item under
  Tier 1). To get an editable embedded value refreshed on reload, make it `@(rodata)` or `#load`.
- **`@(rodata)`/`#load` refresh caveats.** (a) The refresh repoints/overwrites the exe's *canonical*
  copy, so a pointer to that data saved into other mutable state before the reload becomes stale
  (it points at the pre-reload bytes; for `#load` that is the previous mapped block — leaked, so
  still valid, but old). (b) A **value-type** `@(rodata)` is overwritten in place, so its type/size
  must not change across a reload (the existing type-hash guard rejects a change); variable-size
  data should be a slice/string/`#load`, whose header is repointed instead. (c) Writing through
  such data is a user bug and faults (its pages are re-protected read-only by the W^X pass), the
  same as in a normal build.
- **Globals show under their mangled link name in the debugger (`-hot-reload` builds only).**
  To make a pre-existing global resolvable in the PDB (so a reload binds to the exe's copy and
  preserves state), the compiler sets a file-scope global's debug DISPLAY name to its link name
  (`pkg::hits`) instead of its source identifier (`hits`) under `-hot-reload`
  (`src/llvm_backend.cpp`, `LLVMDIBuilderCreateGlobalVariableExpression`). LLVM's CodeView
  emitter names the PDB data symbol after the display name, so this was necessary — but the
  side effect is that in WinDbg/VS/raddbg a global appears as `pkg::hits`, and a watch/hover on
  the bare `hits` may not resolve (use the qualified name). Only file-scope GLOBALS are
  affected — procedures, locals, types, fields, line info, breakpoints, backtraces, and any
  build WITHOUT `-hot-reload` are unchanged; there is no effect on codegen/layout/ABI/runtime.
  Possible refinement: give globals external (public) linkage under `-hot-reload` instead — the
  PDB *publics* stream would then carry the link name (loader-resolvable) while the CodeView
  symbol keeps the source display name (nice debugging), at the cost of publicizing all globals.
- Reload is not transactional across a mid-batch `patch_jump` failure: all targets are
  validated before the first write (so a renamed/removed hot proc aborts cleanly with nothing
  applied), but there is no rollback if a write fails partway through the batch.

## Type-migration gaps (pre/post-patch hooks + reflection migration)

The `@(pre_patch_hook)`/`@(post_patch_hook)` + name-keyed reflection serializer path
(diff in `core/sys/hot_reload/hot_reload.odin`: `hr_layout_differs` / `hr_contains_changed` /
`hr_build_type_changes`; serializer in `examples/hot_reload/migrate/serializer.odin`, copied
into `migrate_full/` and `migrate_enum/`) is scoped to **simple layout changes of a single,
self-contained value struct you hold by pointer**. Everything below is outside that scope.

### Detection gaps — changes the diff will not flag
- **Same-size field-type substitution** (`x: i32 → x: f32`, or `x: Foo → x: Bar` at the same
  size/offset/name). `hr_layout_differs` compares struct fields by name + offset only (not
  type), and transitive flagging fires only on a *changed named type* — `i32`/`f32` are each
  unchanged in themselves. The struct is not flagged **and** the serializer raw-copies the
  bytes → **silent corruption**.
- **Type rename or move to another package.** The diff keys on package-qualified name and has
  no type-level alias (`fs` is field-level). Old name looks removed, new name brand-new → not
  migrated (field zeroes).
- **Bit-sets** are still compared by size alone (a same-size underlying-enum reorder is missed).
- **Qualified-name collision** — two distinct `pkg.Name` types (local types in different procs,
  generic instantiations) can mispair; `change.old` is then wrong (the serializer ignores it,
  but a hook reading it is misled).
- **Anonymous (unnamed) types** are never reported — only named types are.

### Migration gaps — changes the serializer will not handle even when flagged
- **Enum value with no matching saved constant** (a raw/out-of-range integer or bit-flags stored
  in an enum) → `saved_field` stays nil → **nil-deref crash**. Cheapest fixable sharp edge.
- **`#no_nil` unions** — `if src_tag == 0 do break` treats tag 0 as nil, but for `#no_nil` tag 0
  is a real variant, so that variant is skipped. Cheap to fix (check union flags).
- **Pointers / slices / dynamic arrays / maps / cstring / procs** — raw-copied as a handle, never
  followed. The pointee graph is not migrated; if a pointee's type changed the handle points at
  old-layout bytes read as new → corruption; owned heap **leaks or dangles**.
- **Type-incompatible field reuse** (kind mismatch after a name match) falls back to
  `mem.copy(min(size))` → garbage.
- **Bit-fields, SOA, matrix/complex/quaternion/simd, and enum/tag backing sizes other than
  1/2/4/8** are not in the handled variant set → raw copy (fine if unchanged, garbage if changed).

### Architectural gaps — by design of this first pass
- **No instance enumeration.** The system reports which *types* changed, not which *objects*
  exist. Finding and migrating **every** live instance of a changed type (entity arrays, nested
  owners) is entirely the hook's job — there is no object registry. This is the largest practical
  gap versus a real engine's migration.
- **Reference invalidation.** The post-hook allocates a new object and swaps one pointer; every
  other `^T` held elsewhere (other globals, stacks, other threads) dangles against the freed old
  object.
- **No semantic migration.** Byte-by-name only: it cannot convert units (`f32` degrees→radians),
  give a new field a non-zero default, salvage a removed field's data, or re-establish cross-field
  invariants. All such fix-up must be manual in the hook body.
- **Not coordinated with other threads** touching the state during pre/post (the *patch* is
  thread-safe; the *migration* is not).
- **Ownership/allocator** of the new object is the hook's `context.allocator`; arenas and owned
  resources are the user's responsibility.

### Severity / fixability
| Gap | Effect | Cheap fix? |
|---|---|---|
| Enum value with no matching constant | crash (nil deref) | yes — guard, fall back to raw/zero |
| `#no_nil` union tag-0 | wrong variant migrated | yes — check union flags |
| Same-size field-type substitution | silent corruption | no — needs deep field-type compare + conversion |
| Type rename / move | field lost | medium — a type-level alias |
| Pointers/maps not followed | dangling / leak / corruption | no — inherent to reflection migration |
| Instance enumeration / ref invalidation | unmigrated or dangling objects | no — needs an object-registry design |

## Adversarial review findings (PDB-resolver refactor)

Full findings from the adversarial review of the PDB-based refactor (dropping the baked
`runtime.hot_reload_symbol_table`). `[x]` = fixed, `[ ]` = still open. Line refs are
approximate against `core/sys/hot_reload/hot_reload.odin` unless noted.

- [x] **F1 — HIGH — `SymEnumSymbolsW` result ignored → partial/empty map → silent state
      loss.** A missing/public-only PDB or a part-way enumeration left `_hr_syms` empty while
      `hr_dbghelp_ensure` still reported success, so every pre-existing symbol resolved to a
      fresh object-local copy (state reset) with only a misleading "no @(hot_reload)
      procedures found" message. FIX: `hr_dbghelp_ensure` now checks the `SymEnumSymbolsW`
      return and treats an empty map as a hard error with a PDB-specific message.
- [ ] **F2 — HIGH (fragility) — hot detection assumes the 16-byte prefix is literal `0x90`
      NOPs, and is stricter than the patcher's own pad check.** `hr_is_hot_entry` requires all
      16 pre-entry bytes == `0x90` (or a leading `FF 25`), while `hr_patch_atomic`'s
      `hr_has_patch_pad` also accepts `0xCC` over 14 bytes. A future LLVM emitting multi-byte
      NOPs for `patchable-function-prefix`, or a `0xCC` creeping into the prefix, would make
      every hot proc undetectable. PARTIALLY MITIGATED: it now fails *loudly* (empty
      `hot_names` → clear error) instead of silently no-opping. Still open: recognize standard
      multi-byte NOP encodings, unify the two pad predicates, and/or have the compiler stamp
      an unambiguous sentinel; add a load-time self-test that a known hot symbol is detected.
- [x] **F3 — MEDIUM — TLS/register/frame/value symbols poison `_hr_syms` with a non-VA
      `Address`.** `hr_enum_cb` stored `pSym.Address` unconditionally; for a thread-local that
      is a TLS-relative offset, not a pointer. Dodged today (TLS goes via accessors) but a
      live landmine. FIX: `hr_enum_cb` skips symbols flagged `SYMFLAG_TLSREL/REGISTER/REGREL/
      FRAMEREL/VALUEPRESENT/CONSTANT` (constants added to `core/sys/windows/dbghelp.odin`).
- [ ] **F4 — MEDIUM — first-seen-wins on duplicate enumerated names; no section/tag
      disambiguation.** DbgHelp enumerates a symbol under multiple records (public + private);
      usually same address, but a public thunk vs. real body, or an Odin link name colliding
      with a library symbol (more likely now that `/OPT:NOREF` keeps every library member),
      could bind a name to the wrong address. FIX (todo): prefer the record whose address is in
      the exe's `.text`/data range and whose Tag matches; log conflicting addresses.
- [x] **F5 — MEDIUM — loader hardcodes the exe module but the `-debug` gate admitted
      DLL/lib hosts.** `alloc_near_exe`/`hr_resolve_exported`/enumeration all use
      `GetModuleHandleW(nil)` (the exe), but a `-build-mode:dll`/`:staticlib` host would be
      enumerated/patched against the wrong image. FIX: `src/main.cpp` now requires the
      hot-reload host to be `-build-mode:exe` (reload objects use `:obj`).
- [ ] **F6 — MEDIUM — no build-identity check between reload object, manifest, and running
      exe.** Reload a stale object (base exe rebuilt, arena relaid) or one built for a
      different exe and the loader writes const-init blobs at now-wrong offsets and patches —
      silent corruption. FIX (todo): bake a build-id (manifest-layout hash) into both the exe
      (a resolvable symbol) and the reload object; loader compares and refuses on mismatch.
      *Highest-value missing safety net; also listed under Tier 3.*
- [x] **F7 — MEDIUM — reload not transactional; partial patch on mid-batch failure.** A
      missing hot proc was skipped and the rest patched (program left split across two
      versions). FIX: all hot targets are resolved+validated before the first write; any
      failure aborts the whole reload with nothing applied. (Rollback after a mid-batch
      `patch_jump` failure is still not implemented — see Known limitations.)
- [ ] **F8 — MEDIUM — no signature/ABI guard on hot procedures** (globals are type-checked,
      procs are not). Changing a `@(hot_reload)` proc's parameter/return types corrupts the
      frozen host's call sites. FIX (todo): record a canonical signature hash per hot proc in
      the manifest and reject a changing reload. *Also listed under Tier 2.*
- [x] **F9 — LOW/MEDIUM — atomic-patch pad write not covered by the IP-conflict region.** The
      stop-the-world check guarded `[entry, entry+PATCH_LEN)` but the atomic path also writes
      the 16-byte pad below the entry. FIX: the region is now `[entry-PAD_LEN, entry+PATCH_LEN)`.
- [ ] **F10 — LOW (goal regression, not a bug) — `/OPT:NOREF` broadly undermines the
      size motivation for dropping the table.** Forcing `/opt:noref` keeps every linker-visible
      object member (CRT, whole static libs). LLVM-level DCE of Odin symbols is still regained,
      but the net binary-size win is smaller than the framing implies. Accepted trade-off (user
      requested auto-NOREF for whole-lib calls); documented under the Tier 3 `/OPT` item.
- [x] **F12 — LOW — `ADDR32NB` assumed every target in-block, unchecked.** FIX: an
      out-of-block target is now refused (counted unresolved) instead of writing a wrapped RVA.
- [ ] **F11 — LOW.** Symbols dropped on UTF-8 conversion / empty name are silent (consider
      logging in debug builds).
- [x] **F13 — LOW/MEDIUM — process-lifetime state aliased the caller's allocator.** `_hr_syms`,
      `_hr_cur`, and `hr_exe_types_cache` (backing store **and** string keys) were allocated from
      whatever `context.allocator` the first `apply()` caller had installed; a scoped/temporary
      allocator would free them under the loader (use-after-free on the next reload). FIX: all
      three are pinned to `runtime.heap_allocator()` (OS heap, caller-independent). Additionally,
      the loader's per-call scratch was moved off the app's `context.temp_allocator` onto a private
      heap-backed `runtime.Arena` (overridden once at the top of `load_and_patch`, freed each
      reload), so a whole-program reload no longer spikes/overflows the application's temp arena.
- [x] **F14 — LOW/MEDIUM — `apply()` not re-entrant / thread-safe.** FIX: a `_hr_busy` atomic
      compare-exchange guard at the reload entry refuses a concurrent or nested reload with a clear
      message instead of corrupting the shared maps + DbgHelp session. (Still call it from one
      thread, one reload at a time — the guard makes a violation fail loudly, it does not make
      concurrent reloads work.)

### What's still missing (independent of the TODO tiers above)

- **Build-identity / staleness safety (F6)** and **hot-proc ABI guard (F8)** — the two
  highest-value correctness safety nets, both absent.
- **Transactional reload with rollback (F7 remainder)** — no all-or-nothing guarantee if a
  write fails partway through the batch.
- **Stale function pointers held in state** — see Known limitations (non-hot proc pointers).
- **Changed initializers for existing globals do nothing** — see Known limitations.
- **Threads created between the suspend-snapshot and the patch** are not suspended (safe for
  the atomic path, unsafe for the non-atomic fallback).
- **Positive confirmation that the PDB resolved *private* symbols** — the whole design leans
  on DbgHelp finding private CodeView symbols; a load-time self-test (look up one known Odin
  symbol) would turn F1/F2's remaining silent paths into clear diagnostics.
- **`radlink` PDB compatibility** with DbgHelp is unverified (an accepted `linker_choice`).
