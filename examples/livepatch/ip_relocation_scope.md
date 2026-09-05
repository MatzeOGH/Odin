# Scope: instruction-pointer relocation (Live++-style on-stack patching)

What it would take to move a thread that is **currently executing inside** a
patched function onto the new body, instead of the current model where the
in-flight call finishes on the old body and only new calls take the jump.

Windows / x64. Grounds against the existing loader (`core/livepatch/*.odin`).

> **Correction — this is NOT catching up to Live++; it would EXCEED it.**
> Verified against Live++'s own docs and hands-on write-ups (see `gaps.md`
> sources): Live++ does **not** automatically relocate the IP. It patches a jump
> at the function entry (same as this build), lists **"functions on the stack" as
> a limitation**, and waits for an executing function to return before its new
> code is used. Its only IP relocation is the **manual** debugger "set next
> statement" arrow, driven by a human, which works because Live++ has source-level
> debugging of hot code. So:
> - This build is **already at parity** with Live++ on on-stack functions.
> - The Live++ "re-run the function with the fix" workflow is reproduced for free
>   by **manual set-next-statement** once hot code has source-level debugging
>   (gap #1 in `gaps.md`) — none of the tiers below are needed for parity.
> - Everything below is about **automatically** doing what Live++ leaves to the
>   human, i.e. going *beyond* Live++. The hard sub-problems are intrinsic and the
>   scoping stands, but treat this as an optional enhancement, not a gap to close.

---

## Current model (Tier 0)

`apply_many` suspends all other threads and calls `lp_ip_conflicts`
(`threads.odin:199`) to check whether any RIP sits in the tiny patch region
`[entry-PAD_LEN, entry+PATCH_LEN)`. If so it resumes, sleeps, and retries — it
only waits out a thread parked in the *prologue*. A thread executing deep in the
body is ignored: the old body stays mapped, that call runs old code to return,
and only subsequent calls take the atomic jump. Old generations are freed lazily
once `lp_context_touches` (`threads.odin:58`, the full `RtlVirtualUnwind` stack
walk) finds no frame still inside them.

IP relocation replaces "ignore / wait" with "rewrite that thread's `CONTEXT` and
`SetThreadContext`".

---

## The three sub-problems any IP relocation must solve

For a thread stopped at old address `RIP_old` inside patched function `foo`:

1. **P1 — Point mapping.** Find the address in the *new* `foo` where execution
   should resume. `new_entry + (RIP_old - old_entry)` only works if code before
   the resume point is byte-identical.
2. **P2 — Frame transformation.** The new `foo` may have a different frame size,
   different local/spill slots, different alignment. The live stack frame must be
   rebuilt to the new layout before resuming.
3. **P3 — Register remapping.** A value in `rbx` (or a spill slot) in old code may
   live somewhere else in new code. Every live value must be moved to where new
   code expects it.

P2+P3 together require a **complete description of every live value's location at
that exact program point, in both versions** — this is an on-stack-replacement
(OSR) safepoint, the thing JIT VMs (JVM, V8) emit deliberately and only at chosen
points. In full generality across arbitrary edits it is **undecidable** (the
"equivalent point" may not exist — the edit deleted the line you're on).

### The one structural constraint that helps us enormously

**Under `-livepatch`, all user code is compiled `-o:none`** (see STATUS.md
"Optimized builds"). That means:
- A **stable frame pointer** (`rbp`), fixed frame size per function.
- **Every local lives in a memory slot** off `rbp` — no register-allocated
  locals to chase. P3 nearly vanishes for locals; only in-flight expression
  temporaries and the standard callee-saved set matter.
- Locals are addressed by fixed offsets already described in the `-debug` info we
  emit.

This is why the harder tiers below are far more tractable here than in an
optimized-C++ world — and why the resume point must still be an instruction
boundary between statements, not mid-expression (where temporaries are transient).

### The other hard constraint: only the innermost frame is relocatable

If `foo` is deeper on the stack (has live callees above it), its frame cannot be
moved while those callees must still return through it — you'd corrupt the return
path. So every tier below is **"innermost frame only":** relocate a thread only
when `RIP_old` is directly in the patched function with no active callee. (Live++
has this restriction too.) `lp_context_touches` already distinguishes the top
frame from deeper ones, so the detection is in hand.

---

## Achievable tiers, cheapest to hardest

### Tier A — Re-invoke at entry (restart the call)
If the innermost frame is `foo` and restarting `foo` from the top is acceptable,
unwind that frame and re-call new `foo` with the original arguments.
- **Needs:** recover arguments (home space / per-cc from the frame), confirm the
  frame is innermost, and a **user contract that restart is side-effect-safe**.
- **Verdict:** semantically dangerous (re-runs whatever `foo` already did this
  call), narrow. Low value. Skip unless a specific idempotent use case wants it.

### Tier B — Same-offset relocation for tail-only edits  ★ recommended sweet spot
If the edit changes `foo` **only after** `RIP_old`'s offset, and prologue + frame
size + all code up to the resume point are byte-identical, then the frame is
already correct (nothing before the IP changed) and you can set
`RIP = new_entry + (RIP_old - old_entry)` and resume. P2/P3 are no-ops by
construction.
- **Needs (loader):** byte/instruction diff of old vs new `foo`; find the first
  divergent offset; if it is strictly greater than `RIP_old - old_entry` **and**
  frame size/prologue match, relocate. Otherwise fall back to Tier 0 (leave it on
  old code). Reuses the suspend + `CONTEXT` plumbing already in `threads.odin`.
- **Needs (compiler, optional but advisable):** emit per-function frame size + a
  prologue/leading-bytes hash so "layout unchanged up to the divergence point"
  is a cheap, reliable check instead of heuristic byte-diffing.
- **Cost:** ~1–2 weeks. Loader-heavy, small/no compiler change.
- **Verdict:** the safe, verifiable subset. Handles the common "I edited the rest
  of my loop body after the current point" case and lets old generations free
  immediately. Best effort/payoff.

### Tier C — Line-table-driven relocation with frame fix-up  (the real Live++-like feature)
Map `RIP_old → source line` (old line table) → `RIP_new` = start of that line's
code in new `foo` (new line table). Then transform the frame: allocate the new
frame size, and copy each surviving local from its old slot to its new slot by
**name** (a var→frame-offset table per version). Because user code is `-o:none`,
locals are all in memory and this is a bounded memcpy-by-name — structurally the
same operation as the reflection `migrate_fields` already does for globals.
- **Needs (compiler):** per-function, per-version tables of `{local name → rbp
  offset, type}` and `{source line → code offset}`. Most of this already exists in
  the `-debug` CodeView info; the work is *emitting it in a loader-consumable form*
  (a `__odin_livepatch_frame_maps` section) or teaching the loader to read it from
  the PDB.
- **Needs (loader):** a frame rewriter — build the new frame on the thread's
  stack (or in place if the size shrinks), copy matching locals, re-establish
  callee-saved regs from the old frame's saved area, set `RIP`/`RSP`/`RBP`,
  `SetThreadContext`.
- **Restrictions that remain even here:** resume only at a clean statement
  boundary (never mid-expression); refuse when the current source line no longer
  exists in new `foo` (deleted/moved) — fall back to Tier 0; still innermost-frame
  only; control-flow edits that change which block you're "in" are unsafe and must
  be detected and refused.
- **Cost:** ~4–8 weeks. Compiler debug-info emission + a frame rewriter + a
  safe-point/refusal policy. This is the bulk of the engineering.
- **Verdict:** genuine mid-function on-stack replacement. Feasible here mainly
  because of `-o:none`. Do it only if threads parked *inside* a changed function
  must pick up structural edits without returning first.

### Tier D — True OSR with compiler safepoints
Compiler emits explicit migration points carrying full state descriptors (live
ranges, deopt maps) at loop back-edges and call returns, like a JIT. Full
generality, VM-level engineering, and it fights `-o:none` simplicity. **Out of
scope.**

---

## Where it plugs in

All tiers hook the same spot in `apply_many`: after suspend + resolve, for each
suspended thread whose top frame is a patched function (detected by the existing
`lp_context_touches` walk, specialized to report *which* range and the top frame's
`CONTEXT`), attempt relocation for the chosen tier; on refusal, fall back to
today's behavior (leave the thread on old code, keep the old generation alive).
`SetThreadContext` is already reachable via `core:sys/windows`; the access rights
requested in `lp_suspend_other_threads` (`threads.odin:162`) already include
`THREAD_SET_CONTEXT`.

Secondary benefit: any successfully relocated thread stops pinning its old
generation, so `lp_scan_freeable` can reclaim old blocks sooner.

---

## Recommendation

- **Don't build this for parity — it isn't needed.** Live++ doesn't do automatic
  IP relocation either (see the correction banner). To match Live++'s workflow,
  ship **source-level debugging of hot code** (gap #1) and let the user do manual
  set-next-statement in the debugger. That is the whole feature, for free.
- **The pragmatic escape hatch covers the rest.** The state-preservation model
  keeps old bodies resident and redirects new calls, so automatic relocation would
  only help (a) a function that loops long / never returns and must adopt new code
  mid-flight, and (b) freeing old code a little sooner. For (a), move the hot work
  into a *called* function so the next call gets new code — already how the demo's
  frame loop is structured.
- **Only if you want to exceed Live++:** build **Tier B** (same-offset tail-change
  relocation) — modest, loader-mostly, provably safe, ~1–2 weeks. **Tier C** is the
  automatic mid-function version, tractable here only because user code is `-o:none`,
  ~4–8 weeks (mostly compiler debug-info plumbing + a frame rewriter). **Skip Tier A
  and Tier D.**
