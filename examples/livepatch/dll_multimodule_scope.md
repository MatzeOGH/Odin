# Scope: DLL / multi-module host support

What it would take to livepatch code that lives in a **DLL** (or across several
user modules), not just the main executable — Live++ parity gap #2.

Windows / x64. Grounds against the current loader (`core/livepatch/*.odin`) and
the `-build-mode:exe` compiler guard.

---

## The situation today

The whole design assumes **one module: the exe**. That assumption is funneled
through a small number of spots (all in `symbols.odin` unless noted), which is the
good news — the surface is concentrated:

| Site | Exe assumption |
|---|---|
| `alloc_near_exe` (`symbols.odin:66`) | reserves memory near `GetModuleHandleW(nil)` |
| `alloc_near` (`:71`) | already **parameterized by base** — just called with the exe base |
| `lp_dbghelp_ensure` (`:184`) | enumerates only `base = GetModuleHandleW(nil)` — one PDB |
| `_lp_syms` (`:17`) | a single flat name→addr map, no module identity |
| `lp_resolve_exported` (`:138`) | checks the exe first, then ntdll/ucrtbase/kernel32 |
| `lp_new_proc_trampoline` (`:54`) | anchors new-proc trampolines near the exe |
| `lp_tls_block_base` (`:90`) | reads the **exe's** `_tls_index` (`_lp_tls_index`, `:10`) |
| compiler | `-livepatch` requires `-build-mode:exe` (adversarial-review F5) |

Encouraging detail: `lp_dbghelp_ensure` calls `SymInitialize(proc, nil,
fInvadeProcess=true)` — DbgHelp **already loads symbols for every module in the
process**. We just never *enumerate* any base but the exe's. Adding more modules is
more `SymEnumSymbolsW` calls, not a new symbol backend.

---

## How Live++ handles it (from the docs — verified)

Checked against the Live++ documentation. The architecture maps almost 1:1 onto
the scope below, and two of my "risk" items turn out to be things **Live++ does
not solve either**.

- **One agent, explicit per-module opt-in.** A single agent manages the whole
  process, but the app **enables each module by path**:
  `Agent::EnableModule(path, options, …)` / `EnableModules(...)`, with
  `LPP_MODULES_OPTION_ALL_IMPORT_MODULES` to pull in a module *and its imports*.
  `LppGetCurrentModulePath()` registers the caller. So Live++ tracks a **set of
  enabled modules**, not "the exe".
- **Each enabled module needs its own PDB.** Required-files list: "PDB files for
  **all** Live++-enabled modules." Exactly the per-module enumeration below.
- **Cross-module resolution happens at link time.** Live++'s Broker links the
  patch against the running modules' existing symbols ("any functions which are
  not part of the original executable will also be linked correctly"). The Odin
  loader does the equivalent at **load time** via per-module PDB maps — same net
  effect, different stage, same PDB requirement.
- **Dynamically-loaded DLLs are a separate opt-in.**
  `EnableAutomaticHandlingOfDynamicallyLoadedModules(...)` "enabl[es] them on
  load, disabl[es] them on unload." Confirms it is a distinct, deferrable feature.
- **TLS is a Live++ *limitation*, module-scoped:** "Live++ cannot patch functions
  that directly access or modify thread-local storage variables **defined in the
  same module**." So per-module TLS is **not on the parity path** — see item 6.
- **No reflection/RTTI at all** (C++). Cross-module reflection is a *beyond-Live++*
  concern, not parity — see item 7.

**Design implication:** mirror `EnableModule` — let the app/build declare *which*
modules are livepatch-enabled rather than auto-enabling everything. This lines up
with the standing STATUS.md TODO ("enable/disable livepatch selectively for
`LibraryCollections`") — same idea, one mechanism.

## The three sub-cases (in value order)

- **A — user code in one DLL, exe is the host.** Game exe + `gameplay.dll`; you
  edit and reload the DLL's functions. This is the classic "hot-reload gameplay
  code" case and the reason the gap matters. **Most of the value is here.**
- **B — the host itself is a DLL** (a plugin loaded into a third-party app). Same
  machinery; the loader just needs the DLL's own module handle instead of the
  exe's.
- **C — N user modules, any patchable, cross-module TLS/reflection correct.** Full
  generality.

---

## What has to change

### 1. Per-module symbol enumeration + module-scoped resolution — *core, unavoidable*
`_lp_syms` becomes per-module (a map per module, or one map keyed by
`(module, name)`). Enumerate each relevant module's PDB with its own base
(`SymEnumSymbolsW(proc, module_base, …)`). Resolution for a reference in module
M's reload object must prefer **M's own module**, then fall back to the exe /
other user modules / system DLLs — because two DLLs can legitimately define the
same name (`main`, a static, a package global). The current flat first-seen-wins
map would silently bind to the wrong module. **Medium**, localized to the resolver.

### 2. Anchor allocation + trampolines to the target module — *easy*
`alloc_near_exe` and `lp_new_proc_trampoline` take a **module base** parameter and
pass the target module's base, so REL32 from patched code in `gameplay.dll`
reaches `gameplay.dll`'s own globals/functions within ±2 GB. `alloc_near` is
already base-parameterized, so this is plumbing. **Easy.**

### 3. Route each reload object to its target module — *easy/medium*
Bake the owning module's identity into the reload object (or its manifest) so the
loader knows which running module's entry addresses to patch and which PDB to
resolve `original` against. The compiler already emits one object per
package/module; add the module name. `apply_dir`/`apply_many` group objects by
module. **Easy/medium.**

### 4. Per-module manifest + build-id — *medium*
The arena offsets, `type_hash` baselines, and `__odin_livepatch_build_id` are
currently per-exe. Each patchable module needs its own manifest and build-id
(the staleness check compares an object against *its* module). **Medium**, mostly
threading a module key through the manifest read/write.

### 5. Compiler: allow a DLL to be a livepatch host/target — *medium*
Relax the `-build-mode:exe` guard to also accept `:dll`/`:shared`, and emit the
livepatch support (global + TLS arenas, `__odin_lptls$*` accessors, func-hash
table, build-id, type-info tables) **into that module**. Separate-module emission
already routes the TLS accessors into the defining module
(`lbLivePatchStaticSym.module`), so the pattern exists. **Medium.**

### 6. Per-module TLS — *OFF the parity path (Live++ limitation too)*
Each module has its own `_tls_index`, and thread-locals live in that module's TLS
block; `lp_tls_block_base` reads the exe's. Making a DLL's thread-locals work from
hot code is fiddly — **but Live++ does not do it either.** Its docs state it
"cannot patch functions that directly access or modify thread-local storage
variables defined in the same module." So for **parity, this is a documented
limitation, not work** — and the Odin build still keeps its existing edge (exe TLS
works, which Live++ lacks). Solve it later only to *exceed* Live++.

### 7. Reflection / `type_table` across modules — *beyond parity (Live++ has none)*
The `type_table` swap targets `runtime.type_table`. There is a real open question
— does an Odin DLL get its own runtime/`type_table` or share the exe's? — but it
is **not a parity concern**: Live++ has no reflection at all. For parity, keep
reflection working for exe-defined types (already ahead of Live++) and document
DLL-defined-type reflection as a known boundary. Spike it only if a project needs
DLL-defined types to reflect.

### 8. Dynamically-loaded DLLs — *deferrable*
Live++'s `EnableAutomaticHandlingOfDynamicallyLoadedModules` handles a DLL
`LoadLibrary`'d *after* startup: enumerate it on demand and re-run resolution.
Straightforward once 1–5 exist, but not needed for a statically-linked
gameplay DLL. **Defer.**

---

## Complexity verdict

**Medium — bounded, not deep.** The mechanism (map object near its module,
relocate, atomically patch the entry) is unchanged; what changes is *anchoring* —
which base to allocate near, which PDB to resolve against, which manifest/build-id
applies. That is concentrated in `symbols.odin` plus manifest plumbing and one
compiler guard, not spread through the patcher/threads/unwind code (those are
already module-agnostic — they work on address ranges).

Crucially, the two items I first flagged as risky are **off the parity path**,
because checking the Live++ docs shows Live++ doesn't do them either: per-module
TLS is an explicit Live++ limitation, and cross-module reflection has no C++
analogue. So parity is just: parameterize the exe assumption (items 1–5), and
document the same two boundaries Live++ documents. The scope **shrank** after
reading the docs.

### Effort estimate
- **Case A / parity (one gameplay DLL, exe host; DLL-defined TLS + DLL-defined-type
  reflection documented as limitations — exactly as Live++ does):** ~**2–3 weeks**.
  This *is* Live++ parity for multi-module.
- **Beyond parity (correct cross-module TLS and/or DLL-type reflection — neither
  of which Live++ offers):** additional, only if a concrete project needs it;
  size after the spike below.

### Suggested first step
A **half-day spike**: build a trivial `exe + gameplay.dll`, `SymEnumSymbolsW` the
DLL's base, and confirm its Odin symbols enumerate. (Whether the DLL has its own
`type_table`/`_tls_index` matters only for the *beyond-parity* work, so it need not
block the parity build.) Also settle the **module-enable surface** (mirror Live++'s
`EnableModule` — a build flag / API listing the livepatch-enabled modules).
