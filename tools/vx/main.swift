// SPDX-License-Identifier: BSD-3-Clause

// vx: the one front door (principle 25, D11). After todhchai's td.
//
//   vx build [ARCH...]        configure (once) and build each arch's tree
//   vx test [ARCH...]         build, then each arch's QEMU tests, one arch at a time
//   vx boot [ARCH]            build and boot interactively (Ctrl-A x quits)
//   vx bench [--runs N] [--record [--accept]] [--enforce] [--compare REF]
//                             the boot budgets under KVM, judged against
//                             this machine's history (BenchCommand.swift)
//   vx bench --zircon [--rounds N] [--only CONFIG,...] [--logs DIR]
//                             the same budgets against Zircon's (ZirconCommand.swift)
//   vx trace collect|print|summary|diff ...
//   vx loc [--check]          lines per component, and the size budgets
//   vx hardware [--check]     the hardware support list (HardwareCommand.swift)
//   vx rc-oracle [CASE...]    our rc against 9front's (RcOracleCommand.swift, D70)
//   vx ci [--no-bench]        host tests, rc against 9front's, every arch's
//                             build and tests, the size budgets, then the
//                             bench (advisory)
//
// ARCH is amd64, arm64 or rv64; none means all three (amd64 for boot).
// Run these from the repository root. Build vx first and run its binary,
// so the builds it starts don't wait on SwiftPM's lock:
//   swift build --product vx && .build/debug/vx ci
//
// Build steps, which CMake and tools/qemu.sh run from anywhere:
//
//   vx elf2efi IN.elf OUT.efi                 (ImageCommands.swift)
//   vx mkbootfs OUT.img NAME=FILE...
//   vx check-pixels FILE.ppm X,Y,R,G,B...
//   vx qemu-monitor SOCKET COMMAND...         (MonitorCommand.swift)
//   vx mathgen OUT.swift                      libm's constants (MathgenCommand.swift)

import FoundationEssentials
import Glibc

let allArches = ["amd64", "arm64", "rv64"]

func arches(_ args: [String]) -> [String] {
  for a in args where !allArches.contains(a) { fail("unknown arch \(a); vx knows \(allArches.joined(separator: ", "))") }
  return args.isEmpty ? allArches : args
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
  fail("usage: vx build|test|boot|bench|trace|loc|hardware|rc-oracle|ci [options]")
}
args.removeFirst()

switch command {
case "elf2efi": exit(elf2efiCommand(args) ? 0 : 1)
case "mkbootfs": exit(mkbootfsCommand(args) ? 0 : 1)
case "check-pixels": exit(checkPixelsCommand(args) ? 0 : 1)
case "qemu-monitor": exit(qemuMonitorCommand(args) ? 0 : 1)
case "trace": exit(traceCommand(args) ? 0 : 1)
case "mathgen": exit(mathgenCommand(args) ? 0 : 1)
default: break
}

guard FileManager.default.fileExists(atPath: "Package.swift"),
  FileManager.default.fileExists(atPath: "CMakePresets.json")
else { fail("run vx \(command) from the repository root") }

switch command {
case "build": exit(arches(args).allSatisfy { build($0) } ? 0 : 1)
case "test": exit(arches(args).allSatisfy { build($0) && test($0) } ? 0 : 1)
case "boot":
  let arch = arches(args).first!
  guard args.count <= 1, build(arch) else { exit(1) }
  exit(run(["ninja", "-C", "build/\(arch)", "run"], log: nil).ok ? 0 : 1)
case "bench": exit(benchCommand(args) ? 0 : 1)
case "loc": exit(locCommand(args) ? 0 : 1)
case "hardware": exit(hardwareCommand(args) ? 0 : 1)
case "rc-oracle": exit(rcOracleCommand(args) ? 0 : 1)
case "ci": exit(ci(args) ? 0 : 1)
default: fail("unknown command \(command); vx has build, test, boot, bench, trace, loc, hardware, rc-oracle and ci")
}
