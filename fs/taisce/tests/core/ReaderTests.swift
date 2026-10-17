// SPDX-License-Identifier: BSD-3-Clause

// S1f: lock-free readers beside the writer.

import Glibc
import Synchronization
import Taisce
import TaisceHost
import Testing

func sharedFS(blocks: UInt64 = 16384) throws -> FileSystem<SharedMemoryDevice> {
  try FileSystem.format(SharedMemoryDevice(blocks: blocks), label: [], uuid: Array(1...16), now: 1)
}

/// Hands a reader to the thread that will own it.
final class ReaderBox: @unchecked Sendable {
  var reader: FileReader<SharedMemoryDevice>?
  init(_ reader: consuming FileReader<SharedMemoryDevice>) { self.reader = consume reader }
}

/// What the readers and the test share.
final class ReaderRun: Sendable {
  let done = Atomic<Bool>(false)
  let failures = Mutex<[String]>([])
  let reads = Atomic<Int>(0)
}

/// A file's contents at version `v`: one byte value throughout (four blocks
/// and a bit), so a read mixing two versions shows.
func versioned(_ v: Int) -> [UInt8] { [UInt8](repeating: UInt8(truncatingIfNeeded: v), count: 17_000) }

@Test func aSnapshotOutlivesTheWritesAndCommitsAfterIt() throws {
  var fs = try sharedFS(blocks: 4096)
  let f = try fs.create(1, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, versioned(1), now: 3)
  try fs.sync()
  guard var r = fs.reader() else { Issue.record("no reader"); return }
  try r.withSnapshot { (r: inout FileReader<SharedMemoryDevice>) throws(TaisceError) in
    // Everything after this snapshot frees what it sees, commits, and
    // writes new data wherever it can: none of it may land on what the
    // snapshot is reading.
    for v in 2..<8 {
      try fs.write(f, offset: 0, versioned(v), now: 4)
      try fs.sync()
    }
    let g = try fs.create(1, n("g"), .file, mode: 0o644, now: 5)
    try fs.write(g, offset: 0, [UInt8](repeating: 0xEE, count: 3_000_000), now: 5)
    try fs.sync()
    #expect(try r.read(f, offset: 0, count: 1 << 20) == versioned(1))
    #expect(throws: TaisceError.notFound) { try r.lookup(1, n("g")) }
  }
  // Once the reader leaves, the next snapshot has it all, and limbo drains.
  let after = try r.withSnapshot { (r: inout FileReader<SharedMemoryDevice>) throws(TaisceError) in
    try r.read(f, offset: 0, count: 1 << 20)
  }
  #expect(after == versioned(7))
  try fs.sync()
  try fs.sync()
  #expect(fs.engine.limboCount == 0)
  try fs.check()
}

@Test func readersSeeEveryOperationWholeWhileTheWriterRuns() throws {
  var fs = try sharedFS(blocks: 2048)  // small, so the allocator wraps and reuses blocks soon
  let files = 6, names = 40
  var inos: [UInt64] = []
  for i in 0..<files {
    inos.append(try fs.create(1, n("f\(i)"), .file, mode: 0o644, now: 2))
    try fs.write(inos[i], offset: 0, versioned(0), now: 2)
  }
  let dir = try fs.create(1, n("d"), .directory, mode: 0o755, now: 2)
  for i in 0..<names { _ = try fs.create(dir, n("n\(i)"), .file, mode: 0o644, now: 2) }
  // Nearly full: freed blocks come straight back, so one reused while a
  // reader can still see it would show (and the writer meets back-pressure).
  let filler = try fs.create(1, n("filler"), .file, mode: 0o644, now: 2)
  try fs.write(filler, offset: 0, [UInt8](repeating: 0xFF, count: 1150 * 4096), now: 2)
  let counter = try fs.create(1, n("counter"), .file, mode: 0o644, now: 2)
  try fs.setAttribute(counter, n("user:n"), .uint64(0), now: 2)
  try fs.sync()

  let run = ReaderRun()
  let readerCount = 4
  var threads: [pthread_t] = []
  for t in 0..<readerCount {
    // Tiny caches: reads go to the device, where a reused block would show.
    guard let reader = fs.reader(cacheNodes: 1, sharedNodes: 2, sharedBlocks: 2) else { Issue.record("no reader"); return }
    let box = ReaderBox(reader)
    let inos = inos
    threads.append(ToolSupport.spawn {
      var r = box.reader.take()!
      var last: UInt64 = 0
      var i = 0
      func fail(_ message: String) { run.failures.withLock { if $0.count < 10 { $0.append("reader \(t): \(message)") } } }
      while !run.done.load(ordering: .acquiring) {
        i += 1
        do throws(TaisceError) {
          try r.withSnapshot { (r: inout FileReader<SharedMemoryDevice>) throws(TaisceError) in
            // A file: one version, whole.
            let data = try r.read(inos[i % inos.count], offset: 0, count: 1 << 20)
            if data.count != 17_000 || data.contains(where: { $0 != data[0] }) {
              fail("file \(i % inos.count) torn: \(data.count) bytes, first \(data.first ?? 0)")
            }
            // The directory: renames move names, never add or drop one.
            let listed = try r.list(dir)
            if listed.count != names { fail("directory has \(listed.count) names") }
            for (e, _) in listed.prefix(3) where try r.lookup(dir, e.name) != e.ino { fail("lookup disagrees") }
            // Sometimes a long look: the writer frees, commits and
            // reallocates meanwhile, and the snapshot must hold still.
            if i % 8 == 0 {
              let other = inos[(i + 1) % inos.count]
              let before = try r.read(other, offset: 0, count: 1 << 20)
              usleep(20_000)
              if try r.read(other, offset: 0, count: 1 << 20) != before { fail("a snapshot changed") }
            }
            // The counter only goes up.
            guard case .uint64(let now)? = try r.attribute(counter, n("user:n")) else { return fail("no counter") }
            if now < last { fail("counter went back: \(now) after \(last)") }
            last = now
          }
          run.reads.add(1, ordering: .relaxed)
        } catch {
          fail("\(error)")
        }
      }
    })
  }
  var rng = SplitMix(state: 31)
  var current = [Int](repeating: 0, count: names)
  var full = 0
  for k in 1...3000 {
    do throws(TaisceError) {
      switch rng.below(10) {
      case 0..<5:
        try fs.write(inos[rng.below(files)], offset: 0, versioned(rng.below(256)), now: 3)
      case 5..<7:
        let i = rng.below(names)
        try fs.rename(dir, n("n\(i)" + (current[i] == 0 ? "" : "-\(current[i])")), dir, n("n\(i)-\(current[i] + 1)"),
                      now: 3)
        current[i] += 1
      case 7:
        try fs.setAttribute(counter, n("user:n"), .uint64(UInt64(k)), now: 3)
      case 8 where k % 2 == 0:
        try fs.fsync()
      default:
        try fs.sync()
      }
    } catch .noSpace {
      full += 1
    }
  }
  run.done.store(true, ordering: .releasing)
  for t in threads { ToolSupport.join(t) }
  run.failures.withLock { for f in $0 { Issue.record(Comment(rawValue: f)) } }
  let reads = run.reads.load(ordering: .relaxed)
  #expect(reads > 1000, "the readers ran: \(reads)")
  #expect(full == 0, "out of space \(full) times: the file system reclaims what's freed")
  try fs.sync()
  try fs.sync()
  #expect(fs.engine.limboCount == 0)
  try fs.check()
}

final class EpochRun: Sendable {
  let epochs = EpochManager()
  let backwards = Atomic<Int>(0)
}

@Test func theEpochNeverGoesBackEvenAdvancedFromManyThreads() {
  let run = EpochRun()
  var threads: [pthread_t] = []
  for _ in 0..<4 {
    threads.append(ToolSupport.spawn {
      var last: UInt64 = 0
      for _ in 0..<200_000 {
        run.epochs.tryAdvance()
        let now = run.epochs.current
        if now < last { run.backwards.add(1, ordering: .relaxed) }
        last = now
      }
    })
  }
  for t in threads { ToolSupport.join(t) }
  #expect(run.backwards.load(ordering: .relaxed) == 0)
}
