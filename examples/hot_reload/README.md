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
`core:hot_reload` loader package).

1. **Build the demo once and run it.** `-hot-reload` reserves the new-global arena,
   implies `-debug` (producing the PDB the loader resolves symbols from), auto-adds
   `/OPT:NOREF,NOICF`, and writes the manifest (default
   `<pkg>/odin-hot-reload.manifest`) so reload builds line up against it. Run it from
   this folder (it reloads objects from `.\hot_objs\`):

   ```
   odin build examples/hot_reload -out:examples/hot_reload/hot_reload.exe -hot-reload
   cd examples/hot_reload
   .\hot_reload.exe
   ```

   Type `t` + Enter a few times. `counter` (host state) and `hits` (a global) advance.
   **Leave it running.**

2. **Edit** `examples/hot_reload/game.odin` — change the body of `update`, and
   optionally **add a new global or a new procedure** and use them from `update`.
   Save.

3. **Rebuild only the patch** in a second terminal (do *not* rebuild the exe —
   that would restart the process). One command — `-hot-reload-patch` implies
   `-build-mode:obj`, emits into `.\hot_objs\` (created + stale `*.obj` cleared), and
   reuses the default manifest so any new global gets a stable arena slot:

   ```
   cd examples/hot_reload
   odin build . -hot-reload-patch
   ```

4. Back in the running program, press `r` + Enter. It patches `update` in place.
   Type `t` again — new behavior, `hits` continues, any new global keeps its value
   across further reloads, and the **pid is unchanged**.

### Skip the manual build: press `b`

Steps 3–4 collapse into one: after editing, press `b` + Enter. The running program
rebuilds the patch itself and reloads it — no second terminal. That is
`hot_reload.apply_patch()`, which runs `odin build <pkg> -hot-reload-patch` for you
(via `core:os` `process_exec`), streams any compiler errors, and reloads **only if the
build succeeds** — a failed build is surfaced and the running code is left untouched, so
a typo never takes the session down. It finds the package to rebuild from the `pkg_dir`
the `-hot-reload` exe build recorded in the manifest; `odin` is taken from `PATH` unless
you pass a path (the demo passes `..\..\odin.exe`). `build_patch()` is the same rebuild
without the reload. Launch the program from the same shell the base build used, so the
child `odin` inherits the build environment (the environment is not baked into the
manifest).

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

4. **Recompile to an object.** On reload the program is rebuilt to reload object(s)
   with a single `odin build <pkg> -hot-reload-patch` — that flag implies
   `-build-mode:obj`, defaults `-out` to `<pkg>/hot_objs/` (created, and stale `*.obj`
   cleared), and reuses the default manifest. The explicit flags
   (`-hot-reload -build-mode:obj -hot-reload-manifest:<path> -out:<dir>`) still work
   and are needed only when the exe and the reload build come from different directories.

5. **Load + relocate + patch** (`core:hot_reload`, call `hot_reload.apply("hot.obj")`):
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
  REPL where `b` = `hot_reload.apply_patch` (rebuild + reload in-process) and `r` =
  `hot_reload.apply_dir` (reload only).
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
- The loader itself now ships as **`core:hot_reload`** (no longer copied here).

## Reacting to struct layout changes (pre/post-patch hooks)

A reload can also **change the layout of a struct the running program holds** — add,
remove, reorder or rename a field. New code addresses fields at new offsets, so live
state laid out the old way must be migrated. This mirrors Live++'s
`LPP_HOTRELOAD_PREPATCH_HOOK` / `POSTPATCH_HOOK`:

- Mark a proc `@(pre_patch_hook)` or `@(post_patch_hook)`. The loader **autowires**
  them — no registration call. Signature: `proc(changed: []hot_reload.Type_Change)`.
- Before patching, the loader diffs the reloaded object's type-info against the exe's
  and calls every pre hook (running the **old** code) with the set of types whose
  layout changed. After patching it calls every post hook (running the **new** code)
  with the same set. Each `Type_Change` carries the `old` and `new` `^runtime.Type_Info`.
- Serialization is entirely yours: a pre hook serializes the live state, a post hook
  rebuilds it in the new layout. Reflect the destination via `change.new` — in hot
  code `type_info_of(T)` still resolves to the exe's **old** table.

The diff compares each named type by package-qualified name and reports it changed on a
size change, a struct field add/remove/reorder/rename, an enum constant add/remove/
reorder/re-value, a union variant add/remove/reorder, or a kind change — and it flags a
type **transitively**, so a struct is reported when any type it embeds by value (a nested
enum/union/struct) changed in place even though the struct's own size is unchanged. The
exe side of the diff is cached (the exe never changes across reloads).

Four self-driving tests:

```
powershell -ExecutionPolicy Bypass -File examples\hot_reload\migrate\run_migrate_test.ps1
powershell -ExecutionPolicy Bypass -File examples\hot_reload\migrate_enum\run_migrate_enum_test.ps1
powershell -ExecutionPolicy Bypass -File examples\hot_reload\migrate_full\run_migrate_full_test.ps1
powershell -ExecutionPolicy Bypass -File examples\hot_reload\hook_test\run_hook_test.ps1
```

- `migrate/` — the reload inserts a field at the front of `State` (shifting every
  offset); a name-keyed reflection serializer (`migrate/serializer.odin`) migrates the
  survivors to their new offsets while the new field zeroes.
- `migrate_enum/` — `State`'s own layout is unchanged; only a `u8`-backed enum it holds
  re-orders. Exercises transitive flagging plus a non-`int` enum remapped by name.
- `migrate_full/` — one reload that adds, renames (via an `fs:"..."` alias), reorders and
  removes struct fields, re-orders an enum's constants, **and** re-orders a union's
  variants; asserts every survivor is migrated by name (enum and union value remapped by
  name, not raw-copied).
- `hook_test/` — asserts the hooks autowire, that the pre hook runs old code and the post
  hook new code, and that the diff reports exactly the changed types (a changed struct, a
  same-size enum, a same-size union, and a struct flagged only transitively).

Hooks are resolved by exported name — pre hooks against the exe (old code), post hooks
against the reloaded object (its fresh copy) — so a post hook is an ordinary exported
proc, not a patchable/hot one. Serializer caveat: the vendored reflection serializer
handles value types only (no maps/dynamic-arrays/pointers across a reload — keep those
out of migrated state), and the diff still compares bit-sets by size alone.

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
  `core/hot_reload/hot_reload.odin`.
- `core:hot_reload` — the COFF loader/relocator/patcher + `apply`.
- `@(pre_patch_hook)` / `@(post_patch_hook)` attributes + emitted hook-name tables
  (`__odin_hot_reload_{pre,post}_patch_hooks`, storing each hook's exported symbol name):
  `src/checker.{hpp,cpp}`, `src/check_decl.cpp`, `src/entity.cpp`, `src/llvm_backend.cpp`;
  the new-layout type table (`__odin_hot_reload_type_infos`) in `src/llvm_backend_type.cpp`;
  `Type_Change`, the object-vs-exe type-info diff, and by-name hook dispatch in
  `core/hot_reload/hot_reload.odin`.
- `FlushInstructionCache` binding — `core/sys/windows/kernel32.odin`.
