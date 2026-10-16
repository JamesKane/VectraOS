# User mode, programs and boot-time user space

Entering and leaving user mode, the vDSO, user FP/SIMD, sampling and the PMU, program loading, userboot and m2. Part of croi's design notes (index in CLAUDE.md).

## User mode (K6)

User mode (K6a, Kernel/User/, include/user.h): a user thread's registers
are an arch_exception_frame_t at the top of its kernel stack while it is in
the kernel; `UserTraps.enter` (setAspace, `Scheduler.setKernelStack`,
`arch_enter_user`) drops to user mode, and traps/syscalls/interrupts come
back through `arch_exception` (`ExceptionFrame.fromUser`) to
`UserTraps.handle`: interrupts preempt as usual, syscalls go to
`Syscalls.dispatch` (interrupts on), user page faults resolve through the
VM or kill the thread, anything else kills it (exit codes
`killedByFault`/`killedByException` until K7's exception channels).
switchAway keeps PerCpu `kernel_sp` (and the amd64 TSS RSP0) at the next
thread's stack top.
- amd64: swapgs on every user entry/exit (in the kernel GS_BASE is the
  PerCpu, KERNEL_GS_BASE the user's); SYSCALL (LSTAR `syscall_entry`,
  number in rax, args rdi rsi rdx r10 r8 r9) builds the same frame
  (vector 0x100) and returns with sysretq (the rip is SYSCALL's, so
  canonical); STAR/FMASK in `arch_syscall_init`, per CPU.
  `arch_syscall` runs `UserTraps.leaving()` after the dispatch, as every
  other way back to user mode does (it didn't: a killed thread retrying
  failing syscalls ran on until an interrupt caught it in user mode).
- arm64: EL0 vectors (slots 8-15) skip the overflow check and save/restore
  SP_EL0; SP_EL1 is the stack top because user frames sit there; svc #0
  with the number in x16 (Zircon's); TPIDRRO_EL0 is kernel scratch and 0
  for user mode. IRQs from EL0 are slot 9.
- rv64: sscratch is 0 in S-mode (set in arch_init_exceptions: firmware
  leaves anything) and the PerCpu in U-mode; the entry swaps it with tp
  to tell the origins apart; ecall with the number in a7.
- `arch_copy_from_user`/`to_user`: byte loops listed in .croi_fixups
  (arm64 ldtrb/sttrb; rv64 with SUM).
- K6b: user-access protection on every CPU (`arch_user_protection_enable`,
  `croi_user_protection`): amd64 SMEP + SMAP (stac/clac in the accessors
  and `arch_user_access_begin/end`), arm64 PAN set on every kernel entry
  (SPAN clear; accessors use ldtr/sttr, which PAN doesn't block), rv64 SUM
  only inside the accessors. A fault the protection caused
  (`ExceptionFrame.userAccessBlocked`) goes straight to recovery.
  Syscalls touch user memory only through `UserCopy`, which checks the
  user range first: the arch copies don't, and on amd64/rv64 would write
  kernel pages through a pointer user space chose (a test caught it).
  The object syscalls (user/include/croi/syscall.h: handles, signals,
  waits, events, ports, VMOs, trace_configure) use
  the thread's `handleTable` (K7: the process's). `syscall` trace
  category (enter/exit). User programs: `user/` is built with user flags
  (CMake custom command, static at the address the kernel maps it) and
  included with `.incbin` (kernel/userprogram.S).
- K6c: shared read-only pages (include/shared.h, Kernel/User/Vdso.swift):
  the time page, a topology page and a power page (ext 9), each with a
  seqlock sequence (`SharedPages.write` bumps it odd/even); the scheduler
  republishes a CPU's capacity and power hints when they change
  (`publishPowerHints`, outside its lock). The vDSO (user/vdso: header
  with function offsets at byte 0, code, then the three pages, all
  reached PC-relatively) is mapped by `Vdso.map` into a region of its
  own: code read/execute, pages read only (`Vmo(sharedKernelPage:)`, the
  only RAM a physical VMO may cover, never writable). User counter
  access per CPU (`arch_user_counter_enable`: arm64 CNTKCTL_EL1.EL0VCTEN,
  rv64 scounteren.TM). The vDSO's clock is user space's only monotonic
  clock since V1 cut the syscall (D26): the runtime's
  `croi_clock_monotonic` calls it. VdsoSelfTest (mode 2) checks it never
  behind a futex_wait deadline; the Swift `time` suite checks a kernel
  packet timestamp between two readings. User binaries come from `croi_user_binary`
  (cmake/CroiUser.cmake) with `CROI_USER_CFLAGS` (cmake/arch).
- K6d: user FP/SIMD. Every user thread gets an ExtendedState area at
  `UserTraps.enter`; `Scheduler` saves the outgoing and restores the
  incoming thread's state at each switch (`arch_xstate_save/restore`,
  arch cpu.S; kernel threads have none, and the kernel never uses FP, so
  traps and syscalls don't save it). `croi_xstate_config` picks the
  format: amd64 XSAVE with XCR0 = the shared features less PKRU (the
  scheduler switches it) and AMX tiles; arm64 Neon, or SVE Z/P/FFR at the
  boot vector length; rv64 F/D, plus V at vlenb (sstatus FS/VS on for
  user threads). Not yet: lazy AMX via XFD, SME/streaming mode (trapped),
  per-thread SVE vector length. User code is built for the baseline ISA
  with FP/SIMD (`CROI_USER_CFLAGS`: x86-64, Armv8, rv64gc; SVE, V and
  AVX are run-time options); amd64 `_start` realigns its stack.
- K6e, sampling (Kernel/Trace/Sampler.swift): with CROI_TRACE_SAMPLE on,
  each CPU running a thread samples it every 1/sample_hz (trace_configure
  start's sixth argument, default 1 kHz): a SAMPLE record (PC, frame
  count, source) and FRAMES records (two return addresses each, up to
  16), consecutive in the ring. Kernel addresses are image offsets with
  CROI_SAMPLE_KERNEL set. Frame-pointer walks: kernel frames only inside
  the interrupted 32 KiB stack block; user frames via `UserCopy`, and a
  thread sampled in a syscall continues into its user frames (the frame
  at its kernel stack top). Any fixup fault in interrupt context goes
  straight to recovery (`PerCpu.interruptFrame`, set by
  `Interrupts.handle`), so nothing pages in from an interrupt. The
  sampling timer is armed at a switch to a thread and lapses on a tick
  that finds the CPU idle, so idle CPUs stay tickless. The self-test
  runs a 3 ms thread on a third CPU, waits 5 ms, then asks each other
  CPU through an IPI, while the spinner runs, whether it is idle with
  its sampling timer armed, as the PMU test does (fixed 2026-10-15 after
  D34's run). It used to count every sample and armed timer off the
  spinner's CPU, so a background thread running in the window failed
  it: three rv64 boots that day. And no idle CPU had run anything while
  sampling was on, so none was ever armed: re-arming on a lapse without
  disarming at idle passed it. With the bystander, that mutation fails
  every amd64 boot. Kernel and user
  code keep frame pointers; amd64 user `_start` is a crt-style stub that
  calls C (a C entry with a 16-aligned stack misaligns rbp).
- K6e, PMU (Kernel/Trace/Pmu.swift, include/pmu.h, syscall 51
  pmu_configure): per-thread counters (up to 4 generic or raw events;
  `Thread.pmu`, stopped and accumulated at switch-out, restarted at
  switch-in) and overflow sampling into the same SAMPLE records (source
  1 + generic event) with the tracing resource. The sampling counter is
  stopped while a CPU idles. amd64: Intel architectural PerfMon (CPUID
  0xA, full-width writes) or AMD core counters (PerfCtrExtCore, PerfMonV2
  global control), LVTPC vector 0xF8 (not NMI: masked code isn't
  sampled); arm64 PMUv3 (overflow PPI from the GICC's performance GSIV,
  offset 20); rv64 SBI PMU (counters chosen per event by the SBI) with
  Sscofpmf's LCOFI (interrupt 13) when the RHCT lists it. QEMU TCG amd64
  has no PMU; KVM on this AMD host covers the AMD backend; the Intel
  backend is unverified until it runs on an Intel machine. QEMU arm64
  counts instructions only with icount, so its tests use cycles.
- The self-test's overflow check (fixed 2026-10-15, VectraOS V0) asks
  every other CPU, through an IPI and while sampling is still on, whether
  it is idle with the counter running (`Pmu.samplingArmedHere`). That is
  the property: the counter stops when a CPU idles. A busy bystander thread
  on a third CPU must be sampled too.

  The old check counted any sample off the spinner's CPU as "on an idle
  CPU", and summed overflows over CPUs picked by `Cpu.current`, which
  moves because the bootstrap thread isn't pinned. So a background thread
  (`dlog-dumper`, `reclaim`) that ran past one period failed it. That
  happened about 1 boot in 6 on rv64 under TCG, whose cycle counter
  follows host time.

  Verified three ways:
  - the bystander made the old check fail every time;
  - a mutant that leaves the counter armed on idle is caught;
  - the new check passed 6 of 6 rv64 boots.
- User threads killed by a fault or exception are logged (cause and PC)
  until K7's exception channels report them.
- The boot test runs `usertest.S` (per arch) from a VMO: registers kept
  across 1000 null syscalls, a fault and a privileged instruction killed,
  preemption of user code. It timed the null syscalls and wrote a message
  with debug_write until V1 cut that and the clock syscall (D26, D28):
  m2's `syscall.null` times them (KVM: ~40 ns).

## Debuglog and user programs (K8a)

Debuglog and user programs (K8a, Kernel/Object/DebugLog.swift,
Kernel/User/ProgramLoader.swift, include/log.h, include/processargs.h,
syscalls 110-111):
- `DebugLog`: since D38, the one ring (lib/ring, architecture §3) in
  OVERWRITE mode: 512 slots of 256 bytes, each a croi_log_record_t
  (Zircon's layout; its sequence is the ring's), in a contiguous VMO the
  kernel maps to write. Writers (`debuglog_write`, `KernelLog`) are
  serialised by the debuglog lock into the ring's one producer, which
  then adds one to the ring's counter, so its value is the producer
  cursor. Readers hold the VMO (READ | MAP, CROI_PA_VMO_DEBUGLOG) and the
  counter (READ, CROI_PA_DEBUGLOG_COUNTER), from userboot or the kernel's
  self-tests: each maps the ring read only, keeps its own cursor, and
  binds VALUE at its cursor plus one when caught up. Log objects (type
  12) only write and need no resource. A `dlog-dumper` thread is a
  reader like any other (`DebugLog.reader()`) and prints every record as
  `[sssss.mmm] pid:tid> text`, and a `[dlog: n records dropped]` line
  for any it was lapped past. Lock order: debuglog -> object ->
  scheduler (the counter's observers run under the debuglog lock).
- Console: `ConsoleLock` serializes `Uart.write` calls between CPUs
  (recursive holders pass, waiters give up after 10^8 spins so a panic
  can't hang); the dumper's `writeLines` waits up to 50 ms for another
  CPU to finish a line it is writing in pieces.
- `ProgramLoader.start`: an ET_EXEC from kernel memory into a new process
  (each PT_LOAD copied into its own VMO, stack of PT_GNU_STACK's size or
  256 KiB) and a bootstrap channel whose first message is Zircon's
  processargs: PROC_SELF, THREAD_SELF, VMAR_ROOT, then the caller's
  handles (PA_FD 1 = stdout debuglog, PA_RESOURCE, ...), argv[0], the
  environment. PT_GNU_RELRO's pages are read only once relocated (K14c).
  Static PIEs load at a random base (K11b).
- User programs (`croi_user_program` in cmake/CroiUser.cmake): C and/or
  Embedded Swift, linked at 0x1000000 with separate page-aligned
  segments, against the floor (system/sys/floor, todhchai's, the one user
  runtime since D49: `_start` reads the bootstrap message,
  `td_startup_take`, stdout line-buffered into debuglog records, a
  size-class heap over 1 MiB VMO chunks in the root VMAR, threads' blocks
  and ELF TLS, a port per thread for its waits and sleeps; plus lib/rt's
  stack guard and 128-bit division) and the libc (libc.a, below).
  Swift user code imports `CroiRuntime` (user/include/module.modulemap:
  syscall.h, the floor's td_floor.h and td_native.h, and the libc's
  headers); the floor
  imports `CroiSyscall`; the ABI headers it reaches are module
  `CroiAbi` in kernel/include (which CKernel re-exports through abi.h), so
  user code never builds the kernel's private headers. The headers are the
  ABI's one source (D45): statuses, rights and object types are object.h's
  (the kernel's Swift enums need literals, so `swift test`'s AbiTests
  checks them against it), and `vx loc --check` refuses device code that
  makes a call by number, or through todhchai's `td_syscall6`. User Swift isn't
  bound by the kernel's no-ARC rule (low-half addresses). The boot test
  runs user/test/swift: stdout (read back through the ring), heap,
  environment; the `debuglog` suite checks the ring (D38).
- Sys (system/sys, todhchai's, V2): the typed API services use
  (`Handle`, `Channel`, `Port`, `Counter`, `VMO`, `Thread`...), its
  values SysABI's from the headers. Natively (`croi_user_sys`:
  modules SysABI, Sys, LibSys, `libsys.a`; a program built with `SYS`
  imports them) its backend makes V1's calls through syscall.h, the
  array calls with arrays, and reaches the floor through td_floor.h: a
  handle's wait and a counter's wait for a value are `td_wait_bind`'s
  ONCE binding on the thread's port, and `Thread.start` is
  `td_thread_start` (a floor stack that the thread unmaps as it exits).
  SwiftPM builds it over the hosted kernel (SysHost), which follows the
  same model: `swift test`'s SysTests, and natively `bin/sys-test` in
  bootfs (the boot-sys test, `userboot.next=bin/sys-test`). Not yet
  natively: `Process.start` (the loader comes with the launcher, V2's
  item 4).
- The libc (system/libc, todhchai's, V2): ISO C and POSIX in Swift
  (string, stdlib, stdio's printf family, strtod, ctype, libm), its C
  side for what Swift can't be (variadics, va_list, struct and long
  double returns, errno's `_Thread_local`), and its pthreads over the
  floor's threads and futexes. `croi_user_floor` builds three runtime-free
  Embedded modules in import order, LibC, Floor (getenv is LibC's) and
  PThread, into libfloor.a and libc.a, which every user program links:
  `mem*` and `strlen` are the libc's (lib/rt's stay the kernel's and
  the loader's). Its headers are user code's (`runtime.h` includes them).
  SwiftPM builds it hosted: `swift test`'s LibCTests and PThreadTests
  compare it with glibc. Natively the `libc` suite (LibcSuite.swift, its
  C side LibcSuite.c: printf's family can't be called from Embedded
  Swift, which has no `withVaList`) checks the exports, each arch's long
  double (x87's on amd64, binary128's elsewhere), the pthreads and ELF
  TLS. It found the floor copying a static PIE's TLS image from its
  unrelocated p_vaddr (`findTLS` now adds the load bias): no program had
  initialized TLS before. libm's constants are `vx mathgen`'s.
- dlopen (system/ld, todhchai's, V2): `Ld`, the dynamic linker's core
  (`Dynamic.swift`, pure: dynamic tags, GNU and SysV hash lookup, RELA
  relocations bound at load; no TLS, IFUNCs or copy relocations), and
  natively `dlopen`/`dlsym`/`dlclose`/`dlerror` (`<dlfcn.h>`), built as
  module Ld in `croi_user_sys` (libsys.a). A library is bootfs's
  `lib/NAME` (`croi_user_library`: PIC, linked with only its own code):
  its segments mapped as userboot maps a program's (`user/lib/loader`'s
  Segments and Bootfs, shared since V2, over lib/elf's ElfImage, which
  gained a machine parameter, PT_TLS and a public PT_DYNAMIC), relocated
  against the program's exports and the libraries before it, RELRO
  protected, initializers run; never unloaded. A host is an
  EXPORT_DYNAMIC program: the floor and the libc linked whole and
  exported (one heap), Sys and Ld kept out of its exports
  (`--exclude-libs=libsys.a`): a library compiles in what it uses of Sys,
  and exported they would keep code needing the Unicode tables (String's
  `==`; only amd64's Embedded toolchain has them) or the hasher's seed,
  which is also why Ld compares names as bytes. todhchai's ELF and bootfs
  readers were dropped for croi's (`docs/provenance.md`). `swift test`'s
  LdTests link a shared object for each machine and relocate it hosted;
  `bin/dl-test` (boot-dl) loads a C library and a Swift one natively.
- The trace (system/trace, todhchai's, V2, D50): `Trace`, the writer (a
  region a process is given as PA_TRACE_REGION; each thread claims a trace
  ring in it, a header and a one ring it writes through Ring.swift, its
  pointer in the floor's thread block slot 8), and `TraceSession`, which
  starts the kernel's trace, makes regions, and exports every ring
  compacted over the console (td-trace lines) for `vx trace collect`.
  Natively they are modules of libsys.a (Ring, TraceFormat, Trace,
  TraceSession); hosted, `swift test`'s TraceTests record into files and
  reassemble an export. `bin/trace-test` (boot-trace) records the kernel's
  IPC category and itself, checks that its FLOW steps and the kernel's
  CHANNEL_WRITE and CHANNEL_READ share a flow id, and exports; the
  trace-collect test reassembles that from the console qemu.sh keeps.
- Tier 1 (D47): programs in C, C++ and full Swift, built by the
  `*-vectraos` toolchain (`tools/toolchain`: the series renamed from
  todhchai's, its sources and builds in `.cache/toolchain`, outside the
  tree) against `build/<arch>/sysroot` (`cmake/Tier1.cmake`; amd64 only so
  far, for compiler-rt's builtins): the floor as libsys.a and the libc as
  libc.a with their `swift_*` symbols made local, the libc's headers and
  module map (SwiftVectraOSLibc), the floor's td_floor.h, and the ABI
  headers it includes (croi/syscall.h and the CroiAbi module's, which are
  why those spell their layout checks `_Static_assert`: the runtime's C
  shims are gnu11); then libc++, libc++abi and libunwind
  (`cmake/cxx.cmake`) and the Swift runtime and standard library
  (`build_stdlib.sh`). The tree builds as before without the toolchain.
  Tier 1 programs link `ET_EXEC` at 0x1000000 (the clang driver's croi
  link line, patch llvm 0003) and start at the floor's `_start`. The
  boot tests: floor-hello, cxx-hello, swift-hello, swift-start and
  swift-async (`user/tier1`).

## bootfs and userboot (K8b)

bootfs and userboot (K8b, Kernel/User/Userboot.swift, user/userboot,
vx mkbootfs):
- bootfs.img is Zircon's bootfs format (no ZBI around it), built by
  `vx mkbootfs` from the `bootfs` target (today `bin/m2`). The
  kernel adopts the loader's CROI_MEM_BOOTFS pages into an anonymous VMO
  (`Vmo(adopting:)`, `Pmm.adopt`: wired -> vmo; freed when the VMO goes).
- After "boot complete" the kernel starts userboot (an ELF in the kernel
  image, Embedded Swift, compiling lib/elf's source in) with
  `ProgramLoader`: root job, root resource, the root account (D31),
  bootfs VMO (with EXECUTE), the debuglog ring and its counter (D38),
  a stdout debuglog, and the command line's words as its environment
  (`BootOptions.withEnvironment`).
- userboot maps bootfs, finds `userboot.next=` (default bin/launcher;
  the build appends `userboot.next=${CROI_USERBOOT_NEXT}`, default
  bin/m2, to the ESP cmdline), loads its ELF into a new process
  (segments that are all file mapped straight from the bootfs VMO, others
  copied; stack from PT_GNU_STACK), passes on every handle it got plus a
  new stdout in a processargs message, starts it, waits, and prints
  `userboot: <name> exited with <code>`. Boot tests wait for that line
  with code 0 (`CROI_BOOT_DONE`).
- Syscalls added for it: `vmo_get_size` (44; since D36 the VMO info
  topic, through `croi_vmo_size`) and object_get_info CROI_INFO_VMAR
  (base, length). Embedded Swift `String ==` needs the
  Unicode tables (not linked): compare bytes.

## The M2 exit test and budgets (K8c)

The M2 exit test and budgets (K8c, user/m2, Kernel/Object/ProfileObject.swift,
include/profile.h):
- `bin/m2` is userboot.next (CROI_USERBOOT_NEXT): channel pair, a VMO
  passed across, a port wait for a counter's value then to a deadline
  (V1 cut timer objects, D25), debuglog output; then
  it measures the budgets from the trace (user marks via TRACE_OP_RINGS, 4:
  each CPU's ring as a read/map-only VMO) and reports them as `budget`
  lines (K9f: enforced only with `croi.enforce_budgets=1` where
  `Sys.timingIsReal`, CPUID's hypervisor leaf through the floor's
  `td_cpuid`; see "Timing discipline"). KVM: null 32-36 ns,
  channel_call ~1.4 µs (target 1 µs, enforced against 1.6 µs for now),
  port wake median ~1.75 µs (p99 noisy, not enforced), wake error p99
  27-46 µs. Measure wake error with `Sys.now()` directly: converting trace
  counter time from an anchor mark was off by up to 170 µs. Since V1 cut
  events and the thread waits (D23), the port wake binds ONCE to a
  counter's POSITIVE signal and the waker adds to it, handshakes are
  counters, joins wait on ports, and the channel_call server drains a
  PERSISTENT binding of its channel.
- Profile objects (25): `profile_create` (120, profile system resource
  base 10 or root; zx_profile_info_t), `object_set_profile` (121: MANAGE_THREAD on
  the thread, APPLY_PROFILE on the profile), refusal reasons (ext 4) in an out-parameter.
  Test-only syscall 6 is still used by the kernel self-test.
- Under a hypervisor an idle CPU polls for `croi.idle_poll_us` (default
  200, 0 on hardware) before halting, announced in `pollingCpus`, so a
  cross-core wake skips the IPI (and its VM exits).
- `m2.ipc_profile=1` on the command line (K14l): after the channel_call
  batches m2 traces 200 more with syscall, scheduler and IPC records (and
  any kernel `CROI_TK_MARK` probes added while chasing something) and
  prints a call's events with the median gap before each, then samples PCs
  at 10 kHz over 300,000 calls and prints the top ones (kernel ones as
  image offsets with bit 63 set; samples land where interrupts come back
  on, so masked stretches show at their end).
- `m2.wake_profile=1` (K14n): one fair thread, then four, timing out on a
  port every 5 ms (Todhchai's executor), printed as lateness (deadline to
  user space by the vDSO clock) split into the timer interrupt arriving
  late and the kernel's interrupt-to-user path, plus a few wakes' records.
- `m2.portwake_profile=1` (K14o): the port wake bench again, traced,
  each wake's records from both CPUs merged in time (counter_add entry
  to port_wait exit), median gap before each.
- Timed wakes under KVM (K14n): every VM exit cost ~4-5 us on this host.
  `LocalApic.endOfInterrupt` uses KVM's PV EOI where offered (per-CPU
  words in one page, MSR 0x4B564D04; `croi.pv_eoi=off`), testing and
  clearing the bit in one instruction (`arch_test_and_clear_bit0`, btr):
  KVM may clear it at the exit it takes for a newly pending interrupt, and
  a separate test and clear skipped the needed EOI write, leaving the
  vector in service (half the full KVM boots hung). An x86 timer interrupt
  no longer disarms the spent TSC deadline. Under a hypervisor the timer
  hardware is armed early by `Timers.wakeLead` (a running average of how
  late interrupts came after the armed time, capped at 50 us;
  `croi.timer_lead=off`) and the interrupt waits out the rest, so timers
  still never run early. A fair thread's 5 ms port_wait timeout: ~3-6 us
  late (median), from 15-40.
- Hot-path notes from the budget work: `Scheduler.locked` drops the lock
  through `cancelTimeout` (one round trip); `Timers.arm` writes the
  hardware only for a sooner timer and `cancel` leaves it armed (the
  invariant: armed no later than the earliest pending `latest`; the
  interrupt re-arms via `program`); amd64 saves with XSAVEOPT; the heap's
  double-free walk runs only for an object still poisoned;
  `UserAspace.covers` binary-searches; `ObjectWait.one` returns at once
  if the signals are already set. Channel and port default rights are
  Zircon's (no DUPLICATE; ports no WAIT). -O was worse than -Osize.
