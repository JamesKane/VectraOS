# The ring 3 network stack

`servers/netfs` is the IPv4 and TCP stack, in ring 3, serving `/net`. The cards
are the kernel's, as `#E` at `/dev/etherN`, one directory a card. Everything
above them is here: an interface per card with its ARP table, a route table,
IPv4, ICMP, UDP and TCP over `sys/libnet`'s wire formats, and the `/net` files
a program reads. `docs/FLEET.md` step 0 is the plan it grows under.
`cmd/netecho` with `sys/libnet`'s `dial` are what cross a line over it,
`cmd/ping` reaches a machine by name over the conversations under `/net/icmp`,
and `cmd/ipconfig` asks a router for an address over `/net/udp` and writes
what it learns into `/net/ipifc`, `/net/iproute` and `/net/ndb`.

## Interfaces and routes

An interface is a card with an address, a mask, an ARP table and the
datagrams waiting on it. `/net/ipifc/N/ctl` takes `add ip mask` and `remove`,
and `status` says what the interface is. `resolve_addresses` gives each one
the address `/lib/ndb/local` holds for its card, by `ether=`, with `ipmask=`
or a class C; an interface with no record has none, and `init` runs `ipconfig`
for it. `/net/iproute` is the route table: `add dst mask gw` and `remove dst
mask`, and a read lists each route with the interface its gateway is on. An
interface's own subnet is a route nobody adds. `ip_output` picks the interface
and the next hop, resolves the hop by ARP on that interface, and holds the
datagram for the reply. A datagram for the broadcast address leaves the
interface a conversation is bound to, `bind etherN` on its `ctl`, with no
address to resolve, and an interface with no address takes every frame its
card gives it. That pair is what `ipconfig` needs to ask from nothing.

Much of the stack was brought in line with 9front's, read side by side. The ARP
hold, the retransmit, the synchronous connect, the listener close, the
conversation reclaim, and the flow control each match that stack. This document
records what does not yet, so a later session finds it rather than the code
alone.

## The names, beside the stack

`/net/cs` and `/net/dns` are two more servers, mounted after `netfs` at `/net`
so their files sit in the stack's directory. `cs` began inside `netfs`, where
a name was only ever the database's. A name the network must answer is a
question to another process, and a server cannot ask one from inside its own
serve loop while the asker waits on it: `netfs` asking `dns` would park the
loop that `dns` needs to send its datagram. So each asks from a process of
its own. `dns` reads `/net/ndb` for the resolver `ipconfig` learned, or the
gateway record's `dns=` in `/lib/ndb/local`, and dials it by address rather
than through `cs`, since `cs` is what asks it. `init` starts them in that
order: the stack, then `dns`, then `cs`, each mounted as it posts. The suite
proves them with `dnstest`, a resolver of one name announced on this
machine's port 53, asked through both files.

## Deferred work

Each item names what is here, what 9front does instead, and what it waits on.

### Wants a real clock

`docs/DEVTOOLS.md` step 1 gives `/dev/time`. Three things wait for it, because a
round of the ether thread's loop is the only clock the stack has now.

- **Retransmit backoff.** A segment is sent again after a fixed count of
  rounds. 9front measures the round trip and doubles the wait each try, bounded.
  Without a clock the timer is coarse, and it cannot tell a slow link from a
  lost segment.
- **`Time_Wait`.** A closed conversation has no timer to leave `Time_Wait` on,
  so it rests there until a new `clone` reclaims its slot. A real close waits
  two segment lifetimes and then frees itself.
- **A conversation abandoned mid-close.** The last descriptor on a
  conversation whose `data` was opened hangs it up, as Plan 9's `closeconv`
  does, so a program that exits or is killed mid-stream still sends its FIN
  and both ends finish. (A conversation whose `data` was never opened is left
  alone: `dial` closes `ctl` between its connect and its open of `data`.) One
  left in `Fin_Wait_2` by a far end that never answers, or resting in
  `Time_Wait`, holds its slot until a new `clone` reclaims it. A timer would
  reap it on its own. The stack has eight slots, and before the last close
  hung a conversation up, every test that opened a stream and exited kept one
  until the table was full and a listener could accept nothing.

### Efficiency, not correctness

The stack is correct without these. Each is a round trip or a packet it could
save.

- **Fast retransmit.** Three duplicate acknowledgements mean a segment was
  lost, and 9front sends it again at once. Here the retransmit timer is what
  notices, which is slower.
- **Delayed acknowledgement.** Every segment with data draws an
  acknowledgement of its own. One acknowledgement for two segments, on a short
  timer, would halve the traffic back.
- **Nagle.** A write goes on the wire as its own segment. Holding a small write
  briefly, for the bytes behind it, would fill segments better on a slow
  stream.
- **Silly window avoidance.** A read reopens the window by whatever it freed,
  down to one byte. 9front holds the reopening back until it is worth a
  segment, so a slow reader does not draw a run of tiny ones.

### Not yet built

- **Congestion control.** `docs/FLEET.md` step 0 wants it. There is no
  congestion window and no slow start, so the stack sends as fast as the far
  end's window allows and no slower.
- **A send buffer.** A write is sent from the caller's bytes, and a write the
  window stops is held or answered short. A buffer would take the whole write
  and drain it as room opened, so a caller never waited.
- **Partial overlap on receive.** A segment that starts before the stream and
  carries new bytes past it is dropped whole, and the far side sends it again.
  9front trims the old front and keeps the new tail.
- **UDP conversation reclaim.** A TCP conversation's slot is reclaimed when it
  is finished and unreferenced. A UDP conversation has no finished state to key
  that on, so its slot is not yet reclaimed the same way.
- **A lease that renews.** `ipconfig` takes an address once and keeps it. A
  router that hands out short leases will take it back unannounced. Renewal
  wants the clock too.
- **Forwarding.** A datagram for another address is dropped, so a machine with
  two cards does not join its two links. Plan 9's `ipfwd` is the switch.
- **A flush that reaches the far read.** `cmd/exportfs` answers reads on its
  serve loop's own thread, so a read that parks in its namespace parks the
  loop, and a `Tflush` that crosses the wire waits behind the parked read
  rather than cancelling it. The client's read is cancelled at its own end;
  the far read is not. Answering reads from threads of their own, as the
  kernel servers do, is what fixes it.

### The rest of step 0

`docs/FLEET.md` step 0 is more than this stack. The bench's two machines, one
amd64 and one arm64, ping each other by name and cross a line, and each gets an
address for its second card from QEMU's router, which is the whole boot line.
`servers/etherfs`, the card as a ring 3 driver, is named in the plan and waits
on `docs/HARDWARE.md`'s files for a device in ring 3.

## Reading the bench

Three things say where a frame went, for the day a line does not cross.

- **`/dev/ether/stats`** is the card as the kernel saw it: frames handed up
  and written down, used-ring entries taken, and the ring's two indices.
- **`/net/ether0/stats`** is the card as the stack saw it: frames each way,
  datagrams for this machine and for another, and ARP requests asked. A
  count here below the kernel's is a second reader on `/dev/ether/data`.
  The card is not multiplexed, and only `netfs` may read it. The suite's
  live network check once polled it for minutes on a link with no gateway,
  and the stack lost every other frame to it.
- **`fleet --pcap`** captures each machine's frames at QEMU's netdev, to
  `build/net-a.pcap` and `build/net-b.pcap`, for `tcpdump -nn -r`. What one
  machine sent and the other received is then a question with an answer.

The bench's first card is the link between the machines, with no router on
it, so the kernel's boot network check and the suite's gateway checks fail
there by design. The router is on the second card, which `ipconfig` finds.

## Serving 9P, not only dialling it

`docs/FLEET.md` step 1 is 9P the other way: `cmd/exportfs` serves a namespace
on a stream, `cmd/listen` runs it per connection, and `cmd/srv`, `cmd/import`
and the `9fs` function mount what another machine serves. The kernel becomes a
client of a posted stream the same way it is of a posted pipe --
`kernel/pipe/chanwire.odin` builds an `mnt.Wire` over the conversation's data
chan, and `vfs.is_device_server` is what keeps a posted device (`/dev/cons`)
publishing itself rather than being spoken 9P over. `docs/TRANSPORT.md` has
the wire; this names where the network's own files feed it.

## See also

- `docs/FLEET.md` -- the plan this stack grows under, step 0.
- `docs/TRANSPORT.md` -- `kernel/mnt`, the client a mounted `/net` reads
  through, and where an interrupted read keeps a reply that raced its flush.
- `docs/VECTRA9.md` -- the 9P dialect the files are served over.
- `docs/DEVTOOLS.md` -- the `/dev/time` that three of these wait for.
