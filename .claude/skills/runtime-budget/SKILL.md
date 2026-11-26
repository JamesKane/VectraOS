---
name: runtime-budget
description: Estimate a run's time before launching it, and keep suites, checks and benches inside the project's limits. Use before starting any test suite, mutation or model-checking run, bench, soak or loop of boots, and when designing a new check.
---

# Runtime budgets

The owner's rule: a run that takes hours gives no practical feedback.
After a mutation run estimated at about 5 hours was launched, the owner
said: "There are absolutely zero benefit to a five hour test suite.
Delete all that if it can't be brought under 5 minutes."

The project's own limits (CLAUDE.md, D88):

- No arch's QEMU run may take over 5 minutes.
- During a milestone, run `vx test --changed` for what the change risks,
  not the full suite. `vx ci` on every arch closes a milestone.
- A check that flakes is removed, not retried.

## Before launching

1. **Estimate.** Multiply one run's time by the count. Take one run's
   time from its last log (`build/vx/<step>.log`) or ctest's timing, or
   time a single run first.
2. **Over about 5 minutes?** Don't launch. Shrink the run (fewer cases, a
   smaller corpus, `--changed`), or ask the owner, giving the estimate.
3. **A new check** is designed with a time bound from the start, no
   longer than RingCheck's 92 s. Don't add tests that slow an existing
   suite.
4. **Long but agreed runs** go in the background, with the estimate in
   the report, and an explicit `# budget-ok: <reason>` comment on the
   command. That comment is what the hook below lets through.

The brimstone merge gate (`vx test --changed amd64 arm64`, about 15
minutes over two arches) and a board run (11 minutes at most) are within
budget.

## Waiting

- Wait on a pid (`while kill -0 $pid`), on a log's last line, or with
  `run_in_background`.
- Never wait with `until ! pgrep -f PATTERN`. The waiting shell's own
  command line contains PATTERN, so the wait never ends. 21 such loops
  were once found 2 to 3.5 hours old.
- Give every wait a deadline. When it passes, look at why, rather than
  extending it.

## The hook

`.claude/hooks/runtime-budget.sh` runs before every Bash command. It
refuses only clear cases:

- `pgrep -f` waits;
- `ctest --repeat` and other retry-until-pass loops;
- loops of five or more suite, boot or bench runs;
- an explicit `timeout` over 30 minutes on a suite or bench.

Anything else runs. If it refuses something the owner agreed to, add the
`# budget-ok:` comment.
