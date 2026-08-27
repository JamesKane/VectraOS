# The keyboard: the first device that interrupts

`kernel/drivers/kbd/`, and the I/O APIC in `kernel/arch/amd64/ioapic.odin` that
gets its interrupt to a core.

Every interrupt before this one was the LAPIC timer, which the kernel armed and
therefore expected. A keystroke arrives because somebody outside the machine
decided it should, at a moment nothing chose. Almost everything below follows
from that difference.

## The prediction that was half right

Since Milestone 10, `kernel/devfs/cons.odin` calls its polling thread "where an
interrupt handler will stand". It goes on: the day a real one exists,
"`cons_input` goes away and the handler pushes into the same ring".

The first half held exactly. The second did not, and the reason is worth more
than the driver.

**`cons_feed` echoes.** Echo is `cons_write`, which takes `Cons.out`, and that
is a *sleeping* lock. A write draws glyphs, and a write at the bottom of the
screen scrolls first. A spinlock across four megabytes of memory copy would cost
the timer ticks it can never get back. `docs/DEVFS.md` argues that at
length and the argument still holds.

**An interrupt handler that took a sleeping lock would park the interrupt.** Not
the thread it interrupted — the interrupt itself, with its frame on whatever
stack it landed on and no scheduler entry to bring it back.

`sync.can_sleep` would not catch it, either. It counts spinlocks, and a bare
interrupt handler holds none. The call would look legal and run correctly under
any test that never contended. It would stop the machine the first time two
things wanted the console at once.

So the work splits where the constraint falls:

| | may hold | may not |
|---|---|---|
| **top half** — the handler | a spinlock | anything that parks |
| **bottom half** — a thread | a sleeping lock, the console | — |

The thread devfs predicted would go away therefore does not go away. What
changed is what wakes it: a poll became a rendezvous, so nothing runs between
keystrokes. That is the difference that mattered, and it is not the one that was
predicted.

## Why the I/O APIC, given the 8259s are already there

`kernel/arch/amd64/pic.odin` remaps both controllers and masks every line. Its
opening sentence says Vectra will drive interrupts through the local APIC and
this instead. That was a statement of intent for five milestones.
The keyboard is the first device that needed it to be true.

Two reasons not to take the legacy path, and the second settles it.

The 8259 needs *virtual wire mode*. The LAPIC's LINT0 pin programmed as ExtINT,
the controller delivering through it, and an INTA cycle to fetch the vector.
`lapic_attach` masks LINT0 deliberately, because firmware sometimes leaves LINT1
set to deliver an NMI. Undoing that to keep a controller the tree has already
disowned is work aimed backwards.

And **the 8259's vector base collides with the timer's.** `PIC1_VECTOR_BASE` is
32 and `VECTOR_TIMER` is `0x20`, which is the same number. Harmless while every
8259 line is masked. Not harmless the moment one is not.

Device interrupts land at `VECTOR_IRQ_BASE + irq`, which is `0x30` upward —
above the range the 8259s were remapped into, so the collision cannot come back.

## What the I/O APIC assumes rather than discovers

Two things, both of which come from ACPI's MADT on a machine that has one, and
Vectra parses no ACPI tables.

    IOAPIC_PHYS      0xFEC00000, where every PC-compatible puts the first one
    ISA IRQ -> GSI   identity

Neither is safe in general and both are safe here. The one that genuinely bites
is IRQ 0: firmware very often overrides it to GSI 2, and only a MADT says so.
Vectra does not route IRQ 0 — the LAPIC timer is its clock — so the case that
would break is the case that does not arise.

A MADT parse retires both, and it pays for itself twice: the same table lists
the cores SMP will need to start. That is why it is worth waiting for a reason
rather than doing it here.

**Routing and unmasking are two calls**, and that ordering is deliberate. A
driver claims its line, registers its handler, and only then lets the first
interrupt through. The other order has a window where a device already asserting
lands on a vector whose handler is not there yet.

`ioapic_attach` masks every line on the way in, for the same reason. Firmware
leaves entries behind. An inherited route aimed at a vector this kernel never
claimed arrives as an unexpected interrupt, with nothing to service it.

## The top half is three lines, and the shortness is the specification

Read the port, acknowledge the APIC, put the byte in a ring and say so.

**The port read is not optional.** The 8042 asserts its line while its output
buffer is full and does not re-assert for the next byte until it is read. A
handler that acknowledged without reading gets exactly one interrupt, ever.

**The EOI comes before the wake.** A wake can make a thread runnable and the
scheduler may switch to it on the way out of the handler. An EOI after the
switch would come after an arbitrary delay. `docs/SCHED.md` records what a late
one costs: the LAPIC delivers nothing further at or below that priority, with
no error anywhere to say why.

**It returns the state it interrupted.** A keystroke is a device to service
rather than a reason to schedule. The timer is the one handler here that
returns a different `Resume`. It earns that by being the thing that measures a
slice.

## What is translated here, and what is not

Scancode set 1, which is what an 8042 with translation enabled produces and what
every PC delivers by default. The table maps a *position* on the keyboard to the
character a US layout puts there.

Two tables — plain and shifted — rather than one and a rule, because there is no
rule. `2` shifts to `@` and `'` shifts to `"`, and the only thing that predicts
either is a picture of the keyboard.

**Caps lock applies to letters and to nothing else**, and treating it as another
shift is the classic way to get this wrong. Caps lock plus `2` is `2` on every
keyboard anyone ever used, and shift plus `2` is `@`. So the case is flipped
*after* the table answers, and only over the range where case means anything. A
control fails exactly here.

**Control makes a letter into the control character at the same position.** `^A`
is 1 through `^Z` is 26, which is the whole convention and the reason `^D` and
`^U` mean anything to the line discipline. By the time either reaches
`cons_feed`, a control character typed at a keyboard is indistinguishable from
the same one off the serial line. That is what makes the line discipline one
implementation rather than two.

**The `0xE0` prefix is consumed and its key dropped.** An extended code shares
its second byte with an ordinary key — keypad Enter is `0xE0 0x1C`, and so is
the main Enter without the prefix. Ignoring the prefix would make an arrow key
type a letter, which is worse than an arrow key doing nothing.

Absent: key repeat rates, the LEDs, anything above 7-bit, and the arrow keys
themselves. The first two want a `ctl` file, on the convention `/dev/consctl`
set. The arrows want somewhere to go, which is the cursor-in-a-line that
`docs/DEVFS.md` lists as the next thing a person misses.

**The layout is a table in a driver, which is the wrong place for it.** A layout
belongs in a file somebody can replace. That is a `/dev` entry and a format, and
it is worth doing when there is a second layout to want.

## The self-test, and an interrupt nobody typed

Two halves, matching the driver's.

**The translation is a pure question.** What a scancode produces depends on the
code and the modifier state and nothing else. So it is checked against a
`Keyboard` the test owns, with no hardware, no interrupt and no thread. That is
what makes the awkward cases cheap enough to check exhaustively.

**The interrupt path cannot be checked that way, and is checked anyway.** 8042
command `0xD2` asks the controller to place a byte in the first port's output
buffer, which raises IRQ 1 exactly as a keystroke does. Everything after the key
itself is then real: the routed line, the vector, the handler, the ring, the
wake, the thread, the sink.

A check that had to be typed at is a check nobody runs. This one runs every
boot.

The live keyboard's sink is swapped for a recording one and put back. Otherwise
the injected byte lands in the boot log. The swap is safe
because the bottom half is parked — nothing reads `sink` until the injection
wakes it.

### The controls

Seven mutations, one at a time, each observed on a real boot:

| Mutation | First failure |
|---|---|
| caps lock is treated as another shift | `and a letter under it is upper case` (2 checks) |
| the extended prefix is ignored | `the extended prefix is swallowed and remembered` (2 checks) |
| a modifier release is taken for a press | `shift up releases it` (5 checks) |
| the line is routed and left masked | `with the line unmasked` (2 checks) |
| the top half does not read the data port | `and it arrives too, so the port really was read` |
| the top half acknowledges nothing | `and it arrives too, so the port really was read` |
| the top half delivers straight to the sink | `an interrupt really did arrive` (2 checks) |

**Two of those failed nothing the first time round**, and both taught something
the driver alone would not have.

### One keystroke cannot see whether the port was read

The injection check originally sent one scancode. The 8042 asserts its line
while its output buffer is full, and does not re-assert for the next byte until
something reads it. So a top half that acknowledged the APIC without reading the
port delivers its first key correctly and never interrupts again.

One key passes. **Two do not**, and the check sends two now. The same second key
is what catches the missing EOI, which has the same shape from the outside: one
interrupt arrives, and nothing after it.

### A bound measured in ticks is not a bound when the clock stops

The no-EOI control did not fail. It **hung**, and the boot printed nothing from
that line on.

The reason is the LAPIC's, and `docs/SCHED.md` already records it. With no EOI
the APIC delivers nothing further at or below that priority, and the timer sits
at that priority. The wait in this file was `sync.delay`, which is measured in
ticks. The bug being tested is the bug that stops ticks.

`docs/TESTING.md` records that exact failure twice already, in two other
subsystems, and calls a self-test that hangs worse than one that fails. **This is
the third, and the first where the check was measuring in the units the bug
destroys.**

The wait is bounded in *yields* now. A yield is a software interrupt. It
executes rather than arriving, so it works after the APIC stops delivering, and
it still lets the bottom half run before that.

### The one hazard this file argues and does not check

The last control puts `deliver` back in the interrupt handler, and it does fail
-- but for the wrong reason. The counter it trips lives in `push`, which the
mutation removed. **Nothing here detects the hazard itself.**

In the running system that handler would call `cons_feed`, which echoes, which
takes a sleeping lock, which parks. That is an interrupt with its frame on
whatever stack it landed on, and no scheduler entry to bring it back. `sync.can_sleep`
counts spinlocks and a bare handler holds none, so nothing says a word.

The rule that a top half may not park is therefore argued in prose at the top of
`kbd.odin` and enforced by nothing. A depth counter that the trap dispatcher
brackets a handler with would make it a named stop, the way the spinlock rule
already is. It touches the scheduler's hot path, so `docs/HANDOFF.md` carries it
as a gap rather than this milestone carrying it as a patch.

## What this leaves for next time

- **A MADT parse**, which retires both of the I/O APIC's assumptions and hands
  SMP the core list it will need.
- **The arrow keys**, once there is a cursor in the line under construction for
  them to move. `docs/DEVFS.md` has the other half.
- **A layout in a file** rather than a table in a driver.
- **The LEDs and the repeat rate**, behind a `ctl` file on the convention
  `/dev/consctl` set.
- **Serial input on an interrupt.** The 16550 can raise one, and `cons_input`
  is still a thread that polls it once a tick. The keyboard shows the shape.

## See also

- `docs/DEVFS.md` — the console this delivers into, its line discipline, and
  why `Cons.out` parks.
- `docs/BOOT.md` — the descriptor tables, the vectors, and the panic screen.
- `docs/SCHED.md` — the timer interrupt, and what a late EOI costs.
- `docs/TESTING.md` — the self-test discipline, and what an uncaught control
  usually means.
