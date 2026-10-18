# Tracing

Zones, flows, counters and marks, hosted and on croi.

## Tracing

`Trace` (system/trace) records zones, flows, counters and marks in the format
of `docs/trace-format.md`, the same records croi's kernel writes, each
thread's in a trace ring on the one ring (D50). Hosted, a program records
into `$TODHCHAI_TRACE/<pid>.trace`; read the result with:

    .build/debug/vx trace summary DIR        # also: print, diff A B

On croi, `TraceSession` (system/trace/session) records the kernel's rings and
a region per process (given in processargs); the files come out over the
debuglog, and `vx trace collect CONSOLE DIR` reassembles them from a boot's
console for `vx trace summary DIR`, which also reads them as one timeline
(calls through croi). `bin/trace-test` (the boot-trace test) is one such
recording. The console carries ~110 KB/s: keep recordings small.

A node's profile goes another way (D102): proc(4) serves the kernel's
trace at `/proc/trace` with its samples, trace(8) copies the recording
and the processes' mappings to `/mnt/term` in a cpu session, and

    .build/debug/vx trace profile DIR        # also: vx remote trace NODE SECONDS

names the samples from the build (`reader/Profile.swift`, and
`tools/image/lib/Symbols.swift` for the ELFs).
