# IPC protocols

`@IPCLibrary`, idlc, and the wire format's runtime.

## IPC protocols

A library is a Swift file with an `@IPCLibrary` enum holding structs,
enums and protocols (architecture §4, `docs/wire-format.md`); the macro
generates each protocol's client, handler, server and events inside it.
After changing one, regenerate its C header (one per library), its
protocols' pages and baselines, and commit them:

    .build/debug/idlc --c-out DIR --doc-out DIR --baseline DIR FILE      # check
    .build/debug/idlc ... --update-baseline FILE                         # record

`idlc` exits 1 if the change would break a client of the recorded
baseline. A protocol composes others by naming them as it would inherit
(`protocol Directory: NodeIPC.Node`, FIDL's `compose`); for another
library's, pass its file to idlc with `--with system/node/lib/Node.swift`. A
composed client lends its connection for another library's calls:
`dir.node { (c: inout NodeIPC.NodeClient) throws(...) in try c.walk(names) }`.
A public library's structs that other modules build need an explicit
public memberwise `init` (labels as the fields, in order). The test library's outputs live in `system/ipc/tests/{c/generated,docs,baselines}`.
Calls go through `channel_call` and record FLOW records with croi's flow
ids (category `ipc`).
