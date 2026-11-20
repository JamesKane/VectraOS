# D167. One owner a register page: devmgr's MMIO grants are exclusive by the page, and a register another host needs is reached through its owner (2026-11-20, the owner scheduled the backlog's B5)

An MMIO resource grants every page it touches, and the MMU can't keep
two holders of one page apart. Today several hosts can map one page:

- devmgr gives a platform device the ranges its tables link to it
  (`Device.LinkedRange`): SCMI's shared memory and mailboxes (`shmem`,
  `mboxes`), a DisplayPort transmitter's PHY (`phy`), and the reset
  controllers its RSTL names (`reset`), which several devices share
  (the Sky1's RST0 and RST1).
- power(8) holds the root MMIO resource (its manifest's `resource
  mmio`) and carves the pages of the CPUs' CPPC registers itself. On
  the Sky1 those registers are SCMI fast channels in mailbox 6's page,
  which scmi(3) is also granted.
- The kernel has exclusive resources (`CROI_RSRC_FLAG_EXCLUSIVE`), but
  their overlap test compares bytes, not pages, and devmgr makes none.

## The decision

1. **Exclusivity is by the page.** For an MMIO resource, the kernel's
   overlap test with an exclusive one compares the pages each touches,
   not their bytes: a resource that shares a page with an exclusive one
   is refused, whichever is exclusive.
2. **devmgr's MMIO grants are exclusive,** each device's own ranges and
   its linked ones alike. A grant that would share a page with another
   host's fails, the device isn't bound, and devmgr's `status` says
   which page and which host has it. devmgr's own mappings (ECAM, ACPI's
   regions) are its, as before.
3. **A register another host needs is reached through its owner's
   tree,** never by a second grant:
   - **CPPC:** scmi(3), which owns mailbox 6's page, writes a CPU's
     desired-performance register when power(8) asks (a `ctl` line
     naming the register's address and value, refused outside the
     registers devmgr's `cpus` lists), and power(8) gives up `resource
     mmio`. A machine whose CPPC registers are in a page no driver owns
     (ACPI's SystemMemory elsewhere) has devmgr grant power that page,
     exclusively, as any device's.
   - **Shared reset controllers:** the controller is a device of its own
     with a driver that owns its page (the Sky1's RST0 and RST1,
     `CIXHA020`, `CIXHA021`), serving `reset N assert|deassert`, which
     the RSTL links already name as its consumers' provider (D163). Its
     consumers (mali(3), linlon(3), dptx(3)) pulse their resets through
     it instead of mapping its page.
   - **A combo PHY's page** shared by two consumers (the Sky1's USB and
     DisplayPort on one PHY) goes to one driver the same way, when a
     second consumer of it first exists.
4. **devmgr's `status` lists every page in two hosts** (none, once this
   is done), and B4's checks hold it on a board's captured tables.

## Not chosen

- **Groups named in a manifest** (two devices in one host because they
  share a page). It couples drivers that have nothing else in common,
  and the owner-serves-its-registers rule already covers every case
  found.
- **Leaving power(8) the root MMIO resource.** A service that can map
  any page defeats the rule for every other.
