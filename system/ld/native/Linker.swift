// SPDX-License-Identifier: BSD-3-Clause

// dlopen on croi (M5k): shared objects loaded into a running static
// program. A library is bootfs's `lib/NAME`: its segments are mapped into a
// VMAR of their own the way userboot maps a program's (user/lib/loader:
// read-only ones straight from bootfs, writable ones as copy-on-write
// children), it is relocated against the global scope (the program's
// exported symbols, then the libraries loaded before it, then its own),
// its RELRO made read-only, and its initializers run. Libraries are never
// unloaded: a Swift library mustn't be (CLAUDE.md, "Venus"), and none of
// ours need it; dlclose only counts.
//
// Hot reload (D122, docs/plugins.md §2) loads a fresh copy of a file's
// image each time: copied into new memory, made runnable with the VMEX
// resource the program was granted, at a new address, and never found by
// name, so a rename over the file leaves the running copy as it was.
//
// The program exports its symbols when linked with --export-dynamic
// (croi_user_program's EXPORT_DYNAMIC): a library takes libc, the floor
// and Sys from it, so that there is one heap and one of everything.
//
// V2: ELF and bootfs are croi's readers (lib/elf's ElfImage,
// user/lib/loader's Bootfs and Segments), not todhchai's, and bootfs is
// read through a mapping (V1 cut vmo_read, D37).

import CroiRuntime
import Loader
import LibSys
import Sys

/// A library loaded into this process.
public struct Library: Sendable {
  public let name: String
  public let object: DynamicObject
  /// Its VMAR's base and size.
  public let base: UInt, size: Int
}

/// Where libraries come from: bootfs, mapped read only for the process's
/// life.
struct Source {
  let vmo: UInt32
  let base: UInt64
  let size: UInt64
}

public enum DynamicLinker {
  static let lock = Lock()
  nonisolated(unsafe) static var loaded: [(library: Library, references: Int)] = []
  nonisolated(unsafe) static var program: DynamicObject?
  nonisolated(unsafe) static var programRead = false
  nonisolated(unsafe) static var bootfs: Source?
  /// The last failure's message (dlerror's, cleared as it's read).
  nonisolated(unsafe) static var failure: String?

  static let page: UInt64 = 4096

  /// Where libraries come from: bootfs, given to the process (processargs'
  /// PA_VMO_BOOTFS, taken the first time it's needed) or set here.
  public static func use(bootfs vmo: consuming Handle) {
    let raw = vmo.release()
    lock.withLock { bootfs = source(raw) }
  }

  /// `vmo` mapped read only, or nil.
  static func source(_ vmo: UInt32) -> Source? {
    var size: UInt64 = 0
    var base: UInt64 = 0
    guard unsafe croi_vmo_size(vmo, &size) == 0,
      unsafe croi_vmar_map(td_runtime_vmar_root, UInt32(CROI_VM_PERM_READ), 0, vmo, 0, size, &base) == 0
    else { return nil }
    return Source(vmo: vmo, base: base, size: size)
  }

  /// The program's own dynamic section, if it was linked to export symbols:
  /// at its address plus the load bias (that of the segment mapping the
  /// header, file offset 0), as the floor finds its TLS.
  static func programObject() -> DynamicObject? {
    if programRead { return program }
    programRead = true
    guard let header = unsafe td_image_header() else { return nil }
    let phoff = unsafe Int(header.load(fromByteOffset: 32, as: UInt64.self))
    let entry = unsafe Int(header.load(fromByteOffset: 54, as: UInt16.self))
    let count = unsafe Int(header.load(fromByteOffset: 56, as: UInt16.self))
    var bias: UInt = 0
    var dynamic: UInt?
    for i in 0..<count {
      let ph = unsafe header + phoff + i * entry
      let type = unsafe ph.load(as: UInt32.self)
      if unsafe type == 1 && ph.load(fromByteOffset: 8, as: UInt64.self) == 0 {  // PT_LOAD at offset 0
        bias = unsafe UInt(bitPattern: header) &- UInt(ph.load(fromByteOffset: 16, as: UInt64.self))
      }
      if type == 2 { dynamic = unsafe UInt(ph.load(fromByteOffset: 16, as: UInt64.self)) }  // PT_DYNAMIC
    }
    if let dynamic { program = try? DynamicObject(bias: bias, dynamic: bias &+ dynamic, machine: ElfImage.machine) }
    return program
  }

  /// Loads `name` (bootfs's `lib/NAME`, or a path in bootfs) and what it
  /// needs, or finds it loaded; nil with `failure` set if it can't.
  public static func open(_ name: String) -> Int? {
    lock.withLock { () -> Int? in
      do throws(LinkFailure) {
        return try load(name)
      } catch {
        failure = error.message
        return nil
      }
    }
  }

  struct LinkFailure: Error { let message: String }

  /// Where bootfs's `path` lies: bootfs's VMO (the linker's: don't
  /// close it) and the file's offset and length; nil if there's none.
  public static func bootfsFile(_ path: String) -> (vmo: UInt32, offset: UInt64, length: UInt64)? {
    lock.withLock { () -> (vmo: UInt32, offset: UInt64, length: UInt64)? in
      if bootfs == nil, let vmo = StartupHandles.take(ProcessArgs.info(ProcessArgs.vmoBootfs)) { bootfs = source(vmo) }
      guard let source = bootfs else { return nil }
      let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(source.base))!, byteCount: Int(source.size))
      guard let file = try? Bootfs.find(Array(path.utf8).span, in: image) else { return nil }
      return (source.vmo, file.offset, file.length)
    }
  }

  /// Under the lock.
  static func load(_ name: String) throws(LinkFailure) -> Int {
    let path = name.utf8.contains(UInt8(ascii: "/")) ? name : "lib/" + name
    // Names compared as bytes: String's == normalizes, which needs Unicode
    // tables only amd64's Embedded toolchain has.
    let pathBytes = Array(path.utf8), nameBytes = Array(name.utf8)
    if let i = loaded.firstIndex(where: {
      Array($0.library.name.utf8) == pathBytes || $0.library.object.soname.map { Array($0.utf8) } == nameBytes
    }) {
      loaded[i].references += 1
      return i
    }
    if bootfs == nil, let vmo = StartupHandles.take(ProcessArgs.info(ProcessArgs.vmoBootfs)) {
      bootfs = source(vmo)
    }
    guard let source = bootfs else { throw LinkFailure(message: "\(name): no bootfs to load from") }
    let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(source.base))!, byteCount: Int(source.size))
    let file: Bootfs.File
    do throws(Bootfs.Error) {
      file = try Bootfs.find(pathBytes.span, in: image)
    } catch {
      throw LinkFailure(message: error == .notFound ? "\(path): not found" : "\(path): bootfs is malformed")
    }
    let fileBytes = image.extracting(Int(file.offset)..<Int(file.offset + file.length))
    return try link(path, file: file, fileBytes: fileBytes, source: source)
  }

  /// Loads a fresh copy of the image in `vmo`, `size` bytes from `offset`
  /// (page aligned), as `name`: copied into new memory, which `vmex` makes
  /// runnable, linked against what's loaded and never unloaded. Nil with
  /// `failure` set if it can't.
  public static func openFresh(_ vmo: UInt32, offset: UInt64 = 0, size: UInt64, name: String, vmex: UInt32) -> Int? {
    lock.withLock { () -> Int? in
      do throws(LinkFailure) {
        let source = try copy(vmo, offset: offset, size: size, name: name, vmex: vmex)
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(source.base))!, byteCount: Int(size))
        fresh += 1
        return try link("\(name)#\(fresh)", file: Bootfs.File(offset: 0, length: size), fileBytes: image,
                        source: source)
      } catch {
        failure = error.message
        return nil
      }
    }
  }

  /// Fresh copies loaded so far.
  nonisolated(unsafe) static var fresh = 0

  /// `size` bytes of `vmo` copied into a VMO of their own, made runnable
  /// with `vmex`, and mapped read only for the process's life.
  static func copy(_ vmo: UInt32, offset: UInt64, size: UInt64, name: String, vmex: UInt32) throws(LinkFailure) -> Source {
    guard offset % page == 0 else { throw LinkFailure(message: "\(name): not at a page") }
    let length = (size + page - 1) & ~(page - 1)
    guard length > 0 else { throw LinkFailure(message: "\(name): empty") }
    var made: UInt32 = 0
    let created = withUnsafeMutablePointer(to: &made) { m in
      unsafe croi_syscall(CROI_SYS_VMO_CREATE, length, 0, UInt64(UInt(bitPattern: m)), 0, 0)
    }
    guard created == 0 else { throw LinkFailure(message: "\(name): no memory for a copy") }
    let root = td_runtime_vmar_root
    var from: UInt64 = 0, to: UInt64 = 0
    guard unsafe croi_vmar_map(root, UInt32(CROI_VM_PERM_READ), 0, vmo, offset, length, &from) == 0 else {
      _ = croi_handle_close(made)
      throw LinkFailure(message: "\(name): can't be read")
    }
    defer { _ = croi_vmar_unmap(root, from, length) }
    guard unsafe croi_vmar_map(root, UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE), 0, made, 0, length, &to) == 0 else {
      _ = croi_handle_close(made)
      throw LinkFailure(message: "\(name): can't be copied")
    }
    unsafe UnsafeMutableRawPointer(bitPattern: UInt(to))!.copyMemory(from: UnsafeRawPointer(bitPattern: UInt(from))!,
                                                                      byteCount: Int(size))
    _ = croi_vmar_unmap(root, to, length)
    var runnable: UInt32 = 0
    let r = withUnsafeMutablePointer(to: &runnable) { out in
      unsafe croi_syscall(CROI_SYS_VMO_REPLACE_AS_EXECUTABLE, UInt64(made), UInt64(vmex), UInt64(UInt(bitPattern: out)),
                          0, 0)
    }
    guard r == 0, let source = source(runnable) else {
      throw LinkFailure(message: "\(name): can't be made runnable (\(r))")
    }
    return source
  }

  /// Under the lock: the image `fileBytes`, `file` of `source`, mapped,
  /// linked and initialized as `path`.
  static func link(_ path: String, file: Bootfs.File, fileBytes: RawSpan, source: Source) throws(LinkFailure) -> Int {
    // Its headers.
    let elf: ElfImage
    do throws(ElfImage.Error) {
      elf = try ElfImage(parsing: fileBytes)
    } catch {
      throw LinkFailure(message: "\(path): \(error.reason)")
    }
    guard elf.kind == .pie, let dynamic = elf.dynamic else { throw LinkFailure(message: "\(path): not a shared object") }
    guard !elf.tls else { throw LinkFailure(message: "\(path): has TLS, which loaded objects can't yet") }

    // A VMAR for it, then its segments.
    var child: UInt32 = 0
    var base: UInt64 = 0
    let options = UInt64(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE | CROI_VM_CAN_MAP_EXECUTE)
    // The pointers live for the call (an `inout` address returned from a
    // function may be a temporary's).
    let r = withUnsafeMutablePointer(to: &child) { c in
      withUnsafeMutablePointer(to: &base) { b in
        croi_syscall6(CROI_SYS_VMAR_ALLOCATE, UInt64(td_runtime_vmar_root) | options << 32, 0, elf.size,
                      UInt64(UInt(bitPattern: c)), UInt64(UInt(bitPattern: b)), 0)
      }
    }
    guard r == 0 else { throw LinkFailure(message: "\(path): no room for it (\(r))") }
    defer { _ = croi_handle_close(child) }  // the mappings outlive the handle
    let delta = base &- elf.base
    do throws(LoadFailure) {
      try Segments.map(elf, file: file, fileBytes: fileBytes, source: source.vmo, sourceBase: source.base,
                       into: child, vmarBase: base, delta: delta, relocate: false)
    } catch {
      throw LinkFailure(message: "\(path): \(error.what) failed (\(error.status))")
    }

    // Linked: what it needs first, then it against the global scope.
    let bias = UInt(delta)
    let object: DynamicObject
    do throws(LinkError) {
      object = try DynamicObject(bias: bias, dynamic: bias &+ UInt(dynamic), machine: ElfImage.machine)
    } catch {
      throw LinkFailure(message: "\(path): \(describe(error))")
    }
    for dependency in object.needed { _ = try load(dependency) }
    let scope = loaded.map { $0.library.object }
    let main = programObject()
    do throws(LinkError) {
      try object.relocate { name in
        if let found = main?.lookup(name) { return found.address }
        for o in scope { if let found = o.lookup(name) { return found.address } }
        return nil
      }
    } catch {
      let hint = main == nil ? " (the program exports no symbols: link it with EXPORT_DYNAMIC)" : ""
      throw LinkFailure(message: "\(path): \(describe(error))\(hint)")
    }
    if let relro = elf.relro {
      _ = croi_vmar_protect(child, UInt32(CROI_VM_PERM_READ), relro.start &+ delta, relro.end - relro.start)
    }

    loaded.append((Library(name: path, object: object, base: UInt(base), size: Int(elf.size)), 1))
    // Its initializers, last.
    typealias Initializer = @convention(c) () -> Void
    if let f = object.initFunction { unsafe unsafeBitCast(f, to: Initializer.self)() }
    for i in 0..<object.initArray.count {
      let f = unsafe UnsafeRawPointer(bitPattern: object.initArray.address + UInt(i * 8))!.load(as: UInt.self)
      if f != 0 && f != UInt.max { unsafe unsafeBitCast(f, to: Initializer.self)() }
    }
    return loaded.count - 1
  }

  static func describe(_ e: LinkError) -> String {
    switch e {
    case .badDynamic(let what): "can't link: \(what)"
    case .unsupportedRelocation(let type): "relocation type \(type) isn't supported"
    case .undefinedSymbol(let name): "undefined symbol \(name)"
    }
  }

  /// The address of `name` in library `index` (or, with nil, the global
  /// scope: the program, then every library).
  public static func symbol(_ name: String, in index: Int?) -> UInt? {
    let bytes = Array(name.utf8)
    let found = lock.withLock { () -> UInt? in
      if let index {
        guard index < loaded.count else { return nil }
        return loaded[index].library.object.lookup(bytes)?.address
      }
      if let a = programObject()?.lookup(bytes)?.address { return a }
      for l in loaded { if let a = l.library.object.lookup(bytes)?.address { return a } }
      return nil
    }
    if found == nil { lock.withLock { failure = "\(name): undefined symbol" } }
    return found
  }

  /// Takes a reference from library `index`; false if there's none.
  public static func close(_ index: Int) -> Bool {
    lock.withLock {
      guard index < loaded.count, loaded[index].references > 0 else {
        failure = "dlclose: not an open library"
        return false
      }
      loaded[index].references -= 1
      return true
    }
  }

  /// The last failure, cleared.
  public static func takeFailure() -> String? {
    lock.withLock {
      let f = failure
      failure = nil
      return f
    }
  }

  /// The libraries loaded, for a debugger or a status leaf.
  public static var libraries: [Library] { lock.withLock { loaded.map { $0.library } } }
}
