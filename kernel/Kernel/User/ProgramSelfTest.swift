import CKernel
import Fmt
import Synchronization

/// Boot self-test (K8a): the Embedded Swift test program (user/test/swift)
/// started from its ELF by `ProgramLoader`, with a debuglog as stdout and
/// an environment in its bootstrap message. It must exit 0x600D, and the
/// records it wrote must read back through the debuglog ring (D38), in
/// order, tagged with its process koid. Afterwards nothing it made is left.
enum ProgramSelfTest {
    static func run(_ console: Uart) {
        let before = ProcessSelfTest.Counts()
        var reader = DebugLog.reader()
        var dropped: UInt64 = 0
        var record = InlineArray<256, UInt8>(repeating: 0)
        while read(&reader, into: &record, &dropped) {}  // whatever earlier writers left
        dropped = 0
        let (stdout, stdoutRights) = created { () throws(Status) in try DebugLogs.create() }
        var handles = InlineArray<2, ProgramLoader.StartupHandle>(repeating: ProgramLoader.StartupHandle(
            object: stdout, rights: stdoutRights, info: croi_pa_hnd(UInt32(CROI_PA_FD), 1)))
        handles[1] = ProgramLoader.StartupHandle(object: Processes.rootJob, rights: JobObject.defaultRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0))
        let environment: StaticString = "croi.test=1\0swift.greeting=dia duit\0"
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(croi_swift_test_address()))!,
                                   byteCount: Int(croi_swift_test_size()))
        let process: ObjectPointer
        do throws(Status) {
            process = try ProgramLoader.start(
                image, name: "swifttest", job: Processes.rootJob, handles: handles.span,
                environment: unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        } catch {
            panic("program self-test: loading the Swift program")
        }
        let firstBase = ProgramLoader.lastBase
        stdout.release()
        let giveUp = Clock.now() + 30_000_000_000
        while !Processes.info(process: process).exited {
            guard Clock.now() < giveUp else { panic("program self-test: the Swift program never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let code = Processes.info(process: process).returnCode
        let koid = process.header.koid
        process.release()
        guard code == 0x600D else {
            console.write("  swift:  exit code ")
            console.write(hex: UInt64(bitPattern: code))
            console.write("\n")
            panic("program self-test: the Swift program failed")
        }

        // Its stdout, as records tagged with its koid.
        let expected: InlineArray<4, StaticString> = [
            "swift: hello from user mode",
            "swift: 1000 squares, sum 332833500",
            "swift: env croi.test=1",
            "swift: env swift.greeting=dia duit",
        ]
        var matched = 0
        while read(&reader, into: &record, &dropped) {
            let header = unsafe record.span.bytes.unsafeLoadUnaligned(as: croi_log_record_t.self)
            let size = DebugLog.headerSize + Int(header.datalen)
            guard header.pid == koid else { continue }
            guard matched < expected.count,
                  same(record.span.extracting(DebugLog.headerSize..<size), expected[matched]) else {
                console.write("  swift:  unexpected record: ")
                console.write(utf8: record.span.extracting(DebugLog.headerSize..<size))
                console.write("\n")
                panic("program self-test: the Swift program's output")
            }
            matched += 1
        }
        guard matched == expected.count, dropped == 0 else { panic("program self-test: records missing") }

        // A static PIE (K11b) lands somewhere new each time: a second run.
        let (stdout2, stdout2Rights) = created { () throws(Status) in try DebugLogs.create() }
        handles[0] = ProgramLoader.StartupHandle(object: stdout2, rights: stdout2Rights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_FD), 1))
        let second: ObjectPointer
        do throws(Status) {
            second = try ProgramLoader.start(
                image, name: "swifttest", job: Processes.rootJob, handles: handles.span,
                environment: unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        } catch {
            panic("program self-test: loading the Swift program again")
        }
        let secondBase = ProgramLoader.lastBase
        stdout2.release()
        let giveUp2 = Clock.now() + 30_000_000_000
        while !Processes.info(process: second).exited {
            guard Clock.now() < giveUp2 else { panic("program self-test: the second run never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let secondCode = Processes.info(process: second).returnCode
        second.release()
        guard secondCode == 0x600D, firstBase != secondBase, firstBase != 0, secondBase != 0,
              firstBase % KernelLayout.pageSize == 0, secondBase % KernelLayout.pageSize == 0 else {
            console.write("  swift:  PIE bases ")
            console.write(hex: firstBase)
            console.write(", ")
            console.write(hex: secondBase)
            console.write("\n")
            panic("program self-test: a static PIE's random base")
        }
        // The same program as an ET_EXEC whose dynamic section has no
        // relocations (linked --export-dynamic): where it was linked.
        let (stdout3, stdout3Rights) = created { () throws(Status) in try DebugLogs.create() }
        handles[0] = ProgramLoader.StartupHandle(object: stdout3, rights: stdout3Rights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_FD), 1))
        let executable = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(croi_swift_test_exec_address()))!,
                                        byteCount: Int(croi_swift_test_exec_size()))
        let third: ObjectPointer
        do throws(Status) {
            third = try ProgramLoader.start(
                executable, name: "swifttest-exec", job: Processes.rootJob, handles: handles.span,
                environment: unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        } catch {
            panic("program self-test: loading an executable with a dynamic section")
        }
        stdout3.release()
        let giveUp3 = Clock.now() + 30_000_000_000
        while !Processes.info(process: third).exited {
            guard Clock.now() < giveUp3 else { panic("program self-test: the third run never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let thirdCode = Processes.info(process: third).returnCode
        third.release()
        guard thirdCode == 0x600D else { panic("program self-test: the executable with a dynamic section failed") }
        before.expectUnchanged(console)
        console.write("  swift:  Embedded Swift static PIE at random bases (")
        console.write(hex: firstBase)
        console.write(", ")
        console.write(hex: secondBase)
        console.write("): processargs (handles, environment), ")
        console.write("heap over its VMAR, stdout as ")
        console.write(decimal: UInt64(matched))
        console.write(" debuglog records read back through the ring; an ET_EXEC with a dynamic section")
        console.write(" and no relocations; RELRO read only; all torn down\n")
    }

    /// The Swift program's test suites (user/test/swift/Suite.swift), one
    /// run each with `swift.suite=<name>`: each must exit 0x600D and leave
    /// nothing behind, futex records included. A failing check names
    /// itself on the console (its stdout is a debuglog). New syscall tests
    /// are written as suites, not in usertest.c. test_profile binds to a
    /// deadline context lent for the run (the futex suite's inheritance,
    /// the bind suite's leeway).
    static func runSuites(_ console: Uart) {
        // The idle suite first: the others' deadline context bounds every
        // CPU's wake latency below its deep state's.
        let suites: InlineArray<11, StaticString> = ["swift.suite=idle\0", "swift.suite=bind\0", "swift.suite=vmo\0",
                                                     "swift.suite=futex\0", "swift.suite=channel\0",
                                                     "swift.suite=objects\0", "swift.suite=counters\0",
                                                     "swift.suite=time\0", "swift.suite=memory\0",
                                                     "swift.suite=ring\0", "swift.suite=debuglog\0"]
        let before = ProcessSelfTest.Counts()
        runOrPanic(console, suites[0])
        let context: SchedContext
        do throws(AdmissionRefusal) {
            context = try SchedContext(deadline: DeadlineParams(capacity: 3_000_000, deadline: 10_000_000,
                                                               period: 10_000_000))
        } catch {
            panic("suites: no deadline context")
        }
        TestHooks.deadlineContext = context.record
        for i in 1..<suites.count { runOrPanic(console, suites[i]) }
        TestHooks.deadlineContext = nil
        ProcessSelfTest.releaseWhenUnbound(context)
        before.expectUnchanged(console)
        guard Futexes.live.load(ordering: .relaxed) == 0 else { panic("suites: futex records left") }
        console.write("  suites:")
        for i in suites.indices {
            console.write(" ")
            writeName(console, suites[i])
        }
        console.write(": passed, nothing left behind\n")
    }

    /// Runs one suite; panics if it fails.
    private static func runOrPanic(_ console: Uart, _ environment: StaticString) {
        let code = runSuite(unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        guard code == 0x600D else {
            console.write("  suites: ")
            writeName(console, environment)
            console.write(": exit code ")
            console.write(hex: UInt64(bitPattern: code))
            console.write("\n")
            panic("suites: a suite failed (its FAILED line is above)")
        }
    }

    /// Runs the Swift program with `environment` (NUL-terminated strings,
    /// `swift.suite=<name>` among them), the root resource, the root job,
    /// the root account, the debuglog ring and its counter (D38) and a
    /// debuglog as stdout, until it exits: its exit code.
    static func runSuite(_ environment: Span<UInt8>) -> Int64 {
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(croi_swift_test_address()))!,
                                   byteCount: Int(croi_swift_test_size()))
        let (stdout, stdoutRights) = created { () throws(Status) in try DebugLogs.create() }
        var handles = InlineArray<6, ProgramLoader.StartupHandle>(repeating: ProgramLoader.StartupHandle(
            object: stdout, rights: stdoutRights, info: croi_pa_hnd(UInt32(CROI_PA_FD), 1)))
        handles[1] = ProgramLoader.StartupHandle(object: Resources.root, rights: ResourceObject.defaultRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
        handles[2] = ProgramLoader.StartupHandle(object: Processes.rootJob, rights: JobObject.defaultRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0))
        handles[3] = ProgramLoader.StartupHandle(object: Accounts.root, rights: AccountObject.rootRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_ROOT_ACCOUNT), 0))
        handles[4] = ProgramLoader.StartupHandle(object: DebugLog.vmoObject, rights: DebugLog.vmoRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_VMO_DEBUGLOG), 0))
        handles[5] = ProgramLoader.StartupHandle(object: DebugLog.counter, rights: DebugLog.counterRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_DEBUGLOG_COUNTER), 0))
        let process: ObjectPointer
        do throws(Status) {
            process = try ProgramLoader.start(image, name: "swiftsuite", job: Processes.rootJob, handles: handles.span,
                                              environment: environment)
        } catch {
            panic("suites: loading the Swift program")
        }
        stdout.release()
        let giveUp = Clock.now() + 60_000_000_000
        while !Processes.info(process: process).exited {
            guard Clock.now() < giveUp else { panic("suites: a suite never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let code = Processes.info(process: process).returnCode
        process.release()
        return code
    }

    /// A suite's name: "swift.suite=" (12 bytes) up to the NUL.
    private static func writeName(_ console: Uart, _ environment: StaticString) {
        console.write(utf8: unsafe Span(_unsafeStart: environment.utf8Start + 12,
                                        count: environment.utf8CodeUnitCount - 13))
    }

    private static func created(_ body: () throws(Status) -> (ObjectPointer, Rights)) -> (ObjectPointer, Rights) {
        do throws(Status) {
            return try body()
        } catch {
            panic("program self-test: creating a debuglog")
        }
    }

    /// The ring's next record, if there is one.
    private static func read(_ reader: inout NativeRing, into record: inout InlineArray<256, UInt8>,
                             _ dropped: inout UInt64) -> Bool {
        var span = record.mutableSpan
        return span.withUnsafeMutableBytes { unsafe reader.read(to: $0.baseAddress!, dropped: &dropped) }
    }

    private static func same(_ bytes: Span<UInt8>, _ text: StaticString) -> Bool {
        guard bytes.count == text.utf8CodeUnitCount else { return false }
        for i in bytes.indices where unsafe bytes[i] != text.utf8Start[i] { return false }
        return true
    }
}
