# D81. The environment is /env (2026-10-16, decided)

A process's environment is a list in its Startup (D65), and rc keeps it
as 9front's Unix port does (lists joined by ^A, functions as
`#()fn name {...}`, taken at start). So `rfork e` and `E` ask nothing:
there is no environment group to share or copy. Plan 9's environment is
a file tree, `/env`, one per environment group.

- **The launcher serves `/env`**, one tree per group: a file per
  variable. It makes each service's group from its manifest's `env`
  lines and hands the tree as a namespace mount (PA_NS_DIR, D65); the
  Startup carries no environment list. `use env` grants `/svc/env`,
  whose `new` makes an empty group. (Not a service of its own: the
  launcher would then wait on it to start anything, and what starts
  before it would have no `/env`.)
- **rc stores variables as Plan 9's rc does:** a list's elements
  separated by NUL in `/env/NAME`, a function in `/env/'fn#NAME'`. The
  Unix port's ^A and `#()` encodings go. A child shares rc's group
  unless `rfork e` (a copy) or `E` (a new, empty group) says otherwise,
  as in Plan 9 (RFENVG, RFCENVG); `rfork`'s `E` stops being Updenv's emulation.
- **Reads are on demand.** Sys's `getenv` opens `/env/NAME`; tier 1's
  libc builds `environ` from the tree on its first use, not at start,
  so spawn → main (< 200 µs, V2's exit) pays nothing for an environment
  it doesn't read (D80).
- **On Linux** (rc's host build and the oracle, D70), rc keeps 9front's
  Unix encoding, since there is no `/env` there; the device and the
  oracle differ only in where the environment lives.

## Built (2026-10-16)

- `EnvGroups` (system/launch/lib/Env.swift) serves the groups on a
  dispatcher and thread of its own, since a `/svc` tree forwards walks to
  `/svc/env` from the launcher's. A group goes when its last channel
  closes (`NodeTree.lastClosed`). `env` is no service's name, and is
  granted only with `use`.
- Node's `Namespace` reads (`environment`, `getenv`) and writes
  (`setEnvironment`) `/env`'s files.
- rc reads `/env` at start and, before each program, writes what changed
  (plan9.c's Vinit and Updenv); its programs share its group, and it
  writes `$PWD` there before each, since its forks have directories of
  their own. `rfork e` and `E` mount a new group from `/svc/env/new`
  in a copy of rc's namespace, so they make the namespace rc's own as
  `rfork n` does. The Unix encoding stays where there is no `/env`.
- Tier 1's `getenv` reads `/env`, but for `SWIFT_*`: the Swift runtime
  reads those inside a `swift_once`, where Swift code can't run, so they
  come from the boot options.
- The processargs message's environment list holds only the kernel's
  boot options, which userboot gives the program it starts (Sys's
  `BootOptions`: the launcher's `launcher.until`).
- Left: tier 1's `environ` is not built from `/env`. A C global can't be
  filled on first use, and filling it at start costs what this decision
  avoids. It stays the boot options' (empty for a launched process)
  until a program needs it.
