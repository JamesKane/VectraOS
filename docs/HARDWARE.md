# Metal: the OrangePi 6 Plus, and a driver model for hardware Plan 9 never saw

**Written before the code.** Every port in `docs/PORTS.md` boots on a
board QEMU invented. The GIC is where QEMU puts it, and the disk is a
virtio device QEMU attaches when the build asks. This is the plan for a
board a person can buy: the OrangePi 6 Plus, on the CIX Sky1 SoC.

That SoC has twelve cores in two tiers, an Arm GPU with a command stream
front end, and a neural processor. It has five display processors, five
PCIe root ports, ten USB controllers, and firmware the OS must ask for
every clock and every power domain. None of that existed when Plan 9 was
designed. Every operating system since answered it with a driver model
this tree refuses. This document says what Vectra does instead, and in
what order.

The audience is the person this system is for. A hobbyist, a hacker, or
an indie game developer who wants the whole machine in their head and
under their program. `docs/HANDOFF.md` section 6 points here.

## 1. What is taken, and from where

**From Plan 9.** A device is a directory of files, and a driver is what
turns registers into files. A `ctl` file takes a line of text, and a
`data` file takes the bytes. A `status` file answers what the device is
doing, and `ls` is the inventory. A program that wants the hardware reads
a file in its own namespace, and one that wants a fake binds a fake over
the name. `#c`, `#S` and `/dev/fb` are that idea in this tree already,
and nothing below adds a second one.

And one call Plan 9 had that this tree kept: `segattach`. The screen is
memory a process holds, and a draw is a store. Section 4 extends that
call in the direction the hardware moved.

**From the hardware, one thing Plan 9 did not have.** Plan 9 kept its
drivers in the kernel because a driver programs a device to write memory,
and a device writes wherever it is told. A process that could program a
disk controller could overwrite the kernel. That is the whole reason a
driver was privileged.

Every SoC of this decade puts a memory management unit between a device
and memory. Arm calls the shared one the SMMU, and the GPU carries one of
its own. A device behind either sees an address space the kernel chose,
and nothing outside it. That is the change that makes a ring 3 driver
safe, and section 3 is built on it.

**From Carmack, Blow and Muratori.** The direct path is the fast path.
A program that owns a queue in memory and rings a doorbell submits a
frame with no call into anything. An interface is a description of data
in memory, not a sequence of calls into a library that guards a second
library. A stack a person can read end to end is one a person can make
fast, and fix at three in the morning. Measure the path rather than
trust it.

The kernel's job is then three things. Hand a program the hardware's
memory and the hardware's queue. Keep the program from damaging anything
else. Step aside.

Muratori's argument in *The Thirty Million Line Problem* is the closest
statement of this plan's aim. He asks for hardware with a stable
interface, so an operating system needs no driver at all. Nobody can
change the silicon. What this tree can change is the size of the thing
between a program and it. A driver here is the smallest program that gets
a device to a directory. Everything above the directory is a library a
program links and can replace.

**Not taken, and why.** Section 2 names the models this refuses. Each
has the same shape. The kernel owns the resource model, the model is a
private namespace of handles, and the policy sits beside it in the same
privileged code. A program cannot list what it holds, cannot substitute a
fake, and cannot see what the driver decided. The cure is the namespace
this tree already has.

## 2. The models this refuses, and what each got wrong

People who knew the hardware built each of these, under constraints this
tree does not share. The refusal is of the shape, not the people.

**Linux DRM.** A kernel driver per GPU vendor with its own table of
operations, thirty for one vendor and sixty for another, each a struct
the vendor defines. Buffers are handles in a second namespace the file
system cannot see. Synchronisation is three primitives, and a program
needs all three. A userland driver of a million lines sits on top and
speaks a private protocol to its own kernel half. The mode-setting half
alone is larger than this whole tree. It works, and a game on it runs
through five layers before a triangle reaches silicon.

**Windows.** The display driver model pages video memory, preempts the
GPU, and owns a scheduler of its own inside the kernel. The interface a
program sees is a runtime per graphics API, each a library that guards a
driver. A program cannot reach the queue, and the runtime decides when
the queue moves.

**The vendor tree.** The board's own Linux carries the facts section 5 is
built from, and two shapes this plan leaves there. Its NPU driver is not
in the tree at all. What is there is a header of nineteen `ioctl` calls,
matched to a runtime nobody outside the vendor can rebuild. Its display
stack is a component of six drivers wired together at boot, and its
sound card is switched off in the board's own description.

The OS is stuck on the kernel the vendor shipped, because the interfaces
are the vendor's. `/Users/jkane/Development/linux-orangepi` is that
tree, and section 5 says what this plan takes from it, which is facts
and not shape.

**The machine learning API in the operating system.** Every vendor of a
neural processor ships a different kernel interface and a closed
compiler. Every platform answered with a graph format baked into the OS.
A graph format is a research result with a half life of about three
years. An OS that owns one owns a museum. Section 8 says what this tree
does instead, which is memory, a queue, a completion, and nothing else.

**The common thread.** In each, the resource model lives in the driver:
handles, contexts, buffers, fences, each in a namespace of its own that
no tool can list. Plan 9's answer is that the namespace *is* the resource
model. A context is a directory, a buffer is a file with a size, and a
fence is a read that parks. `ls` lists them, `cat` reads them, and a
test binds a fake over any of them.

Nothing here is new. What is new is that the hardware can now afford it.
A memory management unit in front of a device makes the memory a program
holds the only memory its device can reach.

## 3. The driver model: five things the kernel does

A device here is a node in the device tree the firmware hands the
bootloader, and the kernel publishes that tree as files. Everything a
driver in ring 3 needs is then a name.

    /dev/tree/                      #t, the flattened device tree as a
                                    directory per node, a file per property
    /dev/tree/soc/gpu@15010000/
        compatible                  the property, as the tree spells it
        reg                         the property, raw
        interrupts                  the property, raw
        mmio                        the node's register window, attachable
        irq                         one file per interrupt line, a read parks
        dma                         the node's walker: a `ctl` that binds it
                                    to a process's address space, and a
                                    stream of the faults it takes

The three synthesised files are the whole of what the kernel adds, and
each is one of the five things below.

**One: it knows what is there.** `#t` is a read-only server over the
tree, in the shape `vfs.static` already has. A property is a file whose
contents are its bytes. A node is a directory. `ls /dev/tree/soc` is the
hardware inventory, and `cat compatible` says which driver to start.

On the `virt` boards the same tree carries the GIC, the UART and the
PCIe window. So the bases `docs/PORTS.md` section 5 assumes become reads
of `reg` under this plan. That is the first step, and it needs no board.

**Two: it maps the registers.** `mmio` is a device file in `/dev/fb`'s
shape: a size, an offset, and `segattach` through the descriptor. A
process that can open it can attach it, and the namespace is the
permission, as `docs/DRAW.md` section 7 argued for the screen. The
mapping is device memory, uncached and ordered, and the kernel says so in
the page table rather than trusting a program to fence. One page of a
window may be absent from `mmio`, and the fourth thing says which.

**Three: it delivers the interrupt.** `irq` is a stream. A read parks
until the line fires, and answers one line with a count. The kernel's
handler masks the line at the controller, acknowledges, and wakes the
reader. The next read unmasks. That is the level-triggered handshake.

It is also why a reader that goes away cannot storm the machine. The
line stays masked with nobody to unmask it, and the last close masks it
for good. `docs/KBD.md` has the two-call ordering this keeps: route, then
unmask. A message-signalled interrupt is the same file over the GIC's
interrupt translation service, and section 5 says which devices raise
one.

**Four: it programs every walker.** `dma` is the device's memory
management unit, whichever it has. For most nodes that is a stream id on
the SMMU. For the GPU it is the address space registers of the GPU's own
unit, which is why one page of its `mmio` is withheld. The kernel
programs both, and a driver never sees a physical address.

A write of `attach <slot> <pid>` binds one of the device's address
spaces to that process's tables. The device then sees what the process
sees and nothing else, and section 4 is the argument. The kernel refuses
the line unless that process holds a file the writing driver serves. A
driver may therefore bind its device only to a process that is already
its client. That one check makes the line a capability rather than a
privilege.

A device with no `dma` file has no bus mastery. The console UART and a
GPIO block are two, and a driver for either needs no address space.

**Five: it keeps what has to be earlier than a program.** The UART the
kernel logs on, the timer, the interrupt controller, the SMMU itself,
and the firmware calls for cores, clocks and power. Each is the shape
`kernel/arch/arm64` has today with a base read from the tree. The
framebuffer the firmware hands over stays the kernel's until section 6
replaces it.

**Everything else is a program.** The disk driver, the USB stack, the
network card, the display processor, the GPU and the NPU each run in
ring 3. Each is embedded in the image as `servers/ramfs` is, `init`
starts it, and a mount names it. Each opens its node's `mmio`, `irq` and
`dma`, and serves the device as files of its own. The shape is `kbdfs` over
`/dev/scancode`, one layer further down.

A driver that faults ends a process, and the walker means it ended
nothing else. The reaper hangs up its clients, `docs/USER.md`, and `init`
starts it again.

**A device file a program serves.** A driver in ring 3 holds a register
window and wants to hand one page of it to a client. The GPU's doorbell
is the case. A kernel server answers `segattach` through
`vfs.Server.device`, and a ring 3 server has no such hook. It answers
through the wire instead.

The kernel reads the file's `device` extended attribute, which 9P2000.L
carries, and gets `base length` back. It then checks that the range lies
inside a segment the serving process itself holds. A server may hand on
what it holds and nothing else.

That is the capability discipline of section 4 applied to a page, and it
costs no message the wire does not have. The same rule lets a server
hand on a page of its own memory, which section 7's sync page needs.

**What that costs, and where.** A device interrupt is a wake of a parked
reader, which is a schedule and a switch, about the cost of a system
call. For a disk, a network card or a keyboard that is nothing. For a GPU
it is the wrong tool anyway, and section 7 says what a game waits on
instead. A register access is a load or a store through a mapping, at
the same price the kernel pays. There is no copy on either path.

## 4. Memory a device sees: one root, two walkers

`segattach` gives a process the screen. The hardware moved the other way,
and this section moves with it: the device attaches to the process.

**The address space a device walks is the process's own.** On arm64 a
process's lower half is the tree `TTBR0_EL1` names, and the kernel half
is a second tree in `TTBR1_EL1`. The SMMU's stage 1 walks the same table
format the CPU does, and so does the Mali GPU's unit in its AArch64 mode.
So a device's address space is one register write: the physical address
of the process's own root. The device then sees the process's lower half,
every page of it, with the process's permissions. It cannot form an
address in the kernel's half, because that tree was never named.

A pointer is then a pointer. A program builds a command stream in memory
from `segalloc`, and the GPU reads it at the address the program wrote it
at. No handle names a buffer, no call maps one, and no table translates
between two views of one page. That is the property the performance
argument in section 1 asks for, and it costs the kernel no code that
`kernel/mem/space.odin` does not already have.

**A shootdown reaches the device.** `docs/SMP.md` says an unmap reaches
every core's TLB. A device holds a TLB too, and an unmap that missed it
leaves the device able to read a page the process gave back. So a space
carries the list of walkers attached to it, and `unmap` sends each one
its own invalidate. The SMMU takes it on its command queue and the GPU
in an address space register.

That is the one addition to `space.odin`, and it is the cost of the
design. A page that leaves a process leaves it for every walker.

**A walker that does not snoop reads the tables from memory.** The GPU
on this SoC is not coherent with the CPU's caches, section 5. Its walker
reads a page table entry from DRAM. An entry the kernel wrote and left
in a cache line is an entry the GPU does not see. So `map_at` and
`unmap` clean the line they wrote when the space has such a walker
attached. That is one instruction at the one place entries are written,
and a space with no walker pays nothing.

**Attributes differ, and the kernel owns them.** The CPU's memory
attributes come from `MAIR_EL1` by index, and a device's from its own
attribute register. A table shared between them has to mean the same
thing at each index. The kernel programs both registers to one table.
Normal cacheable memory is the same index in each, and device memory the
same. That is a boot-time invariant, checked once, rather than a rule per
mapping.

**Coherence is a fact about the port, not a policy.** Whether a device's
port on the interconnect snoops the CPU's caches is a hardware fact, and
section 5 records it per device. Where it does, a store is visible to
the device after a barrier. Where it does not, the program cleans the
lines it wrote, with a call the library makes beside the doorbell. A
program never guesses. The node's `dma` file reports which, on read.

**A process that ends takes its devices with it.** `space_destroy` walks
the attached list before the tables go, and detaches each walker by
pointing it at an empty table. A device that was mid-transfer faults
into the kernel rather than into freed memory. The fault is a line on
the node's `dma` file for its driver to read. That is the fault rule
`docs/USER.md` argues, extended by one walker.

**`segalloc` takes an address.** Plan 9's `segattach` takes a virtual
address and Vectra's `segalloc` does not, because nothing needed one. A
firmware binary does: the GPU's has sections that name where in the
address space they must land. So `segalloc` grows an address argument, a
zero meaning what it means today. That is the whole of the kernel change
the firmware asks for.

**What this refuses.** A separate device address space with its own
allocator, as every driver model in section 2 has. The two-view design is
where the buffer handle came from, and the handle is where the second
namespace came from. One root removes the reason for both.

## 5. The board

The facts below come from the vendor's device tree and drivers. The tree
to read is `arch/arm64/boot/dts/cix/sky1-orangepi.dtsi`, which the board
file `sky1-orangepi-6-plus.dts` overrides node by node. `sky1.dtsi` is a
newer copy of the same SoC, and it is the one that tells the core types
apart. Nothing includes `sky1-orangepi-6-plus.dtsi`, and it is not to be
read.

### The SoC, and what the kernel drives

| | What it is | Where |
|---|---|---|
| Cores | 4 Cortex-A520, capacity 403, and 8 Cortex-A720, capacity 1024, one DSU cluster with 8 MiB of L3 | MPIDR `0x000` to `0xb00`, one core per affinity-1 value |
| Firmware for cores | PSCI 1.0 over SMC | `psci` node |
| Timer | the generic timer at 1 GHz | PPI 14 for EL1, as on `virt` |
| Interrupt controller | GIC-700, a GICv3, with an interrupt translation service for message-signalled interrupts | distributor `0x0e01_0000`, twelve redistributors at `0x0e09_0000` plus `0x4_0000` per core, the ITS at `0x0e05_0000` |
| Console | a PL011, the same part `virt` has, at 115200 as the firmware left it | `0x040d_0000`, SPI 298 |
| Memory | LPDDR5, from `0x8000_0000`, the amount the firmware's map says | the tree names 4 GiB and the boards ship more |
| The firmware's framebuffer | a live linear framebuffer the display processor scans out, 32 MiB reserved | `0x8480_0000` |
| SMMU | three SMMUv3 instances: one for the display and media masters and the NPU, one for PCIe, one for the on-chip network ports | `0x0b1b_0000`, `0x0b01_0000`, `0x0b0e_0000` |

The tree lists all twelve redistributor bases, at a stride of
`0x4_0000` rather than the `0x2_0000` the architecture's minimum would
give. A GICv3 driver that assumed the minimum would program eleven wrong
addresses, so the driver reads the list.

The vendor enables only the first SMMU. The PCIe one is present in the
silicon and switched off in the tree. So the disk and the network cards
run with flat physical addressing under Linux. This plan switches it on,
because section 3 depends on it. If the part refuses, the drivers behind
it run trusted, and the document that builds them says so.

### Two firmware agents, and what each is for

Nothing on this SoC has a memory-mapped clock controller. Every clock
and every performance domain is a request to the power management core
over SCMI. The transport is a mailbox pair at `0x0659_0000` and
`0x065a_0000`, with the shared memory inside the mailbox window. That agent speaks the
performance, clock and sensor protocols. Every temperature on the chip
is a sensor read through it, and there is no thermal register to read
instead.

Device power domains go the other way, to the secure firmware over an
SMC with id `0xc200_0001` and shared memory at `0x8438_0000`. The GPU,
the display processors, the NPU cores, the video codec and the PCIe
controllers are each a power domain there. So a driver that needs its
device on asks the kernel, and the kernel asks two firmwares.

Below those sit a boot ROM, a primary bootloader, TF-A, the power
management firmware, OP-TEE and UEFI, in that order. Their versions are
in a table at `0x83e0_1000`. An embedded controller on an I2C bus at
address `0x76` owns the fan, the power button and the battery, with
firmware of its own. Two USB-C power delivery controllers at `0x30` and
`0x31` on another bus own the ports' orientation and alternate mode.

### The accelerators

| | What it is | Where |
|---|---|---|
| GPU | an Arm Mali of the Valhall family with a command stream front end, three interrupt lines for jobs, its MMU and the GPU itself, not cache-coherent, with its own MMU and no SMMU stream | registers `0x1501_0000`, a reset and clock unit at `0x1500_0000`, SPIs 237, 238, 239 |
| Its firmware | `mali_csffw.bin`, loaded by the driver into memory the GPU's microcontroller boots from | `/lib/firmware` |
| NPU | an Arm China Zhouyi V3, three cores behind one SMMU stream, no firmware, a 64 KiB register block | `0x1426_0000`, SPI 327, stream `0x1e` on the first SMMU |
| Video codec | an Arm China Linlon V8 with four cores, no driver in the vendor tree | `0x1424_0000`, SPI 326 |
| Image processor | an Arm China i7, with four MIPI receivers and no camera on this board | `0x1434_0000` |
| Audio DSP | a HiFi5 with its own firmware blob | `0x0700_0000` |

The GPU's page tables have to reach memory before the GPU walks them,
section 4. The vendor driver cleans its own table writes the same way.
The NPU sits behind the SMMU and its coherence is that port's.

### The screen

There is no HDMI transmitter on the SoC, and no MIPI DSI. Every output
is DisplayPort. Five display processors, Arm China Linlon D6 parts
descended from Arm's Mali-D71, at `0x1401_0000` and every `0x7_0000`
after, each feed one DisplayPort transmitter. The fifth drives a Parade
converter that makes HDMI. The first two reach the two USB-C ports as
alternate mode, under the power delivery controllers, and the third
drives an embedded panel connector.

Each transmitter carries its own interrupt, SPIs 332 to 336, and each
processor its own, SPIs 316 to 324 in steps of two.

The firmware programs the fifth pair and leaves it scanning the
framebuffer at `0x8480_0000`. That is what Limine hands `kmain`, and it
is why section 6 can wait.

### Storage, network, USB, input

There is no SD card slot and no eMMC. Storage is NVMe, and the boot
firmware lives in a QSPI NOR the OS never touches.

| | What it is | Where |
|---|---|---|
| PCIe | five Cadence root complexes at Gen4, each with its own configuration window, memory windows, and interrupt lines | configuration at `0x2c00_0000`, `0x2900_0000`, `0x2600_0000`, `0x2300_0000`, `0x2000_0000` |
| NVMe | two M.2 slots, on the x4 port and on the x8 port wired as x4 | configuration at `0x2900_0000` and `0x2c00_0000` |
| Network | two 5 GbE controllers on PCIe, on the x2 and one x1 port, which the tree does not name because PCIe enumerates them, and the two on-chip Cadence MACs are off | `0x2600_0000`, `0x2300_0000` |
| WiFi and Bluetooth | an M.2 module on the other x1 port, Bluetooth over USB | `0x2000_0000` |
| USB | ten Cadence controllers, each an xHCI host at its window plus `0x8000`, six USB 3 and four USB 2 | the first at `0x0901_8000`, SPI 262 |
| Keyboard, mouse | USB. There is no 8042 on this board | |
| Interrupts from PCIe | message-signalled, through the ITS, with a legacy line per port as the fallback | |

The firmware trains every PCIe link and configures every USB PHY before
it hands over. A first driver that inherits that state needs no clock
and no power domain of its own. That is what makes step 2 possible
before the SCMI agent is spoken to.

### The rest

| | What it is | Where |
|---|---|---|
| GPIO | seven Cadence controllers of 32 lines, three on a fixed clock in the always-on domain and four behind an SCMI clock | `0x1600_4000` and after, `0x0412_0000` and after |
| Pin control | two register blocks, one per domain | `0x0417_0000`, `0x1600_7000` |
| I2C | ten Cadence controllers, three in use: the clock, the embedded controller, the power delivery pair | `0x0401_0000` and every `0x1_0000` |
| SPI, I3C, PWM | Cadence SPI, Cadence I3C, eight PWM channels sharing a window with four timers | `0x0409_0000`, `0x040f_0000`, `0x0411_0000` |
| The 40-pin header | two I2C buses, two UARTs, a SPI and a PWM, each a node the header variant of the tree enables | |
| Clock | a Ricoh RX8900 on I2C, with an interrupt line | bus 3, address `0x32` |
| Watchdog | the SoC's own | `0x1600_3000`, SPI 376 |
| Audio | no codec and no sound card on the board. Five I2S channels feed the five DisplayPort transmitters, so sound goes out the HDMI | `0x0707_0000` and after |
| Random numbers | a generator the secure element owns, switched off in the tree | `0x0505_5300` |
| A DMA engine | Arm DMA-350, for the low-speed peripherals | `0x0419_0000` |

## 6. The screen: a display processor, and a vblank a program can read

The firmware hands Limine a framebuffer, and Limine hands it to `kmain`.
So the first boot on the board has a screen with no display driver at
all. That is the path the `virt` boards take today. It is why the screen
is not on the critical path of the first boot.

The display processor comes after, as a program in ring 3 over its node.
It replaces one thing and adds one. `/dev/fb` becomes a scanout buffer
the driver allocates and the compositor attaches. `/dev/fbctl` gains the
`size` command `docs/DEVFS.md` reserved for the day a mode could change.
Every client of `/dev/fb` keeps working, because a device segment was
always a base and an extent.

What it adds is `vblank`, a stream beside `fb`. A read parks until the
next vertical blank and answers a count. The compositor reads it once
per frame and paints between two of them. That is the frame pacing a
game wants, and its absence is the tearing a compositor without it
shows. Two buffers, with a `flip` line on `fbctl` naming which is on the
glass, is the whole of double buffering. It is a second step.

**The first driver is the smallest one.** The firmware programmed the
fifth processor and its transmitter, and the HDMI port is lit before the
kernel runs. `servers/dpufs` starts by owning only what the firmware
left: the layer address the processor scans from, and the interrupt it
raises at each frame. That is `flip` and `vblank` on the mode the
firmware chose, in a few hundred lines.

A mode of the driver's own choosing is three more things. A pixel clock
through SCMI, a transmitter the driver trains, and a converter woken
through its GPIO. That is the second step, and each output gets a `ctl`
that reports what is connected and takes a mode.

## 7. The GPU: a command stream front end, and what the kernel does not do

The Sky1's GPU is an Arm Mali with a *command stream front end*, CSF. A
CSF GPU runs a small firmware on a microcontroller inside the GPU. The
firmware takes work from *queues*, which are ring buffers in the GPU's
address space. A program fills a queue with the GPU's own instruction
set. Those are sixty-four bit words that move values, wait on sync
words, run a compute, tiler or fragment job, and flush caches.

A *group* is a set of queues and a priority. A doorbell is a page of
registers per group, and a write to it tells the firmware a queue's
insert pointer moved.

That programming model is the reason this plan can keep the GPU driver
small. It is worth stating what the split is on Linux before saying what
it is here. Linux's driver for these GPUs loads the firmware and manages
the GPU's address spaces. It creates groups and queues, maps the doorbell
page into the program, handles faults, and grows the tiler's heap on
demand. Everything about drawing lives in the program: the command
stream, the descriptors, and the shaders. The kernel never sees a
triangle.

That split is right, and this plan takes it. What it refuses is the
handle namespace and the three sync primitives the split arrived wrapped
in.

The vendor tree's driver is the open one, patched for this SoC. Three
patches matter to a port. The register window is the second `reg` entry
and the first is a reset and clock unit of CIX's own. The clocks are
four SCMI clocks by name, two of them optional. And the interrupt names
are upper case. Section 5 has the numbers.

### The file set

    /dev/gpu/                  served by `servers/gpufs`, a program over
                               /dev/tree/soc/gpu@15010000/{mmio,irq,dma}
    /dev/gpu/ctl               `reset`, and the clock the firmware runs at
    /dev/gpu/firmware          a write loads the firmware blob, once
    /dev/gpu/status            what the firmware reports, on read
    /dev/gpu/new               read it, and it answers a context number
    /dev/gpu/N/ctl             `attach`, `queue <n> <va> <size> <prio>`,
                               `heap <va> <chunk> <max>`, `reset`
    /dev/gpu/N/doorbell        the group's doorbell page, attachable
    /dev/gpu/N/sync            a page of sync words, attachable, in the
                               driver's memory and mapped into the client
    /dev/gpu/N/wait            `n value`, and a read parks until sync word
                               `n` reaches `value`
    /dev/gpu/N/fault           a stream, one line per fault the firmware
                               reports for this context

**A context is a directory, and its memory is the process's.** A program
reads `new`, opens `N/ctl`, and writes `attach`. The driver writes the
binding line to the node's `dma` file, and the kernel checks that the
program is the driver's client. The program's own address space is then
the GPU's view. That is section 4. The program allocates its queues, its
descriptors, its textures and its shaders with `segalloc`, and names them
to the GPU by their address.

`queue` tells the driver where a ring is. The driver tells the firmware.
From then on the program writes instructions into the ring and rings the
doorbell through the page it attached. Zero system calls per submission,
which is the number Carmack asked for.

**Completion is a word in memory.** A CSF instruction adds to a sync
word at an address, and a program that wants to know whether a frame
finished reads that word. The words live in a page the driver owns and
the program attaches, section 3's last rule. So both can read them, and
the GPU can write them in the program's space. A game polls one at the
end of a frame, which is what a game does anyway. A program that wants
to park writes `wait` with the index and the value, and the driver
answers when the firmware signals it.

That is one primitive, a sixty-four bit word at an address, and it is
the only one. A fence between two programs is the same page attached by
both.

**The tiler heap is the one allocation the driver makes for a program.**
A tiler job writes into a heap that grows as geometry arrives, and the
firmware asks for a chunk mid-job. The driver answers from a range the
program named with `heap`, so the memory is still the program's and the
program still bounded it. A heap that runs out fails the job with a
fault line, not the machine.

**A fault is a line on a file.** The firmware reports an address the
context could not reach, and the driver writes it to `N/fault`. A
program reads it, or does not, and the context is reset on the next
`ctl` line. A program that faults the GPU faults nothing else, because
the address space is its own.

**The cache is the program's to clean.** This GPU does not snoop. A
program that wrote a command, a descriptor or a vertex cleans the lines
before it rings the bell. `sys/libgpu` does that inside its submit, so a
program never sees the instruction. The reverse direction is the
same: a result the GPU wrote is read after an invalidate. `dma` reports
`coherent no` for this node, and the library reads it once at open.

### What the program links

The kernel and the driver do not know what a triangle is, so a library
has to. `sys/libgpu` is that library, and it is three things.

- **The command stream.** An encoder for the CSF instruction set, in the
  shape `sys/libdraw` has for the six verbs: a put half a program batches
  with, over a ring in its own memory.
- **The descriptors.** The structures the hardware reads for a draw: a
  framebuffer, a shader program, a set of resources, a job. Each is a
  struct in Odin with the bits named, filled by the program and pointed
  at from the stream.
- **The shader compiler.** The hardest piece, and the one this plan
  leaves for last inside the GPU step. Mesa's open driver documents the
  instruction set in a machine-readable description. Step one is an
  assembler generated from that description, so a program can ship
  shaders as text the library assembles at load. Step two is a small
  intermediate form over it. A shader language is a later document, and
  it is not GLSL.

**The compositor is the first client, and it is a small one.** Every
window is a store in `intuition`'s memory, and a composite is a set of
blits with clipping. That is one compute shader, a descriptor per
window, and a sync word per frame. The compositor on the GPU costs the
CPU nothing per frame, and every window's pixels are where they always
were. `docs/DRAW.md`'s six verbs do not change, and a client cannot
tell.

**A game is the second client, and it is the point.** It opens a
context, allocates its memory, builds its streams and rings its bell.
It reads `vblank` to pace. It polls a word to know. It links one library
and no runtime.

When it wants to know why a frame is slow, every byte of the path is in
its own address space. `cat /dev/gpu/N/fault` says what the hardware
refused.

### What the firmware costs

The GPU does nothing without its firmware, which Arm distributes as a
binary under a licence that permits redistribution and does not permit
reading. It goes in `/lib/firmware`, and `servers/gpufs` writes it to
`/dev/gpu/firmware` at start. The driver places each section at the
address the binary's header names, in its own space, with the `segalloc`
of section 4. Then it points the GPU's first address space at itself. The
microcontroller then boots from the driver's memory.

A machine with no blob has a screen and no GPU, and the compositor keeps
painting on the CPU. That is the one binary this plan runs that nobody
here can read, and it is named as such.

## 8. The NPU: a coprocessor that runs a blob

The Sky1 carries an Arm China Zhouyi V3 neural processor, three cores
behind one SMMU stream. Its programming model is a job queue. A *task
control block* in memory names a compiled graph, its inputs, its outputs
and its scratch. The driver hands its address to the hardware's
scheduler, and a job completes with an interrupt and a status word. The
graph is a binary a closed compiler produces from a model, and nothing
in this tree will write that compiler.

There is no firmware, and no driver in the vendor tree, only a header of
nineteen calls that says what the driver outside it does.

**So the OS provides memory, a queue and a completion, and refuses to
provide a model format.** The file set is the GPU's with fewer files:

    /dev/npu/ctl               `reset`, and the cores that are on
    /dev/npu/status            the hardware's word on itself
    /dev/npu/new               a context number
    /dev/npu/N/ctl             `attach`, and `run <va>`, the task control
                               block's address
    /dev/npu/N/done            a read parks until a job ends, and answers
                               its status line
    /dev/npu/N/fault           as the GPU's

The context's memory is the process's, section 4, through the SMMU this
time rather than a unit of the device's own. A program loads a graph
binary into a segment, fills a task control block beside it, and writes
one line. The library, `sys/libnpu`, knows the block's layout and
nothing about tensors. A tensor is bytes at an address the graph says.

**What a hobbyist does with it.** Compiles a model on a Linux box with
the vendor's tool, copies the binary to `/lib/npu`, and runs it from a
program of forty lines.

**What a hacker does with it.** Reads the task control block layout the
driver's document records from the vendor's header. Pokes the 64 KiB
register block through `mmio` from a shell. The day someone writes an
open compiler, it targets a file that already exists.

**What the OS does not do.** Pretend the model format is its business,
or that the compiler is.

## 9. The rest of the platform

Each of these is a ring 3 server over its node, in the shape section 3
gives. Each is its own document when it is built. The paragraphs here
say what is unusual about each on this board and where it stands in the
order.

**Storage.** NVMe is the only disk, and the system lives on it. The
driver is `servers/nvmefs`, and it serves `#S`'s shape, `data`, `ctl`
and a partition per file, under `/dev/nvme0`. GPT replaces the MBR read,
which `docs/DISK.md` named as the day a disk carries one. The
controller's queues are in the driver's memory and the SMMU walks its
tables. So a disk read is the controller writing into the process that
asked.

The root port's configuration window is a plain ECAM at an address the
tree names, so `kernel/drivers/pci` needs one more base and no new
shape.

**USB.** The keyboard and the mouse on this board are USB, and there is
no 8042. Each of the ten controllers is an xHCI host at its window plus
`0x8000`, and the firmware leaves the PHYs up. xHCI is the largest
driver in the plan. The class drivers over it are HID for input and mass
storage for a stick.

`servers/usbfs` serves the bus as Plan 9's `usbd` does: a directory per
device, `ctl`, `ep` files for the endpoints. `kbdfs` and the mouse driver
then read HID reports from an endpoint file instead of scancodes from a
port. Everything above `/dev/kbd` and `/dev/mouse` stays as
`docs/WORKBENCH.md` built it.

**Network.** The two ports are PCIe network cards, and the WiFi module
is a third on the M.2 slot. The tree does not name the parts, because
PCIe enumerates them, and the PCI id on the first boot will. A driver
per card serves an `ether` directory of Plan 9's shape. The stack over
it is `servers/netfs`, an empty directory since the tree's first commit,
and it becomes IP, UDP and TCP as `/net`. TCP comes early, section 11
says why.

**Audio.** There is no codec on the board. Sound is five I2S channels
into the five DisplayPort transmitters, so the relay clicks
`docs/HANDOFF.md` promises go out the HDMI. `/dev/audio` and
`/dev/volume` are Plan 9's files, over the one channel that feeds the
lit output.

**Video.** The codec block has four cores and a queue of its own, and no
driver anywhere in the vendor tree. It gets the GPU's file shape the day
something wants it, and the register layout has to come from somewhere
first.

**Low-speed.** GPIO, I2C, SPI and PWM on the 40-pin header, each a
directory of files, which is the part a hobbyist wires a sensor to. The
three always-on GPIO blocks run on a fixed clock and need no firmware
call, so they are the first. The embedded controller owns the fan and
runs it without the OS, which is why a driver that restarts cannot cook
the board. The clock is a chip on an I2C bus, and `/dev/rtc` is its
file.

## 10. Firmware, cores and power

The board's firmware is UEFI, and Limine is a UEFI application, so the
boot chain is the one the `virt` boards use. Limine hands over the memory
map, the framebuffer, the cores and the device tree. The one difference
is that the tree is real and the bases are in it.

**The tree, if the firmware offers tables instead.** The vendor's kernel
boots this board under ACPI by default and under a device tree when
asked. Limine passes on whichever the firmware exposes. So the build
compiles the vendor's tree for the board and embeds it in the kernel, as
the font is embedded. `kmain` uses it when the bootloader hands none.
The tree is then a fact this repository owns rather than one the
firmware's setup menu decides.

**Cores.** Twelve, in two tiers by part number: `cpu_class` reads
`MIDR_EL1` and answers `.Efficiency` for a Cortex-A520 and `.Performance`
for a Cortex-A720. The capacity of each comes from the tree. The eight
big cores sit in four performance domains of two. If the SCMI agent
reports one domain with a higher ceiling than the others, its pair is
`.Prime`.

The placement rule in `docs/SCHED.md` then does its job. A game's main
thread lands on the fastest core because it is the busiest thread on
the machine.

**PSCI** starts a core, stops one, and turns the machine off. Limine
starts the cores today, and PSCI is what a halt needs, which
`docs/HANDOFF.md` lists as absent.

**SCMI** is how the OS asks the power management core for a clock rate,
a performance level or a temperature, over the mailbox. The kernel
speaks it, and publishes it as `/dev/scmi`. That is a directory per
domain, with a `ctl` per clock and per performance domain. A `sensor`
file per temperature answers a read in millidegrees. A
ring 3 driver writes there to clock its device.

A second agent, over an SMC, is the device power domains, and the kernel
publishes those in the same directory as `power` files. A driver that
cannot turn its device on serves a directory that says so.

## 11. The development loop, which is the point

A board on a desk, a serial line to the host, and a tree edited on the
host. What makes that a joy or a chore is one thing: how a change reaches
the board.

**The first loop is a stick.** There is no card slot, so the ESP goes on
a USB stick the firmware boots from. It moves to the NVMe once step 2
can write it. Build on the host, copy, boot. That is the loop
`docs/SHELL.md` had before the disk, and it is enough for the first two
steps.

**The second loop is the network, and it is why TCP comes early.** Plan 9
had no install step because the host's tree was a mount. `servers/netfs`
with TCP, a 9P client over it in the kernel's `mnt`, and a 9P server on
the host, and `/n/host` is the host's checkout. A tool edited on the host
runs on the board with no copy. A kernel still boots from the stick, and
everything else does not. That is the loop the rest of the plan is built
in, and it is the one Plan 9 users never gave up.

**What a game developer sees.** A directory. `ls /dev/gpu` says what the
machine can do. `cat /dev/gpu/status` says what it is doing. A program
is one binary that links one library, allocates its memory, and owns a
queue. There is no SDK, no runtime, and no driver version.

A frame is a ring the program wrote and a word the program reads. The
whole path from a key press to a pixel is in this tree and the program,
and both fit in a person's head. `docs/STYLE.md` is why the tree reads
the way it does, and this is who it reads that way for.

## 12. The order

Each step ends with a boot line, and each is usable before the next
starts. The first step needs no board, and that is deliberate. Every
piece of the driver model is checkable on QEMU's `virt` board. It has a
device tree, a GICv3, an SMMUv3 and virtio devices with bus mastery.
The board then adds hardware to a model that already runs, rather than a
model to hardware that does not.

### Step 0: the model, on QEMU

`kernel/tree`, `kernel/arch/arm64`, `kernel/smmu`, `servers/blkfs`,
about 3,000 lines.

- **`#t` at `/dev/tree`**, the flattened tree as files. The GIC, the UART
  and the ECAM bases become reads of `reg`, and the three assumptions
  in `docs/PORTS.md` section 5 retire.
- **GICv3**, beside the v2 the `virt` board runs today, selected by the
  tree's `compatible`. Redistributors from a list of bases, the system
  register interface, and the ITS for message-signalled interrupts.
- **`irq` and `mmio`** per node, and a ring 3 driver for virtio-blk
  through them, `servers/blkfs`, serving what `#S` serves. `kernel/sd`
  stays until the board, so both paths run and the self-test compares
  them.
- **`dma` and the SMMU**, on `virt` with `iommu=smmuv3`. The virtio
  device attaches to `blkfs`'s address space, and the self-test checks
  that a transfer to an address outside it faults rather than lands.
- **The shootdown reaches the device.** A control that skips it reads a
  freed page through the device, and the check is that it cannot.
- **`cpu_class` from MIDR**, with the `virt` board's cores fabricated into
  two tiers by the QEMU command line.
- **`segalloc` at an address**, and the check that a second call at the
  same address is refused.

Proves, in five checks. `cat /dev/tree/intc@8000000/compatible` answers
`arm,gic-v3`. `blkfs` reads the marker `docs/DISK.md` puts on the scratch
disk, through `mmio` and `irq` and no kernel driver. A transfer aimed
outside the driver's space is refused with a fault line and nothing
else changes. A page the driver gave back is not readable by the device.
A thread pinned to `.Efficiency` lands on the core the command line made
one.

### Step 1: the board boots

`build.odin`, `kernel/arch/arm64`, `boot/`, about 800 lines.

- **A `--board=orangepi6` target** that stages an ESP for a stick, with
  Limine's aarch64 binary, and compiles the vendor's tree for the board
  into the kernel.
- **The console** is the PL011 at the base the tree names, and the early
  window moves to it.
- **The firmware's framebuffer**, through Limine, as on `virt`.
- **The cores**, all twelve, through the tree's `cpus` node and PSCI, and
  the two tiers from MIDR.
- **SCMI**, the mailbox agent and the SMC agent, as `/dev/scmi`, with a
  read of one temperature as the proof it works.

Proves, in three checks, on the serial line. `boot complete` with the
suite green on twelve cores. `ps` on the serial shell shows a thread per
class, and `cat /dev/scmi/sensor/0` answers a temperature. The chassis
is on the monitor.

### Step 2: a disk, a keyboard, and the desktop on the board

`servers/nvmefs`, `servers/usbfs`, `servers/kbdfs`, `kernel/drivers/mouse`,
about 6,000 lines.

- **NVMe**, `servers/nvmefs`, with GPT, over the root port the firmware
  trained. Interrupts through the ITS, with the port's legacy line as
  the fallback if the ITS is late.
- **The PCIe SMMU**, switched on. If the part refuses, the driver runs
  trusted and the document says so.
- **xHCI**, `servers/usbfs`, and HID over it. The keyboard and the mouse
  become readers of endpoint files, and `/dev/kbd` and `/dev/mouse` do
  not change.

Proves, in three checks. `ls /n/esp` on the board lists the tools from
the NVMe. A key typed on a USB keyboard reaches a window. `Workbench`
runs, with the overview and nine workspaces.

### Step 3: the network, and the host's tree

`servers/etherfs`, `servers/netfs`, `kernel/mnt`, `tools/9pserve`, about
5,000 lines.

- **The PCIe network card**, an `ether` directory, for whichever part
  the PCI id names.
- **IP, UDP, TCP** as `/net`, Plan 9's file set.
- **9P over TCP**, the kernel's `mnt` over a `/net/tcp` connection, and a
  host-side server in Odin.

Proves, in two checks. `9fs host` on the board lists the checkout at
`/n/host`. A tool edited on the host runs on the board without a copy.

`docs/FLEET.md` is the plan for what runs over this wire. Its step 0 is
this step's stack, with the listening half beside the dialling one. The
two documents build one `/net`, and that one owns its shape.

### Step 4: the display processor

`servers/dpufs`, about 2,500 lines.

- **The fifth display processor** owns scanout of the mode the firmware
  set. `/dev/fb` is its buffer, `fbctl` takes `flip`, and `vblank` is a
  stream.
- **A mode of the driver's own**, with `size`, the pixel clock through
  SCMI, the transmitter trained by the driver, and the converter's GPIO.
- **The other outputs**, each a `ctl` that reports and sets a mode, with
  the USB-C pair last because the power delivery controllers own them.

Proves, in two checks. The compositor paints between two `vblank` reads
and the self-test reads sixty counts in a second. A `size` line changes
the mode and `fbctl` reads back the new geometry.

### Step 5: the GPU, in three parts

`servers/gpufs`, `sys/libgpu`, about 8,000 lines, the longest step.

- **Part one, the firmware and a queue.** Load, boot, a context, a queue,
  a doorbell page, a sync page. A stream of `MOVE` and `SYNC_ADD` that
  increments a word in the program's memory, with no shader anywhere.
- **Part two, compute.** A shader assembled from text by the generated
  assembler, and a compute job that fills a buffer. The compositor on
  it.
- **Part three, the graphics pipeline.** Vertex, tiler and fragment jobs,
  a framebuffer descriptor, and a triangle on the glass.

Proves, in three checks. A sync word in a program's memory reaches the
value the stream added, with the program's own address space as the
GPU's. A compute job writes the pattern the shader computes, read back
by the CPU after an invalidate. A triangle's pixels are on the glass
where the descriptor put them.

### Step 6: the NPU

`servers/npufs`, `sys/libnpu`, about 2,000 lines.

- A context behind the SMMU, a task control block, a graph binary from
  the vendor's compiler, and `done`.

Proves, in one check. A graph that adds two tensors answers their sum,
from the program's own memory.

### Step 7: the rest

Audio out the DisplayPort, the video codec, WiFi, the 40-pin header,
each its own document in whatever order a reason arrives.

## 13. Decisions taken here, and what would reverse them

- **Drivers in ring 3, because a walker makes them safe.** A driver that
  faults ends a process, and the device it programmed can reach nothing
  else. The reversal is a device with no walker. On this board that is
  the PCIe root ports, if the SMMU in front of them cannot be switched
  on. Such a driver runs trusted, and its document says so. The console,
  the timer, the interrupt controller and the walkers themselves stay in
  the kernel because a program needs them before there is a program.
- **The device tree is a directory, and the three synthesised files are
  the whole kernel interface to a device.** `mmio`, `irq` and `dma`.
  A fourth file is a design question, and this document's answer is
  that there is not one.
- **The kernel programs every walker, and a driver never holds a
  physical address.** That is why one page of the GPU's window is
  withheld, and why `dma` takes a pid rather than a root. The reversal
  is a device whose walker has no page of its own to withhold.
- **A device walks the process's own tables.** No second address space,
  no handle, no translation. The reversal is a device whose walker does
  not speak the CPU's format, and on this SoC every one that masters the
  bus does. The cost is a shootdown per walker and a cache clean per
  entry written, and both are paid in one place.
- **Completion is a word in memory, and a read that parks on it.** Not
  three primitives, and not one the kernel owns. The reversal is a device
  that cannot write a word, and none here is.
- **The kernel never sees a triangle, a tensor, or a model.** The GPU
  driver and the NPU driver hand a program memory, a queue and a
  completion. What is in the memory is a library's business. The
  reversal is a device whose vendor put the compiler in the firmware.
  Then the firmware is the blob, and the shape does not change.
- **A ring 3 server may hand on a page it holds**, through an extended
  attribute the kernel checks against the server's own segments. The
  wire does not change. The reversal is a second syscall, and there is
  no reason for one.
- **The firmware blobs are files a program writes to a device.** Named,
  counted, and absent when absent. The machine works without them, with
  less.
- **The network comes before the GPU.** The host mount is the loop
  everything after it is built in, and a GPU built over a stick copy per
  iteration would take twice as long.
- **The screen comes from the firmware first.** A display driver is not
  on the path to a first boot, so the first boot happens sooner and the
  display driver has a working system to be tested in.
- **The vendor's tree is compiled in, not trusted from the firmware.** A
  setup menu is not a build input.

## 14. Sizes and order of dependence

    step 0  the model      tree 800, gicv3 700, smmu 700, blkfs 900      nothing before it
    step 1  the board      build 200, uart 100, psci 200, scmi 400       step 0
    step 2  disk, input    nvmefs 1,500, usbfs 3,500, hid 600            step 1
    step 3  network        etherfs 1,200, netfs 3,000, 9pserve 800       step 2
    step 4  display        dpufs 2,500                                   step 1
    step 5  gpu            gpufs 3,000, libgpu 5,000                     step 3, step 4
    step 6  npu            npufs 1,200, libnpu 800                       step 3
    step 7  the rest       each its own                                  step 3

Step 4 needs only the board and can run beside steps 2 and 3. Step 0's
parts are independent and can proceed at once.

## See also

- `docs/PORTS.md` -- the arm64 port this builds on, and the three
  assumptions step 0 retires.
- `docs/DEVFS.md` -- the device file shape, the `ctl` convention, and the
  divert every raw file keeps.
- `docs/DRAW.md` -- `segattach` through a descriptor, which `mmio`,
  `doorbell` and `sync` are more of.
- `docs/USER.md` -- `segalloc`, the fault rule, and the reaper a driver
  that faults relies on.
- `docs/SMP.md` -- the shootdown a device joins.
- `docs/WORKBENCH.md` -- the desktop this puts on a real screen.
