# 19 — Drivers on demand: design notes

_Design notes, 2026-10-07. **Preliminary sketch, non-binding.** These notes rework the user-land driver infrastructure. Today every driver ships in `bootfs`. Under this sketch, only the drivers needed to boot stay there. Every other driver becomes an entry in an index that `devmgr` matches against the devices the machine has. Each driver is fetched through the update system's store and started without a reboot. Nothing here changes a rule or decision in 00, and nothing is scheduled. §10 lists the documents that would need amending, and §11 lists the questions to settle before any part becomes an ADR. Prior art (§2) was read in `../fuchsia` and `../9front` on 2026-10-07._

## 1. Where things stand

| Piece | Today | Where |
|---|---|---|
| Driver programs and manifests | All in `bootfs.tar`: `/boot/bin/drv-*` and `/boot/drv/*.ndb`. `devmgr` reads both through bootfs | `boot/drv/`, build.c:1278, 2905-2923 |
| Matching | `match_drivers` reads every `/boot/drv/*.ndb` once, at start. It matches PCI by vendor+device or by class, and ACPI by an exact `_HID` string, with at most 8 ACPI records | `servers/devmgr/devmgr.c:397-479`, 654-663 |
| What `bus-acpi` reports | For each present device with a `_HID`: the HID, the path, and up to 8 `_CRS` resources. No `_CID`, `_UID`, `_ADR` or `_DSD` | `servers/bus-acpi/bus-acpi.c:606-687`, `lib/vx-acpi/mint.h:26-47` |
| A device nothing matched | Dropped silently (`if (!m) return;`) | devmgr.c:663 |
| Supervision | Each driver gets revoke, bus-master off, FLR, quiesce and restart, at most 5 starts over its lifetime | devmgr.c:141, 343-368 |
| A new driver while running | Not possible. It needs a new `bootfs`, which means a new slot and a reboot | 06 §9 |
| Releases and the store | Content-addressed trees, `distd` with verified reads, slots, manual apply and rollback. There is no fetching, no signing and no packages yet | 06, M5 step 9 |

01 §7.2 already describes "driver packages" carrying a match manifest. But neither 06 nor ADR-0014 gives a driver anywhere to come from except the release's `bootfs`. 06 §3.1 says `bootfs` should shrink to "what is needed to reach the system volume" once `fsd` exists. Base files stayed in `bootfs` (decided 2026-10-04), so that has not happened. This sketch is that shrink, for drivers.

## 2. Prior art

**Fuchsia (DFv2)** is the full version of this design.
- The ACPI bus driver publishes each device's `_HID`, and its first `_CID`, as string properties. `PRP0001` devices publish their `_DSD` `compatible` instead (`src/devices/board/lib/acpi/device-builder.cc:152-168`, 444ff).
- Drivers carry compiled bind rules. The driver index evaluates them against node properties (`src/devices/bin/driver-index/src/resolved_driver.rs:157-175`).
- Drivers come in tiers: boot, base and "universe". Universe packages are resolved at run time through the full package resolver (`resolved_driver.rs:34-50, 105-155`; `driver-index.cml:30-118`).
- `DriverRegistrar.Register(url)` adds a driver while the system runs (`indexer.rs:491-540`). The index then tells `driver_manager`, which re-matches every node no driver has bound, its *orphans* (`driver_runner.cc:704-710`, `bind/bind_manager.cc:23-50`).
- Matching runs in a fixed order: non-fallback drivers by tier, then fallback drivers (`indexer.rs:225-262`). Two non-fallback matches for one node are an error (`indexer.rs:273-352`).

**Take:** the orphan set, re-matching when a driver arrives, tiers, and fallback-last. **Leave:**
- The bind language and its bytecode. That is a second language with its own compiler, for a job ndb records with an ordered match already do (D14, rule 13).
- Colocation in shared driver hosts. One driver is one process here (00 §3).

**9front** has no loadable kernel drivers. Its user-level USB drivers are the closest prior art, and they are simpler.
- `nusb/usbd` serves `usbevent`, one `attach` line per device. A new reader is first sent an attach for every device already present (`sys/src/cmd/nusb/usbd/usbd.c:312-352`), so a matcher that starts late, or restarts, misses nothing.
- The database is an rc `switch`, by vid+did first and then by class with wildcards. It includes exclusion entries that deliberately start nothing (`sys/src/9/boot/nusbrc:11-79`).
- **Boot-critical and the rest are split by when they run.** The ramdisk's `nusbrc` handles only keyboard, disk and ether. After root is mounted, `rc/bin/nusbrc` opens a second reader for audio, serial, camera, battery and ptp (`rc/bin/nusbrc:13-38`, called from `rc/bin/termrc:26`).

**Take:** replay on open, specific matches before generic ones, explicit "needs no driver" entries, and the two-stage split.

**Windows Update** also fetches drivers by hardware ID. It does so by sending the machine's ID list to a server. §6.3 avoids that.

## 3. The model in one paragraph

Drivers are split into **boot drivers**, which stay in `bootfs` exactly as today, and **shelf drivers**, which do not. Every release builds a **driver index**: one ndb file listing every shelf driver's match records and the hash of that driver's tree. Shelf drivers ship in a new release **set**, `drivers`, signed and rebuilt like the rest of the release. Unlike other sets, it is fetched **one driver subtree at a time**: the store is content-addressed, so `distd` can fetch the objects under one directory and nothing else. `devmgr` keeps every device no driver claimed in an **unmatched** list and looks each one up in the index locally. It asks `distd` for each driver it needs, and when the tree is in the store it starts the driver as it starts any other. The hardware list never leaves the machine. What a machine fetches is "driver X of release N", from the same sources and under the same signature as an update.

These are **not ADR-0014 packages**. A shelf driver belongs to the release: it has the release's version, it is built from the same commit, its signers rebuilt it, and it rolls back with the release. "No base release depends on a package" (ADR-0014) stays true. "Plug-in" here means what D12 already means: an ordinary process, started on demand, confined to what it was given.

## 4. Boot drivers and shelf drivers

A driver is **boot** if the machine cannot reach the system volume, or cannot be recovered, without it:

| Boot (stays in `bootfs`) | Shelf (fetched when present) |
|---|---|
| `bus-acpi` (and `bus-dt` when it exists) | Audio, cameras, Bluetooth |
| Console UARTs | Sensors, battery and AC (`ACPI0003`, `PNP0C0A`), lid and buttons beyond power |
| Storage controllers that a system volume can sit on: NVMe, AHCI, virtio-blk, and USB mass storage with its host controller | GPU acceleration (`drv-gpu-*`, ADR-0018). The display falls back to the boot framebuffer (ADR-0026) until it arrives |
| The keyboard path: i8042 and USB HID keyboard. A passphrase (06 §16 q9) and recovery need it | Touchpads and touchscreens (I²C HID, `PNP0C50`) |
| | RTC (`PNP0B00`). Today it is in `bootfs`; the wall clock can wait a second |
| | NICs and Wi-Fi: see §6.4 |

The boot set covers every **class** a supported machine might boot from, not one machine's hardware. It stays small because the classes are few. A boot driver is never fetched and never comes from the store. Its manifest stays in `/boot/drv` and it is matched first.

A shelf driver's failure never holds up boot. `devmgr` does not wait for shelf drivers, and a client that connects to a post a shelf driver serves waits on the rendezvous, as clients already do (svcd.c:56-59).

## 5. Identifying what needs a driver

### 5.1 What the buses publish

`bus-acpi` grows its `vx_acpi_device` record so that a device carries everything a match can name:

- `hid=`, plus **every** `cid=`. Fuchsia publishes only the first CID, but a generic CID such as `PNP0C50` (HID over I²C) is often second.
- `uid=` and `adr=`.
- For `PRP0001` devices, `compatible=` read from `_DSD`. This is the same key `bus-dt` will publish, so one match record serves both buses.
- The `_CRS` resources, as today. They are needed for the grant, not for the match.

The fixed 16-byte HID and 48-byte path become ndb text in a VMO. Each device becomes one record, and the list is sent once and then as changes.

PCI functions (enumerated inside `devmgr` today) publish `vendor=`, `device=`, `subvendor=`, `subdevice=` and `class=` in the same form. The user asked about ACPI, but most of a PC's devices are PCI. Both feed the same unmatched list.

SoC and board records (01 §7.2) apply first. A device a record suppresses never reaches the unmatched list. A device a record adds is listed as if ACPI had described it.

### 5.2 The unmatched list

`devmgr` keeps every device no driver claimed, instead of dropping it, and serves them as files:

```
/dev/devmgr/devices     every device: bus=acpi path=\_SB.I2C1.TPD0 hid=ELAN0000 cid=PNP0C50 driver=drv-i2c-hid state=running
/dev/devmgr/unmatched   devices with no driver: index entry, or none known
/dev/devmgr/events      attach/detach/state records; a new reader first gets one attach per present device (9front's replay)
/dev/devmgr/ctl         rematch, disable NAME, enable NAME
```

A device in `unmatched` is in one of three states:
1. `wanted`: the index names a driver, and it is not in the store yet.
2. `unknown`: no entry in the index at all. The user can see this and report it.
3. `none`: the index says the device needs no driver.

`none` covers devices that `devmgr` or `bus-acpi` handle themselves, or that need nothing:
- PCI root bridges (`PNP0A03`, `PNP0A08`)
- interrupt link devices (`PNP0C0F`)
- processors (`ACPI0007`)
- the embedded controller, which `bus-acpi` owns (`PNP0C09`)

Without `none` entries, every machine would show a long list of false "unknown" devices.

## 6. The driver index

### 6.1 Format

Each shelf driver's source directory keeps its manifest in the format `/boot/drv` uses (`servers/devmgr/driver.def`), extended with the keys below. `./build release` collects every manifest into one file, `drivers.ndb`, at the root of the `drivers` set's tree. It adds each driver's subtree hash and size:

```
driver=drv-i2c-hid tree=b2:9c1e… size=48211 class=input restart=always
	match=acpi cid=PNP0C50
driver=drv-hda tree=b2:41aa… size=131072 class=audio restart=always
	match=pci class=0x040300
	match=pci vendor=0x8086 device=0xa0c8
driver=drv-acpi-battery tree=b2:07d3… size=20480 class=power
	match=acpi hid=PNP0C0A
	match=acpi hid=ACPI0003
none=acpi hid=PNP0A03 why=devmgr
none=acpi hid=PNP0C0F why=devmgr
none=acpi hid=PNP0C09 why=bus-acpi
```

The keys:
- `match=` gains `hid`, `cid`, `compatible`, `subvendor` and `subdevice`.
- `fallback` marks a generic driver (§6.2).
- `firmware=` names blobs the driver needs, pinned by hash (ADR-0018 item 6). The blobs are fetched with the driver.

The release record names the `drivers` tree hash per architecture, as it names every set (06 §5.3). So the index is signed by the release, and the index names each driver by hash. Nothing else needs a signature.

### 6.2 Match order

`devmgr` matches each device against the boot manifests first, then the index, and takes the first rule that matches:

1. An exact identity: PCI vendor+device (+subsystem), ACPI `hid`, DT `compatible`.
2. A compatible identity: ACPI `cid`, in the order the device lists them.
3. A class: PCI class code.
4. A rule marked `fallback`: a generic driver that a specific one replaces when one exists. This is Fuchsia's fallback-last.

A boot rule beats an index rule at the same level. Two different drivers matching one device at the same level is a **build error** when `./build release` generates the index, and an error in `/dev/devmgr/unmatched` if it still happens at run time. Neither driver is started.

There is no scoring and no bind language. An ordered list of ndb records is enough, and the build can check it. The rule is the same one 9front's rc `switch` follows: specific entries first, then class wildcards, then exclusions.

### 6.3 Matching stays local (rule 12)

The index is a few tens of KiB. A machine fetches it **with every release record it accepts**, whether or not it has the `drivers` set. Matching happens on the machine, so the machine's hardware list is never sent anywhere.

What does leave the machine is which driver trees it fetches. A peer serving the store sees the hashes requested, and those hint at the hardware. The 06 §6.1 source order already reduces this: swarm, then LAN, then public peers, then mirrors. A policy key (§6.4) can also fetch the whole `drivers` set instead of single subtrees, for anyone who prefers to reveal nothing.

### 6.4 Policy, and the network driver problem

`/dist/policy` (06 §6.3) gains one key:

```
drivers=auto        fetch and start a wanted driver from the sources the policy already allows
drivers=ask         list it as wanted, and fetch it when the user says yes (trusted path)
drivers=all         keep the whole drivers set for this release (offline machines, privacy)
drivers=off         boot drivers only
```

Under 06, "apply is not a policy": a release is applied only when the user asks. Fetching a shelf driver is different. It is not an update. It is a missing part of the release that is already running, at the same version and under the same signature. The sketch therefore lets `auto` be the default (§11 question 1).

A driver cannot be fetched without a network, and the network may itself need a driver. The answer:
- **The install media carry the whole `drivers` set** in `store.tar`, so installation works offline.
- `install` copies into the new system's store every shelf driver the machine matches at install time, network drivers included.
- After that, fetching is only needed for hardware added later, such as a dock, a new card, or a USB device. By then the machine has a working network.

A machine whose only NIC has no local driver (06 §8: "the installer needs a driver only for the target disk") is the one remaining case. It needs local media, or a swarm peer reached some other way. It is listed in `unmatched` as `wanted` with `from=none`.

## 7. Fetching and starting without a reboot

```
bus-acpi / PCI walk ──► devmgr: match boot manifests ──► start boot drivers
                              │
                              └─ no match ──► unmatched (index lookup: wanted / unknown / none)
                                                   │ wanted, policy allows
                                                   ▼
                          devmgr ── "want drv-i2c-hid b2:9c1e…" ──► /dist/drivers/ctl  (distd)
                                                   │
                         distd fetches the subtree, checks every object, serves /dist/drivers/drv-i2c-hid/
                                                   │  Tnotify (6e1d)
                                                   ▼
                          devmgr: rematch the unmatched list ──► start_driver(), as today
```

1. **Before the system volume.** `devmgr` runs from `bootfs` and matches only boot manifests. Shelf matches wait in `unmatched`. The order of boot does not change.
2. **When `distd` posts.** `devmgr` connects to it through a rendezvous post, as `sys-partd` connects to `disk0` today. It mounts `/dist/drivers` (the running release's `drivers` tree, plus what is stored) and reads `drivers.ndb`. Every device in `unmatched` is matched again. Drivers already in the store start at once. This is the normal path on every boot of an installed machine.
3. **A driver not in the store.** If the policy allows, `devmgr` writes `want NAME HASH` to `/dist/drivers/ctl`. `distd` fetches the subtree's objects, checks each one, and records the driver as kept for this release. `/dist/drivers/NAME/` then appears, and the notification wakes `devmgr`.
4. **Start.** `devmgr` re-matches (Fuchsia's re-match of unbound nodes), reads the program image through `/dist/drivers` instead of `/boot/bin`, and calls `start_driver` unchanged. The device gets the same grants and supervision, and its post is created the same way.
5. **Hot-plugged devices** (PCIe hot-plug, Thunderbolt, ACPI `Notify` on a dock, USB once a USB bus driver exists) follow the same path from step 3. They are new records on `events`.

**What `devmgr` will run.** `devmgr` holds the root Resource, so it must never run code the release did not sign. It accepts a program only through the connection attached at `distd`'s `drivers` root (rule 3). It reads a program only by the hash its index entry names. `distd`'s verified reads have already checked every block against that hash before `devmgr` sees a byte (06 §4). The program-path field in a shelf manifest is therefore a name inside that tree, never a path.

**`devmgr` stays small.** It gains the unmatched list, the index parser (the same ndb code that parses `/boot/drv`) and one `ctl` write to `distd`. It does not fetch, verify or speak a network protocol: that is `distd`'s job, and keeping it there keeps the process holding the Resource away from anything that parses network input. A separate `drvd` process between the two was considered and dropped. It would be a third party to every driver start, and would add nothing.

## 8. Releases, updates and rollback

- **A shelf driver follows the release.** When an update is staged (06 §9.2), `distd` also fetches the new release's subtree for every driver kept for the current release. The next boot then has its drivers locally, and `fetched` means fetched for this machine's hardware too.
- **Rollback** goes back to the previous release's driver subtrees, which `keep=2` retains (06 §10.3). Driver and base can never be mismatched, because base programs are rebuilt with the kernel and have no frozen syscall numbers (09 §10 q2). This is why shelf drivers are a set and not packages.
- **No newer driver on an older base.** A fixed driver arrives with the release that fixes it. 01 §7.4's live update (a new instance alongside, the old one quiesces) would allow swapping a driver in place, but only within one release, and as a development tool (ADR-0018 item 10). It is not an update path.
- **Garbage collection.** `gc` (06 §10.3) drops subtrees of releases no slot names. It also drops a driver whose hardware has not been seen for some number of boots, unless the policy is `all`. That number is §11 question 4.

## 9. Supervision, failure and the user's view

- Restart works as today: revoke, bus-master off, FLR, quiesce, restart (01 §7.4). A shelf driver that uses up its starts is **disabled** for that device, and stays disabled until the next boot or `enable`. It is listed with its last exit string in `/dev/devmgr/devices`. The boot continues.
- `disable NAME` in `/dev/devmgr/ctl` survives reboots through `/cfg/devmgr/disabled`. This is Fuchsia's `DisableDriver`. A user can turn off a driver that misbehaves without losing the rest of the release.
- The desktop's bench (03 §9.4) reads `devices` and `unmatched`. It shows what is running, what is waiting for a fetch, and what nothing drives. A "wanted" device under `drivers=ask` gets its yes on the trusted path.
- Devices without an IOMMU still need a driver marked `trusted` (01 §7.4). Being on the shelf changes nothing about that. The mark comes from the index entry, which the release signed.

## 10. What would change

| Document | Change |
|---|---|
| 01 §7.2 | The bus record gains `cid`, `uid`, `adr`, `compatible` and subsystem IDs. The match order (§6.2) is added. The unmatched list and `/dev/devmgr` files are added. `devmgr` reads a second manifest source, `/dist/drivers`, after `distd` posts. |
| 01 §7.4 | Restart exhaustion disables the driver for that device instead of leaving the device in limbo. `disable`/`enable`. |
| 06 §3.1 | `bootfs` holds only boot drivers. Shelf drivers leave it. |
| 06 §3.2 | A `drivers` set, fetched one subtree at a time. `drivers.ndb` at its root is always fetched. |
| 06 §6.3 | The `drivers=` policy key. |
| 06 §8 | `install` copies the matched shelf drivers. Install media carry the whole set. |
| 06 §11 | `/dist/drivers/{ctl,status,NAME/}`. |
| man/6/driver, man/8/devmgr | The new keys, files and states. |
| ADR-0014 | Unchanged. Shelf drivers are not packages. |
| Code, not docs | `devmgr`'s "any `match=` other than `acpi` is PCI" and its 8-record ACPI limit go. `bus-acpi` is restarted like any other driver (man/8/devmgr known bugs). |

A natural split, if this becomes work:
1. **Local only, no network.** Richer bus records, the unmatched list and `events`, `drivers.ndb`, the `drivers` set in releases and on install media, and `devmgr` loading from `/dist/drivers`. This needs only what M5 built. It moves `drv-rtc-cmos` and `drv-virtio-net` out of `bootfs` as the first shelf drivers.
2. **Fetching,** once `distd` fetches at all (06 §14: M10 signatures and sources).
3. **Hot-plug buses:** PCIe hot-plug, then USB when a USB stack exists.

## 11. Open questions

1. **Default policy.** `auto` treats a missing driver as part of the running release, which seems right. But it fetches over the network without a question, and rule 12 asks for a policy before anything leaves the machine. The policy exists, so the real question is whether its default should be `auto` or `ask` on a fresh install.
2. **Third-party drivers.** This sketch keeps every driver first-party and release-signed, which matches ADR-0018 item 5 for GPUs. A publisher-signed driver package under ADR-0014 would need:
   - a grant broader than anything an app can hold: hardware, through `devmgr`'s Resource;
   - a stable driver ABI, which in-base drivers do not have;
   - an answer to "who may approve this".

   Recommendation: not in v1. Revisit only if a real vendor driver forces it, and then through an ADR-0029-style broad grant with an IOMMU required and `trusted` never allowed.
3. **Which device is critical is per machine.** A machine that boots from USB storage needs the xHCI driver in `bootfs`; one that boots from NVMe does not. The class rule in §4 puts every bootable class in `bootfs`. The alternative is a per-slot `bootfs` built at apply time from the machine's matched list. That would be smaller, but it is a new thing to get wrong in the boot path. Measure the class rule's size first.
4. **When to forget a driver.** After N boots without its hardware? Never, for network drivers? Docks come and go weekly.
5. **Composite devices.** An I²C touchpad needs its controller's driver to have posted first. 01 §7.2 already says `bus-dt` spawns a driver "only once every provider its grants name has posted". The same rule should apply to shelf drivers whose providers are themselves fetched. Is "wanted" the right state for "waiting for a provider", or does it need its own state?
6. **The name.** "Shelf" is also 06 §16 q7's word for a signed list of publishers. One of the two should change.
