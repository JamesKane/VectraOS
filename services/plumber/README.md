# The plumber

Plan 9's plumber(4) (D85), after todhchai's router: messages in
plumb(6)'s format, routed by its rules to ports. Manifests mount its
tree at `/mnt/plumb`:

| File | What it does |
|---|---|
| `send` | Write a message: routed by the rules to its port. The write fails if no rule takes it (`notFound`), it isn't a message (`invalid`), or its port has no reader and its ruleset starts nothing (`io`). |
| `rules` | The rules in force; a write appends a ruleset (the whole set parsed again; a bad one keeps the old). |
| a port | One for each `plumb to`: a read waits for the next message (D84) and takes one; each channel open on it gets its own copy. |

With no reader on a message's port, `plumb client APP ARG...` starts the
app and holds the message until it opens the port, and `plumb start`
starts it and drops the message. Apps come from its `/bin`, under the job
its manifest's `programs` grants, with its tree at `/mnt/plumb` and its
`/bin`; never a shell.

A message: src, dst, wdir, type and attr a line each (attr `name=value`
pairs, a value quoted '...' when it holds a blank, quote or equals sign),
then ndata, then that many bytes of data.

`lib/` (`Plumber`: `Rules` and `Regex` from todhchai's router, ported to
bytes for tier 0; `Message`, the format; `Plumber`, the ports and
starts; `Defaults`, the rules it starts with) is tested hosted
(`PlumberTests`); `Main.swift` serves it. launch-test sends a URL to
`web`'s reader, and appends a rule whose client `cat` reads the held
message onto the console.

Not yet: plumber(4)'s rules file under a user's lib and `include`, and
OTRUNC on `rules` clearing the set.
