# Kernel objects and syscalls

Handles, waits, ports, tasks, IPC, synchronization and the other object types, mostly Zircon's ABI. Part of croi's design notes (index in CLAUDE.md).

## Kernel objects (K5)

Kernel objects (K5, Kernel/Object/; Zircon's status codes, rights,
signals and object types, so the ABI matches):
- Every object record starts with an `ObjectHeader` (type, koid from 1024,
  signals, observers, lock, atomic refcount); `ObjectPointer` reaches it,
  `Objects.destroy` frees by type. Not `Ref<T>`: objects mutate under
  their own lock, like VMOs and aspaces. `ObjectRef` (~Copyable) is a
  reference held by kernel code; handles hold one each.
- `HandleTable` (per process from K7): slots of (object, rights); a value
  is slot + 8-bit generation + Zircon's fixed low bits, so stale handles
  fail. get (bad handle, wrong type, access denied, in that order),
  duplicate/replace (rights subset or sameRights), close (cancels waits
  through the handle). `HandleTable.withBorrowed` for threads sharing one.
- Waiting: observers on an object's list; `updateSignals` runs them under
  the object lock. Since V1 (D23) a port is the one wait: the observers
  are object_bind's bindings, dropped when the handle they were bound
  through closes. `ObjectWait.one/many` went with object_wait_one/many,
  and the thread waits (`WaitState`) with counter_wait (D25). Ports (`PortObject`):
  FIFO of `PortPacket` (zx_port_packet_t layout), `Ports.queue/wait/
  cancel`; `Observers.waitAsync` is one-shot with EDGE and TIMESTAMP,
  its packet allocated at registration. Lock order: object -> scheduler
  -> port packets (object locks may be held while taking the scheduler
  lock; nothing takes them under it).
- `PacketSource`: kernel events reporting to a port with one owned,
  coalescing packet (count): budget overruns (ext 3,
  `SchedContext.bindOverrunPort`, fired under the scheduler lock) and
  memory pressure (ext 6, `MemoryAccount.bindPressurePort`).
- `VmoObject` (default rights as ZX_DEFAULT_VMO_RIGHTS; `forMapping`
  needs map plus read/write/execute per access). `ResourceObject`: root
  (made at boot) mints system resources; the tracing one (base 14, as
  Zircon) gates `TraceControl` (start, stop, rewind, mark, rings as
  read/map-only VMO handles).

## Processes (K7a)

Processes (K7a, Kernel/Object/Process.swift, include/task.h, syscalls
60-74 in User/TaskSyscalls.swift):
- Job (17), process (1), thread (2) and VMAR (18) objects, Zircon's
  rights and TERMINATED signal. A root job at boot. A process owns its
  `UserAspace` (the vDSO mapped at creation) and `HandleTable`; threads'
  syscalls use the process's table. Its first thread gets the transferred
  handle, arg2 and the vDSO base in the first three argument registers
  (`arch_enter_user` takes three); a C entry on amd64 needs a call-aligned
  stack (crt-style stub, or start sp at top - 8).
- Each user scheduler thread holds a reference to its thread object
  (`Thread.object`), which holds the process. The last running thread
  tears the process down from its own context: `setAspace(nil)`, close
  every handle (so a process holding its own handle still dies), wait
  until earlier exiters have left the address space, destroy it. A
  process whose threads never ran is torn down by its last reference.
- Kill (`task_kill`, process_exit, a fault until K7d's exceptions):
  `Scheduler.interrupt` marks the thread; interruptible waits (syscall
  waits: port, futex and interrupt waits: `block(interruptible: true)`) end
  with `.interrupted`, a running thread is preempted, and every return to
  user mode (`UserTraps.leaving`) exits a marked thread. Return codes
  -1024 (killed), -1026 (policy) and -1028 (exception), Zircon's. Kernel-only waits stay
  uninterruptible.
- A job's children and a process's threads are non-owning lists (an
  object's destroy takes it out under the parent's lock): anything that
  walks one and uses an entry after the lock drops takes a reference
  with `tryRetain` under it. kill(process:) didn't, and a job kill
  (Todhchai's shutdown, ~3 boots in 20 one afternoon) locked a thread
  object freed meanwhile: its poisoned lock word spun forever. SpinLock
  now panics on a holder that isn't a CPU.
- VMARs wrap K4 regions (`UserAspace.withView`); `vmar_map` and friends
  pack handle | options << 32 into one register (six argument
  registers). A dead address space refuses operations under its lock
  (`VmError.dead`). User code has `croi_syscall6`.
  `vmar_unmap_handle_close_thread_exit` (75) is a syscall (Zircon's is
  vDSO code): `Syscalls.run` exits the thread after the handle-table
  borrow ends, so no frame holds a reference; a failed close raises an
  undefined-instruction exception (Zircon's vDSO traps).
- User TLS (`Thread.tls`/`gs`, switched in `switchUserTls`): amd64 FS
  and user GS bases only through object_set/get_property REGISTER_FS/GS
  (4/2; the calling thread's own handle, canonical; CR4.FSGSBASE stays
  off, so the record is the truth and a per-CPU cache skips unchanged
  WRMSRs); arm64 TPIDR_EL0 saved and restored per user thread; rv64 tp
  is in the frame. thread_read/write_state carry them.
- `vmo_create` rounds sizes up to a page (Zircon's RoundSize); size 0
  makes a zero-size VMO, as Zircon's (since K9a).
- `object_get_child` (78, K15d; Zircon's, for Todhchai's Inspector,
  `Processes.child`): a job's child job or process, or a process's
  thread, by koid. ENUMERATE on the parent, SAME_RIGHTS (exactly) for the
  parent handle's rights or a subset of them (else ACCESS_DENIED), a koid
  not a live child NOT_FOUND (dead threads and processes stay listed
  until their last reference, so they are filtered: Zircon drops them
  at exit), other parents WRONG_TYPE. Mode 17's checks 746-751.
- Lock order: job -> process -> thread object -> scheduler.

## Channels (K7b)

Channels (K7b, Kernel/Object/Channel.swift, include/ipc.h, syscalls 80-86
in User/IpcSyscalls.swift):
- Channel (4) endpoints share a `PeerShared` (lock,
  channel id = smaller koid); peers link without references and reach
  each other with `ObjectPointer.tryRetain`. Messages (bytes up to 64
  KiB, up to 64 handles) are one heap block owning a reference per
  handle; as in Zircon, write and call consume every listed handle
  whether or not they succeed (`build` takes each out of the table,
  closing the bad ones, first error wins: TRANSFER, not the channel
  itself, a repeat finds BAD_HANDLE), unless the list can't be read. Closing an endpoint
  raises PEER_CLOSED on the peer, ends calls waiting on it, and frees
  unread messages outside the lock. READABLE/WRITABLE/PEER_CLOSED are
  object signals, so bindings see them. Eventpairs were cut in V1 (D23).
- `channel_call`: the kernel writes a txid (high bit set) into the first
  four bytes; a write whose txid matches a pending call on the peer goes
  straight to that caller. Ext 2 donation: the thread that reads a call
  becomes the owner of the caller's call-record queue
  (`Scheduler.setOwner`, refused if it would close a cycle), so K3b
  inheritance lends it the caller's profile until the reply; an exiting
  thread drops what it owns (`dropOwnership`). `channel_read` packs its
  capacities (bytes | handles << 32) and actuals.
- `ipc` trace: CHANNEL_WRITE/READ and DONATE records carry
  `croi_flow_id(channel id, txid)` (ipc.h, splitmix64 finalizer), which
  user space computes from `object_get_info(HANDLE_BASIC)` koids and the
  txid, so a call and its reply share one flow.
- Test-only syscall 6 (`TestHooks.profile`; NOT_SUPPORTED unless
  `croi.test=1` or `croi.debug_syscalls=on`, since review round 1: its
  hooks reboot, evict and sign with the kernel's key): bind to / report a deadline
  context a self-test provides, until profiles are objects.

## Futexes and timers (K7c)

Futexes and timers (K7c, Kernel/Object/Futex.swift, syscalls 90-91 in
User/SyncSyscalls.swift; timer objects were cut in V1, below):
- Futexes keyed by (address space, user address) in a 256-bucket table
  under the scheduler lock, which is the futex lock: a wait reads the
  word with `UserCopy.wordNoPageIn` (PerCpu.noPageIn: a fault goes to
  recovery; the wait drops the lock, pages it in and retries), compares
  and blocks under it. Records are allocated outside the lock and retire
  when no waiter refers to them (`users`: a woken waiter hasn't run yet
  when its waker returns), the queue is empty and nobody owns them.
  Owners use K7b's `setOwner` (a cycle leaves the futex unowned); wake
  clears the owner. `futex` trace records. V1 cut futex_requeue,
  wake_single_owner and get_owner (D22): todhchai's Lock and pthreads use
  wait and wake only, and with no requeue a waiter's record is the one
  it blocked on (`Thread.futex` went). Futexes are keyed by address
  space, so futex_wake and an ownerless futex_wait skip the handle table
  (`Syscalls.run`; V1, D26): a thread with no handles can sleep on one.
  Tests: the Swift `futex` suite
  (wait's refusals, a wake's count, an owner on a deadline waiter's
  profile); runSuites checks no record is left.
- Out-pointer checks (`Syscalls.check`) ask the address space whether
  writable mappings cover the range (`UserAspace.covers`): nothing is
  read or written, so any size works and a concurrent user write isn't
  clobbered; the copy out still recovers from faults. K14m: a thread
  caches the mapping its last check found (`Thread.coverStart/End`) with
  the address space's `mapGeneration` (bumped under its lock at every
  change to `mappings`), and a check inside it with the generation
  unchanged skips the lock.
- Timer objects (22) were cut in V1 (D25; "Sleeps, timers and counter
  waits" below). The hook their last handle's close used stays:
  `Objects.lastHandleClosed`, Zircon's on_zero_handles, run from
  `HandleTable.close`, a freed message's handles and `releaseTaken`;
  handle_replace adds the new handle before closing the old so the count
  never passes through 0. Nothing uses it until ports cancel their
  bindings there.

## Exceptions and job policy (K7d)

Exceptions and job policy (K7d, Kernel/Object/Exception.swift, task.h,
syscalls 100-107 in User/ExceptionSyscalls.swift):
- A user fault or exception (`UserTraps.offer`, typed per arch by
  `ExceptionFrame.exceptionType`) is offered to the thread's, process's,
  then each job's exception channel up the tree. The kernel keeps its
  end of each (`task_create_exception_channel`; ALREADY_BOUND while the
  user end is open); a message is croi_exception_info_t plus a handle to
  an exception object (29). The faulting thread waits (interruptibly)
  until the object's last reference goes, then: HANDLED resumes it with
  whatever `thread_write_state` put in its frame (`ThreadObject.
  exceptionFrame`, general registers only while in an exception),
  THREAD_EXIT ends it, TRY_NEXT moves on; unhandled kills the process
  (-1028). amd64 #BP's IDT gate is DPL 3 so a user int3 is a breakpoint.
- Job policy (`Policy`): an action per ZX_POL condition in each job,
  copied to child jobs at creation, settable only while the job has no
  children (ABSOLUTE refuses conflicts, RELATIVE skips them; NEW_ANY
  expands to every NEW_*). Creation syscalls check NEW_*; a BAD_HANDLE
  result checks BAD_HANDLE. KILL marks the process killed and lets the
  syscall unwind (Swift frames hold references) before the thread exits
  on its way out; *_EXCEPTION raise POLICY_ERROR first.
- Not yet: SError delivery to the faulting process. (Debugger channels
  and exception reports came in K13g.)

## Counters (K10a)

Counters, K10a (Kernel/Object/Counter.swift, User/CounterSyscalls.swift,
include/counter.h, syscalls 160-162):
- Zircon's counter (type 34; create, add, read; POSITIVE / NON_POSITIVE;
  add needs READ and WRITE, OUT_OF_RANGE on overflow) plus croi's waits
  at a value, object_bind VALUE (was `counter_wait_async(counter, port,
  key, value)` until V1; one packet of type 0x82: target, value reached,
  time), needing WAIT and READ. counter_write and counter_wait were cut
  in V1 (D25): an add of the difference, and a port.
- A value binding is an observer with a threshold (`Observer.byValue`,
  `atValue`): `Observers.notify` fires it when the counter's value
  reaches it, so registration, cancellation on handle close, port_cancel
  and port delivery are the signal bindings'.
- A counter with a deadline profile (K10c, ext 5) lends it to
  the thread each of its packets wakes: `notify` passes `lend(of:)` to
  `Ports.enqueue`, which wakes the port's first waiter with
  `Scheduler.wakeOne(lending:)`. A packet queued with no thread waiting
  lends nothing, as a counter_wait whose value was already reached did.
- Budget `counter.wake_median` (m2, as port wake): counter_add's entry on
  CPU 1 to port_wait's exit on CPU 2, through a CHANGE binding (the
  doorbell; limit 2 µs). Until D25 it was counter_wait's exit, KVM ~1.6
  µs.
- Tests: the Swift `counters` suite (Zircon's semantics, rights, VALUE
  bindings, the lent deadline), moved from boot test mode 14 and mode
  16's lending check.

## Executable VMOs (K13b)

- `vmo_replace_as_executable(vmo, vmex, out)` (49): the vmex must be the
  VMEX system resource (base 1) or root; the new handle has the old
  rights plus EXECUTE; the old handle is gone either way (Zircon's).
- The Swift `vmo` suite (`VmoSuite.executable`).

## FIFOs, sockets and streams: cut in V1 (D21)

croi had Zircon's FIFOs (K13b), sockets and streams (K13c), with their
info topics, properties, policy conditions and the MANAGE_SOCKET right.
V1 cut all fifteen calls: the one ring format replaces FIFOs and
sockets, and a mapping replaces a stream. What streams kept on the VMO
stays, as the VMO's content size (memory.md, "Content size").

## Events, signals and waits: cut in V1 (D23)

croi had Zircon's events (30), eventpairs (84), object_signal (20),
object_signal_peer (85), object_wait_one (21) and object_wait_many
(210), with the user signals (bits 24-31), the SIGNAL_PEER right, the
NEW_EVENT and NEW_EVENTPAIR policy conditions, the HANDLE_CLOSED signal
of a canceled wait and the BLOCKED_WAIT_MANY thread state. V1 cut all
six calls: a counter is the event a user drives (POSITIVE and
NON_POSITIVE are its signals, CHANGE its doorbell), a ring's peer death
is its negotiating channel's PEER_CLOSED, and a port is the one wait
(object_bind, then port_wait).
- Event objects stayed, made by the kernel only, for system_get_event's
  memory pressure events and the kernel self-tests, until D31 cut that
  call; the self-tests now signal counters.
- Tests: the Swift `objects` suite (signals through a port, handles,
  user packets) and `channel` suite (endpoints, handles in messages,
  refusals, a closed peer), moved from usertest.c's modes 0 and 7.
  usertest.c's `wait_for` is a ONCE binding on a port of its own,
  cancelled if it times out (a pending binding holds its port).

## Sleeps, timers and counter waits: cut in V1 (D25)

croi had Zircon's nanosleep (4), timer objects (95-97; type 22, with
the center/early/late slack policies and the NEW_TIMER policy
condition), counter_write (163) and croi's counter_wait (164), with the
thread waits behind it (`WaitState`, `Observer.Kind.wait`,
`Thread.waitState`). V1 cut all six calls:
- A sleep is a `port_wait` with a deadline on a port nothing is bound
  to. A timer is the deadline an event loop passes to its `port_wait`,
  the earliest it has (principle 10: a leeway lets the wait run late,
  never early, and a deadline thread gets none).
- A value is set by adding the difference; a wait at a value is a VALUE
  binding; a counter's lent deadline reaches the thread its packet wakes
  (Counters, above).
- Tests: the `counters` suite; the bind suite's leeway check took the
  zero-slack check of mode 8, which went with its timers. usertest.c's
  sleeps go through `sleep_until` (a port of its own each time: the
  program has no writable data) and its value waits through
  `wait_value` (a VALUE binding on a port of its own, cancelled if it
  times out).

## Clocks: cut in V1 (D26)

croi had Zircon's clock objects (K13f; type 30): clock_create, read,
get_details and update (216-219), vmar_map_clock (77) with its
INFO_CLOCK_MAPPED_SIZE topic, and the PA_CLOCK_UTC startup handle,
which nothing handed out; and Zircon's clock_get_monotonic syscall (3).
V1 cut all six calls:
- Monotonic time is the vDSO's `clock_monotonic` (user.md, "vDSO"),
  which reads the counter through the time page with no syscall. The
  runtime's `croi_clock_monotonic` calls it; m2, userboot and the
  suites read the time through it.
- UTC will be the time service's: it publishes UTC in a read-only
  seqlock VMO it hands each process at start (syscall-audit.md §4). No
  UTC source exists yet, so nothing is lost.
- usertest.c reads the vDSO too. It has no writable data, so a process
  mode finds the vDSO's base in its startup block (`now_ns`), and a
  child in its start argument (`vdso_now`). Mode 2 checks the vDSO's
  clock against a futex_wait deadline, and mode 3 sleeps with
  futex_wait timeouts. Neither has handles, so a futex_wait with no
  owner and a futex_wake skip the handle table (Futexes, above). Mode 4
  spins until the kernel sets a word on its stack, since a sample in
  the vDSO would count as foreign.
- Tests: the Swift `time` suite (the vDSO clock never goes back; a
  CHANGE packet's kernel timestamp falls between two vDSO readings,
  which is mode 2's old comparison with the syscall). Mode 17's
  `clocks` went with the clock objects.

## Display timelines: cut in V1 (D27)

croi had display timelines (K10b, Todhchai ext 1; type 48, under the
display system resource, base 16): a vblank count, driven by
timeline_advance or synthesized from the time on the GOP framebuffer,
waited on with the counter calls, its vblank times on a read-only
seqlock page (timeline_get_page), and timeline_set_period. Ext 10's
ALIGN_TIMELINE option of object_set_profile started a deadline thread's
periods on its vblanks (`vblankGrid`). V1 cut all four calls (170-173)
and the option:
- A driven display's vblank is a counter its IRQ thread adds to. A
  counter with Radharc's deadline profile lends it to the thread it
  wakes, whose period starts at that wakeup (Counters, above).
- A synthetic vblank is Radharc's own: its deadline thread port_waits to
  the vblank time it computes (no leeway for a deadline thread), and its
  period starts when it wakes. m2's `timer.wake_error_p99` measures that
  path, so the `timeline.wake` budgets went with their bench.
- Tests: mode 15 went, and mode 16's alignment checks (385-388) with
  it. The counters suite's refusal of options on a counter's profile
  uses HANDOFF.

## Bring-up calls: cut in V1 (D28)

croi had two calls from before the mechanisms that replaced them:
debug_write (1, K6), a user string on the kernel console, and vmo_map
(43), a VMO mapped into the calling thread's address space "until VMARs
(K7)". V1 cut both:
- Logging is `debuglog_write`. The kernel and userboot hand every
  program a debuglog as fd 1; the runtime's stdout drops output without
  one.
- Mapping is `vmar_map`. usertest.c's process modes map thread stacks
  in their root VMAR (`map_stack`); its children, which have no VMAR
  handle, get five stacks from `make_child` and take one by index.
- The boot's assembly user test checks only that registers survive
  null syscalls (it had also printed with debug_write and timed itself
  with the clock syscall D26 cut). m2's `syscall.null` times them.
- Tests: mode 0's size and mapping checks moved to the vmo suite.

## Interrupt waits: cut in V1 (D29)

croi had Zircon's three ways past a port for interrupt objects:
interrupt_wait (143), one thread blocked on the object;
interrupt_destroy (144), which woke it CANCELED; and interrupt_trigger
(145), which fired a VIRTUAL interrupt. V1 cut all three:
- A bound port is the one way to wait. Ext 5's lent profile and
  handed-off context (K14e) now go with the packet: `sendPacket` passes
  them to `Ports.queueInterrupt`, which wakes a thread from the port
  through `Scheduler.wakeOne(lending:)` or `wakeOne(handingOff:)`. As
  before, a thread that finds the packet already queued borrows nothing.
- Closing the last handle destroys the object (it always was destroyed
  with its last reference). A port binding doesn't hold it.
- A counter is a virtual interrupt. Tests fire an object as its device
  would through test hook 13 (`TestHooks.fire`).
- Tests: usertest.c's modes 11 and 16 moved to the Swift program's
  interrupts suite, which the kernel runs on its own in their place
  (`ProgramSelfTest.runSuite`), with PCI segment 0's ECAM in its
  environment. Mode 17's idle-state check carries its deadline profile
  on the RTC's interrupt instead of a virtual one.

## thread_raise_exception: cut in V1 (D30)

thread_raise_exception (236, K14d) offered ZX_EXCP_USER, with a code
and data of the caller's, to every job debugger from its job up, each
reply ignored. Nothing raised one, so V1 cut it with
`Exceptions.raiseUser`. Job debuggers keep PROCESS_STARTING
(debugging.md).
- Tests: usertest.c's `user_exceptions` went. The objects suite's
  `jobDebuggers` keeps a job debugger delivery under test; suites get
  the root job for it (PA_JOB_DEFAULT).

## system_get_event: cut in V1 (D31)

system_get_event (235) handed out one of five kernel event objects, one
per memory level, exactly one signaled. V1 cut it and the event objects
with it (`EventObject` and the event type).
- The root account replaced it (memory.md, "Memory accounts"): a
  PRESSURE binding on it reports the memory watchdog's level, as an
  account's binding reports its own. Two levels past CRITICAL exist only
  there: IMMINENT_OUT_OF_MEMORY and OUT_OF_MEMORY.
- Userboot and the Swift suites get it as CROI_PA_ROOT_ACCOUNT; nothing
  else can reach it.
- Tests: usertest.c's checks 615–619 moved to the Swift `memory` suite.
  The kernel's object, port and resource self-tests signal counters
  where they used events.

## The small calls (K13e part 1)

The small calls, K13e part 1 (syscalls 210-215 in User/IpcSyscalls.swift,
Kernel/Object/Names.swift; ipc.h, task.h; the pinned tree's semantics):
- object_wait_many (210) was cut in V1 (D23): ports are the one wait.
- handle_close_many (211): 0 skipped, bad values BAD_HANDLE with the rest
  still closed, 64 per chunk.
- port_cancel_key (212), since D32 port_cancel with source 0: every
  async wait to the port with the key, whatever its source, and every queued packet with it (user ones too;
  not kernel sources' or interrupts'), NOT_FOUND if none. Each port keeps
  `watched` (an object address per observer to it, under its packets
  lock; Observers.add/remove, notify, handleClosed and port_cancel keep
  it), safe because an object loses its observers before its last
  reference.
- channel_write_etc / read_etc / call_etc (213-215) were cut in V1
  (D22): a handle's rights are narrowed with handle_duplicate before it
  is sent. What K13e added to channel_read stays: it checks the handle
  first, refuses unknown options with NOT_SUPPORTED, and
  CROI_CHANNEL_READ_MAY_DISCARD drops a message that doesn't fit. Tests:
  the Swift `channel` suite.
- ZX_PROP_NAME (3): 32-byte names (31 + NUL) on processes, threads (BAD_
  STATE once dead), jobs, BTIs and VMOs (in the VmoRecord), resources read
  only, others WRONG_TYPE; process_create and thread_create now store
  theirs.
- Tests: the Swift `objects` suite (names, handle_close_many,
  port_cancel by key), moved from mode 17's `small_calls` (D23).

## Info topics and vmar_op_range (K13e part 2)

Info topics and vmar_op_range, K13e part 2 (User/InfoTopics.swift,
TaskSyscalls `vmarOpRange`, syscall 76; task.h, vmo.h):
- object_get_info takes Zircon's actual and avail (fifth and sixth
  arguments, optional). Fixed-size topics: actual 1 (0 and BUFFER_TOO_
  SMALL when short), avail 1; lists fill what fits and give the total.
  Topics are matched on bits 27:0 with the version in 31:28.
- PROCESS (STARTED / EXITED, `ProcessObject.startTime`), THREAD (state
  from ThreadObject and the scheduler; a blocked thread's BLOCKED_* reason
  from the syscall in its user frame, a page fault's PAGER;
  `exceptionChannelType` while an exception is offered; affinity in
  mask[0]), THREAD_STATS (BAD_STATE once dead), TASK_RUNTIME (cpu and
  queue time: `Thread.totalRuntime` grows in `charge`, `queueTime` at
  switch-in from `readySince`; exiting threads add theirs to the process,
  dying processes and jobs to their job), JOB (return code -1024 after
  task_kill), JOB_CHILDREN / JOB_PROCESSES / PROCESS_THREADS (koids,
  ENUMERATE), VMO (no rights needed; koid kept on the VmoRecord, flags,
  committed/private/scaled bytes; V1-V3 prefixes), PROCESS_VMOS (VMO
  handles then one entry per mapping; running processes only),
  PROCESS_MAPS (aspace, then regions and mappings depth first; V1/V2
  entries), HANDLE_TABLE (INSPECT | MANAGE_PROCESS | MANAGE_THREAD;
  `HandleTable.snapshot`). Not tracked: page-fault and lock-contention
  time. (Debugger attachment: K13g.)
- vmar_op_range (76): COMMIT, DECOMMIT, MAP_RANGE, ZERO, DONT_NEED and
  ALWAYS_NEED (K14a's hints), PREFETCH; rights by op on the VMAR
  handle, then per mapping; gaps BAD_STATE; mappings of sub-VMARs only
  with OP_CHILDREN (never for COMMIT/DECOMMIT/PREFETCH). Checked whole
  under the aspace lock, then done piece by piece without it (pagers may
  be waited for); `UserAspacePointer.mapPresent` maps what the VMO has.
- Mode 17's `info_topics`.

## object_bind (V1)

object_bind (V1, D20; Kernel/Object/Bind.swift, include/port.h, syscall
22): the one way an event source reports to a port. It replaced
object_wait_async (22), interrupt_bind (141), counter_wait_async (165),
thread_bind_overrun_port (122) and account_bind_pressure_port (242).
- `object_bind(port, croi_bind_item_t *items, count)`: up to 64 items
  (handle, options, key, trigger, status out), bound in order to one port
  (WRITE, looked up once). It stops at the first failure and returns how
  many succeeded; every processed item gets its status. A bad port,
  pointer or count fails the call before anything is bound.
- Kinds: SIGNALS (ONCE: the old wait_async; PERSISTENT: below), VALUE
  (ONCE: a counter's fence), CHANGE (a counter's doorbell), INTERRUPT,
  OVERRUN, PRESSURE. The last four are persistent by nature and refuse a
  trigger; VALUE refuses PERSISTENT; EDGE and TIMESTAMP are SIGNALS'.
- PERSISTENT SIGNALS and CHANGE are observers of kind `.source`, each
  owning a `PacketSource` (the reused, coalescing packet that overruns and
  pressure already had): it stays on the object, fires at every
  `Observers.notify` that satisfies it (CHANGE: every `Counters.setLocked`,
  `notify(changed: true)`), and while its packet is queued further events
  only raise the count (payload[1] for signals, [2] for CHANGE).
  Persistent SIGNALS is "every event that leaves a trigger asserted", not
  a strict edge: notify isn't called when signals clear, so an edge
  can't be seen reliably; a reader drains until the object would block,
  and gets at most one spurious packet per drain.
- Unbinding: `port_cancel(port, source, key)` removes ONCE, PERSISTENT,
  INTERRUPT and (D31) PRESSURE bindings (`InterruptObjects.cancel`, which replaced
  interrupt_bind's UNBIND) and takes a queued packet back
  (`PacketSource.retire`); closing the handle a SIGNALS, VALUE or CHANGE
  binding was made through does too. OVERRUN and PRESSURE last until
  their object goes or is bound again, or PRESSURE until port_cancel.
  A new PRESSURE binding reports the level at once unless normal (D31).
- port_wait gained a leeway (fourth argument): `Scheduler.block`'s
  timeout is armed with that slack (late only; none for a deadline
  thread), principle 10.
- Tests: the Embedded Swift suite `bind` (user/test/swift/BindSuite.swift,
  run by `ProgramSelfTest.runSuites`): batches and refusals, the doorbell's
  coalescing, unbinding by cancel and by close, persistent and EDGE
  signals, the leeway. A mutant whose CHANGE never fires fails it with
  "a doorbell rings". The older kinds keep their usertest.c coverage.
