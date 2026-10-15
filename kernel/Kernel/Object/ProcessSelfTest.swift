import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-tests that run the user test program as a process.
///
/// K7a (mode 6): it creates, starts, waits for, kills and inspects child
/// processes, a job and VMARs from user mode. Afterwards every process,
/// address space and object it made must be gone: a process holding its
/// own handle included.
///
/// K7b (mode 7): calls between two of its threads, the client on a
/// deadline context the kernel provides, which must be lent to the server
/// while it serves (ext 2); the `ipc` trace records of a call share one
/// flow id, the one user space computes. Channel basics moved to the
/// channel suite (D23). Panics on failure.
enum ProcessSelfTest {
    static func run(_ console: Uart) {
        let before = Counts()
        let exitCode = runInProcess(mode: 6)
        guard exitCode == 0x600D else {
            console.write("  proc:   user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("process self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  proc:   processes from user mode: create, map, start, exit codes, kill, fault, ")
        console.write("multi-thread exit, job kill, VMARs; all torn down (a process holding itself too)\n")
    }

    static func runIpc(_ console: Uart) {
        let before = Counts()
        let context: SchedContext
        do throws(AdmissionRefusal) {
            context = try SchedContext(deadline: DeadlineParams(capacity: 3_000_000, deadline: 10_000_000,
                                                               period: 10_000_000))
        } catch {
            panic("ipc self-test: no deadline context")
        }
        TestHooks.deadlineContext = context.record
        do throws(VmError) {
            try Trace.start(categories: CROI_TRACE_IPC, pages: 16, mode: UInt32(CROI_TRACE_ONESHOT))
        } catch {
            panic("ipc self-test: trace start")
        }
        let exitCode = runInProcess(mode: 7)
        Trace.stop()
        TestHooks.deadlineContext = nil
        releaseWhenUnbound(context)
        guard exitCode == 0x600D else {
            console.write("  ipc:    user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("ipc self-test: user side")
        }
        // The last call's flow, as user space computed it from the channel's
        // koids and the txid: its call, read, donation and reply.
        let flow = Syscalls.reported.load(ordering: .relaxed)
        var writes = 0, reads = 0, donations = 0
        for cpu in 0..<Smp.count {
            Trace.forEachRecord(cpu) { record in
                guard record.a == flow else { return }
                switch record.kind {
                case UInt16(CROI_TK_CHANNEL_WRITE): writes += 1
                case UInt16(CROI_TK_CHANNEL_READ): reads += 1
                case UInt16(CROI_TK_DONATE): donations += 1
                default: break
                }
            }
        }
        guard writes == 2, reads >= 1, donations == 1 else {
            console.write("  ipc:    flow records: writes ")
            console.write(decimal: UInt64(writes))
            console.write(", reads ")
            console.write(decimal: UInt64(reads))
            console.write(", donations ")
            console.write(decimal: UInt64(donations))
            console.write("\n")
            panic("ipc self-test: a call's trace records don't share its flow")
        }
        before.expectUnchanged(console)
        console.write("  ipc:    calls with txids, timeout, peer closed; a deadline caller's profile lent to the ")
        console.write("server (ext 2); ")
        console.write("call, read, donation and reply share the flow user space computes\n")
    }

    /// A user thread that failed a check may exit still bound, and its
    /// process is marked exited just before the thread unbinds on its way
    /// out: drop the context once nothing uses it.
    static func releaseWhenUnbound(_ context: consuming SchedContext) {
        let record = context.record
        let giveUp = Clock.now() + 2_000_000_000
        while Scheduler.locked({ record.pointee.boundThreads }) != 0, Clock.now() < giveUp {
            Scheduler.sleep(until: Clock.now() + 1_000_000)
        }
        _ = consume context
    }

    /// K7d (mode 9): exception channels (process, then job; HANDLED with
    /// registers rewritten, TRY_NEXT, THREAD_EXIT, none listening) and job
    /// policy (deny, kill, inheritance, fixed once populated, exceptions).
    static func runExceptions(_ console: Uart) {
        let before = Counts()
        let exitCode = runInProcess(mode: 9)
        guard exitCode == 0x600D else {
            console.write("  excp:   user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("exception self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  excp:   exception channels (process then job, registers rewritten, try-next, thread exit, ")
        console.write("unhandled kill), job policy (deny, kill, inherited, fixed once populated, policy exceptions)\n")
    }

    /// K9a (mode 10): resources (ranges, exclusivity, the root filter,
    /// info), a physical VMO over a device register read through a
    /// mapping, cache policy, VMO range ops, zero-size VMOs.
    static func runDrivers(_ console: Uart) {
        let before = Counts()
        let exitCode = runInProcess(mode: 10)
        guard exitCode == 0x600D else {
            console.write("  drv:    user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("driver self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  drv:    resources (ranges, exclusive, RAM and kernel MMIO refused, info), physical VMO over ")
        console.write("a device read through a mapping, cache policy, op_range (commit, zero, decommit, cache ops), IO ports (amd64)\n")
        console.write("  fw:     boot data (ZBI: RSDP, SMBIOS, framebuffer, memory ranges) read only; ACPI tables and SMBIOS ")
        console.write("through physical VMOs, cached only; the kernel's framebuffer pattern read write-combining\n")
    }

    /// K9c: interrupt objects from user mode, the Swift program's
    /// interrupts suite (InterruptSuite.swift; usertest.c's mode 11 until
    /// V1, D29): the state machine fired by a test hook, each machine's RTC
    /// (amd64 GSI 8, arm64 INTID 34, rv64 GSI 11) routed to CPU 1 by
    /// interrupt_set_affinity, MSIs, and a handed-off context. The suite
    /// finds PCI segment 0's ECAM in its environment (`swift.ecam=`).
    static func runInterrupts(_ console: Uart) {
        #if arch(x86_64)
        let number: UInt32 = 8
        #elseif arch(arm64)
        let number: UInt32 = 34
        #else
        let number: UInt32 = 11
        #endif
        let before = Counts()
        let suite: StaticString = "swift.suite=interrupts\0swift.ecam=0x"
        var environment = InlineArray<64, UInt8>(repeating: 0)
        var length = 0
        for i in 0..<suite.utf8CodeUnitCount {
            environment[length] = unsafe suite.utf8Start[i]
            length += 1
        }
        let ecam = Mcfg.count > 0 ? Mcfg.windows[0].base : 0
        for shift in stride(from: 60, through: 0, by: -4) {
            let digit = UInt8(truncatingIfNeeded: ecam >> UInt64(shift) & 0xF)
            environment[length] = digit < 10 ? 0x30 + digit : 0x57 + digit
            length += 1
        }
        length += 1  // its NUL
        let exitCode = ProgramSelfTest.runSuite(environment.span.extracting(0..<length))
        guard exitCode == 0x600D else {
            console.write("  irq:    user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("interrupt self-test: user side")
        }
        before.expectUnchanged(console)
        guard Smp.count < 2 || DeviceIrqs.lastCpu(number) == 1 else {
            console.write("  irq:    taken on CPU ")
            console.write(decimal: UInt64(bitPattern: Int64(DeviceIrqs.lastCpu(number))))
            console.write(", affinity said 1\n")
            panic("interrupt self-test: affinity not honored")
        }
        console.write("  irq:    interrupt objects (fired by a test hook; RTC ")
        console.write(decimal: UInt64(number))
        console.write(" by port, on CPU 1; a handed-off context), port wake ")
        console.write(decimal: Syscalls.reported.load(ordering: .relaxed) / 1000)
        console.write(" us median\n")
        // Todhchai's budget is for hardware: under KVM the wakeup IPI exits.
        Budgets.report(console, "irq.wait_wake_median", Syscalls.reported.load(ordering: .relaxed), target: 5_000)
        #if arch(x86_64)
        console.write("  msi:    allocations and info; where present, edu's MSI by port and a virtio ")
        console.write("MSI-X table's entries programmed, masked, moved to CPU 1, cleared\n")
        #elseif arch(arm64)
        if Its.ready {
            console.write("  msi:    through the GICv3 ITS: allocations and info; where present, edu's MSI by port, ")
            console.write("an event not mapped for it refused, a virtio MSI-X table's entries programmed, moved to ")
            console.write("CPU 1 (MOVI), cleared\n")
        } else {
            console.write("  msi:    not supported (no ITS)\n")
        }
        #else
        if Aia.active {
            console.write("  msi:    through AIA's IMSICs: allocations and info; where present, edu's MSI by port, ")
            console.write("a virtio MSI-X table's entries programmed, moved to CPU 1's file, cleared\n")
        } else {
            console.write("  msi:    not supported (no IMSIC: the PLIC has no MSIs)\n")
        }
        #endif
    }

    /// K9e: DMA through the stub IOMMU from user mode (usertest.c mode 12).
    static func runDma(_ console: Uart) {
        let before = Counts()  // a PMT left behind would hold its VMO and BTI
        let exitCode = runInProcess(mode: 12)
        guard exitCode == 0x600D else {
            console.write("  dma:    user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("DMA self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  dma:    stub IOMMU BTI (logged), pins per page and contiguous, held against decommit and ")
        console.write("cache policy, quarantine, contiguous VMOs, properties narrowing only\n")
    }

    /// K12a: VT-d from user mode (mode 18): a device's DMA through its own
    /// domain, and refused (read only, unpinned): the unit counts faults.
    static func runIommu(_ console: Uart) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        let before = Counts()
        let faults = Iommus.faultsCounted()
        let exitCode = runInProcess(mode: 18)
        if exitCode == 0x600E {
            console.write(Iommus.firstUnit() == nil ? "  iommu:  skipped (no IOMMU in the firmware's tables)\n"
                          : Mcfg.count == 0 ? "  iommu:  skipped (no MCFG)\n" : "  iommu:  skipped (no edu device)\n")
            return
        }
        guard exitCode == 0x600D else {
            console.write("  iommu:  user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("IOMMU self-test: user side")
        }
        // The two refused writes were recorded (the fault event is an MSI
        // to the boot CPU; give it a moment).
        let settle = Clock.now() + 100_000_000
        while Iommus.faultsCounted() < faults + 2, Clock.now() < settle { Scheduler.sleep(until: Clock.now() + 1_000_000) }
        guard Iommus.faultsCounted() >= faults + 2 else {
            console.write("  iommu:  faults recorded: ")
            console.write(decimal: Iommus.faultsCounted() - faults)
            console.write(" (expected 2)\n")
            panic("IOMMU self-test: faults")
        }
        before.expectUnchanged(console)
        console.write("  iommu:  ")
        console.write(Iommus.firstUnitName)
        console.write(": ")
        console.write("edu's DMA through its domain; refused read only and unpinned (faults ")
        console.write("logged); blocked when its BTI went, claimed again; the unit bound again\n")
        #endif
    }

    /// ZX_INFO_TASK_STATS and ZX_INFO_KMEM_STATS from user mode (mode 13).
    static func runMemoryStats(_ console: Uart) {
        let before = Counts()
        let exitCode = runInProcess(mode: 13)
        guard exitCode == 0x600D else {
            console.write("  mem:    user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("memory stats self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  mem:    task stats (mapped, private, shared, scaled with its fraction), kmem stats\n")
    }

    static func runExtensions(_ console: Uart) {
        let before = Counts()
        let exitCode = runInProcess(mode: 17)
        guard exitCode == 0x600D else {
            console.write("  extensions: user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("extensions self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  extensions: thread trace ids, overruns to a port, debuglog progress, a job's reserved CPU, powerctl refusals, VMO children, physical slices with ZERO_CHILDREN and handle counts, snapshots, anonymous slices and references, vmo_read racing decommit, the pager, the small calls, info topics and vmar_op_range, suspension and process memory, a debugger channel, single-step and hardware breakpoints, resizable VMOs, smc_call, a crashed thread held for post-mortem attach, eviction and discardable VMOs, page loaning and borrowing, UNBOUNDED VMOs, zero intervals, cprng\n")
    }

    /// Live processes, address spaces and objects, to check nothing leaked.
    struct Counts {
        let processes = Processes.live.load(ordering: .relaxed)
        let aspaces = UserAspaces.live.load(ordering: .relaxed)
        let objects = Objects.live.load(ordering: .relaxed)

        /// The last thread drops its references just after the process is
        /// marked exited, on its way out: gives it a moment, then panics if
        /// anything is still left.
        func expectUnchanged(_ console: Uart) {
            let settle = Clock.now() + 2_000_000_000
            var now = Counts()
            while !same(now), Clock.now() < settle {
                Scheduler.sleep(until: Clock.now() + 1_000_000)
                now = Counts()
            }
            guard !same(now) else { return }
            console.write("  proc:   leaked: processes ")
            console.write(decimal: UInt64(now.processes - processes))
            console.write(", address spaces ")
            console.write(decimal: UInt64(now.aspaces - aspaces))
            console.write(", objects ")
            console.write(decimal: UInt64(now.objects - objects))
            console.write("\n")
            panic("process self-test: something outlived its process")
        }

        private func same(_ other: Counts) -> Bool {
            other.processes == processes && other.aspaces == aspaces && other.objects == objects
        }
    }

    /// Runs the user test program as a process in `mode`, with a startup
    /// block at 0x3000000 (job, self, root VMAR, code VMO, code size, root
    /// resource, boot data, IOMMU, ECAM, the vDSO's base), and
    /// returns its return code once it has exited.
    static func runInProcess(mode: UInt64) -> Int64 {
        let page = KernelLayout.pageSize
        let codeSize = (croi_user_program_size() + page - 1) & ~(page - 1)
        var exitCode: Int64 = 0
        do throws(Status) {
            let created = try Processes.create(job: Processes.rootJob)
            let process = created.process
            let vmar = created.vmar
            let code = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: codeSize) }
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            let codeVmo = try VmoObject.wrap(code.record)
            let startup = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: page) }
            let startupVmo = try VmoObject.wrap(startup.record)
            let stack = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: 16 * 1024) }
            let record = VmarPointer(object: vmar).info.aspace
            try vmStatus { () throws(VmError) in
                try UserAspace.withView(record) { (aspace: borrowing UserAspace) throws(VmError) in
                    _ = try aspace.map(code, size: codeSize, at: 0x100_0000, rights: .read | .execute)
                    _ = try aspace.map(stack, size: 16 * 1024, at: 0x200_0000, rights: .read | .write)
                    _ = try aspace.map(startup, size: page, at: 0x300_0000, rights: .read)
                }
            }
            let job = try Processes.addHandle(Processes.rootJob, rights: JobObject.defaultRights, to: process)
            let me = try Processes.addHandle(process, rights: ProcessObject.defaultRights, to: process)
            let root = try Processes.addHandle(vmar, rights: VmarObject.defaultRights, to: process)
            let codeHandle = try Processes.addHandle(codeVmo, rights: VmoObject.defaultRights.union(.execute),
                                                     to: process)
            let resource = try Processes.addHandle(Resources.root, rights: ResourceObject.defaultRights, to: process)
            let bootData = try Processes.addHandle(BootData.object, rights: BootData.rights, to: process)
            var block = InlineArray<9, UInt64>(repeating: 0)
            block[0] = UInt64(job) | UInt64(me) << 32
            block[1] = UInt64(root) | UInt64(codeHandle) << 32
            block[2] = codeSize
            block[3] = UInt64(resource)
            block[4] = UInt64(bootData)
            if let unit = Iommus.firstUnit() {
                block[5] = unit.base
                block[6] = UInt64(unit.type)
            }
            block[7] = Mcfg.count > 0 ? Mcfg.windows[0].base : 0  // segment 0's ECAM
            block[8] = ProcessPointer(object: process).pointee.vdsoBase  // now_ns's clock: no writable data to keep it in
            var span = block.mutableSpan
            span.withUnsafeMutableBytes { raw in
                startup.writeBytes(at: 0, from: UInt64(UInt(bitPattern: raw.baseAddress!)), count: 72)
            }
            codeVmo.release()
            startupVmo.release()
            vmar.release()
            let thread = try Processes.createThread(process: process)
            try Processes.start(thread: thread, pc: 0x100_0000, sp: 0x200_0000 + 16 * 1024, arg0: mode,
                                arg1: 0x300_0000, first: true)
            thread.release()
            let giveUp = Clock.now() + 30_000_000_000
            while !Processes.info(process: process).exited {
                guard Clock.now() < giveUp else { panic("process self-test: the test process never ended") }
                Scheduler.sleep(until: Clock.now() + 2_000_000)
            }
            exitCode = Processes.info(process: process).returnCode
            process.release()
        } catch {
            panic("process self-test: setting up the first process")
        }
        return exitCode
    }
}
