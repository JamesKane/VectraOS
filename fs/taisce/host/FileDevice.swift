// SPDX-License-Identifier: BSD-3-Clause

// A volume in a file or a block device on the host: an image for
// mkfs.taisce, taisce-fuse and the tests.

import Glibc
import Taisce

public final class FileHandle: Sendable {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  deinit { close(fd) }
}

public struct FileDevice: ConcurrentReadable {
  public let blockSize = Layout.blockSize
  public let blockCount: UInt64
  let file: FileHandle

  /// Opens `path`. With `blocks`, makes (or resizes) it to that many blocks.
  public init(path: String, blocks: UInt64? = nil) throws(TaisceError) {
    let fd = open(path, O_RDWR | O_CLOEXEC | (blocks == nil ? 0 : O_CREAT), 0o644)
    guard fd >= 0 else { throw .io(errno) }
    file = FileHandle(fd)
    if let blocks {
      guard ftruncate(fd, off_t(blocks) * off_t(Layout.blockSize)) == 0 else { throw .io(errno) }
      blockCount = blocks
    } else {
      var st = stat()
      guard fstat(fd, &st) == 0 else { throw .io(errno) }
      blockCount = UInt64(st.st_size) / UInt64(Layout.blockSize)
    }
  }

  public mutating func read(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    try readConcurrently(block, count: count)
  }

  /// pread: any thread, any time (S1f's readers).
  public func readConcurrently(_ block: UInt64, count: Int) throws(TaisceError) -> [UInt8] {
    guard count >= 0, block + UInt64(count) <= blockCount else { throw .outOfRange }
    var bytes = [UInt8](repeating: 0, count: count * blockSize)
    let wanted = bytes.count
    let n = bytes.withUnsafeMutableBytes { pread(file.fd, $0.baseAddress, wanted, off_t(block) * off_t(blockSize)) }
    guard n == wanted else { throw .io(n < 0 ? errno : EIO) }
    return bytes
  }

  public mutating func write(_ block: UInt64, _ bytes: [UInt8]) throws(TaisceError) {
    guard bytes.count % blockSize == 0, block + UInt64(bytes.count / blockSize) <= blockCount else {
      throw .outOfRange
    }
    let n = bytes.withUnsafeBytes { pwrite(file.fd, $0.baseAddress, bytes.count, off_t(block) * off_t(blockSize)) }
    guard n == bytes.count else { throw .io(n < 0 ? errno : EIO) }
  }

  public mutating func flush() throws(TaisceError) {
    guard fdatasync(file.fd) == 0 else { throw .io(errno) }
  }
}
