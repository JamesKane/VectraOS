// swift-tools-version: 6.2
// SPDX-License-Identifier: BSD-3-Clause

// Host build: vx and the libraries and tests that run on the developer's
// machine. The images (loader, kernel, user space) are CMake's
// (CMakeLists.txt, one tree per arch); vx drives both (D11, D13), and
// CMake runs vx's build steps (elf2efi, mkbootfs, check-pixels,
// todhchai-check), building it here first.

import PackageDescription

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
    .executableTarget(name: "vx", dependencies: ["Bench", "ImageFormats", "TraceFormat", "TraceReader"], path: "tools/vx"),
  ]
)
