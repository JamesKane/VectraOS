// SPDX-License-Identifier: BSD-3-Clause

import Mutate
import Testing

let sample = """
  # a comment
  suite RingCheckTests
  measure ring check:

  mutant swift-publish-relaxed
  in lib/ring/Ring/Ring.swift
  find order: .releasing)
  with order: .relaxed)
  why the producer's publish must release its slots
  mutant drops-a-line
  in a/b.swift
  find x\\ny\\tz\\\\
  with
  why a line goes
  survives nothing reads it
  """

@Test func aMutantsFileIsParsed() {
  let (file, problems) = parseMutants(sample)
  #expect(problems.isEmpty)
  #expect(file?.suite == "RingCheckTests" && file?.measure == "ring check:")
  #expect(file?.mutants.count == 2)
  let first = file?.mutants[0]
  #expect(first?.name == "swift-publish-relaxed" && first?.path == "lib/ring/Ring/Ring.swift")
  #expect(first?.find == "order: .releasing)" && first?.with == "order: .relaxed)")
  #expect(first?.survives == nil && first?.line == 5)
}

@Test func escapesAreRead() {
  let (file, _) = parseMutants(sample)
  #expect(file?.mutants[1].find == "x\ny\tz\\")
  #expect(unescape("a\\qb") == nil && unescape("a\\") == nil)
}

@Test func withMayBeEmptyAndSurvivesIsKept() {
  let (file, _) = parseMutants(sample)
  #expect(file?.mutants[1].with == "")
  #expect(file?.mutants[1].survives == "nothing reads it")
}

@Test func errorsNameTheirLine() {
  let (file, problems) = parseMutants("suite S\nmutant m\nin p\nfind x\nwhy y\nbogus 1\n", file: "m")
  #expect(file == nil)
  #expect(problems.contains("m:6: unknown keyword `bogus`"))
  #expect(problems.contains("m:2: mutant m has no `with`"))
  #expect(parseMutants("mutant m\n").1.contains("mutants:1: no `suite`"))
  #expect(parseMutants("suite S\nin p\n").1 == ["mutants:2: `in` outside a mutant"])
  #expect(parseMutants("suite S\nmutant a\nin p\nin q\n").1.contains("mutants:4: `in` twice in mutant a"))
  #expect(parseMutants("suite S\nmutant a\nin p\nfind \\q\n").1.contains { $0.hasPrefix("mutants:4:") })
}

@Test func anEditMustApplyExactlyOnce() {
  #expect(applyEdit("a b c", find: "b", with: "X") == .success("a X c"))
  #expect(applyEdit("a b c", find: "b", with: "") == .success("a  c"))
  #expect(applyEdit("a b c", find: "z", with: "X") == .failure(.missing))
  #expect(applyEdit("b b b", find: "b", with: "X") == .failure(.ambiguous(3)))
  #expect(applyEdit("a\nb\n", find: "a\nb", with: "c") == .success("c\n"))
}

@Test func theEndingsAreTold() {
  let c = ["ring check: 10 states"]
  let other = ["ring check: 9 states"]
  #expect(classify(passed: false, measure: [], control: c, measured: true, survives: nil) == .caught)
  #expect(classify(passed: false, measure: c, control: c, measured: true, survives: "r") == .caught)
  #expect(classify(passed: true, measure: c, control: c, measured: true, survives: nil) == .didNothing)
  #expect(classify(passed: true, measure: c, control: c, measured: true, survives: "r") == .didNothing)
  #expect(classify(passed: true, measure: other, control: c, measured: true, survives: nil) == .survived)
  #expect(classify(passed: true, measure: other, control: c, measured: true, survives: "r") == .survivedExplained)
  #expect(classify(passed: true, measure: [], control: [], measured: false, survives: nil) == .survived)
  #expect(classify(passed: true, measure: [], control: [], measured: false, survives: "r") == .survivedExplained)
  #expect(Ending.caught.acceptable && Ending.survivedExplained.acceptable)
  #expect(!Ending.survived.acceptable && !Ending.didNothing.acceptable)
}

@Test func colourEscapesAreStripped() {
  #expect(plain("\u{1B}[92m✔\u{1B}[0m Test x passed\u{1B}[90m") == "✔ Test x passed")
  #expect(plain("no escapes") == "no escapes")
}

@Test func measureLinesAndTheFirstFailureAreFound() {
  let out = "noise\n  ring check: a 5 states\nring check: b 6 states\nring checks no\n✘ Test x() failed after 0.1s\n"
  #expect(measureLines(out, prefix: "ring check:") == ["ring check: a 5 states", "ring check: b 6 states"])
  #expect(measureLines(out, prefix: nil) == [])
  #expect(firstFailure(out) == "✘ Test x() failed after 0.1s")
  #expect(firstFailure("a\nb\n") == "b" && firstFailure("") == "no output")
}
