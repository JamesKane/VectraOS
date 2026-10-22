// SPDX-License-Identifier: BSD-3-Clause

// The objects behind the driver's handles. Every handle points at 24
// bytes: the loader's word (ICD_LOADER_MAGIC until the loader puts its
// dispatch table there; 0 in non-dispatchable objects), the object's Venus
// id (offset 8, as the encoders read it: VenusObject), and the driver's
// state for objects that keep some (retained; 0 otherwise).

import TDVenus
import Venus

enum VenusHandle {
  static let loaderMagic: UInt64 = 0x01CD_C0DE

  static func make(id: UInt64, state: VenusState?, dispatchable: Bool) -> OpaquePointer {
    let p = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
    unsafe p.storeBytes(of: dispatchable ? loaderMagic : 0, as: UInt64.self)
    unsafe p.storeBytes(of: id, toByteOffset: 8, as: UInt64.self)
    let s = state.map { unsafe UInt(bitPattern: Unmanaged.passRetained($0).toOpaque()) } ?? 0
    unsafe p.storeBytes(of: s, toByteOffset: 16, as: UInt.self)
    return OpaquePointer(p)
  }

  static func id(_ h: OpaquePointer?) -> UInt64 { unsafe VenusObject.id(h) }

  /// The state an object keeps (not retained for the caller).
  static func state(_ h: OpaquePointer?) -> VenusState? {
    guard let h = unsafe h else { return nil }
    let s = unsafe UnsafeRawPointer(h).load(fromByteOffset: 16, as: UInt.self)
    guard s != 0, let p = unsafe UnsafeRawPointer(bitPattern: s) else { return nil }
    return unsafe Unmanaged<VenusState>.fromOpaque(p).takeUnretainedValue()
  }

  /// The context of a dispatchable object (or any with state).
  static func context(_ h: OpaquePointer?) -> VenusContext? { unsafe state(h)?.context }

  /// Frees a handle and drops its state.
  static func free(_ h: OpaquePointer?) {
    guard let h = unsafe h else { return }
    let p = unsafe UnsafeMutableRawPointer(h)
    let s = unsafe p.load(fromByteOffset: 16, as: UInt.self)
    if s != 0, let state = unsafe UnsafeRawPointer(bitPattern: s) {
      unsafe Unmanaged<VenusState>.fromOpaque(state).release()
    }
    unsafe p.deallocate()
  }
}

/// What an object keeps: at least its context.
class VenusState {
  let context: VenusContext
  init(_ context: VenusContext) { self.context = context }
}

@safe final class InstanceState: VenusState {
  var physicalDevices: [OpaquePointer] = unsafe []
  var enumerated = false
}

final class PhysicalDeviceState: VenusState {
  var memory = VkPhysicalDeviceMemoryProperties()
}

@safe final class DeviceState: VenusState {
  let physical: PhysicalDeviceState
  var queues: [(family: UInt32, index: UInt32, flags: UInt32, handle: OpaquePointer)] = unsafe []
  /// Its own handle, for the driver's own commands on it.
  var handle: OpaquePointer?
  init(_ context: VenusContext, physical: PhysicalDeviceState) {
    self.physical = physical
    super.init(context)
  }
}

/// A queue: its own vtest timeline and a sync counting its submissions.
@safe final class QueueState: VenusState {
  let device: DeviceState
  let timeline: UInt32
  let sync: UInt32
  var submitted: UInt64 = 0
  /// A fence of the driver's, for idle waits through the renderer.
  var idleFence: OpaquePointer?
  init(_ context: VenusContext, device: DeviceState, timeline: UInt32, sync: UInt32) {
    self.device = device
    self.timeline = timeline
    self.sync = sync
    super.init(context)
  }
}

/// A fence: signaled once its queue's sync reaches `value` (0: not
/// submitted since its reset; `signaled` covers a fence created signaled).
final class FenceState: VenusState {
  var sync: UInt32 = 0
  var value: UInt64 = 0
  var signaled = false
}

/// Device memory: its blob, when host-visible.
@safe final class MemoryState: VenusState {
  var resource: UInt32 = 0
  var address: UnsafeMutableRawPointer?
  var size = 0
}

/// A command buffer: its commands, recorded as Venus encodes them and sent
/// at vkEndCommandBuffer.
final class CommandBufferState: VenusState {
  var encoder = VenusEncoder()
}
