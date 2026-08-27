package pkgd

// This package is NOT edited by the reload. Its object must therefore NOT be re-emitted
// (incremental emission), yet its value must still be reachable (resolved from the exe).
value :: proc() -> int {
	return 1000
}
