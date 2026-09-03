# The arm64 and riscv64 ports

`kernel/arch/arm64/`, `kernel/arch/riscv64/`, `kernel/arch/arch_arm64.odin`,
`kernel/arch/arch_riscv64.odin`, `sys/libuser/sys_arm64.odin`,
`sys/libuser/sys_riscv64.odin`, `kernel/user/programs_arm64.S`,
`kernel/user/programs_riscv64.S`, `kernel/link_arm64.ld`, `kernel/link_riscv64.ld`

Vectra was written on amd64 with the other two architectures as a promise:
`arch` is the only CPU-facing import, and a port is a matter of blanks to
fill in. This document records what filling them in took, what each port has,
and what it has not got yet. `docs/BOOT.md` still owns the trap path and
`docs/MEMORY.md` the walk, because neither changed shape. What changed is
written here.

Both ports boot under Limine on QEMU's `virt` board, on UEFI firmware:

    odin run build.odin -file -out:.vectra-build -- run --arch=arm64
    odin run build.odin -file -out:.vectra-build -- run --arch=riscv64
    odin run build.odin -file -out:.vectra-build -- check --arch=riscv64

## 1. What the promise cost

The portable kernel was portable in its imports and not quite in its
vocabulary. Five things named amd64 from outside `kernel/arch`, and each is
now a neutral name every architecture binds:

- **The trap frame's registers.** `kernel/user` read `frame.rax` for a
  system call's number, `frame.rdi` for its first argument, and wrote
  `frame.cs` back when a program handed a frame in through `noted`. Those
  are `arch.syscall_request`, `arch.set_syscall_result`, `arch.frame_ip`,
  `arch.frame_sp`, `arch.frame_call_handler` and `arch.frame_sanitise_user`
  now, in `<arch>/frame.odin`. A frame is opaque above the line, and the
  door's calling convention is one file per architecture on each side of it:
  `sys/libuser/sys_<arch>.odin` puts the number where `frame.odin` reads it.
- **The calling convention.** `proc "sysv"` names one architecture's ABI,
  and the compiler refuses it on the other two. Every procedure the assembly
  enters or that the bootloader calls is `proc "c"` now, which is the same
  convention on amd64 and the native one elsewhere.
- **The bootloader's per-core record.** A core is a LAPIC id, an MPIDR or a
  hart id, and the response layout differs with it. `kernel/boot/limine`
  has one file per architecture behind `mp_cpu_id` and `mp_bsp_id`, and the
  paging mode each port pins is beside it.
- **The console.** `kernel/drivers/uart` drove a 16550 behind x86 port I/O
  and imported `amd64` to do it. It drives four consoles now, through one
  `Port`: the same chip behind ports or in memory, ARM's PL011, and a
  firmware console reached by a call. `arch.serial_console` says which the
  machine has, and section 3 says why one of them has to map its own way in.
- **The boot lines.** `traps: cs 8, tr 30` is a fact about a GDT. Each
  architecture writes its own line through `arch.describe_traps`, and the
  timer and interrupt controller lines name themselves through
  `arch.TIMER_NAME` and `arch.IRQ_CONTROLLER_NAME`.

Nothing in `kernel/sched`, `kernel/mem`, `kernel/vfs` or below changed. The
walk, the switch, the locks and the wire run on all three as written.

## 2. The assembly

The rule from `docs/HANDOFF.md` holds: anything that defines a symbol, is
entered by the CPU, or needs a loop is a `.S` file clang assembles, and
everything else is a template. Each port has three files and a placeholder:

| File | What it is |
|---|---|
| `arm64/vectors.S` | the sixteen-entry vector table and the tail that saves every register and the vector unit, calls into Odin, and restores whichever frame comes back |
| `riscv64/vectors.S` | the one trap entry `stvec` names, the `sscratch` dance that finds a kernel stack for a trap from a program, and the same tail |
| `<arch>/ap.S` | the stack switch a released core makes |
| `<arch>/fpu_hold.S` | four vector registers held live across a preemption, for the scheduler's self-test |
| `kernel/user/programs_<arch>.S` | thirty-one program symbols, each a single trapping instruction: see section 6 |

**The templates are bytes.** The checker behind `asm` knows each
architecture's general instructions, and not the ones a kernel is made of.
`msr daifset`, the barriers, `tlbi`, `brk`, `svc` and `wfi` on arm64;
`ecall`, `ebreak`, `wfi`, `sfence.vma`, `pause` and a read of `sp` on
riscv64: each either has no operand form the checker accepts or is modelled
as an instruction nothing falls through. Every one is a `#byte` sequence in
`<arch>/cpu.odin`, annotated with the mnemonic clang assembles it from, and
clang was the oracle that produced the bytes. A register in a byte sequence
is the one the binding beside it pins, `x0` or `a0` throughout. The riscv64
CSR instructions the checker does know are spelt by number, with the name
beside each.

## 3. What each port has, and what it does about it

### arm64

- **Runs at EL1 on SP_EL1.** The protocol enters with `PSTATE.SP` clear, on
  the register a program will own, and with the vector unit off.
  `early_init` selects SP_EL1 and turns the unit on before any Odin runs,
  for the reason `arch.early_init` exists on amd64: the first struct move
  is a vector instruction.
- **Two base registers, one root.** The VMM has one root per address
  space with the kernel half at entries 256 and up. `TTBR1_EL1` holds the
  kernel root always, with `T1SZ` 16, and `TTBR0_EL1` holds a user root
  with `T0SZ` 17, so a user address indexes only entries 0..255 of the table
  it names. The bootloader's direct map is at `0xffff_0000_0000_0000` plus
  a slide, which is entries 0..127 of the kernel root, and `is_canonical`
  accepts a 48-bit kernel address for that reason. A kernel thread's TTBR0
  is the early window below, so a null dereference in the kernel still
  faults. `paging.odin` argues it.
- **A window for the console.** The protocol maps memory and the
  framebuffer and nothing else, and the PL011 is a device. Four static
  tables in `early.odin` map its one page at its own physical address
  through TTBR0 before there is an allocator, and `main.odin` moves the
  port onto the kernel's own mapping the moment the VMM is up.
- **The GIC, version 2.** One controller does the local APIC's job and the
  I/O APIC's. `gic.odin` speaks the memory-mapped distributor and CPU
  interface at `0x0800_0000`, which is where QEMU's `virt` board puts them
  when `gic-version=2` is on the command line, and `build.odin` puts it
  there.
- **The generic timer.** `CNTFRQ_EL0` is the rate, so there is nothing to
  calibrate against. The EL1 physical timer fires once, and the acknowledge
  re-arms it.
- **The vectors.** GIC interrupt ids as they are, 0..1019; the GIC's
  `nothing pending` as the spurious vector; `svc #0x401` and `#0x402` from
  the kernel for the yield and the interrupt bracket's test; any `svc` from
  a program as the door.

### riscv64

- **Runs in supervisor mode above OpenSBI.** The firmware is the console,
  the timer and the way to another hart, through `ecall`. `sbi.odin` has
  the four calls this kernel makes.
- **The console is the firmware's.** No mapping, no window, no register.
  The 16550 at `0x1000_0000` waits for something that wants it directly.
- **`ecall` cannot trap into this kernel.** From supervisor mode it is the
  firmware's door, and no delegation changes that. The kernel's synchronous
  trap into itself is `ebreak`, with a number in `a7`: zero for a
  breakpoint, a software vector otherwise. A program's `ecall` is the door,
  and it is delegated.
- **The stack for a trap from a program.** The hart switches no stack.
  `sscratch` holds this hart's per-CPU record while a program runs and zero
  while the kernel does, and the first instruction of the entry swaps it
  with `tp` to learn which. `vectors.S` describes the dance.
- **The clock rate is in the device tree.** There is no register for it.
  `early.odin` parses just enough of the flattened tree to find
  `/cpus/timebase-frequency`, and a tree it cannot parse is a timer that
  says it will not calibrate.
- **The PLIC.** Source numbers from 1, a supervisor context per hart at
  `2h + 1`, and enable bits that are the mask. Sv48, pinned, which is the
  same four-level tree with the same 47-bit halves amd64 has.
- **The vectors.** Exception causes 0..15 are traps. Interrupt causes sit
  at 16 and up, so the timer is 21. PLIC sources sit at 32 and up. The
  software vectors sit at `0x81` and up. An `ebreak` carries one in `a7`. A
  software interrupt carries no number of its own, so the sender leaves a
  set of them in the receiver's per-CPU record.

## 4. Where the boots stand

Both boots run the same `kmain` amd64 runs, self-tests and all. On the
`virt` boards at the time of writing:

| | arm64 | riscv64 |
|---|---|---|
| traps, breakpoint round trip | passes | passes |
| memory: PMM, VMM, heap, the three self-tests | passes | passes |
| Vectra9, the namespace | passes | passes |
| the cooperative scheduler | passes | passes |
| the timer, preemption, every lock and queue suite | passes | passes |
| devfs, srv, pipe, the wire, the posted service | passes | passes |
| address spaces, the door | passes | passes |
| ring 3 | the Odin programs run (section 6) | the Odin programs run |
| the user self-test | 267 of 783 fail, on the placeholders | the same |
| the four cores | all online | all online |
| `boot complete` | eight boots in ten | two in two |

The arm64 count is the honest one, and `docs/HANDOFF.md` section 6 has the
two shapes the other two boots took. riscv64 has been booted whole twice at
the time of writing.

## 5. What is still one architecture's

- **The non-maskable stop.** The panic path stops the other cores with an
  interrupt they cannot mask. Neither port has one. The arm64 stop is an
  SGI and the riscv64 stop is a software interrupt. A core inside a spinlock
  takes neither until it lets go, and until then it can write over the
  report.
- **The keyboard.** There is no PS/2 controller on either board, and
  `kbd.init` says so by reading all-ones from a port that is not there.
  Input is the serial line.
- **The 16550 on riscv64** is reached through the firmware and not mapped.
- **The device tree** is parsed for one property. The GIC, the PLIC and
  the UART addresses are the `virt` board's, assumed as the I/O APIC's is
  on amd64.
- **Big.LITTLE.** `cpu_class` answers `.Performance` for every core. The
  scheduler already knows the three tiers, and the MIDR table that would
  fill them in is not written.

## 6. The programs that are not ported

`kernel/user/programs_amd64.S` holds thirty-one ring 3 programs in x86-64
assembly, one per check in `kernel/user/verify.odin`. They are the spinner
the tick catches, the pokers and peekers that fault on purpose, and the one
that answers 9P by hand. Each port needs them again in its own assembly.
None are written yet. `programs_arm64.S` and `programs_riscv64.S` carry
every symbol as one trapping instruction. The kernel links, and a program
that runs ends on its first instruction rather than on nothing.

The user self-test therefore fails on the ports, loudly and by the hundred,
and that is the intended report. What it also shows is worth a line. The
build driver compiles six Odin programs for ring 3: the ramfs, the console
server, the draw server and the rest. They are ordinary packages. They run
on arm64 as built, through the door in `sys_arm64.odin`, and the lines they
write reach the serial port.

## See also

- `docs/BOOT.md` -- the trap path and the boot order, which the ports keep
- `docs/MEMORY.md` -- the walk the ports supply an encoding for
- `docs/SMP.md` -- how a core arrives, which is the same on all three
- `docs/HANDOFF.md` -- where the ports stand, and what to do next
