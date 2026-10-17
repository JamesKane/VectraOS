# D99. The launcher answers memory pressure by ending services in bands; a service may start on first use and end when idle (2026-10-17, proposed)

A device has no swap: anonymous memory has nowhere to go but RAM. The
kernel's memory watchdog reports the system's level on the root
account (D31), evicts what is reclaimable, and at OOM reboots after
`croi.oom.reboot_timeout_ms`. Nothing in user space binds that level
today, and the launcher starts every service at boot and keeps it
running. So the only answer to pressure is eviction and then a reboot,
and every service that will ever be used costs memory from boot on.

XNU's answer is jetsam: bands, a limit on each process, killing idle
and background processes before anything else, and launchd starting a
service on its first message and letting it exit when idle, with
processes written so they can be killed. Each part maps onto something
the launcher already has: its `/svc` forwarder, which stands in for a
service across restarts; exit strings (D72); notes (D87); and accounts
(ext 6). This decision adds no kernel mechanism.

- **The launcher holds the root account's PRESSURE binding**, the one
  binding D31 allows. Nothing else acts on the system's level. Services
  that want to know the level read it from the launcher's tree.
- **Each service has an account of its own**, made by the launcher and
  passed as `CROI_PA_MEMORY_ACCOUNT`, so `/svc/launcher/memory` reads
  each service's charge from its account. `memory limit SIZE` in a
  manifest sets that account's limit. Over it, commits fail as they do
  now, and the service learns of it from its own account's pressure.
- **Bands, from the manifest** (`memory BAND`):
  - `essential`: never ended (the launcher, devmgr, the file system,
    kbdfs, the console).
  - `system`: the default, ended only at imminent OOM.
  - `on-demand`: ended first.

  At warning, the launcher asks the `on-demand` services to go. At
  critical, it ends them, largest resident memory first. At imminent
  OOM, it ends `system` services the same way, until the level falls.
  The kernel's eviction and reboot stay as they are, as the last resort.
- **`start on-demand`**: the launcher doesn't start such a service at
  boot. The first walk through any `/svc` forwarder starts it, and the
  walk is held until the service answers on its export, bounded by
  `readyTimeout` as at boot. A `mount` of it starts it the same way.
  `on-demand` services are started this way by default.
- **Idle exit is the service's own call.** An `on-demand` service that
  ends with the exit string `idle` is stopped, not failed: the launcher
  starts it again on the next walk, and such an end doesn't count
  toward the 5-in-30-seconds limit. To ask a service to go, the launcher
  posts the note `idle` (D87). A service with nothing outstanding exits
  `idle`. A busy one takes the note and keeps running. One that never
  asked for notes dies of it, which is the contract: an `on-demand`
  service keeps its state on disk or with its clients, and survives being
  ended at any point.
- **Apps** (V5) take the bands as well. Radharc tells the launcher which
  app has focus, and background apps are ended before any service. That
  ordering is designed with apps, not here.

**Checks and budget.** LaunchTests (hosted) check the manifest
directives, the order in which bands are ended, starting on a walk, and
that an `idle` exit is a stop. The boot-launch test gains an `on-demand`
service that a walk starts, that exits `idle`, and that the next walk
starts again. A new suite drives the root account's level with the test
watermarks (the `memory` suite's hooks) and checks which services the
launcher ends at each level. Two budgets:
- `launch.demand_start_ms`: from the first walk to the answer, for the
  test's service.
- `memory.relief_ms`: from critical to below warning, under the suite's
  load.

Both are reported from when the change lands, with limits set in V6,
on the first board. Their `docs/risk.tsv` rows land with the tests.

**Pages.** manifest(6) gains `memory` and `start`, and launcher(8)
gains the bands, starting on first use, and the `idle` exit.

**Proposed placement:** accounts, bands and `start on-demand` in V3, as
the bring-up link's services (cpu, 9gate, the network stack) multiply
what runs at boot. The pressure policy is checked before V6, whose
boards have 2 to 8 GB of RAM where QEMU has whatever it is given.

Rejected: a pressure service separate from the launcher. Two processes
would decide what runs, and only the launcher knows each service's band
and how to start it again. Rejected: paging anonymous memory to Taisce,
which is swap. It writes flash, adds a backing store to every VMO, and
answers pressure late. Not chosen yet: a compressed tier before
eviction (XNU's compressor; NT keeps compressed pages in a process of
their own). It may follow on its own decision, after V4.
