// SPDX-License-Identifier: BSD-3-Clause

// The codecs' records (M4h2): parsing and its errors, matching by content
// and by extension, conflicts, and the committed built-in index against
// every codecs/**/codec.manifest.

import Codecs
import Foundation
import Testing

func index(_ text: String) throws -> CodecIndex { try CodecIndex(text: text, file: "t") }

let two = """
  codec wav
  class audio
  type audio/wav
  extension wav
  magic 0 RIFF
  magic 8 WAVE
  codec flac
  class audio
  type audio/flac
  extension flac
  magic 0 fLaC
  codec png
  class image
  extension png
  magic 0 0x89504e470d0a1a0a
  """

@Test func recordsParseAndMatchByContentThenName() throws {
  let i = try index(two)
  #expect(i.codecs.map { $0.name } == ["wav", "flac", "png"])
  #expect(i.codecs[0].magic == [.init(offset: 0, bytes: Array("RIFF".utf8)), .init(offset: 8, bytes: Array("WAVE".utf8))])
  #expect(i.codecs[2].magic[0].bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  #expect(i.conflicts == [])
  let wav = Array("RIFF\0\0\0\0WAVEfmt ".utf8)
  #expect(i.match(wav)?.name == "wav")
  #expect(i.match(wav, name: "x.flac")?.name == "wav")  // content first
  #expect(i.match(Array("RIFF\0\0\0\0AVI ".utf8)) == nil)  // one magic of two isn't enough
  #expect(i.match(Array("junk".utf8), name: "song.flac")?.name == "flac")
  #expect(i.match(Array("junk".utf8), name: "song") == nil)
  #expect(i.match([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])?.codecClass == "image")
}

@Test func recordsFailLoudlyWithTheirLine() {
  func error(_ text: String) -> String {
    do throws(CodecIndexError) {
      _ = try CodecIndex(text: text, file: "t")
      return "parsed"
    } catch {
      return error.description
    }
  }
  #expect(error("class audio\n") == "t:1: 'codec' must come first")
  #expect(error("codec a\nclass audio\nmagic x RIFF\n") == "t:3: 'magic' takes an offset and bytes (text, or 0x and hex)")
  #expect(error("codec a\nclass audio\nmagic 0 0x123\n") == "t:3: 'magic' takes an offset and bytes (text, or 0x and hex)")
  #expect(error("codec a\nclass audio\nextension .wav\n") == "t:3: 'extension' takes one, no dot")
  #expect(error("codec a\nclass audio\ntype wav\n") == "t:3: 'type' takes a media type")
  #expect(error("codec a\nextension a\n") == "t:1: codec 'a' has no class")
  #expect(error("codec a\nclass audio\n") == "t:1: codec 'a' can't be recognized (no magic, no extension)")
  #expect(error("codec a\nclass audio\nextension a\nsniff 1\n") == "t:4: unknown directive 'sniff'")
}

@Test func sharedRecordsConflict() throws {
  let i = try index("""
    codec a
    class audio
    type audio/x
    extension x
    magic 0 AB
    codec b
    class audio
    type audio/x
    extension x
    magic 0 AB
    """)
  #expect(i.conflicts == ["t:1 and t:6: 'a' and 'b' both read audio/x", "t:1 and t:6: 'a' and 'b' both claim .x",
                          "t:1 and t:6: 'a' and 'b' have the same magic"])
  #expect(i.match(Array("ABCD".utf8)) == nil)  // two by content: neither
}

/// Every codecs/**/codec.manifest, sorted (td codecs' order).
func codecManifests(_ root: String) throws -> [(path: String, text: String)] {
  let all = try FileManager.default.subpathsOfDirectory(atPath: "\(root)/codecs")
  return try all.filter { $0.hasSuffix("codec.manifest") }.sorted().map {
    ("codecs/" + $0, try String(contentsOfFile: "\(root)/codecs/\($0)", encoding: .utf8))
  }
}

@Test func theBuiltInIndexIsCurrent() throws {
  var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
  parts.removeLast(3)  // codecs/tests/CodecsTests.swift
  let root = parts.joined(separator: "/")
  let manifests = try codecManifests(root)
  let committed = try String(contentsOfFile: "\(root)/codecs/lib/generated/BuiltIn.swift", encoding: .utf8)
  #expect(committed == CodecIndex.generatedSource(manifests), "regenerate: BuiltIn.swift")
  let builtIn = try index(builtInIndex)
  #expect(builtIn.conflicts == [])
  #expect(builtIn.codecs.map { $0.name } == manifests.map { m in try! index(m.text).codecs[0].name })
}
