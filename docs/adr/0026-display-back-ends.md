# ADR-0026: Display back ends: a narrow engine protocol under `displayd`, firmware adoption first, one DisplayPort library, block layouts as data

Status: proposed, 2026-10-03. It makes ADR-0018 item 7 concrete: what a vendor's `displayd` back end is, and what it shares with the others. Found by surveying the Q8B's display (ADR-0019 §6), the CIX Sky1's (ADR-0027), Fuchsia's display stack, Linux's DRM and 9front. It is built with the first hardware back end, `disp-msm` in M9; `simplefb` and virtio-gpu in M7 and M8 are written against it from the start.

## Context

03 §3 makes `displayd` a user-space KMS. Each output has CRTC and plane state, commits are atomic, and the display IRQ signals a per-output vblank `Counter`. ADR-0018 item 7 gives each vendor a back end, flip only at first. Neither says where the line between `displayd` and a back end runs, or what two back ends share. Two are now in view, and their hardware has the same shape:

| | Q8B (SC8280XP) | Sky1 |
|---|---|---|
| Display engine | Qualcomm DPU (MDP 8.0) | Arm China Linlon-D6 (Arm's D71 design) |
| Transmitter | Qualcomm DP controller and eDP/DP PHY | Trilinear DP TX (a Xilinx-family core) and Cadence PHYs |
| Linux code for it | msm `disp/dpu1` 37.6k lines (10.9k of it the catalog), `dp/` 9.2k, `phy-qcom-edp` 1.5k | CIX BSP: `linlon-dp` 14.4k, `dptx` 12k, `phy/cix` 2k |
| Firmware leaves | one pipe running at 1080p60, HBR3 ×4 | one pipe running, link trained, and a "GOP owned it" bit behind an SMC |

Each Linux driver carries its own DisplayPort code: AUX transfers, DPCD parsing, a link-training loop, and the timing math. DRM's `drm_dp_helper.c` (4.9k lines) has the spec's definitions and predicates but no training state machine. Twelve drivers call `drm_dp_clock_recovery_ok` (msm, i915, amdgpu, radeon, mediatek, tegra, hibmc, zynqmp, analogix, cadence, Synopsys and ITE), and each has a training loop of its own. Linux's size comes from three things: support for every generation, helper layers stacked on vtables (`drm_bridge_funcs` has 46 operations, and about 100 drivers implement it), and that per-vendor DisplayPort code. Its central idea, a check that can fail split from a commit that cannot, is sound.

Others draw the line differently:

- **Fuchsia** splits a display coordinator (7.9k lines: clients, layers, fences, vsync queues, EDID parsing) from engine drivers that know only hardware. Its `fuchsia.hardware.display.engine` protocol says it is "designed to minimize the complexity … of implementing a display engine driver, possibly at the cost of increased complexity in the Display Coordinator." An engine has about 15 operations: import and release images, `CheckConfiguration`, `SubmitConfiguration` with a stamp that strictly increases, power, and events for a display added (with its raw EDID bytes), a display removed, and vsync with the stamp now on screen. A configuration is a mode and a list of layers. There are no CRTC, encoder or connector objects. A configuration that passed the check stays valid when only its image ids change, so a flip needs no new check. Its transmitters are libraries: `designware-hdmi` (2.1k lines) is the Synopsys IP, apart from the Amlogic engine. Its Amlogic and Intel engines adopt the boot firmware's pipeline. It has no shared DisplayPort library: Intel's AUX and training live in the Intel driver.
- **9front** sets modes in user space. `aux/vga`'s `igfx.c` (2.5k lines) does a full Intel modeset, DP link training included. The kernel side, `devvga.c` and `vga.c`, is 0.7k lines and offers only `/dev/vgactl` and the framebuffer. Hardware and monitor variation is a text database, `/lib/vgadb`, not code.
- **Linux's msm** keeps each SoC's DPU layout in a catalog of C tables: `dpu_8_0_sc8280xp.h` is 427 lines naming every SSPP, LM, CTL and INTF with its base, length and IRQ bit. The mode-setting code is shared, and a new SoC is a table.
- **Genode** and **Managarm** run displays through Linux's DRM, under `lx_emul` or behind DRM's uAPI. Both are compatibility layers, which rule 13 rules out.

## Decision

1. **`displayd` owns policy, back ends own registers.** `displayd` keeps everything that is the same on every machine:
   - the clients, and the per-output CRTC and plane state of 03 §3;
   - atomic all-or-nothing commits;
   - EDID parsing, mode lists, and the `/wsys/outputs/NAME/{info,ctl}` files;
   - the vblank `Counter`s.
   A back end knows its hardware and nothing else. It never parses EDID, and it keeps no client state.
2. **The engine protocol** is a native message protocol between `displayd` and a back end, specified in `docs/proto/display.md` with `simplefb`, its first user. Its shape is Fuchsia's:
   - `INFO`: the number of outputs and layers, the pixel formats and modifiers for each layer, and the buffer constraints (contiguous, an address limit, alignment, cache policy);
   - `IMPORT` and `RELEASE` of a `vx-buffer` (01 §6.1) as a scan-out image;
   - `CHECK(cfg)`: yes, or no with the first layer or setting that failed. A `cfg` is, for each output, a mode and a list of layers: an image or a solid colour, source and destination rectangles, alpha, and rotation;
   - `APPLY(cfg, stamp)`: never fails for a configuration that passed `CHECK`. Stamps strictly increase. A configuration that differs from a checked one only in its images is applied without a new `CHECK`, so a flip is one message;
   - `POWER(output, on|off)`;
   - events: `ADDED(output, raw EDID, preferred mode, the mode it is showing)`, `REMOVED(output)`, and `VBLANK(output, time, stamp)`, which says which stamp is on screen. `displayd` signals the output's `Counter` from it.
   There are no CRTC, encoder, connector or bridge objects in it. Those are `displayd`'s model of a configuration, not things a back end must reproduce.
3. **Adopting the firmware's pipeline is every back end's first state.** At start a back end reads the pipeline the firmware left running back into a configuration: the mode, the layer, the buffer and its format. It reports it with `ADDED`, the mode marked as the firmware's. Flips change only the scan-out address. When `displayd` lets go, or the back end exits, the saved registers are written back and the firmware's framebuffer shows again. `/wsys/outputs/NAME/info` shows `adopted=firmware` until a modeset replaces it. A back end that finds the display off at start reports no output in this state; lighting it is the full back end's job. This is ADR-0018 item 7's flip only, as `msmfb` and CIX's own driver both do it, and Fuchsia's Amlogic and Intel engines.
4. **One DisplayPort library, `lib/vx-dp`, first-party.** Every DP back end uses it. It holds what the DisplayPort specification defines, not what a controller defines:
   - AUX transactions with the spec's retry rules, over three operations from the back end (`xfer`, `reset`, `hpd`);
   - DPCD definitions and capability parsing; sink count and IRQ_HPD handling;
   - the link-training state machine (clock recovery, then equalization with TPS2, 3 or 4, then rate and lane fallback), over operations from the back end to set the pattern, set swing and pre-emphasis for each lane, and set the rate and lanes;
   - the timing math: MSA fields, transfer unit sizes, and M/N for controllers that need them.
   Swing and pre-emphasis tables are the PHY's, and stay with the back end or its record. MST, DSC, PSR and HDCP are not in version 1; each is added when a back end needs it.
5. **One EDID library, `lib/vx-edid`,** used by `displayd` alone (item 1). It parses the base block, CTA-861 and DisplayID into modes. The standard timings (DMT, CTA VICs) are tables of data, generated once from the specifications.
6. **Block layouts are data.** A back end's register layout for a SoC (the blocks, their bases, counts, IRQ bits, and which block feeds which) is a section of the SoC record (`/boot/soc/*.ndb`, ADR-0019 §7), not code. It is checked against a schema when the back end loads, and a record that fails the schema stops it. One back end then covers a family: `disp-msm` covers DPU generations whose registers match, with a new record each. This is msm's catalog written as 9front's `vgadb`.
7. **A transmitter is a stage, not a framework.** Between the engine and the connector, a back end may have a short fixed chain of transmitter stages: the DP controller with its PHY, a bridge chip, a panel. Each is a plain struct of at most `enable`, `disable`, `mode_valid`, `hpd` and a pointer to its `vx-dp` link. The chain is fixed when the back end starts. There is no component framework and no helper vtable on top of the struct. A transmitter IP that appears behind more than one engine becomes a library of its own, as Fuchsia did with `designware-hdmi`.
8. **Back ends follow the vendor ADR's band**, as GPU drivers do (ADR-0018 item 3). Each vendor ADR says which outputs its back end drives, which it does not, and its line count against Linux's.

## Consequences

- A flip is one `APPLY` with no check, and its completion is one `VBLANK` event. That is the whole hot path of the desktop.
- `vx-dp` is written once and serves `disp-msm`, the Sky1's back end, and every later DP back end. It is also the first-party rewrite of `msmfb`'s GPL timing code that ADR-0019 §6 already required, so that work moves into the library.
- A new SoC in a supported family costs a record, not a driver.
- `displayd` holds the complexity Fuchsia's coordinator does: configurations, EDID, mode lists. It is written once, against `simplefb` and virtio-gpu, before any hardware back end.
- Version 1 of the protocol has no writeback, no colour management, no VRR and no HDR. Each is a later version, with the back end that first needs it.
- Back ends in user space are debuggable as ordinary processes (05), and a crashed one restarts with the firmware's picture back on screen (item 3).

## Open questions

1. **Scan-out buffer constraints across drivers.** A scan-out image on the Q8B must come from `disp-msm`'s pool (ADR-0019 open question 4); on the Sky1 it goes through the SMMU (ADR-0027). Does `INFO`'s constraint list suffice for `winsrv` to allocate correctly without asking the back end each time?
2. **Several outputs on one engine.** Both engines can drive two streams from one controller. Version 1 has one output for each back end; the configuration already allows more.

## References

- Fuchsia: `sdk/fidl/fuchsia.hardware.display.engine/` (`overview.fidl`, `engine.fidl`), `src/graphics/display/drivers/coordinator/`, `drivers/amlogic-display/display-engine.cc` (firmware adoption), `lib/designware-hdmi/`, `lib/edid/`
- Linux: `drivers/gpu/drm/display/drm_dp_helper.c`, `drivers/gpu/drm/msm/disp/dpu1/catalog/`, `include/drm/drm_bridge.h`
- 9front: `sys/src/cmd/aux/vga/igfx.c`, `sys/src/cmd/aux/vga/edid.c`, `/lib/vgadb`
- ADR-0018 item 7; ADR-0019 §6; ADR-0027
