# D165. Every check shown able to fail: `vx mutate` runs a suite against copies of the tree, each with one named edit that removes a safeguard, and a survivor is reported with why it survives (2026-11-20, the owner scheduled the backlog's B1)

A suite that passes says the code is right only if the suite would fail
on wrong code. RingCheck (D43) shows it can for the ring's wake protocol:
its `broken*` checks drop a fence or relax a publish inside the checker
(`Checker.Mutation`) and must fail. Nothing shows it for the rest of the
ring's safeguards, or for any other suite. The Rust reenvisioning's
review (the roadmap's backlog, B1) found there properties that held of
nothing, a safeguard that changed nothing (the state count the same
without it) and a checker that asked the code under test for the
answer.

## The decision

1. **A mutants file beside each suite** that takes part, named
   `mutants`, in the suite's directory (RingCheck's:
   `lib/ring/tests/Model/mutants`). Its lines, `#` comments dropped:

   ```text
   suite RingCheckTests
   measure ring check:
   mutant swift-publish-relaxed
   in lib/ring/Ring/Ring.swift
   find order: .releasing)
   with order: .relaxed)
   why the producer's publish must release its slots
   survives REASON
   ```

   `suite` names what runs: a SwiftPM test target (later kinds: an
   arch's QEMU test by its ctest name). `measure PREFIX` names the
   output lines that measure a run (RingCheck's `ring check: ... N
   states`). Each `mutant NAME` starts an edit: `in` the path from the
   repository's root, `find` the text, `with` its replacement (`\n`,
   `\t` and `\\` escaped; `with` may be empty), `why` the safeguard it
   removes, and `survives` only for an edit expected to survive, saying
   why that is right.
2. **`vx mutate SUITE [NAME ...]`** (SUITE a mutants file's directory or
   its suite's name) makes a copy of the tracked tree under
   `build/vx/mutate/`, never the working tree, and runs the suite there
   unchanged (a control), then once for each mutant: its edit applied,
   the suite run, the edit reverted. An edit whose `find` doesn't occur
   exactly once in its file is an error, not a pass.
3. **Each mutant ends one of four ways:** *caught* (the suite failed);
   *survived, explained* (it passed and its `survives` says why);
   *survived* (it passed, no reason); *did nothing* (it passed with the
   same measure lines as the control's: the edit changed nothing the
   suite looks at; only for a suite that names a `measure`). The last two
   fail the step, and so does a mutant that doesn't build: an edit that
   breaks the build removes no safeguard the suite could judge.
4. **Controls run among the mutants:** the unchanged suite first, after
   every fifth mutant and last. A control that fails ends the step,
   saying so: on a busy machine a failure is the machine's, not a catch.
5. **Not in `vx ci`.** A milestone's exit runs it, or a change runs it
   by name while working (D88). Each mutants file's suite and paths must
   exist (`vx test --check`). The mutants files are their own risk map:
   `vx test --changed` names the suites whose `vx mutate` a change risks
   (a file under the suite's directory, or a mutant's `in`), without
   rows of their own in `docs/risk.tsv`.
6. **What it writes:** `build/vx/mutate.log` (each run's output), and a
   line a mutant on its output: name, ending, seconds, and the first
   failing line or the reason.

## Not chosen

- **Mutations inside the checker only** (`Checker.Mutation`). They reach
  what the checker models (fences, release orders), not a safeguard in
  the code under test, nor any other suite.
- **Generated mutants** (every operator flipped, every line deleted).
  Most are noise, and the review's finding was about named safeguards,
  each with a reason it must matter.
- **Editing the working tree.** A killed run would leave a mutant
  behind.
