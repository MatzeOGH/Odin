package pkgb

import a "../pkga"

// Calls into pkga: when BOTH pkga and pkgb are patched, the fresh pkgb body must reach the
// fresh pkga body (cross-object resolution). Edited `+ 10` -> `+ 20` by the reload.
value :: proc() -> int {
	return a.value() + 10
}
