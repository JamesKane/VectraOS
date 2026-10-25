// SPDX-License-Identifier: BSD-3-Clause

// Starting a process from a program image, natively (V2's item 4): the
// program is loaded as userboot loads the first one (user/lib/loader's
// Program, the Loader module), and its first thread starts with a
// bootstrap channel whose one message is its Startup as processargs, with
// its own process and thread, its root VMAR and a debuglog for its stdout
// added. Nothing else: no job, no resource, no bootfs, unless the Startup
// holds them. A program that needs libraries is linked with them here
// (D124, Program.loadLinked), from the entry's `libraries` or the lib/ of
// the bootfs image it is in, and its first thread's second argument is
// the record of what was linked.

import CroiSyscall
import Loader
import TDFloor
import TDNative

extension ProgramEntry {
  /// Every file in the bootfs image `bootfs` (a VMO the caller keeps open
  /// while processes start from it), named by its path: what Process.start
  /// loads, and the files beside them (a launcher's manifests).
  public static func bootfs(_ bootfs: borrowing Handle) throws(Status) -> [ProgramEntry] {
    let size = try Kernel.vmoSize(bootfs.raw)
    let mapped = unsafe try Kernel.vmoMap(bootfs.raw, 0, size, false)
    defer { unsafe Kernel.vmoUnmap(mapped, size) }
    let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(mapped), byteCount: size)
    do throws(Bootfs.Error) {
      return try Bootfs.entries(in: image).map {
        ProgramEntry(image: bootfs.raw, offset: Int($0.file.offset), length: Int($0.file.length),
                     name: String(decoding: $0.name, as: UTF8.self))
      }
    } catch {
      throw .ioDataIntegrity
    }
  }
}

extension Kernel {
  /// Root VMARs of processes made and not yet started, by the process's
  /// koid (a handle's number may be reused; a koid never is).
  nonisolated(unsafe) static var vmars: [(koid: UInt64, vmar: UInt32)] = []
  static let vmarsLock = Lock()

  /// Keeps a new process's root VMAR for its start.
  static func keep(_ process: UInt32, vmar: UInt32) {
    guard let koid = try? info(process).koid else {
      close(vmar)
      return
    }
    vmarsLock.withLock { vmars.append((koid, vmar)) }
  }

  static func takeVmar(_ process: UInt32) throws(Status) -> UInt32 {
    let koid = try info(process).koid
    let vmar = vmarsLock.withLock { () -> UInt32? in
      guard let i = vmars.firstIndex(where: { $0.koid == koid }) else { return nil }
      return vmars.remove(at: i).vmar
    }
    guard let vmar else { throw .badState }  // started already, or not made here
    return vmar
  }

  /// Loads `program` into `process` and starts `thread` there with
  /// `startup` (its handles `handles`, consumed whatever happens).
  static func processStart(_ process: UInt32, _ thread: UInt32, _ program: ProgramEntry, _ startup: Startup,
                           _ handles: [(info: UInt32, handle: UInt32)]) throws(Status) {
    var given = handles
    defer { for h in given { close(h.handle) } }
    let vmar = try takeVmar(process)
    given.append((ProcessArgs.info(ProcessArgs.vmarRoot), vmar))

    // The file, mapped readable for the loader to read (and copy from).
    let start = program.offset & ~(pageSize - 1)
    let length = pages(program.offset + program.length - start)
    let mapped = unsafe try vmoMap(program.image, start, length, false)
    defer { unsafe vmoUnmap(mapped, length) }
    let base = unsafe UInt64(UInt(bitPattern: mapped))
    let fileBytes = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(mapped + (program.offset - start)),
                                   byteCount: program.length)
    let elf: ElfImage
    do throws(ElfImage.Error) {
      elf = try ElfImage(parsing: fileBytes)
    } catch {
      throw .invalidArgs
    }
    let loaded: Program.Loaded
    let file = Bootfs.File(offset: UInt64(program.offset), length: UInt64(program.length))
    if Program.needsLibraries(elf, fileBytes) {
      do throws(Program.LinkFailure) {
        let libraries: Program.Libraries = program.libraries.map { .find($0) } ?? .bootfs
        loaded = try Program.loadLinked(program.name, image: program.image, file: file, libraries: libraries,
                                        into: vmar)
      } catch {
        // Why, naming the object, on the starter's output: a status alone
        // can't say which library or symbol.
        print("process start: \(error.message)")
        throw Status(rawValue: Int32(truncatingIfNeeded: error.status)) ?? .internal
      }
    } else {
      do throws(LoadFailure) {
        loaded = try Program.load(elf, file: file, fileBytes: fileBytes, source: program.image,
                                  sourceBase: base &- UInt64(start), into: vmar)
      } catch {
        throw Status(rawValue: Int32(truncatingIfNeeded: error.status)) ?? .internal
      }
    }

    // Its own handles, and its stdout.
    given.append((ProcessArgs.info(ProcessArgs.processSelf), try duplicate(process, .sameRights, consume: false)))
    given.append((ProcessArgs.info(ProcessArgs.threadSelf), try duplicate(thread, .sameRights, consume: false)))
    given.append((ProcessArgs.info(ProcessArgs.fd, 1), try debuglogCreate()))
    let bytes = { (s: String) in Array(s.utf8) }
    let args = startup.args.isEmpty ? [bytes(program.name)] : startup.args.map(bytes)
    let message = Program.processArgs(infos: given.map { $0.info }, args: args,
                                      environment: [], names: startup.names.map(bytes))
    let ends = try channelCreate()
    defer { close(ends.0) }
    let raws = given.map { $0.handle }
    given = []  // the write takes them, written or not
    try channelWrite(ends.0, message, raws)
    // process_start takes the bootstrap end, started or not (Zircon's rule).
    try check(croi_syscall6(CROI_SYS_PROCESS_START, UInt64(process), UInt64(thread), loaded.entry, loaded.stack,
                            UInt64(ends.1), loaded.handover))
  }

  /// The process's own Startup: its arguments and names as
  /// the floor kept them, its handles the floor's table.
  static let currentStartup: Startup = {
    var argc: Int32 = 0
    let args = unsafe strings(td_argv(&argc), Int(argc))
    var count: Int32 = 0
    let names = unsafe strings(td_startup_names(&count), Int(count))
    return Startup(args: args, names: names, floor: true)
  }()

  static func startupTake(_ info: UInt32) -> UInt32? {
    let h = td_startup_take(info)
    return h == 0 ? nil : h
  }

  static func startupInfos() -> [UInt32] {
    var out: [UInt32] = []
    for i in 0..<td_startup_count() {
      let info = td_startup_info(i)
      if info != 0 { out.append(info) }
    }
    return out
  }

  /// C's environ: the kernel's boot options, in the program userboot
  /// starts.
  static func bootOptions() -> [String] {
    guard let env = unsafe environ else { return [] }
    var n = 0
    while unsafe env[n] != nil { n += 1 }
    return unsafe strings(env, n)
  }

  static func strings(_ p: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ n: Int) -> [String] {
    guard let p = unsafe p else { return [] }
    var out: [String] = []
    for i in 0..<n { if let s = unsafe p[i] { out.append(unsafe string(s)) } }
    return out
  }

  static func string(_ p: UnsafePointer<CChar>) -> String {
    var bytes: [UInt8] = []
    var i = 0
    while unsafe p[i] != 0 {
      bytes.append(UInt8(bitPattern: unsafe p[i]))
      i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
