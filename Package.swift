// swift-tools-version: 6.2
// SPDX-License-Identifier: BSD-3-Clause

// Host build: vx and the libraries and tests that run on the developer's
// machine. The images (loader, kernel, user space) are CMake's
// (CMakeLists.txt, one tree per arch); vx drives both (D11).

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
    .executableTarget(name: "vx", dependencies: ["Bench", "TraceFormat", "TraceReader"], path: "tools/vx"),
  ]
)
