// SPDX-License-Identifier: BSD-3-Clause

// The ABI's values as Sys's types: statuses, rights, signals, object types
// and port packets. Shared by the hosted kernel (SysHost) and the typed API
// (Sys), so both speak the kernel's numbers. The headers are the one source
// (D45): everything here is taken from them (module CroiAbi, re-exported,
// so Sys's users name the rest of the ABI the same way), except Status's
// cases, which an enum needs as literals; SysTests checks those against
// object.h.

@_exported import CroiAbi

/// A system call's result: the ABI's values (object.h), negative, so they
/// can travel in an epitaph.
public enum Status: Int32, Error, Equatable, Sendable {
  case ok = 0
  case `internal` = -1
  case notSupported = -2
  case noResources = -3
  case noMemory = -4
  case invalidArgs = -10
  case badHandle = -11
  case wrongType = -12
  case outOfRange = -14
  case bufferTooSmall = -15
  case badState = -20
  case timedOut = -21
  case shouldWait = -22
  case canceled = -23
  case peerClosed = -24
  case notFound = -25
  case alreadyExists = -26
  case alreadyBound = -27
  case unavailable = -28
  case accessDenied = -30
  case io = -40
  case ioDataIntegrity = -42
  case fileBig = -53
  case noSpace = -54

  /// A call's result as a status: a negative one's, else `ok`.
  public init(result: Int64) {
    self = result >= 0 ? .ok : Status(rawValue: Int32(truncatingIfNeeded: result)) ?? .internal
  }
}

/// What a handle allows (object.h's CROI_RIGHT_*). A handle keeps its
/// rights when it moves through a channel.
public struct Rights: OptionSet, Equatable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static var duplicate: Rights { Rights(rawValue: CROI_RIGHT_DUPLICATE) }
  public static var transfer: Rights { Rights(rawValue: CROI_RIGHT_TRANSFER) }
  public static var read: Rights { Rights(rawValue: CROI_RIGHT_READ) }
  public static var write: Rights { Rights(rawValue: CROI_RIGHT_WRITE) }
  public static var execute: Rights { Rights(rawValue: CROI_RIGHT_EXECUTE) }
  public static var map: Rights { Rights(rawValue: CROI_RIGHT_MAP) }
  public static var getProperty: Rights { Rights(rawValue: CROI_RIGHT_GET_PROPERTY) }
  public static var setProperty: Rights { Rights(rawValue: CROI_RIGHT_SET_PROPERTY) }
  public static var enumerate: Rights { Rights(rawValue: CROI_RIGHT_ENUMERATE) }
  public static var destroy: Rights { Rights(rawValue: CROI_RIGHT_DESTROY) }
  public static var getPolicy: Rights { Rights(rawValue: CROI_RIGHT_GET_POLICY) }
  public static var setPolicy: Rights { Rights(rawValue: CROI_RIGHT_SET_POLICY) }
  public static var signal: Rights { Rights(rawValue: CROI_RIGHT_SIGNAL) }
  public static var wait: Rights { Rights(rawValue: CROI_RIGHT_WAIT) }
  public static var inspect: Rights { Rights(rawValue: CROI_RIGHT_INSPECT) }
  public static var manageJob: Rights { Rights(rawValue: CROI_RIGHT_MANAGE_JOB) }
  public static var manageProcess: Rights { Rights(rawValue: CROI_RIGHT_MANAGE_PROCESS) }
  public static var manageThread: Rights { Rights(rawValue: CROI_RIGHT_MANAGE_THREAD) }
  public static var applyProfile: Rights { Rights(rawValue: CROI_RIGHT_APPLY_PROFILE) }
  public static var manageVmo: Rights { Rights(rawValue: CROI_RIGHT_MANAGE_VMO) }
  /// handle_duplicate: the same rights as the source.
  public static var sameRights: Rights { Rights(rawValue: CROI_RIGHT_SAME_RIGHTS) }
  /// Transfer, duplicate, wait and inspect: every object's.
  public static var basic: Rights { Rights(rawValue: CROI_RIGHTS_BASIC) }
}

/// Signals objects assert (ipc.h, task.h, counter.h). V1 cut user signals
/// and the objects that set them (D23, D31): counters are the one event.
public enum Signals {
  /// A channel has a message to read.
  public static var readable: UInt32 { CROI_SIGNAL_READABLE }
  /// A channel can be written.
  public static var writable: UInt32 { CROI_SIGNAL_WRITABLE }
  /// A channel's peer is closed.
  public static var peerClosed: UInt32 { CROI_SIGNAL_PEER_CLOSED }
  /// A job, process or thread has ended.
  public static var terminated: UInt32 { CROI_SIGNAL_TASK_TERMINATED }
  /// A thread is running.
  public static var threadRunning: UInt32 { CROI_SIGNAL_THREAD_RUNNING }
  /// A process has a note waiting to be taken (D87).
  public static var note: UInt32 { CROI_SIGNAL_PROCESS_NOTE }
  /// A counter's value is above zero, or not.
  public static var positive: UInt32 { CROI_COUNTER_POSITIVE }
  public static var nonPositive: UInt32 { CROI_COUNTER_NON_POSITIVE }
}

/// Object types, as object_get_info reports them (object.h).
public enum ObjectType {
  public static var process: UInt32 { CROI_OBJ_TYPE_PROCESS }
  public static var thread: UInt32 { CROI_OBJ_TYPE_THREAD }
  public static var vmo: UInt32 { CROI_OBJ_TYPE_VMO }
  public static var channel: UInt32 { CROI_OBJ_TYPE_CHANNEL }
  public static var port: UInt32 { CROI_OBJ_TYPE_PORT }
  public static var interrupt: UInt32 { CROI_OBJ_TYPE_INTERRUPT }
  public static var log: UInt32 { CROI_OBJ_TYPE_LOG }
  public static var resource: UInt32 { CROI_OBJ_TYPE_RESOURCE }
  public static var job: UInt32 { CROI_OBJ_TYPE_JOB }
  public static var vmar: UInt32 { CROI_OBJ_TYPE_VMAR }
  public static var profile: UInt32 { CROI_OBJ_TYPE_PROFILE }
  public static var exception: UInt32 { CROI_OBJ_TYPE_EXCEPTION }
  public static var counter: UInt32 { CROI_OBJ_TYPE_COUNTER }
}

/// A port packet (port.h's croi_port_packet_t): key, type, status and 32
/// bytes of payload.
public typealias Packet = croi_port_packet_t

extension croi_port_packet_t: @retroactive Equatable {
  public init(key: UInt64, type: UInt32 = CROI_PKT_TYPE_USER, status: Int32 = 0,
              payload: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)) {
    self.init()
    self.key = key
    self.type = type
    self.status = status
    self.payload = payload
  }

  public static func == (a: Packet, b: Packet) -> Bool {
    a.key == b.key && a.type == b.type && a.status == b.status && a.payload.0 == b.payload.0
      && a.payload.1 == b.payload.1 && a.payload.2 == b.payload.2 && a.payload.3 == b.payload.3
  }

  /// For a signal packet: the signals that triggered it, and all observed.
  public var trigger: UInt32 { UInt32(truncatingIfNeeded: payload.0) }
  public var observed: UInt32 { UInt32(truncatingIfNeeded: payload.0 >> 32) }
}

/// A deadline that never passes.
public let infiniteDeadline = Int64.max

/// The flow id of a channel message (ipc.h's croi_flow_id): both ends
/// compute it from what they share, the channel's id (the smaller of its
/// two endpoints' koids) and the message's txid, so a call and its reply
/// share one flow and nothing extra travels.
public func flowID(channel: UInt64, txid: UInt32) -> UInt64 { croi_flow_id(channel, txid) }

/// Resource kinds (resource.h's CROI_RSRC_KIND_*, as literals: an enum
/// needs them; SysTests checks them): what range of hardware a resource
/// grants. ROOT is the root resource, every kind's.
public enum ResourceKind: UInt32, Sendable {
  case mmio = 0
  case irq = 1
  /// amd64 only.
  case ioport = 2
  case root = 3
  /// arm64 only: SMCCC function ids.
  case smc = 4
  case system = 5

  public var name: String {
    switch self {
    case .mmio: "mmio"
    case .irq: "irq"
    case .ioport: "ioport"
    case .root: "root"
    case .smc: "smc"
    case .system: "system"
    }
  }

  /// The kind `name` names (not `root`), compared as bytes: a String
  /// switch needs Unicode tables tier 0 lacks.
  public init?(name: String) {
    for kind in [ResourceKind.mmio, .irq, .ioport, .smc, .system] where name.utf8.elementsEqual(kind.name.utf8) {
      self = kind
      return
    }
    return nil
  }
}

/// The system resource's ranges (resource.h's CROI_RSRC_SYSTEM_*_BASE),
/// each one wide: a child of the system resource for one of them grants
/// that and nothing else.
public enum SystemResource {
  /// Making a VMO executable (VMO.executable).
  public static var vmex: UInt64 { UInt64(CROI_RSRC_SYSTEM_VMEX_BASE) }
  /// The kernel's trace, its samples and the PMU's (trace_configure,
  /// pmu_configure's sampling).
  public static var tracing: UInt64 { UInt64(CROI_RSRC_SYSTEM_TRACING_BASE) }
}

/// Processargs handle types (processargs.h's CROI_PA_*) that a process
/// passes on to the ones it starts: the low byte of an info word, whose
/// bits 16-31 are an argument.
public enum HandleType {
  public static var jobDefault: UInt32 { CROI_PA_JOB_DEFAULT }
  public static var vmoBootfs: UInt32 { CROI_PA_VMO_BOOTFS }
  /// Boot data: a read-only VMO of ZBI items from firmware.
  public static var vmoBootData: UInt32 { CROI_PA_VMO_BOOTDATA }
  public static var rootResource: UInt32 { CROI_PA_RESOURCE }
  /// Each kind's ranged root.
  public static func resource(_ kind: ResourceKind) -> UInt32 {
    switch kind {
    case .mmio: CROI_PA_MMIO_RESOURCE
    case .irq: CROI_PA_IRQ_RESOURCE
    case .ioport: CROI_PA_IOPORT_RESOURCE
    case .smc: CROI_PA_SMC_RESOURCE
    case .system: CROI_PA_SYSTEM_RESOURCE
    case .root: CROI_PA_RESOURCE
    }
  }
  public static var user0: UInt32 { CROI_PA_USER0 }
  /// A process's trace region.
  public static var traceRegion: UInt32 { CROI_PA_TRACE_REGION }
  /// A driver host's device resources; the argument says which.
  public static var device: UInt32 { CROI_PA_DEVICE }
  /// A Node channel in the namespace; its argument indexes the names table
  /// (Namespace's Startup, D65).
  public static var nsDir: UInt32 { CROI_PA_NS_DIR }
  /// The launcher's forwarder for a namespace entry that is a service's
  /// mount, its argument the entry's: it reconnects the entry when the
  /// service restarts.
  public static var nsReconnect: UInt32 { CROI_PA_NS_RECONNECT }
  /// The server end of the process's own Node tree.
  public static var export: UInt32 { CROI_PA_DIRECTORY_REQUEST }
  /// The session board, to post to /srv.
  public static var srvBoard: UInt32 { CROI_PA_SRV_BOARD }
  /// The UTC page (D48): argument 0 read only (the floor maps it), 1
  /// writable (the time service's).
  public static var vmoUTC: UInt32 { CROI_PA_VMO_UTC }
  /// A page the process writes its exit string to, as it ends (Plan 9's
  /// exits, D72): ExitString is the parent's side, td_exits the child's.
  public static var vmoStatus: UInt32 { CROI_PA_VMO_STATUS }
  /// The debuglog (D38): its ring, read only, and its doorbell, the counter
  /// holding the ring's producer cursor. Holding them is the right to read.
  public static var vmoDebuglog: UInt32 { CROI_PA_VMO_DEBUGLOG }
  public static var debuglogCounter: UInt32 { CROI_PA_DEBUGLOG_COUNTER }

  /// An info word: the type, and the argument in bits 16-31.
  public static func info(_ type: UInt32, _ argument: UInt32 = 0) -> UInt32 { croi_pa_hnd(type, argument) }
}

/// processargs (processargs.h): what a started process's bootstrap
/// message says, which the floor's start reads and Sys's loader writes.
public enum ProcessArgs {
  public static var protocolMagic: UInt32 { CROI_PROCARGS_PROTOCOL }
  public static var version: UInt32 { CROI_PROCARGS_VERSION }

  /// Handle types: the low byte of a handle-info word.
  public static var processSelf: UInt32 { CROI_PA_PROC_SELF }
  public static var threadSelf: UInt32 { CROI_PA_THREAD_SELF }
  public static var jobDefault: UInt32 { CROI_PA_JOB_DEFAULT }
  public static var vmarRoot: UInt32 { CROI_PA_VMAR_ROOT }
  public static var vmoBootfs: UInt32 { CROI_PA_VMO_BOOTFS }
  public static var fd: UInt32 { CROI_PA_FD }
  public static var resource: UInt32 { CROI_PA_RESOURCE }
  public static var user0: UInt32 { CROI_PA_USER0 }
  public static var traceRegion: UInt32 { CROI_PA_TRACE_REGION }

  /// A handle-info word: the type, and an argument in bits 16-31.
  public static func info(_ type: UInt32, _ argument: UInt32 = 0) -> UInt32 { croi_pa_hnd(type, argument) }
}

/// An object_bind item (port.h's croi_bind_item_t): an event source, what
/// to wait for, and the packets' key.
public typealias Binding = croi_bind_item_t

extension croi_bind_item_t {
  /// Any of `signals` on `handle`: once, or with `persistent` at every
  /// event that leaves one asserted (coalesced while the packet is unread);
  /// with `edge`, not at once if one already is.
  public static func signals(_ handle: UInt32, _ signals: UInt32, key: UInt64, persistent: Bool = false,
                             edge: Bool = false) -> Binding
  {
    Binding(handle: handle,
            options: CROI_BIND_SIGNALS | (persistent ? CROI_BIND_PERSISTENT : 0) | (edge ? CROI_BIND_EDGE : 0),
            key: key, trigger: UInt64(signals), status: 0, reserved: 0)
  }

  /// A counter reaching `value` (once: a fence).
  public static func value(_ counter: UInt32, _ value: Int64, key: UInt64) -> Binding {
    Binding(handle: counter, options: CROI_BIND_VALUE, key: key, trigger: UInt64(bitPattern: value), status: 0,
            reserved: 0)
  }

  /// Every add to a counter (a ring's doorbell).
  public static func changes(_ counter: UInt32, key: UInt64) -> Binding {
    Binding(handle: counter, options: CROI_BIND_CHANGE | CROI_BIND_PERSISTENT, key: key, trigger: 0, status: 0,
            reserved: 0)
  }

  /// Every firing of an interrupt, until `Interrupt.ack` re-arms it; the
  /// port made with `bindToInterrupt`.
  public static func interrupt(_ interrupt: UInt32, key: UInt64) -> Binding {
    Binding(handle: interrupt, options: CROI_BIND_INTERRUPT | CROI_BIND_PERSISTENT, key: key, trigger: 0, status: 0,
            reserved: 0)
  }
}

/// A counter_add item (counter.h's croi_counter_add_item_t).
public typealias CounterAdd = croi_counter_add_item_t

/// A channel_write item (ipc.h's croi_channel_write_item_t, D41).
public typealias ChannelWriteItem = croi_channel_write_item_t

/// A channel_read item (ipc.h's croi_channel_read_item_t, D41).
public typealias ChannelReadItem = croi_channel_read_item_t
