# ADR-0040: Descriptors past 2, and `/fd`

Status: proposed, 2026-10-06. M6 step 6d7b2 (decided the same day: `/fd` as 9front's devdup). It makes the spawn message's `fd=` records, until now musl's back end's own, part of the spawn message's ABI (`abi/vx/abi.h`) for descriptors past 2, for native programs as for POSIX ones, and gives every process a `/fd` naming its descriptors, so rc's `<{...}` and `>{...}` can work as 9front's.

## Context

A native program has had three descriptors, standard input, output and error: channel ends its spawn message names `stdin`, `stdout` and `stderr`, carrying the pipe protocol (a header, then bytes, each message). rc could redirect descriptors 3 to 9 but gave a program none of them (rc(1)). musl's back end has a whole descriptor table, which it passes to a POSIX child in `fd=` records: `fd=N pipe=read|write end=NAME` names a channel end in the message, and other forms name files, sockets and the console.

9front's rc runs `<{cmd}` (`sys/src/cmd/rc/havefork.c`, `Xpipefd`) by making a pipe, giving one end to a forked child running `cmd`, keeping the other as a descriptor of its own, and passing the argument `/fd/N`; the program opens `/fd/N`, which devdup (`sys/src/9/port/devdup.c`) serves from the opener's own descriptor table, as a copy of that descriptor. rc does not wait for the child.

## Decision

1. **Descriptors 3 to 9 in the spawn message** are musl's `fd=` records: `fd=N pipe=read|write end=NAME`, naming a channel end in the message that carries the pipe protocol (`read` is the child's reading end); or `fd=N file=PATH flags=F offset=O [token=T]`, an open file, which the child joins by its token (`Tshare`, `Tjoin`), one join a token, or else opens again by its name at the offset. A native program's vx-rt keeps them, beside 0 to 2 from `stdin`, `stdout` and `stderr`, which stay as they are. musl's back end takes these records beside the three handles too: the handles give 0 to 2, the records the rest, as before when there are no handles (a POSIX parent's message).
2. **A redirected file is the file.** A file rc opened for descriptor 3 to 9 goes as a `file=` record with a token: the program has the open file itself, and takes nothing from it until it reads (a relay would read it for every program given it, whether or not it does; found by fsdadm's `{ rm f; cat <[0=3] } <[3]f`). A here document, a capture and a pipe are relays or channels, as for 0 to 2. A native program passing on a file it was given gives its record without the token, which was good once: the next program opens the name again at the offset.
3. **`/fd/N`** names the opening process's descriptor N, 0 to 9. Opened, it is a copy of that descriptor, read or written as it is: musl's back end opens it as `dup`; vx-ns opens it for a native program through a hook vx-rt sets, a file served by the process itself, not by a 9P server. A descriptor the process does not have is `NOT_FOUND`. `/fd` itself is not listed.
4. **rc's `<{cmd}` and `>{cmd}`** are 9front's: a word that makes a pipe, starts `cmd` in a child with the pipe as its standard output (or input, for `>{...}`), not waited for, and gives the command `/fd/N`, N the lowest descriptor from 3 its redirections leave free, with the other end as that descriptor, kept until the command has run.

## Consequences

- `cmp <{a} <{b}`, `diff <{...}`, and a program written for 9front that reads `/fd/3` work, natively and through musl.
- A file a native program passes on (rc's own descriptor 3, given to its children) is opened again by name, at the offset it was given at, not shared: after it is removed or renamed, they do not find it.
- `/fd` is a name in the process, not a device in its namespace: `ls /fd`, binding it elsewhere or a child's `/fd` showing its parent's do not exist; `ns` does not show it.
