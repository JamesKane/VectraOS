# Booting, the CPU, and the trap path

`boot/`, `kernel/arch/`, `kernel/main.odin`, `kernel/panic.odin`,
`kernel/log.odin`, `kernel/splash.odin`, `kernel/drivers/`

This layer runs from the moment the firmware gives control to Limine. It ends
when `kmain` has a screen, a serial port, a descriptor table and somewhere to
report a fault. This is the layer with the least room for a mistake that
something discovers later. A fault before the trap path exists is a triple fault
with nothing to show for it. A mapping decided here is one that every later
table walk inherits.

The order in `kmain` is not arbitrary, and it is the shortest summary of this
file. It runs serial, base revision, **traps**, framebuffer, memory, then
everything that can afford to fail loudly.

## Decisions, and what would reverse them

- **Limine 12.6.1, base revision 6.** Vendored UEFI binaries only (x64, aa64,
  riscv64, ia32) in `boot/limine/`. There is no BIOS stage and no `limine`
  deploy tool, because Vectra boots UEFI everywhere. `kmain` reports the
  granted revision.
- **Paging pinned to 4-level** (`min_mode = max_mode = 4LVL` in
  `paging_mode_request`). Limine would otherwise hand us 5-level on capable
  hardware, which moves the canonical hole and changes every table walk.
  Support for 5-level should arrive as a deliberate edit to that request.
- **`arch` is the only CPU-facing import** the portable kernel may use.
  A `#+build` tag selects the per-architecture bindings
  (`arch_amd64.odin`, `arch_arm64.odin`, `arch_riscv64.odin`). The latter two
  are stubs, and they exist so that a port fills in blanks rather than edits
  call sites.
- **Inline asm, no nasm.** Odin's `asm(...)` with LLVM AT&T templates and
  register constraints covers port I/O, control registers and MSRs. Verified by
  disassembly.
- **The framebuffer `Surface` is the shared drawing type.** The boot splash, the
  future panic screen, and `intuition`'s off-screen window buffers are all
  Surfaces. A bevel drawn at boot and one on a titlebar are therefore the same
  code. `kernel/drivers/fb/palette.odin` is the single source of colour truth.
- **Console font is host-rasterised.** `tools/genfont.py` bakes PTMono at 13px
  (exactly 8×16) into `kernel/drivers/console/font_data.odin`. It is
  serviceable. A hand-drawn bitmap face is the right long-term answer for the
  amber terminal.
- **The logger replays.** A static buffer of 16 × 128 bytes holds the lines
  that arrive before the framebuffer exists. `attach_screen()` draws them when
  the console attaches, so screen and serial agree line-for-line.

Traps and the panic screen:

- **Traps come up before the framebuffer**, immediately after the serial port
  and the base revision check. Everything after that point is code that faults
  while somebody writes it. A fault before it is a triple fault with nothing to
  show for it. The fault stacks therefore have to be static `.bss` arrays
  rather than PMM pages. That is the right trade, because memory bring-up above
  all is what this has to be able to debug.
- **SYSCALL and SYSRET fix the selector layout**, not taste. `SYSCALL`
  takes CS from `STAR[47:32]` and SS from that plus 8. `SYSRET` to 64-bit code
  takes CS from `STAR[63:48]` plus 16 and SS from plus 8. Hence kernel code then
  kernel data, and user code32 then user data then user code64. The code32 slot
  is present purely as a placeholder. A later renumber of these does not break
  the build. It breaks the first system call.
- **Three vectors get interrupt stacks of their own**: the double fault (IST1),
  NMI (IST2) and the machine check (IST3). The double fault is the one that
  matters. A fault that happens *because* the stack is bad has nowhere to push
  its frame, and that is a triple fault. The self-test provokes one and checks
  the result.
- **All 256 vectors are installed, not just the 32 exceptions.** A stray
  interrupt on a vector with no descriptor is a `#GP`, and a `#GP` with no
  handler is a double fault. The cheapest way to make a stray interrupt say
  `vector 39 arrived and nobody was expecting it` is to give every vector a
  stub.
- **The assembler generates the stubs.** Nothing writes them out, and nothing
  generates a file of them. `.rept` emits 256 of them. `.balign 16` makes each one exactly
  sixteen bytes, whether or not it pushed a dummy error code, so `idt_init`
  finds the nth by multiplication. That alignment is load-bearing. It is what
  turns a table of 256 function pointers into one label and a shift.
- **The legacy PICs are remapped *and* masked** before anything could call
  `sti`. A mask alone is not enough. A spurious IRQ 7 can still arrive. Without
  the remap it arrives as a **page fault**, with a garbage error code and a
  stale CR2. The panic screen would then report that with total confidence.
- **A trap handler returns a bool: resume, or stop.** The only thing that ever
  resumes today is the breakpoint the boot self-test arms for itself. That
  narrowness is deliberate, and a stray `#BP` from anywhere else still panics.
- **The panic screen's body text is amber, not red.** The red band, the
  `[ FAIL ]` tags and the FAULT lamp carry the alarm. The report itself is
  mostly hex that a reader has to take slowly, and a wall of red is the worst
  way to present it.
- **The panic path reports what was *mapped* at CR2, not just the address.**
  `nothing is mapped there` and `mapped read-only and you wrote to it` are
  different bugs that produce the same CR2. `mem.permissions` already knew how
  to tell them apart.

## Known warts

- **The trap stub saves general-purpose registers only.** No `FXSAVE`, so a
  handler that *returns* into code with live SSE state would corrupt it. Panics
  never return, and the only path that resumes today is a breakpoint the kernel
  raised on itself. This is therefore fine now. It is the first thing that has
  to grow the day anything resumes arbitrary code. A debugger would, and so
  would a page fault that repairs the mapping and retries.
- **No `swapgs` in the entry path.** Correct today, because nothing runs at
  CPL 3. It becomes wrong the moment userland does, and the fix has to land in
  the same tail that the point above rewrites.
- **The panic screen has no backtrace.** It reports the faulting instruction and
  the register state, and it cannot walk the stack. That needs either deliberate
  frame pointers or retained unwind tables. It is the largest single thing
  missing from an otherwise complete fault report.
- **OVMF is borrowed from `../odin-os/ovmf/ovmf_x64.fd`.** `build.odin`
  hard-codes that path and dies if it is missing. Vectra should vendor its own
  firmware. It will also need `AAVMF` and `RISCV_VIRT` equivalents before the
  other arches can boot.
- **QEMU's vvfat is read-write, so OVMF writes `NvVars` into `build/esp/`.** It
  is harmless. It does mean the staged ESP is not byte-reproducible.
- **`arm64` and `riscv64` are stubs, and are falling further behind.**
  `build.odin` has their rows filled in and the vendored bootloaders are
  present. But there are no `link_arm64.ld` or `link_riscv64.ld` scripts. And
  `arch_amd64.odin` now carries both the paging interface *and* the trap
  interface that the other two do not declare.
- **Memory-map entry count varies run to run** (27, 31, 33) with OVMF and vvfat.
  It is not a bug. Do not chase it.

## See also

- `docs/MEMORY.md` — what the PMM and VMM do with what the boot survey found.
- `docs/HANDOFF.md` — build and run, and the Odin toolchain constraints.
