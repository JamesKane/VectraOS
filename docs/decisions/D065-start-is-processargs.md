# D65. A process's start is its processargs; todhchai's Startup protocol is not lifted (2026-10-16, proposed)

todhchai's launcher hands each process a channel serving `Startup`:
`info()`, then `mount(i)` once per mount, `export()`, `board()` and
`ready()`. That is a second mechanism beside processargs, which already
carries a process's handles, arguments and environment, and it costs a
round trip per mount before `main` gets anywhere (V2's budget: spawn to
main under 200 µs). It can't become one call either: a reply's vector
can't carry handles (D54), since Embedded Swift can't hold `~Copyable`
values in an Array.
- **The start is one message.** Sys's `Startup` is processargs as a
  value: arguments (its name first), handles each with an info word,
  and the names table, which processargs has always had and croi left
  unused. (Its environment list, since D81, holds only the kernel's
  boot options, which userboot gives its program: a process's
  environment is its `/env`.) A parent builds one and `Process.start`
  moves it in.
  Natively it is the bootstrap message (the floor now keeps the names
  table), and a process reads its own as `Startup.current`; hosted, the
  program's entry is given it, so hosted and native services read their
  start the same way.
- **The namespace is PA_NS_DIR handles,** as Fuchsia's is: each a Node
  channel, its argument indexing the names table for the path it is
  mounted at, with the union placement (replace, before, after) and
  `create` in the argument's high bits. `Namespace(startup)` builds it.
- **What a process serves and posts are handle types too:** its own Node
  tree's server end (Fuchsia's PA_DIRECTORY_REQUEST) and, with `srv`,
  the session board's client end.
- **Readiness is answering.** An exporting service is ready when it
  answers a batch on its export: the launcher opens its root from the
  export, with a deadline, to mount it in the /svc trees of those that
  use it. Clients' requests queue in the channel meanwhile, so nothing
  needs a separate `ready()`.
- **Left behind for now:** `seal` (a process's own guard against its
  libraries mounting what they're handed; it can come back as an info
  word's bit) and the per-client services' `grant` (the keyring's, M6k).
- **The loader is userboot's,** shared: `user/lib/loader`'s Program
  places a static PIE, maps its segments, makes RELRO read only and maps
  its stack, for userboot and for Sys's `Process.start` alike (Sys's
  Loader module; Ld uses its Bootfs and Segments).
