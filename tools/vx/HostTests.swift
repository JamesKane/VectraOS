// SPDX-License-Identifier: BSD-3-Clause

// One SwiftPM test target's tests, built and run alone (vx test --host).
// On Linux that is `swift test --filter`. On the Mac `swift test` builds
// every target, and some need Glibc, so the target is built with `swift
// build --target` and its bundle run through the toolchain's
// swiftpm-testing-helper, which runs Swift Testing's tests.

import HostSystem

/// How a target's run ended: `built` says whether its build did.
struct HostTestResult {
  var built: Bool
  var ok: Bool
  var seconds: Double
}

#if canImport(Darwin)
/// The toolchain `.swift-version` names, as an xctoolchain on the Mac.
private func macToolchain() -> String? {
  let version = trimmed((try? String(contentsOfFile: ".swift-version", encoding: .utf8)) ?? "")
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  for dir in ["\(home)/Library/Developer/Toolchains", "/Library/Developer/Toolchains"] {
    let t = "\(dir)/swift-\(version)-RELEASE.xctoolchain"
    if FileManager.default.fileExists(atPath: t) { return t }
  }
  return nil
}
#endif

/// Builds and runs test target `target` in the current directory (the
/// package's root), its output appended to `log`.
func runHostTests(_ target: String, log: String?) -> HostTestResult {
  let build = run(["swift", "build", "--target", target], log: log)
  guard build.ok else { return HostTestResult(built: false, ok: false, seconds: build.seconds) }
  #if canImport(Darwin)
  guard let tc = macToolchain(), let bin = capture(["swift", "build", "--show-bin-path"]),
    let xcode = capture(["xcode-select", "-p"])
  else {
    complain("no toolchain with swiftpm-testing-helper found for \(target)")
    return HostTestResult(built: false, ok: false, seconds: build.seconds)
  }
  let platform = xcode + "/Platforms/MacOSX.platform/Developer"
  let exe = "\(bin)/\(target).xctest/Contents/MacOS/\(target)"
  guard FileManager.default.isExecutableFile(atPath: exe) else {
    complain("no test bundle at \(exe)")
    return HostTestResult(built: false, ok: false, seconds: build.seconds)
  }
  setenv("DYLD_FRAMEWORK_PATH", platform + "/Library/Frameworks", 1)
  setenv("DYLD_LIBRARY_PATH", "\(tc)/usr/lib/swift/macosx/testing:\(platform)/usr/lib", 1)
  let r = run(
    ["\(tc)/usr/libexec/swift/pm/swiftpm-testing-helper", "--test-bundle-path", exe, exe, "--testing-library", "swift-testing"],
    log: log)
  #else
  let r = run(["swift", "test", "--filter", "^\(target)\\."], log: log)
  #endif
  return HostTestResult(built: true, ok: r.ok, seconds: build.seconds + r.seconds)
}
