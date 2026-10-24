import CEFI
import Fmt

/// Why the loader gave up. Reported on the firmware console before exiting.
enum LoaderError: Error {
    /// A firmware call failed.
    case firmware(StaticString, EFI_STATUS)
    /// kernel.elf is missing or malformed.
    case kernel(StaticString)
    /// The machine or firmware state isn't one we can hand off from.
    case unsupported(StaticString, UInt64)
    /// The CPU lacks a feature of the arch's baseline (Baseline.swift).
    case baseline(StaticString)
}

extension LoaderError {
    func report(to out: some TextOutput) {
        out.write("croi loader: ")
        switch self {
        case .firmware(let what, let status):
            out.write(what)
            out.write(" failed: EFI status ")
            out.write(hex: UInt64(status))
        case .kernel(let what):
            out.write("bad kernel image: ")
            out.write(what)
        case .unsupported(let what, let detail):
            out.write("unsupported: ")
            out.write(what)
            out.write(" (")
            out.write(hex: detail)
            out.write(")")
        case .baseline(let missing):
            out.write("CPU below the ")
            out.write(Baseline.name)
            out.write(" baseline: no ")
            out.write(missing)
        }
        out.write("\n")
    }
}
