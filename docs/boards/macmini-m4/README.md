# Mac mini (M4, base configuration)

A stretch goal (owner, 2026-10-16), and a research track: bring VectraOS
up on a base M4 Mac mini, from Asahi Linux's published facts where they
exist and by reverse engineering where they don't. Nothing here is
scheduled, and the machine breaks two of our standing rules (ACPI-only
boot and our own page size), so any bring-up starts with a decision.

Facts are marked with their source. Most hardware facts below come from
Asahi's M1 and M2 work and are **(memory)** for the M4 until checked
against Asahi's documentation, m1n1 or the machine.

| Source | Commit or date | What |
|---|---|---|
| Linux (`../linux`) | `24a19b953e2a` (2026-10-11) | `arch/arm64/boot/dts/apple/`: device trees up to the M3 (`t8122`, `t603x`), none for the M4; `drivers/irqchip/irq-apple-aic.c`, `drivers/iommu/apple-dart.c` |
| [Botmonster, "Asahi Linux daily drives M1 and M2, but not yet the M4"](https://botmonster.com/self-hosting/asahi-linux-apple-m4-daily-linux/) | 2026 | Asahi's M4 status |
| [AppleInsider](https://appleinsider.com/articles/25/04/08/asahi-linux-m4-support-hits-a-roadblock-because-of-apple-silicon-changes), [heise](https://www.heise.de/en/news/Asahi-Linux-Problems-with-the-port-for-Apple-s-M4-10346962.html), [Linux Magazine](https://www.linux-magazine.com/Online/News/Asahi-Linux-Runs-into-Issues-with-M4-Support) | 2025-04 | the SPTM roadblock |
| [Asahi's M4 feature page](https://asahilinux.org/docs/platform/feature-support/m4/) | read 2026-10-16 (no date on the page) | per-feature status for M4 machines |
| [omarchy-silicon/omarchy-mac](https://github.com/omarchy-silicon/omarchy-mac), [omarchy-m-testing PR #47](https://github.com/maralcbr/omarchy-m-testing/pull/47) | read 2026-10-16 | the Omarchy downstreams' M4 claims |

## Where Asahi is

- **Early bring-up, in Asahi's own kernel.** Asahi's M4 page, read
  2026-10-16, lists the Mac mini (2024) with the M4 (`T8132`): its
  devicetree and the **AICv3** interrupt controller are in `linux-asahi`
  7.4, which the page's legend calls stable and available there; NVMe is
  work in progress; there is **no installer**; cpufreq, cpuidle, USB,
  Ethernet, DCP, HDMI and the GPU are TBA. It says nothing about m1n1 or
  SPTM. A 2026 article had every M4 line TBA (Botmonster), so this page
  is newer. M1 and M2 are daily drivers; the M3 has audio, cpufreq and an
  installer in progress (Botmonster, 2026). Mainline Linux has M3 device
  trees but none for the M4 (`../linux`).
- **Omarchy's "experimental M4 support"** (heard 2026-10-16) isn't borne
  out by its downstreams: omarchy-mac lists the M4 among its development
  targets but says no Apple Silicon board is supported or qualified and
  ships no installer; omarchy-m-testing records the M4 (`t8132`), M4 Pro
  (`t6040`) and M4 Max (`t6041`) as unknown or unsupported, after a
  refresh from Asahi's docs (`0d1f891`, 2026-10-04). Whatever runs there
  runs on Asahi's kernel, so Asahi's page is the source to follow.
- **The roadblock is SPTM.** On the M4, Apple's Secure Page Table Monitor
  runs in GL2 when a boot object is configured, and macOS's kernel can't
  run under m1n1's hypervisor, which is how Asahi traces the hardware.
  Asahi suggested hijacking XNU's exception handlers and page-table code
  instead (AppleInsider, heise, 2025-04). Whether SPTM also constrains a
  third-party kernel booted with permissive security is not known here
  (memory).

So "use Asahi's facts" covers what carries over from the M1–M3 and what
Asahi publishes for the M4 later; the rest is reverse engineering without
Asahi's main tool.

## What breaks our rules

- **No UEFI and no ACPI.** Apple's iBoot boots the machine and describes
  it with Apple's own device tree (the ADT). Asahi's chain is iBoot, then
  m1n1, then U-Boot for UEFI, then Linux with a devicetree (memory). The
  kernel is ACPI-only (architecture §2), as the RV2 (D51) and the Orange
  Pi 5 Plus already show. Unlike the RK3588, no ACPI firmware exists for
  Apple Silicon. A bring-up needs a decision: a loader stage that reads
  the ADT (or m1n1's devicetree) and fills our handoff, or ACPI tables we
  write and ship.
- **16 KiB pages.** croi's pages are 4 KiB (`KernelLayout.pageSize`).
  Apple's DART IOMMUs map 16 KiB pages only, which was Asahi's biggest
  porting cost (memory). The CPU itself supports a 4 KiB granule (memory),
  so the question is the IOMMUs and anything that shares page tables with
  them.

## How it differs from our other arm64 targets (memory, from M1/M2)

- **Interrupts:** Apple's AIC, not a GIC (AICv3 on the M4, Asahi's page);
  timers arrive as FIQs. A new interrupt controller for croi.
- **CPU start:** no PSCI; secondary cores start through Apple's own
  mechanism (the power manager, `RVBAR`). New SMP bring-up.
- **IOMMUs:** Apple DARTs, not SMMUv3. A new IOMMU kind.
- **Devices behind coprocessors:** storage (ANS, NVMe-like), display
  (DCP), audio and more run Apple firmware on RTKit coprocessors, loaded
  before the OS. That firmware is part of the hardware (as for the Q8B's
  blobs), but each coprocessor's mailbox protocol has to be learned.
- **GPU:** Apple's own (AGX), with no public ISA; Asahi's reverse-
  engineered driver doesn't cover the M4 yet. Against D62's floor:
  unknown.
- **Console:** no UART on a connector; Asahi gets serial through the
  USB-C port with vendor messages, driven from another Mac (memory).
- **Network:** the Mac mini has wired Ethernet (memory: on PCIe), the V3
  link's path, part to identify.

## CPU

- 10 cores, 4 performance and 6 efficiency, in the base configuration
  (memory). Armv9-class (memory), so above D53's baseline; to check its
  ID registers on the machine.

## What would come first

1. Asahi's M4 progress, followed until m1n1 runs on the M4 or the SPTM
   question is answered for a non-Apple kernel.
2. The firmware decision above (ADT-reading loader stage or our own ACPI
   tables), argued against D51's and the Orange Pi 5 Plus's cases.
3. The 16 KiB question: whether croi takes a 16 KiB page size on arm64,
   or keeps 4 KiB with the DARTs mapping in 16 KiB units.
4. Then the AIC, CPU start, a DART driver and the USB-C serial path.
