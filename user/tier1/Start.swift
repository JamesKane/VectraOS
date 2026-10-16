// SPDX-License-Identifier: BSD-3-Clause

// bin/swift-start: as little as a full Swift program does (M6e's start and
// size budgets, tests/native/Tier1Bench.swift): the runtime's start (its
// metadata registered by swiftrt.o, its initializers) and an exit.

@main struct Start {
  static func main() {}
}
