// SPDX-License-Identifier: BSD-3-Clause

// vx: the one front door (principle 25, D11). After todhchai's td.
//
//   vx build [ARCH...]        configure (once) and build each arch's tree
//   vx test [ARCH...]         build, then each arch's QEMU tests, one arch at a time
//   vx boot [ARCH]            build and boot interactively (Ctrl-A x quits)
//   vx bench [--runs N] [--record [--accept]] [--enforce] [--compare REF]
//                             the boot budgets under KVM, judged against
//                             this machine's history (BenchCommand.swift)
//   vx trace print|summary|diff FILE...
//   vx loc [--check]          lines per component, and the size budgets
//   vx ci [--no-bench]        host tests, every arch's build and tests, the
//                             size budgets, then the bench (advisory)
//
// ARCH is amd64, arm64 or rv64; none means all three (amd64 for boot).
// Run from the repository root. Build vx first and run its binary, so the
// builds it starts don't wait on SwiftPM's lock:
//   swift build --product vx && .build/debug/vx ci

import FoundationEssentials
import Glibc

guard FileManager.default.fileExists(atPath: "Package.swift"),
  FileManager.default.fileExists(atPath: "CMakePresets.json")
else { fail("run vx from the repository root") }

let allArches = ["amd64", "arm64", "rv64"]

func arches(_ args: [String]) -> [String] {
  for a in args where !allArches.contains(a) { fail("unknown arch \(a); vx knows \(allArches.joined(separator: ", "))") }
  return args.isEmpty ? allArches : args
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
  fail("usage: vx build|test|boot|bench|trace|loc|ci [options]")
}
args.removeFirst()

switch command {
case "build": exit(arches(args).allSatisfy { build($0) } ? 0 : 1)
case "test": exit(arches(args).allSatisfy { build($0) && test($0) } ? 0 : 1)
case "boot":
  let arch = arches(args).first!
  guard args.count <= 1, build(arch) else { exit(1) }
  exit(run(["ninja", "-C", "build/\(arch)", "run"], log: nil).ok ? 0 : 1)
case "bench": exit(benchCommand(args) ? 0 : 1)
case "trace": exit(traceCommand(args) ? 0 : 1)
case "loc": exit(locCommand(args) ? 0 : 1)
case "ci": exit(ci(args) ? 0 : 1)
default: fail("unknown command \(command); vx has build, test, boot, bench, trace, loc and ci")
}
