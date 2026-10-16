import CroiRuntime

/// Ports as rings (D19, D44): a port made with CROI_PORT_RING delivers its
/// packets into the one ring, which this process maps and drains with no
/// syscall; port_wait with no packets is its sleep, and packets the ring
/// has no room for wait in the port.
enum PortRingSuite {
    static func run() {
        refusals()
        noSyscall()
        overflow()
        coalesced()
        sleeps()
        broken()
        print("swift: portring passed")
    }

    static var slots: UInt64 { UInt64(CROI_PORT_RING_SLOTS) }
    static var slotSize: Int { MemoryLayout<croi_port_packet_t>.size }
    static var size: Int { RingLayout.size(slotSize: slotSize, count: Int(slots))! }
    static var change: UInt32 { UInt32(CROI_BIND_CHANGE) | UInt32(CROI_BIND_PERSISTENT) }

    /// A ring port, its ring's VMO mapped read-write, and its consumer.
    struct RingPort: ~Copyable {
        let port: Handle
        let vmo: Handle
        let mapping: Mapping
        var ring: NativeRing

        init() {
            var out: (UInt32, UInt32) = (0, 0)
            check(Sys.call(CROI_SYS_PORT_CREATE, UInt64(CROI_PORT_RING), Sys.address(&out)) == 0
                      && out.0 != 0 && out.1 != 0, "a ring port made, and its ring's VMO")
            port = Handle(adopting: out.0)
            vmo = Handle(adopting: out.1)
            mapping = Mapping(vmo, length: pageSize)
            let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(mapping.address))!
            guard let attached = unsafe NativeRing(attaching: base, size: Int(pageSize), producer: false,
                                                   slotSize: PortRingSuite.slotSize,
                                                   format: UInt64(CROI_PORT_RING_FORMAT)) else {
                check(false, "its ring is the one ring, of port packets")
                td_exit(1)
            }
            ring = attached
        }

        /// The packets ready, copied out and released.
        mutating func drain() -> [croi_port_packet_t] {
            var packets: [croi_port_packet_t] = []
            let ready = ring.ready()
            for i in 0..<ready {
                var packet = croi_port_packet_t()
                unsafe withUnsafeMutableBytes(of: &packet) { unsafe ring.get(i, to: $0.baseAddress!) }
                packets.append(packet)
            }
            if ready > 0 { _ = ring.release(ready) }
            return packets
        }

        /// port_wait's sleep: its status.
        func wait(_ deadline: UInt64) -> Int64 {
            Sys.call(CROI_SYS_PORT_WAIT, port.arg, deadline, 0, 0, 0)
        }

        /// port_queue of `count` user packets keyed from `first`: how many.
        func queue(from first: UInt64, _ count: Int) -> Int64 {
            var packets: [croi_port_packet_t] = []
            for i in 0..<count {
                var packet = croi_port_packet_t()
                packet.key = first + UInt64(i)
                packets.append(packet)
            }
            return packets.withUnsafeMutableBufferPointer { buffer in
                Sys.call(CROI_SYS_PORT_QUEUE, port.arg, unsafe UInt64(UInt(bitPattern: buffer.baseAddress)),
                         UInt64(count))
            }
        }
    }

    /// port_wait takes no packets from a ring port, and needs some from
    /// any other; the ring's page stays committed and cached as it is.
    static func refusals() {
        let ringPort = RingPort()
        var packet = croi_port_packet_t()
        check(unsafe croi_port_wait(ringPort.port.raw, 0, &packet, 0) == Status.invalidArgs,
              "a ring port's packets are the ring's")
        let plain = Port()
        check(Sys.call(CROI_SYS_PORT_WAIT, plain.handle.arg, 0, 0, 0, 0) == Status.invalidArgs,
              "a plain port has no ring to wait for")
        check(Sys.call(CROI_SYS_VMO_OP_RANGE, ringPort.vmo.arg, UInt64(CROI_VMO_OP_DECOMMIT), 0, pageSize, 0, 0)
                  == Status.badState, "the ring's page can't be decommitted")
        check(Sys.call(CROI_SYS_PORT_CREATE, UInt64(CROI_PORT_RING) | 1 << 7, Sys.address(&packet))
                  == Status.invalidArgs, "unknown options refused")
    }

    /// Packets queued are in the ring at once, in order: no syscall to read
    /// them.
    static func noSyscall() {
        var ringPort = RingPort()
        check(ringPort.queue(from: 100, 10) == 10, "ten packets queued")
        let packets = ringPort.drain()
        var inOrder = packets.count == 10
        for (i, packet) in packets.enumerated() where packet.key != 100 + UInt64(i) || packet.type != 0 {
            inOrder = false
        }
        check(inOrder, "and in the ring, in order, with no port_wait")
        check(ringPort.wait(Sys.now() + 1_000_000) == Status.timedOut, "port_wait times out on an empty ring")
    }

    /// More than the ring holds: the rest wait in the port and go in as
    /// the reader frees slots, at port_wait.
    static func overflow() {
        var ringPort = RingPort()
        check(ringPort.queue(from: 0, 64) == 64 && ringPort.queue(from: 64, 36) == 36, "a hundred packets queued")
        var keys: [UInt64] = []
        for packet in ringPort.drain() { keys.append(packet.key) }
        check(keys.count == 64, "a ring's worth delivered")
        check(ringPort.wait(0) == 0, "port_wait delivers the rest")
        for packet in ringPort.drain() { keys.append(packet.key) }
        var inOrder = keys.count == 100
        for (i, key) in keys.enumerated() where key != UInt64(i) { inOrder = false }
        check(inOrder, "all of them, in order")
    }

    /// A PERSISTENT binding's packet coalesces while it waits in the port
    /// (the ring full), and is armed again once it is in the ring.
    static func coalesced() {
        var ringPort = RingPort()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        check(Port.bindRaw(ringPort.port, counter, change, key: 9) == 0, "a counter bound CHANGE")
        _ = croi_counter_add(counter.raw, 1)
        _ = croi_counter_add(counter.raw, 1)
        var packets = ringPort.drain()
        check(packets.count == 2 && packets[0].key == 9 && packets[0].payload.2 == 1 && packets[1].payload.2 == 1,
              "a packet per add while the ring has room")
        check(ringPort.queue(from: 0, 64) == 64, "the ring filled")
        for _ in 0..<3 { _ = croi_counter_add(counter.raw, 1) }
        packets = ringPort.drain()
        check(packets.count == 64, "only the queued packets in it")
        check(ringPort.wait(0) == 0, "port_wait delivers the rest")
        packets = ringPort.drain()
        check(packets.count == 1 && packets[0].key == 9 && packets[0].payload.2 == 3 && packets[0].payload.1 == 5,
              "one packet for the three adds, with the value")
    }

    struct Late {
        var port: UInt32 = 0
        var delay: UInt64 = 0
    }

    /// A packet from another thread wakes a reader asleep on its empty ring.
    static let latePacket: @convention(c) (UInt64) -> Void = { argument in
        let late = unsafe UnsafeMutablePointer<Late>(bitPattern: UInt(argument))!
        unsafe Sys.sleep(late.pointee.delay)
        var packet = croi_port_packet_t()
        packet.key = 77
        _ = unsafe croi_port_queue(late.pointee.port, &packet)
        Thread.exit()
    }

    static func sleeps() {
        var ringPort = RingPort()
        let late = UnsafeMutablePointer<Late>.allocate(capacity: 1)
        defer { unsafe late.deallocate() }
        unsafe late.initialize(to: Late(port: ringPort.port.raw, delay: 5_000_000))
        let thread = Thread(latePacket, UInt64(UInt(bitPattern: late)))
        let woken = ringPort.wait(Sys.now() + 5_000_000_000)
        let packets = ringPort.drain()
        thread.join()
        check(woken == 0 && packets.count == 1 && packets[0].key == 77, "a reader asleep on its ring is woken")
    }

    /// A reader whose cursor runs past the kernel's has broken its ring:
    /// port_wait says so, and the kernel writes no more into it.
    static func broken() {
        let ringPort = RingPort()
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(ringPort.mapping.address + UInt64(RingLayout.consumerLine)))!
            .pointee = 5
        check(ringPort.queue(from: 0, 1) == 1 && ringPort.wait(0) == Status.badState, "a broken ring is refused")
    }
}

extension Port {
    /// object_bind of one item to a port held as a plain handle.
    static func bindRaw(_ port: borrowing Handle, _ source: borrowing Handle, _ options: UInt32, key: UInt64) -> Int64 {
        var item = croi_bind_item_t(handle: source.raw, options: options, key: key, trigger: 0, status: 1, reserved: 0)
        let bound = Sys.call(CROI_SYS_OBJECT_BIND, port.arg, Sys.address(&item), 1)
        return bound < 0 ? bound : Int64(item.status)
    }
}
