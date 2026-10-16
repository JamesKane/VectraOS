# D69. The first board is the Orange Pi 6 Plus; the Q8B moves to V8 (2026-10-16, decided; replaces D5's choice)

D5 chose the Radxa Dragon Q8B as the first hardware because AbyssBSD
ran it under ACPI with its NPU working. Since then the corpus has grown
to eight machines (`docs/hardware/support.tsv`, `docs/boards/`), and the
owner asked which first board leaves the largest base for the others.
The Orange Pi 6 Plus (CIX Sky1) is available for VectraOS, not only for
AbyssBSD (owner, 2026-10-16).

**What each first board would build, and who reuses it:**

| First board | Work it forces | Reused by |
|---|---|---|
| Q8B | GENI UART, TC956x Ethernet with its DMA offset, Windows PEP power and `qcom-gcc` clocks, an SMMU policed by Qualcomm's hypervisor, EPSS and TSENS | GICv3 with ITS (Sky1, RK3588) and NVMe; the rest is Qualcomm's alone |
| Orange Pi 6 Plus | an RTL8126 driver; GICv3 with ITS, SMMUv3 and PCIe on hardware; ACPI power (power resources, SCMI clocks, `_CPC`, `_LPI`) through the user-space AML interpreter; three core tiers (D68); NVMe | the Realtek RTL8125/8126 family is the V3 link's NIC on the AMD tower, brimstone and the Orange Pi 5 Plus too; GICv3 with ITS on the RK3588 and the Q8B; the ACPI power path on every ACPI machine; the Radxa Orion O6 is the same SoC |
| AMD tower (`pc-7900x`) | RTL8125; a GOP text console; AMD-Vi and the LAPIC one-shot timer on hardware; RDNA 2 | the Realtek family as above; the GOP console on every machine without a serial port (brimstone, the Mac Pro); AMD-Vi and the timer on brimstone; RDNA 2 is D62's desktop floor |
| i7-12700KF | `igc`; COM1 if wired; VT-d; HFI | VT-d on the Mac Pro; its RX 6750 XT is `gpu-amd`'s first device; `igc` serves no other machine |

**The decision:**
- **V4's board is the Orange Pi 6 Plus.** Its firmware is what croi
  expects (SystemReady ACPI, EL2 ours, no vendor hypervisor), its
  console is already in croi (PL011 through DBG2, `boot-dbg2-console`),
  and the driver its V3 link needs serves four machines on two arches.
  It is arm64 and edge-class, the project's main target, and D53's
  baseline was already checked against it. The board notebook's own
  comparison found it "the shorter path to V3's exit on hardware".
- **The AMD tower follows as amd64's first board** (a new V4c, after the
  RV2's V4b), on the same Realtek driver. It brings the GOP text
  console, AMD-Vi and RDNA 2 to hardware, and it is free when the owner
  frees it, unlike brimstone (the development host) or the 12700KF
  (shared with AbyssBSD).
- **The Q8B moves to V8,** whose CDSP and Adreno work needs it: its
  bring-up becomes V8's first item. Its value was always the CDSP and the
  Adreno; its platform work (GENI, TC956x, PEP, the hypervisor's SMMU)
  serves no other board, so it no longer leads.
- **D5's other line stands:** the RK3588 and the Hailo-8 follow once the
  accelerator protocol exists.

**What follows in the roadmap and the list** (edits made with this
entry's acceptance, not before):
- V4 becomes the Orange Pi 6 Plus. Its known needs, from the notebook:
  a board rule for the watchdog's refresh (or `croi.watchdog=off`
  until board rules exist, handoff v4), a board rule to take over the
  firmware-enabled SMMUs with the IORT's RMRs (or devices left as
  firmware set them), the RTL8126 in the net class, NVMe, and the GPU's
  power-up order exactly as AbyssBSD found it. Its first read on the
  board settles D53's crypto question.
- V3's "GENI console, written ahead" moves to V8 with the Q8B.
- V4b (the RV2) follows the Orange Pi 6 Plus on the same V3 link; D51's
  "after the Q8B" reads as after V4.
- V4c is new: the AMD tower.
- The board named in V6's, V7's and V9's exits becomes the Orange Pi 6
  Plus. V6's native display (D62's board track puts Adreno first) and
  V8's accelerators are reordered in their own entries; until then V6
  runs on the GOP framebuffer on the board.
- Open question 6 (a hardware watchdog on the Q8B) becomes the Sky1's
  SBSA watchdog, which V4 needs anyway.
- `support.tsv`: `cix-sky1` becomes planned with milestone V4 and gets
  its component rows; `pc-7900x` becomes planned with V4c; `radxa-q8b`'s
  rows keep their level with milestone V8 (D66).
- **Unchanged:** D16 (milestones in order), D53's baseline (both boards
  meet it), D68 (its kernel half still lands before V4, which now has
  three core tiers instead of two).
