# ADR-0011: One process model, served as files

Status: accepted, 2026-10-01; revised the same day after checking 9front. `posixd` is folded into `procfs`. Amends 01 §2 and §9, 02 §5.1 and 05 §3.

## Context

VectraOS is Plan 9 evolved, in standard C (00 §1). In Plan 9 there is one process table, with one pid per process. A process keeps its pid across `exec`. Everything about a process is a file under `/proc/n`: `status`, `ctl`, `note`, `notepg`, `wait`, `ns`, `fd`, `args`, `mem` and `regs`. 9front's APE builds POSIX's process calls out of those files.

The code has two process models, and neither is Plan 9's:

- **The kernel task tree, served by `procfs`.** It uses task ids, and serves only `status` and a `ctl` that can only kill.
- **`posixd`.** It holds pids, process groups, sessions, signals and `wait`, all reached by binary `channel_call`s, and serves no files. That breaks rule 2: every service has a file interface. It also contradicts 02 §2's template, which binds `/srv/posixd/proc`.

Because of this split:

- `/proc/N` is keyed by task id.
- `execve` makes a new task (`ports/musl/vx/process.c`), so a process moves to a new `N`.
- The old task exits with status 0, so `gsh` and `svcd` see a false exit.
- Native programs have no pids, no note groups and no `wait`.

## Decision

Checked against 9front (`port/sysproc.c`, `port/proc.c`, `port/devproc.c`, and APE's `wait.c`, `kill.c`, `setpgid.c`, `getpgrp.c`). Each piece below is Plan 9's, moved out of the kernel where a micro-kernel needs it to be.

- **`procfs` holds the one process table, and `posixd` goes away.** Every process, native or POSIX, is in it.
- **A pid is the kernel's task id.** 9front allocates a pid inside `rfork` (`pidalloc`), as part of making the process, and refcounts it so it is not reused while a note group or a parent names it. Here `task_create` already gives every task a 64-bit id that is never reused, so that id is the pid, and nothing needs a refcount. `getpid` is `task_info` on the process's own task, read once, as 9front's reads `_tos->pid`.
- **`exec` keeps the task, and so the pid**, as 9front's `sysexec` keeps the `Proc`. That needs `task_exec` (ADR-0012).
- **Spawning registers the child with `procfs` before it runs.** Here the creator is in user space, so registering is the user-space half of `rfork`. It is the one channel call, because it carries the child's task handle, with `DEBUG` and `SIGNAL` rights, which only a channel can carry. It also names the parent and note group, and says whether the parent wants a wait record (`RFNOWAIT`).
  - `vx-rt`'s spawn does it for every spawner: `gsh`, the musl back end, and through `vx_proc_register` the back end's `fork` and `svcd`. The call goes on `procfs`'s listen channel, the post `/srv/proc`, or the connector the spawner's namespace mounted `/proc` from (lib/vx-proc/proc.h). A service `svcd` started before `procfs` is registered by `svcd` once `procfs` is up; it holds their task handles already.
  - `svcd` registers each service in a note group of its own (`RFNOTEG`), as Plan 9's daemons run, so a note to one group never reaches the rest of the system.
  - A child whose parent asked for no wait record (`gsh`'s, `svcd`'s) runs even if registering fails, so a `procfs` that is gone leaves the shell able to run programs. Any other child is not started.
  - Everything else about processes is a file.
- **Wait records, as in 9front's `pexit` and `pwait`.** When a registered task ends, `procfs` queues a record for its parent, at most 128 per parent, unless the parent spawned it with no-wait. A parent that has gone leaves the record undelivered. `ppid` keeps naming it, as in 9front, whatever the kernel's task tree does.
- **Files under `/proc/N`, 9front's set where it has one:**

  | File | Contents |
  |---|---|
  | `status` | One ndb record (D14): `pid= name= state= threads= mem=`, and `sid=` for POSIX's sessions |
  | `ctl` | 9front's verbs: `kill`, `stop`, `start`, `startstop`, `waitstop`, `hang`, `nohang`; plus `setsid`, and `intent` (rule 6) |
  | `note` | A write posts a note (ADR-0010) to the process |
  | `notepg` | A write posts a note to every process in the process's note group, the writer too: unlike 9front's `postnotepg`, which skips it, because here a note to oneself arrives before the write returns, so `kill(0)` signals the caller as POSIX asks |
  | `noteid` | The note group: read it, or write another group's id to join that group, as 9front checks it |
  | `ppid` | The parent's pid |
  | `wait` | A read blocks until a child ends, then returns one ndb record: `pid= name= status="…" utime= stime= real=`. Its stat length is the number of records queued, as 9front's is |
  | `ns` | The namespace group's table, as namespace(6) lines (ADR-0009) |
  | `args`, `fd/` | As 02 §5.1 lists them |
  | debug files | As 05 §3 lists them |

  `status` and `wait` are ndb records rather than 9front's fixed-width text and `Waitmsg` string. That is the evolution D14 already chose.
- **The back end's process calls become file operations, as APE's are:**
  - `getppid` reads `ppid`. `getpgrp` reads `noteid`, and `setpgid` writes it.
  - `kill` writes `note`. `kill(0)` writes the caller's own `notepg`, which reaches the caller too. `kill(-pgid)` joins that group, writes `notepg`, and goes back, as APE's does.
  - `waitpid` reads `/proc/N/wait` and keeps any record for a child it was not asked about, as APE does. `WNOHANG` stats the file first and returns at once if its length is 0.
  - A note posted to a process blocked in a `wait` read ends that read, so it returns `EINTR`, as a 9front note ends the sleep. `ptyd` does the same with the reads it holds.
  - `SIGCHLD` is the note `posix: SIGCHLD pid=N`, which `procfs` posts to a registered parent when a child ends, stops or continues.
  - Stopping and continuing are `ctl stop` and `ctl start`, done by `thread_suspend`.
- **A POSIX session id is the one idea 9front lacks.** It is a field in the same table, set by `ctl setsid`, so that job control (step 4c) has somewhere to live.
- **Authority does not change.** `procfs` holds the rights it was given at registration. Writing `ctl` or `note`, or opening the debug files, needs a token that names the process (02 §5.1, 05 §3).

## Consequences

- POSIX is a library again, as rule 13 intends. What is left of the personality is musl's back end, `ptyd`, and the `posix` 9Px extension.
- `ps`, `kill`, `wait` and a debugger all work the same way on native and POSIX processes, over 9Px. So they also work on a remote node's `/proc`.
- Steps 3b–3d and 4c are rewritten on top of `procfs`. The process table, job control and the back end's signal machinery carry over. What goes away is the RPC layer between them, and with `task_exec`, `posixd`'s `EXEC`.
- `procfs` holds one connection per process, so vx-9p's limit of 16 connections per server becomes a server's own setting.
- The `posix_spawn`, exit and `wait` round trip must still come in under 500 µs (00 §8). That is a handful of 9Px operations on a local ring, each about 1 µs.
