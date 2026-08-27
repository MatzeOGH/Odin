# Live++-style in-process hot reload (proof of concept)

Windows / x64. This demonstrates replacing the machine code of a **running** Odin
executable with freshly compiled code, without restarting the process and without
a DLL boundary — the way [Live++](https://liveplusplus.tech/) works.

Unlike the usual "compile the game as a DLL and reload it" pattern, here the
source uses **normal direct calls** and **no per-procedure tags** — under
`-hot-reload` every procedure is hot-patchable automatically (Live++-style). On
reload we recompile the program to a COFF object, load that object directly into
the running process, **relocate it against the running process**, and overwrite
the prologue of each procedure **whose code changed** with a jump to the fresh
code. Existing call sites reach the new code transparently; process state —
including package **globals** — is untouched.

A reload may also **introduce new globals and new procedures** (see below).

## Manual workflow (edit, then reload by hand)

Use the `odin.exe` from **this repo** (it has `-hot-reload` and the
`core:sys/hot_reload` loader package).

1. **Build the demo once and run it.** `-hot-reload` reserves the new-global arena
   and (implying `-debug`) produces the PDB the loader resolves symbols from;
   `-hot-reload-manifest` records the layout so reload builds can line up against
   it. It loads `hot.obj` from its working directory, so run it from this folder:

   ```
   odin build examples/hot_reload -out:examples/hot_reload/hot_reload.exe -debug -hot-reload -hot-reload-manifest:examples/hot_reload/hot.manifest
   cd examples/hot_reload
   .\hot_reload.exe
   ```

   Type `t` + Enter a few times. `counter` (host state) and `hits` (a global) advance.
   **Leave it running.**

2. **Edit** `examples/hot_reload/game.odin` — change the body of `update`, and
   optionally **add a new global or a new procedure** and use them from `update`.
   Save.

3. **Rebuild only the object** in a second terminal (do *not* rebuild the exe —
   that would restart the process). Pass the **same** manifest so any new global
   gets a stable arena slot:

   ```
   odin build examples/hot_reload -build-mode:obj -use-single-module -hot-reload -hot-reload-manifest:examples/hot_reload/hot.manifest -out:examples/hot_reload/hot.obj
   ```

4. Back in the running program, press `r` + Enter. It patches `update` in place.
   Type `t` again — new behavior, `hits` continues, any new global keeps its value
   across further reloads, and the **pid is unchanged**.

## Or run the whole thing scripted

```
powershell -ExecutionPolicy Bypass -File examples\hot_reload\demo.ps1
```

This builds the exe, simulates an edit that **adds new globals** (`reloads`, and
`threshold`/`limits` with **compile-time constant initializers**) and a **new
procedure** (`bonus`), compiles it to `hot.obj`, and drives **two** reloads.
`mirror` is where hot code stashes the new `threshold` global so the host can see
it:

```
==> new-global arena slots recorded in the manifest:
next_free 49
new 0  3300913439211647358 0  hot_reload_demo::reloads     # zero-init, no flag
new 8  3300913439211647358 17 hot_reload_demo::threshold   # const 42, init-flag at 16
new 24 3211830901467771920 49 hot_reload_demo::limits      # const [3]i64, init-flag at 48
...
> counter = 1   hits = 2   mirror = 0
counter = 2   hits = 4   mirror = 0
reload ok: true
counter = 37   hits = 6   mirror = 43   # const init applied (42) then +1; counter += 10+5+limits[1]=20
reload ok: true
counter = 72   hits = 8   mirror = 44   # threshold persisted across reload 2 (not reset to 43)
```

`mirror` reaching `44` (not `43`) is the point: the new global's **constant
initializer is applied exactly once**, and its state persists across every
reload. `counter` jumping by 35 per tick shows the aggregate constant `limits`
was written correctly too. The `[hot] fmt from hot code …` line is printed **by the
patched `update` itself** — `fmt` of ints now works from inside hot code. (The
`[hot] note: 0 unresolved and N unsupported …` line is expected: `unsupported`
counts leftover debug relocation kinds in code paths you never execute (unwind
`.pdata`/`.xdata` relocations are now handled, so they no longer count here);
`unresolved` should be 0 — a nonzero count in `.text` now aborts the reload with
the symbol name.)

## How it works

1. **The build flag (no tags).** Building with `-hot-reload` makes **every**
   eligible procedure replaceable — no `@(hot_reload)` tag. The compiler gives each
   one `noinline` and a patchable prologue (a 16-byte pad + short-redirect entry);
   `@(no_hot_reload)` opts a procedure out. `-hot-reload` implies `-debug`.

2. **PDB-based resolution + change detection.** There is no baked symbol table. The
   loader resolves the running exe's procedure/global addresses from the exe's
   **PDB** (DbgHelp), and the compiler emits a small `{name_hash, content_hash}`
   table (`__odin_hot_reload_func_hashes`, no addresses — dead-code elimination
   stays on) so the loader patches only the procedures whose code actually changed.

3. **The new-global arena + manifest.** `-hot-reload` also reserves a zero-init
   arena (`__odin_hot_reload_global_arena`) in the exe. The compiler writes a
   **manifest** (`-hot-reload-manifest:<path>`) recording every original global
   and, for reload builds, the arena offset assigned to each **new** global — so
   the same new global lands at the same address every reload and its state
   persists.

4. **Recompile to an object.** On reload the whole program is rebuilt to one COFF
   object with `-hot-reload -hot-reload-manifest:<same path> -build-mode:obj
   -use-single-module`.

5. **Load + relocate + patch** (`core:sys/hot_reload`, call `hot_reload.apply("hot.obj")`):
   - Map the object's sections into one contiguous block reserved **within ±2 GB
     of the exe** (so RIP-relative references stay in range).
   - Apply `AMD64_REL32`/`REL32_1..5`/`ADDR64` relocations. Each target symbol is
     resolved by policy: a symbol that exists in the running exe and is **not** hot
     → the exe's address (reuses procedures and points existing globals at the
     exe's copy); a **hot** symbol → the object's fresh copy; an object-local
     symbol (new procedures, constants, labels) → its loaded copy. New globals
     reference the arena symbol (resolved to the exe's arena) plus a byte offset.
     An **undefined external** not in the table — a C-runtime helper
     (`memcpy`/`memset`/…), `_tls_index`, an `__imp_*` import cell, or a Windows-API
     symbol — is resolved against the running process via `GetProcAddress` / an
     in-image reference / a synthesised pointer cell; if the target is beyond REL32
     range it is reached through a near-block absolute-jump trampoline. This is what
     lets hot code call `fmt` and the rest of the standard library. As a final
     fallback the external is looked up in the exe's **PDB** (DbgHelp
     `SymFromNameW`), which resolves non-exported, in-image symbols — in particular a
     **statically-linked foreign-library function** (e.g. a `vendor:raylib` proc) the
     base source never referenced. That needs the exe built with `-debug` (a PDB) and
     `/OPT:NOREF,NOICF` so the linker keeps such unreferenced functions in the image;
     see `demo_raylib.ps1`. Adding a library *not* linked into the base exe at all is
     not supported.
   - Redirect each running procedure whose code changed to its fresh copy (atomic
     short-jump publish into the prologue pad, or a 14-byte overwrite fallback) and
     `FlushInstructionCache`. `apply` discovers which procedures to patch itself
     (structurally, via the prologue pad, filtered by the change-detection hashes),
     so callers don't list them.

## Scope and limitations

Works: replacing a running procedure; hot code that reads/writes existing package
globals (state preserved); **new procedures** (called from hot code, transitively);
**new globals** (persist across reloads via the arena); and **`fmt`/`any`/reflection
from hot code**, including `%v` over user structs and `typeid_of(T)` for any type
present in the program at exe-build time.

Out of scope for this PoC (documented edges):

- **Runtime initializers for new globals.** New globals may carry **compile-time
  constant** initializers — the loader writes them into the arena exactly once (via
  a per-global flag byte), so they start at their declared value and then persist.
  A *runtime* (non-constant) initializer or a new `@(init)` for a fresh global is
  still unsupported (rejected at build time).
- **New host-callable entry points.** A brand-new procedure is reachable through
  the patched call graph, but the frozen host cannot gain a new direct call site.
- **Changing an existing global's type/layout** across a reload is rejected at
  build time (its preserved memory cannot be reinterpreted). The new-global arena
  is a fixed size (`-hot-reload-arena-size`, default 256 KiB).
- **Reflection over a brand-new type introduced only by a hot edit.** `fmt`/`any`/
  reflection over any type that exists in the program at exe-build time now works
  from hot code (`typeid` is the build-stable canonical hash; under `-hot-reload` the
  exe's `type_table` is made complete and hot code resolves `type_info` through it).
  But a type that appears *only* in a reload edit is absent from the exe's frozen
  `type_table`, so reflection on it won't be correct.
- Each reload leaks the mapped block (new-global storage is in the exe arena, so it is
  unaffected); whole-program recompile per reload; x64 / Windows / COFF only.

Thread safety: patching is safe while other threads run the hot procedures. On a reload
the loader suspends every other thread, checks none is parked in a prologue it is about to
overwrite (retrying if so), and publishes each redirect by flipping the 2-byte hotpatch
entry to a short jump into a compiler-emitted 16-byte pad with a single atomic store — so
a concurrent thread never executes a half-written instruction. In-flight calls already
inside the old body finish on the old code (it stays mapped); new calls take the jump. The
`examples/hot_reload/mt_test` program is an automated regression test for this
(`run_mt_test.ps1`: worker threads hammer the hot proc while the main thread reloads 200×;
exit 0 = PASS).

## Files

- `game.odin` — the demo: an ordinary (untagged) procedure `update` and a `main`
  REPL that calls `hot_reload.apply`.
- `demo.ps1` — builds the exe, simulates an edit that adds a new global + proc →
  `hot.obj`, and drives two reloads.
- `demo_raylib.ps1` — builds the exe with `vendor:raylib` statically linked, then
  reloads code that calls a raylib procedure the base source never referenced
  (`rl.GetRandomValue`), resolved via the exe's PDB.
- `mt_test/` — automated regression test for thread-safe patching (see above).
- `rodata_test/` — automated regression test for `@(rodata)` / `#load` / `#load_directory`
  / `#hash` / `#load_hash` refresh (`run_rodata_test.ps1`: a data-only reload changes a
  `@(rodata)` value, a size-changed `#load` asset, a `#load_directory` file, a `#hash`
  literal, and the `#load_hash` file; all are observed while an ordinary mutable global
  keeps its runtime value; exit 0 = PASS).
- The loader itself now ships as **`core:sys/hot_reload`** (no longer copied here).

## Compiler / library changes this depends on

- Tagless patchability + `@(no_hot_reload)` opt-out — `src/checker.{hpp,cpp}`,
  `src/entity.cpp`, `src/check_decl.cpp`, `src/llvm_backend_proc.cpp`
  (`lb_proc_is_hot_reloadable`).
- `-hot-reload` (implies `-debug`), `-hot-reload-arena-size`, `-hot-reload-manifest`
  flags; PDB-based resolution + change-detection hash table
  (`__odin_hot_reload_func_hashes`); new-global arena + manifest; auto
  `/OPT:NOREF,NOICF` — `src/main.cpp`, `src/build_settings.cpp`,
  `src/llvm_backend.cpp`, `src/linker.cpp`, `core/sys/windows/dbghelp.odin`
  (`SymEnumSymbolsW`).
- Reflection from hot code — under `-hot-reload`, a complete `type_table`
  (`src/checker.cpp`, `generate_minimum_dependency_set`) and typeid-based
  `type_info` resolution (`src/llvm_backend_type.cpp`, `lb_type_info` →
  `__type_info_of`).
- `@(rodata)` / `#load` / `#load_directory` / `#hash` / `#load_hash` refresh — immutable
  embedded data is re-provided fresh each reload by repointing the exe's canonical copy at
  the reload object's fresh copy (`__odin_hot_reload_refresh_syms` table + the loader's
  repoint pass; `#load_directory` globals are baked const under `-hot-reload` via
  `lb_const_load_directory_slice` so their header can be repointed; `#hash`/`#load_hash`
  constant-integer globals are overwritten in place, and their `::` constant form already
  refreshes via normal recompile), plus per-section W^X tightening of the mapped block —
  `src/llvm_backend.cpp`, `src/llvm_backend_stmt.cpp`, `src/llvm_backend.hpp`,
  `core/sys/hot_reload/hot_reload.odin`.
- `core:sys/hot_reload` — the COFF loader/relocator/patcher + `apply`.
- `FlushInstructionCache` binding — `core/sys/windows/kernel32.odin`.
