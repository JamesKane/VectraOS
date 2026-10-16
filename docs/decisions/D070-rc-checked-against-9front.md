# D70. rc is checked against 9front's rc, a host-only oracle (2026-10-16, decided)

We call our shell rc, so it should behave as rc does. An audit
(2026-10-16) found it far from that: about half of rc(1) works, and the
in-memory tests (RcTests) had passed it anyway, since they check what the
port does rather than what rc does. The oracle is 9front's rc itself.
- **9front's rc, vendored unchanged on the host** (`tools/rc-oracle/9front`,
  from 9front `048f21ab2`, with its MIT licence and NOTICE, and rows in
  IMPORTS.tsv): its own source and its `unix.c` port, with the parser
  bison generated committed beside `syn.y` so that the toolchain's clang
  builds it and nothing else is needed. It never reaches the device: D4
  keeps third-party code off the device, and this decision adds a host
  tool whose output is a verdict, not an artifact.
- **Our side is `rcport`** (`tools/rc-oracle/port`): our rc's library on
  Linux, its programs Linux's, as 9front's unix rc runs them.
- **The corpus is ours** (`shell/rc/tests/oracle`, a script a case, each
  printing what it checks). `vx rc-oracle` runs each through both shells
  in a fresh directory and compares stdout, the exit status and whether
  either wrote to stderr (the messages' text differs).
- **`known.tsv` names what differs today,** with why: `port`, a gap to
  fix (the roadmap's V2 item 6 lists them), or `linux`, an artefact of the
  oracle running on Linux (numeric statuses), which never agrees. A case
  that differs and isn't named fails; so does one named that now agrees,
  so the list is always exactly what is left. `vx ci` runs it.
- **What it can't see** is the device's system layer (`shell/rc/native`:
  relays, stdio rings, bootfs programs); boot-launch's rc run checks that,
  and a device-side test belongs with each fix there (the pipeline bug).
- **Rejected:** the 9front VM as the oracle (a serial console to drive,
  slow and single-client; it's still the reference for Plan 9's exact
  statuses and programs), and expected outputs written by hand (they
  would encode our reading of rc(1), which is what was wrong).
