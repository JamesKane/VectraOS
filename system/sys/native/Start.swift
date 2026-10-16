// SPDX-License-Identifier: BSD-3-Clause

// libsys's Swift views (M3, decided: ours, not croi's runtime) of what the
// floor's start (system/sys/floor, D49) kept: the handles the process was
// started with, its arguments and its environment, as Swift values.
// Embedded Swift has no CommandLine. Over the floor's C interface
// (td_floor.h), so that tier 1's full Swift builds it too (M6e); tier 1's
// LibSys will re-export its platform's C library (VectraOSLibc, D47).

import TDFloor
import TDNative

/// The handles the process was started with, by their processargs info.
public enum StartupHandles {
  /// The handle started with `info`, which is the caller's from then on;
  /// nil if there was none or it was taken.
  public static func take(_ info: UInt32) -> UInt32? {
    let h = TDFloor.td_startup_take(info)
    return h == 0 ? nil : h
  }

  /// The info words of the handles not yet taken.
  public static var remaining: [UInt32] {
    var out: [UInt32] = []
    for i in 0..<TDFloor.td_startup_count() {
      let info = TDFloor.td_startup_info(i)
      if info != 0 { out.append(info) }
    }
    return out
  }
}

/// A C string's bytes as a String.
func string(_ p: UnsafePointer<CChar>) -> String {
  var bytes: [UInt8] = []
  var i = 0
  while unsafe p[i] != 0 {
    bytes.append(UInt8(bitPattern: unsafe p[i]))
    i += 1
  }
  return String(decoding: bytes, as: UTF8.self)
}

/// The arguments the process was started with, its name first.
public enum Arguments {
  public static var strings: [String] {
    var out: [String] = []
    var argc: Int32 = 0
    guard let argv = unsafe TDFloor.td_argv(&argc) else { return out }
    for i in 0..<Int(argc) { if let p = unsafe argv[i] { out.append(unsafe string(p)) } }
    return out
  }
}

/// The environment the process was started with (`name=value` strings).
public enum Environment {
  public static var strings: [String] {
    var out: [String] = []
    guard let env = unsafe environ else { return out }
    var i = 0
    while let p = unsafe env[i] {
      out.append(unsafe string(p))
      i += 1
    }
    return out
  }

  /// The value of `name`, if the environment has it: its first entry's.
  public static func value(_ name: String) -> String? {
    guard let env = unsafe environ else { return nil }
    let key = Array(name.utf8)
    var i = 0
    while let p = unsafe env[i] {
      i += 1
      var n = 0
      while n < key.count, unsafe UInt8(bitPattern: p[n]) == key[n] { n += 1 }
      if n == key.count, unsafe p[n] == 0x3D { return unsafe string(p + n + 1) }  // '='
    }
    return nil
  }
}
