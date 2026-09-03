/*
Counting checks, and remembering the first one that failed.

Seventeen files wrote this by hand, and every one of them wrote it the same
way. A counter, a failure counter, the name of the first failure, and a
procedure that raises one or two of the three. The rule they all keep is worth
stating once rather than seventeen times. **The first failure is the one to
report, because later ones are almost always its consequences.**

A boot log has one line per subsystem, so a run that fails has room for one
name. The first is the right one to keep. A test that opens a file and then
reads it reports `the file opened` rather than `the read came back empty`.
Those are one bug, and the second name points away from it.

## Why this is not in the kernel

`sys/vectra9/verify.odin` runs before anything the kernel offers exists, and it
is the layer under the kernel rather than inside it. A tally that lived in
`kernel/` would be one that half the self-tests could not reach.

Every result struct embeds this with `using`, so `r.checks` and `r.failures`
still read as though they were its own fields, and every call site that reads
them is untouched.
*/
package libodin

Tally :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,

	// The failures after the first, as many as fit. The first is the line;
	// these are the trace beneath it, for the run where the consequences
	// are not obvious from the cause. Names only, and never a substitute
	// for reading the first one.
	later:         [LATER_MAX]string,
	later_count:   int,
}

LATER_MAX :: 40

/*
tally records one check and reports what it was told.

The return value is what lets a caller stop. A self-test that could not open
the thing it tests has nothing to say about it. `if !check(...) { return }` is
how that reads at every call site in the tree.
*/
tally :: proc "contextless" (t: ^Tally, ok: bool, what: string) -> bool {
	t.checks += 1
	if !ok {
		t.failures += 1
		if t.first_failure == "" {
			t.first_failure = what
		} else if t.later_count < LATER_MAX {
			t.later[t.later_count] = what
			t.later_count += 1
		}
	}
	return ok
}

/*
passed reports whether a run may print a green line.

**Zero checks is not a pass.** A self-test that returned before it tested
anything failed at something the failure counter cannot see. A run that reports
`0 checks passed` then looks exactly like a run with nothing to do. Every caller
in the tree wrote `failures == 0 && checks > 0` for that reason.
*/
passed :: proc "contextless" (t: Tally) -> bool {
	return t.failures == 0 && t.checks > 0
}
