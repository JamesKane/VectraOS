# D52. amd64's baseline: the 2013 Mac Pro's (Ivy Bridge) (2026-10-16, decided)

D51 set rv64's baseline; amd64 had none beyond x86-64 with SSE2
(`CROI_USER_CFLAGS` is empty). The owner's call: the SIMD level of the
2013 Mac Pro or newer. Its Xeon E5 v2 is Ivy Bridge-EP, so the baseline
is clang's `-march=ivybridge`: SSE4.2, POPCNT, AVX, F16C, PCLMUL, RDRAND,
FSGSBASE and XSAVEOPT (from the bundled clang's predefined macros).
Every later Mac Pro, and any x86 since Haswell, is a superset.
- **AVX is the SIMD floor, not AVX2.** Ivy Bridge has 256-bit float AVX
  but no AVX2, FMA, BMI1/2, LZCNT or MOVBE, so `x86-64-v3` is out. Those,
  AES-NI (absent from clang's `ivybridge` though every Mac Pro has it) and
  AVX-512 stay run-time options.
- **User code** builds with `-march=ivybridge` and may assume AVX. Code
  that checks for AVX at run time today stops checking.
- **The kernel is unchanged:** no SIMD or FP state (`-mgeneral-regs-only`,
  `-mno-sse`). It already saves user AVX state with XSAVEOPT (user.md,
  K6d). The loader refuses a CPU without the baseline's CPUID bits and
  says which is missing.
- **QEMU:** `-cpu IvyBridge` becomes the floor run beside `-cpu max`
  (both have AVX under TCG; whether TCG covers every bit of the model is
  checked when the run is added). The bench's `-cpu host` is unaffected.
- **What follows in code,** each its own change: `cmake/arch/amd64.cmake`'s
  user flags, the loader's check, the floor run in `tools/qemu.sh` and
  `vx ci`, and user.md's "AVX is a run-time option".
- **arm64 is not covered** by this entry; its baseline is still open.
