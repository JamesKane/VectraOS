# The tools

`cmd/` is one package per command, one binary each, built like the servers
and served from `/bin`. Plan 9's tools, with Plan 9's flags where the flag
was worth having, and none of POSIX's. `docs/SHELL.md` step 3 is the plan
they came from; this is what they are.

## What there is

    echo [-n] args          cat [files]             ls [-dlp] [files]
    pwd                     mkdir [-p] dirs         rm [-rf] files
    cp from... to           mv from... to           cmp [-s] a b
    wc [-lwc] [files]       tee [-a] files          tail [-n N | +N] [file]
    grep [-cinsv] re [files]   sed [-n] [-e s]... [file]
    sort [-rnu] [files]     uniq [-cdu] [file]      tr [-d] set1 [set2]
    basename [-d] path [suffix]   cleanname [-d dir] names
    test expr               seq [first [incr]] last sleep seconds
    read [-m]               env
    bind [-abc] new old     mount [-abc] /srv/name old   unmount [new] old

`mv` is a copy and a remove, because no server here renames yet. `grep`
and `sed` share `sys/libregex`, Plan 9's dialect: `. * + ? [] ^ $ | ()`
and `\`, run as a Thompson simulation so a pattern is never exponential.
`sed` knows `p`, `d`, `q` and `s///[gp]` under line, `$` and `/re/`
addresses, which is the sed a build script uses. `ls -l` prints the mode
and size; there is no owner and no clock to print yet.

## How a tool is written

Three lines of ceremony and then the work, with `sys/libuser` for the rest:

    @(export, link_name = "_start")
    start :: proc "c" (block: ^abi.Args) {
        context = libuser.startup()
        args := libuser.args(block)[1:]
        ...
        libuser.exits(status)
    }

`libuser.Reader` and `read_line` for a line at a time, `read_all` and
`read_file` for the whole thing, `Bio` for output that comes in pieces,
`eprint` for an error line, `itoa` and `atoi` for the numbers. None of the
tools formats through `core:fmt`: a tool that does is a hundred and fifty
kilobytes in the image, and one that does not is a few. The exit status is
a word: empty for success, the reason otherwise, which is what `rc`'s `if`
and `&&` read.

## Where the files go

`servers/memfs` is the filesystem the tools work in until the disk: a tree
in memory, files that grow as they are written, made and removed by name.
It posts `/srv/memfs`, forks, and the parent exits, so a shell can start it
on one line and mount it on the next. Removing a file is a `Tremove` it
answers and carries on from -- `libuser.serve` grew a `remove_stops`
argument for it, because every server before it was a fixed tree that took
`Tremove` as its stop. The teaching `ramfs` keeps its two files and its
name for now; when the disk lands and it retires, `memfs` takes the name.

Behind memfs the kernel grew `mkdir` -- a create with `DMDIR` in the mode
becomes `Tmkdir` on the parent and a walk to the child -- and `unmount`,
which `sys/abi` numbers 37. `/lib` joined the root's directories, served
by `#l` from the image: the test script lives there, and later steps will
put more.

## Checked by

`tests/tools.rc`, run by `verify_tools` in `kernel/user` as
`rc /lib/tests/tools.rc`. One `check` line per tool:

    check name expected command-output...

The output words are joined, so a command that prints several or none
compares as one string. The script starts `memfs`, mounts it at `/mnt`,
does its file work there, and takes both down. Its exit word is the count
of checks that held, and `TOOLS_EXPECTED` in `verify.odin` is the number of
tools, so a tool added to `cmd/` without a line in the script fails the
boot -- which is the point. The lines land in the serial log, `ok name`
each, for a person.

## What is not here

`awk`, `sam`, `ed`, `diff`, `tar`, `date` -- each waits for a reason or a
clock. `ls` has no time column and `test` no `-r -w -x`, because files have
no owner yet. `mv` across a rename-capable server, when there is one.
Regular expressions have no captures, so `sed` has no `\1`.
