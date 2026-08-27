package pkgc

import b "../pkgb"

// Two-hop chain: pkgc -> pkgb -> pkga, all three patched in one reload. Edited
// `+ 100` -> `+ 200` by the reload.
value :: proc() -> int {
	return b.value() + 100
}
