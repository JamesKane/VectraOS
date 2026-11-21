// SPDX-License-Identifier: BSD-3-Clause

// The capabilities of the ALU coverage: subgroup operations, the narrow types' storage and float atomics.

/// The opcodes of the ALU coverage: OpGroupNonUniform* (333 to 366) and the float atomics OpAtomicFAddEXT (6035),
/// OpAtomicFMinEXT (5614) and OpAtomicFMaxEXT (5615); each has a type and a result.
func aluOpInfo(_ op: UInt16) -> OpInfo? {
  let names: [UInt16: String] = [
    333: "OpGroupNonUniformElect", 334: "OpGroupNonUniformAll", 335: "OpGroupNonUniformAny", 336: "OpGroupNonUniformAllEqual",
    337: "OpGroupNonUniformBroadcast", 338: "OpGroupNonUniformBroadcastFirst", 339: "OpGroupNonUniformBallot",
    340: "OpGroupNonUniformInverseBallot", 341: "OpGroupNonUniformBallotBitExtract", 342: "OpGroupNonUniformBallotBitCount",
    343: "OpGroupNonUniformBallotFindLSB", 344: "OpGroupNonUniformBallotFindMSB", 345: "OpGroupNonUniformShuffle",
    346: "OpGroupNonUniformShuffleXor", 347: "OpGroupNonUniformShuffleUp", 348: "OpGroupNonUniformShuffleDown",
    349: "OpGroupNonUniformIAdd", 350: "OpGroupNonUniformFAdd", 351: "OpGroupNonUniformIMul", 352: "OpGroupNonUniformFMul",
    353: "OpGroupNonUniformSMin", 354: "OpGroupNonUniformUMin", 355: "OpGroupNonUniformFMin", 356: "OpGroupNonUniformSMax",
    357: "OpGroupNonUniformUMax", 358: "OpGroupNonUniformFMax", 359: "OpGroupNonUniformBitwiseAnd",
    360: "OpGroupNonUniformBitwiseOr", 361: "OpGroupNonUniformBitwiseXor", 362: "OpGroupNonUniformLogicalAnd",
    363: "OpGroupNonUniformLogicalOr", 364: "OpGroupNonUniformLogicalXor", 365: "OpGroupNonUniformQuadBroadcast",
    366: "OpGroupNonUniformQuadSwap", 5614: "OpAtomicFMinEXT", 5615: "OpAtomicFMaxEXT", 6035: "OpAtomicFAddEXT",
  ]
  guard let n = names[op] else { return nil }
  return OpInfo(name: n, hasType: true, hasResult: true, refused: false)
}

extension Supported {
  /// GroupNonUniform (61) with Vote, Arithmetic, Ballot, Shuffle, ShuffleRelative, Clustered and Quad (62 to 68);
  /// StorageBuffer16BitAccess and UniformAndStorageBuffer16BitAccess (4433, 4434), StoragePushConstant16 (4435), the 8 bit
  /// forms (4448 to 4450); the float atomics' AtomicFloat16AddEXT, AtomicFloat32AddEXT, AtomicFloat16MinMaxEXT and
  /// AtomicFloat32MinMaxEXT (6095, 6033, 5616, 5612).
  static let aluCapabilities: [UInt32] = [
    61, 62, 63, 64, 65, 66, 67, 68, 4433, 4434, 4435, 4448, 4449, 4450, 6095, 6033, 5616, 5612,
  ]
}
