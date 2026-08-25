# Live++-style in-process hot reload (proof of concept)

Windows / x64. This demonstrates replacing the machine code of a **running** Odin
executable with freshly compiled code, without restarting the process and without
a DLL boundary — the way [Live++](https://liveplusplus.tech/) works.

Unlike the usual "compile the game as a DLL and reload it" pattern, here the
source uses **normal direct calls**. On reload we recompile the program to a COFF
object, load that object directly into the running process, **relocate it against
the running process**, and overwrite the prologue of each running `@(hot_reload)`
procedure with a jump to the fresh code. Existing call sites reach the new code
transparently; process state — including package **globals** — is untouched.

## Manual workflow (edit, then reload by hand)

Use the `odin.exe` from **this repo** (it has `@(hot_reload)` and `-hot-reload`).

1. **Build the demo once and run it.** `-hot-reload` bakes a symbol table into the
   exe so the loader can resolve references against the running process. It loads
   `hot.obj` from its working directory, so run it from this folder:

   ```
   odin build examples/hot_reload -out:examples/hot_reload/hot_reload.exe -debug -hot-reload
   cd examples/hot_reload
   .\hot_reload.exe
   ```

   Type `t` + Enter a few times. `counter` (host state) and `hits` (a global) advance.
   **Leave it running.**

2. **Edit** `examples/hot_reload/game.odin` — change the body of `update`, e.g.
   `s.counter += s.step * 10`. The body may read/write globals and call other
   procedures. Save.

3. **Rebuild only the object** in a second terminal (do *not* rebuild the exe —
   that would restart the process). Write it next to the running exe:

   ```
   odin build examples/hot_reload -build-mode:obj -use-single-module -out:examples/hot_reload/hot.obj
   ```

4. Back in the running program, press `r` + Enter. It patches `update` in place.
   Type `t` again — new behavior, but **`hits` continues** from its previous value
   and the **pid is unchanged**.

## Or run the whole thing scripted

```
powershell -ExecutionPolicy Bypass -File examples\hot_reload\demo.ps1
```

This builds the exe, simulates an edit → `hot.obj`, and drives the reload
automatically. Expected output — the **pid is unchanged**, `counter` now advances
by the edited amount, and the global `hits` **keeps counting across the reload**:

```
hot-reload demo — pid 25532
> counter = 1   hits = 1
counter = 2   hits = 2
[hot] patched update: 0x7FF673A158F0 -> 0x7FF6738F3400
reload ok: true
counter = 12   hits = 3
counter = 22   hits = 4
```

That `hits` goes `2 → 3 → 4` is the point: the reloaded code writes the **exe's**
copy of the global, not a private one. A DLL swap cannot do this.

## How it works

1. **The language feature.** `@(hot_reload)` (a new procedure attribute) marks a
   procedure as replaceable. The compiler gives it `noinline` (so it stays a
   discrete, patchable function), a patchable prologue
   (`"patchable-function"="prologue-short-redirect"`), and exports it under a
   stable, unmangled symbol name so the loader can find it in a recompiled object.

2. **The symbol table.** Building with `-hot-reload` bakes
   `runtime.hot_reload_symbol_table` into the exe: `{name, address, is_hot}` for
   every procedure and global. It is the running process's name → address map.

3. **Recompile to an object.** On reload the whole program is rebuilt to one COFF
   object (`-use-single-module` puts every procedure in a single `.text`):

   ```
   odin build <package> -build-mode:obj -use-single-module -out:hot.obj
   ```

4. **Load + relocate + patch** (`hot_reload.odin`):
   - Map the object's sections into one contiguous block reserved **within ±2 GB
     of the exe** (so RIP-relative references stay in range).
   - Apply `AMD64_REL32`/`REL32_1..5`/`ADDR64` relocations. Each target symbol is
     resolved by policy: a symbol that exists in the running exe and is **not** hot
     → the exe's address (this reuses functions and, crucially, points global
     references at the exe's globals); a **hot** symbol → the object's fresh copy;
     an object-local symbol (constants, labels) → its loaded copy.
   - Overwrite each running hot procedure's first 14 bytes with
     `FF 25 00000000 <qword target>` (a RIP-relative absolute jump) and
     `FlushInstructionCache`. Procedures are 16-byte aligned, so the patch stays
     inside the procedure's own slot.

## Scope and limitations

Works: replacing a running procedure; hot code that reads/writes package globals
(state preserved) and references other procedures/data in the program.

Out of scope for this PoC (documented edges, not attempted):

- **Calls whose result depends on runtime type identity** (e.g. `fmt.*` and other
  variadic/`any`-based APIs) from *inside* hot code. Simple calls and global access
  work, but `any`/typeid values constructed in the reloaded object are not
  guaranteed to match the running exe's type numbering, so keep printing/logging in
  the host (as the demo does) rather than in the hot procedure.
- **Changing data layout across a reload** — adding/removing globals or types, or
  changing a struct's size. The reload assumes the type/global set is stable (only
  procedure *bodies* change). This is the same restriction Live++ imposes.
- Non-atomic patching (patch at a safe point — the demo does it between ticks);
  each reload leaks the previously mapped block; whole-program recompile per reload
  (Odin has no incremental builds yet); x64 / Windows / COFF only.

## Files

- `game.odin` — the demo: a `@(hot_reload)` procedure and a `main` REPL that reloads it.
- `hot_reload.odin` — the COFF object loader, relocator, and in-process patcher.
- `demo.ps1` — builds the exe, simulates an edit → `hot.obj`, and drives a reload.

## Compiler changes this depends on

- `@(hot_reload)` procedure attribute — `src/checker.{hpp,cpp}`, `src/entity.cpp`,
  `src/check_decl.cpp`, `src/llvm_backend_proc.cpp`.
- `-hot-reload` build flag + `runtime.hot_reload_symbol_table` emission —
  `src/main.cpp`, `src/build_settings.cpp`, `src/llvm_backend.cpp`,
  `base/runtime/core.odin`.
- `FlushInstructionCache` binding — `core/sys/windows/kernel32.odin`.
