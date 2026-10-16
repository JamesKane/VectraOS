// swift-tools-version: 6.2
// SPDX-License-Identifier: BSD-3-Clause

// Host build: vx and the libraries and tests that run on the developer's
// machine. The images (loader, kernel, user space) are CMake's
// (CMakeLists.txt, one tree per arch); vx drives both (D11, D13), and
// CMake runs vx's build steps (elf2efi, mkbootfs, check-pixels),
// building it here first.

import PackageDescription

let unchecked: [SwiftSetting] = [.unsafeFlags(["-enforce-exclusivity=unchecked"])]
let c23: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-std=gnu23"])]
// The flags device code is held to everywhere (cmake/CroiUser.cmake's).
let tier0: [SwiftSetting] = [
  .enableExperimentalFeature("Lifetimes"),
  .strictMemorySafety(),
  .unsafeFlags(["-Werror", "StrictMemorySafety"]),
]

let package = Package(
  name: "vectraos",
  products: [
    .executable(name: "vx", targets: ["vx"]),
  ],
  targets: [
    .target(name: "TraceFormat", path: "system/trace/format"),
    .target(name: "TraceReader", dependencies: ["TraceFormat"], path: "system/trace/reader"),
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
    .testTarget(name: "AbiTests", dependencies: ["KernelAbi", "CroiAbi"], path: "kernel/tests/Abi/Tests",
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
    .executableTarget(name: "vx", dependencies: ["Bench", "ImageFormats", "TraceFormat", "TraceReader"], path: "tools/vx"),
  ],
  cLanguageStandard: .gnu2x
)
