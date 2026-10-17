// SPDX-License-Identifier: BSD-3-Clause

// A cpu session on the wire (D77), shared by the node's cpu server and
// vx cpu, the terminal: TCP to port 17019 (Plan 9's rcpu), sealed by
// Noise IK with the prologue `cpu`, its payloads empty, the terminal the
// initiator. The terminal's first message is the command record, the
// command for rc -c (empty for an interactive rc):
//
//     size[4] command[size]      little-endian, as 9P's integers
//
// After it the roles turn round: the terminal serves its tree in 9P2000
// and the node is its client, mounting it at /mnt/term.

public enum CpuProtocol {
  /// The port the cpu server announces: Plan 9's rcpu, `tcp!*!17019`.
  public static let port = 17019
  /// The handshake's prologue: a 9gate handshake can't be passed off as a
  /// cpu one, nor one as the other.
  public static let prologue: [UInt8] = Array("cpu".utf8)
  /// The longest command the record carries.
  public static let maxCommand = 8192

  /// The command record: its size, then its bytes.
  public static func record(_ command: [UInt8]) -> [UInt8]? {
    guard command.count <= maxCommand else { return nil }
    let n = UInt32(command.count)
    return [UInt8(n & 0xff), UInt8(n >> 8 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 24)] + command
  }

  /// The command in a record that starts `bytes`, and how many bytes the
  /// record took; nil until it is whole. `invalid` if it can't be one.
  public static func command(_ bytes: [UInt8]) -> Parsed {
    guard bytes.count >= 4 else { return .partial }
    let n = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
    guard n <= maxCommand else { return .invalid }
    guard bytes.count >= 4 + n else { return .partial }
    return .whole(Array(bytes[4..<4 + n]), used: 4 + n)
  }

  public enum Parsed: Equatable, Sendable {
    case partial
    case invalid
    case whole([UInt8], used: Int)
  }
}
