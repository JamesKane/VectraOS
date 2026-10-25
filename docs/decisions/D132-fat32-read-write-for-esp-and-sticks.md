# D132. FAT32 is read and written, for the ESP and removable sticks; Taisce stays the one file system for the system's own data (2026-10-24, the owner's choice; amends D8)

D8 kept FAT read-only, for the ESP. Two needs on the boards change that:
- **UEFI loading.** The loader, kernel and bootfs live on the ESP,
  which firmware reads as FAT32. Today another system writes them (the
  Orange Pi's FreeBSD, the dev machine's deploy). A node that installs
  or updates its own boot images writes FAT32.
- **Bring-up logs on a stick.** The AMD tower (V6c) has no serial
  port. If the PCIe serial card isn't there in time, the console's log
  goes to the USB stick it boots from, and the dev machine reads it.

The owner's call: FAT32 is written as well as read. The same driver
serves both needs.

**What this doesn't change.** Taisce is the one file system for the
system's own data (D8, D105): volumes, attributes, queries, `/data`.
FAT32 is for interchange with firmware and other machines: the ESP, and
sticks. Nothing VectraOS keeps for itself lives on FAT. No FAT12 or
FAT16, and no exFAT.

**Needs first.** USB mass storage (bulk-only transport and SCSI, under
xhci(3), into the block class) for sticks; the ESP on an NVMe disk is
reachable through nvme(3) already.

**Not decided yet** (when the work starts, with V6c's item 1): where
the driver lives (a service beside fs(4), or a block-class client that
mounts at `/mnt/<name>`), long names (VFAT's LFN entries) and their
case rules, and how a write is made safe against power loss (FAT has no
journal: order the FAT, the data and the directory entry, and mark the
volume dirty).
