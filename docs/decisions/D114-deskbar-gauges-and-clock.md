# D114. Deskbar wakes only when something it shows changes: its gauges read files answered on change, sampled only while someone is at the desktop, and Radharc draws the clock (2026-10-22, decided; extends D84, D107, D111)

todhchai's Deskbar polled its gauges once a second and woke each minute
for its clock: 15.4 wakeups a second on an idle desktop, against the
budget "idle desktop wakeups over 60 s: 0" (`docs/performance.md`).
V5's step 4 ports Deskbar (D107), so the gauges and the clock are
settled first. The owner chose Radharc drawing the clock (2026-10-22),
to be reworked if it doesn't fit.

## Decided

- **A gauge's source answers a read only when its value changes**
  (D84). Node's `changing` node is one mechanism for all of them: each
  channel opened at it is answered at once with the text, then a read
  waits until the text differs from what that channel last read. The
  service says when the text may have changed (`ready`); hysteresis
  lives in how it rounds. Deskbar reads each source on a thread that
  waits in that read, so an unchanged value never wakes Deskbar.
- **The gauges here are CPU and PACING.**
  - CPU is proc(4)'s `/proc/cpu`: `busy N`, the percentage of the
    online CPUs' time not idle over the last second. proc samples the
    kernel's per-CPU idle times (the system resource's INFO range,
    granted by a manifest's `info`) once a second, and only while a
    channel is open at the file. The text changes when the value moves
    5 points from the last one given.
  - PACING is Radharc's `pacing`: `p99 N`, the 99th percentile of the
    latch's lateness over the last 120 latches, in microseconds. The
    text changes when it moves 100 µs. It is computed at latches, so it
    costs nothing while the screen is still.
  - GPU and AUDIO come with the GPU (step 6) and an audio service; the
    "in use" rows come with Radharc's gated capture and inject.
- **The gauges are sampled only while someone is at the desktop.**
  Radharc's `idle` file says `active` or `idle`, as a `changing` node:
  `idle` once 10 s pass with no key or pointer input, `active` at the
  next input. Deskbar keeps `/proc/cpu` open only while it reads
  `active`; closing it stops proc's sampling. The idle deadline rides on
  Radharc's latch thread's one wait, armed only after input, so an idle
  desktop has none. The lock screen and display blanking will use the
  same file.
- **Radharc draws the clock.** A window gives Radharc an area of its
  content and a format (`showClock`, Window protocol version 8; an
  empty area takes it away). Radharc draws the time there in the
  theme's `deskbar.clock` style, right-aligned: UTC, as `HH:MM` or
  `h:MM AM`. The next minute's image is drawn ahead on Radharc's frame
  drawer thread. The latch thread's wait takes the minute's start as a
  deadline, and that frame swaps the image in and damages only the
  clock's area. Deskbar sets the area and follows `Deskbar:Clock24`, and
  never wakes for the time.
- **The clock's minute is Radharc's one wakeup on an idle desktop.** It
  changes the screen, so it is a frame, not idle work. Radharc's
  `status` counts the clock's frames (`clocks N frames N`) apart from the
  rest, so the idle measure can leave them out. That measure counts the
  wakeups that draw nothing new.
- **Apps are the launcher's.** A manifest's `app NAME` makes its service
  an app: not started at boot, listed in `/svc/launcher/apps`
  (`SERVICE<TAB>NAME<TAB>running|stopped<TAB>app|preferences`), and
  started by `start SERVICE` on `/svc/launcher/ctl`. `preferences` puts
  an app in Deskbar's Preferences submenu. Tracker's add-ons read the
  same list.

## Not chosen

- **Deskbar's own minute thread** (todhchai's). It is a wakeup a minute
  in a second process, with a redraw and a present. Radharc composes
  that frame anyway.
- **Leaving the clock out of the idle measure while Deskbar draws it.**
  This hides the same wakeup without removing Deskbar's.
- **Sampling the CPU from Deskbar.** Its thread would wake each second,
  and the counts need the INFO range, which belongs to proc.
- **Sampling whenever a reader waits.** Deskbar always waits on its
  gauges, so proc would wake each second for good.
