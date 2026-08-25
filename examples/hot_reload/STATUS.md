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
- [x] **`-hot-reload` build flag** — forces single module and bakes the symbol table.
      - `src/main.cpp` (BuildFlag_HotReload), `src/build_settings.cpp` (bool hot_reload).
- [x] **`runtime.hot_reload_symbol_table`** — `{name, address, is_hot}` for every
      generated procedure and global; the running process's name→address map.
      - `base/runtime/core.odin` (declaration),
        `src/llvm_backend.cpp` (`lb_generate_hot_reload_symbol_table`).
- [x] **`FlushInstructionCache` binding** — `core/sys/windows/kernel32.odin`.
- [x] **COFF object loader / relocator / patcher** — `examples/hot_reload/hot_reload.odin`:
      parse COFF, map the object in one block **within ±2 GB of the exe**, apply
      `AMD64_REL32`/`REL32_1..5`/`ADDR64` relocations with the resolver policy
      (in-table & not hot → exe addr; hot → object copy; object-local → loaded copy),
      overwrite each running procedure's prologue with a 14-byte `FF 25` absolute jump.
- [x] **Global state preserved across reload** — validated by the demo (`hits` keeps
      counting through a reload).
- [x] Demo + scripted repro — `game.odin`, `demo.ps1`.

## TODO

### Tier 1 — architectural (the real gaps to Live++)

- [ ] **Incremental compilation.** Recompile only changed procedures/modules instead
      of the whole program to one object each reload. Needs compiler work to emit and
      reuse per-procedure or per-module objects (object emission is in
      `src/llvm_backend.cpp` ~`lb_llvm_object_generation`, currently temp-and-delete).
- [ ] **Thread-safe / atomic patching.** Today the 14-byte overwrite is non-atomic and
      assumes single-threaded; a thread executing inside a procedure being patched will
      corrupt/crash. Needed:
  - [ ] Suspend all other threads during a patch.
  - [ ] Inspect each thread's instruction pointer; defer the patch or relocate an IP
        that sits inside a procedure being replaced.
  - [ ] Replace the 14-byte overwrite with the MSVC 2-byte hotpatch prologue + a
        `/FUNCTIONPADMIN` pre-function pad holding the long jump (atomic short-jump
        publish). The `"patchable-function"` attribute already lays the groundwork.
- [ ] **Unwind info for new code.** Register the loaded object's `.pdata`/`.xdata`
      (`RtlAddFunctionTable`) so panics/exceptions and stack walks through hot code
      work. Requires handling `IMAGE_REL_AMD64_ADDR32NB` relocations for those sections.

### Tier 2 — correctness / capability

- [ ] **Import (`__imp_*`) resolution.** Resolve IAT imports so hot code can call
      foreign / Win32 functions directly (currently counted as "unresolved").
- [ ] **More relocation kinds.** `ADDR32NB` (needed for unwind + some data), `ADDR32`,
      `SECREL`/`SECTION` (debug/TLS). Error loudly if an *unsupported* relocation lands
      inside a hot procedure (today all unsupported ones are silently skipped).
- [ ] **New symbols across a reload.** Support referencing procedures/globals that
      weren't in the original build (not in the table), adding new globals, and running
      new `@(init)` / global initializers for freshly introduced state.
- [ ] **Variadic / `any` from hot code.** `fmt.*` etc. are unreliable because
      `typeid`/`type_info` identity isn't guaranteed to match the running exe across
      builds (an argument came out garbage and crashed). Either guarantee stable type
      numbering under `-hot-reload`, or resolve type-info/`typeid` through the running
      exe. Until then: keep printing/logging in the host.
- [ ] **Function-local statics.** Verify local `@(static)` variables resolve to the
      exe copy (preserved) rather than an object-local copy.

### Tier 3 — robustness / lifecycle

- [ ] **`/OPT:NOICF` when hot procedures exist** — stop the linker folding identical
      procedures (would break per-procedure patching). Add in `src/linker.cpp`.
- [ ] **Validate optimized builds** (`-o:speed`/`-o:size`) — cross-TU inlining and
      COMDAT folding can defeat patching; confirm `noinline` + single module hold up.
- [ ] **Free the previously mapped block** on the next reload (currently leaks one
      block per reload); optionally support unpatch / rewind.
- [ ] **Guard the 14-byte patch** — assert the procedure is ≥14 bytes to its next
      16-byte-aligned neighbor before overwriting (today relies on 16-byte alignment).
- [ ] **Drop the baked table / binary bloat** — resolve exe symbol addresses from the
      PDB instead of `-hot-reload` baking a full table and rooting all symbols (which
      disables dead-code elimination and grows the binary).

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

## Known limitations (current, by design of the PoC)

- Windows / x64 / COFF only.
- Single-threaded; patch at a safe point (the demo does it between ticks).
- Whole-program recompile per reload; no incremental build.
- Type/global set must be stable across a reload — only procedure *bodies* may change
  (no struct-size changes, no added globals/types). Same restriction Live++ imposes.
- Keep `fmt`-style variadic/`any` calls in the host, not in hot procedures.
- Each reload leaks the mapped object block.
