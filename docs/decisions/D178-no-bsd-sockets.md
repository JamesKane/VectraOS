# D178. No BSD sockets: tier 1's libc has no sockets, `poll`, `select` or resolver, and POSIX networking programs are outside first-party support; a program reaches the network through Plan 9's `dial`, `announce`, `listen` and `accept` (2026-11-21, decided by the owner; amends D79 and D80)

D80's table mapped "sockets, `getaddrinfo`" onto `/net` and `/net/cs`
through `dial`, and D79 said "BSD sockets exist only in tier 1's libc,
over `/net`". Both read as a promise that the libc would carry sockets
one day. It never has (`system/libc` has no `sys/socket.h`), and the
owner's direction is that it never will.

The reason is the history. Unix's networking didn't come from the Unix
tradition. Sockets were added to 4.2BSD beside the file system, with
their own namespace, their own calls for naming, connecting and waiting
(`bind`, `connect`, `getaddrinfo`, `select`), and their own options
(`setsockopt`, `ioctl`). Plan 9 corrected that: a connection is files
under `/net`, named by a dial string, looked up by the connection
server, and handed between machines by binding a directory (D79,
`cpu`'s `/mnt/term/net`). VectraOS took Plan 9's form, and keeping a
second form in the libc would be two mechanisms for one job
(principle 1).

## The decision

- **Tier 1's libc has none of BSD networking:** no `socket`, `bind`,
  `connect`, `listen` or `accept` in their BSD form, no `sendmsg`,
  `recvmsg` or `setsockopt`, no `select`, `poll` or `epoll`, no
  `getaddrinfo`, `gethostbyname` or `inet_*`, and no `sys/socket.h`,
  `netinet/` or `netdb.h` headers.
- **POSIX networking programs are outside first-party support.**
  Nobody ports one as VectraOS's own. A program written for BSD sockets
  isn't a target the libc aims at, any more than one that needs `fork`
  (D80).
- **A program reaches the network through Plan 9's calls:** `dial`,
  `announce`, `listen` and `accept` over `/net`, with names looked up
  through `/net/cs` and `/net/dns` (D79). Sys has them in Swift. C in
  tier 1 gets them with Plan 9's signatures, in a small native library
  beside the libc, never inside it as POSIX. Waiting on many
  connections uses the native waits (ports and rings) or a thread a
  connection, as Plan 9's servers do.
- **A third-party program brought over for a stated purpose** (D177's
  bench ports, such as Redis) gets a VectraOS backend of its own over
  these calls, as it has one for each OS it already supports. That
  backend lives with the port. Nothing is added to the libc for it.
- **Unchanged:** foreign personalities (`docs/foreign.md`) map their
  own network APIs, Winsock among them, onto `/net` through `dial`
  inside the personality. That is the same rule: the mapping lives with
  the guest ABI, and nothing native takes its shape. Host tools (D4)
  use the host's sockets as they always have (`tools/cpu`, vtest).

## What changes

- D80's mappings table: the "sockets, `getaddrinfo`" row is withdrawn.
  `/net` and `/net/cs` are reached through `dial`, not mapped from
  sockets.
- D79's sentence "BSD sockets exist only in tier 1's libc, over
  `/net`" is withdrawn: they exist nowhere on the device.
- D177's network rows (`uc_http`, `uc_redis`) already follow this.
  They wait on C-callable `dial` for tier 1, which is D177's open
  question 3.
