# rc, the shell

`apps/rc` is Plan 9's shell in Odin: the same grammar, the same list
semantics, the same execution model. It is what `boot complete` will
become. It runs a script from `-c`, from a file, or interactively from
descriptor 0, and `/bin/rc` is in the image.

    rc [-c command] [-eix] [file [arg ...]]

## The shape

A line is read, parsed into a tree, run, and freed, and the next line is
read. The parser is a recursive descent, one procedure per level of the
grammar, in `parse.odin`; its file comment is the grammar. The tree is
`tree.odin`, and the walk over it is `exec.odin`.

    lex.odin      words, quotes, the free caret, `$x(1)`, `<<tag`
    parse.odin    the grammar
    tree.odin     Node, Redir, and what each kind means
    word.odin     a word's value: lists, `^`, `$#`, `$"`, patterns, globbing
    exec.odin     the walk: forks, pipelines, backquotes, redirections
    builtin.odin  the commands that must run in the shell's own process
    var.odin      variables, and their mirror in `/env`
    status.odin   `$status`, and `await` behind it
    input.odin    characters from a string, a file, or a descriptor
    main.odin     options, `rcmain`, the read-run loop
    rcmain        the defaults, run before the first command

**The tree is walked, not compiled.** Plan 9's rc compiles a line to
bytecode and runs a small machine. Here a fork copies the interpreter
whole and the child continues from the node it was forked with, so the
pointer is all a child needs. That is what the bytecode was buying.

## Processes

Every fork is `rfork(RFPROC|RFFDG)`: a copy of memory, a copy of the
descriptor table, the environment shared. A simple command that names a
program forks, and the child applies its redirections and execs. A
pipeline forks a child per stage, and the parent closes both pipe ends
before it waits, so the reader sees the end when the writer is gone. A
forked child whose whole node is one program execs it in place rather than
forking again, as Plan 9's rc does: `sleep 100 &` leaves `$apid` naming
the sleep itself, so `kill $apid` reaches it, and a pipeline of n stages is
n processes. A
backquote forks one child with its output into a pipe, reads the pipe to
its end, and splits on `$ifs`. `&` forks and does not wait; `$apid` is the
child. `@` is a subshell.

A child's status comes back through `await` as `pid word`, and the word is
`$status`: empty for success, a reason otherwise, `fault` for a program
that faulted, the number for one that used the numeric `exit`. A
pipeline's status is its stages' joined by `|`. `await` gives up every
half second and the shell asks again; `wait` with no argument is
`await(0)`, any child.

## Words

A word evaluates to a list. `$x` is the variable, `(a b)` is two, `$#x` is
a count, `$"x` is one string, and `^` distributes: one against many gives
many, equal lengths pair off, anything else is an error. Pattern
characters travel through evaluation as a mark byte before each unquoted
`*`, `?` and `[`, as in Plan 9. A simple command's arguments are matched
against the filesystem, component by component over `dirread`, and a word
that matches nothing is itself. `~` and `case` match against a string.
Everywhere else the marks come off.

## Redirections

`<`, `>`, `>>`, `<>`, `>[2]`, `>[2=1]`, `>[2=]`, `|[2]`, `|[2=0]`, and
`<<tag` here documents with `$name` substituted unless the tag is quoted.
A command that runs in a child applies its redirections and does not look
back. One that runs in the shell -- a builtin, a function, a brace -- has
them applied and then undone: the descriptor being replaced is parked on a
number from 20 up and put back after. `exec` is the one whose
redirections are meant to stay.

## Variables and `/env`

A variable set is written to `/env/name`, its elements separated by NUL,
and the table is read back from `/env` at startup, so a program rc starts
sees what rc set, and an rc a program starts sees what the program's
environment held. `$*`, `$0`, `$status`, `$apid` and `$n` stay out of the
file. `x=y cmd` sets `x` for `cmd` and puts the old value back.

The variables and functions are tables searched by name rather than
maps. Odin's `map` lost every entry in this build, silently, and a shell
has dozens of either, which a scan finds faster than a hash would.

## Builtins

`.` `builtin` `cd` `eval` `exec` `exit` `flag` `rfork` `shift` `wait`
`whatis`, and the keywords `if` `if not` `for` `while` `switch` `case` `fn`
`~` `!` `@`. `rfork` takes Plan 9's letters: `n N e E s f F m`.

## What is not here

`<{cmd}` and `>{cmd}`, which need `/fd`. The `` `` `` backquote with its
own separators. Functions in `/env` as `fn#name`. Notes, so `^C` does
nothing yet. `whatis` prints `fn name {...}` rather than the body. The
prompt and interactive reading are written and not yet exercised: nothing
gives rc a console until `docs/SHELL.md` step 8.

## Checked by

`verify_rc` in `kernel/user` spawns `/bin/rc -c` on a one-line script
with a function, a `for`, backquotes, a pipeline through `echo` and `cat`,
a `while`, a `switch`, `~`, `$#` and `$"`, and reads the word its `exit`
says. Twenty forks and execs of a copied shell on an emulated core take a
few hundred ticks -- 160 to 260 across the three boards, ten times any
other program -- which is why its patience is longer than theirs.
`cmd/echo` and `cmd/cat` exist because a pipeline needs two ends.
