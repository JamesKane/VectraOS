# ADR-0027: The CIX Sky1's display: `disp-linlon` for the Linlon-D6, the Trilinear DP transmitter on `vx-dp`

Status: proposed, 2026-10-03. The Sky1's vendor display ADR under ADR-0026. The Sky1 (Orange Pi 6 Plus, Radxa Orion O6) is the candidate second arm64 board (00 §5), not tiered; this is built when it is promoted. Found by reading CIX's BSP kernel (`cixtech/cix_opensource__linux`, 2026-08-19), Linux's komeda and zynqmp DP drivers, and AbyssBSD's survey of the Orange Pi 6 Plus (`docs/boards/orangepi-6-plus/README.md` there). Nothing here has been run on the board yet.

## Context

The Sky1 has five display engines and five DisplayPort transmitters. Under ACPI they are `CIXH5010` (each engine), `CIXH502F` (each transmitter), and `CIXH5008`, a reset block for them all. CIX's Linux drivers are not upstream: they are in its BSP kernel, `drivers/gpu/drm/cix/`, 33k lines with HDCP and headers.

**The engine is a Linlon-D6, which is Arm's D71 design.** The DT names it `armchina,linlon-d6`. Mainline Linux's komeda driver (9.0k lines) already drives it with its unchanged D71 code (`komeda_drv.c:110`, `d71/d71_dev.c:631`). CIX's `linlon-dp` (14.4k lines) is komeda renamed (`d71/` became `hw/`): 60% of its lines are komeda's unchanged. It adds:
- the five engines gathered into one DRM device, with IOVAs mirrored across their SMMU domains;
- the handover from UEFI;
- `aclk` scaling with the pixel clock, AXI QoS and cache settings, and sysfs knobs;
- small register changes: wider read-AXI fields, explicit compositor input ids, pixels-per-cycle in the timing controller, and image merge.

The register model is the D71's. A global control unit (GCU) at offset 0, then two pipelines, each with four layers and a writeback layer, a compositor (CU) with two scalers, a splitter and a merger, and an output unit (DOU) with its timing controller (BS). Blocks describe themselves at 0x200 strides and are found by type. Each engine is 0x20000 of registers with one level-triggered interrupt: `0x14010000`, `0x14080000`, `0x140f0000`, `0x14160000`, `0x141d0000`, SPIs 316–324.

**The transmitter is a Xilinx-family DP core.** Its registers from `0x000` to `0x148` (link rate, lanes, training pattern, transmitter enable, the AUX command and reply registers) are at the same offsets as in Linux's `zynqmp_dp.c`, and its MSA block has Xilinx's field order, moved from `0x180` to `0x820` with four sources for MST. CIX's driver copies zynqmp's comments. Trilinear added interrupt cause and mask registers, HDCP, MST, audio and secondary data packets, and PSR. The PHYs are Cadence: Torrent-family USB/DP PHYs, and a separate eDP PHY.

**How they connect.** Engine *n*'s two pipelines feed transmitter *n*'s two stream inputs. On the Orange Pi 6 Plus:

| Output | PHY | Connector |
|---|---|---|
| dp0, dp1 | USB/DP PHY, 2 DP lanes beside USB3 | the two USB-C ports, alt mode through the RTS5453H PD controllers and the type-C mux |
| dp2 | its own eDP PHY | eDP panel |
| dp3 | USB/DP PHY, DP only, 4 lanes | the DP connector |
| dp4 | USB/DP PHY | a Parade PS185 DP-to-HDMI converter, which no driver controls |

AbyssBSD's survey puts its monitor on "DP-4"; whether that is dp3 or dp4 is not yet known.

**What UEFI leaves.** The GOP driver lights one output with pipeline 0, layer 0, and a framebuffer in a 32 MiB region at `0x84800000` that the DT maps one-to-one for all five engines through their SMMU. A SiP call, `0xc200000f` (`GET` is 1, the bit is 17), says whether the output is still the GOP's. CIX's drivers use it and an `enabled_by_gop` property to skip the engine's reset, the PHY's setup and link training, and the stream programming. At the first modeset they compare the requested mode with the live timing registers and the sink's link status, and keep the link when they match. They refuse the handover for sinks that are MST- or PSR-capable.

**What the firmware owns.** Clocks are SCMI: each engine's `aclk`, a pixel clock for each pipeline, and the transmitter's `apb_clk` and video clocks. Under ACPI they are reached through the clock controller's AML (`CIXHA010`, ADR-0024). Power is an ACPI power resource for each engine. The engines' memory reads go through the MMHUB SMMUv3 (`0xb1b0000`), four stream ids each. This is unlike the Q8B, whose display streams are in bypass.

**CIX's code is not to be trusted as written:**
- timer delays spin with no timeout;
- a failed link training is logged and ignored ("train failed but GO ON");
- swing and pre-emphasis for lane 0 are applied to every lane;
- the same-mode check reads the wrong register for the second stream;
- `CIXH5008`'s driver resets display 2 unconditionally under ACPI;
- the eDP panel driver is derived from Linux's `panel-simple`.

## Decision

### 1. The pieces

| Piece | Where | Does | Estimate |
|---|---|---|---|
| `disp-linlon` | a `displayd` back end (ADR-0026) | Drives the Linlon-D6 engines and, through its transmitter stage, the Trilinear DP TX | flip only 0.3–0.5k; one output with modes 2–2.5k, plus the transmitter |
| the Trilinear stage | inside `disp-linlon` (ADR-0026 item 7) | The `vx-dp` operations for this core: AUX, HPD and IRQ_HPD, training patterns, MSA and TU programming, the video clock gates | 1–1.5k, with `vx-dp` doing the protocol |
| the USB/DP PHY | the same | Swing and pre-emphasis for each lane; PLL programming for a rate change | 0.3–0.5k plus tables |
| `/boot/soc/sky1.ndb` | boot image | The engines' and transmitters' bases, the block layout, SMMU stream ids, which output is which connector, the PHY tables (ADR-0026 item 6) | a page |

The reference for the engine is mainline komeda, not CIX's fork; the fork is read only for what Sky1 adds. The reference for the transmitter is CIX's `dptx/` beside Linux's `zynqmp_dp.c`. Neither is copied (ADR-0018 item 5).

### 2. Flip only

1. **Find the live output.** Make the SiP call, then read each engine's GCU mode. The one in `DO0_ACTIVE` is the GOP's. Read its mode back from the DOU's BS registers (active size, horizontal and vertical intervals) and its buffer from layer 0 (`P0_PTR_LOW`/`HIGH` at `+0x100`/`+0x104`, `P0_STRIDE` at `+0x108`, `LAYER_FMT` at `+0xD8`). Do not reset the GCU.
2. **Flip.** Write layer 0's pointer, low word then high, and its stride if it changed; then write `GCU_CONFIG_VALID0` (`+0xD4`) = 1. The registers are shadowed and latch at the next frame.
3. **Completion and vblank.** The GCU's `CVAL0` interrupt (`GLB_IRQ_STATUS` bit 0) says the configuration latched; it carries `APPLY`'s stamp to the `VBLANK` event. The DOU's `PL0` interrupt (bit 13), raised at the programmed line, drives the vblank `Counter`. The layer's end-of-write interrupt is for writeback only and is not used.
4. **Buffers** are linear XRGB8888 with a pitch that is a multiple of 16 bytes, in the GOP's 32 MiB window, which is already mapped for the engine. Three 1080p buffers fit; a 4K buffer (33.2 MB) does not. So flip only is 1080p or below, or a smaller buffer than the mode, scaled. AFBC is later.
5. **Restore** the saved layer registers and set `CONFIG_VALID` again when `displayd` lets go.

The transmitter is not touched: UEFI's link and stream stay as they are. This needs no clock, reset, SCMI or SMMU code.

### 3. One output with hotplug and modes

In the order CIX's driver uses, which is komeda's:
1. Push the transmitter's stream off, and stop the engine in two phases: its shadow registers do not latch once the output is off.
2. Set the pixel clock's rate and `aclk`'s (at least the pixel clock, twice it when scaling down, in steps from 200 to 800 MHz) through `clock` (ADR-0024).
3. Program the layer, the compositor's inputs, the output unit, and the BS timing; set the GCU's mode to `DO0_ACTIVE` and wait for it; set `CONFIG_VALID`.
4. On the transmitter, through `vx-dp`: train the link if the rate, lanes or sink changed, program the MSA and transfer unit, and enable the stream. MVID and NVID are measured by the hardware (asynchronous clock mode) and are not computed.

Rate changes reprogram the PHY's PLL; retraining at the same rate writes only swing and pre-emphasis. A training failure is an error that fails the commit, not a warning.

**Scan-out through the SMMU.** Beyond the GOP window, scan-out buffers are mapped in each engine's SMMU domain by the kernel (01 §7.1), as any device's DMA is. `disp-linlon` is not `trusted`: unlike the Q8B's display, its device cannot read memory that is not mapped for it.

### 4. Order of outputs

The first output is the one UEFI lights. The first to take modes is a DP-only one, dp3 or dp4 behind the PS185, so that hotplug does not need the PD controller and type-C mux. USB-C alt mode on dp0 and dp1 (perhaps 1k lines for the RTS5453H and the mux) and the eDP panel on dp2 come after.

### 5. Not in scope

MST, DSC, PSR, audio, HDCP, writeback, colour management, AFBC, both pipelines on one engine, and the five engines as one device. Each is added when a need arrives, under its own amendment.

## Consequences

- The Sky1's display needs no Linux code: perhaps 4–5k first-party lines for one output with modes, against CIX's 33k. The DP protocol in it is `vx-dp`'s, shared with `disp-msm`.
- `disp-linlon` is the first back end whose scan-out goes through an IOMMU. That tests ADR-0026's buffer constraints from the side opposite the Q8B's.
- Mode changes depend on ADR-0024's AML clock methods. Flip only does not, so the Sky1 can show an accelerated desktop before its clock work is done.
- A later Linlon part (the D8 is in CIX's product list) is a record, if its blocks are the D6's.

## Open questions

Each needs the board: an `acpidump` and register reads, both read only.

1. **Does the IORT map the GOP window** at `0x84800000` for the engines, as the DT does? It should be a reserved memory range (RMR) node; if it is not, flip only needs the kernel to map the window first.
2. **What `CIXH5010`'s `_DSD` holds**: `enabled_by_gop`, the pipeline children and their clock names.
3. **Which engine UEFI uses** on the Orange Pi 6 Plus, and whether "DP-4" is dp3 or dp4.
4. **Whether the PS185 needs anything from us.** Its power-down GPIO is in the DT, but no driver uses it, so firmware or straps leave it on.

## References

- CIX BSP kernel, `github.com/cixtech/cix_opensource__linux`: `drivers/gpu/drm/cix/` (`linlon-dp/`, `dptx/`, `cix_display.c`), `drivers/phy/cix/`, `arch/arm64/boot/dts/cix/sky1.dtsi`, `sky1-orangepi-6-plus.dts`
- Linux: `drivers/gpu/drm/arm/display/komeda/`, `drivers/gpu/drm/xlnx/zynqmp_dp.c`, `drivers/phy/cadence/phy-cadence-torrent.c`
- AbyssBSD: `docs/boards/orangepi-6-plus/README.md`
- ADR-0018, ADR-0024, ADR-0026
