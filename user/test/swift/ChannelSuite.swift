import CroiRuntime

/// Channels: endpoints, handles in messages, refusals that consume them,
/// and a closed peer, moved here from usertest.c's ipc (mode 7) when V1 cut
/// events and eventpairs (D23); and what the *_etc forms did, done the one
/// way left, from small_calls when V1 cut those (D22).
enum ChannelSuite {
    static func run() {
        endpoints()
        transfer()
        refusals()
        peerClosed()
        narrowedRights()
        mayDiscard()
        batches()
        synchronousWake()
        print("swift: channel passed")
    }

    static var transferRight: UInt32 { 1 << 1 }
    static var read: UInt32 { 1 << 2 }
    static var wait: UInt32 { 1 << 14 }
    static var sameRights: UInt32 { CROI_RIGHT_SAME_RIGHTS }
    static var readable: UInt32 { UInt32(CROI_SIGNAL_READABLE) }
    static var peerClosedSignal: UInt32 { UInt32(CROI_SIGNAL_PEER_CLOSED) }

    /// A message received: the call's status, with its byte and handle
    /// counts in `actual` (bytes | handles << 32).
    struct Received {
        var bytes = InlineArray<64, UInt8>(repeating: 0)
        var handles = InlineArray<4, UInt32>(repeating: 0)
        var actual: UInt64 = 0
        var byteCount: UInt64 { actual & 0xFFFF_FFFF }
        var handleCount: UInt64 { actual >> 32 }

        mutating func read(_ channel: borrowing Handle, bytes capacity: UInt64 = 64, handles slots: UInt64 = 4)
            -> Int64 {
            Sys.readChannel(channel.arg, 0, bytes: Sys.address(&bytes), handles: Sys.address(&handles),
                            capacity: capacity | slots << 32, &actual)
        }
    }

    /// Writes `text` with `count` handles from `handles`: the call's status.
    static func write(_ channel: UInt64, _ text: StaticString, _ handles: UInt64 = 0, count: UInt64 = 0) -> Int64 {
        unsafe Sys.writeChannel(channel, bytes: UInt64(UInt(bitPattern: text.utf8Start)),
                               count: UInt64(text.utf8CodeUnitCount), handles: handles, handleCount: count)
    }

    static func duplicate(_ handle: borrowing Handle, _ rights: UInt32) -> UInt32 {
        var out: UInt32 = 0
        check(Sys.duplicate(handle.arg, UInt64(rights), &out) == 0, "a duplicate")
        return out
    }

    static func closed(_ raw: UInt32) -> Bool { croi_handle_close(raw) == Status.badHandle }

    /// Two endpoints, each the other's related koid; nothing to read yet.
    static func endpoints() {
        let channel = Pair()
        var a = croi_info_handle_basic_t(), b = croi_info_handle_basic_t()
        let size = UInt64(MemoryLayout<croi_info_handle_basic_t>.size)
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, channel.a.arg, UInt64(CROI_INFO_HANDLE_BASIC), Sys.address(&a), size)
                  == 0 && Sys.call(CROI_SYS_OBJECT_GET_INFO, channel.b.arg, UInt64(CROI_INFO_HANDLE_BASIC),
                                   Sys.address(&b), size) == 0, "both ends' info")
        check(a.related_koid == b.koid && b.related_koid == a.koid && a.type == 4, "each end's peer is the other")
        var nothing = Received()
        check(nothing.read(channel.b) == Status.shouldWait, "nothing to read")
    }

    /// A handle in a message leaves our table, arrives, and works there:
    /// an add through it is seen through the original.
    static func transfer() {
        let channel = Pair()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var sent = duplicate(counter, sameRights)
        check(write(channel.a.arg, "hello", Sys.address(&sent), count: 1) == 0, "a message with a handle")
        check(closed(sent), "the handle left our table")
        check(Port.signals(of: channel.b, readable, deadline: Sys.now() + 1_000_000_000) & readable != 0, "READABLE")
        var message = Received()
        check(message.read(channel.b, bytes: 2, handles: 1) == Status.bufferTooSmall && message.byteCount == 5
                  && message.handleCount == 1, "too small: the sizes it needs")
        check(message.read(channel.b) == 0 && message.byteCount == 5 && message.handleCount == 1
                  && message.bytes[0] == UInt8(ascii: "h") && message.bytes[4] == UInt8(ascii: "o"), "received")
        let arrived = Handle(adopting: message.handles[0])
        check(croi_counter_add(arrived.raw, 1) == 0, "an add through the handle that arrived")
        check(Port.signals(of: counter, UInt32(CROI_COUNTER_POSITIVE), deadline: Sys.now() + 1_000_000_000)
                  & UInt32(CROI_COUNTER_POSITIVE) != 0, "is seen through the original")
        check(Port.signals(of: channel.b, readable) & readable == 0, "nothing more to read")
    }

    /// Refusals consume the handles listed, as Zircon's do, unless the list
    /// can't be read: without TRANSFER (the first error wins, the rest go
    /// too), a repeat (gone by the second look), a bad channel handle.
    static func refusals() {
        let channel = Pair()
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var two = InlineArray<2, UInt32>(repeating: 0)
        two[0] = duplicate(counter, wait)
        two[1] = duplicate(counter, sameRights)
        check(write(channel.a.arg, "x", Sys.address(&two), count: 2) == Status.accessDenied
                  && closed(two[0]) && closed(two[1]), "without TRANSFER: both consumed")
        two[0] = duplicate(counter, sameRights)
        two[1] = two[0]
        check(write(channel.a.arg, "x", Sys.address(&two), count: 2) == Status.badHandle && closed(two[0]),
              "a repeat: consumed")
        two[0] = duplicate(counter, sameRights)
        check(write(0x7FFF_FFF0, "x", Sys.address(&two), count: 1) == Status.badHandle && closed(two[0]),
              "a bad channel: consumed")
        two[0] = duplicate(counter, sameRights)
        check(write(channel.a.arg, "x", 0x10, count: 1) == Status.invalidArgs, "an unreadable list")
        check(croi_handle_close(two[0]) == 0, "keeps its handles")
    }

    /// An endpoint can't travel in its own channel, and is consumed, which
    /// closes it: its peer sees PEER_CLOSED, refuses writes (consuming
    /// them), and reads drain before they refuse.
    static func peerClosed() {
        var a: UInt32 = 0, b: UInt32 = 0
        check(Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&a), Sys.address(&b)) == 0, "a channel")
        let other = Handle(adopting: b)
        check(write(UInt64(a), "bye") == 0, "a last message")
        check(write(UInt64(a), "x", Sys.address(&a), count: 1) == Status.notSupported && closed(a),
              "an endpoint in its own channel: refused, consumed")
        check(Port.signals(of: other, peerClosedSignal, deadline: Sys.now() + 1_000_000_000) & peerClosedSignal != 0,
              "PEER_CLOSED")
        let counter = Handle(creating: CROI_SYS_COUNTER_CREATE)
        var sent = duplicate(counter, sameRights)
        check(write(other.arg, "x", Sys.address(&sent), count: 1) == Status.peerClosed && closed(sent),
              "writes refused, consuming")
        var message = Received()
        check(message.read(other) == 0 && message.byteCount == 3, "the last message drains")
        check(message.read(other) == Status.peerClosed, "then reads refuse")
    }

    struct Pair: ~Copyable {
        let a: Handle
        let b: Handle

        init() {
            var a: UInt32 = 0, b: UInt32 = 0
            check(Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&a), Sys.address(&b)) == 0, "a channel")
            self.a = Handle(adopting: a)
            self.b = Handle(adopting: b)
        }
    }

    /// A handle's rights are narrowed with handle_duplicate before it is
    /// sent (a DUPLICATE disposition did both), and arrive as such; one
    /// without TRANSFER is refused and consumed.
    static func narrowedRights() {
        let channel = Pair()
        let vmo = Handle(vmo: pageSize)
        var narrowed: UInt32 = 0
        check(Sys.duplicate(vmo.arg, UInt64(read | transferRight), &narrowed) == 0,
              "a duplicate with fewer rights")
        check(Sys.writeChannel(channel.a.arg, bytes: 0, count: 0, handles: Sys.address(&narrowed), handleCount: 1) == 0,
              "sent")
        var received: UInt32 = 0
        var actual: UInt64 = 0
        check(Sys.readChannel(channel.b.arg, 0, bytes: 0, handles: Sys.address(&received), capacity: 1 << 32,
                              &actual) == 0 && actual == 1 << 32, "received")
        let arrived = Handle(adopting: received)
        var info = croi_info_handle_basic_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, arrived.arg, UInt64(CROI_INFO_HANDLE_BASIC), Sys.address(&info),
                       UInt64(MemoryLayout<croi_info_handle_basic_t>.size)) == 0, "its info")
        check(info.rights == read | transferRight && info.type == 3, "it arrives with only those rights")
        var stuck: UInt32 = 0
        check(Sys.duplicate(vmo.arg, UInt64(read), &stuck) == 0, "one without TRANSFER")
        let handle = stuck
        check(Sys.writeChannel(channel.a.arg, bytes: 0, count: 0, handles: Sys.address(&stuck), handleCount: 1)
                  == Status.accessDenied,
              "can't be sent")
        check(croi_handle_close(handle) == Status.badHandle, "and is consumed")
    }

    /// channel_read: a message that doesn't fit stays, unless MAY_DISCARD
    /// drops it; any other option is NOT_SUPPORTED.
    static func mayDiscard() {
        let channel = Pair()
        let text: StaticString = "long message"
        let length = UInt64(text.utf8CodeUnitCount)
        let bytes = unsafe UInt64(UInt(bitPattern: text.utf8Start))
        var buffer = InlineArray<16, UInt8>(repeating: 0)
        var actual: UInt64 = 0
        func receive(_ options: UInt64, capacity: UInt64) -> Int64 {
            Sys.readChannel(channel.b.arg, options, bytes: Sys.address(&buffer), handles: 0, capacity: capacity, &actual)
        }
        check(Sys.writeChannel(channel.a.arg, bytes: bytes, count: length, handles: 0, handleCount: 0) == 0, "written")
        check(receive(2, capacity: 16) == Status.notSupported, "an unknown option")
        check(receive(0, capacity: 4) == Status.bufferTooSmall && actual == length, "too small: the size it needs")
        check(receive(0, capacity: 16) == 0 && actual == length && buffer[0] == UInt8(ascii: "l"), "and it stays")
        check(Sys.writeChannel(channel.a.arg, bytes: bytes, count: length, handles: 0, handleCount: 0) == 0, "written again")
        check(receive(UInt64(CROI_CHANNEL_READ_MAY_DISCARD), capacity: 4) == Status.bufferTooSmall && actual == length,
              "MAY_DISCARD: too small, the size it needed")
        check(receive(0, capacity: 16) == Status.shouldWait, "and it is gone")
    }

    /// channel_write and channel_read take arrays (D41): each goes on past
    /// an item that fails, with every item's status written back; a write
    /// item's handles are consumed even when it fails.
    static func batches() {
        let first = Pair()
        let second = Pair()
        var x: UInt32 = 0, y: UInt32 = 0
        check(Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&x), Sys.address(&y)) == 0
                  && croi_handle_close(y) == 0, "a channel whose peer is gone")
        let lonely = Handle(adopting: x)
        let one: StaticString = "one", three: StaticString = "three"
        var sent = duplicate(Handle(vmo: pageSize), read | transferRight)
        let consumed = sent
        let empty = croi_channel_write_item_t()
        var writes = InlineArray<3, croi_channel_write_item_t>(repeating: empty)
        writes[0] = unsafe croi_channel_write_item_t(channel: first.a.raw, options: 0,
                                                     bytes: UInt64(UInt(bitPattern: one.utf8Start)), handles: 0,
                                                     num_bytes: 3, num_handles: 0, status: 1, reserved: 0)
        writes[1] = croi_channel_write_item_t(channel: lonely.raw, options: 0, bytes: 0, handles: Sys.address(&sent),
                                              num_bytes: 0, num_handles: 1, status: 1, reserved: 0)
        writes[2] = unsafe croi_channel_write_item_t(channel: second.a.raw, options: 0,
                                                     bytes: UInt64(UInt(bitPattern: three.utf8Start)), handles: 0,
                                                     num_bytes: 5, num_handles: 0, status: 1, reserved: 0)
        check(Sys.call(CROI_SYS_CHANNEL_WRITE, Sys.address(&writes), 3) == 2, "two of three written")
        check(writes[0].status == 0 && Int64(writes[1].status) == Status.peerClosed && writes[2].status == 0,
              "each write's status")
        check(croi_handle_close(consumed) == Status.badHandle, "the failed write's handle is consumed")

        let third = Pair()
        var bytes = InlineArray<2, UInt64>(repeating: 0)
        var reads = InlineArray<3, croi_channel_read_item_t>(repeating: croi_channel_read_item_t())
        reads[0] = croi_channel_read_item_t(channel: first.b.raw, options: 0, bytes: Sys.address(&bytes), handles: 0,
                                            num_bytes: 16, num_handles: 0, actual_bytes: 0, actual_handles: 0,
                                            status: 1, reserved: 0)
        reads[1] = reads[0]
        reads[1].channel = second.b.raw
        reads[1].num_bytes = 4  // "three" needs 5
        reads[2] = reads[0]
        reads[2].channel = third.b.raw
        check(Sys.call(CROI_SYS_CHANNEL_READ, Sys.address(&reads), 3) == 1, "one of three read")
        check(reads[0].status == 0 && reads[0].actual_bytes == 3 && bytes[0] & 0xff_ffff == 0x656e6f,
              "the first message")
        check(Int64(reads[1].status) == Status.bufferTooSmall && reads[1].actual_bytes == 5,
              "too small: the size it needs")
        check(Int64(reads[2].status) == Status.shouldWait && reads[2].actual_bytes == 0, "nothing to read")
        check(Sys.call(CROI_SYS_CHANNEL_READ, Sys.address(&reads), 0) == Status.invalidArgs
                  && Sys.call(CROI_SYS_CHANNEL_WRITE, Sys.address(&writes), 65) == Status.invalidArgs,
              "a count of 0 or over 64 is refused")
    }
}

extension ChannelSuite {
    struct Server {
        var channel: UInt32
        var port: UInt32
    }

    /// The CPU `thread` runs on, or last ran on.
    static func cpu(of thread: UInt32) -> UInt32 {
        var stats = croi_info_thread_stats_t()
        check(Sys.call(CROI_SYS_OBJECT_GET_INFO, UInt64(thread), UInt64(CROI_INFO_THREAD_STATS), Sys.address(&stats),
                       UInt64(MemoryLayout<croi_info_thread_stats_t>.size)) == 0, "a thread's stats")
        return stats.last_scheduled_cpu
    }

    /// channel_call's request wakes a server waiting on a port onto the
    /// caller's CPU, and its reply wakes the caller onto the server's,
    /// when nothing else waits there (equal CPUs: none is bigger). Most
    /// of the calls, not all: other work may queue on a CPU at any time.
    /// Before, both woke on idle CPUs, never the other's.
    static func synchronousWake() {
        let channel = Pair()
        let port = Port()
        let server = UnsafeMutablePointer<Server>.allocate(capacity: 1)
        unsafe server.initialize(to: Server(channel: channel.b.raw, port: port.handle.raw))
        let entry: @convention(c) (UInt64) -> Void = { argument in
            let server = unsafe UnsafeMutablePointer<Server>(bitPattern: UInt(argument))!
            var message: UInt64 = 0
            var actual: UInt64 = 0
            while true {
                var items = InlineArray<1, croi_bind_item_t>(repeating: croi_bind_item_t(
                    handle: unsafe server.pointee.channel, options: UInt32(CROI_BIND_SIGNALS), key: 0,
                    trigger: UInt64(CROI_SIGNAL_READABLE), status: 1, reserved: 0))
                var packet = croi_port_packet_t()
                guard unsafe Sys.call(CROI_SYS_OBJECT_BIND, UInt64(server.pointee.port), Sys.address(&items), 1) == 1,
                      unsafe croi_port_wait(server.pointee.port, .max, &packet, 0) == 0,
                      unsafe Sys.readChannel(UInt64(server.pointee.channel), 0, bytes: Sys.address(&message), handles: 0,
                                             capacity: 8, &actual) == 0,
                      message >> 32 != 0 else { break }  // a zero after the txid: done
                _ = unsafe Sys.writeChannel(UInt64(server.pointee.channel), bytes: Sys.address(&message), count: 8,
                                            handles: 0, handleCount: 0)
            }
            Thread.exit()
        }
        let worker = Thread(entry, UInt64(UInt(bitPattern: server)))
        var request: UInt64 = 1 << 32
        var reply: UInt64 = 0
        var args = croi_channel_call_args_t()
        args.wr_bytes = Sys.address(&request)
        args.wr_num_bytes = 8
        args.rd_bytes = Sys.address(&reply)
        args.rd_num_bytes = 8
        var bytes: UInt32 = 0, handles: UInt32 = 0
        let calls = 40
        var requests = 0, replies = 0
        for _ in 0..<calls {
            let before = cpu(of: td_runtime_thread_self)
            check(Sys.call(CROI_SYS_CHANNEL_CALL, channel.a.arg, 0, .max, Sys.address(&args), Sys.address(&bytes),
                           Sys.address(&handles)) == 0, "a call")
            let served = cpu(of: worker.handle.raw)
            if served == before { requests += 1 }
            if cpu(of: td_runtime_thread_self) == served { replies += 1 }
        }
        request = 0
        _ = Sys.writeChannel(channel.a.arg, bytes: Sys.address(&request), count: 8, handles: 0, handleCount: 0)
        worker.join()
        unsafe server.deallocate()
        check(requests >= calls / 2, "a call's request runs on the caller's CPU")
        check(replies >= calls / 2, "its reply wakes the caller on the server's CPU")
    }
}
