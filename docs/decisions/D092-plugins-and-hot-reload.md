# D92. Hot reload is a program's own code in its own process; a plug-in is a process; both compiled, in any language (2026-10-17, proposed)

The owner's direction (2026-10-17): todhchai's and NeoVectra's goals for
hot-reloading libraries and plug-in infrastructure carry into VectraOS,
and the user compiles Swift, or whatever language they prefer, for them
instead of using something like Lua. `docs/plugins.md` is the design.

- **Hot reload** (todhchai's `CodeModule`, NeoVectra's `app.so` host):
  a program's own code image, loaded by `system/ld` as a fresh copy at a
  new address and never unmapped, over a state block at a fixed address
  (`CROI_VM_SPECIFIC`) whose type is `BitwiseCopyable` and whose layout
  the image declares. Release builds link the image in.
- **A plug-in is a process** (todhchai principle 27; NeoVectra 01 §6.6):
  no foreign code runs in another program's process. A host's plug-in
  points are IDL interfaces in its manual page; a plug-in has a sealed
  namespace, shares data through lent and sealed VMOs, uses rings for
  bulk, and is replaced live by start, quiesce and handoff.
- **Any language that emits our ELF or Wasm:** Embedded and full Swift,
  C and C++ through the `*-vectraos` toolchain, other LLVM front ends
  with a target, and anything with a Wasm target through `wasmd`, whose
  plug-ins are processes like any other. rc is the scripting language;
  no host embeds an interpreter.
- **Compilers stay on a host** (D4, D47): `vx` builds, and the image
  reaches the device over cpu or 9gate. Compiling on the device is open.
- **Proposed placement:** `system/ld` gains fresh-copy images (and TLS
  in loaded objects) before V5; the host template, `@HotState` and the
  first plug-in point (Radharc's layout policies) in V5 with the SDK;
  record and replay, the hot-reload game exit and Wasm plug-ins in V9.

Not chosen: in-process plug-ins (a host would share every plug-in's
crashes, allocator, ABI and toolchain); an embedded scripting language
(NeoVectra's Lua, third-party under D4, and a second way to program the
system beside rc and compiled code); unmapping old images (a Swift
library mustn't be unloaded, and pointers into them would dangle).
