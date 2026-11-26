---
name: merge-gate
description: Merge a finished branch into main the way this project does. Use when asked to merge a branch, or when an agent's work item is done and needs landing. Checks the runs at the branch's final commit, reads their logs, merges --no-ff with the house message, pushes main to brimstone, and cleans up the worktree.
---

# Merging a branch

A branch merges only after it passes at its final commit:

- brimstone's `vx test --changed amd64 arm64`;
- a board run, if it touches anything board-test runs.

You check those yourself. Agents have reported board runs made before
their last commit.

## 1. Runs at the tip

1. Find the tip: `git log --oneline -1 BRANCH`.
2. For each run the branch needs, find its log and the commit it ran at:
   - **brimstone:** the remote-test skill's run, for the merge gate. If
     the run was at an older commit, or there is no run, run it now on
     the tip.
   - **The board:** the board-run skill, needed when the branch touches
     vulkan-test, loinnir-test, gpu-test, compose-test or any driver
     board-test binds. A pass under Venus or in QEMU does not stand in
     for the board.
3. Read the logs yourself, not the agent's summary:
   - brimstone: the arch logs in `build/vx/brimstone/`, and `BRIM EXIT 0`;
   - the board: `board-test: passed`, and the tests' end-of-run summary
     lines.

   Note the counts. They go in the message.
4. A check that failed and "passed on rerun" has not passed. A flaky
   check is removed, not retried. Find the cause, or ask.
5. During a milestone, rv64 is left out unless the change is rv64's own.

## 2. Before merging

- **Agent work committed.** A finished agent may have left documentation
  or test-map changes uncommitted in its worktree. Check
  `git -C <worktree> status --short`, and commit what belongs to the
  work.
- **Bookkeeping.** Run
  `.build/debug/vx man --check && .build/debug/vx test --check && .build/debug/vx loc --check`.
  Each of these is part of the change, in the same commit:
  - pages for new or changed behaviour;
  - `docs/risk.tsv` rows for new tests;
  - `docs/unsafe.tsv` for unsafe counts;
  - `IMPORTS.tsv` rows for lifted files.
- **The main checkout's state.** Another session may be using it. Check
  `git status` and which branch is checked out before switching. If main
  isn't free there, merge from a worktree that has main checked out.

## 3. The merge

    git merge --no-ff BRANCH -F MSG

The message is one paragraph:

- `Merge BRANCH (<item>, <D-numbers>):`
- what the system now does, in plain sentences;
- the runs that passed and the commit they passed at.

It ends with the Co-Authored-By line. For example:

    Merge audio-hda (V6f item 3, D179): hda(3), an HD Audio controller and its codec in the audio class, tested on QEMU's ich9-intel-hda with audio-test and the audio service; brimstone's amd64 and arm64 and the board's board-test (79 checks) passed at 445dd288

Use `-F` with a file, so backticks and quotes survive the shell.

## 4. After the merge

1. Push main to brimstone. Push to GitHub's origin only when the owner
   asks.

       GIT_SSH_COMMAND='ssh -o HostKeyAlias=brimstone' git push brimstone.local:Projects/OS/VectraOS main

2. Update the opening of `docs/roadmap.md`, where things stand, if the
   merge changes it.
3. Update the project memory: what merged, at which commit, and what is
   next.
4. Remove the agent's worktree and branch once they are merged and
   clean. Merged worktrees under `.claude/worktrees/` have held tens of
   GB.

       git -C <worktree> status --short          # must be empty
       git branch --merged main | grep BRANCH     # must list it
       git worktree remove <worktree> && git branch -d BRANCH
