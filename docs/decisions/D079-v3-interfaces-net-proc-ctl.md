# D79. V3's interfaces are Plan 9's: /net with dial strings, /proc with notes, and ctl files (2026-10-16, decided)

V3 brings in the network, notes between processes and the board tools
(D77). Each had a Unix shape waiting for it: N1's `NetIPC` is BSD
sockets in typed IPC (listen on a port, accept, connect), notes would
become a kill-like call with `ps` and `kill` programs, and warm boot,
power and restarts would be commands. Plan 9 makes each a file tree
that cpu and `import` reach for free. V3 takes Plan 9's.

## The network is /net

- **`services/net` serves `/net`**, as Plan 9's protocol devices:
  `/net/tcp/clone`, and per connection `N/ctl`, `data`, `listen`,
  `local`, `remote`, `status`, `err`; `/net/udp` the same; `/net/ipifc`
  for addresses and `/net/iproute` for routes. Opening `clone` reserves a
  connection, `connect` and `announce` are ctl lines, and reading
  `listen` waits for a call. These are Node control (D64); `data` is the
  connection's bulk, the one ring through Node's `attach` (D67), so a
  stream costs no syscall while it flows. N1's NetRing (TDNR) and
  `NetIPC` are not lifted: the stack is, under the tree.
- **Dial strings.** `dial("tcp!host!port")`, `announce`, `listen` and
  `accept` in Sys, as Plan 9's libc has them, over `/net`; names are
  looked up through `/net/cs` (the connection server) and `/net/dns`,
  never by a resolver library.
- **cpu and import reach a network.** A cpu session can bind the
  terminal's `/mnt/term/net` over its own, as Plan 9's `import -a`
  does; sockets could not. BSD sockets exist only in tier 1's libc,
  over `/net` (D80).

## Processes are /proc

- **A proc service serves `/proc/N`**, for each process its holder of
  the right job may see: `status` (Plan 9's fields), `ctl` (`kill`,
  `stop`, `start`), `note`, `notepg`, `ns` (the namespace as `bind`
  and `mount` lines), `fd`, `args`, `wait`. It reads the kernel's info
  topics and acts through process handles.
- **Notes are posted through `/proc`**: `echo interrupt
  >/proc/N/note`, and `notepg` for a note group, which rc's `rfork`
  then has (its `e`, `f` and `s` no longer ask nothing, D81 for `e`).
  The kernel side, V3's notes item, is a right on a process handle that
  the proc service uses; programs see only `/proc`. The syscall ceiling
  holds (91 calls), or a cut pays for any call it adds.
- **The commands are Plan 9's:** `ps` reads `status`, `kill NAME`
  prints rc commands to pipe into rc (`echo kill>/proc/N/ctl`), and
  `ns` prints `/proc/N/ns`. Debugging over `/proc/N/ctl`, `mem` and
  `regs`, in front of the kernel's debugger channels, comes later and
  is not V3's.

## Power, warm boot and restarts are ctl files

- **`/dev/reboot`**, served by the service holding the power resource
  over `SYSTEM_POWERCTL`, takes ctl lines, as Plan 9 reboots through
  `#c/reboot`: `reboot`, `poweroff`, and `warmboot KERNEL BOOTFS`, whose
  two paths it reads (from `/mnt/term` in a cpu session).
- **Restarts are the launcher's ctl:** `echo restart NAME
  >/svc/launcher/ctl`, as launch-test already kills through it.
- **The board tools are rc scripts** over these files (`reboot`,
  `poweroff`, `warmboot`, `restart`, `log -f` as `cat /dev/kprint`), not
  programs of their own.

## Small ones, while here

- `launcher.until=SERVICE` ends the launcher with that service's exit
  string (D72), not a number.
- The clock service serves `/dev/time` beside the UTC page (D48), so
  `date` reads a file; the page stays the fast path.
