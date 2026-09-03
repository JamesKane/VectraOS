/*
Floating-point state held live across preemption, for the scheduler's
self-test.

`docs/TESTING.md` records why this is assembly at all. An unoptimised build
spills every temporary to the stack. A check written in Odin passed with the
FXSAVE removed, because the values it compared were never in a register.
Only code that pins XMM registers and spins inside itself can observe
whether the trap tail saves them.

**And why it is a file rather than a template.** The spin needs a label to
branch back to. A template's label reaches LLVM without its colon in this
compiler. The block then assembles to nothing, and the thread runs off the
end of it. `fpu_hold.S` is the same loop, and clang assembles it. The four
registers are the callee's to trash under System V, so nothing of the
caller's is living in them across the call either.
*/
package amd64

foreign {
	vectra_fpu_hold :: proc "c" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) ---
}

// fpu_hold loads four XMM registers from `value`, spins until `flag` while
// counting rounds in `counter`, and writes the sum of the four to `out`.
fpu_hold :: proc "contextless" (value: ^f64, flag: ^bool, out: ^f64, counter: ^u64) {
	vectra_fpu_hold(value, flag, out, counter)
}
