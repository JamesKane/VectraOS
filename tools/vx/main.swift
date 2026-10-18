// SPDX-License-Identifier: BSD-3-Clause

// vx: the one front door (principle 25, D11). After todhchai's td.
//
//   vx build [ARCH...]        configure (once) and build each arch's tree
//   vx test [ARCH...] [--only TEST,...]
//                             build, then each arch's QEMU tests, one arch at a time
//   vx test --changed [REF] [--plan]
//                             only what the change since REF risks (TestCommand.swift, D88)
//   vx test --check           risk.tsv against the tree: names exist, every test has a row
//   vx boot [ARCH] [--cpu [KEY]]
//                             build and boot interactively (Ctrl-A x quits); with
//                             --cpu, the launcher and a cpu server for KEY
//                             (this terminal's by default) on localhost!17019
//   vx cpu -k NODEKEY [-r ROOT] [-c CMD] NODE
//                             rc on a node, with this terminal (CpuCommand.swift, D77)
//   vx bench [--runs N] [--record [--accept]] [--enforce] [--compare REF]
//                             the boot budgets under KVM, judged against
//                             this machine's history (BenchCommand.swift)
//   vx bench --zircon [--rounds N] [--only CONFIG,...] [--logs DIR]
//                             the same budgets against Zircon's (ZirconCommand.swift)
//   vx trace collect|print|summary|diff ...
//   vx loc [--check]          lines per component, and the size budgets
//   vx man [-w] [SECTION] TITLE [NODE] | --check | --missing | --index FILE
//                             the manual (ManCommand.swift, D86)
//   vx hardware [--check]     the hardware support list (HardwareCommand.swift)
//   vx rc-oracle [CASE...]    our rc against 9front's (RcOracleCommand.swift, D70)
//   vx acpi import|fetch-qemu|list  the AML interpreter's corpus (ACPICommand.swift, D74)
//   vx ci [--no-bench]        host tests, rc against 9front's, every arch's
//                             build, amd64's and arm64's tests, the size budgets, the
//                             manual's check, then the
//                             bench (advisory)
//
// ARCH is amd64, arm64 or rv64; none means all three (amd64 for boot), but
// for test, which runs amd64's and arm64's suites (rv64's is off until full
// Swift runs there; name it to run it).
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
/// The arches whose QEMU suites `vx test` and `vx ci` run by default. rv64
/// builds but isn't tested until full Swift (tier 1) runs there: its
/// LLVM lacks Swift's calling conventions (roadmap, item 3). `vx test rv64`
/// still runs it.
let testedArches = ["amd64", "arm64"]

func arches(_ args: [String]) -> [String] {
  for a in args where !allArches.contains(a) { fail("unknown arch \(a); vx knows \(allArches.joined(separator: ", "))") }
  return args.isEmpty ? allArches : args
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
  fail("usage: vx build|test|boot|cpu|remote|bench|trace|loc|man|hardware|rc-oracle|acpi|ci [options]")
}
args.removeFirst()

switch command {
case "elf2efi": exit(elf2efiCommand(args) ? 0 : 1)
case "mkbootfs": exit(mkbootfsCommand(args) ? 0 : 1)
case "check-pixels": exit(checkPixelsCommand(args) ? 0 : 1)
case "qemu-monitor": exit(qemuMonitorCommand(args) ? 0 : 1)
case "trace": exit(traceCommand(args) ? 0 : 1)
case "mathgen": exit(mathgenCommand(args) ? 0 : 1)
case "cpu": exit(cpuCommand(args) ? 0 : 1)
case "remote": exit(remoteCommand(args) ? 0 : 1)
default: break
}

guard FileManager.default.fileExists(atPath: "Package.swift"),
  FileManager.default.fileExists(atPath: "CMakePresets.json")
else { fail("run vx \(command) from the repository root") }

switch command {
case "build": exit(arches(args).allSatisfy { build($0) } ? 0 : 1)
case "test": exit(testCommand(args) ? 0 : 1)
case "boot": exit(bootCommand(args) ? 0 : 1)
case "bench": exit(benchCommand(args) ? 0 : 1)
case "loc": exit(locCommand(args) ? 0 : 1)
case "man": exit(manCommand(args) ? 0 : 1)
case "hardware": exit(hardwareCommand(args) ? 0 : 1)
case "rc-oracle": exit(rcOracleCommand(args) ? 0 : 1)
case "acpi": exit(acpiCommand(args) ? 0 : 1)
case "ci": exit(ci(args) ? 0 : 1)
default: fail("unknown command \(command); vx has build, test, boot, cpu, remote, bench, trace, loc, man, hardware, rc-oracle, acpi and ci")
}
