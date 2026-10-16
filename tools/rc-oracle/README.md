# rc's oracle

Our rc (`shell/rc`) checked against 9front's (D70).

    swift build --product vx && .build/debug/vx rc-oracle [CASE...]

- `9front/` is 9front's rc as it is at 9front `048f21ab2`
  (`sys/src/cmd/rc`, MIT, `LICENSE` and `NOTICE` beside it), built for
  Linux by the toolchain's clang into `.build/rc-oracle/rc` (its own
  `unix.c` port). `syn.c` and `y.tab.h` are the parser bison 3.8.2
  generated from `syn.y` (`bison -y -d syn.y`, then `y.tab.c` as `syn.c`),
  committed so that no yacc is needed. Host only: it never reaches the
  device.
- `port/` is `rcport`, our rc's library on Linux (its programs Linux's,
  as 9front's unix rc runs them).
- The cases are `shell/rc/tests/oracle/*.rc`, each run through both
  shells in a fresh directory under `.build/rc-oracle/work` (there with
  its stdout and stderr), stdin empty. Their stdout, exit status and
  whether they wrote to stderr must agree. A case whose first line is
  `#flags: -e -x` (a comment to rc) is run with those flags.
- `shell/rc/tests/oracle/known.tsv` names the cases that differ today:
  `port`, a gap to fix (docs/roadmap.md, V2 item 6), or `linux`, an
  artefact of the oracle on Linux. A new divergence fails, and so does a
  named case that now agrees: when a fix makes one agree, take its line
  out.

To add a case, write `NAME.rc` printing what it checks (deterministic:
no timing races, no machine-specific output), run `vx rc-oracle NAME`,
and if 9front and we differ, either fix rc or name it in known.tsv with
why.
