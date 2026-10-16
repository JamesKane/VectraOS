# Principles

These rules are normative. A change that breaks one needs a dated entry in
[decisions/](decisions/) explaining why. They merge NeoVectra's thirteen
rules (`NeoVectra/docs/00-overview.md` §2) with todhchai's twenty-nine
principles (`todhchai/docs/principles.md`). Where the two disagreed, the
decision log says which side won.

## A. One way

1. **One mechanism per job.** Never add a second layer that wraps the first:
   no compatibility shims, portability layers or abstractions over
   abstractions. Adding a mechanism means removing or refusing another. When
   two of our earlier projects solved the same problem, we keep one solution
   and delete the other. (NeoVectra rule 13)
2. **The base system fits in one head.** Every component publishes its line
   count, and a check enforces the total (see performance.md, "Size"). If one
   person cannot understand the first-party base system, it is too big.
3. **Every layer must pay rent.** A layer exists only if it makes something
   measurably faster, safer or simpler for the programs above it.
   (todhchai 6)

## B. The data plane and the control plane

4. **The kernel is a setup engine.** It creates address spaces, threads and
   scheduling contexts, capabilities, shared regions, notifications and IRQ
   delivery. Anything that could run as a process does. Bulk data never
   passes through the kernel. (vision; NeoVectra 1)
5. **Nodes are for control and discovery; rings are for bulk.** Every
   service is a node in the namespace, so it is browsable, scriptable and
   reachable over the network. A service may also offer rings for its hot
   paths, but a ring is never the *only* way to reach it. (NeoVectra 2,
   todhchai 7)
6. **One ring format.** Every bulk path uses the same SPSC ring: input,
   audio, frames, packets, blocks and tensors. The ring is defined in
   architecture §3, and nothing else defines one.
7. **One wire format.** Channel messages and structured ring payloads use the
   IPC wire format, which is little-endian, aligned and decoded in place.
   There is no JSON, protobuf or FlatBuffers on the device.
8. **One buffer currency.** A buffer is a VMO plus a format descriptor plus a
   timeline fence. The CPU, GPU, NPU, display, video, network and disk all
   exchange exactly that. (NeoVectra 7)

## C. Time and threads

9. **One wait for everything.** A thread waits on one port. Ring doorbells,
   IRQs, timers, child exits, window events, frame clocks and file changes
   are all delivered into it. (NeoVectra 4, todhchai 2)
10. **Time is an absolute deadline plus a leeway.** There are no relative
    sleeps and no timer-resolution knobs. (NeoVectra 5, todhchai 3)
11. **Threads declare intent, never priority.** The intents are `frame`,
    `interactive`, `throughput`, `background` and `realtime(period, budget)`,
    and realtime is admission-tested. A program that needs whole cores
    reserves them. (NeoVectra 6, todhchai 5)
12. **Batch by default.** Hot interfaces take arrays with counts.
    Single-item calls are for cold paths. (NeoVectra 11)

## D. Contracts

13. **Performance numbers block releases.** Every promise is a budget with a
    target, the milestone that first enforces it, and a running check. "A
    budget with no check running is not a budget." (todhchai 9)
14. **The tool that measures is the tool that explains.** Budgets are read
    from trace events. A failing run keeps its trace.
15. **A budget is never loosened in the same change that would otherwise
    fail it.**
16. **v1 promises are permanent, so v1 promises little.** Every protocol
    supports capability queries from its first version. (todhchai 14,
    NeoVectra 9)
17. **Errors are values.** Swift APIs use typed throws. The C ABI returns
    status codes. (todhchai 13)

## E. Data you can see and query

18. **Files carry typed attributes, and the file system answers live
    queries.** This is BeOS's database file system, done again in Taisce.
    Spatial window and folder state is stored as attributes, not in
    preference files. (todhchai 15)
19. **The system shows what it is doing.** Every service describes itself
    in its node tree. Every process can inspect its own handles, memory and
    trace. (todhchai 16, NeoVectra 10)

## F. The developer's joy

20. **The platform is a library the app calls, not a framework that calls
    the app.** The app owns its loop. (todhchai 1)
21. **A minimal windowed app takes at most 12 API calls**, and the budget
    checks it. (todhchai 8)
22. **APIs grow out of real programs.** Every SDK surface is designed against
    a reference program that uses it. (todhchai 8)
23. **Debugging and hot reload are OS services**, not IDE features.
    (todhchai 17)
24. **Apps are single files; installing one means copying it.** (todhchai 18)
25. **One front door.** One command, `vx`, builds, boots, tests, benches,
    traces and runs CI. A newcomer runs `vx boot` and sees a desktop.

## G. Ownership and authority

26. **Capabilities, not ambient authority.** A process can name only what it
    was given, and its namespace is its sandbox. (NeoVectra 3, todhchai 20)
27. **Local first.** Nothing leaves the machine, or the user's own swarm,
    unless a policy says so. (NeoVectra 12)
28. **The device runs only our code.** Everything that executes on a
    VectraOS device is first-party Swift or C23, written clean-room. Heavy
    toolchains such as MLIR may run on the developer's host as build tools
    whose output is our artifact format. Vendor firmware blobs that the
    hardware requires are the only exception, and each is listed with its
    provenance. (D4)
29. **Swift first, C23 where necessary.** C23 is for the ABI headers, the
    compiler runtime, trampolines and the few places Embedded Swift cannot
    express. Each such C file names its reason in its header comment.
