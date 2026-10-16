# D71. Programs come from the namespace: Node's `memory`, and bootfs served at /bin (2026-10-16, decided)

Until now a program could start another only from a bootfs handle it was
given (a manifest's `programs`), by name: rc mapped `/bin/NAME` to
bootfs's `bin/NAME` itself, so only rc saw a /bin, and no other process
could list, read or run what was there. Plan 9's /bin is a directory of
the namespace, built by binding, and a process runs what its namespace
holds. Node had no way to hand over a file's contents as memory, so a
program found in a namespace couldn't be started from it.
- **Node gains `memory(executable:)` (version 3, `@since(3)`):** a file's
  contents as a VMO to read or map, never to write, its first `size`
  bytes the file's, as Fuchsia's `GetBackingMemory`. With `executable`,
  a VMO a process can be started from (or a library loaded from); only a
  server whose files may run gives one, and only if its handle can
  (`denied` otherwise). NodeTree serves it: a memory file (`memory(path,
  vmo, size:, executable:)`) gives its VMO, any other file a copy that
  can't run. `Namespace.memory(path, executable:)` asks for one.
- **The bootfs service (`services/bootfs`, `bin/bootfs`) serves the boot
  image as a read-only tree,** as Fuchsia's /boot: each file at its path,
  a read-only copy-on-write child of the image's VMO, as Fuchsia's
  bootsvc makes them (a slice can't be snapshotted, and the loader
  snapshots a program's writable segments; NO_WRITE keeps EXECUTE). Its
  manifest takes the image with a new directive, `bootfs` (the image
  alone, to serve). It starts early.
- **A manifest mounts its bin/ at /bin** with the existing `mount /bin
  bootfs/bin`. Starting a program is then opening `/bin/NAME`, asking for
  its memory to run, and `Process.start` with it: one way for every
  process, and what /bin shows is what runs.
- **rc starts what its namespace holds:** a program is a file whose
  server gives memory to run (and a `#!` script one whose interpreter is
  one). rc needs a job and its namespace, no longer bootfs; an rc it
  starts gets the same. `rfork N` takes /bin away with the rest, so
  nothing runs, as in Plan 9.
- **Left as it was:** `programs` still gives bootfs with its job, for
  what loads from bootfs directly (the launcher's programs, a future
  devmgr). It can become a job alone once they take /bin too.
- **Rejected:** /bin as a listing only, rc still loading from its bootfs
  handle by name (what /bin shows and what runs could disagree once
  anything is bound there); the launcher serving bootfs itself (it would
  grow a file server beside its supervision); reading a program over Node
  into a new VMO and making it executable (a copy per start, and the
  VMEX resource handed to every starter).
