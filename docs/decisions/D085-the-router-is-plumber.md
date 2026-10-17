# D85. The router is Plan 9's plumber: plumber(4)'s files (2026-10-17, decided)

todhchai's router (M6k) is Plan 9's plumber in substance, its rules
plumb(6)'s and its regular expressions regexp(6)'s, but its interface is
a typed protocol: `Router.route(message)` and `listen(port:channel:)`
with message events. D79 to D82 moved the network, processes, the
environment and the device classes to Plan 9's file trees, and D84 lets
a read wait, which a port file needs. The owner's direction
(2026-10-17): serve plumber(4)'s files.

- **The plumber serves `/mnt/plumb`**: `send` (a plumb(6) message
  written there is routed by the rules), `rules` (read the rules in
  force; a write appends a ruleset, the whole set parsed again, a bad one
  keeping the old) and a file for each port the rules name (`plumb to`),
  never taken away. A port's read waits for its next message (D84) and
  takes one at a time; each channel open on a port gets its own copy
  (Node's per-channel streams).
- **With no reader on its port**, a ruleset's `plumb client APP ARG...`
  starts the app and holds the message until the app opens the port;
  `plumb start` starts it and drops the message; with neither the write to
  `send` fails. Apps come from the plumber's `/bin`, under the job its
  manifest's `programs` grants, given its tree at `/mnt/plumb` and its
  `/bin`; never a shell, as todhchai had it.
- **Messages are plumb(6)'s text**: src, dst, wdir, type and attr a
  line each, then ndata and that many bytes of data. rc and tools plumb
  by writing `send`, with no client library; cpu and import reach a
  terminal's plumber as files (D77).
- todhchai's rules engine (`Rules`, now on bytes for tier 0, gaining
  `plumb client`) and its regexp (`Regex`, a Pike VM) are lifted; its
  typed `RouterIPC`, `RouterState` and SDK routing are not. `services/router`
  is `services/plumber`.

Not chosen: lifting the typed router as provenance first listed it (a
protocol beside the file tree every other service now has); an include
statement and the rules file under a user's lib (rules start from the
plumber's built-in set and grow by writes to `rules`, until there is a
user's directory to keep them in).
