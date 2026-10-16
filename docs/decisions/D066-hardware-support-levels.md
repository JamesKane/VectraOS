# D66. Hardware support levels, each with its check (2026-10-16, decided)

What VectraOS runs on is scattered: the boards in D5 and D51, the
baselines in D52 and D53, the GPUs in D62 and D63, the research tracks in
the roadmap, and QEMU only in `vx ci`. A support level is a promise, so
under principle 13 it needs a running check, like a budget.
- **Seven levels, each defined by its evidence:**

  | Level | Meaning | Evidence |
  |---|---|---|
  | Research | Looked at, unscheduled | A roadmap research track or a decision |
  | Planned | Scheduled, no code yet | A decision and a milestone |
  | Development | Bring-up code in the tree, exit not yet passed | The code's paths; a model or QEMU test where one exists |
  | Experimental | Passed its exit at least once, no recurring check | A recorded pass: commit, date, tests |
  | Supported | A regression is a failure | A running check: `vx ci` for QEMU, a fresh recorded pass for a board |
  | Deprecated | Works, scheduled to go | A decision naming when |
  | Retired | Removed | The decision; the row stays |

  They are levels, not tiers: tier 0 and tier 1 are the toolchain's
  (D47), and stay a column of their own.
- **One list, a TSV:** `docs/hardware/support.tsv`, after `IMPORTS.tsv`,
  with `docs/hardware/README.md` for the levels and the rules. Columns:
  id, kind (platform or component), parent, arch, level, milestone,
  decision, tier1 (yes, no, deferred), gates, evidence (test names),
  last pass (commit, date), notes. Board facts stay in `docs/boards/`.
- **Platforms and their components.** A platform (QEMU q35, QEMU virt on
  arm64 and rv64, the Q8B, the RV2, the Mac Pro) has component rows: the
  devices it needs, such as the GENI UART, SMMUv3, TC956x, the SMC fan,
  the D700s. A platform's level is at most that of its required
  components; for Experimental these are the console, SMP, interrupts,
  the timer and the V3 link's network device.
- **Gates.** A platform may carry a safety gate that must pass before it
  rises above Development. The Mac Pro's is D63's: the fan fails safe,
  and a missing sensor reads as hot.
- **Health is derived; only a person changes a level.** A supported row
  whose last check failed shows `supported (failing since <commit>)`; one
  whose evidence is old shows `supported (stale)`.
- **A board's evidence is fresh by commits, not days:** its last recorded
  pass is at or after the last commit touching `boot/`, `kernel/`, `lib/`
  or that board's drivers. Quiet weeks don't make it stale; changes do.
- **Supported means the tests pass, not the budgets.** Budgets on boards
  are judged by `vx bench` as today; making them part of Supported is a
  later, stricter decision.
- **No level is lowered in the change that would fail its check**
  (principle 15's rule for budgets). A failing supported row is fixed, or
  demoted in its own commit with a roadmap entry.
- **The tools:** `vx hardware` prints the list with health derived;
  `vx hardware --check` runs under `vx ci` and refuses a row whose
  decision or milestone doesn't exist, a Development row whose paths
  don't, a supported QEMU row with no ci step, a stale board row, a
  platform above its components, and a gate not passed. Evidence is
  written by the tool that ran the check (`vx remote test BOARD
  --record`, V3 and V4, into `docs/hardware/runs.tsv`), never by hand.
- **The first list:** QEMU q35, arm64 virt and rv64 virt Supported (`vx
  ci`); QEMU `rva22s64` (D51), the Q8B (D5), the RV2 (D51) and the Mac
  Pro (D52, D63) Planned; the GENI UART Development once V3's model test
  lands; the CIX Sky1 (D53), the RK3588 and the Hailo-8 Research; the
  desktop GPUs (D62) Planned, their start still open.
- **Milestones name their level changes:** V4's exit takes the Q8B to
  Experimental and V4b's the RV2; Supported waits until `vx remote test`
  runs against the board as a routine.
