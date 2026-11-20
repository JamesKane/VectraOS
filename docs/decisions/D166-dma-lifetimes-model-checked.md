# D166. A PMT's and its BTI's lifetimes are checked as they ship: their logic is generic over a world the kernel and a model both provide, and RingCheck's checker explores every interleaving of a small machine (2026-11-20, the owner scheduled the backlog's B6; extends D43)

`kernel/Kernel/Object/Dma.swift` keeps a BTI's and its PMTs' lifetimes
with reference counts and states changed in separate locked steps: a
PMT holds its VMO and, while live or unpinned, its BTI (`holdsBti`); a
handle closed on a live PMT moves it to its BTI's quarantine list, which
then holds it; `pmt_unpin`, `bti_release_quarantine`, a BTI's last
release and a process's death (its handles closed in any order) run
those steps on other threads. Its one recorded bug was an interleaving
of exactly that kind (V2's item 7c: a BTI closed before its PMT was
unpinned, then freed under the PMT's next lock). No test explores the
orders; the drivers suite runs one.

RingCheck (D43) explores every interleaving of the ring's real code on
a small machine, the code calling hooks where it touches shared memory.
The backlog's B6 asks the same of the kernel's lifetime logic.

## The decision

1. **The lifetime logic is generic over a world.** The parts of
   `Dma.swift` that change a PMT's state, `holdsBti`, the BTI's
   `livePins`, `quarantined` and quarantine list, and that retain,
   release or free either object (pin's last step, `unpin`,
   `handleClosed`, `releaseQuarantine`, `destroyPmt`, `destroyBti`'s
   quarantine walk) move to a file of their own, generic over a
   `DmaWorld` protocol: lock and unlock a BTI, read and write the
   fields, retain, release and free a PMT or BTI, unpin a VMO range,
   unmap an I/O range. Objects are named by the world's handles
   (addresses in the kernel). The kernel's world is the real objects,
   with no change in behaviour and no cost (specialised, no
   existentials). Everything else in `Dma.swift` (paging in, the
   window, I/O mapping, properties) stays.
2. **A model world for the checker,** in the ring checker's style: its
   state (a few objects' counts, states, fields and a pin count a page)
   in one checked region, each world call a step at which the checker
   may switch threads. Its threads are the operations as drivers make
   them: pin, unpin, close the PMT's handle, close the BTI's handle,
   release the quarantine, and a process's death closing what it holds.
3. **Invariants checked at every step and at the end:** no object
   touched after it is freed; every object freed once, when its count
   reaches zero, and none left at the end; a page's pin count equal to
   the PMTs live or quarantined over it, or held for good by an
   orphaned quarantine (a stub BTI closed with PMTs quarantined); a
   BTI's counters equal to what its PMTs say; a device never left
   mapped to a page that isn't pinned.
4. **RingCheck's checker is the shared one.** It moves from
   `lib/ring/check` to `lib/check`, unchanged but for its name and the
   hooks it offers, and RingCheck and the DMA check both use it. Each
   check has broken variants that must fail (as RingCheck's do): the
   7c bug restored (the PMT drops its BTI at unpin), and the quarantine
   taken without the list's reference.
5. **A time bound from the start:** the DMA check runs within 30 s on
   brimstone, and the machine it explores is sized to fit (one BTI, two
   PMTs, three threads at most); a larger one is a parameter, not a
   default. Like RingCheck it runs on Linux (its coroutines are
   ucontext, which macOS doesn't keep working).

## Not chosen

- **A model written beside the code** (the operations restated as a
  state machine). It would check the restatement, not what ships, which
  is the review's point.
- **The whole DMA path under the checker** (paging in, I/O page
  tables). The bugs were in the lifetimes; the rest is sequential.
- **A new checker.** RingCheck's already runs real code on coroutines
  with state hashing; a second one would be a second mechanism for the
  same job.
