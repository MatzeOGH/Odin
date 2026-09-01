# Live patching — `core:livepatch`

A technical breakdown of how the `core:livepatch` package hot-reloads code into a
running Windows process. This document covers the **runtime package** (the
`core/livepatch/*.odin` files). The compiler side (`-livepatch`,
`-livepatch-patch`, the emitted metadata symbols and patch pads) is what makes
the process patchable; it is referenced here only where the runtime depends on
it.

Everything is `#+build windows` and x64-only. The mechanism is: compile the
program's own package again to a relocatable COFF `.obj`, map that object into
memory next to the running exe, wire up its relocations against the live image,
then atomically redirect the changed procedures' entry points to the freshly
compiled bodies.

---

## The big picture

```
odin build <pkg> -livepatch-patch      ->  hot_objs/*.obj   (relocatable COFF)
                                              |
apply_dir()/apply()  ---------------------->  apply_many()
                                              |
   1. map object(s) into memory near the exe          (livepatch.odin)
   2. build merged symbol tables, detect changed hot procs
   3. apply COFF relocations against the live image
   4. refresh @(rodata)/#load globals, swap the type table
   5. suspend other threads, verify none are mid-prologue
   6. patch each changed proc's entry -> new body       (patch.odin)
   7. resume; retire now-unreferenced old generations    (threads.odin)
```

The running exe must be built with `-livepatch -debug`. `-debug` is required
because the whole scheme resolves addresses in the live image through its **PDB**
(via DbgHelp), not through the exe's export table.

---

## File map

| File | Responsibility |
|------|----------------|
| `build.odin`    | Public entry points: `apply`, `apply_dir`, `build_patch`, `apply_patch`, async variants. Shells out to `odin build … -livepatch-patch`. |
| `livepatch.odin`| The core routine `apply_many`: mapping, symbol merge, relocation, orchestration of the whole reload. |
| `coff.odin`     | COFF/PE record structs and readers (headers, symbols, sections, relocations, string table). |
| `symbols.odin`  | Symbol resolution: PDB enumeration via DbgHelp, exe/DLL exports, TLS offsets, the "near arena" for trampolines and import cells. |
| `patch.odin`    | The actual entry-point patching: patch-pad detection, atomic pad jump, overwrite fallback. |
| `threads.odin`  | Thread suspension, IP/stack-walk safety checks, and generation lifetime (freeing old reloads safely). |
| `meta.odin`     | Reads compiler-emitted metadata: per-proc content hashes, patch hooks, new-global inits. |
| `types.odin`    | Reflection type-table diffing and swapping so `type_info_of` sees edited/new types. |

---

## Public API (`build.odin`)

```odin
apply(obj_path: string) -> bool          // one .obj
apply_dir(dir := "hot_objs") -> bool     // every .obj in a dir, as one reload
apply_many(obj_paths: []string) -> bool  // the core routine

build_patch(odin := "odin", env) -> bool // rebuild the .objs only
apply_patch(odin := "odin", env) -> bool // rebuild + apply in one step

build_patch_async(...) -> ^Async_Build   // rebuild on a worker thread
try_apply_async(ab) -> (applied, still_building: bool)
```

`build_patch` just runs `odin build <dir-of-exe> -livepatch-patch`, which emits
`hot_objs/*.obj` next to the exe. The async pair exists so a game/app loop can
kick off a rebuild without stalling a frame and apply it once the worker signals
`done` (via atomics; `try_apply_async` joins and applies on the calling thread).

Two global busy-flags guard against overlap:
- `_lp_busy` — one `apply_many` at a time.
- `_lp_build_busy` — one build/apply pipeline at a time.

When the exe was **not** built with `-livepatch`, `ODIN_LIVEPATCH` is false and
every entry point compiles down to `return false`.

---

## Step 1 — Mapping the object (`lp_map_object`)

The `.obj` is a standard AMD64 relocatable COFF file. `lp_map_object`:

1. Reads the whole file, validates the machine is `IMAGE_FILE_MACHINE_AMD64`.
2. Walks the section headers, laying each non-empty section out at a
   page-aligned offset within a single contiguous block. It records per-section
   offsets and the running `total` size.
3. **Reserves that block within ±1.5GB of the exe** via `alloc_near_exe`
   (`symbols.odin`). This is the crux of x64 relocation: `REL32` displacements
   are signed 32-bit, so code in the object can only reach the live image with a
   direct `call rel32` if it sits within 2GB. `alloc_near` probes outward from
   the exe base in 1MB steps up to `0x6000_0000` until `VirtualAlloc` succeeds.
4. Copies each section's raw bytes into its slot. Notes the `.text` base/size
   for later icache flushing.
5. Initializes a `Near_Arena` (a small executable scratch region, also placed
   near the exe) for trampolines and import cells, plus a `resolved[]` array
   sized to the symbol count.

The block is allocated `PAGE_EXECUTE_READWRITE`; protections are tightened
per-section at the very end of a successful reload.

---

## Step 2 — Symbol merge & change detection (`lp_build_symbols`)

All objects in one reload are treated as a set. For every defined COFF symbol,
two maps are built:

- **`all_defs[name]`** → the symbol's address *inside the mapped object*.
- **`all_syms[name]`** → the address a relocation should point at. This is the
  key decision:
  - Resolve the name in the **live exe** via the PDB (`lp_resolve_pdb`).
  - If it resolves, it is code, it has **changed**, and its entry point looks
    like a livepatchable "hot" entry → target the **object's** fresh copy and
    record it in `hot_names`.
  - Otherwise → target the **exe's existing** copy. This is what keeps unchanged
    code, globals, and cross-references pointing at the one live instance instead
    of duplicating state into the object.
  - If it does not resolve in the exe at all → fall back to the object copy.

"Changed" comes from `lp_proc_changed` (`meta.odin`): the compiler emits
`__odin_livepatch_func_hashes`, a table of `(fnv64(name), content_hash)`. The
running exe's table is read once into `_lp_cur`; the object's table is compared
against it. Same hash → unchanged → don't patch. This is why an unchanged reload
patches nothing.

> **Known limitation — the content hash is blind to referenced constants.**
> `lb_livepatch_proc_content_hash` (`src/llvm_backend.cpp`) hashes a proc's own IR,
> which names its string/constant globals by an index-based symbol
> (`csbs$<module>$0`) rather than by content. An edit that changes *only* a string
> literal (`"v1"` → `"v2"`) leaves the hash identical, so the proc is judged
> unchanged and the reload does nothing for it — the same blindness also stops the
> compiler emitting the module object at all. To force a reload, make any
> non-string change alongside it.

"Hot" comes from `lp_is_hot_entry` (`patch.odin`): the entry must be preceded by
a **patch pad** (see Step 6). If a proc changed but its prologue doesn't match a
pad, it is counted as a `hot_detect_miss` and reported — it cannot be patched.

Object-local constants (the `.odinti` section, `LP_CONST_SECTION`) are
deliberately **not** merged: they stay private to each object so identically
named local constant blobs don't collide.

---

## Step 3 — Relocation (`lp_relocate_object`)

First, each symbol index gets a resolved address in `o.resolved[]`:
- Defined in a real section → object-local const section keeps its object
  address; everything else uses `all_syms[name]` (the merge decision above).
- Undefined (`section_number == 0`) → `all_syms` if present, else
  `lp_resolve` against exports/PDB/imports (`symbols.odin`).

Then every relocation in every section is applied. Supported AMD64 types:

| Type | Handling |
|------|----------|
| `ADDR64` (0x01)   | `*u64 += target` — absolute 64-bit. |
| `REL32…REL32+5` (0x04–0x09) | PC-relative 32-bit with the built-in addend offset (`+1`…`+5` bytes). Computes `disp = target + addend - next`. If it overflows ±2GB, allocates a **trampoline** in the near arena (`lp_trampoline_for`) that does an absolute jump, and points the rel32 at that instead. |
| `ADDR32NB` (0x03) | Image-relative 32-bit (RVA). Computed relative to the object block base, with bounds checking so it can't wrap. |
| `SECREL` (0x0B)   | Section-relative — used for **thread-locals**. Resolved through `lp_tls_offset`, which calls the compiler-emitted accessor `__odin_lptls$<var>` to learn the variable's offset within the live TLS block, so the reload shares the exe's TLS storage. |

Unresolved relocations **in executable sections** abort the reload
(`unresolved_text`); unresolved relocations in data you never touch are only a
note. A common failure mode — a foreign-library function whose code isn't in the
running image — is reported with guidance (reference it in the base build, or
`/WHOLEARCHIVE`).

After patching bytes, the `.text` icache is flushed
(`FlushInstructionCache`), and each `.pdata` section is registered with
`RtlAddFunctionTable` so stack unwinding / exception handling works *through* the
newly mapped code.

### The near arena (`symbols.odin`)

`Near_Arena` bump-allocates 4KB executable blocks near the exe for two needs:
- **Trampolines** (`lp_trampoline_for`): 16-byte absolute-jump thunks for
  out-of-range `REL32` targets.
- **Import cells** (`lp_imp_cell`): 8-byte pointer cells for `__imp_<symbol>`
  references, so `call [rip+disp]`-style indirect imports resolve to a near cell
  holding the real address.

---

## Step 4 — Data & reflection refresh (`livepatch.odin`, `types.odin`)

Before touching code, three data-side updates happen, driven by compiler
metadata found in the "meta" object (`meta_i`):

1. **New global inits** (`__odin_livepatch_new_global_inits`): globals the reload
   *introduces* get their initializer blob copied into the runtime global arena,
   guarded by a once-flag so re-applying doesn't re-run initialization.

2. **`@(rodata)` / `#load` refresh** (`__odin_livepatch_refresh_syms`): named
   read-only globals whose *contents* changed are copied byte-for-byte over the
   live copy (temporarily `PAGE_READWRITE`). The live address wins so all
   existing references see the new bytes.

3. **Type-table swap** (`types.odin`): `lp_analyze_types` diffs the reload's
   `__odin_livepatch_type_infos` against the live named types
   (`lp_layout_differs` compares size, struct fields/offsets, enum members,
   union variants). If any type is new or changed layout, the reflection
   `runtime.type_table` slice header is swapped to the reload's version so
   `type_info_of` / `typeid_of` see edited and new types. A cached
   `__odin_livepatch_type_table_hash` lets an unchanged type set skip the whole
   walk. `lp_contains_changed` (memoized, recursive) also computes the set of
   *transitively* affected types passed to patch hooks.

A fast-path early-out: if there are no changed hot procs, no refresh targets, and
no type swap, the reload commits the hash table and reports "no changed
procedures to patch".

### Patch hooks (`meta.odin`)

The compiler collects user procedures marked as pre/post patch hooks into
`__odin_livepatch_pre_patch_hooks` / `__odin_livepatch_post_patch_hooks`.
`lp_call_patch_hooks` invokes them around the patch, passing the `[]Type_Change`
list. Pre-hooks resolve to the **live** proc (run the old code before the swap);
post-hooks resolve to the **reload's** proc (run the new code after). This is
where an app migrates existing state to a changed struct layout.

### Globals keep their exe address — and why a layout change is refused

All three data updates above preserve the global's **live exe address**; nothing
is duplicated into the reload. In `lp_build_symbols`, a data symbol (non-code)
always resolves to the exe's copy (`all_syms[name] = exe_addr`), so a reference
to global `a` from a freshly patched proc and a reference from an *unpatched*
proc land on the exact same address. Mutable state therefore survives a reload
untouched.

That single-instance invariant is exactly why the compiler **refuses a global
whose type layout changed** (`lb_livepatch_handle_global`, `src/llvm_backend.cpp`
→ "global '…' changed type/layout across a reload"). The base build records each
global's layout hash in the `.manifest`; a patch build compares and errors on a
mismatch. An existing exe global is a fixed address with fixed *old-layout*
storage in `.data`/`.bss`, and unpatched procedures reference it through
already-compiled instructions that a hot patch never rewrites. Relocating it to a
new-layout arena slot would make patched code see the new copy while unpatched
code kept reading the stale exe copy — silent divergence. Refusing it is the safe
default.

**The supported way to evolve a global's structure** is to put the evolving data
behind a *pointer* global (`state: ^State`, heap-allocated). The pointer's layout
never changes, so the guard never fires; grow or reorder `State` freely and
migrate the old value to the new layout in a `@(post_patch_hook)` (the
`[]Type_Change` list tells you what changed). New value fields are zero-init'd and
preserved from then on. For a value global you must evolve in place, add a
new differently-named global with the new layout and copy across in the hook —
new globals are already supported (Step 4.1).

To do the migration without hand-copying every field, call `migrate_fields`
(`types.odin`) from the hook: it reflection-copies every field present in both
the old and new struct (matched by name and identical type), skipping fields
whose own type changed and dropping fields that no longer exist. Typical use —
reallocate at the new layout and repoint:

```odin
@(post_patch_hook)
on_reloaded :: proc(changed: []livepatch.Type_Change) {
	for c in changed {
		if c.new == type_info_of(State) {
			ns := new(State)                                    // correctly sized for the new layout
			livepatch.migrate_fields(ns, c.new, state, c.old)   // copy matching fields by name
			state = ns
		}
	}
}
```

Note the invariant this does **not** repair: an *unpatched* procedure still reads
the global through the field offsets baked into its already-compiled code, so a
reorder/insert only stays correct if every accessor is re-patched in the same
reload. Appending fields (existing offsets unchanged) is the safe, common case
and needs no migration at all.

---

## Step 5 — Thread safety (`threads.odin`)

Patching an entry point that a thread is currently executing would corrupt it.
So before writing any jump:

1. **`lp_suspend_other_threads`** — enumerate every thread in the process with
   `NtGetNextThread`, skip our own (via `GetThreadId`), `SuspendThread` the rest.
2. **`lp_ip_conflicts`** — read each suspended thread's `RIP`. If any sits inside
   a to-be-patched region (`[entry-PAD_LEN, entry+PATCH_LEN)`), resume everyone,
   `Sleep(1)`, and retry — up to `MAX_ATTEMPTS` (100). This waits out a thread
   that is momentarily in a prologue rather than aborting.

Once no thread's IP conflicts, the reload is **committed** (memory won't be freed
on the deferred cleanup path) and the writes proceed while threads stay
suspended. Threads are resumed immediately after the jumps are installed.

Note the model: threads already *inside* the old body keep running the old code
to completion (their return addresses are untouched); only *new* calls take the
jump to the new body. Safety only requires that no thread's IP is sitting on the
exact bytes being overwritten.

---

## Step 6 — Patching the entry point (`patch.odin`) — in detail

This is the heart of the mechanism: turning "the new body lives at address X" into
"every future call to `foo` runs X instead of the old bytes", without ever
producing a torn instruction or corrupting a thread that is mid-call.

### The compiler-provided shape of a hot entry

`patch.odin` only works because the compiler lays out every livepatchable
procedure in a specific way. In `lb_add_proc_attributes` (`src/llvm_backend_proc.cpp`)
each such proc gets three LLVM attributes:

```cpp
lb_add_attribute_to_proc(m, p->value, "noinline");
lb_add_attribute_to_proc_with_string(m, p->value,
    "patchable-function", "prologue-short-redirect");
lb_add_attribute_to_proc_with_string(m, p->value,
    "patchable-function-prefix", "16");
```

- **`noinline`** — the proc must have a real, addressable entry point to patch;
  it can't be inlined into its callers.
- **`patchable-function-prefix "16"`** — emit **16 bytes of NOP prefix data
  immediately before the function symbol**. This is `PAD_LEN`. The symbol still
  points at the real first instruction; the 16 pad bytes sit at
  `[entry-16, entry)`.
- **`patchable-function "prologue-short-redirect"`** — guarantee the **first
  instruction of the prologue is at least 2 bytes long**, and is a valid place to
  write a 2-byte self-relative jump. (LLVM will lengthen a 1-byte first
  instruction if needed.) This is what makes the atomic 2-byte flip legal — the
  write never splits an instruction boundary in a way a concurrent fetch could
  observe half of.

So in memory a hot proc looks like:

```
        entry-16                         entry
          |                                |
   ... [ 16 bytes of NOP prefix pad ] [ >=2-byte first insn ][ rest of prologue ] ...
          \___________ PAD_LEN _________/ \_ overwritten atomically _/
```

Two runtime constants match this: `PAD_LEN = 16` (the prefix), and
`PATCH_LEN = 14`, the length of the absolute indirect jump we write:

```
FF 25 00 00 00 00        jmp qword [rip+0]     ; 6 bytes
<8-byte absolute target address>               ; 8 bytes  -> 14 total
```

14 fits inside the 16-byte pad (with 2 bytes to spare). This is the only way to
express an *unconditional, full-64-bit-range* jump on x64 in a fixed small
footprint — a normal `jmp rel32` can't reach an arbitrary 64-bit target, which is
exactly why the reload also had to be mapped *near* the exe for its own internal
calls.

### Detecting a patchable entry (`lp_has_patch_pad`, `lp_is_hot_entry`)

Before a proc is even considered "hot" in Step 2, and again right before
patching, the runtime confirms the pad is really there by looking at the 16 bytes
in front of the entry (`lp_has_patch_pad`):

- If they start with `FF 25`, a previous reload already installed an abs jump here
  → still a valid pad.
- Otherwise the 16 bytes must decode as a pure **NOP sled**.

`lp_is_nop_sled` / `lp_nop_len` decode the actual x86 NOP encodings the assembler
may emit, not just `0x90`:
- any run of `0x66` operand-size prefixes,
- `0x90` (1-byte `nop`, possibly with those prefixes),
- `0F 1F /0` (multi-byte `nop r/m`), decoding the ModRM/SIB/displacement to get
  the true instruction length.

This matters because the compiler/assembler pads the 16 bytes with a *few* long
NOPs, not sixteen `0x90`s, so a naive "all bytes == 0x90" check would fail.

`lp_is_hot_entry` additionally guards `entry >= PAD_LEN` so the `entry-16`
arithmetic can't underflow for a proc improbably close to address 0.

If a proc's content hash changed but this check fails, it is *not* patched and is
counted as a `hot_detect_miss` and warned about — the pad is the contract, and
without it there is no safe patch site.

### `patch_jump` — two strategies

```odin
patch_jump :: proc(original, target: rawptr) -> (ok, atomic: bool) {
    if lp_patch_atomic(original, target) { return true, true }
    return lp_patch_overwrite(original, target), false
}
```

It always *prefers* the atomic pad path and only falls back to a direct overwrite
when there is no usable pad.

### Strategy A — atomic pad jump (`lp_patch_atomic`)

This is the normal path for compiler-emitted hot procs. The trick is that the
14-byte jump is written **into the pad**, which nothing is executing, and only a
tiny 2-byte redirect is written over the live entry:

1. Re-check `lp_has_patch_pad(original)`; bail if the pad isn't there.
2. `VirtualProtect` the region `[entry-16, entry+2)` (`PAD_LEN + 2` bytes) to
   `PAGE_EXECUTE_READWRITE`.
3. **Write the full 14-byte `FF 25` absolute jump into the pad** (`entry-16`),
   pointing at the new body (`lp_write_abs_jump`). No thread can be here — the pad
   is not reachable code yet.
4. `FlushInstructionCache` over the pad so the CPU's icache picks up the new
   bytes.
5. **Atomically** store `0xEEEB` at the entry with
   `intrinsics.atomic_store((^u16)(original), 0xEEEB)`. Little-endian that is the
   two bytes `EB EE`, i.e. `jmp short -18`:

   ```
   target = (entry + 2)  +  (-18)  =  entry - 16   ; = start of the pad
   ```

   So the entry now jumps back 16 bytes into the pad, which jumps (absolute) to
   the new body.
6. `FlushInstructionCache` over those 2 bytes.
7. Restore the pad's original page protection.

Why this is safe under concurrency: the only byte range a *running* thread can be
fetching from is the live entry. That range is mutated by a **single aligned
16-bit atomic write**. A concurrent instruction fetch therefore sees either the
old first instruction in full or the new `EB EE` in full — never a mix. The
14-byte jump it ultimately lands on was already fully written and icache-flushed
*before* the flip became visible. Combined with the `prologue-short-redirect`
guarantee that the first instruction is ≥2 bytes, the write can never leave a
half-instruction behind.

The resulting control flow after patching:

```
call foo   ->   entry:    EB EE         (jmp -16)
                entry-16:  FF 25 .. <ptr>  (jmp qword [rip+0] -> new body)
                                          -> new_foo executes
```

Re-patching later just overwrites the pad's abs-jump target and re-flips the same
2 bytes; because `lp_has_patch_pad` also accepts an existing `FF 25`, a proc can
be hot-reloaded any number of times.

### Strategy B — in-place overwrite (`lp_patch_overwrite`)

The fallback when there is no pad (e.g. a hand-built or non-`-livepatch` entry
that still needs redirecting). It writes the 14-byte abs jump **directly over the
entry's first 14 bytes**:

1. Compute the gap to the *next* symbol via `lp_next_symbol_after` (a scan of the
   PDB symbol addresses). If fewer than `PATCH_LEN` (14) bytes are available,
   **refuse** — overwriting would spill into the following procedure.
2. `VirtualProtect` 14 bytes to `PAGE_EXECUTE_READWRITE`, write the abs jump,
   restore protection, flush the icache.

This path is **not atomic** — it stomps up to 14 bytes, so it is unsafe if any
thread's instruction pointer is inside those bytes. Its correctness relies
entirely on Step 5: all other threads are suspended and confirmed (via
`lp_ip_conflicts`) not to have their `RIP` inside `[entry-16, entry+14)` before
any write happens. The atomic path benefits from the same suspension but doesn't
strictly need it; the overwrite path does.

### Where the callers of `patch_jump` sit

In `apply_many`, patching is the final mutating step and happens **while threads
are suspended and after `committed = true`**:

```
suspend threads  ->  verify no IP conflict  ->  (refresh globals, swap type table)
                 ->  for each target: patch_jump(original, fresh)
                 ->  resume threads  ->  retire freeable old generations
```

Each successfully patched entry records `_lp_owner[entry] = gen_serial`, which is
how a *later* reload knows this generation's code is still the current occupant of
that entry — and therefore must not be freed until something newer replaces it and
no thread's stack is still inside it (Step 7).

---

## Step 7 — Generations & safe freeing (`threads.odin`)

Each successful reload's memory (object blocks, near arenas, `.pdata`
registrations) is bundled into an `Lp_Generation` with a monotonically
increasing `serial` and the set of addresses it "owns" (patched entries, refresh
targets, the type-table ref). `_lp_owner[addr] = serial` records who last wrote
each address.

Old generations can't be freed immediately — a thread may still be executing
inside their code. On each reload, while threads are suspended,
`lp_scan_freeable` marks a past generation freeable only if:
- **Unreferenced** — every address it owns has since been overwritten by a newer
  generation (`_lp_owner[addr] != gen.serial`), *and*
- **Untouched** — walking every suspended thread's stack
  (`lp_thread_touches`, via `RtlLookupFunctionEntry` + `RtlVirtualUnwind`) finds
  no return address inside the generation's code ranges.

`lp_free_marked` then releases those blocks and `RtlDeleteFunctionTable`s their
unwind info. This is a deferred, reference-counted-by-generation GC for hot code:
memory is reclaimed on a *later* reload once nothing can be running in it. If the
`apply_many` fails before commit, a `defer` frees the half-built objects instead.

`live_generations()` exposes the count of still-tracked generations.

---

## Applying multiple patches over time

Every call to `apply` / `apply_dir` / `apply_many` is one **reload**, and reloads
accumulate. The design lets you patch the same procedure over and over
(`v1 → v2 → v3 …`) while keeping change-detection honest, avoiding jump chains,
and reclaiming dead code lazily. Four pieces of persistent state make this work,
all updated only on a *successful* reload.

### 1. Patches always originate at the exe's original entry

The critical anti-accumulation property: when a proc is re-patched, the redirect
is **not** stacked on top of the previous redirect. In `apply_many`:

```odin
original := lp_resolve_pdb(h.name)   // ALWAYS the exe's static entry, from the PDB
```

`lp_resolve_pdb` returns the address in the *original linked image*, which never
moves. So for `foo`:

- Reload 1: entry `foo` → `EB EE` → pad → `jmp` **body_v1** (in gen 1's block).
- Reload 2: the same entry `foo` is re-patched. `lp_has_patch_pad` sees the
  existing `FF 25` in the pad and accepts it; `lp_patch_atomic` **overwrites the
  pad's 8-byte target** with `body_v2`'s address and re-flips the same `EB EE`
  (the atomic store just writes the identical 2 bytes again, harmless).

```
   foo:      EB EE  ────┐         (unchanged across reloads)
   foo-16:   FF 25 ─────┴──▶ body_vN   ◀── only this pointer is rewritten each reload
```

There is never a `v3 → v2 → v1` chain of jumps. Each reload retargets the single
pad at the original entry straight to the newest body. Old bodies become
unreferenced immediately (nothing jumps to them anymore) but are freed lazily
(below).

### 2. `_lp_cur` — change detection tracks the *live* state, not the exe

`_lp_cur` (in `meta.odin`) starts as the running exe's per-proc content hashes.
After each successful reload the applied object's hashes are merged in:

```odin
for k, v in obj_hashes { _lp_cur[k] = v }
```

So `lp_proc_changed` always compares a new object against **whatever is currently
live**, not the original binary. Concretely: if reload 2's `.obj` still contains
`foo_v1` (because you only edited `bar`), `foo`'s hash matches `_lp_cur` and it is
*not* re-patched. Only procedures whose content differs from the current live
version are touched on any given reload. Without this, every reload would
re-patch every proc in the package.

`_lp_cur_type_hash` accumulates the same way for the reflection type table, and
`lp_advance_live_types` / `_lp_latest_ti_hdr` advance the "live named types"
baseline after a swap — so a later type diff compares against the most recently
swapped table, not the exe's original type set.

### 3. Once-only side effects don't re-fire

Re-applying must not re-run one-time work:

- **New-global inits** are each guarded by a `flag` byte in the runtime arena
  (`New_Global_Init.flag_offset`); the blob is copied only while `flag == 0`, then
  the flag is set. A global introduced in reload 2 is initialized once, even if
  reload 3, 4, … still carry it.
- **`@(rodata)`/`#load` refresh** and the **type-table swap** are idempotent
  byte-copies — re-doing them with identical bytes is a no-op, and the type-hash
  fast-path skips the whole type walk when nothing changed.

Patch **hooks**, by contrast, fire on *every* reload that has changes (pre-hooks
before the swap on the old code, post-hooks after on the new code), receiving that
reload's `[]Type_Change`. They are the intended place for per-reload state
migration.

### 4. Generations pile up, then collapse

Each successful reload appends one `Lp_Generation` (serial `1, 2, 3, …`) holding
that reload's mapped blocks, near arena, and `.pdata` registrations, plus the set
of addresses it `owned` (entries it patched, globals it refreshed, the type-table
ref). `_lp_owner[addr]` is overwritten to the newest serial that wrote `addr`.

Memory is **not** freed when a generation is superseded — a thread may still be
running inside its code, or have a return address into it. Instead, on each
*subsequent* reload (threads suspended), `lp_scan_freeable` retires an old
generation only when both hold:

- **Unreferenced** — every address it owns now maps to a *newer* serial in
  `_lp_owner` (something replaced all of its patches / refreshes), and
- **Untouched** — a full stack walk of every suspended thread finds no return
  address inside its code ranges.

So the steady state is: a handful of live generations at most — the current one
plus any older ones whose code some thread is still executing or still on a call
stack. A generation that patched a proc *no later reload has touched again* stays
referenced forever and is never freed, which is correct: its body is still the
live implementation of that proc. The count is observable via
`live_generations()`, and each collapse prints `freed N stale reload
generation(s); M still in use`.

### Which copy does a reload's code call? (newly-added procedures)

Symbol resolution is **per-reload and self-contained**: `lp_build_symbols` looks
only at *this* reload's objects plus the *exe's PDB*. It never consults prior
generations. So the address a relocation targets is decided fresh each reload:

- **Symbol exists in the exe** → point at the exe's copy, unless it's a changed,
  hot procedure (then this reload's fresh copy).
- **Symbol does not exist in the exe** (a procedure a patch *introduced*) →
  `exe_addr` is nil, so it falls to `all_syms[name] = obj_addr`: **this reload's
  own copy**.

Therefore, if v1 adds `helper` and both v1 and v2 call it, **v2 calls v2's copy
of `helper`** — even if `helper` didn't change — not v1's. Every reload maps and
links its own copies of all non-exe procedures; v1's `helper` and v2's `helper`
are distinct addresses.

A newly-added procedure has **no exe entry and no patch pad**, so it can never be
an independent patch target — it exists only as a callee inside reload blocks. And
the per-proc content hash (`lb_livepatch_proc_content_hash`) is FNV64 of the
proc's *own* normalized LLVM IR, which names callees by symbol (`call @helper`) —
there is **no transitive invalidation**. So if v2 edits `helper`'s body but its
caller `foo` is otherwise unchanged, `foo`'s hash is identical, `foo` is not
re-patched, and the live `foo` (still v1's body) keeps calling **v1's `helper`**.
To make an edited leaf procedure take effect, something on the live call path that
reaches it must itself be re-patched (its own bytes must differ).

### Worst case and its bound

The only unbounded growth is the near-exe address space: each reload reserves a
fresh block within ±2GB of the exe and can't reuse a still-referenced old one.
Generations that never become freeable (e.g. a proc left running in an infinite
loop that was patched once and never again) pin their blocks. In practice reloads
during development churn the same handful of procs, older generations go
unreferenced quickly, and their blocks are released on the next reload — so memory
tracks the number of *distinct currently-live* hot bodies, not the total number of
reloads ever applied.

---

## Dependencies on the compiler & PDB

The runtime leans on several compiler-emitted symbols (resolved through the PDB):

| Symbol | Purpose |
|--------|---------|
| `__odin_livepatch_func_hashes`      | per-proc content hashes → change detection |
| `__odin_livepatch_build_id`         | rejects objects not built against the running exe |
| `__odin_livepatch_type_infos` / `_type_table_hash` / `_type_table_ref` | reflection type diffing & swap |
| `__odin_livepatch_new_global_inits` | init blobs for newly introduced globals |
| `__odin_livepatch_refresh_syms`     | `@(rodata)`/`#load` globals to refresh |
| `__odin_livepatch_pre/post_patch_hooks` | user migration hooks |
| `__odin_lptls$<var>`                | per-thread-local offset accessors (SECREL relocs) |
| the 16-byte NOP pad before each hot entry | the atomic patch site |

And on **DbgHelp** (`SymInitialize` / `SymEnumSymbolsW`) to enumerate the live
image's symbols once (`lp_dbghelp_ensure`), since non-exported procedures and
globals aren't in the export table. No PDB (no `-debug`) → no live addresses →
livepatch can't work.

---

## Preloading — how a patch can import a package

A patch object never carries stdlib code: `lb_livepatch_skip_object`
(`src/llvm_backend.cpp`) skips every module under a builtin collection
(`base:`, `core:`, `vendor:`). So a reload can only *call* what is already in
the running image. Left alone, that means a live edit reaching for a procedure
the base build never referenced dies at "unresolved symbol", which rules out
adding an `import` to a patched file.

A `-livepatch` base build therefore preloads everything its imports could
reach, along two paths:

**Odin source — `generate_livepatch_package_deps` (`src/checker.cpp`).** Runs
right after `generate_livepatch_type_info_deps`, and forces every top-level
procedure and variable of every imported package into the minimum dependency
set. The linker then keeps it all, because `-livepatch` already implies
`/OPT:NOREF`, and the publics land in the PDB where `lp_resolve_pdb` reads
them.

This cannot widen the set of *packages*: the checker only ever creates entities
for transitively-imported packages, and a procedure body can only reference
what its own file imports. Three kinds of entity are skipped, because forcing
them makes the compiler check code that was never meant to exist:

- uninstantiated polymorphic procedures (`add_dependency_to_set` already
  refuses these);
- discarded generic instantiations — overload resolution registers a candidate
  per proc-group member and throws away the ones whose `where` clauses fail,
  but the entities stay in `info.entities`;
- aliases (`to_lower_camel_case :: to_camel_case`), which have no body of their
  own; emitting one alongside the entity it aliases produces two functions
  against one `DISubprogram`, which LLVM rejects.

It runs on **host builds only**. A patch build's dependency set then stays a
strict subset of the host's, so a reload can never need a global or procedure
the host image lacks — and every F5 avoids generating IR for all of `core:`.

**Foreign archives — `/WHOLEARCHIVE` (`src/linker.cpp`).** A static archive
only contributes the members something referenced. Under `-livepatch` each
non-system foreign library is passed as `/WHOLEARCHIVE:<path>` so every member
is in the image. `system:` libraries are excluded — they resolve to a bare
filename with no directory, and whole-archiving the system import libraries
only balloons the IAT.

**Cost, and the escape hatch.** Measured on `examples/livepatch_demo`
(`tests/livepatch/bench.ps1`):

| | no preload | preload | |
|---|---|---|---|
| base build   | 0.73s   | 1.12s   | 1.53x |
| patch build  | 0.62s   | 0.58s   | unchanged |
| exe          | 4.18 MB | 6.41 MB | 1.53x |
| pdb          | 2.63 MB | 4.96 MB | 1.89x |

The **patch build is unaffected**, and `hot_objs` is byte-identical either way
— which is the point of keeping this on the host side. A larger PDB does mean
a longer first-apply pause, since `lp_dbghelp_ensure` enumerates every symbol
once. How much a given project pays depends on how much of its import graph is
currently dead code.

`-livepatch-no-preload` turns both paths off. A reload is then limited to
procedures the base build already referenced, which is what `tests/livepatch`
asserts as its negative case.

What still needs a full rebuild: importing a package that *nothing* in the base
build imports. Its code was never compiled into the host at all.

---

## Failure modes it guards against

- Wrong-arch object, object too small, build-id mismatch → abort early.
- Unresolved relocation in executable code → abort (nothing patched).
- Changed proc with no patch pad → reported, skipped, warned.
- Overwrite that would spill into the next proc → refused.
- A thread stuck in a prologue for 100 attempts → abort.
- Failure before commit → deferred cleanup frees everything mapped.
