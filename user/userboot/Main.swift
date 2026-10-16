import CroiRuntime

/// userboot (K8b; Zircon's userboot): the first user process. The kernel
/// starts it in the root job with the root job, the root resource, bootfs
/// as a VMO, the boot data (firmware items, zbi.h), the debuglog ring and
/// its counter (D38), a debuglog as stdout and the kernel command line as
/// its environment. It finds the program
/// `userboot.next=` names in bootfs (default bin/launcher), loads its ELF
/// into a new process (read-only segments mapped straight from the bootfs
/// VMO, writable ones copied, PT_GNU_RELRO then read only, a stack from
/// PT_GNU_STACK), hands it
/// everything userboot was given in a processargs message, starts it and
/// reports when it exits; with `userboot.shutdown=` it then powers the
/// machine off or resets it.
@main
struct Userboot {
    typealias Failure = LoadFailure

    static var defaultNext: StaticString { "bin/launcher" }
    static var defaultStackSize: UInt64 { 256 * 1024 }
    static var pageSize: UInt64 { 4096 }

    static func main() {
        do throws(Failure) {
            try run()
        } catch {
            say("userboot: ")
            say(error.what)
            print(" failed: \(error.status)")
            td_exit(1)
        }
        td_exit(0)
    }

    static func run() throws(Failure) {
        let job = td_startup_take(croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0))
        let resource = td_startup_take(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
        let bootfs = td_startup_take(croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTFS), 0))
        guard job != 0, resource != 0, bootfs != 0 else { throw Failure(what: "taking startup handles", status: CROI_ERR_BAD_HANDLE) }
        let next = option("userboot.next=") ?? bytes(defaultNext)
        // userboot.shutdown= (Power.swift) needs the root resource and the
        // boot data after they have gone to the program.
        let shutdown = option("userboot.shutdown=")
        var keptResource: UInt32 = 0
        var keptBootData: UInt32 = 0
        let sameRights = CROI_RIGHT_SAME_RIGHTS
        if shutdown != nil {
            try call("keeping the root resource", unsafe croi_handle_duplicate(resource, sameRights, &keptResource, 0))
        }

        var size: UInt64 = 0
        try call("sizing bootfs", unsafe croi_vmo_size(bootfs, &size))
        var bootfsBase: UInt64 = 0
        try call("mapping bootfs", unsafe croi_vmar_map(td_runtime_vmar_root, UInt32(CROI_VM_PERM_READ), 0,
                                       bootfs, 0, size, &bootfsBase))
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(bootfsBase))!, byteCount: Int(size))
        let file: Bootfs.File
        do throws(Bootfs.Error) {
            file = try Bootfs.find(next.span, in: image)
        } catch {
            say("userboot: ")
            write(next)
            say(error == .notFound ? " is not in bootfs\n" : ": bootfs is malformed\n")
            throw Failure(what: "finding the next program", status: CROI_ERR_NOT_FOUND)
        }
        let elf: ElfImage
        do throws(ElfImage.Error) {
            elf = try ElfImage(parsing: image.extracting(Int(file.offset)..<Int(file.offset + file.length)))
        } catch {
            say("userboot: ")
            write(next)
            say(": ")
            say(error.reason)
            say("\n")
            throw Failure(what: "reading its ELF", status: CROI_ERR_INVALID_ARGS)
        }

        var process: UInt32 = 0
        var vmar: UInt32 = 0
        // Spawn to main (Todhchai's 200 µs budget) starts here; the program
        // gets the time as croi.spawn_ns= in its environment.
        let spawned = UInt64(td_monotonic())
        try call("creating its process", next.span.withUnsafeBytes { name in
            sys(CROI_SYS_PROCESS_CREATE, UInt64(job), UInt64(UInt(bitPattern: name.baseAddress)), UInt64(name.count), 0,
                address(&process), address(&vmar))
        })
        var region = croi_info_vmar_t()
        try call("reading its VMAR", sys(CROI_SYS_OBJECT_GET_INFO, UInt64(vmar), UInt64(CROI_INFO_VMAR), address(&region),
                                         UInt64(MemoryLayout<croi_info_vmar_t>.size)))
        // A static PIE (K11b) goes in a child VMAR at a random place in the
        // lower half of the root; an ET_EXEC where it was linked.
        var target = (vmar: vmar, base: region.base)
        var delta: UInt64 = 0
        if elf.kind == .pie {
            target = try randomPlace(in: vmar, region, size: elf.size)
            delta = target.base &- elf.base
        }
        let fileBytes = image.extracting(Int(file.offset)..<Int(file.offset + file.length))
        try Segments.map(elf, file: file, fileBytes: fileBytes, source: bootfs, sourceBase: bootfsBase,
                         into: target.vmar, vmarBase: target.base, delta: delta, relocate: true)
        if let relro = elf.relro {  // relocated: read only from here on
            try call("protecting its RELRO", croi_vmar_protect(target.vmar, UInt32(CROI_VM_PERM_READ),
                                                 relro.start &+ delta, relro.end - relro.start))
        }
        if target.vmar != vmar { _ = croi_handle_close(target.vmar) }  // the region stays
        let stackSize = ((elf.stackSize ?? defaultStackSize) + pageSize - 1) & ~(pageSize - 1)
        var stack: UInt32 = 0
        var stackBase: UInt64 = 0
        try call("making its stack", sys(CROI_SYS_VMO_CREATE, stackSize, 0, address(&stack)))
        try call("mapping its stack", unsafe croi_vmar_map(vmar, UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE), 0,
                                          stack, 0, stackSize, &stackBase))
        _ = croi_handle_close(stack)

        var thread: UInt32 = 0
        try call("creating its thread", next.span.withUnsafeBytes { name in
            sys(CROI_SYS_THREAD_CREATE, UInt64(process), UInt64(UInt(bitPattern: name.baseAddress)),
                UInt64(name.count), 0, address(&thread))
        })

        // Everything userboot was given goes on, plus the new process's own
        // handles and a debuglog for its stdout.
        var log: UInt32 = 0
        // Both copies in one call (D39).
        let copy = { (handle: UInt32) in
            croi_handle_duplicate_item_t(handle: handle, rights: sameRights, options: 0, out: 0, status: 0, reserved: 0)
        }
        var copies = [copy(process), copy(thread)]
        let copied = copies.withUnsafeMutableBufferPointer { items in
            unsafe sys(CROI_SYS_HANDLE_DUPLICATE, UInt64(UInt(bitPattern: items.baseAddress)), 2)
        }
        try call("duplicating handles", copied < 0 ? copied : copied < 2 ? Int64(copies[Int(copied)].status) : 0)
        let processCopy = copies[0].out
        let threadCopy = copies[1].out
        try call("creating its stdout", sys(CROI_SYS_DEBUGLOG_CREATE, 0, 0, address(&log)))
        var handles: [UInt32] = [processCopy, threadCopy, vmar, job, resource, bootfs, log]
        var infos: [UInt32] = [
            croi_pa_hnd(UInt32(CROI_PA_PROC_SELF), 0), croi_pa_hnd(UInt32(CROI_PA_THREAD_SELF), 0),
            croi_pa_hnd(UInt32(CROI_PA_VMAR_ROOT), 0), croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0),
            croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0), croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTFS), 0),
            croi_pa_hnd(UInt32(CROI_PA_FD), 1),
        ]
        // The boot data, the debuglog ring and its counter (D38), and each
        // kind's ranged root that the kernel gave (by arch).
        for type in [CROI_PA_VMO_BOOTDATA, CROI_PA_VMO_DEBUGLOG, CROI_PA_DEBUGLOG_COUNTER, CROI_PA_MMIO_RESOURCE,
                     CROI_PA_IRQ_RESOURCE, CROI_PA_IOPORT_RESOURCE, CROI_PA_SMC_RESOURCE, CROI_PA_SYSTEM_RESOURCE] {
            let info = croi_pa_hnd(UInt32(type), 0)
            let ranged = td_startup_take(info)
            if ranged != 0 {
                if type == CROI_PA_VMO_BOOTDATA, shutdown != nil {
                    try call("keeping the boot data", unsafe croi_handle_duplicate(ranged, sameRights, &keptBootData, 0))
                }
                handles.append(ranged)
                infos.append(info)
            }
        }
        let message = processArgs(infos: infos, name: next, spawned: spawned)
        var ours: UInt32 = 0
        var theirs: UInt32 = 0
        try call("creating its bootstrap channel", sys(CROI_SYS_CHANNEL_CREATE, 0, address(&ours), address(&theirs)))
        try call("writing its bootstrap message", message.span.withUnsafeBytes { bytes in
            handles.span.withUnsafeBytes { values in
                unsafe croi_channel_write(ours, 0, bytes.baseAddress, UInt32(bytes.count),
                                          values.baseAddress?.assumingMemoryBound(to: UInt32.self), UInt32(handles.count))
            }
        })
        _ = croi_handle_close(ours)
        try call("starting it", sys(CROI_SYS_PROCESS_START, UInt64(process), UInt64(thread), elf.entry &+ delta,
                                    stackBase + stackSize, UInt64(theirs), 0))
        say("userboot: started ")
        write(next)
        say("\n")

        // Its end, through a port: the one wait (D23).
        var port: UInt32 = 0
        try call("creating a port", sys(CROI_SYS_PORT_CREATE, 0, address(&port)))
        var item = croi_bind_item_t(handle: process, options: UInt32(CROI_BIND_SIGNALS), key: 0,
                                    trigger: UInt64(CROI_SIGNAL_TASK_TERMINATED), status: 1, reserved: 0)
        let bound = sys(CROI_SYS_OBJECT_BIND, UInt64(port), address(&item), 1)
        try call("binding its end", bound < 0 ? bound : bound == 1 ? 0 : Int64(item.status))
        var packet = croi_port_packet_t()
        try call("waiting for it", unsafe croi_port_wait(port, .max, &packet, 0))
        _ = croi_handle_close(port)
        var info = croi_info_process_t()
        try call("reading its exit code", sys(CROI_SYS_OBJECT_GET_INFO, UInt64(process), UInt64(CROI_INFO_PROCESS),
                                              address(&info), UInt64(MemoryLayout<croi_info_process_t>.size)))
        say("userboot: ")
        write(next)
        print(" exited with \(info.return_code)")
        if let shutdown { try Power.act(shutdown, resource: keptResource, bootData: keptBootData) }
    }

    /// A child VMAR of `size` bytes at a random page in the lower half of
    /// the root VMAR (ASLR, from cprng_draw), retried where it collides.
    static func randomPlace(in root: UInt32, _ region: croi_info_vmar_t, size: UInt64) throws(Failure)
        -> (vmar: UInt32, base: UInt64) {
        // Room for it in the lower half, else the subtraction (review fix:
        // it wrapped) and a modulus by zero pages.
        guard size < region.len / 2, (region.len / 2 - size) / pageSize > 0 else {
            throw Failure(what: "placing it", status: CROI_ERR_OUT_OF_RANGE)
        }
        let pages = (region.len / 2 - size) / pageSize
        let canMap = UInt32(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE | CROI_VM_CAN_MAP_EXECUTE | CROI_VM_SPECIFIC)
        for _ in 0..<16 {
            var random: UInt64 = 0
            try call("drawing a base", sys(UInt64(CROI_SYS_CPRNG_DRAW), address(&random), 8))
            var child: UInt32 = 0
            var base: UInt64 = 0
            let status = sys(CROI_SYS_VMAR_ALLOCATE, UInt64(root) | UInt64(canMap) << 32, (random % pages) * pageSize,
                             size, address(&child), address(&base))
            if status == 0 { return (child, base) }
            guard status == -26 else { throw Failure(what: "placing it", status: status) }  // ALREADY_EXISTS: again
        }
        throw Failure(what: "placing it", status: CROI_ERR_NO_MEMORY)
    }

    /// The processargs message (processargs.h): header, handle infos,
    /// argv[0] (the program's bootfs name), then userboot's environment.
    static func processArgs(infos: [UInt32], name: [UInt8], spawned: UInt64) -> [UInt8] {
        let header = MemoryLayout<croi_proc_args_t>.size
        var environment: [UInt8] = []
        var index = 0
        while let entry = unsafe environ[index] {
            index += 1
            let length = unsafe strlen(entry)
            for j in 0..<length { environment.append(unsafe UInt8(bitPattern: entry[j])) }
            environment.append(0)
        }
        environment.append(contentsOf: bytes("croi.spawn_ns="))
        environment.append(contentsOf: decimal(spawned))
        environment.append(0)
        var args = croi_proc_args_t()
        args.protocol = UInt32(CROI_PROCARGS_PROTOCOL)
        args.version = UInt32(CROI_PROCARGS_VERSION)
        args.handle_info_off = UInt32(header)
        args.args_off = UInt32(header + 4 * infos.count)
        args.args_num = 1
        args.environ_off = args.args_off + UInt32(name.count + 1)
        args.environ_num = UInt32(index) + 1
        var message: [UInt8] = []
        withUnsafeBytes(of: &args) { raw in
            for i in 0..<raw.count { message.append(unsafe raw[i]) }
        }
        for info in infos {
            for shift in stride(from: 0, to: 32, by: 8) { message.append(UInt8(truncatingIfNeeded: info >> UInt32(shift))) }
        }
        message.append(contentsOf: name)
        message.append(0)
        message.append(contentsOf: environment)
        return message
    }

    /// `value` in decimal ASCII.
    static func decimal(_ value: UInt64) -> [UInt8] {
        var digits: [UInt8] = []
        var v = value
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(v % 10))
            v /= 10
        } while v != 0
        return digits.reversed()
    }

    /// The rest of the environment string that starts with `prefix`.
    static func option(_ prefix: StaticString) -> [UInt8]? {
        let wanted = bytes(prefix)
        var index = 0
        while let entry = unsafe environ[index] {
            index += 1
            let length = unsafe strlen(entry)
            guard length >= wanted.count else { continue }
            var same = true
            for j in 0..<wanted.count where unsafe UInt8(bitPattern: entry[j]) != wanted[j] { same = false }
            guard same else { continue }
            var value: [UInt8] = []
            for j in wanted.count..<length { value.append(unsafe UInt8(bitPattern: entry[j])) }
            return value
        }
        return nil
    }

    static func bytes(_ text: StaticString) -> [UInt8] {
        var result: [UInt8] = []
        for i in 0..<text.utf8CodeUnitCount { result.append(unsafe text.utf8Start[i]) }
        return result
    }

    static func say(_ text: StaticString) {
        unsafe td_stdout_write(UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self), text.utf8CodeUnitCount)
    }

    static func write(_ text: [UInt8]) {
        text.span.withUnsafeBytes { bytes in
            unsafe td_stdout_write(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
        }
    }

    static func call(_ what: StaticString, _ status: Int64) throws(Failure) {
        guard status == 0 else { throw Failure(what: what, status: status) }
    }

    static func sys(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
                    _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> Int64 {
        croi_syscall6(number, a0, a1, a2, a3, a4, a5)
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
    }
}
