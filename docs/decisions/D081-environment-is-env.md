# D81. The environment is /env (2026-10-16, decided)

A process's environment is a list in its Startup (D65), and rc keeps it
as 9front's Unix port does (lists joined by ^A, functions as
`#()fn name {...}`, taken at start). So `rfork e` and `E` ask nothing:
there is no environment group to share or copy. Plan 9's environment is
a file tree, `/env`, one per environment group.

- **An env service serves `/env`**, one tree per group: a file per
  variable. The launcher makes each service's group from its manifest
  and hands the tree as a namespace mount (PA_NS_DIR, D65); the Startup
  carries no environment list.
- **rc stores variables as Plan 9's rc does:** a list's elements
  separated by NUL in `/env/NAME`, a function in `/env/'fn#NAME'`. The
  Unix port's ^A and `#()` encodings go. A child shares rc's group
  unless `rfork e` (a new, empty group) or `E` (a copy) says otherwise,
  as in Plan 9; `rfork`'s `E` stops being Updenv's emulation.
- **Reads are on demand.** Sys's `getenv` opens `/env/NAME`; tier 1's
  libc builds `environ` from the tree on its first use, not at start,
  so spawn → main (< 200 µs, V2's exit) pays nothing for an environment
  it doesn't read (D80).
- **On Linux** (rc's host build and the oracle, D70), rc keeps 9front's
  Unix encoding, since there is no `/env` there; the device and the
  oracle differ only in where the environment lives.
