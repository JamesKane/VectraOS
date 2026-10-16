# D73. Node gains wstat: a node renamed in its directory, given a time, or cut (2026-10-16, decided)

Plan 9's touch sets a file's time, mv renames a file within its
directory, cp -x keeps a file's time, and create on a file there cuts
it, all through wstat. Node had none of it: a node's name and time were
the server's alone, and only the fs protocol renamed (Directory.rename,
for a volume), so the shell's commands couldn't do what 9front's do.
- **Node version 4 adds `@since(4) func wstat(_ change: Wstat)`, Plan 9's
  wstat on the channel's node:** `Wstat`'s fields `name` (a new name in
  its directory, none other there of it), `modified` (nanoseconds since
  the epoch) and `size` (a file cut, or grown with zeros), each nil to
  leave it, as nulldir's "don't touch". All of it is done or none.
- **NodeTree serves it:** a node a client made may be renamed and given a
  time; a file it may write, a size; anything else is `denied`,
  `unsupported` or `isDirectory`. Its directory's watchers hear one name
  go and the other come. `Namespace.wstat(path, change)` asks.
- **The fs protocol's `Directory.rename` stays,** for moving between
  directories of one volume, which Plan 9's wstat can't: mv tries it
  there before copying.
- **Left out:** modes, owners and groups, which Node doesn't have, and an
  access time.
- **Rejected:** the fs protocol alone (touch, mv and cp -x would work only
  on a volume that speaks it, none before Taisce, V3); leaving the gap.
