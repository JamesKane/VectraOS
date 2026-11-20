# D171. Checks run over a whole machine's description, on devmgr's own model, and a device no driver serves is left alone on purpose, with its reason (2026-11-20, the owner scheduled the backlog's B4)

Each check we have looks at one device, or at one grant, when devmgr
makes it. Nothing reads a board whole: two devices' registers that
overlap, an enabled device nobody has read, a clock with no provider, a
stream id two masters share, an interrupt two drivers take, an SMMU with
no supply, a register page two hosts hold (D167) were each found, when
they were, by a driver failing on the board. A generator that refuses a
chip that doesn't check out found a video codec granted to the console
in hand-written tables; ours had nothing to refuse with, and a second
description format for the checks to read would break principle 1.

## The decision

1. **The checks read what devmgr reads.** `BoardCheck`
   (`tools/boardcheck/lib`, host only) loads a board as devmgr models it:
   ACPI's devices from the board's captured tables (`vx acpi`), through
   the code devmgr runs at boot (`loadNamespace` and `link`, moved from
   devmgr's `Main.swift` into `drivers/devmgr/lib/Enumeration.swift` for
   it), with the IOMMU units and stream ids of the IORT; a devicetree's
   from its compiled tree (`DeviceTreeBus.devices`). The driver records
   are every `driver.manifest` under `drivers/`, as `etc/drivers` has
   them, and the page check is `PageLedger`'s own (`claims`, `shared`),
   not a copy of its rule.
2. **Seven checks.** Each prints findings, and a board passes with
   none:
   - `overlap`: two devices' register ranges overlap unless one lies
     inside the other;
   - `unowned`: an enabled device that no `driver` record matches and no
     `leave` record covers, one both cover (a stale record), one two
     drivers match alike;
   - `providers`: a link with no provider or naming a device that isn't
     there, and a cycle of providers; a tree's fixed clocks end a chain,
     and the Sky1's CLKT clocks and SCMI power domains go to the device
     with shared memory, its SCMI agent;
   - `iommu-supply`: a master in a power domain behind a unit with no
     supply of its own, and a unit no device holds and no record names;
   - `interrupts`: an interrupt two devices a driver is bound to have (a
     device no driver takes owns none: a USB controller's core and its
     xhci host name one);
   - `stream-ids`: an id two masters have on one unit (a PCI root
     complex's requester ids and a named component's alike);
   - `pages`: a 4 KiB page two hosts are granted, each bound device a
     host with what devmgr grants it, a firmware call's memory too.

   Not done: **a driver's register offsets against the spec's tables**,
   which chinese-wall has for few of the blocks and in no form a check can
   read; **a supply with no root** beyond a link with no provider, since a
   regulator's chain on a tree ends at a fixed supply the tree gives no
   mark but its `regulator-fixed` driver.
3. **A device left alone is a record.** A `leave NAME` record in a
   `driver.manifest` takes `match` lines (a driver's kinds, and for it
   alone `acpi-path PATH`, with `*` for any bytes, for a device with no
   hardware id, and `iommu BASE`, a unit no device holds) and a
   `reason`, which it must have. devmgr reads them into the index
   (`DriverIndex.leftAlone`) and acts on none: a device no driver matches
   isn't bound, as before. The records are
   `drivers/left-alone/driver.manifest`. A driver's record may not take
   `acpi-path` or `iommu`, and a `leave` record may not take a driver's
   directives.
4. **Where they run.** `BoardCheckTests` (a SwiftPM target, so in
   `vx ci`): the Sky1's captured tables (skipped, with the reason
   printed, where `.cache/acpi/orangepi-6-plus` isn't), the RV2's tree
   through the toolchain's clang (skipped without it), and a control for
   each check. `vx dtc --check` runs the checks on one tree, printing
   each finding and exiting 1 on any.
5. **Every check has a control** (D165's rule): a small board built to
   break exactly that check and the same board mended to pass it, and
   the Sky1's real tables broken one way at a time, one for each check.
   A leave rule that covers nothing on its board fails too.

## What it found

On the Orange Pi 6 Plus's tables, nothing that stays after the records:
the first run found 212 of its 252 devices with no record covering them (marked left
alone, with reasons, in groups), 14 `i2c` links to controllers whose
`_STA` reads firmware memory the capture doesn't have (the check judges
such a device present, as the board runs it), the SCMI power domains'
empty providers, both SMMUs with no device and no supply (recorded: the
tables give a unit no supply, and D169's leases are what keep a provider
from cutting one under a master), and ten pairs of USB cores and xhci
hosts that name one interrupt (the core is no driver's).

On the RV2's tree: eight devices nobody had read (left alone), the fixed
clocks, and **one open finding the tree keeps**: its two EHCI
controllers' second `reg` is a word of the APMU's page (`0xd428287c`,
`0xd4282bc4`: their VBUS drive bits), which k1-syscon owns, so D167's
exclusive grants cannot give both. The fix is a syscon link through the
APMU's tree in ehci(3), not a record; `BoardCheckTests` names the finding
so that the test fails when it is gone and the tree is clean.

## Not chosen

- **A second description of a board for the checks** (their generator's
  chip tables). The tables and the tree are the description.
- **A list of accepted findings.** A check is mended or its subject is
  recorded as left alone, with a reason, by the record devmgr reads; the
  one open finding is a test that expects exactly it.
- **A `leave` field on a driver's record.** A device left alone has no
  driver whose record could say so.
