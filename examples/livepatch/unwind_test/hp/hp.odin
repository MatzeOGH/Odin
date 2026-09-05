package hp
// Base version: deep() reaches capture() with NO intermediate hot frames.
// (After the reload it threads through h1..h6 — see run.ps1.)
deep :: proc(capture: proc() -> int) -> int { return capture() }
