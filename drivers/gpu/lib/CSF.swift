// SPDX-License-Identifier: BSD-3-Clause

// The GPU class's native capset for command-stream GPUs, `csf` (D173): what
// a user-side driver needs of a kernel one, with panthor's object model
// (chinese-wall's panthor 10, 07 section 7.13) and none of Linux's ioctl
// encoding. A context has VMs (a GPU address space each), buffers (a VMO
// the driver pinned, mapped by the client), binds of a buffer's range at
// an address of a VM, and groups of queues over a VM. A job is a stream
// in a VM that a queue runs; the driver wraps it in its own ring
// sequence (flush, call, sync), so a client never writes a ring. A
// submission's waits and signals are the class's syncs: counters of the
// client's that the driver adds to when each job of the submission is done
// (D25: counters only add). A group that a fault, a timeout or a reset
// ended makes its context `lost`: it runs nothing more, the context's
// other groups and every other context run on.
//
// It is the same class as `GPUDeviceIPC`: a device offers this capset as
// `GPUCapset.csf`, and `Device.open` on it returns a channel that speaks
// `Context` below. The protocol library is its own (an IPC library can't
// name another's types), so `GPUError` and `SyncValue` repeat the
// class's, case for case and field for field.

import IPC
import Node

/// The capsets of the GPU class. A virtio-gpu's are its device's own (Venus
/// is 4); a native one's start at 0x1000, where none of virtio's can be.
public enum GPUCapset {
  public static let venus: UInt32 = 4
  /// Arm Mali's command-stream frontend (mali(3)).
  public static let csf: UInt32 = 0x1000
}

@IPCLibrary(id: "todhchai.gpu.csf", version: 1)
public enum GPUCSFIPC {
  public enum GPUError: Int32, IPCErrorCode, Sendable {
    /// An argument breaks a rule of the object model.
    case invalid = 1
    /// No such buffer or sync.
    case notFound
    /// A table is full (VMs, groups, buffers, syncs).
    case unavailable
    case noMemory
    /// The context's group ended, or the device failed: no more work runs.
    case lost
  }

  /// A sync to wait for or to raise.
  public struct SyncValue: Equatable, Sendable {
    public var id: UInt32
    public var value: UInt64
    public init(id: UInt32, value: UInt64) {
      self.id = id
      self.value = value
    }
  }

  /// What the GPU and its firmware report (panthor 10 section 10.3), as
  /// the registers say.
  public struct Info: Equatable, Sendable {
    public var gpuID: UInt32
    public var csfID: UInt32
    /// The firmware's interface version (GLB_VERSION).
    public var interfaceVersion: UInt32
    public var features: UInt64
    /// The cores the driver may use (the harvest mask applied).
    public var shaderPresent: UInt64
    public var tilerPresent: UInt64
    public var l2Present: UInt64
    public var asPresent: UInt32
    /// The GPU's virtual address bits.
    public var vaBits: UInt32
    /// The GPU page sizes a bind can use, as a bitmap (4 KiB and 2 MiB).
    public var pageSizes: UInt32
    /// Firmware group slots.
    public var groupSlots: UInt32
    /// Queues a group may have (command-stream slots).
    public var queuesPerGroup: UInt32
    /// A stream's work registers, and of them the last `unpreservedRegisters`
    /// a job's call clobbers.
    public var workRegisters: UInt32
    public var unpreservedRegisters: UInt32
    public var scoreboards: UInt32
    /// Bit p is set when a group may have priority p (0 low, 3 realtime).
    public var priorities: UInt32
    public init(gpuID: UInt32, csfID: UInt32, interfaceVersion: UInt32, features: UInt64, shaderPresent: UInt64,
                tilerPresent: UInt64, l2Present: UInt64, asPresent: UInt32, vaBits: UInt32, pageSizes: UInt32,
                groupSlots: UInt32, queuesPerGroup: UInt32, workRegisters: UInt32, unpreservedRegisters: UInt32,
                scoreboards: UInt32, priorities: UInt32) {
      self.gpuID = gpuID
      self.csfID = csfID
      self.interfaceVersion = interfaceVersion
      self.features = features
      self.shaderPresent = shaderPresent
      self.tilerPresent = tilerPresent
      self.l2Present = l2Present
      self.asPresent = asPresent
      self.vaBits = vaBits
      self.pageSizes = pageSizes
      self.groupSlots = groupSlots
      self.queuesPerGroup = queuesPerGroup
      self.workRegisters = workRegisters
      self.unpreservedRegisters = unpreservedRegisters
      self.scoreboards = scoreboards
      self.priorities = priorities
    }
  }

  /// A VM: its handle (1 to 32), and where the client's addresses end: it
  /// owns [0, `userRange`), and the driver keeps the rest.
  public struct VMInfo: Equatable, Sendable {
    public var id: UInt32
    public var userRange: UInt64
    public init(id: UInt32, userRange: UInt64) {
      self.id = id
      self.userRange = userRange
    }
  }

  /// A buffer: `vmo` is the pinned, write-combining memory (map it
  /// writable), `id` names it to `bind`, `size` is rounded to the GPU
  /// page.
  public struct Buffer: ~Copyable {
    public var vmo: Handle
    public var id: UInt32
    public var size: UInt64
    public init(vmo: consuming Handle, id: UInt32, size: UInt64) {
      self.vmo = vmo
      self.id = id
      self.size = size
    }
  }

  /// A queue of a group: its ring's size (a power of two, 4 KiB to
  /// 64 KiB) and its priority within the group (0 to 15).
  public struct QueueConfig: Equatable, Sendable {
    public var ringSize: UInt32
    public var priority: UInt32
    public init(ringSize: UInt32, priority: UInt32) {
      self.ringSize = ringSize
      self.priority = priority
    }
  }

  /// A job: the stream at `stream` (64-byte aligned) of `size` bytes (a
  /// multiple of 8) for queue `queue` to run; both 0 is a sync point, done
  /// when the queue's jobs before it are. `flush` is the cache flush ID
  /// the client last saw (0 flushes; bits 24 to 30 are zero).
  public struct Job: Equatable, Sendable {
    public var queue: UInt32
    public var stream: UInt64
    public var size: UInt32
    public var flush: UInt32
    public init(queue: UInt32, stream: UInt64, size: UInt32, flush: UInt32) {
      self.queue = queue
      self.stream = stream
      self.size = size
      self.flush = flush
    }
  }

  /// A group's state (panthor 10 section 10.6.4): bit 0 the group was
  /// stopped with jobs unfinished (a timeout or a reset), bit 1 a queue hit a
  /// fatal fault (named in `fatalQueues`), bit 2 a reset others caused
  /// ended it. A group with a bit set takes no more jobs. `resident` is
  /// whether it holds a firmware slot.
  public struct GroupState: Equatable, Sendable {
    public var state: UInt32
    public var fatalQueues: UInt32
    public var resident: Bool
    public init(state: UInt32, fatalQueues: UInt32, resident: Bool) {
      self.state = state
      self.fatalQueues = fatalQueues
      self.resident = resident
    }
  }

  public protocol Context {
    func info() -> Info

    /// A VM of `userRange` bytes of the client's addresses (0 chooses;
    /// at most the address space less 256 MiB); the handle and where the
    /// client's addresses end.
    func createVM(userRange: UInt64) throws(GPUError) -> VMInfo
    /// The handle goes at once; the VM lives until its groups are gone.
    func destroyVM(vm: UInt32) throws(GPUError)

    /// Pinned write-combining memory of `size` bytes (`flags` is 0).
    func createBuffer(size: UInt64, flags: UInt32) throws(GPUError) -> Buffer
    func destroyBuffer(id: UInt32) throws(GPUError)
    /// Map `size` bytes of the buffer from `offset` at `address` of the VM,
    /// replacing what was mapped there (all multiples of 4 KiB, inside the
    /// client's addresses). `flags`: bit 0 read-only for the GPU, bit 1 not
    /// executable, bit 2 the GPU doesn't cache it.
    func bind(vm: UInt32, buffer: UInt32, offset: UInt64, size: UInt64, address: UInt64, flags: UInt32)
      throws(GPUError)
    func unbind(vm: UInt32, address: UInt64, size: UInt64) throws(GPUError)

    /// A group over `vm` with one queue for each of `queues`, at `priority`
    /// (0 low, 1 medium, 2 high, 3 realtime); its handle (1 to 128).
    func createGroup(vm: UInt32, queues: [QueueConfig], priority: UInt32) throws(GPUError) -> UInt32
    func destroyGroup(group: UInt32) throws(GPUError)
    func groupState(group: UInt32) throws(GPUError) -> GroupState

    /// A counter of the client's to wait on and raise; its id.
    func addSync(counter: consuming Handle) throws(GPUError) -> UInt32
    func removeSync(id: UInt32)

    /// The jobs, each on its queue in order, once every wait has reached
    /// its value; when the last job of the call is done, each signal is
    /// raised to its value, well or not (`groupState` says). A group that
    /// ended gives `lost`.
    func submit(group: UInt32, jobs: [Job], waits: [SyncValue], signals: [SyncValue]) throws(GPUError)
  }
}
