# Odin hot reload — technical design

Live++-style in-process hot reload for Odin (Windows / x64). This document is the single
source of truth for why the feature works the way it does. The source (the compiler plus the
`core:sys/hot_reload` loader) keeps only short, local comments. Each such comment points back
here by section number.

The feature has two halves. They meet at a fixed set of emitted symbols.

- **Compiler** (`src/*.cpp`): under `-hot-reload` it makes each user procedure patchable. It
  redirects new globals into a persistent arena. It emits a small set of support symbols and
  tables that the loader reads by name.
- **Loader** (`core/sys/hot_reload/hot_reload.odin`): at run time it maps a fresh object into
  the running process, relocates it, and overwrites the prologue of each changed procedure with
  a jump to the new code. The process does not restart, and its state does not change.

Section 13 lists the `__odin_hot_reload_*` symbols that form the contract between the two halves.

---

## 1. Overview & model

Workflow:

    # build the host once
    odin build <pkg> -hot-reload -debug
    # recompile after an edit (this does not restart the process)
    odin build <pkg> -hot-reload-patch
    # from inside the running process
    hot_reload.apply_dir("hot_objs")

The reload recompiles with **separate modules** to a directory of COFF objects, one per
package. The running process then loads these objects directly. There is no DLL. The loader
relocates the objects against the exe and against each other. It then overwrites the prologue of
each running hot procedure whose code changed with a jump to the fresh code. Existing direct
calls reach the new code. The process never restarts, and its state stays intact.

The reload set is small on purpose. The standard-library collections (base, core, vendor) are
not emitted on a reload build. That code is already in the running exe, and the loader resolves
it from the exe's PDB. An unchanged user package is not re-emitted either. So a reload normally
produces the default/metadata object plus the package or packages that the user actually edited.
The loader maps every object before it relocates any of them. A new procedure or global in one
object is therefore reachable from another object. A cross-object reference past signed 32-bit
REL32 range goes through a near trampoline, like any far external.

The loader resolves relocations against *external* symbols (other procedures, runtime helpers,
and globals) against the addresses in the running process. It looks up each name in the exe's PDB
with DbgHelp `SymFromNameW`. No symbol table is baked into the exe. A relocation to an existing
global resolves to the exe's copy, so global state is preserved.

The loader recovers the set of procedures to patch by structure, not from a baked list. A hot
procedure's running entry is a 2-byte MSVC hot-patch slot in front of a 16-byte
patchable-function-prefix pad (section 7). An ordinary prologue never has this shape.

The loader registers the object's `.pdata`/`.xdata` unwind info with `RtlAddFunctionTable`, and
uses the loaded block as the image base. Windows x64 stack walking then works through hot code.
`panic`/`assert` backtraces, the runtime's hardware-fault handler, and a debugger's call stack
all unwind correctly across hot frames. This concerns stack *unwinding* only. Odin has no
exceptions. It does not make hot code source-debuggable.

Scope: **Windows / x64 only.** The loader is `#+build windows`. The codegen paths key off
`build_context.hot_reload`.

---

## 2. Build flags & their effects

| Flag | Effect |
| --- | --- |
| `-hot-reload` | Build a host exe that supports in-process hot reload. |
| `-hot-reload-patch` | Build the reload patch object for a running host. |
| `-hot-reload-manifest:<path>` | Override the manifest path (section 3). |
| `-hot-reload-arena-size:<int>` | Bytes reserved for new globals (default 262144). |
| `-hot-reload-tls-arena-size:<int>` | Per-thread bytes reserved for new thread-locals (default 4096). |

`-hot-reload` turns on these related settings:

- `-debug`. The loader resolves the running exe's symbols from its PDB, so a PDB must sit next to
  the exe. `-debug` also pins the base build and the reload build to the same optimization level.
  The per-procedure change-detection hashes (section 6) need this match.
- `/OPT:NOREF,NOICF` at link time (section 12).
- Separate (per-package) modules. The build forces this on for any global `-o` level (section 8),
  because the fixed builtin-`-o:2` / user-`-o:none` split needs separate modules.
- Every eligible procedure becomes hot-patchable (section 7).

The host must be an executable (`-build-mode:exe`). The loader hardcodes the running EXE module
(`GetModuleHandleW(nil)`) for symbol enumeration, near-block allocation, and patching. So a DLL
or static-lib host would be enumerated and patched against the wrong image. The reload object
itself is exempt from this host check. The `-build-mode:obj` build, and the asm/llvm intermediate
outputs, do not need to be an exe, because the loader reads the *host's* PDB, not the object's.
Multiple-module and DLL hosts are future work.

`-hot-reload-patch` is the whole "recompile" step. It turns on everything that `-hot-reload`
turns on, plus `-build-mode:obj`. When the user gives no `-out`, it defaults the output to
`<main-package-dir>/hot_objs/hot.obj`. It creates that directory. It also clears stale `*.obj`
from a previous edit-set first, so a reload only ever maps the current set (section 3 and
section 14). So the recompile command is just `odin build <pkg> -hot-reload-patch`. The user
gives no `-build-mode`, `-out`, manifest, or linker flags to line up with the host build. An
explicit `-out` turns off both the default and the clean. A later explicit `-build-mode` that
moves the mode away from `obj` is a contradiction, so the compiler rejects it.

Do **not** rebuild the executable to reload code. That restarts the process.

---

## 3. Manifest: format & lifecycle

The manifest is the compiler's persistent, build-to-build record. It lets the host build and its
reload builds line up. It pins the new-global arena offsets, the change-detection baseline, the
build-id, and the base package directory. It is a plain text file. The default path is
`<main-package-dir>/odin-hot-reload.manifest`. Both builds of the *same* package resolve to the
same default path, so the user need not pass `-hot-reload-manifest`. Pass the same explicit path
to both builds only when they build from different directories.

The build mode decides base against reload, not the presence of the file. The base build is the
executable. It sets the layout fresh, and it always rewrites the manifest. Only a reload build
(`-build-mode:obj`) reads the baseline. The key is the build mode, not the file, for a reason. The
default manifest path can then persist between sessions. A stale file does not make a base exe
build look like a reload. (`-hot-reload` requires the host to be an exe, so a non-Object build is
always the base.)

A rejected build must not persist its state. If the build has any error (for example the ABI
guard in section 6, or an exhausted arena), the compiler leaves the manifest intact. A bad
`sig`/offsets write would make the guard "sticky" and reject even a later corrected build.

Line format. The tokens are space-separated. The name is the rest of the line after the fixed
numeric fields, and it can contain spaces.

    arena_size <bytes>
    next_free <bytes>              # bump pointer into the new-global arena
    tls_arena_size <bytes>
    tls_next_free <bytes>          # bump pointer into the TLS arena
    build_id <u64>                 # section 6
    pkg_dir <path>                 # base package dir, so a running app can rebuild the patch
    orig <type_hash> <name>        # an original global / @(static): link name -> canonical type hash
    sig <sig_hash> <name>          # a hot proc: link name -> canonical proc-type (signature) hash
    fhash <content_hash> <name>    # a hot proc: link name -> content hash of the previous build
    new <off> <type_hash> <flag+1> <name>      # new global: arena offset, type hash, init-flag offset+1 (0 == none)
    tls_new <off> <type_hash> <flag+1> <name>  # new thread-local: TLS arena offset, ...

The base build records the `pkg_dir` line. A reload build preserves it exactly when it rewrites
the manifest. A running app can then rebuild the patch itself with `hot_reload.build_patch()`,
which runs `odin build <pkg_dir> -hot-reload-patch`.

---

## 4. New-global arena

A reload object can introduce globals that did not exist at the time of the exe build. These
globals cannot live in the object's own data. The loader remaps the object every reload, so their
state would be lost. There is also no room in the exe's fixed data sections. So the exe reserves a
zero-init **arena**. Reload objects place new globals into it at fixed, manifest-pinned byte
offsets. Their state then persists across every later reload.

- `__odin_hot_reload_global_arena` is a `[arena_size]u8` global, over-aligned to 16. The
  alignment keeps an aggregate, f64, or SIMD global correct at an aligned offset inside the arena.
  The base exe build defines it, zero-init and **external**, so the loader can find it by name in
  the exe's PDB. A reload object build declares it external, and the loader resolves it to the
  exe's arena. A new global compiles to a constant in-bounds GEP into this arena, pointer-cast to
  the global's type.

Three places classify globals, and they mirror each other:

- **File-scope globals** — the global loop in `lb_generate_code`.
- **Local `@(static)`** — `lb_build_static_variables`.
- **Cross-module references to a new global** — `lb_find_value_from_entity`. New globals are
  inline arena GEPs, registered only in `default_module`. A reference from another module must
  re-materialize that GEP in *this* module. The arena base is a real external that the loader
  resolves, so the GEP is valid in any module. The alternative — an undefined external declared
  by link name — the loader cannot resolve, and it fails with "unresolved symbol". The global
  loop runs before procedure codegen and pins the offsets in the manifest, so they are ready
  here.

For each global, on a reload build:

- **Original** (present in `manifest.orig`): emit it normally. The loader resolves the reference
  to the exe's live copy, so state is preserved. The type and layout must not change. A changed
  canonical type hash is a hard error, because the preserved memory cannot be reinterpreted
  safely.
- **New**: redirect it into the arena at a pinned offset. The compiler classifies the
  initializer:
  - none / zero / nil → zero-init (the arena is already zero).
  - compile-time constant → the loader copies the constant's bytes into the arena slot **once**.
    A one-byte flag in the arena gates the copy (see the init table, section 13). Only the
    introducing build emits the constant blob and the descriptor.
  - anything at run time (a new `@(init)` included) → not supported, hard error.
  - an `any`-typed new global → not supported, hard error.

On the base build the compiler records every global into `manifest.orig` for later reloads.

---

## 5. TLS arena & accessors

Thread-locals cannot use the plain-global arena. Their storage is per-thread. The code reaches it
through `_tls_index` plus a SECREL offset into the thread's TLS block, so a thread-local has no
plain address.

- **New thread-locals** from a reload go into `__odin_hot_reload_tls_arena`. This is a
  `@thread_local [tls_arena_size]u8` array in the exe. Every thread, both existing and future,
  gets its own zeroed copy at a fixed offset in its TLS block. Access is a GEP into this
  thread_local symbol, so the loader's SECREL handler resolves it to the exe's TLS block. Both the
  base build and the reload build define it, zero-init. TLS references resolve by SECREL name
  rewrite, not by symbol address, so the reload object's own (unused) copy is fine. Odin
  thread-locals cannot have initializers (a checker rule), so these are always zero-init.
- **Original thread-locals** stay preserved through a per-variable accessor thunk. The compiler
  emits one thunk for each:

      __odin_hrtls$<link-name>() -> rawptr { return &var }

  A use of the thread_local inside the thunk lowers to the exe's TLS access sequence, so the thunk
  returns the per-thread address. The loader derives this name from a SECREL relocation's target
  variable. It finds the accessor in the exe's PDB and calls it to learn the variable's offset in
  the exe's TLS block. No baked map is needed, because the name is a pure function of the
  variable's (build-stable) link name. The compiler emits the accessor into the module that
  *defines* the thread-local, because LLVM forbids a cross-module reference to a global. The
  symbol is public either way, so the loader resolves it by name whatever module holds it.

A new thread-local static that does not fit the exe's frozen TLS arena is a hard error. The user
must rebuild the exe with a larger `-hot-reload-tls-arena-size`. A changed type or layout on a
preserved or arena-backed thread-local is a hard error, the same as section 4.

---

## 6. Change detection & minimal-object emission

The loader patches only the procedures whose code actually changed. A reload re-emits only the
package objects that contain a change. Both decisions come from a per-procedure **content hash**.

**Content hash** (`lb_hot_reload_proc_content_hash`) is a stable, debug-normalized hash of a
procedure's emitted LLVM IR text. The compiler hashes `LLVMPrintValueToString(p->value)` with the
debug info removed:

- Drop debug-record lines in full (`llvm.dbg.*` intrinsics and `#dbg_` records).
- Truncate each remaining line at its first ` !` or ` #`. In LLVM IR text `!` starts trailing
  metadata operands (`, !dbg !12`). `#` starts attribute-group references (`... #0 ...`). Both are
  module-globally numbered, and they renumber between builds when unrelated code is added or
  removed. Instruction operands always come first, so the truncation keeps the relevant prefix.
- Trim trailing spaces and commas at the truncation point. A `-debug` instruction
  (`br label %e, !dbg !N` → `br label %e,`) then hashes the same as its non-debug form
  (`br label %e`). The base exe is `-debug`, but the reload object usually is not, so the two forms
  must reconcile.
- Collapse any `$<module_name>$<hex>` run. Compiler-generated constant globals (string backing
  stores and similar) have names of the form `<prefix>$<module_name>$<hex-index>`. Both the module
  name (from `-out`) and the atomic index change between builds. The compiler strips this
  build-specific suffix to canonicalize such references. The referenced length stays, so a length
  change is still detected.

The compiler frees the scratch buffer for each procedure (`TEMPORARY_ALLOCATOR_GUARD`). Without
this, the whole program's normalized IR text accumulates in the temporary allocator, because this
runs for every hot proc. Compile memory then grows with program size.

**Soundness for change detection.** A real instruction or operand change alters the kept text, so
the hash differs. Debug-only differences do not change machine code. Metadata-ID renumbering from
an unrelated edit hashes the same. So an unchanged procedure keeps the same hash across builds.
This is the shakiest part of the design (section 14).

**`__odin_hot_reload_func_hashes`** is a table of `{u64 name_hash, u64 content_hash}` over every
hot-reloadable procedure. This is the same set that gets the patchable prologue. The compiler
gathers it from *every* module, not `default_module` alone. The table carries no addresses and
roots nothing, so DCE stays on. The loader reads the exe's copy (through the PDB) as the baseline,
and the reload object's copy (through its COFF symbol) each reload. It patches only the procedures
whose content hash changed. `name_hash` is FNV-1a-64 of the link name, to match the loader's
`hr_fnv64`.

**Minimal object emission.** While the compiler emits the func-hash table, it marks a proc's
module CHANGED if the content hash differs from the manifest baseline, or is new, or this is a
base build. At object-generation time the build does not emit an unchanged user-package module at
all. Its code is unchanged and still in the exe, so a reload skips the object. All file-scope
globals live in `default_module`, which is always emitted. So a user-package module changes only
when one of its procs changes, and proc hashing is enough. `lb_hot_reload_skip_object` skips (1) a
builtin-collection module (resolved from the exe) and (2) an unchanged user module. It never skips
`default_module` (metadata and RTTI, `pkg==nullptr`), and it never skips on a base exe build.

**Build-id guard (F6).** `__odin_hot_reload_build_id : u64` is a fingerprint of the exe's
reload-relevant layout. It folds the arena sizes plus the canonical hashes of the original globals
and the hot procs. The fold uses commutative addition, so the value does not depend on map or
thread iteration order. The base build bakes this value into the exe. Every reload object reads
the same value back from the manifest. The loader refuses a reload whose id differs from the
running exe's. A stale object built against a since-rebuilt exe (arena relaid) is then rejected,
instead of a silent memory corruption at now-wrong arena offsets. The compiler emits this after
the func hashes, so the manifest's `sig` map is complete.

**Signature ABI guard (F8).** The frozen host's call sites marshal the *original* signature into
the patched-in body. So a hot proc's parameter and return types must not change across a reload.
The base build records each hot proc's canonical signature hash in `manifest.sig`. On a reload
build a proc whose signature changed is a hard error. The user must revert the signature or
restart the program. This mirrors the global type-hash guard of section 4.

---

## 7. Patchable procedures

Under `-hot-reload` the compiler makes **every eligible procedure hot-patchable, with no
`@(hot_reload)` tag**. `lb_proc_is_hot_reloadable` defines eligibility. The compiler uses the same
predicate both to stamp the patchable attributes and to emit the change-detection hashes, so the
two sets stay identical. A procedure is eligible when it:

- has a body and is not foreign;
- is not the program entry point;
- is not opted out with `@(no_hot_reload)`;
- is not force-inlined (`#force_inline` and noinline are mutually exclusive, and a force-inlined
  proc has no out-of-line body to patch);
- has a normal prologue (this excludes a `naked` or inline-asm calling convention);
- lives in one of the **user's own** packages, not the bundled core/base/vendor collections.

For each eligible proc the compiler adds `noinline` (so the machine code stays a discrete,
replaceable function). It also adds `patchable-function` = `prologue-short-redirect` and
`patchable-function-prefix` = `16`. The 16-byte NOP pad sits directly in front of the entry. The
compiler emits the pad, so it is linker-independent and works with lld-link, link.exe, and radlink
alike. The loader parks the full 14-byte absolute jump in this pad. It then flips the 2-byte entry
to a short jump into the pad with one atomic store, for a torn-free publish. 16 keeps the entry
16-byte aligned.

**Why the compiler excludes core/base/vendor** (`lb_path_is_stdlib`). A build that makes *every*
procedure noinline, patchable, full-debug, and content-hashed defeats inlining of the whole
standard library. A program that uses `fmt` pulls in thousands of core procedures. Each stays a
standalone function with full CodeView debug info, and the compile spikes into multiple GB. The
user rarely edits those procedures during a hot-reload session. The user edits their own code. The
exclusion anchors on the `builtin` flag that the compiler sets when it registers its shipped
collections (base, core, vendor). It does not anchor on the collection *name*, and it does not
anchor on all of `ODIN_ROOT`:

- A user `-collection` (a collection named `core` included) has `builtin=false`. So a game
  engine's `src/engine/core` stays hot-reloadable.
- `ODIN_ROOT/examples/...` (the hot-reload tests) is under no collection. So it stays
  hot-reloadable too.

Path matching (`lb_path_under_dir`) is separator- and case-insensitive, with a path boundary after
the directory. So `.../core` does not match a sibling `.../core_extra`.

`@(no_hot_reload)` opts one procedure out. It stays inlinable, optimized, and never patched. The
compiler forces no export, because the loader resolves a running procedure from the exe's PDB by
its link name.

---

## 8. Per-module optimization split

Under `-hot-reload` the optimization split is **fixed for any global `-o` flag**:

- The standard-library collections (base, core, vendor) build at `-o:2` (optimized and inlined),
  because a reload never patches them.
- Everything the user can edit builds at `-o:none` (noinline, patchable, full-debug). This covers
  the user packages, the default/metadata module, and the polymorphic/equal modules.

So `-o:speed` and `-o:size` still get an optimized standard library, but they keep user code
reloadable. User code must stay `-o:none` for any `-o` value for two reasons:

1. The base exe and every reload object must compile user code **identically**. A mismatch would
   diverge the change-detection IR hashes (section 6).
2. Optimized user code would reference core procs that the base inlined away.

A user proc's IR does not depend on a builtin module's opt level, because there is no cross-module
inlining without LTO. So an optimized standard library does not perturb the per-function hashes.
The split needs separate modules. So `-hot-reload` forces `use_separate_modules` on
(`init_build_context`), even at `-o:speed` or `-o:size` where it is not the default. The per-module
level lives on `lbModule::optimization_level`. Both the pass pipeline (`llvm_backend_passes.cpp`
switches on it) and target-machine creation (`lb_generate_code`) read it.

---

## 9. RTTI & type_info

A reloaded procedure can reflect (through `fmt`, `any`, or `type_info_of`) on *any* type in the
program, not only the subset that this build uses for RTTI. Three changes make reflection in hot
code resolve against the exe's tables:

- **Full type-info expansion** (`generate_minimum_dependency_set`, gated on
  `hot_reload && !no_rtti`): emit `type_info` for every declared entity's type, for the types
  those reference (recursively), and for each decl's collected `type_info_deps`. The exe's
  `type_table` is then complete.
- **`type_info` reroute** (`lb_type_info`): resolve `type_info_of(T)` through the running exe's
  `type_table` by (build-stable) `typeid`, with a `__type_info_of` runtime call, not by a
  build-local index into this object's array. So reflection in hot code lands on the exe's
  `Type_Info` and matches an `any` value built from the same stable `typeid`.
- **Published slice** (`lb_setup_type_info_data`): the loader needs both the exe's (old) and the
  reload object's (new) type-info tables to diff struct layouts across a reload. `runtime.type_table`
  is an internal symbol with an awkward PDB name. So the compiler publishes a dedicated
  `[]^Type_Info` slice under the fixed external name `__odin_hot_reload_type_infos`. It shares the
  same backing array, and it is findable by name in both the exe's PDB and the reload object's
  symbols. The backing array is a private anonymous global, referenced section-relative. So the
  object's copy stays object-local (the new layouts), and the object does not reuse the exe's copy.

**Global debug link-name fix** (`lb_generate_code`, debug-info emission). The loader resolves a
reloaded object's reference to a pre-existing global by the *link* name in the exe's PDB. LLVM's
CodeView emitter names a global's PDB symbol after the debug *display* name. A global's display
name is only its source identifier (`hits`, not `pkg::hits`). So a reload's `pkg::hits` reference
would miss and silently get a fresh copy, and state would not persist. Functions already store the
link name in the PDB, so they resolve. Under `-hot-reload` the compiler passes the link name as
both the debug name and the linkage name, so globals resolve too. A hot-reload build is a dev
build, so the debugger then shows `pkg::hits`.

---

## 10. Refresh globals (`@(rodata)` / `#load`)

Some globals hold immutable embedded data. The loader must provide this data *fresh* on each
reload, not preserve it. A global is a refresh global when it is:

- an `@(rodata)` variable, or
- a variable whose initializer is directly a `#load(...)` or `#load_directory(...)` directive (and
  `#hash` or `#load_hash` for a local static).

The bytes are read-only either way. A write through them faults. So there is no run-time state to
protect, and the loader "repoints" the exe's copy at the reload's data. These stay normal globals
(never arena-backed). The compiler records them in the **refresh table**
`__odin_hot_reload_refresh_syms` as `{size, link name}`. The loader looks up each name in both the
exe (PDB) and the reload object. It then overwrites the exe's copy with the object's fresh copy, so
an edit to the data appears after a reload. `size` is `type_size_of` the variable. For a
slice/string/`#load` global it is the 16-byte header, repointed at the object's fresh blob, so a
size change is free. For a value-type `@(rodata)` it is the full byte size, overwritten in place.

An *original* refresh global flows through the type-guard. Its references alias the exe's single
canonical copy, which the loader overwrites. A *new* refresh global falls through to object-local
emission (resolved fresh each reload), not to the persist-arena. So its data stays genuinely
read-only.

`#load_directory` needs a special case (`lb_const_load_directory_slice`). It normally yields a
run-time value. So a package-scope global would be built by the startup runtime, and the reload
object's static storage would be zero, which the refresh repoint cannot use. Under `-hot-reload`
the compiler bakes the const `[]Load_Directory_File` slice as the initializer, like `#load`. The
object then carries a real header that the loader repoints at the fresh backing data. For a local
`@(static)`, the compiler does not bake `#load_directory`, so it is excluded from the local-static
refresh set.

---

## 11. Patch hooks

`@(pre_patch_hook)` and `@(post_patch_hook)` procedures are Live++-style migration hooks. The
loader calls them around a patch and passes the changed-type set. It calls the pre set (from the
running exe, old code) before the patch, and the post set (from the reloaded object, new code)
after. The expected shape is `proc(changed: []hot_reload.Type_Change)`: one slice parameter, no
results. The checker enforces this loosely, because the loader casts the resolved address to this
type, and an odd signature would mis-call. Both attributes need a `-hot-reload` build, and both
force `is_export` so the symbol has a stable, unmangled name.

The compiler emits two tables, `__odin_hot_reload_pre_patch_hooks` and
`__odin_hot_reload_post_patch_hooks`. Each lists the **exported symbol name** of every matching
procedure, not a pointer. The loader resolves each name itself, the pre set against the running
exe, and the post set against the reloaded object. Names, not pointers, let a post hook reach its
fresh copy without being a patchable/hot procedure. `find_symbol_address` on the object returns the
object-local definition directly.

---

## 12. Linker settings

Under `-hot-reload` the linker gets:

- **`/OPT:NOICF`** stops the linker from folding identical functions. Folding would break
  per-procedure patching, because two procs that share one body could not be patched
  independently.
- **`/OPT:NOREF`** overrides the linker templates' hardcoded `/opt:ref`. It keeps functions that
  the base source never referenced, chiefly members of already-linked static libraries (for
  example `vendor:raylib`), in the image. A reload can then call a foreign-library procedure that
  the base never used, and the loader can resolve it through the exe's PDB. Odin procs and globals
  that the base does not use are still dead-code-eliminated at the LLVM level. This setting keeps
  only linker-visible library members. Add `/WHOLEARCHIVE:<lib>` to also pull a member that the
  base never touched at all.

The compiler emits the pre-function pad that the atomic patcher needs (the patchable-function-prefix,
section 7). So the pad is linker-independent and needs no `/FUNCTIONPADMIN`.

---

## 13. Emitted-symbol ABI

This is the contract between the compiler and the loader. The compiler emits each symbol below
under `-hot-reload`, and the loader reads it by name. The loader finds some symbols in the exe's
PDB. Those are external plus `llvm.used`, so they survive DCE and land in the PDB. The loader reads
other symbols only from the mapped object. Those are internal plus compiler-used.

| Symbol | Shape | Read by / purpose |
| --- | --- | --- |
| `__odin_hot_reload_global_arena` | `[arena_size]u8`, align 16 | Section 4. Base: defined external. Reload obj: external decl. New globals GEP into it. |
| `__odin_hot_reload_tls_arena` | `@thread_local [tls_arena_size]u8` | Section 5. New thread-locals GEP into it. Both builds define it. |
| `__odin_hrtls$<link-name>` | `proc() -> rawptr` | Section 5. Accessor thunk that returns `&var`. The loader calls it to learn a preserved thread-local's TLS offset. |
| `__odin_hot_reload_func_hashes` | `{ i64 count; {u64 name_hash, u64 content_hash}[] }` | Section 6. Change-detection baseline/delta. |
| `__odin_hot_reload_build_id` | `u64` | Section 6. Layout fingerprint. The loader refuses a mismatched object (F6). |
| `__odin_hot_reload_new_global_inits` | `{ i64 count; {i64 arena_off, i64 flag_off, i64 size, rawptr blob}[] }` | Section 4. The loader copies each blob into the arena once, gated by its flag byte. Internal. |
| `__odin_hot_reload_refresh_syms` | self-contained blob: `[i64 count]` then per entry `[i64 size][i64 name_len][name bytes]` | Section 10. `@(rodata)`/`#load` repoint list. Internal, no pointer relocations. |
| `__odin_hot_reload_type_infos` | `[]^Type_Info` | Section 9. Published type table for struct-layout diffing. |
| `__odin_hot_reload_pre_patch_hooks` | `{ i64 count; {rawptr name, i64 name_len}[] }` | Section 11. Pre-patch hook names (resolved against the exe). |
| `__odin_hot_reload_post_patch_hooks` | same as pre | Section 11. Post-patch hook names (resolved against the object). |

The manifest (section 3) is not a symbol. It is the build-to-build half of the same contract. The
`lb_type_info` reroute calls `__type_info_of`, an existing runtime helper (section 9).

---

## 14. Known risks & follow-ups

1. **IR-text content hashing** (section 6) is the most fragile part of the design. Correctness
   rests on the `LLVMPrintValueToString` output plus ad-hoc string normalization, and it is slow,
   because it runs for every hot proc. Two alternatives to evaluate: a hash of the emitted
   machine-code bytes, or a structural hash over the IR instead of its text.
2. **Manifest build statefulness** (section 3). A text sidecar that the compiler both reads and
   writes couples independent builds through the filesystem. This is surprising, and it is a source
   of "stale file" footguns. The build-mode key mitigates it. It is worth an attempt to derive the
   offsets and the baseline from the exe/PDB directly, and to remove the sidecar.
3. **`init_build_paths` filesystem side effects** (section 2). The `-hot-reload-patch` out-dir
   default creates `hot_objs/` and deletes stale `*.obj` during *path init*. A path-setup function
   that mutates the filesystem is a smell. Consider a move of the directory lifecycle into the
   loader's `build_patch()` tooling, or a required `-out`.
4. **Windows / x64 only.** The loader is `#+build windows`. The codegen paths assume the PE/COFF,
   PDB, DbgHelp, and x64-unwind toolchain. A cross-platform story (ELF/DWARF, Mach-O) is future
   work. Until then the `-hot-reload` flag should be scoped to Windows/x64 at parse time.
