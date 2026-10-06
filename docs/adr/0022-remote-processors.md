# ADR-0022: Remote processors: booting them through the secure world, and talking to them over GLINK

Status: accepted, 2026-10-06 (proposed 2026-10-02). Found by looking at the Radxa Dragon Q8B (ADR-0019); built in M9 (04 §6), but for audio through the ADSP, which waits for its own ADR with M13.

## Context

Modern SoCs run whole subsystems on processors of their own, with firmware the OS loads but does not write. On the Q8B, the ADSP (a Hexagon DSP) owns:

- **the fan:** Radxa's firmware runs a fan loop from the 46 TSENS sensors and drives the PMIC's PWM. Until the OS starts the ADSP, the fan runs at full speed, a hardware fail-safe. It is loud, but it is safe. UEFI does not start the ADSP.
- **USB-C:** the Type-C and power-delivery state machines. The plug's orientation comes from the ADSP. Without it, a plug turned over after boot comes up at USB 2 only.
- **DisplayPort alternate mode** on USB-C. The ADSP negotiates it and reports pin assignment and HPD.
- **audio:** the LPASS codecs, through AudioReach on the DSP.

The CDSP (the NPU) is the same kind of processor, but no open user-space stack exists for it, so it is out of scope (02 §5.3).

AbyssBSD drives the ADSP natively (`docs/boards/radxa-dragon-q8b/power-thermal-idle.md`, `usb.md`, the README's GLINK notes), from Linux's design used as reference:

- **Booting** is the secure world's job, through SCM's PAS calls:
  1. `init_image` with the ELF header and hash segment;
  2. `mem_setup` for the relocatable image;
  3. copying its 24 segments into the carve-out (`0x86c00000`, 32 MiB, reserved by UEFI);
  4. `auth_and_reset`.

  The fan needs nothing more: no RPMh votes, SMP2P or GLINK.
- **Stopping** is dangerous. A PAS `shutdown` of a running DSP hangs the SoC. Linux first raises the stop state through SMEM and SMP2P and waits for the DSP's acknowledgement. AbyssBSD's driver refuses to stop the ADSP at all.
- **Talking** is GLINK, a channel transport over two SMEM rings with IPCC doorbells:
  - the DSP announces version 1;
  - the host agrees on intent reuse;
  - the DSP opens named channels: `PMIC_RTR_ADSP_APPS` (USB-C, as Linux's pmic_glink), `adsp_apps` (GPR, for audio), `IPCRTR` (QRTR, with the service registry that says when the audio domain is up), `RADXA_SVC_ADSP_APPS` (the fan's mode and duty cycle), and others.
- **Firmware:** `qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn` from linux-firmware (`ADSP.HT.5.6.c2-00037-MAKENA-1`), under `LICENSE.qcom`, which allows redistribution. It is over 8 MiB.
- **Hazards:**
  - the board's firmware setting *Hypervisor Settings* must be `Auto` or `Disabled`, or the fan service does not run;
  - a PWM driver on the PMIC's LPG fights the ADSP and winds the fan to 100%;
  - every address given to the DSP for audio carries the SMMU stream ID's low bits above bit 32, or the DSP's first access hangs the SoC.

None of this is in the blueprint. Without it, the Q8B is loud, has USB-C at USB 2 speed one way round, and has no sound. ADR-0018's pattern for large subsystems applies:
- find the firmware boundary (PAS for booting, GLINK for talking);
- define native protocols shaped by their users;
- read Linux's code without linking it.

## Decision

1. **One driver per remote processor, `drv-qcom-pas`, serving `/dev/rproc/NAME/`:**

```
/dev/rproc/adsp/
    info     soc=sc8280xp pas=1 firmware=qcom/sc8280xp/radxa/dragon-q8b/qcadsp8280.mbn carveout=0x86c00000+32M
    state    offline | booting | running | crashed
    ctl      (write) start · stop
```

   - **Start** loads the firmware from the release tree, checks its BLAKE2b hash against the SoC record, and boots it with `svcd`'s SCM operations (01 §7.1). The steps are `init_image`, `mem_setup`, segment copy and `auth_and_reset`, as named operations, never raw SMCs. The carve-out is a VMO marked `secure-after=pas` (01 §7.1), so the driver's mapping is revoked once authentication succeeds.
   - **Stop** is accepted only by the SMEM and SMP2P stop handshake: raise stop, wait for the DSP's acknowledgement with a deadline, then PAS `shutdown`. If there is no acknowledgement, the stop fails and the DSP keeps running. `drv-qcom-pas` never calls `shutdown` on a DSP that has not acknowledged.
   - **Crash detection** is through SMP2P's error bit. The state goes to `crashed`, and the GLINK edge (item 2) is torn down. Restarting a crashed DSP (Linux's SSR) is later work. Until then a crashed ADSP stays down, and the fan returns to its full-speed fail-safe.
   - The SoC record lists the processors to start at boot (`rproc=adsp boot=early`). The ADSP starts as soon as `drv-qcom-pas` and `svcd`'s SCM operations are up, so the fan quiets early.
2. **The GLINK edge for each processor is a driver, `drv-qcom-glink`, serving each channel as a ring session.**
   - It owns the edge's SMEM items (a carve-out VMO), the IPCC doorbell (MMIO and an `Irq`), and the edge protocol: version, intents, opening and closing channels.
   - Each channel the DSP opens is posted as `/srv/glink/adsp/CHANNEL`. A client dials it as it dials any ring session (`lib/vx-ring/session.c`), and sends and receives whole datagrams.
   - A channel has one client at a time, named by the manifest (`connect=glink/adsp/PMIC_RTR_ADSP_APPS`), so no other process can speak on the fan's or USB-C's channel.
   - QRTR is not a router process. The `IPCRTR` channel's one client, the audio driver, speaks QRTR itself, until a second QRTR user exists.
3. **The consumers are ordinary drivers:**
   - `drv-qcom-pmic-glink`, on `PMIC_RTR_ADSP_APPS`. It enables the port notifications, answers each with its acknowledgement, and sets each USB-C combo PHY's lane select and PCS reset, from MMIO that only it holds. Messages are 32 bytes, with Linux's trailing reserved word. It also carries DisplayPort alternate mode's pin assignment and HPD to `disp-msm` when that work starts (ADR-0019 open question 3).
   - The audio driver, on `adsp_apps` and `IPCRTR`, with the `audio` class (03 §7). That is later work, with its own ADR when it starts.
   - Nothing speaks on `RADXA_SVC_ADSP_APPS` in version 1. The fan's own loop is enough. A client for its mode and duty cycle can come later, reporting into `thermd`'s tree (ADR-0021).
4. **What the OS never touches** is listed in the SoC record as owned by the remote processor, and `devmgr` refuses to match a driver to it: the PMIC's LPG PWM channel 3 and PMIC GPIO 8 are `owner=adsp`.
5. **The firmware** is pinned by BLAKE2b in the SoC record when it is vendored into the release tree, as ADR-0019 §8 pins the GPU's. It is served from `/lib/firmware/qcom/`, and loaded from a VMO, so there is no size cap.
6. **The DSP's reach is the kernel's to set.** A remote processor reaches memory only through its SMMU streams, which the kernel programs (01 §7.1), and through its carve-out. The audio stream (`0xc01`) is a `DmaDomain` that the audio driver maps its buffers into, including the stream-ID bits the DSP expects above bit 32.

## Consequences

- The Q8B is quiet after early boot, and SuperSpeed works on USB-C either way round, from three small drivers (PAS boot, GLINK, pmic_glink). Their sizes are measured against AbyssBSD's `qcom_adsp`, `qcom_glink` and `qcom_pmic_glink` when the work starts: this checkout's `src` submodule predates them. Audio is a later ADR.
- The shape carries to other SoCs' coprocessors (a remote-processor driver, a message-transport driver serving channels as ring sessions, and ordinary drivers as clients), Apple's RTKit coprocessors at T2 among them. Each is an amendment that names its boot path and its transport.
- A crashed ADSP is visible (`state crashed`), and safe (the fan's fail-safe), but not yet recovered. SSR is the next step when it is needed.
- The firmware setting for the hypervisor is a board fact, not a driver fix. The Q8B's install notes say it, and `drv-qcom-glink` logs it when the ADSP runs but never opens `RADXA_SVC_ADSP_APPS`, the sign of the wrong setting.
