# The launcher

Manifests, jobs and processes, each process's namespace, restarts.

## The launcher

`system/launch/lib` reads manifests (one directive a line, documented at
the top of `Manifest.swift`), starts a job and a process per service with
only what the manifest grants, and restarts by policy. Lifted from
todhchai and cut to the core: apps, scripting, the tracer, the Inspector's
views, per-client services, `seal` and power control are not lifted
yet.

A process's start is its Startup (D65): its arguments (its service's name
first) and its namespace as PA_NS_DIR handles, each a Node channel named
in processargs's names table, with its union placement and `create` in
the info word. Its environment is its `/env` (D81): a group the launcher
serves, made from its manifest's `env` lines; `use env` grants
`/svc/env`, whose `new` makes another. An exporting service is given its
export's server end, and with `srv`, `/srv` and the board to post to
it. Every process is given the UTC page to read (D48), which the floor
maps; a `clock` service gets it writable too. A service reads it first thing:

    let start = Startup.current
    let ns = try Namespace(start)
    try tree.serve(start.export()!)

There is no Startup protocol and no `ready()`: an exporting service is
ready when it answers on its export, which the launcher asks (bounded by
`readyTimeout`) before starting what uses it. A process's `/svc` is a
tree the launcher serves for it, holding only the services it uses, each
forwarding to the service's current instance; after a restart, opening
the path again reaches the new one.

## Natively

`bin/launcher` (`system/launch/launcher`) is the program userboot starts
(`userboot.next=bin/launcher`): its programs are bootfs's `bin/NAME`, its
manifests bootfs's `etc/manifests/*.manifest`, and `launcher.until=SERVICE`
on the kernel's command line makes it exit with that service's code.
Programs load through Sys's `Process.start`, userboot's loader (D65).
The bootfs service (`services/bootfs`, D71) serves the image as a tree; a
manifest that starts programs mounts its bin/ at /bin (`mount /bin
bootfs/bin`), and starts what it finds there.

## Tests

`LaunchTests` (hosted) check manifests and their errors, what each process
is granted, unions, restarts and reconnecting through `/svc`, the
launcher's own tree, restart policies and `/srv`, with
`TreeService.swift`'s service. Natively, the boot-launch test boots the
launcher with `tests/native/manifests` (services `a` and `b`, which are
`bin/launch-service`, the same service) until `bin/launch-test` ends:
it reads every `/svc/*/status`, reaches `a` through `b`, kills `a` through
`/svc/launcher/ctl` and reaches its next instance by the same paths.
