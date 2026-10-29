# D149. The LAN budgets as measured: a QEMU node bridged onto the LAN, 9gate's share of a Tread, and the bulk read at 1 GbE's rate (2026-10-29, decided by the owner; amends D148's budgets)

D148 left the LAN budgets standing until V7's first step measured them.
The step's measures (the roadmap's V7, peer-bench's `remote_read_4k`
and `remote_bulk`) changed three things:

- The board's 4 KiB Tread to the dev machine is 133-191 µs at p50, and
  an ICMP ping between the two is 82-103 µs already: "< 50 µs node to
  node" is under the wire's own round trip, which no OS meets.
- The board's bulk read, 49-54 MB/s, is the board's raw TCP (about 53
  MB/s in, 41 out): the limit is the network path (net, rge), not 9gate.
  The link is 2.5 GbE (the dev machine's NIC; the board's is 5 GbE), not
  the 1 GbE the budget names.
- A QEMU node on QEMU's user network is no second node: it costs about
  160 µs a Tread by itself, its bulk reads stall (about 1 MB/s), and a
  caller from the LAN reaches it only with its isolation off.

## Decided

1. **The harness:** the board and an amd64 QEMU node (KVM) on the dev
   machine, the node a host on the LAN of its own: its virtio-net on a
   bridge (`br0`) that holds the dev machine's NIC, joined through
   QEMU's bridge helper (`qemu.sh --bridge br0`), its address by DHCP
   from the LAN. Nothing sits between it and the wire but the bridge. The
   bridge is made once on the dev machine, by its owner (root).
   Two QEMU nodes on one machine were not chosen: they measure no wire,
   and net serves one interface, so the cpu link would need another.
2. **The Tread budget is 9gate's share:** a 4 KiB Tread's p50 node to
   node, less the p50 of a ping from the dev machine to the board, is
   under 50 µs.
3. **The bulk read keeps D148's number:** at least 112 MB/s (90% of
   1 GbE), the dev machine reading the board's export, is V7's limit;
   90% of the link as it is (2.5 GbE: about 281 MB/s) is a target. The
   board's TCP path gets V7's work toward it, measured as raw TCP before
   9P.

Until 9gate's plain listener, nothing on the dev machine reads a node's
export, so the bulk read is measured the other way (the board reading
`/mnt/term`) and both ways node to node.
