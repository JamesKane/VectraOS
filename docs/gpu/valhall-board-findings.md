# Valhall board findings: where a flow-field wait takes effect

Board: the G720 on the Orange Pi 6 Plus, 2026-11-20, gpu-test's probes
(`drivers/gpu/tests/native/Probes.swift`; the shaders are
`graphics/compiler/valhall/backend/tests/ProbeShaderTests.swift`). This is a
question and its evidence for the spec writers of `specs/valhall`; it says
nothing about any other source.

## The question

Specs 10.9.1, 10.9.2, 13.3.1 and 15 said a wait in an instruction's flow field
is satisfied before that instruction issues, so the instruction that reads a
message's result can carry the wait itself. Does the hardware do that?

## What the board did

Setup in every probe: `LOAD.i32.slot0 @r2` (x[i]) and `LOAD.i32.slot1 @r3`
(y[i]) issued, then the shapes below; the result is stored to y and compared
with the CPU's value.

| Shape after the loads | Result |
|---|---|
| `NOP.wait0` then `FADD.f32 r0, r2^, 0x0` (q1) | correct x |
| `FADD.f32.wait0 r0, r2^, 0x0` (q4: the reading instruction carries the wait) | garbage (`0xfff00000`) |
| `NOP.wait2` then the read (q2); `FADD.f32.wait2` (q3) | garbage: slot 2 is not the load's slot, so the bit order is as specified |
| compiled saxpy: `FMA.f32.wait0 r0, u2.w0, r2^, ...` then `FADD.f32.wait1 r0, r0^, r3^` | garbage; the y operand was right only by timing |
| compiled reduction (branches, barriers) with the waits on the readers | sums 0 |
| compiled globalID (no loads) | correct |

## The observed rule

A wait in an instruction's flow field takes effect after that instruction, as
`reconverge`, `discard` and `end` do. An instruction is protected only by a
wait carried by an earlier instruction; the wait on its own flow field never
protects its own reads. The specs' note that a stand-alone `NOP` carrying a
wait is merged into the preceding instruction fits this reading.

The compiler now places each wait on the instruction before the consumer (or a
`NOP`), the validator rejects a read covered only by its own wait, and the
interpreter faults on one.

## Open: not yet run on the board

- A message carrying a wait on its own slot (`LOAD.slot0.wait0` then the
  reader) is read by the spec as waiting for that message; probe `q5` runs it.
- The probe `r-old-listing` is the compiler's earlier saxpy; the board stored
  garbage for it, and the probe prints it as an expected failure.
