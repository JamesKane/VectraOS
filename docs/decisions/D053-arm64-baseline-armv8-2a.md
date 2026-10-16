# D53. arm64's baseline: the Q8B's Armv8.2-A, checked against the CIX Sky1 (2026-10-16, decided)

D51 and D52 set rv64's and amd64's baselines. The owner's call for
arm64: the Q8B's level (D5), cross-referenced with the CIX Sky1 (the
Orange Pi 6 Plus and Radxa Orion O6, in croi's board review and
AbyssBSD's `docs/boards/orangepi-6-plus/`).
- **The two boards.** The Q8B's Cortex-X1C and A78C report, under Linux
  (AbyssBSD's `radxa-dragon-q8b/dumps/linux/cpuinfo.txt`): fp, asimd,
  aes, pmull, sha1, sha2, crc32, atomics, fphp, asimdhp, asimdrdm, lrcpc,
  dcpop, asimddp, uscat, ilrcpc, flagm, paca and pacg. No BTI, no SVE.
  The Sky1's Cortex-A720 and A520 are Armv9.2-A (Linux's
  `arch/arm64/boot/dts/cix/sky1.dtsi`; the bundled clang's `-mcpu`
  definitions add SVE2, BF16, I8MM, BTI and MTE), so they cover
  everything above except the crypto instructions, which are a licensee
  option on those cores. No Sky1 `cpuinfo` is in any tree yet.
- **The baseline is `-march=armv8.2-a+fp16+dotprod+rcpc`:** LSE atomics,
  FP16 arithmetic, the dot product and LDAPR. Both boards have each of
  them. RCpc is Armv8.3's, kept because both have it and Swift's acquire
  loads use it.
- **Run-time options:** AES, PMULL and SHA (until a Sky1 dump shows
  them; then a new entry may add them), the Armv8.4 extras the Q8B also
  has (LRCPC2, FlagM, LSE2), SVE and SVE2, BF16, I8MM and MTE (Sky1
  only), and BTI, whose landing pads stay in user code
  (`-mbranch-protection=bti`, hint space) and are enforced where the CPU
  has it, as now (hardening.md, K14r). PAuth is on both; the kernel's
  pac-ret stays in hint space.
- **The kernel is unchanged:** `-mgeneral-regs-only`, no FP or SIMD. The
  loader refuses a CPU without the baseline's ID register fields
  (`ID_AA64ISAR0_EL1` atomics, dot product, `ID_AA64PFR0_EL1` FP and
  AdvSIMD half precision, `ID_AA64ISAR1_EL1` LRCPC) and says which is
  missing.
- **QEMU:** `-cpu cortex-a76` (Armv8.2 with FP16, the dot product and
  RCpc) becomes the floor run beside `-cpu max`.
- **What follows in code,** each its own change: `cmake/arch/arm64.cmake`'s
  user flags, the loader's check, and the floor run in `tools/qemu.sh` and
  `vx ci`.
- **To do:** a Sky1 `cpuinfo` (or its ID registers) in AbyssBSD's board
  notes, which settles the crypto question.
