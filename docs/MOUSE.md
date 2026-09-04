# The mouse, and the first pointing device

`kernel/drivers/mouse/`, `kernel/devfs/mouse.odin`, and the check in
`kernel/main.odin` that reads the file.

`docs/WORKBENCH.md` step 1, the first part. Every screen document before
it stopped at the sentence that there was no pointing device in this
system. There is one now, and it is a file: `/dev/mouse`, one line per
movement, in the format `rio` reads. The driver is the keyboard's shape
in `kernel/drivers/kbd`, and `docs/KBD.md` argues that shape at length.
This document records what a mouse adds to it.

## 1. The driver is the keyboard's, with a packet in place of a scancode

The 8042 has two ports, and the mouse is on the second. A byte from it
arrives on IRQ 12 rather than IRQ 1, and the controller's status says
which port it came from. The top half reads the port, acknowledges the
interrupt controller, and puts the byte in a ring. That is three things,
and the shortness is the specification. The bottom half is an ordinary
thread that takes bytes out and makes packets of them.

A packet is three bytes. The first carries the buttons, the signs of the
two movements, two overflow bits, and a bit that is always one. The
second and third are the movements, low eight bits each, with the sign
above them in the first byte.

The bit that is always one is what finds the frame again. A byte that arrives as the first of a packet without
it is dropped and counted. The next byte with it is the first of the
next packet. That is the whole of the error recovery a mouse has, and it
is enough, because a lost byte costs one packet.

The bottom half keeps the pointer's position and adds each movement to
it. It clamps the position to the screen it was told the size of. It
turns Y over, because a mouse counts up and a screen counts down. What
leaves the
driver is a position, the buttons as `rio` numbers them, and the tick.
The buttons are 1 for the left, 2 for the middle and 4 for the right,
which is not the packet's order.

## 2. Bringing the second port up

The 8042 keeps its second port off until asked, and a mouse reports
nothing until told to. `init` enables the port, sends the mouse its
defaults and then the command to report, and reads the acknowledgement
of each by polling the controller. The interrupt is enabled last, in the
controller's configuration byte, after both acknowledgements are in
hand, so neither can arrive at a handler. Every wait on the controller is
bounded. A controller that never answers is a machine with no mouse, and
the boot says so and goes on.

The ports have no 8042, and `arch.inb` there answers all ones for every
port, which is what an absent device answers on a PC's bus. `init` reads
the status port first and refuses on that, the way the keyboard's does.
So the two `virt` boards boot without a warning about a controller they
never had, and `/dev/mouse` answers ENXIO at the open on them.

## 3. The file

`/dev/mouse` is a line per movement:

    m         312         200           1       48213 

An `m`, then four fields eleven characters wide with a space after each:
the position, the buttons, and the tick. That is Plan 9's format, width
for width. A line is always 49 bytes, and a reader that knows the format
need not parse it. A read parks until there is a movement newer
than the last line it answered, and answers one. The file keeps the
latest movement and a count of them, and a read is behind when its own
count is.

**One reader.** The file is exclusive: a second open answers EBUSY. A
pointer has one owner, and that is the draw server, which serves each
window its own `mouse` in the window's coordinates. A program that
opened `/dev/mouse` beside it would take every other movement, and
neither would work.

## 4. Checked by

The driver's own checks are `kernel/drivers/mouse/verify.odin`, in the
keyboard's two halves. The packet decoder is a pure question, asked on a
`Mouse` of the test's own. A movement in each direction. A negative
movement made of the sign bit and the low byte. Each button as `rio`
numbers it. The pointer stopping at both edges.

A byte without the always-one bit is dropped, and the next packet read
whole. The ring is the keyboard's and is checked the same way.

The interrupt path is checked for real. 8042 command 0xD3 puts a byte in
the second port's output buffer, which raises IRQ 12 exactly as a
movement does. A packet injected that way takes the routed line, the
vector, the handler, the ring, the wake and the thread. The route is
read back first, so a line that did not take fails a check with a name
rather than a patience.

Then the file. `verify_mouse_file` in `kernel/main.odin` opens
`/dev/mouse` and sees a second open refused. It parks a read on a thread
and sees it stay parked. It injects a packet with the right button held
and reads the one line back. The line carries the position the packet
moved to and a 4 in the buttons field. That is the contract a draw server reads by,
checked from the file's side.

What is not checked: a mouse that reports on its own. Under `--gfx` the
QEMU window's pointer feeds the same driver. `cat /dev/mouse` from the
serial line then prints a line per movement, which is a check made by
hand.

## 5. What is not here

Acceleration, a scaling, the wheel. Each is a command to the mouse, and
`/dev/mousectl` on the `/dev/consctl` convention is where they belong.
The wheel wants a fourth byte and the protocol dance that asks for it,
and comes the day something scrolls. A cursor, which is the draw server's
to draw and `docs/WORKBENCH.md` step 2's to build. `virtio-input`, which
is what would give the two ports a mouse and a keyboard both, and is the
plan's step 5.

## See also

- `docs/KBD.md` -- the keyboard driver this one is shaped after, and the
  I/O APIC line both assume rather than read.
- `docs/DEVFS.md` -- `#c`, the taps, and the parked read every device
  file here shares.
- `docs/WORKBENCH.md` -- the plan this is the first step of.
