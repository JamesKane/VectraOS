// SPDX-License-Identifier: BSD-3-Clause

// The audio class's lease (D180, D181): the protocol at `lease` in each
// device's directory, through which one lessee, the audio service, is
// lent the playback stream: its buffer's VMO, the layout of its periods,
// and the counter the class adds 1 to as the device finishes each one.
// The lease lasts while its channel is open.

import IPC
import Node

@IPCLibrary(id: "vectraos.audio.lease", version: 1)
public enum AudioLeaseIPC {
  public enum LeaseError: Int32, IPCErrorCode, Sendable {
    /// Another channel holds the lease, or this one already does.
    case busy = 1
    /// The device has no playback stream.
    case unsupported
    /// The device couldn't be set up or started.
    case io
    /// `clock` before `lend`.
    case notLent
  }

  /// A lent stream's layout: `periods` periods of `periodFrames` frames,
  /// `lead` of them with the device at a time, in the format `ctl` says:
  /// `sample` is the index of its sample format in s8, u8, s16, s24, s32,
  /// f32.
  public struct Layout: Equatable, Sendable {
    public var periods: UInt32
    public var periodFrames: UInt32
    public var lead: UInt32
    public var sample: UInt32
    public var channels: UInt32
    public var rate: UInt32
    public init(periods: UInt32, periodFrames: UInt32, lead: UInt32, sample: UInt32, channels: UInt32, rate: UInt32) {
      self.periods = periods
      self.periodFrames = periodFrames
      self.lead = lead
      self.sample = sample
      self.channels = channels
      self.rate = rate
    }
  }

  /// The lent buffer: map `buffer` writable, its first `periods` ×
  /// `periodFrames` frames the stream's.
  public struct Lent: ~Copyable {
    public var buffer: Handle
    public var layout: Layout
    public init(buffer: consuming Handle, layout: Layout) {
      self.buffer = buffer
      self.layout = layout
    }
    /// The VMO, taken out: another module can't consume one field of it.
    public consuming func takeBuffer() -> Handle { buffer }
  }

  /// The stream's counter: the periods the device has finished since the
  /// lease began, so period `k` is the buffer's slot `k mod periods`.
  public struct Clock: ~Copyable {
    public var counter: Handle
    public init(counter: consuming Handle) { self.counter = counter }
    public consuming func takeCounter() -> Handle { counter }
  }

  public protocol Lease {
    /// The playback stream, lent: its buffer, made silence, and its
    /// layout. The stream starts at once and runs until the channel
    /// closes; the lessee writes each period `lead` ahead of the device.
    func lend() throws(LeaseError) -> Lent
    /// The lent stream's counter.
    func clock() throws(LeaseError) -> Clock
  }
}
