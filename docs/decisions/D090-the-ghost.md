# D90. The Ghost: an opt-in, local-first agent built from the namespace's own mechanisms (2026-10-17, proposed)

The owner's direction (2026-10-17): an opt-in agentic system on the
machine's heterogeneous compute, which turns system errors into
actionable insights, evolves the system to its user's needs and
automates tasks, using cloud frontier models when the user wishes, with
local first as the rule. `docs/ghost.md` is its vision and design.

- **Opt-in, and absent when off:** no `/svc/ghost`, no process, no model
  in memory, and nothing in the system depends on it.
- **No new mechanism.** Sessions are processes confined by a namespace
  template; their tools are the namespace's verbs from `.schema` and
  `.help`; events arrive on rings and the plumber's ports; keys are
  factotum's; undo is Taisce's snapshots; audit is the session's
  `actions` and the trace; automations are rc scripts with triggers.
- **Models are `.vxm` artifacts on the first-party executor** (D4),
  converted from third-party formats by `vxc` on the host. NeoVectra's
  vendored llama.cpp, whisper.cpp and ONNX runtime are not carried.
- **Local, then the user's swarm, then a provider**, by a policy
  enforced while a prompt is assembled, with sensitivity labels that
  follow the data and a lamp when anything leaves.
- **The model authors; the result doesn't need it.** Fixes are rc lines
  or plans of verbs, automations are scripts, and confirmed insights
  become readable signatures, all previewed before they run.
- **Proposed placement:** V10, after V9, since it needs V3's `/net` and
  factotum, V4's Taisce, V5's trusted path, V7's swarm and V8's
  accelerators. Earlier milestones design in effect classes in
  `.schema`, a Taisce origin attribute, non-realtime GPU queues, and the
  executor's decoding ops (`docs/ghost.md` §11).

Open, in `docs/ghost.md` §13: decoding ops in `.vxm`, model weights
under D4, a time trigger, the policy's syntax, and the name.

Not chosen: NeoVectra's `aid` as it was (third-party runtimes on the
device, D4; `auditfs` as a second layer over files); an agent that is
always on (it would cost every machine that doesn't want it); a model
that runs the user's automations (they would wake a model for work a
script does, and be harder to read and debug).
