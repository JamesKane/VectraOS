// SPDX-License-Identifier: BSD-3-Clause

/// A method's ordinal: the 64-bit FNV-1a hash of `"<protocol id>.<method>"`
/// in UTF-8, with the top bit cleared (reserved for ordinals the system
/// defines). The `@IPCProtocol` macro and `idlc` both compute it this way,
/// and both reject a protocol in which two methods' ordinals collide.
///
/// FNV-1a is from Fowler, Noll and Vo's published description: offset basis
/// 0xcbf29ce484222325, prime 0x100000001b3.
public func methodOrdinal(_ name: Span<UInt8>) -> UInt64 {
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for i in name.indices {
    hash ^= UInt64(name[i])
    hash &*= 0x0000_0100_0000_01b3
  }
  return hash & ~(1 << 63)
}
