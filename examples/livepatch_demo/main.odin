package livepatch_demo
// odin build examples/livepatch_demo -livepatch -debug -out:examples/livepatch_demo/demo.exe

import "core:livepatch"
import "core:os"
import "core:path/filepath"
import "core:fmt"
import mu "vendor:microui"
import rl "vendor:raylib"

WIDTH  :: 900
HEIGHT :: 600
N_BALLS :: 24

Ball :: struct {
	pos, vel: rl.Vector2,
	radius:   f32,
	color:    rl.Color,
}

State :: struct {
	balls:    [N_BALLS]Ball,
	bg:       rl.Color,
	gravity:  f32,
	speed:    f32,
	paused:   bool,
	reloads:  int,
	boo : f32
}

state:  ^State
ctx:    mu.Context

@(rodata)
PALETTE := [4]u8{0, 0, 255, 255}

new_var := 88

IMG := #load("image_v1.png")
img_tex: rl.Texture2D
img_src: rawptr

reload : bool
patch_build: ^livepatch.Async_Build // non-nil while a background patch build is running


main :: proc() {
	rl.InitWindow(WIDTH, HEIGHT, "Odin livepatch demo edit frame(), press F5")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	mu.init(&ctx)
	ctx.text_width  = mu.default_atlas_text_width
	ctx.text_height = mu.default_atlas_text_height

	atlas := atlas_texture()
	defer rl.UnloadTexture(atlas)

	img_tex = load_image_texture(IMG)
	img_src = raw_data(IMG)
	defer rl.UnloadTexture(img_tex)

	state = new(State)

	seed_state(state)
	prime_widgets(&ctx) // keep the microui widget palette in the exe so live edits can add any of them

	exe_dir := filepath.dir(os.args[0])
	odin_exe, _ := filepath.join({exe_dir, "..", "..", "odin.exe"})




	for !rl.WindowShouldClose() {
		// F5 kicks the patch build onto a worker thread so the window keeps animating during the
		// (multi-second) compile; try_apply_async then applies it here on the main thread once the
		// build is ready. patch_build is non-nil exactly while a build is in flight.
		if (reload || rl.IsKeyPressed(.F5)) && patch_build == nil {
			reload = false
			patch_build = livepatch.build_patch_async(odin = odin_exe)
		}
		if patch_build != nil {
			if _, building := livepatch.try_apply_async(patch_build); !building {
				patch_build = nil
			}
		}

		if raw_data(IMG) != img_src {
			rl.UnloadTexture(img_tex)
			img_tex = load_image_texture(IMG)
			img_src = raw_data(IMG)
		}

		mu_handle_input(&ctx)
		frame(state, &ctx)

		rl.BeginDrawing()
		rl.ClearBackground(state.bg)
		draw_scene(state)
		mu_render(&ctx, atlas)
		rl.EndDrawing()
	}
}

seed_state :: proc(s: ^State) {
	s.bg      = {24, 26, 33, 255}
	s.gravity = 300
	s.speed   = 1
	palette := [?]rl.Color{
		{239, 83, 80, 255}, {66, 165, 245, 255}, {102, 187, 106, 255},
		{255, 202, 40, 255}, {171, 71, 188, 255}, {38, 198, 218, 255},
	}
	for &b, i in s.balls {
		b.radius = 10 + f32((i * 7) % 22)
		b.pos    = {f32(60 + (i * 53) % (WIDTH - 120)), f32(40 + (i * 31) % 200)}
		b.vel    = {f32(80 + (i * 17) % 160) * (i & 1 == 0 ? 1 : -1), 0}
		b.color  = palette[i % len(palette)]
	}
}

frame :: proc(s: ^State, ctx: ^mu.Context) {
	dt := rl.GetFrameTime()

	if !s.paused {
		for &b in s.balls {
			b.vel.y += s.gravity * dt
			b.pos += b.vel * dt * s.speed

			if b.pos.x - b.radius < 0        { b.pos.x = b.radius;          b.vel.x = +abs(b.vel.x) }
			if b.pos.x + b.radius > WIDTH    { b.pos.x = WIDTH - b.radius;  b.vel.x = -abs(b.vel.x) }
			if b.pos.y + b.radius > HEIGHT   { b.pos.y = HEIGHT - b.radius; b.vel.y = -abs(b.vel.y) * 0.86 }
			if b.pos.y - b.radius < 0        { b.pos.y = b.radius;          b.vel.y = +abs(b.vel.y) }
		}
	}

	mu.begin(ctx)
	if mu.window(ctx, "Controls", {20, 20, 250, 260}) {
		mu.layout_row(ctx, {-1}, 0)
		mu.label(ctx, "Edit frame() and press F5")
		mu.label(ctx, fmt.tprintf("%d", new_var))

		mu.layout_row(ctx, {70, -1}, 0)
		mu.label(ctx, "Gravity")
		mu.slider(ctx, &s.gravity, 0, 1200)
		mu.label(ctx, "Speed")
		mu.slider(ctx, &s.speed, 0, 3)

		mu.layout_row(ctx, {-1}, 0)
		mu.checkbox(ctx, "Paused", &s.paused)
		
		
		if .SUBMIT in mu.button(ctx, "Reset positions") {
			seed_state(s)
		}
		
	}
	mu.end(ctx)
}

draw_scene :: proc(s: ^State) {
	for b in s.balls {
		rl.DrawCircleV(b.pos, b.radius, b.color)
	}

	if img_tex.id != 0 {
		src := rl.Rectangle{0, 0, f32(img_tex.width), f32(img_tex.height)}
		dst := rl.Rectangle{WIDTH - 180, 30, 150, 150}
		rl.DrawTexturePro(img_tex, src, dst, {0, 0}, 0, rl.WHITE)
	}

	if patch_build != nil {
		rl.DrawText("building patch… (window stays live)", 20, HEIGHT - 55, 20, {245, 200, 90, 255})
	}
	rl.DrawText("edit frame(), press F5 to livepatch", 20, HEIGHT - 30, 20, {180, 190, 210, 255})
	rl.DrawText(rl.TextFormat("reloads: %d", i32(s.reloads)), WIDTH - 150, HEIGHT - 30, 20, {180, 190, 210, 255})
}

lalal:= 64

load_image_texture :: proc(png_bytes: []u8) -> rl.Texture2D {
	img := rl.LoadImageFromMemory(".png", raw_data(png_bytes), i32(len(png_bytes)))
	defer rl.UnloadImage(img)
	fmt.println(lalal)
	new_proc() // <- add a new function of first reload
	return rl.LoadTextureFromImage(img)
}

// gets added on first patch run and prints v1 on the second patch v2 new_proc should print v2



new_proc :: proc() {
	//fmt.println(lalal)
	//fmt.println("v2")
}


@(post_patch_hook)
on_reloaded :: proc(changed: []livepatch.Type_Change) {
	state.reloads += 1
	fmt.println(len(changed))
	for t in changed {
		fmt.println(t.old)
	}
}






































prime_widgets :: proc(ctx: ^mu.Context) {
	if rl.GetTime() < 0 {
		_ = mu.button(ctx, "")
		v: mu.Real
		_ = mu.slider(ctx, &v, 0, 1)
		b: bool
		_ = mu.checkbox(ctx, "", &b)
		buf: [1]u8
		n: int
		_ = mu.textbox(ctx, buf[:], &n)
		_ = mu.header(ctx, "")
		mu.text(ctx, "")
	}
}