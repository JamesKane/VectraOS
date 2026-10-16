# ACPI: the tables and our AML interpreter

`TDACPI` (`lib/`), lifted from todhchai (D74, V2 item 7a): the RSDP,
XSDT/RSDT and every table's header and checksum; the DSDT and SSDTs
loaded into one namespace with their load-time code run; the AML
interpreter, written from the ACPI 6.5 specification with no ACPICA
(D4); operation regions and fields through a host; and devices: `_STA`,
`_HID`, `_CID`, `_UID`, `_ADR`, `_INI` in order, `_CRS` (every resource
descriptor), `_PRT` and `_OSC`. Tier 0, so devmgr (item 7c) runs it on
the device. It does no I/O itself: operation regions, sleeping,
notifications and `_OSI` go through `ACPIHost`, which devmgr implements
natively and the tests with fakes that record every access.

How it was built, step by step, and its limits (64 levels of
expressions and statements, 32 of calls; 128 KiB of stack in a release
build, so its thread gets 256 KiB) are todhchai's record, `A0.md`, which
the code's `A0b`-`A0g` notes refer to.

**Tests.** `ACPITests` (hosted, `swift test`): encoded AML from the
grammar for each rule, robustness limits, and a fuzzer mutating the
corpus's tables (40 mutants a table; `TODHCHAI_ACPI_FUZZ=N` runs more).
Over the corpus: every table loads with no unknown opcode, every
identifying method evaluates or fails only for want of regions, every
`_CRS` and `_PRT` decodes. The corpus stays out of the tree, in
`.cache/acpi` (firmware tables are vendor binaries, QEMU's GPL fixtures):

    .build/debug/vx acpi fetch-qemu      # QEMU 11.1.2's tables: q35, pc, microvm, arm64 and rv64 virt
    sudo .build/debug/vx acpi import     # this machine's, Linux's device view as the oracle
    .build/debug/vx acpi list

Tests over it skip when it's absent, and those that compare with Linux
skip without an import. Natively, `bin/acpi-test` (the boot-acpi test,
every arch) loads the tables this boot was given and checks what the
corpus tests check, a PCI host bridge's `_CRS` and `_PRT`, and on amd64
`\_S5` and the CMOS clock (PNP0B00).

Not yet: the budgets todhchai's `acpi-bench` judged (loading the largest
DSDT, `_STA` across every device), which come with devmgr, where the
interpreter runs for real; and userboot's `\_S5` byte scan, which goes
when devmgr owns the namespace (7c).
