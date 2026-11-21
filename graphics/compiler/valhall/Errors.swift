// SPDX-License-Identifier: BSD-3-Clause

// The errors in words, for messages (Embedded Swift has no reflection to do
// it for us).

extension EncodeError {
  /// The error in words.
  public var description: String {
    switch self {
    case .fieldOverflow(let f): "the value of " + f + " does not fit its bits"
    case .unknownValue(let f): "the value of " + f + " is not one of its names"
    case .reservedFlow: "the flow value is reserved"
    case .badPage: "the FAU page is not 0 to 3"
    case .badCount(let f): "the count " + f + " is out of range"
    case .misaligned(let f): "the distance " + f + " is not a multiple of 8 bytes"
    case .wrongArch: "the instruction does not exist on the arch"
    }
  }
}

extension DecodeError {
  /// The error in words.
  public var description: String {
    switch self {
    case .reservedBit: "bit 63 is set"
    case .noInstruction: "no instruction has these fixed bits"
    case .wrongArch: "the instruction does not exist on this arch"
    }
  }
}

extension AssembleError {
  /// The error in words.
  public var description: String {
    switch self {
    case .syntax(let s): s
    }
  }
}
