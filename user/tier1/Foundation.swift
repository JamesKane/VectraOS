// SPDX-License-Identifier: BSD-3-Clause

// FoundationEssentials on croi (M6g): swift-foundation's essentials built
// for the *-vectraos triple (D47). JSON and property lists through
// Codable, Data and base64, URLs, dates (ISO 8601, the Gregorian
// calendar), Decimal, UUIDs, and ProcessInfo. Exits 0 if all held.
// FileManager's checks come back with fdio (roadmap V2 item 3), whose
// files they need: todhchai's ran them on a volume at /data.

import FoundationEssentials
import VectraOSLibc

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) {
  if !ok {
    print("foundation-test: FAILED: \(what)")
    failures += 1
  }
}

struct Song: Codable, Equatable {
  var title: String
  var year: Int
  var rating: Double?
  var tags: [String]
  var added: Date
}

@main struct FoundationTest {
  static func main() throws {
    // Codable: JSON and both property list formats.
    let song = Song(title: "Ag Iascaireacht", year: 1993, rating: 4.5, tags: ["trad", "reel"],
                    added: Date(timeIntervalSince1970: 749_000_000))
    let json = try JSONEncoder().encode(song)
    check(try JSONDecoder().decode(Song.self, from: json) == song, "JSON round trip")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let sorted = String(decoding: try encoder.encode(song), as: UTF8.self)
    check(sorted == #"{"added":"1993-09-25T23:33:20Z","rating":4.5,"tags":["trad","reel"],"title":"Ag Iascaireacht","year":1993}"#,
          "sorted JSON: \(sorted)")
    for format in [PropertyListDecoder.PropertyListFormat.xml, .binary] {
      let plistEncoder = PropertyListEncoder()
      plistEncoder.outputFormat = format
      let plist = try plistEncoder.encode(song)
      check(try PropertyListDecoder().decode(Song.self, from: plist) == song, "property list round trip (\(format))")
    }

    // Data and base64.
    let bytes = Data((0..<256).map { UInt8($0) })
    check(Data(base64Encoded: bytes.base64EncodedString()) == bytes, "base64")
    check(Data("hello".utf8).base64EncodedString() == "aGVsbG8=", "base64's text")

    // URLs.
    let url = URL(string: "https://example.org:8443/a/b/../c?x=1&y=two#frag")!
    check(url.host() == "example.org" && url.port == 8443 && url.fragment() == "frag", "URL parts")
    check(url.standardized.path() == "/a/c", "URL standardized: \(url.standardized.path())")
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    check(components.queryItems?.first(where: { $0.name == "y" })?.value == "two", "query items")
    components.queryItems = [URLQueryItem(name: "q", value: "a b&c")]
    check(components.percentEncodedQuery == "q=a%20b%26c", "query encoding: \(components.percentEncodedQuery ?? "nil")")
    check(URL(filePath: "/data/x/y.txt").deletingLastPathComponent().path() == "/data/x/", "file URLs")

    // Dates and the Gregorian calendar.
    let date = Date(timeIntervalSince1970: 1_000_000_000)
    check(date.description == "2001-09-09 01:46:40 +0000", "Date.description: \(date.description)")
    check(date.formatted(.iso8601) == "2001-09-09T01:46:40Z", "ISO 8601: \(date.formatted(.iso8601))")
    check(try Date("2001-09-09T01:46:40Z", strategy: .iso8601) == date, "ISO 8601 parsed")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    check(parts.year == 2001 && parts.month == 9 && parts.day == 9 && parts.weekday == 1, "calendar: \(parts)")
    let later = calendar.date(byAdding: .month, value: 6, to: date)!
    check(calendar.component(.month, from: later) == 3, "a date six months on")

    // Decimal and UUIDs.
    let price = Decimal(string: "19.99")! * 3
    check(price == Decimal(string: "59.97")!, "Decimal: \(price)")
    let id = UUID()
    check(UUID(uuidString: id.uuidString) == id && id != UUID(), "UUID")
    check(UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!.uuidString == "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
          "a UUID parsed")
    check(UUID(uuidString: "not-a-uuid") == nil, "a bad UUID")

    // ProcessInfo.
    let info = ProcessInfo.processInfo
    check(info.processIdentifier > 0, "processIdentifier")
    check(info.arguments.first == "bin/foundation-test", "arguments: \(info.arguments)")
    check(info.hostName == "localhost", "hostName")
    check(info.activeProcessorCount >= 1, "activeProcessorCount")

    print("foundation-test: \(failures == 0 ? "passed" : "FAILED")")
    exit(failures == 0 ? 0 : 1)
  }
}
