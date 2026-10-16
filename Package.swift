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
  // The launcher (system/launch, V2): manifests, a job and a process per
  // service, each process's namespace as its Startup (D65), restarts.
  .target(name: "Launch", dependencies: ["Node", "IPC"], path: "system/launch/lib", swiftSettings: tier0),
  .testTarget(name: "LaunchTests", dependencies: ["Launch", "Node", "IPC"], path: "system/launch/tests",
              exclude: ["native"], swiftSettings: [.enableExperimentalFeature("Lifetimes")]),
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
    .executableTarget(name: "vx", dependencies: ["Bench", "Hardware", "ImageFormats", "TraceFormat", "TraceReader"], path: "tools/vx"),
  ] + ipc,
  cLanguageStandard: .gnu2x
)
