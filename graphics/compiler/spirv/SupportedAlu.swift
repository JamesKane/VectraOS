// SPDX-License-Identifier: BSD-3-Clause

// The capabilities of the ALU coverage: subgroup operations, the narrow types' storage and float atomics.

extension Supported {
  /// GroupNonUniform (61) with Vote, Arithmetic, Ballot, Shuffle, ShuffleRelative, Clustered and Quad (62 to 68);
  /// StorageBuffer16BitAccess and UniformAndStorageBuffer16BitAccess (4433, 4434), StoragePushConstant16 (4435), the 8 bit
  /// forms (4448 to 4450); the float atomics' AtomicFloat16AddEXT, AtomicFloat32AddEXT, AtomicFloat16MinMaxEXT and
  /// AtomicFloat32MinMaxEXT (6095, 6033, 5616, 5612).
  static let aluCapabilities: [UInt32] = [
    61, 62, 63, 64, 65, 66, 67, 68, 4433, 4434, 4435, 4448, 4449, 4450, 6095, 6033, 5616, 5612,
  ]
}
