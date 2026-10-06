# ADR-0029: Broad grants are separate, visible and revocable; no program gets the whole home by default

Status: accepted, 2026-10-06 (proposed 2026-10-03).

## Context

Rule 3 makes the namespace the authority, and 02 §7 confines `aid`'s agents to a template, an `auditfs` view of one project, and grants made through the trusted path (03 §5.7, §8.5). That covers agents the system starts. It does not yet cover three other ways one program can come to see everything a user has:

- **The POSIX template.** 02 §2 showed `/lib/ns/posix` binding `#home/$user` whole. The template as built (`boot/lib/ns/posix`, M4) has no home yet, but the documented intent gives every POSIX program all of the user's files and `/net` together. A third-party agent (a coding agent's command-line client, ported or installed as a POSIX program) would get them with none of `aid`'s labels, audit or undo.
- **Grants that look routine.** 06 §3 shows a package's namespace grants in one list beside its dependencies and keys. A package asking for all of `/home` reads like one asking for `/dev/audio`, so a user approves it the same way.
- **Aggregates.** The dump view holds every file the user has deleted. A context pool (`/ai/ctx/*`) can hold mail, messages, window text and files together. Neither is classed as anything special when it is granted.

Apple's change to Full Disk Access in macOS (announced 2026-10-02) is the same problem met late: one grant that sidesteps every other control, kept because backup tools need it, and riskier as agents become capable and autonomous. We decide this before M7 brings packages and before M11 brings agents, rather than retrofitting it.

## Decision

1. **A broad grant is any of these:**
   - all of a user's home (`#home/$user`), or any tree that contains another app's data;
   - another app's data tree (decision 5);
   - the dump view and snapshots (`/n/snap`, `fsd`'s `dump` attach, a label);
   - `fsd`'s `adm` files, or any connection to `fsd` not attached at a restricted root;
   - the whole `/wsys` tree, or another window's `a11y` (03 §5.7);
   - debugging access (`/proc/N/mem`, `ctl`) to processes other than the holder's own children;
   - a context pool holding items from more than one source, or from mail or messages (02 §5.6);
   - `auditfs`'s logs of sessions other than the holder's.

2. **Broad grants are given only from the grant settings,** a surface the user opens, drawn on the trusted path (03 §5.7) and answered only by physical input, with a deliberate action (the user types the program's name). They are never given:
   - in an install's list of grants (06 §3), which shows them apart and says they are not yet given;
   - in answer to a program's `request` (02 §7), so a program cannot make the prompt appear. It can say what it needs and point the user to the settings;
   - by "always for this project" or any other standing approval.

   Agents never hold a broad grant. A user who wants an agent to see more makes a narrower view for it.

3. **They are visible and revocable.** `svcd` keeps every grant (broad grants and standing approvals) as ndb records. They are readable, and are changed only through the grant settings. They are not a file in `$home`, so a program that can write the home cannot grant itself anything. `/proc/N/status` names each broad grant a process holds, and the status bar marks it while a holder runs. A broad grant is tied to the package and its publisher key. It is asked for again when a package update changes the package's grants, and lost when the key changes.

4. **No program is started with more than its starter has, unless it carries its own grants:**
   - A process can mount only connections it holds handles for (02 §2), so a share, copy or clean spawn can never be wider than its parent.
   - The only wider start is `svcd` starting a package under the grants its manifest declares and the user gave it.
   - A package started at a confined process's request (an agent session, or anything running under a template narrower than the user's session) runs without its broad grants.
   - The plumber marks each message with its sender's confinement, and its rules do not start a holder of a broad grant for a confined sender.

5. **The POSIX template gives no home:**
   - `/lib/ns/posix` binds the system's view only, as `boot/lib/ns/posix` does today.
   - `/lib/ns/posix.user` adds `#home/$user`. It is used only for the user's login session (the console shell, the desktop session) and what that session runs directly.
   - A package's POSIX program gets `/lib/ns/posix`, its own data tree (`#appdata/$user/PKG`) as `$HOME`, and what its manifest's `needs=` names. `needs=cwd` binds the directory it was started in, at the same path, `-c`. That is what a compiler or a command-line agent needs, and nothing more.
   - **A package's programs always run in its manifest's namespace, whoever starts them.** Typing a package's command in the shell starts it through `svcd`; it does not join the shell's group.
   - What the user builds and runs themselves, unpackaged, runs as the user (rule 13: their user land is their business). `newns -n /lib/ns/NAME command`, after Plan 9's `auth/newns`, runs such a program under a narrower template.

6. **App data is kept out of the home:**
   - Each package's state (an adapter's local store, a mail client's messages, a browser's history) lives in its own tree, `#appdata/$user/PKG`, a separate attach root on `fsd` that `#home/$user` does not contain.
   - Only that package's namespace, the grant settings, and a broad grant reach it.
   - System search indexes another app's messages only after the user adds them to a pool. That pool is then a broad grant when given to anything else (decision 1).
   - `aid` itself never holds a home connection: a pool's `add` takes a handle the caller passes, not a path for `aid` to resolve.

7. **Backup needs no broad grant once the volume is encrypted.** `fsd` can export a snapshot as a stream of its blocks, still encrypted under the volume's key (11 §12). A backup program stores and restores the stream without ever holding the key or reading a file. Until encryption lands, backup is a broad grant to the dump, and the grant settings say so.

## Consequences

- 00 gains D22. 02 §2, §5.6 and §7; 03 §8.5; 06 §3.3, §3.4, §7 and question 9; 07 §6.1, §8; and 11 §12 are amended to match.
- `boot/lib/ns/posix` already matches decision 5. `posix.user` arrives with `fsd` serving homes. `#appdata`, the grant settings, `svcd`'s grant records and launching packages through `svcd` arrive with packages at M7. Pools and agents arrive at M11.
- Porting a POSIX tool that reads or writes `~/.config` or `~/.cache` changes nothing: its `$HOME` is its own data tree. A tool that expects to read the user's real dotfiles (a shell, an editor's configuration) is run from the user's session, or packaged with an explicit `needs=` for that one file.
- Undo and labels (03 §8.5, §8.6) still cover only `aid`'s sessions. A POSIX agent is confined by its namespace and nothing else. This ADR makes that namespace narrow by default; it does not track what the agent does inside it.
- The grant settings are a new trusted-path surface, which `winsrv` and the shell must draw, at M7.
