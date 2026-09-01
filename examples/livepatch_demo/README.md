# Livepatch demo — raylib + microui

A bouncing-ball scene with a microui control panel, wired for **livepatch**: edit the code,
press **F5** in the window, and the running program changes *without restarting* — the balls
keep their exact positions and velocities. State survives because it lives in globals, which
livepatch preserves across a reload.

Windows / x64 only (livepatch is `#+build windows`).

## Build & run

Build the host once, with livepatch on. Run this from the repo root so the built compiler
(`odin.exe`) is the one on hand:

```bash
odin build examples/livepatch_demo -livepatch -debug -out:examples/livepatch_demo/demo.exe
```

This produces `demo.exe`, `demo.pdb`, and `odin-livepatch.manifest` next to the source. Then:

```bash
examples/livepatch_demo/demo.exe
```

## The demo

1. With the window open, drag the panel, move the **Gravity**/**Speed** sliders, toggle
   **Paused**, hit **Reset positions**.
2. Open `main.odin` and edit the `frame` proc — try any of:
   - change a slider range, e.g. `mu.slider(ctx, &s.gravity, 0, 3000)`
   - add a widget, e.g. another `mu.checkbox` or `mu.button`
   - change the bounce damping (`* 0.86`) or wall logic
   - in `seed_state`, change `s.bg` or the ball palette
3. **Save, then press F5 in the window.** `demo.exe` rebuilds the patch and hot-loads it.
   The change appears; the balls keep moving from where they were. The on-screen **reloads**
   counter ticks up (bumped by the `@(post_patch_hook)`).

F5 calls `livepatch.build_patch_async()`, which shells out `odin build <this dir>
-livepatch-patch` (the package is just the exe's own directory) **on a worker thread**,
so the window keeps animating during the multi-second compile — you'll see a "building patch…"
line while it runs. Each frame the loop calls `livepatch.try_apply_async()`, which applies the
resulting `hot_objs/*.obj` on the main thread once the build is ready (the apply must stay on the
app's own thread — it briefly suspends every other thread to patch). A compile error just prints
and leaves the running program untouched.

For the simple blocking version, `livepatch.apply_patch()` does the build and apply in one call.

## What you can and can't change live

- **Freely, live:** anything in `frame`, `draw_scene`, `seed_state`, or the `State` fields —
  values, colors, physics, layout, and any widget the base build already used.
- **Also live:** any raylib or microui procedure, including ones the base build never called,
  and a brand-new `import` of a package some package here already imports. A `-livepatch` base
  build preloads everything its imports could reach -- it emits every procedure of every
  imported Odin package, and links foreign archives whole (`/WHOLEARCHIVE`) -- so the whole
  raylib and microui surface is in the image waiting for you. For this demo that costs a 1.5x
  larger exe, a 1.9x larger PDB and +0.4s on a full rebuild — the F5 patch build is unaffected.
  `-livepatch-no-preload` turns it off if you would rather have the smaller host.
- **Needs a full rebuild (not F5):** importing a package that *nothing* in the base build
  imports. Its code was never compiled into the host, and a patch object never carries stdlib
  code, so the reload fails with "unresolved symbol." Rebuild the host once.
- **Also live, but exercises the migration path:** adding a field to `State`. New globals /
  new struct fields are zero-initialized and preserved from then on.

See [`core/livepatch/HOW_IT_WORKS.md`](../../core/livepatch/HOW_IT_WORKS.md) for how it works.

## Files

- `main.odin` — setup, frame loop, F5 trigger, and the editable `frame` proc (**edit this**).
- `mu_raylib.odin` — microui↔raylib backend (atlas texture, input, command rendering).

## Non-livepatch build

The demo runs the same without livepatch; `apply_patch()` is then a no-op returning `false`:

```bash
odin build examples/livepatch_demo -out:examples/livepatch_demo/demo.exe
```
