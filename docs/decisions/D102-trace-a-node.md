# D102. trace: proc serves the kernel's trace, and vx names its samples (2026-10-18, decided; extends D50, D79)

The cpu link's remaining cost (roadmap, "The link's throughput") is CPU
time in net, the virtio-net driver and the cpu server, about 16 µs a
frame, and finding where it goes needs a profile of the node. The kernel
already samples (K6e: a SAMPLE record a tick or a PMU overflow, the PC
and up to 16 return addresses by frame pointer, user frames through a
syscall), and TraceSession (D50) already reads its rings. What was
missing: a service holding the tracing resource, a way to say which
program an address is in, a way off the node faster than the debuglog
(about 110 KB/s), and names. D79's board tools left `trace` waiting for
where its trace goes.

- **proc(4) serves `/proc/trace`**, as Plan 9's devproc serves
  /proc/trace to trace(1). proc already holds every process under the
  launcher, which is what naming samples needs: each process's trace
  task (`CROI_INFO_THREAD_TRACE`, a thread's id shifted right 12) and
  the mappings it may run (`CROI_INFO_PROCESS_MAPS`). `ctl` takes `start
  [hz N] [pages N] [CATEGORY ...]` (samples always on) and `stop`;
  `kernel.trace` is TraceSession's kernel file; `procs` is text, the
  processes seen at the start and the stop with their executable
  mappings. No second recorder: proc drives TraceSession.
- **A `tracing` manifest directive.** The launcher carves the tracing
  range from its system resource, as it carves VMEX for push, and grants
  it as argument 1 of PA_SYSTEM_RESOURCE; only proc's manifest asks.
  Granting proc the whole system resource would give it power, MSIs and
  the IOMMUs.
- **Mappings say where code came from by their VMO's name**, not by a
  new record: the launcher names bootfs `bootfs`, bootfs(4) names each
  file's child after its path, and a pushed build is `push:NAME`. The
  loader maps read-only code straight from those VMOs, so a mapping's
  VMO offset is an offset in the bootfs image, in a file, or in the
  pushed file. (The design first named each segment's VMO in the loader;
  code segments have none of their own, so that would have meant a child
  per segment, which costs every process start.)
- **The trace goes to the dev machine through /mnt/term.** trace(8) is an
  rc script: start, `sleep` (a new command, Plan 9's sleep(1)), stop,
  and `cp` of the two files to a directory, under /mnt/term in a cpu
  session; the link carries tens of MB/s. `vx remote trace` runs it in
  one step, as `vx remote boot` runs warmboot.
- **vx names the samples from the build.** `vx trace profile` reads
  kernel.trace and procs, places each address (a kernel offset, or a
  mapping's VMO offset), and names it from the kernel ELF and the bootfs
  image's own ELFs (the build keeps them unstripped), with a .symtab
  reader of its own in ImageFormats and the Swift runtime's demangler;
  no llvm-symbolizer. It counts by process and by function, own and
  inclusive, and prints folded stacks for flame graphs.

**Checks.** ProcTests drive `/proc/trace` over a fake kernel; TraceTests
put samples together and count them; ImageFormatsTests name addresses in
a made ELF, in bootfs and the kernel; LaunchTests grant `tracing` only
when allowed; CommandsTests time `sleep`. boot-cpu profiles the node for
two seconds during copies and expects samples of net named from net's
ELF, and the kernel's.

**Limits.** Function names, not lines (no DWARF reader yet: roadmap's
debugger). A process that starts and ends within a recording isn't in
procs. Nothing checks that the bootfs vx reads is the one the node ran.
One recording at a time.

Rejected: a tracing service of its own beside proc, which would ask proc
for every process's threads and mappings. Rejected: the debuglog export
TraceSession already has (the console's 110 KB/s would take minutes for
a second at 1 kHz on four CPUs). Rejected: a mapping record in the trace
format (D10's records stay as they are; procs is read once, beside it).
