# init: boot to a shell

`boot complete` is a prompt now. The kernel's last act, after every check,
is to start `/bin/rc /lib/init`: an rc script on the disk, run as the
first program, with the console as its three descriptors. What it does is
the script's business, and the script is `apps/rc/init`, staged by the
build into `build/esp/vectra/lib/init` and reached as `/lib/init` through
the bind `docs/FATFS.md` describes.

    kbdfs &                          the keyboard, served as a file
    while(! test -e /srv/kbdfs) sleep 1
    mount /srv/kbdfs /n/kbd
    intuition /n/kbd/kbd &           the draw server, reading its keys there
    while(! test -e /srv/draw) sleep 1
    terminal &                       a window with a shell in it
    cd $home
    exec rc -i                       and this console's shell, which init becomes

## Two shells, two keyboards

The machine has one console, `/dev/cons`, into which the kernel's line
discipline puts both the serial line and the keyboard. A window system that
cooks per window has to take the console raw, and then the serial line is
raw with it and belongs to the window in front -- which is what the draw
server did until this step, and what would have left a serial shell with
no line of its own.

So `init` splits them. `kbdfs` opens `/dev/scancode`, which diverts the
keyboard out of the console into a file `kbdfs` serves, translated. The
draw server is started with that file's name and reads its keys there
instead of at `/dev/cons`, and so never writes `rawon` to the kernel. The
console keeps its discipline, cooked and echoing, and holds the serial line
alone. A shell on it is an ordinary program reading descriptor zero.

On the `virt` boards there is no keyboard controller, so `kbdfs` serves a
file nothing ever arrives on, the window cannot be typed at, and the serial
line is the machine's whole keyboard. The window is still there with its
prompt, drawn by a shell that will wait as long as it takes.

## The terminal, which is a window with a shell in it

`apps/terminal` is `rio`'s window in miniature. It claims a window, uploads
the font, starts `/bin/rc` with two pipes for its three descriptors, and is
from then on two things at once: the glass the shell's output lands on and
the keyboard its input comes from. Both park, and a proc cannot wait on
two things, so it is `sys/libthread`'s shape: a proc reading the shell's
output, a proc reading the window's keys raw, each sending what it reads
on a channel, and one thread that waits on both with `alt`. Shell output
goes into the grid. A key goes through `libedit` into the line, drawn as
it is typed at the cursor, and a finished line goes to the shell. A grid
of cells with a cursor is what the window shows: newline, return,
backspace and tab mean what they mean, and a line past the bottom scrolls
the rest up.

The drawer owns the ending. When the shell's output pipe closes, the shell
is gone -- a typed `exit`, or a fault -- and `threadexitsall` takes the two
readers down and exits, which closes the window.

The window system does not echo, and that is why the terminal draws the
typed line itself; `docs/DRAW.md` section 14 says why the discipline lives
where it does. The terminal no longer touches the kernel's `consctl` at
all: it reads a window's console, and the kernel's belongs to the serial
shell, whose echo an earlier terminal's `echooff` would have turned off.

## What the kernel does

`init_init` in `kernel/main.odin` checks `/lib/init` is there and starts
`/bin/rc /lib/init` through `user.start_program`, which is `start_server`
without the wait: the process is the machine's from then on. It runs after
every self-test, including the multiprocessor one, so no check counts it,
and just before `boot complete`. The boot thread exits after that and the
idle loops keep the machine running, which is what every ring 3 server
that outlives the boot already relied on.

`rc` itself grew one thing: after a line runs, or fails to parse, the next
prompt is `$prompt(1)` again rather than the continuation's. The
interactive path had been written and never exercised, as `docs/RC.md`
said.

## What it cost, and what it says

Two shells took thirteen processes when this was written:

    fatfs, kfs                     one serving process each
    the serial shell               one
    kbdfs                          a server and a reader
    intuition                      a server, a reader, and a worker per parked read
    terminal                       a drawer, a typist, and its rc

That was three times what Plan 9 spends on the same picture, and the cost
of one missing thing: a process here cannot wait on two descriptors, so
every server with two blocking sources forks a reader, and `serve_mux`
forked a worker for every request that parked. The process table went from
twelve to thirty-two for this step and the console's fid table from
sixty-four to two hundred and fifty-six, because a running system is not a
self-test; `docs/PROCS.md` step 2 took both further. `docs/PROCS.md` is the
process and thread system revisited to be Plan 9's. Its first step took
the workers away, and two shells were ten processes. Its fourth put the
servers on `sys/libthread`, and they are thirteen again, differently:

    fatfs, kfs                     one each
    the serial shell               one
    kbdfs                          a proc of threads, a reader for its pipe,
                                   and a reader for the scancodes
    intuition                      the same three
    terminal                       the same three, and its rc

The three more are the pipe readers, and they are what no server holding
a lock cost. `docs/THREAD.md` section 10 is the argument, and `ps` from
the serial line lists them, every one `Blocked`.

## Checked by

`verify_terminal` in `kernel/user` now types into a window that has a
shell in it: it waits for rc's `% `, types `hi!` and edits it, sees the
line on the glass as it is typed, sends it, and sees rc answer on the
next row and prompt again before typing `exit`, which ends rc and the
terminal with it. The serial shell is checked by hand, on the line, from
the host:

    % echo hello from the serial line
    hello from the serial line
    % pwd
    /usr/glenda
    % ls /n/esp/vectra/bin | wc -l
         41
    % echo boot `{cat boots} >> visits; cat visits
    boot 16

`boots` is the count `docs/KFS.md`'s self-test keeps, and `visits` is a
file that is still there the next boot.

## What is not here

- **`^C` in a window on a machine with no keyboard**, which is every
  `virt` board: the serial line's `^C` reaches the serial shell, and the
  window has no keys to carry one. `docs/PROCS.md` step 3 is where `^C`
  itself arrived.
- **A second window**, and a way to make one. `MAX_WINDOWS` is two.
- **A login**, or a user other than glenda.
- **The draw server on the serial line's terms.** A machine with no
  keyboard shows a window it cannot type at.
