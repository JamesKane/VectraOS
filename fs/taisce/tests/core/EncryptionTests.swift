// SPDX-License-Identifier: BSD-3-Clause

// S2: encrypted volumes. What's written reads back through the key and
// nowhere else; nothing of it shows on the disk; a changed or moved
// block, or a superblock changed without the key, is caught; the keybag's
// passphrases open the volume and its slots change by a commit alone.

@testable import Taisce
import TDCrypto
import Testing

let volumeKey = VolumeKey((0..<32).map { UInt8($0 * 7 + 1) })

func sealed(_ disk: MemoryDevice, _ key: VolumeKey? = volumeKey) -> SealedDevice<MemoryDevice> {
  SealedDevice(disk, sealing: key.map { Sealing($0) })
}

func encryptedFS(blocks: UInt64 = 8192) throws -> FileSystem<SealedDevice<MemoryDevice>> {
  let slot = Keybag.Slot.passphrase(n("correct horse"), key: volumeKey, salt: Array(repeating: 1, count: 32),
                                    iterations: 3)
  return try FileSystem.format(sealed(MemoryDevice(blocks: blocks)), label: n("secret"), uuid: Array(1...16),
                               now: 1, keybag: Keybag([slot]))
}

/// Whether `needle` appears anywhere in `haystack`.
func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
  guard needle.count <= haystack.count else { return false }
  return (0...(haystack.count - needle.count)).contains { i in
    haystack[i] == needle[0] && Array(haystack[i..<(i + needle.count)]) == needle
  }
}

@Test func anEncryptedVolumeReadsBackAndHidesItsBytes() throws {
  var fs = try encryptedFS()
  let f = try fs.create(root, n("plans-for-tuesday"), .file, mode: 0o600, now: 2)
  let secret = Array((0..<300).map { _ in Array("attack at dawn ".utf8) }.joined())
  try fs.write(f, offset: 0, secret, now: 2)
  try fs.setAttribute(f, n("user:note"), .string(n("eyes only")), now: 2)
  try fs.fsync()  // into the intent log too
  let logged = fs.engine.store.volume.device.base
  try fs.sync()
  _ = try fs.check()
  let disk = fs.engine.store.volume.device.base
  for image in [logged, disk] {
    for word in ["attack at dawn", "plans-for-tuesday", "eyes only"] {
      #expect(!contains(image.storage, n(word)), "\(word) is on the disk")
    }
  }
  // The label stays plain: the superblock is.
  #expect(contains(disk.storage, n("secret")))
  for image in [logged, disk] {
    var again = try FileSystem.mount(sealed(image))
    let ino = try again.lookup(root, n("plans-for-tuesday"))
    #expect(try again.read(ino, offset: 0, count: secret.count) == secret)
    #expect(try again.attribute(ino, n("user:note")) == .string(n("eyes only")))
    _ = try again.check()
  }
}

@Test func aVolumeOpensOnlyWithItsKey() throws {
  var fs = try encryptedFS()
  try fs.sync()
  let disk = fs.engine.store.volume.device.base
  #expect(throws: TaisceError.locked) { _ = try FileSystem.mount(sealed(disk, nil)) }
  // Another key authenticates none of its superblocks.
  #expect(throws: TaisceError.notAVolume) {
    _ = try FileSystem.mount(sealed(disk, VolumeKey(Array(repeating: 9, count: 32))))
  }
  // A plain volume isn't opened with a key.
  var plain = try newFS()
  try plain.sync()
  #expect(throws: TaisceError.invalid) { _ = try FileSystem.mount(sealed(plain.engine.store.volume.device)) }
  // The keybag, read without the key, gives it to the passphrase alone.
  var probe = sealed(disk, nil)
  let keybag = try #require(try Volume.newestSuperblock(&probe).keybag)
  #expect(keybag.unlock(n("correct horse")) == volumeKey)
  #expect(keybag.unlock(n("correct horsf")) == nil)
  #expect(keybag.unlock([]) == nil)
}

@Test func aChangedOrMovedBlockIsCaught() throws {
  var fs = try encryptedFS()
  let f = try fs.create(root, n("f"), .file, mode: 0o644, now: 2)
  try fs.write(f, offset: 0, pattern(3, 3 * 4096), now: 2)
  try fs.sync()
  var c = Changes()
  let extents = try fs.extents(f, 0, 3, &c)
  let extent = try #require(extents.first)
  #expect(extent.count == 3)
  let disk = fs.engine.store.volume.device.base
  let block = Int(extent.physical)
  // One bit of ciphertext changes a whole 16-byte block of plaintext.
  var flipped = disk
  flipped.storage[block * 4096 + 100] ^= 1
  var a = try FileSystem.mount(sealed(flipped))
  #expect(throws: TaisceError.corrupt(.checksum(UInt64(block)))) { _ = try a.read(f, offset: 0, count: 4096) }
  // A block copied over another decrypts under the wrong tweak.
  var moved = disk
  moved.storage.replaceSubrange((block * 4096)..<((block + 1) * 4096),
                                with: disk.storage[((block + 1) * 4096)..<((block + 2) * 4096)])
  var b = try FileSystem.mount(sealed(moved))
  #expect(throws: TaisceError.corrupt(.checksum(UInt64(block)))) { _ = try b.read(f, offset: 0, count: 4096) }
}

@Test func aSuperblockChangedWithoutTheKeyIsPassedOver() throws {
  var fs = try encryptedFS()
  _ = try fs.create(root, n("first"), .file, mode: 0o644, now: 2)
  try fs.sync()
  _ = try fs.create(root, n("second"), .file, mode: 0o644, now: 3)
  try fs.sync()
  let disk = fs.engine.store.volume.device.base
  var probe = sealed(disk, nil)
  let newest = try Volume.newestSuperblock(&probe)
  // Rewrite the newest superblock's copies with a changed field and a
  // good plain checksum, as anyone can: the key's authenticator fails, so
  // the group before is mounted.
  var forged = disk
  for slot in [newest.layout.headSlot(txg: newest.txg), newest.layout.footerSlot(txg: newest.txg)] {
    var b = Array(disk.storage[(Int(slot) * 4096)..<((Int(slot) + 1) * 4096)])
    b[88] ^= 1  // nextInode
    let c = Checksum(of: Array(b[..<4080]), key: nil)
    b.put(c.a, at: 4080)
    b.put(c.b, at: 4088)
    #expect(try Superblock.decode(b) != nil)
    forged.storage.replaceSubrange((Int(slot) * 4096)..<((Int(slot) + 1) * 4096), with: b)
  }
  var mounted = try FileSystem.mount(sealed(forged))
  #expect(mounted.engine.store.volume.superblock.txg < newest.txg)
  #expect(throws: TaisceError.notFound) { _ = try mounted.lookup(root, n("second")) }
  _ = try mounted.lookup(root, n("first"))
}

@Test func slotsChangeByACommit() throws {
  var fs = try encryptedFS()
  let current = fs.keybag
  var keybag = try #require(current)
  keybag.slots[1] = .passphrase(n("battery staple"), key: volumeKey, salt: Array(repeating: 2, count: 32), iterations: 3)
  try fs.setKeybag(keybag)
  var disk = sealed(fs.engine.store.volume.device.base, nil)
  var read = try #require(try Volume.newestSuperblock(&disk).keybag)
  #expect(read == keybag)
  #expect(read.unlock(n("battery staple")) == volumeKey)
  #expect(read.unlock(n("correct horse")) == volumeKey)
  keybag.slots[0] = nil
  try fs.setKeybag(keybag)
  disk = sealed(fs.engine.store.volume.device.base, nil)
  read = try #require(try Volume.newestSuperblock(&disk).keybag)
  #expect(read.unlock(n("correct horse")) == nil)
  #expect(read.unlock(n("battery staple")) == volumeKey)
  // The volume mounts as it was.
  var again = try FileSystem.mount(sealed(fs.engine.store.volume.device.base))
  _ = try again.check()
}

/// A swarm slot opens with the answer of its member's key, read back from
/// the superblock, and with no other: the answer of another key, an
/// answer to another request, a changed address.
@Test func aSwarmSlotOpensWithItsMembersAnswer() throws {
  var g = SystemRandomNumberGenerator()
  func random(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255, using: &g) } }
  let member = McCallumRelyea.privateKey(random(32)), other = McCallumRelyea.privateKey(random(32))
  var fs = try encryptedFS()
  let current = fs.keybag
  var keybag = try #require(current)
  let address = "tcp!192.168.0.31!17021"
  keybag.slots[2] = try #require(Keybag.Slot.swarm(member: McCallumRelyea.publicKey(member), address: address,
                                                    key: volumeKey, random: random(64)))
  try fs.setKeybag(keybag)
  var disk = sealed(fs.engine.store.volume.device.base, nil)
  let read = try #require(try Volume.newestSuperblock(&disk).keybag)
  #expect(read == keybag)
  let slot = try #require(read.swarmSlots.first)
  #expect(read.swarmSlots.count == 1 && slot.address == address)
  let (message, blinding) = try #require(slot.request(random: random(64)))
  #expect(message.count == 64 && Array(message[0..<32]) == McCallumRelyea.publicKey(member))
  let x = Array(message[32..<64])
  #expect(slot.open(answer: try #require(McCallumRelyea.answer(x, key: member)), blinding: blinding) == volumeKey)
  #expect(slot.open(answer: try #require(McCallumRelyea.answer(x, key: other)), blinding: blinding) == nil)
  let (again, _) = try #require(slot.request(random: random(64)))
  let late = try #require(McCallumRelyea.answer(Array(again[32..<64]), key: member))
  #expect(slot.open(answer: late, blinding: blinding) == nil)
  var moved = slot
  moved.address = "tcp!10.0.0.1!17021"
  #expect(moved.open(answer: try #require(McCallumRelyea.answer(x, key: member)), blinding: blinding) == nil)
  // A passphrase doesn't open it, nor it a passphrase's slot.
  #expect(slot.open(n("correct horse")) == nil)
  #expect(try #require(read.slots[0]).open(answer: try #require(McCallumRelyea.answer(x, key: member)),
                                           blinding: blinding) == nil)
  #expect(Keybag.Slot.swarm(member: McCallumRelyea.publicKey(member), address: String(repeating: "a", count: 57),
                            key: volumeKey, random: random(64)) == nil)
}

/// What a plain volume does, an encrypted one does: snapshots and send.
@Test func anEncryptedVolumeTakesSnapshotsAndSends() throws {
  var a = try encryptedFS(blocks: 16_384)
  let f = try a.create(root, n("f"), .file, mode: 0o644, now: 2)
  try a.write(f, offset: 0, pattern(4, 100_000), now: 2)
  let one = try a.takeSnapshot(now: noon)
  try a.write(f, offset: 50_000, pattern(5, 1000), now: 3)
  try a.unlink(root, n("f"), now: 4)
  _ = try a.check()
  let old = try a.withSnapshot(one) { (v: inout FileSystem<SealedDevice<MemoryDevice>>) throws(TaisceError) in
    try v.read(try v.lookup(root, n("f")), offset: 0, count: 100_000)
  }
  #expect(old == pattern(4, 100_000))
  var b = try newFS(blocks: 16_384)
  let into = try b.create(root, n("recv"), .directory, mode: 0o755, now: 2)
  var stream = try a.send(from: nil, to: one)
  var r = b.receiver(into: into)
  while true {
    let bytes = try a.read(&stream, max: 9000)
    if bytes.isEmpty { break }
    try b.receive(&r, bytes, now: 9)
  }
  #expect(try b.read(try b.lookup(into, n("f")), offset: 0, count: 100_000) == pattern(4, 100_000))
}
