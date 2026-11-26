---
name: remote-test
description: Run a branch's tests on brimstone, the Linux test host, through its two locked slots. Use for the merge gate (`vx test --changed amd64 arm64` at a branch's final commit), for any arch this Mac doesn't configure (amd64, rv64), for tier 1 links, and for idlc, which doesn't build on the Mac.
---

# Testing on brimstone

brimstone is the Linux machine that runs the QEMU suites this Mac can't,
under KVM. It has one repository and two slots, and several sessions use
it at once. Always go through `brimstone-run.sh`, beside this file. It
pushes the branch, takes a slot's lock, runs, copies the logs back, puts
the slot back on main and releases the lock. An agent once checked out a
branch on brimstone without the lock and corrupted another agent's run.

## Running

    .claude/skills/remote-test/brimstone-run.sh BRANCH [COMMAND...]

- COMMAND defaults to `.build/debug/vx test --changed amd64 arm64`, the
  merge gate. It takes about 15 minutes.
- COMMAND runs inside single quotes on brimstone, so it must not contain
  one. For anything longer, write a script, `scp` it over and run that.
- Run it with `run_in_background`, redirecting to a log in your
  scratchpad. Then wait on the log's last line, which is always
  `BRIM EXIT <status>`:
  - a number is the command's exit code;
  - `push-failed`, `no-slot`, `no-workspace` and `low-disk` mean it
    never ran.
- The arch logs (`build/vx/<arch>-test.log` on brimstone) come back into
  `build/vx/brimstone/`. Read them yourself before reporting a pass.
- Name the commit the run was at in your report: the branch's tip when
  you started. If you commit again, the run no longer counts.

Never wait with `until ! pgrep -f ...`: the waiting shell's own command
line matches, so the wait never ends. Wait on the log's `BRIM EXIT`
line, or on the background command's pid.

## What the script handles, and why

- **Host name.** The bare name `brimstone` stopped resolving
  (2026-11-23). The script reaches it as `brimstone.local` (mDNS) with
  `-o HostKeyAlias=brimstone`, and pushes the same way. `BRIM_HOST`
  overrides the name.
- **Login shell.** Over a plain `ssh`, brimstone has no `swift` on PATH.
  A stale `.build/debug/vx` then runs and fails in 0 s. Commands run
  under `zsh -lic`.
- **Slots.**
  - Slot 1 is `~/Projects/OS/VectraOS`, locked by `~/vx-brimstone.lock`.
  - Slot 2 is `~/Projects/OS/VectraOS-2`, a worktree sharing slot 1's
    `.cache`, locked by `~/vx-brimstone-2.lock`.
  - A slot whose checkout has been removed (slot 2 was, for space) is
    skipped.
- **Locks.** A lock is a directory with an `owner` file: host, pid, start
  time and branch.
  - A lock whose owner is a dead process on this Mac is broken.
  - Any other lock is waited on, for `BRIM_WAIT_MIN` minutes (60 by
    default). After that the script stops with `no-slot` and prints who
    holds what.
  - Don't break a lock by hand unless you know its owner is gone.
- **Disk.** It refuses to start with less than `BRIM_MIN_FREE_GB`
  (20 GB) free.

## Other jobs on brimstone

- **idlc.** Copy the Swift file over and run
  `.build/debug/idlc --man-out --baseline --update-baseline` there, then
  fix the generated page's `src` path. Run it as a brimstone-run.sh
  COMMAND, so it holds a slot.
- **rv64.** During a milestone rv64 stays out of the gate: use
  `vx test --changed amd64 arm64`. It runs at the milestone's exit, or
  when the change is rv64's own. One session ran `cmake build/rv64`
  before `vx test --changed` on brimstone; do that if vx reports the rv64
  tree out of date.
- **Tier 1 links** take several GB each. Before starting one, tell the
  other sessions and cap `LINK_JOBS`.

## Pushing main

After a merge, main goes to brimstone, never to GitHub's origin unless
the owner asks:

    GIT_SSH_COMMAND='ssh -o HostKeyAlias=brimstone' git push brimstone.local:Projects/OS/VectraOS main
