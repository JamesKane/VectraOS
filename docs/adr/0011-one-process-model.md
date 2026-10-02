# ADR-0011: One process model, served as files

Status: accepted, 2026-10-01. `posixd` is folded into `procfs`. Amends 01 §2 and §9, 02 §5.1 and 05 §3.

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

- **`procfs` holds the one process table, and `posixd` goes away.** Every process, native or POSIX, has a pid. It is assigned at spawn and kept across `exec`.
  - The kernel task id is an internal detail, shown in `status` as `task=`.
  - Each process has a parent, a note group, and a session id.
- **Spawning registers the child with `procfs` before it runs**, as step 3b does for `posix_spawn`.
  - This is the one channel call: it carries the child's task handle, with `DEBUG` and `SIGNAL` rights, which only a channel can carry.
  - `exec` registers the new task under the same pid. `procfs` then drops the old task without reporting an exit.
  - Everything else about processes is a file.
- **Files under `/proc/N`, evolved from Plan 9's set:**

  | File | Contents |
  |---|---|
  | `status` | One ndb record (D14): `pid= ppid= task= name= state= noteg= sid= threads= mem=` |
  | `ctl` | Plan 9's verbs: `kill`, `stop`, `start`, `hang`, `noteg N`, `setsid`, and `intent` (rule 6) |
  | `note`, `notepg` | Writes post a note (ADR-0010) to the process, or to every process in its note group |
  | `wait` | Reads block until a child ends, then return one ndb record: `pid= status="…" utime= stime= real=` |
  | `ns` | The namespace group's table, as namespace(6) lines (ADR-0009) |
  | `args`, `fd/` | As 02 §5.1 lists them |
  | debug files | As 05 §3 lists them |

  `status` stays an ndb record rather than Plan 9's fixed-width text. That is the evolution D14 already chose.
- **Note groups are POSIX's process groups.** `killpg` writes `notepg`, as APE does. A session id is the one POSIX idea Plan 9 lacks. It is a small field in the same table, set by `ctl setsid`, so that job control (step 4c) has somewhere to live.
- **The back end's process calls become file operations:**
  - `getpid` and `getppid` read `status` once, and cache it.
  - `kill` writes `note`, `killpg` writes `notepg`, and `setpgid`/`setsid` write `ctl`.
  - `waitpid` reads `/proc/self/wait` and keeps any record for a child it was not asked about, as APE does. `WNOHANG` polls the file through the one port (01 §9).
  - `SIGCHLD` is the note `posix: SIGCHLD`, which `procfs` posts to a parent when a child ends, if the parent has a handler for it.
  - Stopping and continuing are `ctl stop` and `ctl start`, still done by `thread_suspend`.
- **Authority does not change.** `procfs` holds the rights it was given at registration. Writing `ctl` or `note`, or opening the debug files, needs a token that names the process (02 §5.1, 05 §3).

## Consequences

- POSIX is a library again, as rule 13 intends. What is left of the personality is musl's back end, `ptyd`, and the `posix` 9Px extension.
- `ps`, `kill`, `wait` and a debugger all work the same way on native and POSIX processes, over 9Px. So they also work on a remote node's `/proc`.
- Steps 3b–3d and 4c are rewritten on top of `procfs`. The process table, job control and the back end's signal machinery carry over. What goes away is the RPC layer between them.
- The `posix_spawn`, exit and `wait` round trip must still come in under 500 µs (00 §8). That is a handful of 9Px operations on a local ring, each about 1 µs.
