# D5. First hardware: Radxa Dragon Q8B (2026-10-15, decided)

The board is a Qualcomm SC8280XP: Cortex-X1C/A78C cores, an Adreno 690 GPU
and a Hexagon CDSP NPU, with UEFI and ACPI firmware.

- **Why:** AbyssBSD already runs it under ACPI with the CDSP working, and its
  notes (`AbyssBSD/docs/boards/radxa-dragon-q8b/`) are ground truth. croi's
  ACPI-only boot path carries over, so no devicetree work is needed.
- **Later:** RK3588 and Hailo-8 follow once the accelerator protocol exists.
