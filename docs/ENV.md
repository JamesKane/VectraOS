# The environment device

`kernel/env/` is `#e`, bound at `/env`: a directory whose files are
variables, one directory per process. Plan 9 keeps a process's environment
here rather than in the process, and every tool that reads or sets one is
a client of the directory like any other program.

    cat /env/path              read it
    echo -n /bin > /env/path   set it
    rm /env/path               unset it
    ls /env                    list it

## One group per process

The directory a process sees is its **environment group**: a table of up
to `MAX_VARS` variables with a reference count. A process holds exactly
one, in `Process.env`, and the holding follows the descriptor table's
rules to the letter:

| event | the child's group |
|---|---|
| `spawn` | a copy, so a shell's `x=y cmd` reaches the command and not the shell |
| `rfork` | shared, unless `RFENVG` copies it or `RFCENVG` starts it empty |
| `rfork` without `RFPROC` | the same two flags act on the caller, in place |
| `exec` | kept; the program changes and the environment does not |
| `exit` | one holder gone, and the last one frees the values |

The pool is `MAX_GROUPS` records, sized like the descriptor pool: one per
process slot plus slack for a fork that holds its copy beside the
original. `env.live()` is the sensor the user suite's balance checks read.

## One server for every group

The device is one `vfs.Server`, and a message names a fid. A fid on a
**variable** names it absolutely: `group slot << 16 | id`, where the id is
monotonic within its group and never reused, so a fid opened on a name
that is then removed and recreated names nothing rather than the newcomer.
A fid on the **root** names whoever is asking. A walk from it, a listing
of it and a create in it all resolve the group of the calling process,
through the resolver `kernel/user` registers at boot. The device imports
nothing about processes, which is the same door `kernel/srv` opens for a
descriptor number in a `Twrite`.

That works because the device is synchronous: every message runs in the
caller's thread, where `current process` is defined. Off a process the
root answers as an empty directory.

## Reads, writes and the shell's idioms

A value is a byte array up to `VALUE_MAX`, grown from the heap in powers
of two so a shell appending a path one element at a time does not
reallocate per write.

    Tread      the bytes from the offset
    Twrite     overwrite from the offset, extend, zero-fill a gap
    Tlopen     with O_TRUNC, empty first
    Tsetattr   a length truncates or zero-fills; mode and times are ignored
    Tlcreate   a new name, empty and open; an existing one is EEXIST
    Tremove    the name and its value go
    Treaddir   the caller's group, with the id as the cookie

This is Plan 9's `devenv` behaviour, and it is what lets `echo x > /env/y`
replace and `>>` append without the device knowing which a shell meant.
Files are `0666` and the directory `0777`: a process's environment is its
own to change.

## What is not here

No `#ec`, Plan 9's read-only view of the boot environment. No `envcpy`
into a program's memory: a program that wants a variable opens the file,
which is what `sys/libuser` will do for `getenv`. Nothing yet writes
`$path` at boot; the shell's `init` will, and until then `/env` is empty
when the first program starts.

## Checked by

`tests/abi`, spawned by the user suite as `/bin/abitest`: create, write,
read, truncate, stat, list, a spawned copy that reads what its parent
wrote, an `RFENVG` copy that changes its own and not its parent's, an
`RFCENVG` child that finds nothing, a sharing child whose `rm` reaches its
parent. `verify_rfork` in `kernel/user` checks the group pool balances and
that `rfork(RFENVG)` is granted in place.
