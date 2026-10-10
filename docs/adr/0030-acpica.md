# ADR-0030: ACPICA 20260930, its core vendored unchanged, for `bus-acpi`

Status: accepted, 2026-10-06 (proposed 2026-10-03). The import was reviewed by James Kane on 2026-10-03 (`VENDOR.ndb`).

## Context

M5 step 7 runs ACPICA in user space, in `bus-acpi` (01 §7.2, ADR-0024): it loads the firmware's DSDT and SSDTs, runs their AML, lists the devices and their resources, and later enters sleep states and serves AML methods to drivers. Writing an AML interpreter is out of the question; ACPICA is the one every OS but Windows uses. ADR-0003 asks for pinned, reviewed source with one ADR per import. 04 §3.1 already lists ACPICA among the vendored libraries, never linked into the kernel.

## Decision

- **ACPICA 20260930**, the latest release (2026-09-30), from `github.com/open-acpica/acpica` (ACPICA's home since it left Intel's), is vendored unchanged under `third_party/acpica`. Only its OS-independent core is kept (`subset=`): `source/include` and nine directories of `source/components` (dispatcher, events, executer, hardware, namespace, parser, resources, tables, utilities), about 86 kLOC. The compiler (iASL), the disassembler, the debugger, the tools and the tests are left out. Licence: BSD-3-Clause, or GPL-2.0-only; this release is the first under those, in place of Intel's own licence. VectraOS takes it under BSD-3-Clause.
- **Provenance.** ACPICA's releases are not signed, and publish no checksum. The tarball's sha256 is the one `./build` would see from a fresh download over HTTPS (2026-10-03). When reviewing, confirm it against a second fetch, and compare the kept files with the release's git tag.
- **The build** is `./build`'s, from `ports/acpica/port.ndb`: a native port, compiled once per architecture with the native programs' freestanding flags (not against musl) into `libacpica.a`, which `bus-acpi` links. The vendored tree has no platform header for VectraOS, and its `acenv.h` stops at an unknown one, so the port force-includes its own (`ports/acpica/acvectra.h`), which stands in for `acenv.h`: 64-bit, the system's C library, ACPICA's own object caches, no debugger. ACPICA is told the C library is the system's so that its `utclib.c` does not define `memcpy` and its kin a second time: `bus-acpi` gives the few string and character functions ACPICA calls (its OS layer, first-party).
- **The OS layer** (`AcpiOs*`) is `bus-acpi`'s, first-party. The tables come from the kernel's copy of them (the `acpi` VMO), laid out in an address range of the OS layer's own, behind a synthesized RSDP and XSDT, since the firmware's memory they came from may since have been reclaimed. Operation regions (`SystemMemory`, `SystemIO`) are minted by `devmgr` on request (M5 step 7b, ADR-0024 item 4).

## Known limits

- The FACS is not among the kernel's copies, so ACPICA runs without it: no global lock shared with firmware, no waking vector. QEMU's AML takes no global lock; a real machine's may (01 §7.2's x86 laptops).
- One thread: the OS layer's locks and semaphores are counters, and deferred work (`AcpiOsExecute`) runs at once.

## Consequences

- Upgrading is replacing the tree with the next release's subset, checking whether a new file in the nine directories needs a new entry in `port.ndb`, and rebuilding.
- ACPICA's code is not under the house rules (04 §1.1); it builds with its own flags and warnings, and `./build check` does not lint it, as for musl and Lua.
