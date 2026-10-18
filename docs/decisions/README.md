# Decision log

Entries are dated and never edited after the fact. A reversal is a new entry
that names the one it replaces.

- **Decided** means the project owner made the call.
- **Proposed** means it was drafted with the founding docs and stands until
  someone confirms or reverses it.

Each decision is a file in this directory, named by its number (D054 is
`D054-wire-format-unions.md`); a new decision takes the next free number
in a new file, and a line in the index below.

## Index

- [D1. Languages: Embedded Swift first, C23 where necessary](D001-languages-swift-first-c23.md) — 2026-10-15, decided
- [D2. The kernel: lift croi, then slim it](D002-kernel-lift-croi-slim.md) — 2026-10-15, decided
- [D3. The control plane: todhchai's Node protocol locally, 9P2000.L only at the network edge](D003-control-plane-node-protocol.md) — 2026-10-15, decided
- [D4. Third-party code: first-party on the device, heavy tools only on the host](D004-third-party-code-on-device.md) — 2026-10-15, decided
- [D5. First hardware: Radxa Dragon Q8B](D005-first-hardware-radxa-q8b.md) — 2026-10-15, decided
- [D6. One wire format: todhchai's IPC wire format, not FlatBuffers](D006-one-wire-format-todhchai.md) — 2026-10-15, proposed
- [D7. Wasm as a process, not a unikernel](D007-wasm-as-process.md) — 2026-10-15, proposed
- [D8. One file system: Taisce](D008-one-file-system-taisce.md) — 2026-10-15, decided
- [D9. Desktop: tile and space workspace modes, switchable live](D009-desktop-workspace-modes.md) — 2026-10-15, decided; details proposed
- [D10. Performance contracts from todhchai](D010-performance-contracts-todhchai.md) — 2026-10-15, decided
- [D11. One front door: `vx`](D011-one-front-door-vx.md) — 2026-10-15, proposed
- [D12. Names](D012-project-names.md) — 2026-10-15, proposed
- [D13. Host tools under SwiftPM, images under CMake](D013-host-tools-swiftpm-images-cmake.md) — 2026-10-15, decided in V0
- [D14. No Python in the build](D014-no-python-in-build.md) — 2026-10-15, decided
- [D15. A bring-up link before the board, over SSH](D015-bring-up-link-ssh.md) — 2026-10-15, decided
- [D16. Milestones run in order](D016-milestones-run-in-order.md) — 2026-10-15, decided; corrects D15
- [D17. Boot budget history starts at V2](D017-boot-budget-history-v2.md) — 2026-10-15, decided
- [D18. The control plane stays on channels, and is batched](D018-control-plane-channels-batched.md) — 2026-10-15, decided
- [D19. Ports become rings](D019-ports-become-rings.md) — 2026-10-15, decided
- [D20. object_bind, the first cut](D020-object-bind-first-cut.md) — 2026-10-15, decided
- [D21. FIFOs, sockets and streams are cut](D021-fifos-sockets-streams-cut.md) — 2026-10-15, decided
- [D22. The channel _etc forms and the futex extras are cut](D022-channel-etc-futex-extras-cut.md) — 2026-10-15, decided
- [D23. Events, signals and the thread waits are cut](D023-events-signals-thread-waits-cut.md) — 2026-10-15, decided
- [D24. Desktop look: Platinum Indigo, not neon](D024-desktop-look-platinum-indigo.md) — 2026-10-15, direction decided; details proposed
- [D25. Sleeps, timers and the counter waits are cut](D025-sleeps-timers-counter-waits-cut.md) — 2026-10-15, decided
- [D26. Clocks are cut](D026-clocks-cut.md) — 2026-10-15, decided
- [D27. Display timelines are cut](D027-display-timelines-cut.md) — 2026-10-15, decided
- [D28. The bring-up calls are cut: debug_write and vmo_map](D028-bring-up-calls-debug-write-vmo-map.md) — 2026-10-15, decided
- [D29. The interrupt waits are cut](D029-interrupt-waits-cut.md) — 2026-10-15, decided
- [D30. thread_raise_exception is cut](D030-thread-raise-exception-cut.md) — 2026-10-15, decided
- [D31. system_get_event is cut; the root account reports memory levels](D031-system-get-event-cut.md) — 2026-10-15, decided
- [D32. port_cancel_key merges into port_cancel](D032-port-cancel-key-merge.md) — 2026-10-15, decided
- [D33. handle_close takes an array](D033-handle-close-array.md) — 2026-10-15, decided
- [D34. handle_replace merges into handle_duplicate](D034-handle-replace-merge.md) — 2026-10-15, decided
- [D35. One test call](D035-one-test-call.md) — 2026-10-15, decided
- [D36. vmo_get_size and process_info become info topics](D036-info-topics-vmo-process.md) — 2026-10-15, decided
- [D37. vmo_read and vmo_write are cut](D037-vmo-read-write-cut.md) — 2026-10-15, decided
- [D38. The debuglog becomes a read-only ring; debuglog_read is cut](D038-debuglog-read-only-ring.md) — 2026-10-15, decided
- [D39. handle_duplicate takes an array](D039-handle-duplicate-array.md) — 2026-10-15, decided
- [D40. The wakes take arrays: port_queue, port_wait, counter_add, interrupt_ack](D040-wakes-take-arrays.md) — 2026-10-15, decided
- [D41. channel_read and channel_write take arrays](D041-channel-read-write-arrays.md) — 2026-10-15, decided
- [D42. vmar_map, vmar_unmap and vmar_protect take arrays](D042-vmar-calls-arrays.md) — 2026-10-15, decided
- [D43. The one ring: Ring.swift, ring.h, and RingCheck on both](D043-one-ring-ringcheck.md) — 2026-10-15, decided
- [D44. Ports as rings: CROI_PORT_RING](D044-ports-as-rings-croi-port-ring.md) — 2026-10-15, decided
- [D45. One ABI: lifted code includes VectraOS's headers](D045-one-abi-lifted-code.md) — 2026-10-15, decided
- [D46. Byte streams on the one ring](D046-byte-streams-one-ring.md) — 2026-10-15, decided; amended 2026-10-16
- [D47. Tier 1: the *-vectraos toolchain comes with V2](D047-tier-one-vectraos-toolchain.md) — 2026-10-15, decided; amended 2026-10-16
- [D48. Time: UTC in a page the time service writes](D048-time-utc-page.md) — 2026-10-15, decided
- [D49. The floor is the one user runtime](D049-floor-user-runtime.md) — 2026-10-15, decided
- [D50. Trace rings on the one ring](D050-trace-rings-one-ring.md) — 2026-10-15, decided
- [D51. The rv64 board: Orange Pi RV2 (Ky X1), and RVA22 as rv64's baseline](D051-rv64-board-orange-pi-rv2.md) — 2026-10-16, decided; firmware open
- [D52. amd64's baseline: the 2013 Mac Pro's (Ivy Bridge)](D052-amd64-baseline-ivy-bridge.md) — 2026-10-16, decided
- [D53. arm64's baseline: the Q8B's Armv8.2-A, checked against the CIX Sky1](D053-arm64-baseline-armv8-2a.md) — 2026-10-16, decided
- [D54. The wire format gains unions](D054-wire-format-unions.md) — 2026-10-16, decided
- [D55. The GPU stack lifted from todhchai: Vulkan underneath, Loinnir on top](D055-gpu-stack-vulkan-loinnir.md) — 2026-10-16, proposed
- [D56. GPU memory is named by intent; Loinnir places it per device](D056-gpu-memory-by-intent.md) — 2026-10-16, proposed
- [D57. VRAM and the process's memory budget](D057-vram-process-memory-budget.md) — 2026-10-16, proposed; open
- [D58. One synchronization mechanism: Loinnir tracks hazards](D058-gpu-one-synchronization-hazards.md) — 2026-10-16, proposed
- [D59. Shader-visible layouts come from the IDL](D059-shader-layouts-from-idl.md) — 2026-10-16, proposed
- [D60. GPU debugging is Loinnir's validation and the trace](D060-gpu-debugging-validation-trace.md) — 2026-10-16, proposed
- [D61. The Venus ring is an exception to the one ring](D061-venus-ring-exception.md) — 2026-10-16, proposed
- [D62. GPU hardware floor and driver order](D062-gpu-hardware-floor-driver-order.md) — 2026-10-16, proposed
- [D63. The Mac Pro's D700s meet D62's floor; descriptor heaps are required; the fan fails safe](D063-macpro-d700-floor.md) — 2026-10-16, proposed
- [D64. Node's batch: operations on a current node](D064-node-batch-current-node.md) — 2026-10-16, decided
- [D65. A process's start is its processargs; todhchai's Startup protocol is not lifted](D065-start-is-processargs.md) — 2026-10-16, proposed
- [D66. Hardware support levels, each with its check](D066-hardware-support-levels.md) — 2026-10-16, decided
- [D67. Bulk Node reads and writes: an SQ/CQ ring pair and a data VMO the client makes](D067-node-bulk-sq-cq.md) — 2026-10-16, decided
- [D68. The scheduler places by capacity and topology; thermal limits reach it as capacity](D068-capacity-aware-thermal-scheduling.md) — 2026-10-16, proposed; the cpu_set_info merge decided
- [D69. The first board is the Orange Pi 6 Plus; the Q8B moves to V8](D069-first-board-orange-pi-6-plus.md) — 2026-10-16, decided; replaces D5's choice
- [D70. rc is checked against 9front's rc, a host-only oracle](D070-rc-checked-against-9front.md) — 2026-10-16, decided
- [D71. Programs come from the namespace: Node's `memory`, and bootfs served at /bin](D071-programs-from-the-namespace.md) — 2026-10-16, decided
- [D72. A process says why it ended: an exit string on a status page, Plan 9's exits](D072-exit-strings.md) — 2026-10-16, decided
- [D73. Node gains wstat: a node renamed in its directory, given a time, or cut](D073-node-wstat.md) — 2026-10-16, decided
- [D74. Drivers as todhchai's, ported to V1: real IOMMUs, ACPI platform devices, the runtime's MMIO accessors](D074-drivers-scope.md) — 2026-10-16, decided
- [D75. The terminal is rio's window, remote sessions are Plan 9's cpu, and the keyring becomes factotum](D075-cpu-and-factotum.md) — 2026-10-16, decided
- [D76. Taisce on disk and the desktop come before the boards](D076-taisce-and-desktop-before-boards.md) — 2026-10-16, decided; amends D16
- [D77. The bring-up link is Plan 9's cpu, not SSH](D077-bring-up-link-is-cpu.md) — 2026-10-16, decided; supersedes D15's protocol, amends D75
- [D78. 9gate's core dialect is 9P2000, not 9P2000.L](D078-9p2000-core-dialect.md) — 2026-10-16, decided; amends D77
- [D79. V3's interfaces are Plan 9's: /net with dial strings, /proc with notes, and ctl files](D079-v3-interfaces-net-proc-ctl.md) — 2026-10-16, decided
- [D80. POSIX is tier 1's APE, and nothing else's](D080-posix-is-tier1-ape.md) — 2026-10-16, decided
- [D81. The environment is /env](D081-environment-is-env.md) — 2026-10-16, decided
- [D82. Driver classes are Plan 9's device directories for control, the one ring for bulk](D082-device-directories.md) — 2026-10-16, decided
- [D83. Keyboards are 9front's kbdfs, keyed by HID usages: drivers push them to kbin, kbdfs gives runes and the console](D083-keyboards-are-kbdfs.md) — 2026-10-17, decided; amends D82
- [D84. A Node read may wait: streams, answered when they have bytes](D084-node-reads-may-wait.md) — 2026-10-17, decided
- [D85. The router is Plan 9's plumber: plumber(4)'s files](D085-the-router-is-plumber.md) — 2026-10-17, decided
- [D86. The system is documented by its manual: Plan 9's sections, NeoVectra's guide format, headers as directives](D086-the-manual.md) — 2026-10-17, proposed
- [D87. Notes are a queue on the process, posted and taken as a property; untaken, a note kills](D087-notes-in-the-kernel.md) — 2026-10-17, decided
- [D88. During a milestone, test what a change risks; the full suite closes the milestone](D088-risk-based-testing.md) — 2026-10-17, decided
- [D89. Crypto is todhchai's whole library, checked against 9front's libsec on the host](D089-crypto-oracle.md) — 2026-10-17, decided; extends D70
- [D90. The Ghost: an opt-in, local-first agent built from the namespace's own mechanisms](D090-the-ghost.md) — 2026-10-17, proposed
- [D91. Themes are data over one vocabulary; Platinum Indigo is the default, not the only look](D091-themes.md) — 2026-10-17, proposed; extends D24
- [D92. Hot reload is a program's own code in its own process; a plug-in is a process; both compiled, in any language](D092-plugins-and-hot-reload.md) — 2026-10-17, proposed
- [D93. A ring read of a stream waits, as a plain read does](D093-ring-reads-wait.md) — 2026-10-17, decided; amends D67, extends D84
- [D94. A write to a full stream waits, as a read of an empty one does](D094-stream-writes-wait.md) — 2026-10-17, decided; extends D84 and D93
- [D95. Native applications: what both NeoVectra and todhchai planned, our code speaking existing standards](D095-native-applications.md) — 2026-10-17, proposed
- [D96. Studio: streaming for creators, on capture, rings and existing ingest protocols](D096-studio-streaming-for-creators.md) — 2026-10-17, proposed
- [D97. The console's shell is rc on kbdfs's /dev/cons, in kbdfs's note group](D097-console-shell.md) — 2026-10-17, decided; extends D77, D83, D87
- [D98. A ring's doorbell lends its ringer's profile, until the woken side blocks](D098-ring-doorbells-lend.md) — 2026-10-17, proposed; extends K10c's lending
- [D99. The launcher answers memory pressure by ending services in bands; a service may start on first use and end when idle](D099-pressure-and-on-demand-services.md) — 2026-10-17, proposed; extends D31
- [D100. A service's mount reconnects through the launcher's forwarder](D100-mounts-reconnect.md) — 2026-10-17, decided; extends D65, enables D99
- [D101. Warm boot: the kernel hands off to a new kernel and bootfs held in memory](D101-warm-boot.md) — 2026-10-17, decided; extends D77, D79
- [D102. trace: proc serves the kernel's trace, and vx names its samples](D102-trace-a-node.md) — 2026-10-18, decided; extends D50, D79
