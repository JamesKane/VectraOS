// SPDX-License-Identifier: BSD-3-Clause

// bin/gpu-test (gpu-test(8), D173): what runs on a command-stream GPU
// through the GPU class's `csf` capset: a user stream the GPU runs, a
// stream that faults ending only its group, and the cost of a job that
// does nothing. The stream is the user side's own: MOV48 and STORE_STATE
// of the timestamp, then a SYNC_ADD64 into a counter word of the buffer
// (chinese-wall's valhall 01); the driver wraps it in the kernel's ring
// sequence. RingInstruction (the driver's, which writes that sequence)
// has the encodings, so this program is built with its file.
//
// Where no GPU offers `csf`, it says so and exits 0.

import GPUClient
import GPUDevice
import Node
import Sys

@main struct GPUTest {
  static func fail(_ what: String) -> Never {
    print("gpu-test: FAILED: \(what)")
    Process.exit(code: 1)
  }

  /// Where the buffer is bound in the VM: the stream at its start, the timestamp
  /// and the counter in the second page.
  static let base: UInt64 = 0x10_0000
  static let timestampOffset = 4096
  static let counterOffset = 4096 + 64

  static func main() {
    let ns: Namespace
    do throws(NamespaceError) { ns = try Namespace(Startup.current) } catch { fail("no namespace") }
    GPUContext.namespace = ns
    guard CSFContext.isOffered() else {
      print("gpu-test: skipped: no csf GPU")
      Process.exit(code: 0)
    }
    ranAStream()
    aFaultEndedOnlyItsGroup()
    emptyJobs()
    print("gpu-test: passed")
    Process.exit(code: 0)
  }

  /// A context with a VM, a two-page buffer bound at `base`, a group of one queue and a sync.
  struct Rig {
    var context: CSFContext
    var vm: UInt32
    var buffer: CSFBuffer
    var group: UInt32
    var sync: UInt32
  }

  static func rig() -> Rig {
    do throws(CSFClientError) {
      let context = try CSFContext()
      let vm = try context.createVM().id
      let buffer = try context.createBuffer(size: 8192)
      try context.bind(vm: vm, buffer: buffer, size: UInt64(buffer.size), address: base)
      let group = try context.createGroup(vm: vm, ringSizes: [4096])
      let sync = try context.createSync()
      return Rig(context: context, vm: vm, buffer: buffer, group: group, sync: sync)
    } catch {
      fail("context: \(error)")
    }
  }

  /// MOV48 r0 timestamp's address; STORE_STATE the timestamp there; MOV48 r2
  /// the counter's address and r4 1; wait for the store; SYNC_ADD64 r4 into
  /// the counter.
  static func stream() -> [UInt64] {
    [
      RingInstruction.mov48(0, base + UInt64(timestampOffset)),
      RingInstruction.storeState(address: 0, cycles: false),
      RingInstruction.mov48(2, base + UInt64(counterOffset)),
      RingInstruction.mov48(4, 1),
      RingInstruction.wait(mask: 0x00FF),
      RingInstruction.syncAdd64(address: 2, value: 4),
    ]
  }

  static func ranAStream() {
    let r = rig()
    let words = stream()
    r.buffer.write(words: words, at: 0)
    r.buffer.store(UInt64(0), at: timestampOffset)
    r.buffer.store(UInt64(0), at: counterOffset)
    let job = GPUCSFIPC.Job(queue: 0, stream: base, size: UInt32(words.count * 8), flush: 0)
    do throws(CSFClientError) { try r.context.submit(group: r.group, jobs: [job], signals: [(r.sync, 1)]) } catch {
      fail("submit: \(error)")
    }
    guard r.context.wait(sync: r.sync, value: 1, timeoutNanoseconds: 10_000_000_000) else {
      fail("the GPU didn't raise the counter within 10 seconds")
    }
    let timestamp = r.buffer.load(UInt64.self, at: timestampOffset)
    let counter = r.buffer.load(UInt64.self, at: counterOffset)
    guard timestamp != 0 else { fail("the stream's timestamp reads 0") }
    guard counter == 1 else { fail("the stream's counter word reads \(counter), not 1") }
    guard let state = try? r.context.groupState(r.group), state.state == 0 else { fail("the group's state isn't clean") }
    print("gpu-test: ok: the GPU ran a command stream (timestamp \(timestamp))")
  }

  /// A CALL to an address nothing maps: the MMU faults, the group ends, its
  /// context is lost; another context's stream still runs.
  static func aFaultEndedOnlyItsGroup() {
    let r = rig()
    let unmapped: UInt64 = 0x7000_0000
    let words: [UInt64] = [
      RingInstruction.mov48(0, unmapped),
      RingInstruction.mov32(2, 64),
      RingInstruction.call(address: 0, size: 2),
      0,
    ]
    r.buffer.write(words: words, at: 0)
    let job = GPUCSFIPC.Job(queue: 0, stream: base, size: UInt32(words.count * 8), flush: 0)
    do throws(CSFClientError) { try r.context.submit(group: r.group, jobs: [job], signals: [(r.sync, 1)]) } catch {
      fail("faulting submit: \(error)")
    }
    // The counter rises when the group ends, with an error.
    guard r.context.wait(sync: r.sync, value: 1, timeoutNanoseconds: 10_000_000_000) else {
      fail("a faulting stream's counter didn't rise within 10 seconds")
    }
    guard let state = try? r.context.groupState(r.group), state.state & 2 != 0, state.fatalQueues & 1 != 0 else {
      fail("a faulting stream left no fatal fault in its group's state")
    }
    do throws(CSFClientError) {
      try r.context.submit(group: r.group, jobs: [job])
      fail("a lost context took a job")
    } catch {
      guard error == .lost else { fail("a lost context's submit says \(error), not lost") }
    }
    print("gpu-test: the fault: group state \(state.state), fatal queues \(state.fatalQueues)")

    // A fresh context's stream.
    let again = rig()
    let good = stream()
    again.buffer.write(words: good, at: 0)
    again.buffer.store(UInt64(0), at: counterOffset)
    let ok = GPUCSFIPC.Job(queue: 0, stream: base, size: UInt32(good.count * 8), flush: 0)
    do throws(CSFClientError) { try again.context.submit(group: again.group, jobs: [ok], signals: [(again.sync, 1)]) } catch {
      fail("submit after a fault: \(error)")
    }
    guard again.context.wait(sync: again.sync, value: 1, timeoutNanoseconds: 10_000_000_000),
      again.buffer.load(UInt64.self, at: counterOffset) == 1
    else { fail("a fresh context's stream didn't run after a fault") }
    print("gpu-test: ok: a faulting stream ended only its group")
  }

  /// Submit to the counter's raise, for a job with no stream: the median of 100.
  static func emptyJobs() {
    let r = rig()
    let empty = GPUCSFIPC.Job(queue: 0, stream: 0, size: 0, flush: 0)
    var times: [Int64] = []
    for i in 1...100 {
      let start = Clock.monotonic()
      do throws(CSFClientError) { try r.context.submit(group: r.group, jobs: [empty], signals: [(r.sync, UInt64(i))]) } catch {
        fail("empty job: \(error)")
      }
      guard r.context.wait(sync: r.sync, value: UInt64(i), timeoutNanoseconds: 10_000_000_000) else {
        fail("an empty job's counter didn't rise within 10 seconds")
      }
      times.append(Clock.monotonic() - start)
    }
    times.sort()
    let median = (times[49] + times[50]) / 2
    print("budget name=gpu.mali.empty_job_us value=\(median / 1000) unit=us")
  }
}
