# Livepatch vs. Live++ — parity analysis

Goal: **parity with [Live++](https://liveplusplus.tech/) (Windows)** — nothing
more. This document is built from the actual Live++ documentation, FAQ, and
release notes (fetched 2026-09), not from assumptions. Anything Live++ itself does
**not** do is explicitly out of scope (see the last section), and anything the
Odin build already does that Live++ can't is called out so it is **not** mistaken
for a gap.

Windows / x64. See `STATUS.md` for the detailed TODO tiers and
`core/livepatch/HOW_IT_WORKS.md` for the mechanism.

Sources:
[Live++ docs](https://liveplusplus.tech/docs/documentation.html),
[FAQ](https://liveplusplus.tech/faq.html),
[Schöner write-up](https://blog.s-schoener.com/2024-12-16-liveplusplus-debug/).

---

## Feature map: where the Odin build stands against Live++

| Capability | Live++ | Odin livepatch | Verdict |
|---|---|---|---|
| Patch changed functions in a running process | ✓ | ✓ (atomic 2-byte publish into compiler pad) | **parity** |
| Thread-safe patching (freeze threads, safe publish) | ✓ | ✓ (suspend + IP-check + atomic store) | **parity** |
| Functions on the stack keep old code until they return | ✓ (documented limitation) | ✓ (same design) | **parity** |
| Preserve global/static state across reload | ✓ | ✓ | **parity** |
| Add new functions / globals / statics | ✓ | ✓ (arena + manifest) | **parity** |
| Add new structs/types; use them in patched code | ✓ | ✓ | **parity** |
| Structural (layout) changes via pre/post-patch hooks | ✓ (`LPP_HOTRELOAD_PRE/POSTPATCH_HOOK`) | ✓ (`@(pre/post_patch_hook)` + `migrate_fields`) | **parity** (mechanism) |
| Sync point so patches land at a safe frame boundary | ✓ (synchronized agent, `WantsReload()`) | ✓ (app calls `apply()` between frames) | **parity** |
| Reuse the original compiler/flags to build the patch | ✓ (Broker) | ✓ (`apply_patch()` → `odin build -livepatch-patch`) | **parity** |
| Hold on failed build, surface compile errors | ✓ (compile/link error hooks) | ✓ (`apply_patch` holds on non-zero exit) | **parity** |
| Optimized builds (no LTO/LTCG/WPO) | ✓ (LTO unsupported) | ✓ (stdlib `-o:2`, user `-o:none`, no cross-module LTO) | **parity** |
| Unwind / SEH through patched code | ✓ (VEH/SEH) | ✓ (`RtlAddFunctionTable`) | **parity** |
| **Thread-local storage across reload** | ✗ (documented limitation) | ✓ (existing + new TLS) | **Odin ahead** |
| **Reflection / RTTI refresh from patched code** | n/a (C++) | ✓ (`type_table` swap; edited + new types) | **Odin ahead** |
| **Source-level debugging of patched code** | ✓ (breakpoints + stepping, minor caveats) | ✗ | **GAP** |
| **DLL / multi-module hosts** (.exe/.dll/.lib) | ✓ (auto-handles loaded DLLs) | ✗ (exe host only) | **GAP** |
| **Built-in file watcher / continuous compilation** | ✓ (opt-in auto-compile on save) | ✗ (manual trigger) | **GAP** |
| **Incremental compile speed** (obj/pdb cache) | ✓ (Broker caches, per-TU) | ~ (front-end still whole-program) | **partial gap** |
| **Multi-process patching** (many instances at once) | ✓ (out of the box) | ✗ (single process) | **GAP** |
| **Hot Restart** (restart process, keep caches, skip link) | ✓ | ✗ | **GAP** |
| **Change a function's signature** | ✓ | ✓ (callee-entry redirect; direct callers re-patch in the same reload) | **parity** |
| Granular compile/link lifecycle hooks | ✓ (`LPP_PRECOMPILE`/`COMPILE_START`/`LINK_*`…) | ~ (pre/post-patch + error-hold only) | **minor gap** |

---

## Parity gaps, ranked by value

Only things **Live++ does and the Odin build does not**. This is the whole parity
backlog.

### 1. Source-level debugging of hot code — *the biggest gap*
Live++ works with the debugger: you can set breakpoints in patched code and step
through it (with minor caveats — breakpoints may shift a line, globals in the
watch window need a Natvis refresh). The Odin build has **none** of this: the hot
object is anonymous `VirtualAlloc` memory with no registered module/PDB, so hot
frames show as raw addresses and no breakpoint binds. Unwinding *through* hot code
already works (`RtlAddFunctionTable`); this is the missing symbol/line half.
- **Path:** emit a PDB for the reload object and register the mapped range via
  DbgHelp `SymLoadModuleEx`, reusing the "block is the image base" trick the unwind
  registration already relies on (see STATUS.md Tier 1).
- **Bonus:** this also delivers Live++'s "drag the instruction pointer back and
  re-run the function with my fix" workflow — that is just the debugger's manual
  *set-next-statement*, which needs source-level debugging and nothing else.

### 2. DLL / multi-module host support
Live++ patches `.exe`, `.dll`, and `.lib` projects and auto-handles dynamically
loaded modules. The Odin build **hardcodes the exe** — a `-build-mode:dll`/
`:staticlib` host is rejected, and the loader resolves everything against
`GetModuleHandle(nil)` and the exe's PDB. Any app that ships gameplay code as a
DLL (a very common pattern, and arguably *the* reason to want hot reload) cannot
be livepatched today.
- **Work:** enumerate/patch against the right module handle + PDB per loaded
  module; extend `alloc_near_exe`, the symbol enumeration, and build-identity to a
  multi-module world. Architecturally significant.

### 3. Built-in file watcher / continuous compilation
Live++ can watch the source tree and auto-compile on save (opt-in; its default is
a hotkey, which the Odin build already matches via `apply_patch()`). Adding a
`ReadDirectoryChangesW` watcher on the package dir that debounces and calls
`apply_patch()` closes this. **Lowest effort of all the gaps** — days.

### 4. Incremental compile speed
Live++'s Broker caches `.obj`/`.pdb` and recompiles per translation unit, so
reloads are proportional to the edit. The Odin build is incremental on *object
emission and loading* but the front-end (parse + type-check) and IR-gen still run
whole-program each reload. For a large project this dominates reload latency.
Largest *compiler* effort; real front-end incrementality (reusing checker/IR
state across builds) is the ceiling on reload speed.

### 5. Multi-process patching
Live++ patches several running instances at once with no special setup (great for
client/server or editor/game). The Odin build is single-process. Needs a
broker-like driver that applies the same object set to multiple PIDs.

### 6. Hot Restart
Live++ can restart the process while keeping loaded data and caches resident, to
skip link time on a full restart. The Odin build has no equivalent. Distinct
feature; medium value, mostly a workflow accelerator.

### 7. Granular compile/link lifecycle hooks
Live++ exposes `LPP_PRECOMPILE_HOOK`, `LPP_COMPILE_START/ERROR_HOOK`,
`LPP_LINK_START/ERROR_HOOK`, `LPP_GLOBAL_HOTRELOAD_START/END_HOOK`. The Odin build
has `@(pre/post_patch_hook)` and holds on a failed build, but no compile/link-phase
callbacks. Minor; add if an app wants to gate the build phases.

---

## Already at parity or ahead — do NOT build these for parity

- **On-stack functions** — parity (both keep old code until return; verified).
- **Thread-local storage** — Odin is **ahead**; Live++ lists TLS as unsupported.
- **Reflection/RTTI refresh** — Odin is **ahead**; no C++ analogue.
- **Data-migration hooks + sync point** — parity of *mechanism*. In *both* systems
  the actual migration is the user's job in the hook. Odin's reflection
  `migrate_fields` is a bonus. Its sharp edges (enum-with-no-constant nil-deref,
  `#no_nil` tag-0) are just **bugs to fix**, not parity gaps — cheap, do them.
- **New globals/procs/types** — parity, including storage policy: a new global is an
  undefined external the loader resolves to its own persistent storage (like Live++'s
  real linked-image globals), not a slot in a fixed exe arena — so there is no size cap
  and no "arena exhausted" build error (`-livepatch-arena-size` is deprecated/ignored).
  Caveat: Odin applies a new global's *compile-time constant* initializer once, not a
  runtime initializer/`@(init)`; Live++'s new-global init is underdocumented and Clang
  has its own dynamic-init limitation, so this is roughly comparable, not a clear gap.
- **Optimized builds** — parity (both forgo LTO/LTCG).
- **Unwind / SEH through hot code** — parity.
- **Changing a function's signature** — parity. Both redirect at the callee's
  entry and never rewrite call sites, so a signature change is an ordinary code
  change: the changed callee re-patches, and every *direct* caller's marshalling
  changes with it, so the caller re-patches in the same reload and reaches the new
  body through the new ABI. The compiler rejects any call that doesn't match the
  new signature, so no old-ABI caller of a new-ABI body can be produced. Same
  residual caveat as Live++: a stored `proc`-value holding the old signature. The
  build-time rejection (F8) has been removed.

---

## Explicitly NOT parity work (out of scope for "match Live++")

These are things I earlier floated that are **not** needed to match Live++,
because Live++ doesn't do them either:

- **Automatic instruction-pointer relocation / on-stack replacement.** Live++
  does not do this (functions on the stack are a documented Live++ limitation; its
  only IP relocation is *manual* debugger set-next-statement). See
  `ip_relocation_scope.md` — it would *exceed* Live++, not reach it.
- **Linux (ELF) / macOS (Mach-O).** Live++ Windows is Windows-only; matching it
  needs no other OS. (Live++ has separate console SKUs; not relevant to a
  Windows/x64 target.)
- **ARM/ARM64 or x86.** Live++ is x86/x64 only; the Odin build's x64-only is fine
  for a 64-bit target.
- **Deep migration robustness (instance enumeration, following pointer graphs).**
  In Live++ this is equally the user's responsibility inside the hooks — not a
  Live++ feature to match.

---

## Recommended parity roadmap

In order:

1. **File watcher** (gap #3) — days; closes the last ergonomic difference.
2. **Source-level debugging via `SymLoadModuleEx`** (gap #1) — the defining
   missing capability; also hands you the manual set-next-statement "re-run with
   fix" workflow for free. Already scoped, image-base trick in place.
3. **The two migration crash-guards** (bugs, not gaps) — trivial, remove footguns.
4. **DLL / multi-module host** (gap #2) — the one architecturally large item that
   real "gameplay code in a DLL" users will hit.

Then, as reach/polish: incremental front-end (gap #4), multi-process (gap #5),
hot restart (gap #6), lifecycle hooks (gap #7).
