# D146. The board's display: scan-out through the display SMMU without a copy, `present` in the display class, then the DisplayPort transmitter for EDID, hotplug and mode setting (2026-10-29, decided; for the owner's review; extends D120, D126)

V6's item 6 left three follow-ups after linlon(3)'s flip:
- mode setting;
- hotplug;
- scan-out through the display SMMU, with no copy.

linlon flips firmware's output at firmware's mode. Its DMA goes through
the stub's BTI, and the engine's streams stay in bypass on the display
SMMU, so the engine could read all of memory. A layer then scans out
only physically contiguous memory, so every flush copies the damage
into one of two buffers of linlon's own.

The functional specs in `chinese-wall/specs` (`linlon-dpu`,
`sky1-dp-tx`) cover what is missing:
- **Streams.** Each engine n has five stream ids on the display SMMU,
  6n, 6n+1, 6n+3, 6n+4 and 6n+5 (6n+2 is its AFBC encoder's). They
  need the same translations (`linlon-dpu/08 §8.2.1`).
- **TBUs.** The layer's TBU-enable bit is for integrated TBUs only, and
  stays 0 behind an external SMMU (`01 §1.5`).
- **Coherency.** The engine never snoops the CPU's caches, whatever
  `_CCA` or the SMMU's coherency say (`08 §8.2.3`).
- **The HDMI converter.** The board's PS185 is a transparent
  DisplayPort-to-HDMI converter (`sky1-dp-tx/04 §4.9`). Plug detection,
  the monitor's capability registers (the DPCD) and its EDID all come
  over DP4's AUX channel. Our board notes said "the PS185 gives no
  EDID", after AbyssBSD, which never drove AUX.

The owner chose the order (2026-10-29): this design, then step 1.

## Decided

### 1. A BTI for a named component

**IORT's named components** (node type 1: platform devices, the
Sky1's display engines among them) get BTIs on their SMMUv3.
- **The id.** `bti_create`'s id on an SMMUv3 unit is a PCI requester
  id below 2^16. With bit 32 set, the low 32 bits name a named
  component by its node's offset in the IORT. Both the kernel and
  devmgr read that table, and the offset is firmware's, stable for the
  boot.
- **The claim.** It takes every stream id the node's mappings route to
  this SMMU: one domain, one context descriptor and one ASID, with
  each stream's entry pointing at the same context descriptor.
- **Reserved memory.** Reserved ranges (RMRs) of any of those streams
  are identity-mapped in the domain, as for a PCI device's stream.
  Firmware's framebuffer stays reachable, so `show` of 0 still puts it
  back. Device addresses are never allocated over a reserved range.
- **The release.** Each stream returns to bypass if it has reserved
  memory, and aborts otherwise, as one stream does today.
- **What a claim costs.** Each stream's entry is made invalid, then
  translated (break, then make). A stream scanning out may miss its
  fetches for that moment: at most one frame glitches, once, at the
  claim.

### 2. devmgr gives it

devmgr matches each ACPI device to a named component by the node's
device object name (`\_SB_.DPU4`; names compared segment by segment,
each padded to four characters). That device gets the SMMU's BTI in
place of the stub's, and its `dma` line says `translated by SMMUv3
<base>`. A platform device no named component names keeps the stub.

### 3. Display class version 3: `present`

`present(output, image, damage)` shows the image on the output with
its damage, in one latch. It returns when the frame showing it is the
one being scanned out. `show` and `flush` stay. A client of version 3
draws into an image that isn't on the screen and presents it, so
nothing it draws tears.
- **linlon.**
  - `attach` pins the image through the BTI: one run of device
    addresses, so the layer reads it as one linear buffer.
  - `present` cleans the CPU's caches over the damaged rows
    (`vmo_op_range` `CACHE_CLEAN` on the image's VMO), points the layer
    at the image, and latches.
  - linlon's own buffers and its copy go.
  - `flush` of the shown image cleans the damage and latches with no
    change of buffer. It is version 2's single-image path, which tears
    while the client draws.
- **virtio-gpu.** `present` is `flush`, then `show` if the output was
  showing another image. The host's copy is the GPU's
  (`TRANSFER_TO_HOST_2D`).
- **Radharc.**
  - It keeps two images per output and presents them in turn.
  - A frame recomposes its damage together with the previous frame's
    into the image that isn't shown, using buffer age, so the hidden
    image catches up without a copy.
  - Twice an output's memory is the cost: 8 MiB more at 1080p.

### 4. dptx(3): the transmitter, read first

A driver for the Sky1's DisplayPort transmitter (`CIXH502F`), in the
display class's tree.
- **Firmware's link stays up.** dptx doesn't reset the transmitter,
  retrain it or touch the PHY.
- **What it reads.** Over AUX, the DPCD and the EDID (I2C-over-AUX, at
  `0x50`). linlon's `edid` returns that EDID, and Radharc names the
  output by it (D120).
- **Hotplug.** HPD's level and its interrupt are watched. A monitor
  plugged into or out of the PS185 is a short HPD pulse and a change of
  the DPCD's sink count, and becomes `outputsChanged`. An HPD going low
  and staying low, where the link itself is lost, does too.
- **Its interface to linlon.** It is dptx's own. Its shape follows when
  the driver is written.

### 5. Mode setting within the trained link

A mode is set only where it fits the link firmware trained (the same
rate and lane count): the engine's timing, pipeline 0's pixel clock
over SCMI, the transmitter's stream registers (its MSA, transfer unit
and video adapter), and the modes offered taken from the EDID.
- **Taking over firmware's timing** follows `linlon-dpu/08 §8.5`: a
  two-phase disable, the pixel clock gated, and `ip_reset` pulsed
  through the S5 reset controller.
- **`Output` stays as it is.** The modes offered and the choice of one
  are a protocol addition, decided with this step.

## Open: the owner's

Modes faster than firmware's link need retraining, and so the combo
PHY's tables (`sky1-dp-tx/03`). Whether that, MST, audio and the board's
other DisplayPort outputs are in V6 or later is the owner's call.

## Left out

AFBC, the scalers, a second layer, rotation, the AFBC encoder, PSR,
HDCP, DSC and adaptive sync.
