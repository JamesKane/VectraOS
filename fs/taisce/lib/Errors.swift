// SPDX-License-Identifier: BSD-3-Clause

/// What can go wrong in Taisce. Tier 0: no strings, so every case says
/// what it is by itself.
public enum TaisceError: Error, Equatable, Sendable {
  /// The device failed (errno on the host).
  case io(Int32)
  /// A block number past the end of the device, or a buffer that isn't
  /// whole blocks.
  case outOfRange
  /// No superblock copy is valid: not a Taisce volume, or both copies are damaged.
  case notAVolume
  /// A version this code doesn't read.
  case unsupportedVersion(UInt32)
  /// The device is too small for the layout asked for.
  case tooSmall
  /// There isn't enough free space.
  case noSpace
  /// A commit failed on the device, so nothing more is written until the
  /// volume is mounted again (which finds the last commit that completed).
  case readOnly
  /// On-disk structures disagree (what was found is the case's name).
  case corrupt(Corruption)
  /// A key or value larger than a node allows (BTree.maxKey, maxValue),
  /// or a transaction group larger than the log.
  case tooLarge
  /// A delta for a key that isn't there.
  case missingKey
  /// A delta past the end of the value it changes.
  case badDelta
  // The file system's, as POSIX names them.
  case notFound  // ENOENT
  case exists  // EEXIST
  case notDirectory  // ENOTDIR
  case isDirectory  // EISDIR
  case notEmpty  // ENOTEMPTY
  case nameTooLong  // ENAMETOOLONG
  case invalid  // EINVAL: a bad name, or a directory moved into itself
  /// A query that doesn't parse, and the byte where it stopped making sense.
  case badQuery(UInt32)
  /// A query no index can serve: declare one, or ask for a scan.
  case needsIndex
  /// A live query's place is no longer in the journal: run it again.
  case journalTrimmed
}

public enum Corruption: Equatable, Sendable {
  case superblockLayout
  case bitmapSize
  /// The bitmap a superblock names doesn't have the checksum it records.
  case bitmapChecksum
  case node
  /// A block whose bytes don't have the checksum its pointer records.
  case checksum(UInt64)
  case catalog
  case inode
  case directory
  case extent
  case attribute
  case index
  case journal
  /// The file system's own invariants (FileSystem.check).
  case fileSystem(FileSystemFault)
  /// Blocks in use that no tree holds, or held twice.
  case leakedBlocks
  /// A tree breaks an invariant (BTree.check says which).
  case tree(TreeFault)
}

public enum TreeFault: Equatable, Sendable {
  case keysOutOfOrder
  case keyOutsideItsBounds
  case uneven  // leaves at different depths
  case underfull
  case overfull
  case childCount
  case blockNotAllocated
}

public enum FileSystemFault: Equatable, Sendable {
  case danglingEntry  // names an inode that isn't there
  case wrongType  // an entry's type isn't its inode's
  case linkCount
  case parent
  case unreachable  // an inode no name or orphan holds
  case sharedBlock  // two extents, or an extent and a node, on one block
  case extentPastEnd
  case indexMismatch  // an index isn't what the attributes and fields say
  case backlink  // a node's record of its names doesn't match the directories
}
