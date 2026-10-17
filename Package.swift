// swift-tools-version: 6.2
// SPDX-License-Identifier: BSD-3-Clause

// Host build: vx and the libraries and tests that run on the developer's
// machine. The images (loader, kernel, user space) are CMake's
// (CMakeLists.txt, one tree per arch); vx drives both (D11, D13), and
// CMake runs vx's build steps (elf2efi, mkbootfs, check-pixels),
// building it here first.

import CompilerPluginSupport
import PackageDescription

let unchecked: [SwiftSetting] = [.unsafeFlags(["-enforce-exclusivity=unchecked"])]
let c23: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-std=gnu23"])]
// The flags device code is held to everywhere (cmake/CroiUser.cmake's).
let tier0: [SwiftSetting] = [
  .enableExperimentalFeature("Lifetimes"),
  .strictMemorySafety(),
  .unsafeFlags(["-Werror", "StrictMemorySafety"]),
]

// What C reaches V1's calls through: croi/syscall.h, and the kernel's ABI
// headers it includes by quoted names.
let abiHeaders = CSetting.unsafeFlags([
  "-I", "\(Context.packageDirectory)/user/include", "-iquote", "\(Context.packageDirectory)/kernel/include",
])

// A target list of its own: one literal of them all is too much for the
// type checker.
let ipc: [Target] = [
  // IPC (system/ipc, V2): the wire format (D6, docs/wire-format.md),
  // @IPCLibrary (the macro, and the runtime its generated code calls,
  // over Sys), and idlc (C headers, docs and API baselines from the same
  // protocol files). Echo is the test protocol and its server.
  .target(name: "IPCWire", path: "system/ipc/wire", swiftSettings: tier0),
  .testTarget(name: "IPCWireTests", dependencies: ["IPCWire"], path: "system/ipc/tests/wire",
              swiftSettings: tier0),
  .target(name: "IPCModel", dependencies: [
    "IPCWire", .product(name: "SwiftSyntax", package: "swift-syntax"),
    .product(name: "SwiftParser", package: "swift-syntax"),
  ], path: "system/ipc/model"),
  .macro(name: "IPCMacros", dependencies: [
    "IPCModel",
    .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
    .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
  ], path: "system/ipc/macros"),
  .testTarget(name: "IPCMacrosTests", dependencies: [
    "IPCMacros",
    .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
  ], path: "system/ipc/tests/macros"),
  .target(name: "IDL", dependencies: [
    "IPCModel", .product(name: "SwiftParser", package: "swift-syntax"),
  ], path: "system/ipc/idl"),
  .executableTarget(name: "idlc", dependencies: ["IDL"], path: "tools/idlc"),
  .target(name: "IPC", dependencies: ["IPCWire", "Sys", "Trace", "IPCMacros"], path: "system/ipc/runtime",
          swiftSettings: tier0),
  // td_wire.h: the wire format in C, over V1's calls (croi/syscall.h, whose
  // quoted includes find the kernel's ABI headers; -iquote keeps its
  // time.h from the host's <time.h>). Hosted, only the codec runs: the C
  // client's calls run natively.
  .target(name: "TDWire", path: "system/ipc/c",
          cSettings: [abiHeaders]),
  .target(name: "IDLCTests", dependencies: ["TDWire"], path: "system/ipc/tests/c", exclude: ["generated"],
          cSettings: [.headerSearchPath("generated"), abiHeaders]),
  .testTarget(name: "IDLTests", dependencies: ["IDL", "IDLCTests", "IPC", "Echo"], path: "system/ipc/tests/idl",
              swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
  .target(name: "Echo", dependencies: ["IPC"], path: "system/ipc/tests/echo",
          swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
  .testTarget(name: "IPCTests", dependencies: ["IPC", "Echo"], path: "system/ipc/tests/runtime",
              swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
  // Node (system/node, V2): the protocol every service serves, batched
  // (D18, D64), the tree helper that serves it, namespaces and /srv.
  .target(name: "Node", dependencies: ["IPC", "Ring"], path: "system/node/lib", swiftSettings: tier0),
  .testTarget(name: "NodeTests", dependencies: ["Node", "IPC", "IDL"], path: "system/node/tests",
              exclude: ["native"], swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
  // The time service's RTC reading (services/time, D48): its registers as UTC.
  .target(name: "RTC", path: "services/time/lib", swiftSettings: tier0),
  .testTarget(name: "RTCTests", dependencies: ["RTC"], path: "services/time/tests"),
  // The pty service's line discipline (services/pty, D46); the service and
  // its protocol are native (launch-test runs them).
  .target(name: "Pty", path: "services/pty/lib", sources: ["LineDiscipline.swift"], swiftSettings: tier0),
  .testTarget(name: "PtyTests", dependencies: ["Pty"], path: "services/pty/tests"),
  // The fs protocol's client side (services/fs, V2: FDIO's; the service
  // comes with Taisce, V3).
  .target(name: "Fs", dependencies: ["Node", "IPC"], path: "services/fs/lib", swiftSettings: tier0),
  // FDIO (system/fdio, V2): POSIX descriptors over the namespace, tier 1's
  // files; hosted, over a namespace a test installs.
  .target(name: "FDIO", dependencies: ["Fs", "Node", "IPC"], path: "system/fdio",
          exclude: ["native", "tests", "README.md"], sources: ["lib", "hosted"], swiftSettings: tier0),
  .testTarget(name: "FDIOTests", dependencies: ["FDIO", "Node", "IPC"], path: "system/fdio/tests", exclude: ["native"]),
  // rcport: our rc on Linux, which `vx rc-oracle` checks against 9front's (D70).
  .executableTarget(name: "rcport", dependencies: ["Rc"], path: "tools/rc-oracle/port",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
  // rc, the shell (shell/rc, V2: tier 1 natively): its grammar and
  // evaluation, over a system.
  .target(name: "Rc", path: "shell/rc/lib"),
  .testTarget(name: "RcTests", dependencies: ["Rc"], path: "shell/rc/tests"),
  // The shell's file commands (shell/commands, V2: tier 1 natively, with rc).
  .target(name: "Commands", dependencies: ["Fs", "Guide", "Node", "IPC"], path: "shell/commands/lib"),
  .testTarget(name: "CommandsTests", dependencies: ["Commands", "Node", "IPC"], path: "shell/commands/tests"),
  // Directives (D86): the one record format, one directive a line: the
  // launcher's manifests, drivers' and the manual's page headers.
  .target(name: "Directives", path: "system/directives/lib", swiftSettings: tier0),
  .testTarget(name: "DirectivesTests", dependencies: ["Directives"], path: "system/directives/tests"),
  // guide (D86): the manual's page format, its parser and its renderer for
  // a terminal; the one reader of pages.
  .target(name: "Guide", dependencies: ["Directives"], path: "system/guide/lib", swiftSettings: tier0),
  .testTarget(name: "GuideTests", dependencies: ["Guide"], path: "system/guide/tests"),
  // The launcher (system/launch, V2): manifests, a job and a process per
  // service, each process's namespace as its Startup (D65), restarts.
  .target(name: "Launch", dependencies: ["Directives", "Node", "IPC"], path: "system/launch/lib", swiftSettings: tier0),
  .testTarget(name: "LaunchTests", dependencies: ["Launch", "Node", "IPC"], path: "system/launch/tests",
              exclude: ["native"], swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
  // ACPI (drivers/bus/acpi, V2 item 7a, D74): its tables and our AML
  // interpreter, todhchai's; tier 0. Its tests run over a corpus of
  // firmware tables out of the tree (vx acpi).
  .target(name: "TDACPI", path: "drivers/bus/acpi/lib", swiftSettings: tier0),
  .testTarget(name: "ACPITests", dependencies: ["TDACPI"], path: "drivers/bus/acpi/tests", exclude: ["native"]),
  // Cryptography, ours (D89): tier 0, optimized even in debug builds (every
  // Taisce block is hashed). 9front's libsec is the tests' oracle, host only.
  .target(name: "TDCrypto", path: "crypto/lib", swiftSettings: tier0 + [.unsafeFlags(["-O"])]),
  .target(name: "LibsecOracle", path: "crypto/oracles/9front", exclude: ["LICENSE", "NOTICE"],
          cSettings: [.headerSearchPath("."), .unsafeFlags(["-std=gnu99", "-fms-extensions", "-w"])]),
  .testTarget(name: "CryptoTests", dependencies: ["TDCrypto", "LibsecOracle"], path: "crypto/tests"),
  // PCI over ECAM (drivers/bus/pci, V2 item 7b, D74): configuration space,
  // enumeration, BARs and capabilities, todhchai's; ECAM's registers
  // through the runtime's accessors (CroiMMIO, croi/mmio.h).
  .systemLibrary(name: "CroiMMIO", path: "user/include"),
  .target(name: "PCI", dependencies: ["CroiMMIO"], path: "drivers/bus/pci/lib", swiftSettings: tier0),
  .testTarget(name: "PCITests", dependencies: ["PCI", "TDACPI"], path: "drivers/bus/pci/tests", exclude: ["native"]),
  // devmgr and the driver host (V2 item 7c, D74): todhchai's, its BTIs on
  // the machine's IOMMUs and its registers through CroiMMIO.
  .target(name: "DriverHost", dependencies: ["CroiMMIO", "Sys"], path: "drivers/host", swiftSettings: tier0),
  .target(name: "DevMgr", dependencies: ["CroiMMIO", "Directives", "DriverHost", "PCI", "Sys", "TDACPI"], path: "drivers/devmgr/lib",
          swiftSettings: tier0),
  .testTarget(name: "DevMgrTests", dependencies: ["DevMgr", "PCI", "Launch", "TDACPI"], path: "drivers/devmgr/tests"),
  // virtio over PCI (V2 item 7d, D74): the modern transport and split
  // queues, todhchai's; virtio-blk's request format, which its tests'
  // model drives the rings through (the block class comes in V3).
  .target(name: "Virtio", dependencies: ["CroiMMIO", "DriverHost", "Sys"], path: "drivers/virtio/lib",
          swiftSettings: tier0),
  .target(name: "VirtioBlk", dependencies: ["Virtio"], path: "drivers/block/virtio-blk/lib", swiftSettings: tier0),
  .testTarget(name: "VirtioTests", dependencies: ["Virtio", "VirtioBlk"], path: "drivers/virtio/tests"),
  // The input class (V2 item 7d, D83): the usages keyboards push to kbdfs.
  .target(name: "InputDevice", path: "drivers/input/lib", swiftSettings: tier0),
  .testTarget(name: "InputTests", dependencies: ["InputDevice"], path: "drivers/input/tests"),
  // The net class (D82): a NIC as Plan 9's ether(3) directory.
  .target(name: "NetClass", dependencies: ["Node", "IPC", "Sys"], path: "drivers/net/lib", swiftSettings: tier0),
  .testTarget(name: "NetClassTests", dependencies: ["NetClass", "Node", "IPC", "Sys"], path: "drivers/net/tests"),
  // The network stack (D79): one interface's protocols, no I/O of its own.
  .target(name: "Net", dependencies: ["TDCrypto"], path: "services/net/lib", swiftSettings: tier0),
  .testTarget(name: "NetTests", dependencies: ["Net"], path: "services/net/tests"),
  // /net's protocols over it, as Plan 9's ip(3) (D79).
  .target(name: "IP", dependencies: ["Net", "Node", "IPC", "Sys"], path: "services/net/ip", exclude: ["tests"],
          swiftSettings: tier0),
  .testTarget(name: "IPTests", dependencies: ["IP", "Net", "Node", "IPC", "Sys"], path: "services/net/ip/tests"),
  // Names (D79): the network database, cs and dns, as Plan 9's ndb(8).
  .target(name: "Ndb", dependencies: ["Net", "Node", "IPC", "Sys"], path: "services/ndb/lib", swiftSettings: tier0),
  .testTarget(name: "NdbTests", dependencies: ["Ndb", "IP", "Net", "Node", "IPC", "Sys"], path: "services/ndb/tests"),
  // 9gate (D77, D78): 9P2000's codec, and Noise IK, its transport. 9front's
  // fcall(2) is the codec's oracle, host only, as libsec is crypto's (D89).
  .target(name: "NineP", path: "services/9gate/p9", swiftSettings: tier0),
  .target(name: "Noise", dependencies: ["TDCrypto"], path: "services/9gate/noise", swiftSettings: tier0),
  .target(name: "FcallOracle", path: "services/9gate/oracles/9front", exclude: ["LICENSE", "NOTICE"],
          cSettings: [.headerSearchPath("."), .unsafeFlags(["-std=gnu99", "-fms-extensions", "-w"])]),
  // 9gate's export and import over them (services/9gate/lib).
  .target(name: "Gate", dependencies: ["NineP", "Noise", "Node", "IPC", "IPCWire", "Sys"], path: "services/9gate/lib",
          swiftSettings: tier0),
  .testTarget(name: "GateTests", dependencies: ["Gate", "NineP", "Noise", "FcallOracle", "Node", "IPC", "Sys"],
              path: "services/9gate/tests"),
  // kbdfs (D83): the keyboard and the console, after 9front's.
  .target(name: "Kbdfs", path: "services/kbdfs/lib", swiftSettings: tier0),
  .testTarget(name: "KbdfsTests", dependencies: ["Kbdfs"], path: "services/kbdfs/tests"),
  // /proc (V3, D79): a directory a process, notes posted through it (D87).
  .target(name: "Proc", dependencies: ["Node", "IPC"], path: "services/proc/lib", swiftSettings: tier0),
  .testTarget(name: "ProcTests", dependencies: ["Proc", "Node", "IPC"], path: "services/proc/tests"),
  // The console (V2 item 8): its text grid and renderer, and fontgen,
  // which writes its font from data/fonts/spleen (third-party data, D4's
  // data not code).
  .target(name: "FontGen", path: "text/fonts/gen"),
  .executableTarget(name: "fontgen", dependencies: ["FontGen"], path: "tools/fontgen"),
  .target(name: "Console", path: "services/console/lib", swiftSettings: tier0),
  .testTarget(name: "ConsoleTests", dependencies: ["Console", "FontGen"], path: "services/console/tests"),
  // The plumber (V2 item 8, D85): plumber(4)'s files, todhchai's rules.
  .target(name: "Plumber", path: "services/plumber/lib", swiftSettings: tier0),
  .testTarget(name: "PlumberTests", dependencies: ["Plumber"], path: "services/plumber/tests"),
]

let package = Package(
  name: "vectraos",
  products: [
    .executable(name: "vx", targets: ["vx"]),
  ],
  dependencies: [
    // Host toolchain under D4, not code on the device: the release matching
    // the Swift 6.4 compiler, for the @IPCLibrary macro and idlc.
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0"),
  ],
  targets: [
    .target(name: "TraceFormat", path: "system/trace/format"),
    .target(name: "TraceReader", dependencies: ["TraceFormat", "Ring"], path: "system/trace/reader"),
    // The trace writer (system/trace, V2): hosted over a file
    // ($TODHCHAI_TRACE); natively over the region its process is given
    // (CMake). Its C side: the cycle counter, a thread-local pointer and
    // atomics on shared memory.
    .target(name: "TDTraceCPU", path: "system/trace/c"),
    .target(name: "Trace", dependencies: ["TraceFormat", "Ring", "TDTraceCPU"], path: "system/trace/writer",
            exclude: ["native"], swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
    .testTarget(name: "TraceTests", dependencies: ["Trace", "TraceReader"], path: "system/trace/tests",
                exclude: ["native"]),
    .target(name: "Bench", path: "tools/bench/lib"),
    .testTarget(name: "BenchTests", dependencies: ["Bench"], path: "tools/bench/tests"),
    .target(name: "ImageFormats", path: "tools/image/lib"),
    .testTarget(name: "ImageFormatsTests", dependencies: ["ImageFormats"], path: "tools/image/tests"),
    // The one ring (D43): Ring.swift, ring.h through CRing, and RingCheck,
    // the model checker that runs both (CRingChecked: ring.h on its hooks).
    // Code that runs on RingCheck's coroutines has no runtime exclusivity
    // checks: their record of accesses is a list in stack order, which
    // switching stacks breaks.
    .target(name: "Ring", path: "lib/ring/Ring", swiftSettings: unchecked),
    .target(name: "RingCheckContext", path: "lib/ring/check/context"),
    .target(name: "RingCheck", dependencies: ["Ring", "RingCheckContext"], path: "lib/ring/check/Checker",
            swiftSettings: unchecked),
    .target(name: "CRing", path: "lib/ring/tests/CRing"),
    .target(name: "CRingChecked", path: "lib/ring/tests/CRingChecked"),
    .testTarget(name: "RingTests", dependencies: ["Ring", "CRing"], path: "lib/ring/tests/Native",
                swiftSettings: [.unsafeFlags(["-Xcc", "-std=gnu23"])]),
    .testTarget(name: "RingCheckTests", dependencies: ["Ring", "RingCheck", "CRingChecked"],
                path: "lib/ring/tests/Model", swiftSettings: unchecked + [.unsafeFlags(["-Xcc", "-std=gnu23"])]),
    // The ABI headers (D45): object.h is the one source of statuses, rights
    // and object types; the kernel's Swift enums, which need literals, are
    // checked against it.
    .systemLibrary(name: "CroiAbi", path: "kernel/include"),
    // KernelAbi is Status.swift alone, through a link.
    .target(name: "KernelAbi", dependencies: ["CroiAbi"], path: "kernel/tests/Abi/KernelAbi",
            swiftSettings: c23),
    .testTarget(name: "AbiTests", dependencies: ["KernelAbi", "CroiAbi", "TraceFormat"], path: "kernel/tests/Abi/Tests",
                swiftSettings: c23),
    // Sys (system/sys, V2): what services use to reach the kernel. SysABI
    // is the ABI's values as Sys's types (from CroiAbi, D45); SysHost the
    // hosted kernel (one Linux process, a handle table per hosted process),
    // on V1's model; Sys the typed API over it, natively over the kernel
    // (CMake). SysHost has no dynamic exclusivity checks: a thread's end is
    // accounted in a pthread key destructor, which may run after the Swift
    // runtime's thread-local access set is gone; its lock serializes it.
    .target(name: "SysABI", dependencies: ["CroiAbi"], path: "system/sys/abi", swiftSettings: tier0 + c23),
    .target(name: "SysHost", dependencies: ["SysABI"], path: "system/sys/host", swiftSettings: unchecked + c23),
    .target(name: "Sys", dependencies: ["SysABI", "SysHost"], path: "system/sys",
            exclude: ["abi", "host", "tests", "floor", "native", "backend/native"], sources: ["api", "backend/host"],
            swiftSettings: tier0 + c23),
    .testTarget(name: "SysTests", dependencies: ["Sys", "SysHost"], path: "system/sys/tests", exclude: ["native"],
                swiftSettings: c23),
    // Our libc (system/libc, V2), tier 0, tested against the host's glibc.
    // native/ exports the functions under their C names: CMake's build
    // only. Optimized in debug builds too: its value-generic conversions
    // run unspecialized at -Onone, several times slower, and its tests run
    // millions of them. errno is glibc's hosted (Errno.swift).
    .target(name: "LibC", path: "system/libc", exclude: ["README.md", "native", "tests", "pthread", "include"],
            swiftSettings: tier0 + [.enableExperimentalFeature("Extern"), .unsafeFlags(["-O"], .when(configuration: .debug))]),
    .target(name: "TDFloat128", path: "system/libc/tests/float128"),  // glibc's binary128, for the tests
    .testTarget(name: "LibCTests", dependencies: ["LibC", "TDFloat128"], path: "system/libc/tests",
                exclude: ["float128"]),
    // Its pthreads, a module of their own: natively over the floor
    // (CMake), hosted over Sys, for the tests that compare them with glibc's.
    .target(name: "TDAtomic", path: "system/libc/pthread/c"),
    .target(name: "PThread", dependencies: ["Sys", "TDAtomic"], path: "system/libc/pthread",
            exclude: ["c", "native", "tests", "platform/floor"], sources: ["lib", "platform/hosted"],
            swiftSettings: tier0 + c23),
    .testTarget(name: "PThreadTests", dependencies: ["PThread", "Sys"], path: "system/libc/pthread/tests",
                swiftSettings: c23),
    // ELF images as croi loads them (lib/elf: the kernel's, the loader's
    // and userboot's) and the dynamic linker's core (system/ld, V2), tested
    // hosted on shared objects linked for each machine; natively, dlopen
    // over them is CMake's (croi_user_sys).
    .target(name: "Elf", path: "lib/elf/Elf", swiftSettings: tier0),
    .target(name: "Ld", path: "system/ld", exclude: ["native", "tests"], sources: ["lib"], swiftSettings: tier0),
    .testTarget(name: "LdTests", dependencies: ["Ld", "Elf"], path: "system/ld/tests", exclude: ["native"]),
    .target(name: "Hardware", path: "tools/hardware/lib"),
    .testTarget(name: "HardwareTests", dependencies: ["Hardware"], path: "tools/hardware/tests"),
    // Risk-based testing (D88): docs/risk.tsv, vx test --changed.
    .target(name: "Risk", path: "tools/risk/lib"),
    .testTarget(name: "RiskTests", dependencies: ["Risk"], path: "tools/risk/tests"),
    // The manual on the dev machine (D86): its pages, index and backlog, and
    // the check against the code (vx man).
    .target(name: "Manual", dependencies: [
      "Guide", .product(name: "SwiftParser", package: "swift-syntax"),
      .product(name: "SwiftSyntax", package: "swift-syntax"),
    ], path: "tools/man/lib"),
    .testTarget(name: "ManualTests", dependencies: ["Manual", "Guide"], path: "tools/man/tests"),
    .executableTarget(name: "vx", dependencies: ["Bench", "Guide", "Hardware", "ImageFormats", "Manual", "Risk", "TDACPI", "TraceFormat",
                                                 "TraceReader"], path: "tools/vx"),
  ] + ipc,
  cLanguageStandard: .gnu2x
)
