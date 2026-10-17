# The Ghost in the Machine

A vision and high-level design (2026-10-17, proposed; D90). It says what
the Ghost is, the rules it lives under, how it is built from mechanisms
the system already has, and what the earlier milestones must design in
now so it doesn't need a second mechanism later. Nothing here is
scheduled yet; §11 proposes where it goes.

The starting point is NeoVectra's `aid` (`NeoVectra/docs/03-desktop-agentic.md`
§8 and `18-verbs.md` §4). §12 says what is taken from it and what
changes.

## 1. What it is

The Ghost is an opt-in agent that lives in the namespace. It reads what
the system says about itself, talks to the user, and acts only through
the files and verbs it was given. It has three jobs:

1. **Insight.** It turns the system's failures into something the user
   can act on: what happened, the evidence, the likely cause, and a
   previewed fix.
2. **Evolution.** It changes the system to fit its user (rules,
   bindings, namespaces, scripts, and on the developer's host, source),
   always as a reviewable, reversible change set.
3. **Automation.** It writes automations: rc scripts with triggers,
   which then run without it.

It is **local first**. Models run on the machine's own CPU, GPU and NPU,
then on the user's own swarm, and reach a cloud frontier model only
where the user's policy allows it, and the user can always see when that
happened.

## 2. The rules it lives under

The Ghost adds no mechanism the system lacks. Each of its parts is an
existing mechanism used for one more purpose:

| Need | The mechanism it uses | Principle |
|---|---|---|
| Talking to it | a service's node tree, `/svc/ghost`, and the `ghost` command | 5, 19 |
| What it may touch | its session's namespace, made from a template | 26 |
| Its tools | the verbs of the services in that namespace, from their `.schema` and `.help` | 1 |
| Inference | `/dev/accel` and `.vxm` artifacts on the first-party executor (architecture §8) | 28, D4 |
| Bulk data (tokens, embeddings, audio) | the one ring | 6 |
| Events in | rings it attaches to and the plumber's ports (D85) | 9 |
| Keys for providers | factotum (D75) | 26 |
| Undo | Taisce's copy-on-write snapshots | 1, 18 |
| Audit | its own `actions` files and the trace | 14, 19 |
| Automations | rc scripts, plumber rules, and a time trigger (§7) | 1 |

Five rules follow, and they shape everything below:

- **Off means absent.** Without the Ghost installed and enabled there is
  no `/svc/ghost`, no process, no model in memory, and nothing else in
  the system depends on it. Every surface in §9 disappears with it.
- **The model authors; the result doesn't need the model.** An insight's
  fix is an rc line or a plan of verbs. An automation is a script. A
  learnt failure becomes a rule. What the Ghost leaves behind runs, is
  read and is debugged like anything a person wrote.
- **Every claim cites a node.** An insight's evidence is a path: a trace
  record, a debuglog sequence number, `/proc/N/status`, a manual page's
  BUGS section. An answer with nothing to cite is labelled a guess.
- **Every change is a proposal first.** The user sees a diff or a plan
  before it runs. Changes to files run under a snapshot and undo in one
  step; the Ghost says plainly what can't be undone (§8).
- **Nothing leaves without a policy and a lamp.** Local is the default
  route, and egress is decided while a prompt is assembled, never after.

## 3. Shape

```
 surfaces     ghost(1) in rc · Radharc slips and panel · plumbed text · cpu sessions
 ───────────────────────────────────────────────────────────────────────────────
 /svc/ghost   ctl · status · policy · usage · models/ · providers/ · insights/
              clone → N/ { ctl  data  events  actions  ns }        (one per session)
 ───────────────────────────────────────────────────────────────────────────────
 ghost        sessions, the tool loop, context assembly, labels, placement
 (tier 1)     watchers: debuglog, trace, /proc notes, exit strings, budgets, status
 ───────────────────────────────────────────────────────────────────────────────
 runners      one process per loaded model: its .vxm, its accel context, nothing else
 providers    one process per frontier provider: /net, one factotum key, TLS
 ───────────────────────────────────────────────────────────────────────────────
 /dev/accel/* (CPU · GPU · NPU executor backends)   ·   swarm accel over 9gate (V7)
```

- **`ghost` is a tier 1 service** (full Swift). It is on no real-time
  path, and its sessions, contexts and tool loop are object graphs with
  shared ownership, which tier 0 doesn't have.
- **A session is a process,** started by `ghost` with a namespace made
  from a template (§8). `clone` gives a session directory, as Plan 9's
  `/net` does: `ctl` (verbs: `ask`, `cancel`, `approve`, `deny`,
  `close`), `data` (the conversation, streamed on a byte-stream ring,
  D46), `events` (a waiting read, D84: tool calls, approvals asked,
  egress), `actions` (every mutating operation, in order) and `ns` (the
  session's namespace, readable).
- **Runners** are sandboxed processes holding one model's `.vxm` and an
  accelerator context. A runner that crashes takes down only the
  requests it was serving. Weights are mapped from Taisce, not read, so
  several sessions share one copy.
- **Providers** are adapter processes under `/svc/ghost/providers/NAME`
  that look like a runner from inside: the same request and stream. Each
  holds `/net`, factotum's RPC for its one key, and nothing else.

## 4. Inference, local first

### 4.1 Models are artifacts, not runtimes

D4 rules out NeoVectra's vendored llama.cpp, whisper.cpp and ONNX
runtime, and its on-device GGUF parsing. Instead:
- **`vxc` converts models on the host** (GGUF, safetensors, ONNX) into
  `.vxm`: the graph in TOSA and the weights, quantised, in the IPC wire
  format. The device never parses a third-party format.
- **The executor gains what decoding needs**: quantised matrix products
  (int8 and int4 with scales), attention with a KV cache kept as a
  device buffer (principle 8's buffer currency), and sampling. The CPU
  backend stays the reference that every other backend is checked
  against (architecture §8). Whether these are TOSA ops or extensions in
  `.vxm` is open (§13).
- **Model weights are data from third parties.** D4 covers code; weights
  need their own rule (§13). The proposal: allowed, as firmware blobs
  are, each listed with its source, licence and digest, and converted
  only by `vxc`.

### 4.2 Placement

`ghost` places each request by what the work is, what the machine has,
and what the user's policy allows. The order is always local, then the
user's swarm, then a provider.

| Work | Preferred | Why |
|---|---|---|
| Embeddings, classifiers, OCR, speech: small and sustained | NPU (the Sky1's, the CDSP) | Performance per watt; leaves the GPU to frames |
| Decoding for chat and insight | GPU, weights resident | Memory bandwidth dominates |
| Long prefill | GPU, or a swarm node's when the round trip is small | Compute dominates |
| Indexing the manual, logs and files | NPU, else CPU with `background` intent | Never noticed |
| Beyond the local models | swarm, then a provider, by policy | Local first |

- **Both memory models** (D56): on unified memory a model's weights are
  `.device` memory beside the desktop's; on a discrete GPU they are VRAM
  and count against the Ghost's job (D57's answer applies).
- **The frame deadline wins.** Inference submits on non-realtime GPU
  queues. Where the GPU can preempt compute, the driver preempts it for
  composition; where it can't, runners split work into dispatches under
  a budgeted size (§10), adapting to the driver's queue latency.
- **Memory pressure unloads models first.** The Ghost's job has its own
  memory limit, and when the root account reports a level (D31) the
  Ghost drops its least recently used model or steps down a
  quantisation before anything else feels it.
- **Thermals and power** reach it as capacity (D68): on a hot or
  battery-powered board it prefers the NPU and caps GPU work.
- **A board without a capable accelerator** still gets the deterministic
  half of the Ghost (§5's signatures, §7's automations) and small models
  on the CPU, and reaches bigger ones on a swarm node: the AMD tower or
  the Mac Pro's D700s (whose power management must fail safe).

### 4.3 Frontier providers

- A provider (for example the Anthropic API with current Claude models)
  is mounted at `/svc/ghost/providers/NAME` and used only where a
  `route` in the policy names it (§8.4).
- **The key lives in factotum.** The adapter asks for it per session
  over factotum's RPC; no app and no session ever holds it.
- **HTTPS needs a first-party TLS 1.3 client** on D89's crypto. Nothing
  in the tree has one yet; it is a dependency (§11).
- **`usage`** says where every request ran, its tokens, and its cost
  against the policy's budget.

## 5. Insight

### 5.1 What the system already says

VectraOS is built to explain itself (principle 19), so the Ghost has
structured inputs from the start. It reads them, through its namespace:

| Source | What it gives |
|---|---|
| The debuglog ring (D38) | kernel and driver messages, with sequence numbers to cite |
| The trace (D50) | spans, budgets' events, what a failing run kept (principle 14) |
| Exit strings (D72) and rc's `$status` | why a program ended, in words |
| Notes (D87) and `/proc` (D79) | what a process died of, its handles and memory |
| `budget ...` lines and `vx bench` reports | a promise missed, by how much, against which history |
| `/svc/*/status`, devmgr's trees, `/dev` | a service or a device that is down or degraded |
| The manual (D86) | what the component does, its limits, its BUGS |

### 5.2 From failure to insight

```
 sources ──► watchers ──► signatures ──match──► insight (no model)
                              │
                              └─no match──► session: gather evidence ──► model ──► insight
                                                                          │
                                         insight confirmed by the user ───┴─► new signature
```

- **Watchers cost nothing while nothing fails.** They attach to rings
  and wait on one port (principle 9); none polls. `idle.wakeups` holds
  with the Ghost enabled.
- **Signatures come first.** A signature is a plumb(6)-style rule (D85's
  rules engine and regexp): a pattern over a source's records, and the
  insight it produces. Most repeated failures never reach a model.
- **A model sees evidence, not the world.** For an unmatched failure the
  Ghost assembles a context: the records around it, the process's
  `/proc` entries, the manual pages of the components involved, and the
  relevant source when the user is a developer with the tree mounted.
- **An insight** is a file under `/svc/ghost/insights/`: what happened,
  the evidence (paths and sequence numbers), the likely cause (cited or
  labelled a guess), and an action, an rc line or a plan of verbs that
  the user previews and runs (§8.2).
- **Learning is a rule, not a weight.** When the user confirms an
  insight, the Ghost proposes a signature for it, which the user keeps
  or doesn't. The system's knowledge of its own failures grows as
  readable rules.

Examples of what the user gets:
- `ghost why` after a failed command: "`mount` failed: 9gate refused the
  peer's key (the debuglog, seq 4412). The key changed since
  pairing. The plan: show both keys, then trust the new one in
  factotum, on approval."
- An amber slip after a boot: "`boot.userboot_start` rose 18% on
  this board, past its floor. The trace puts the time in PCI
  enumeration, waiting on one device's link (the span is cited).
  Compare interleaved first: `vx bench --compare HEAD~1`."
- A driver crash: the devmgr's restart, the fault from `/proc`, the
  driver's page's BUGS entry that matches, and the bug report drafted as
  a file.

## 6. Evolution

The system is configured by files, so evolving it is writing files. The
Ghost writes at three depths, each a change set the user reviews:

| Depth | What changes | Where it runs | Undo |
|---|---|---|---|
| Settings | plumber rules, `/env`, Radharc bindings and layout policies, namespace templates, launcher manifests | on the device | Taisce snapshot |
| Scripts | rc scripts and their triggers, signatures (§5.2) | on the device | Taisce snapshot |
| Source | patches to the user's tree: a driver quirk, a new command, a tier 1 program | on the developer's host, built and tested by `vx` | git |

- **Every change is attributed.** Each file the Ghost writes carries
  Taisce attributes (`sys:origin=ghost`, the session and the request),
  so "everything the Ghost changed this week" is a live query, and the
  user can review or revert it in Tracker.
- **Source changes follow the repository's rules.** A patch comes with
  its test and its manual page (D86), runs through `vx test --changed`
  (D88), and is applied by the developer, never on the device. The
  device has no compiler; a script is the deepest change it runs.
- **A frontier coding agent on the host** (Claude Code, for example)
  is the natural author for source. It reaches the device through `vx
  cpu` (D77) like any developer tool, with the namespace the developer
  exports, and is not a Ghost session.

## 7. Automation

An automation is an rc script, a trigger, and the namespace it runs in.
It runs without a model.

- **Triggers are existing events:** a plumber rule (a file changed, a
  message of a type, D85), a device's arrival in devmgr's tree, a note,
  an insight, or a time. Time is the one trigger the system lacks a
  mechanism for; §13 asks which one it gets (Plan 9's cron is the
  candidate, on absolute deadlines, principle 10).
- **Authoring:** the user says what they want ("when a camera appears,
  start the detector and send its masks to the dashboard"), the Ghost
  writes the script and its trigger, shows them, and installs them on
  approval. They are files in the user's tree, with the attributes of
  §6.
- **Recording:** Radharc's `wctl` verbs and the services' verbs, kept
  as a stream while the user records (NeoVectra 18 §5), become a script
  that names objects, not pixels.
- **Judgment inside an automation** is an explicit step, `ghost ask`,
  in the script, run under the same policy and labels as any session.
  A script with no `ghost ask` never wakes a model.
- **An automation's authority is its namespace,** fixed when it is
  installed. It can't grow at run time; a script that needs more is
  changed and approved again.

## 8. Authority and safety

### 8.1 Sessions are confined by their namespace

- A session's namespace comes from a template the user picks or the
  Ghost proposes (`insight`: read-only views of the logs, trace, `/proc`
  and the manual; `settings`: those plus the user's config tree;
  `project NAME`: one directory tree). It can name only what it was
  given (principle 26) and sees its own session at `N/`, never another.
- **No broad grants.** The whole home, another app's data, other
  windows' contents and the screen's pixels are never in a session's
  namespace and can't be asked for (NeoVectra's ADR-0029, taken whole).
  A user who wants the Ghost to see more makes a narrower view for it.

### 8.2 Tools and approval

- **A session's tools are its namespace's verbs,** generated from each
  service's `.schema` (name, typed arguments, what it returns, effect
  class) and the first sentence of its `.help`, which comes from the
  manual. The tool's name is its path and verb. A service with a page
  and a schema is usable by the Ghost with no further work, and the
  manual's check (D86) keeps the three from drifting.
- **Effect classes drive approval.** `read-only` runs. `reversible`
  runs under the session's snapshot. `destructive` asks. A service that
  isn't on the system's trusted list counts as `destructive` in every
  verb.
- **Approval is on the trusted path:** a Radharc prompt no client can
  draw, naming the session, the verb and its arguments, with *once*,
  *this session*, *always for this template*, and *deny*. Standing
  approvals are listed and revocable. Headless, the prompt goes to the
  console that started the session (rc in a rio window, or a cpu
  session).

### 8.3 Audit and undo

- **Every mutating operation** is a record in `N/actions` and a trace
  event, so what the Ghost did is in the same timeline as what the
  system did.
- **Undo** rolls back the files under the session's snapshot in one
  step. It can't reach a verb already applied to a service, traffic
  already sent, or a prompt already sent to a provider; the panel says
  which of a session's actions are past undo.

### 8.4 Labels, egress and injected text

- **Data carries a sensitivity label,** a Taisce attribute on files and
  a label on each source (the debuglog is `internal`, a file under a
  user's `secret` tree is `secret`). The policy maps labels to routes:

```
# /svc/ghost/policy (syntax open, §13); first match wins
label  path=/usr/*/private/**     sensitivity=secret
route  sensitivity=secret          only=local
route  task=insight                prefer=local  then=swarm
route  task=chat                   prefer=local  then=swarm  then=provider:anthropic  max=internal
route  task=code                   prefer=provider:anthropic  max=internal  budget=5USD/day
default                            prefer=local  then=swarm  deny=provider
```

- **The policy is enforced while the context is assembled,** so a secret
  never enters a prompt bound for a provider.
- **Labels follow the data.** A tool's result carries the label of what
  it read, and a session's egress limit is the highest label it has
  seen: a session that read a secret file can't reach a provider.
- **Text the Ghost reads is data, never instructions.** Logs, files,
  web pages and tool results are marked untrusted in the context. A
  session that has read untrusted text asks before any `destructive`
  verb, even one with a standing approval.
- **Lamps.** Radharc's bar shows a lamp while a session is live and
  another when anything has left the machine; `usage` and the session's
  `events` say what and where.

## 9. Surfaces

- **rc:** `ghost why` (the last failure in this window), `ghost ask
  TEXT`, `ghost fix` (show the last insight's action, then run it on
  approval), `ghost` alone for a session in the window. The command is a
  client of `/svc/ghost` and nothing more.
- **Plumbing:** a plumber rule sends selected text of type `error` (an
  exit string, a log line, a `$status`) to the Ghost's port, so
  right-clicking any failure in any rio window asks about it (D85).
- **Radharc:** insights as slips from the bar, a panel for sessions and
  their actions, and the trusted-path prompt (§8.2).
- **The manual:** answers cite pages, and the manual viewer (V5) opens
  them. The Ghost's own pages are `ghost(1)` and `ghost(4)`.
- **Headless boards and the swarm:** through `cpu` (D77), a terminal's
  Ghost can work on a board's tree at `/mnt/term`'s other end, and a
  board's watchers can send their insights to the terminal's Ghost.

## 10. Budgets

Each lands with its check and its milestone (principle 13). Proposed
targets, to be set against hardware when the milestone starts:

| Budget | Target | Check |
|---|---|---|
| `ghost.off.rss` | 0 bytes, no process, when disabled | boot test |
| `ghost.idle.wakeups` | 0 while nothing fails | `idle.wakeups`, with the Ghost on |
| `ghost.signature.latency` | a matched failure's insight within 50 ms | self-test with a planted failure |
| `ghost.ttft.local` | first token of an insight from the board's local model, per board class | bench |
| `ghost.frame.misses` | 0 frame deadlines missed with inference on the compositor's GPU | desktop bench |
| `ghost.pressure.release` | a model's memory back within 100 ms of a pressure level | self-test |
| `ghost.egress.unlabelled` | 0 provider requests carrying data the policy didn't allow | self-test with a labelled secret |

## 11. Where it goes, and what to design in now

Its parts arrive with the milestones that build their dependencies:

| Dependency | Milestone |
|---|---|
| `/net`, factotum, cpu | V3 |
| Taisce on disk: snapshots, attributes, live queries | V4 |
| Radharc: the trusted path, slips, the bar's lamps, rio | V5 |
| The swarm's accelerators over 9gate | V7 |
| `/dev/accel`, `.vxm`, `vxc`, the executor and its backends | V8 |

The proposal is **V10, the Ghost**, after V9, in steps: (a) watchers,
signatures and insights with no model; (b) the CPU runner and local
models; (c) the GPU and NPU runners and placement; (d) evolution and
automation; (e) providers, with the TLS client. Its exit: on the Orange
Pi 6 Plus, a planted driver failure yields a cited insight from a local
model whose fix runs and undoes; an automation authored by the Ghost
runs with the Ghost disabled; and every budget in §10 is green.

Some things are cheap now and expensive later, so the earlier
milestones should design them in:
1. **Effect classes in `.schema`:** idlc gives every verb `read-only`,
   `reversible` or `destructive`, and the manual's check requires it.
2. **Failures stay structured:** exit strings in words (D72), `status`
   nodes that say why they're degraded, and BUGS sections that name the
   symptom a user sees, so signatures have something to match.
3. **An origin attribute in Taisce** (`sys:origin`), written by any
   program on behalf of another, before V4's attributes are frozen.
4. **Non-realtime GPU queues and compute preemption** in Loinnir and the
   GPU drivers (D58, D62), so inference never needs its own path to the
   GPU.
5. **The executor's ops for decoding** considered when V8 designs the
   `.vxm` format, not added after it.

## 12. What we take from NeoVectra, and how it changes

| NeoVectra (`03` §8, `18` §4) | The Ghost | Why |
|---|---|---|
| `aid` serving `/ai` | `ghost` serving `/svc/ghost` | The same service; services live under `/svc` here |
| llama.cpp, whisper.cpp, an ONNX runtime, vendored | `.vxm` on the first-party executor | D4 |
| GGUF and ONNX headers parsed on the device | converted by `vxc` on the host | D4; no third-party format is parsed on the device |
| `keyd`, and `tlsd` attaching the key | factotum, and a provider adapter holding only its key | D75: one keyring |
| `auditfs` between agent and files | the session's `actions`, the trace, Taisce snapshots | One mechanism: the Ghost's tools are already its own calls |
| Tools are the namespace's verbs | taken | |
| Permission, labels, egress at assembly, ADR-0029 | taken | |
| The palette and inline assist | Radharc's, in V5's terms | Radharc replaces winsrv (provenance) |
| Agents run continuously, models answer everything | the model authors; signatures and scripts run without it | Idle costs nothing, and the result is readable |

## 13. Open questions

1. **Decoding on the executor:** TOSA ops (`MATMUL` with quantised
   inputs, composed attention) or `.vxm` extensions for the KV cache and
   int4. Settled with V8's `.vxm` format.
2. **Model weights and D4:** allowed as listed third-party data, as
   firmware is? Needs a decision before any model ships.
3. **A time trigger:** Plan 9's cron as a service, or something the
   launcher already has. One mechanism, chosen once.
4. **The policy's syntax:** plumb(6)'s, ndb's (if `/net/cs` brings
   ndb in V3), or another. The system should have one rules syntax.
5. **The name:** `ghost` for the service and command, or an Irish name
   beside Taisce and Radharc (`taibhse`), with the Ghost as what the user
   calls it.
6. **Where a session's approvals live** across boots, and how a user
   reviews them, once Taisce is on disk.
7. **Remote insights:** does a board run its own watchers and signatures
   and send insights to the terminal, or does the terminal's Ghost watch
   the board's tree over 9gate?
