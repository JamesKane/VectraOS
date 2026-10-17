# D88. During a milestone, test what a change risks; the full suite closes the milestone (2026-10-17, decided)

A full run, the host tests and amd64's and arm64's QEMU suites, takes
several minutes, most of it boots that the change in hand can't break.
Run after every step of a milestone, that time adds up to most of the
work. The owner's call: during a milestone, only the tests a change puts
at risk run; the full suite is the milestone's exit.

- **The map is a file:** `docs/risk.tsv` names, for each path in the
  tree, the arches to build, the SwiftPM test targets, the ctest names
  and vx's checks (man, loc, hardware, rc-oracle, risk) that a change
  under it risks. The longest path matching a file wins. It is reviewed
  like code, not guessed at each time.
- **Unknown is everything:** a changed file no row maps runs the full
  suite and every check, and says which file it was. So does a row that
  says `all`, for the build's own files.
- **Every test has a row:** `vx test --check`, in `vx ci`, fails when a
  path, target or test it names doesn't exist, and when a test target or
  a tested arch's ctest name is named by no row. A row of `all` names
  nothing, so a new test can't hide behind one.
- **`vx test --changed [REF]`** runs the plan for the change since REF
  (`main` by default: committed, staged, unstaged and untracked), and
  `--plan` only prints it. `vx test --only TEST,...` runs named tests.
- **The full suite closes a milestone:** `vx ci` on every arch is the
  exit, with its bench, as before. A map that missed something is
  found there, and fixed in the map.
- An arch whose suite is off by default (rv64 until tier 1 runs there) is
  built for a change to its own code, not tested.

Rejected: running the suites in parallel within an arch, which shortens
the full run but still pays for boots the change can't reach (and
loads the machine other sessions share); and choosing tests by hand
each time, which can't be reviewed and drifts.
