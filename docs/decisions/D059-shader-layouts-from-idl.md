# D59. Shader-visible layouts come from the IDL (2026-10-16, proposed)

Metal's shared headers make a CPU struct and a GPU struct one
declaration. todhchai matches them by hand: GLSL beside Swift, with
tests pinning sizes (Radharc's 48-byte `Quad`). The project already has
one mechanism that defines layouts, the IDL and its wire format (D6,
principle 7).
- **idlc also emits shader declarations:** std430 structs in GLSL (Slang
  if the shader language changes; both are host compilers under D4) for
  the structs a library marks shader-visible, beside the Swift and C it
  already writes. Root structs, the compositor's `Quad` and the TOSA
  tensor descriptors (architecture §8) are each declared once.
- **Shader-visible structs are plain data:** scalars, SIMD vectors,
  fixed arrays and GPU addresses (`UInt64`); no vectors, optionals,
  strings, unions or handles. idlc refuses the rest, and applies std430's
  alignment, so Swift's layout and the shader's agree by construction.
- **This replaces** the hand-pinned layout tests. A test checks that the
  emitted GLSL is current, as idlc's other outputs are.
