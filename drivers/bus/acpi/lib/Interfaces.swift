// SPDX-License-Identifier: BSD-3-Clause

/// What the OS answers to `_OSI` (ACPI 6.5 §5.7.2). Firmware is written
/// and tested against Windows, and branches on which Windows it runs
/// under, so an OS that wants the firmware's tested paths claims the
/// Windows interface strings Microsoft documents, as Linux does, and the
/// feature strings ACPI defines. It never claims "Linux".
public enum OSInterfaces {
  static func bytes(_ s: StaticString) -> [UInt8] { unsafe s.withUTF8Buffer { unsafe Array($0) } }

  public static let windows: [[UInt8]] = [
    bytes("Windows 2000"), bytes("Windows 2001"), bytes("Windows 2001 SP1"), bytes("Windows 2001.1"),
    bytes("Windows 2001 SP2"), bytes("Windows 2001.1 SP1"), bytes("Windows 2006"), bytes("Windows 2006.1"),
    bytes("Windows 2006 SP1"), bytes("Windows 2006 SP2"), bytes("Windows 2009"), bytes("Windows 2012"),
    bytes("Windows 2013"), bytes("Windows 2015"), bytes("Windows 2016"), bytes("Windows 2017"),
    bytes("Windows 2017.2"), bytes("Windows 2018"), bytes("Windows 2018.2"), bytes("Windows 2019"),
    bytes("Windows 2020"), bytes("Windows 2021"), bytes("Windows 2022"),
  ]

  /// Feature strings (§5.7.2).
  public static let features: [[UInt8]] = [
    bytes("Module Device"), bytes("Processor Device"), bytes("3.0 Thermal Model"), bytes("3.0 _SCP Extensions"),
    bytes("Processor Aggregator Device"),
  ]

  /// Whether the default policy claims `name`.
  public static func claims(_ name: [UInt8]) -> Bool { windows.contains(name) || features.contains(name) }
}
