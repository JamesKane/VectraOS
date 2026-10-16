# Hardware support

What VectraOS runs on, and how sure we are of it. The list is
[`support.tsv`](support.tsv), one row per platform or component; this
file says what its levels mean and how a row moves between them. The
rules are D66's (`docs/decisions/D066-hardware-support-levels.md`). Facts
about a board, its addresses, buses and quirks, stay in its notebook in
`docs/boards/`.

## Levels

A level is a promise, and each is defined by the evidence behind it, not
by how far along the work feels.

| Level | Meaning | Evidence |
|---|---|---|
| research | Looked at, unscheduled | A roadmap research track or a decision |
| planned | Scheduled, no code yet | A decision and a milestone |
| development | Bring-up code in the tree, exit not yet passed | The code's paths; a model or QEMU test where one exists |
| experimental | Passed its exit at least once, no recurring check | A recorded pass: commit, date, tests |
| supported | A regression is a failure | A running check: `vx ci` for QEMU, a fresh recorded pass for a board |
| deprecated | Works, scheduled to go | A decision naming when |
| retired | Removed | The decision; the row stays |

These are levels, not tiers. Tier 0 and tier 1 are the toolchain's
(D47); the `tier1` column says where tier 1's programs run.

## The columns

| Column | Holds |
|---|---|
| `id` | A short name, unique in the file. QEMU platforms' start with `qemu-`; components start with their platform's |
| `kind` | `platform`, or `component`: a device or function a platform needs |
| `parent` | A component's platforms, comma-separated; `-` for a platform, or a device that fits any host (a GPU, an M.2 card) |
| `arch` | `amd64`, `arm64`, `rv64`, or `all` |
| `level` | One of the seven above |
| `required` | For a component: `yes` if its platform's exit needs it (below) |
| `milestone` | The roadmap milestone that brings it up, `open` when its decision leaves that open, `-` for research |
| `decision` | The decisions that name it, comma-separated |
| `tier1` | For a platform: `yes`, `no` or `deferred` |
| `gates` | Gates that must pass before it rises above development (below) |
| `evidence` | The tests that check it (ctest names, or `vx test ARCH` for all of one arch's), or for development the code's paths |
| `last_pass` | A board's last recorded pass, `commit date`; QEMU rows leave it to `vx ci` |
| `notes` | One line; detail goes in the board's notebook |

`-` means none. The file is tab-separated, with the header as its first
line.

## Required components

A platform's level is at most that of its required components: those its
milestone's exit needs. On a board that is the console, SMP, interrupts,
the timer and the network device of V3's link (V4's and V4b's exits run
V3's commands against the board). On QEMU, today, it is the console,
SMP, interrupts and the timer, which `vx ci` boots with; virtio-net joins
them when V3 lands, since V3's exit runs in QEMU. A platform whose
required components are not all named yet (the Mac Pro's network chip is
read on the machine) cannot rise past planned until they are.

## Gates

A gate is a safety condition with a test of its own. It is listed on the
platform and on the components it protects, and none of them rises above
development until the test passes.

| Gate | Passes when | From |
|---|---|---|
| `fan-fail-safe` | With the SMC driver stopped, crashed or given a sensor that reads 0 or nothing, the fan goes to its safe speed or the machine powers off; a missing sensor reads as hot | D63, `docs/boards/macpro6-1/` |

## Health

Only a person changes a level. Health is worked out from the evidence and
shown beside it:
- `supported (failing since <commit>)`: the last check failed.
- `supported (stale)`, for a board: its last recorded pass is older than
  the last commit touching `boot/`, `kernel/`, `lib/` or that board's
  drivers. Freshness is counted in commits, not days, so a quiet week
  doesn't make a board stale and a kernel change does.
- `experimental (stale)` the same way, as a hint that the board needs a
  run.

## Moving a row

- **Up:** the change that raises a level carries its evidence: the code
  for development, a recorded pass for experimental, the running check
  for supported. A milestone's exit names the changes it makes (V4: the
  Q8B to experimental; V4b: the RV2). A board becomes supported once `vx
  remote test` runs against it as a routine.
- **Down:** never in the change that would fail its check (principle
  15's rule for budgets). A failing supported row is fixed, or demoted in
  a commit of its own with a roadmap entry saying why.
- **Out:** deprecated needs a decision naming when; at that point the row
  becomes retired and stays in the file.
- **Supported means the tests pass.** Budgets on boards are judged by `vx
  bench` as everywhere; making them part of supported would be a later
  decision.

## The tools

`vx hardware` prints the list with health worked out, and `vx hardware
--check`, run by `vx ci`, refuses:
- a malformed row, or an id that appears twice;
- a decision or milestone that doesn't exist, or a level without the one
  it needs (only research may have neither);
- a development row without code paths, or with paths that don't exist;
- an experimental or supported QEMU row whose tests aren't all in its
  arch's ctest (configure the tree first: `vx build`);
- an experimental or supported board without a `last_pass` that
  `runs.tsv` records, and a supported board that is stale or has no pass;
- a platform above its required components, or past a gate not passed.

The rules live in `tools/hardware/lib` and are tested hosted
(`HardwareTests`).

## How a row is judged

- **QEMU or a board, by id:** a platform whose id starts with `qemu-` is
  judged by `vx ci`; every other platform by its recorded runs. A
  component goes by its platforms.
- **Evidence:** an entry with a slash is a path (code, for development);
  any other is a test, a ctest name or `vx test ARCH`.
- **Runs:** `runs.tsv` beside this file, one line per board run:

      date<TAB>commit<TAB>platform<TAB>pass|fail<TAB>tests

  `tests` lists what passed, gates included (a gate passes when a pass
  of its platform lists it). Lines starting with # are comments. It is
  written by the tool that ran the check, `vx remote test BOARD --record`
  (V3 and V4), never by hand; until that exists there are no runs, and no
  board can rise past development.

## Open

- **Milestones not yet set:** the Mac Pro (D52, D63), the desktop GPUs
  (D62, whose track's start is open), and the IvyBridge and cortex-a76
  floor runs (D52, D53, which name the change but not when). They are
  `open` until the roadmap places them.
- **The RV2's firmware path** (D51) must be decided before V4b starts.
