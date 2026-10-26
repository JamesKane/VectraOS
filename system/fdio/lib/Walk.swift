// SPDX-License-Identifier: BSD-3-Clause

// fdio's directory walk (M6g), what BSD's fts does (fts(3), which glibc
// has too, and FoundationEssentials walks trees with): each root, then
// each directory before its entries (FTS_D) and again after them (FTS_DP),
// depth first, files in between (FTS_F); a node that can't be stat'd is
// FTS_NS, a directory that can't be listed FTS_DNR in place of its
// FTS_DP. An entry's status comes with its directory's listing, one
// call a directory, not one an entry. With `noStat` (FTS_NOSTAT) the
// listing carries none and other entries are FTS_NSOK, as the listing
// still says what's a directory. `skip` (FTS_SKIP) on a directory just returned leaves its
// entries out. There are no links to follow or cycles to find. Natively
// the C interface is <fts.h> (system/fdio/native/Fts.swift).

/// What a walk's entry is: fts_info's values.
public enum WalkInfo: UInt16, Sendable {
  case directory = 1  // FTS_D
  case directoryNotRead = 4  // FTS_DNR
  case directoryAfter = 6  // FTS_DP
  case error = 7  // FTS_ERR
  case file = 8  // FTS_F
  case noStat = 10  // FTS_NS
  case noStatAsked = 11  // FTS_NSOK
}

/// One entry of a walk.
public struct WalkEntry: Sendable {
  /// The root as given, or the path through it to this entry.
  public var path: String
  /// The root as given, or this entry's name in its directory.
  public var name: String
  /// 0 for a root, 1 for its entries, and so on.
  public var level: Int
  public var info: WalkInfo
  /// For FTS_NS, FTS_DNR and FTS_ERR: why.
  public var errno: Int32
  /// What stat said, unless it wasn't asked (or failed).
  public var status: FileStatus?
}

public final class Walk: @unchecked Sendable {
  enum Task {
    /// `status`: what the parent's listing said, if it said.
    case visit(path: String, name: String, level: Int, isDirectory: Bool?, status: FileStatus?)
    case expand(WalkEntry)
    case after(WalkEntry)
  }

  let noStat: Bool
  let order: ((WalkEntry, WalkEntry) -> Bool)?
  var tasks: [Task] = []
  /// The directory just returned (FTS_D), until the next call.
  var lastDirectory: WalkEntry?
  var skipping = false

  /// A walk of `roots` (paths as given), entries in each directory sorted
  /// by `order` if given, else in the listing's order.
  public init(_ roots: [String], noStat: Bool = false, order: ((WalkEntry, WalkEntry) -> Bool)? = nil) {
    self.noStat = noStat
    self.order = order
    var visits = roots.map { WalkEntry(path: $0, name: $0, level: 0, info: .file, errno: 0, status: nil) }
    if let order { visits.sort(by: order) }
    tasks = visits.reversed().map { .visit(path: $0.path, name: $0.name, level: 0, isDirectory: nil, status: nil) }
  }

  /// FTS_SKIP: the directory just returned has its entries left out.
  public func skip() { if lastDirectory != nil { skipping = true } }

  /// The next entry, or nil when the walk is done.
  public func next() -> WalkEntry? {
    if let d = lastDirectory {
      lastDirectory = nil
      tasks.append(skipping ? .after(d) : .expand(d))
      skipping = false
    }
    while let task = tasks.popLast() {
      switch task {
      case .visit(let path, let name, let level, let isDirectory, let listed):
        var entry = WalkEntry(path: path, name: name, level: level, info: .file, errno: 0, status: nil)
        if noStat && level > 0 && isDirectory == false {
          entry.info = .noStatAsked
          return entry
        }
        let status = listed.map(Result<FileStatus, Errno>.success) ?? FDIO.status(path)
        switch status {
        case .failure(let e):
          entry.info = .noStat
          entry.errno = e.code
        case .success(let s):
          entry.status = s
          entry.info = s.isDirectory ? .directory : .file
          if s.isDirectory { lastDirectory = entry }
        }
        return entry
      case .expand(let d):
        // The listing carries each entry's status, so an entry is stat'd
        // by its path only where it didn't: a mount point's (id 0).
        switch FDIO.listing(d.path, fields: noStat ? 0 : FDIO.statusFields) {
        case .failure(let e):
          var failed = d
          failed.info = .directoryNotRead
          failed.errno = e.code
          return failed
        case .success(let (_, listed)):
          tasks.append(.after(d))
          var children: [WalkEntry] = []
          for e in listed {
            let path = d.path.utf8.last == 0x2F ? d.path + e.name : d.path + "/" + e.name
            let s = FileStatus(e)
            children.append(WalkEntry(path: path, name: e.name, level: d.level + 1,
                                      info: s.isDirectory ? .directory : .file, errno: 0,
                                      status: noStat || s.id == 0 ? nil : s))
          }
          if let order { children.sort(by: order) }
          for c in children.reversed() {
            tasks.append(.visit(path: c.path, name: c.name, level: c.level, isDirectory: c.info == .directory,
                                status: c.status))
          }
        }
      case .after(let d):
        var after = d
        after.info = .directoryAfter
        return after
      }
    }
    return nil
  }
}
