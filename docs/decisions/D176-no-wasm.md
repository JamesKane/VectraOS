# D176. No Wasm: there is no `wasmd`, no WASI and no Wasm plug-ins; V9 is games (2026-11-21, decided; reverses D7)

The owner's direction (2026-11-21): take Wasm out of scope entirely.

- **Reverses D7.** There is no first-party Wasm runtime (`wasmd`), no
  interpreter, no AOT through `vxc`, and no WASI mapped onto the Node
  protocol and rings.
- **What the others said about Wasm no longer applies:**
  - D4: the Wasm runtime is no longer among the first-party pieces on
    the device;
  - D15: V9 is games, not "Wasm and games";
  - D80: there is no WASI guest ABI under its rule; POSIX through tier
    1 is the only foreign ABI it governs (with the foreign personalities
    of `docs/foreign.md`, which take the same rule);
  - D92: plug-ins and hot-reloaded images are ELF only, built by our
    toolchains or any LLVM front end with a `*-vectraos` target; "anything
    with a Wasm target" is gone;
  - D95's exclusion of Wasm from the network stands, and now covers every
    Wasm.
- **What goes with it:** architecture §9, `wasmd` in the target layout,
  the WASI-import budget in `docs/performance.md`, V9's `wasmd`, WASI,
  Wasm plug-in items and its exit's Wasm Bevy or Godot sample, and the
  vision's row and line about Wasm games.
- **Portability across arches** was Wasm's argument for plug-ins. It is
  met as everything else is: one source tree built for amd64, arm64 and
  rv64.

Not touched: the toolchain patches' WASI branches (`tools/toolchain`).
They are upstream LLVM, Swift and Foundation code that VectraOS joins
where both lack something, not a Wasm target of ours.
