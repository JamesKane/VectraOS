# Performance contracts

This document is todhchai's `docs/performance.md`, adopted unchanged in
mechanism (D10). Read that file for the full doctrine. Here we restate the
rules, list every budget with the milestone that starts enforcing it, and add
the budgets the edge vision needs.

## 1. Rules

1. **Every promise is a budget:** a target, the milestone that first
   enforces it, and a running check. "A budget with no check running is not a
   budget." NeoVectra's budgets went five milestones without a check and came
   in 1.5× to 35× over.
2. **The tool that measures is the tool that explains.** Every budget is read
   from trace events. A failing run keeps its trace, and `vx trace` opens it.
3. **Once met, a budget is also guarded against regression.** A result fails
   if it is worse than the median of the last 5 recorded runs by more than
   *both* the rule's tolerance and its absolute floor. It also fails if it
   passes the rule's hard limit.
4. **No budget is loosened in the same change that would otherwise fail it.**
   Loosening one is a dated entry in docs/decisions/.

## 2. Mechanism

| Piece | Source | What it does |
|---|---|---|
| `Judge` | `todhchai/tools/bench/lib/Judge.swift` | `Rule{tolerance, floor, window=5, limit?, unit}`, verdicts and a Markdown report |
| History | `todhchai/tools/bench/lib/History.swift` | A TSV per host in `bench/history/<host>.tsv`. `--record` refuses to record on a busy machine. `--accept` records a regression openly. |
| Native scrape | `todhchai/tools/td/NativeCommand.swift` | Boots in QEMU and parses `budget name=X value=V unit=U limit=L` lines |
| Trace | `todhchai/docs/trace-format.md`, croi `Trace/` | One 32-byte LE record `{time, kind, cpu, tid, a, b}` shared by kernel and user space |
| Compile-time contract | `@AudioRenderer`-style macros | Puts `@_noAllocation` on real-time callbacks. A run-time count of retains and allocations backs it up. |
| Hardware runs | new | The Q8B runs the native suite over serial with the same scrape, and keeps its own history file. |

## 3. Budgets

The milestones are those in roadmap.md. Numbers marked *new* are proposals
for the edge vision. All others come from todhchai or croi and were set
against croi.

### Kernel and IPC (V1)

| Budget | Limit |
|---|---|
| null syscall | < 100 ns |
| `channel_call` round trip, with deadline donation | < 1 µs on hardware (KVM: about 1.3 µs, held under 1.6 µs; V1 item 6) |
| cross-core port wake | < 2 µs |
| ring submit + complete, both sides busy (`ring.round_trip`, `ring.kicks`; under a hypervisor, whose host's stalls make a side sleep a few times a run, the kicks are judged against history instead) | < 300 ns, `ring_kicks` = 0 on hardware |
| uncontended futex | 0 syscalls |
| IRQ → driver thread | < 5 µs |
| real-time wake error, p99 | < 100 µs |
| ring throughput, 64-byte slots, cross-core (`ring.per_1000_slots`) *(new)* | ≥ 100 M slots/s on amd64 KVM |

### Boot and processes (V0–V2)

| Budget | Limit |
|---|---|
| kernel → console | < 100 ms |
| spawn → main | < 200 µs |
| shutdown | < 500 ms |
| services RSS (`services.rss`: each service and what it started, private plus its share of shared pages, from the launcher's `memory`; vx bench's services boot) | < 32 MiB |
| idle desktop wakeups over 60 s | 0 |
| idle desktop RSS | < 256 MiB |
| smallest full-Swift program, spawn → exit | < 1 ms, < 8 MiB loaded |
| Q8B power-on → desktop *(new)* | < 3 s (firmware time is reported separately) |

### Bring-up link (V3 in QEMU, V6 on the boards; all *new*)

| Budget | Limit |
|---|---|
| warm boot: `vx remote boot` → cpu answering again, QEMU KVM (`remote.warmboot`, boot-cpu; vx bench's cpu boot) | < 2 s |
| warm boot on the Q8B | < 5 s |
| a 64 MiB copy from `/mnt/term` to the board, virtio-net under KVM (`remote.copy`, boot-cpu; vx bench's cpu boot) | ≥ 100 MB/s |
| the first `vx cpu` call after a cold boot, as the server starts listening, QEMU KVM (`remote.first_call`, boot-cpu; vx bench's cpu boot) | < 500 ms |
| a node's own 64 MiB copy between two memory files through NodeFile (`node.file_copy`, D103; vx bench's services boot) | < 256 ms (≥ 250 MB/s), target 64 ms |
| the same copy on the Q8B over 2.5 GbE | ≥ 100 MB/s (debug builds: tracked, no limit until V6 sets one) |
| `vx cpu`: a line sent → the program's reply on the dev terminal, on-link | < 5 ms p99 |
| `log -f` lag: debuglog write → dev machine | < 50 ms p99 |
| a normal (non-`--cpu`) image's listening TCP ports | 0 |

### Files (V4)

From the services boot's /data, a Taisce volume on a virtio disk (launch-test, vx bench's services boot; D105).

| Budget | Limit |
|---|---|
| cached 4 KiB read: a mapped file's, through FileCache (`fs.read_4k`) | < 5 µs |
| live query update: a change made until its event comes (`fs.live_update`) | < 1 ms |
| fsync, p99 (`fs.fsync_p99`; under QEMU reported, judged on a board, D105) | < 2 ms |
| group commit of 64, p99 (`fs.commit_64_p99`) | < 20 ms |
| 4 lock-free readers of a mapped file (`fs.readers_4_x100`, their time against one's ×100) | ≤ 1.5× the single-reader time |
| a listing of 100k entries through fs(4), warm (`wholeListing`; `fs.list_100k`, where timing is real) | < 100 ms |

### Desktop and apps (V5)

| Budget | Limit |
|---|---|
| Tracker listing 100k entries, warm (moved from V4, D105) | < 100 ms |
| minimal windowed app | ≤ 12 API calls |
| cold start → first frame | < 50 ms |
| terminal key → draw | < 1 ms; on the glass in ≤ 2 frames |
| game-loop frame error against present feedback, p99 (judged in V9, D107) | ≤ 1 ms |
| synth at 128 frames (judged in V9, D107) | 0 underruns |
| editor steady state (judged in V11, D107) | 0 dropped frames, 0 allocations in layout and paint |
| workspace mode switch, tile ↔ space, 20 windows (`desktop.mode_switch`, reported by boot-workspaces, D116; animation waits on motion) | animated, and done within 2 frames of input |
| theme switch: every window following the theme shown in the new one, Platinum Indigo ↔ Neon Tab (`theme.switch`) and a knob turned (`theme.switch_knob`), reported by boot-kit (D119) | ≤ 2 frames of the change |
| every shipped theme, its variants and its knobs' extremes pass `theme check` (`theme.check`, in `vx ci`, D119) | 0 findings |
| a 4K frame of twelve windows composed on the GPU, each shipped theme (`theme.compose.4k.<theme>`, reported by boot-venus under Venus, D121; measured submit to done, the copy to host-visible memory included) | < 1.5 ms (target) |

### Edge (V7–V9, all *new*)

| Budget | Limit |
|---|---|
| 9gate, local loopback 4 KiB Tread | < 50 µs |
| 9gate, LAN 1 GbE bulk read | ≥ 90% of line rate |
| Linux `v9fs` mount of a VectraOS export | passes the 9P2000.L conformance suite in `tests/net` |
| accel: ring → CPU backend dispatch overhead | < 20 µs per graph invocation |
| accel: camera → CDSP → render ring, 1080p frame | 0 CPU copies of pixel data (counted) |
| Wasm interpreter: call into a WASI import backed by a ring | < 1 µs |

### Tracer

| Budget | Limit |
|---|---|
| enabled zone | < 20 ns |
| disabled zone | one load + one branch |
| flight recorder overhead | < 1% |

### Size (enforced from V0)

todhchai had no enforcement for principle 10. Here it is a budget.

| Budget | Limit |
|---|---|
| syscall count | published; the ceiling is set at V1 and only goes down |
| first-party lines per component | published by `vx loc`; growth beyond 10% in one change needs a reason in the commit |
| the manual's parser and renderer (`system/guide/lib`) | ≤ 1,500 Swift lines (D86; `vx loc --check`) |
| `swift_retain`/`swift_release` symbols in tier-0 images | 0 (croi's `CheckNoArc`) |
