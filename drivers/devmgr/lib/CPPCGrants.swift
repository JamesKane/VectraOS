// SPDX-License-Identifier: BSD-3-Clause

// The CPUs' desired-performance registers the SCMI agent may write for
// power(8) (D167): the registers `cpus` lists in memory, as the arguments
// the agent is started with.

public enum CPPCGrants {
  /// `--cppc=0x<address>/<bits>` for each distinct desired-performance
  /// register in `cpus`'s text (SystemMemory, 8 to 64 bits at bit 0), a
  /// line each, as the manifest's `arg` lines take them.
  public static func arguments(cpus: String) -> [String] {
    var out: [String] = []
    for line in cpus.utf8.split(separator: 0x0A) {
      let w = line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
      // <uid> <path> perf <lowest> <nonlinear> <nominal> <highest> mhz <low> <nominal> desired <space> <address> <width> <offset>
      guard w.count >= 15, w[2].utf8.elementsEqual("perf".utf8), w[10].utf8.elementsEqual("desired".utf8),
        w[11].utf8.elementsEqual("0".utf8), w[12].utf8.starts(with: "0x".utf8), w[14].utf8.elementsEqual("0".utf8),
        let width = UInt8(w[13]), [8, 16, 32, 64].contains(width)
      else { continue }
      let argument = "--cppc=" + w[12] + "/" + w[13]
      if !out.contains(where: { $0.utf8.elementsEqual(argument.utf8) }) { out.append(argument) }
    }
    return out
  }
}
