/*
odd -- the Odin half of the mixed image, `docs/DEVTOOLS.md` step 0.

One image holds a C `main` and this Odin package. `main` calls
`odin_triple`, which is C calling Odin; `odin_triple` calls `c_inc`, which
is Odin calling C. Both directions link in one image, which is the whole
of what the mixed proof shows. The procedures are `"c"`, so the two
languages meet on the platform's own calling convention.
*/
package odd

// A C procedure `main.c` defines, resolved by the linker with no library.
foreign {
	c_inc :: proc "c" (n: i32) -> i32 ---
}

// odin_triple is called from C. It calls back into C, so the image proves
// a call each way.
@(export, link_name = "odin_triple")
odin_triple :: proc "c" (n: i32) -> i32 {
	return c_inc(n) * 3
}
