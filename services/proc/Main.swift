// SPDX-License-Identifier: BSD-3-Clause

// bin/proc (V3, D79): /proc, a directory for each process under the job
// its manifest's `jobs` grants (the launcher's: every service and what each
// starts). Manifests mount its tree at /proc. It holds a handle to each
// process it has seen while it lives, to read and to kill it and to post
// its notes (D87). Given `tracing`, it serves /proc/trace (D102): the
// kernel's trace through a TraceSession, and each process's trace task
// and the mappings it may run.

import IPC
import Node
import Proc
import Sys
import TraceSession

func fail(_ what: String) -> Never {
  print("proc: \(what)")
  Process.exit(code: 2)
}

/// The kernel's trace, under the tracing resource: one recording at a time.
final class Tracer: @unchecked Sendable {
  let resource: UInt32
  let lock = Lock()
  var session: TraceSession?

  init(resource: consuming Handle) { self.resource = resource.release() }

  func start(_ hz: UInt64, _ pages: Int, _ categories: UInt32) throws(Status) {
    try lock.withLock { () throws(Status) in
      session?.stop()
      session = nil  // its mappings of the rings go before they are made again
      session = try TraceSession(resource: resource, categories: [], kernel: categories, pagesPerCPU: pages,
                                 sampleHz: hz)
    }
  }

  func stop() -> [UInt8] {
    lock.withLock { () -> [UInt8] in
      guard let session else { return [] }
      session.stop()
      return session.kernelTrace()
    }
  }
}

/// The processes under a job, and handles to them.
final class Processes: @unchecked Sendable {
  let root: UInt32
  let lock = Lock()
  /// A handle to each process seen (raw: an Array can't hold a Handle).
  var held: [(koid: UInt64, raw: UInt32)] = []

  init(root: consuming Handle) { self.root = root.release() }

  /// Every process under the root job, its jobs' koids from the root down;
  /// handles kept to each, and closed for those gone.
  func entries() -> [ProcEntry] {
    var out: [ProcEntry] = []
    var handles: [(koid: UInt64, raw: UInt32)] = []
    func visit(_ job: borrowing Handle, _ path: [UInt64]) {
      guard let koid = try? job.info().koid else { return }
      let jobs = path + [koid]
      // An ended process stays in its job while a handle holds it, this
      // one's included: it isn't shown, nor held.
      for p in (try? Job.processes(job)) ?? [] {
        guard let h = try? job.child(p), let info = try? Process.info(h), !info.exited else { continue }
        out.append(ProcEntry(koid: p, jobs: jobs))
        handles.append((p, h.release()))
      }
      for j in (try? Job.children(job)) ?? [] {
        guard let child = try? job.child(j) else { continue }
        visit(child, jobs)
      }
    }
    let rootJob = Handle(raw: root)
    visit(rootJob, [])
    _ = rootJob.release()
    let stale = lock.withLock { () -> [UInt32] in
      defer { held = handles }
      return held.map { $0.raw }
    }
    for raw in stale { _ = Handle(raw: raw) }  // closed
    return out
  }

  /// `body` with a handle to `koid`, if it has been seen.
  func with<R>(_ koid: UInt64, _ body: (borrowing Handle) -> R?) -> R? {
    lock.withLock { () -> R? in
      guard let raw = held.first(where: { $0.koid == koid })?.raw else { return nil }
      let h = Handle(raw: raw)
      let r = body(h)
      _ = h.release()
      return r
    }
  }

  func status(_ koid: UInt64) -> ProcStatus? {
    with(koid) { p -> ProcStatus? in
      guard let info = try? Process.info(p) else { return nil }
      let state = info.exited ? "Moribund" : info.started ? "Running" : "New"
      let cpu = (try? Process.runtime(p))?.cpuTime ?? 0
      let memory = (try? Process.stats(p)).map { ($0.privateBytes + $0.scaledShared) / 1024 } ?? 0
      return ProcStatus(name: (try? p.name()) ?? "", state: state, userMilliseconds: UInt64(max(0, cpu)) / 1_000_000,
                        realMilliseconds: 0, memoryKiB: memory)
    }
  }

  func kill(_ koid: UInt64) -> Bool { with(koid) { p in (try? Sys.kill(p)) != nil } ?? false }

  /// Its trace task (a thread's trace id's high bits), name and mappings
  /// that may run; nil if it has no thread, or is gone.
  func describe(_ koid: UInt64) -> TracedProcess? {
    with(koid) { p -> TracedProcess? in
      guard let threads = try? Process.threads(p), let first = threads.first, let t = try? p.child(first),
        let id = try? Thread.traceID(t)
      else { return nil }
      let mappings = ((try? Process.mappings(p)) ?? []).filter { $0.executable }
      return TracedProcess(koid: koid, task: id >> 12, name: (try? p.name()) ?? "", mappings: mappings)
    }
  }

  func post(_ koid: UInt64, _ text: String) throws(Status) {
    var failure: Status? = .badState
    _ = with(koid) { p -> Bool? in
      do throws(Status) {
        try Note.post(text, to: p)
        failure = nil
      } catch {
        failure = error
      }
      return true
    }
    if let failure { throw failure }
  }
}

@main struct ProcService {
  static func main() {
    let start = Startup.current
    guard let job = start.take(HandleType.info(HandleType.jobDefault, 1)) else {
      fail("no job to show (its manifest's `jobs`)")
    }
    let processes = Processes(root: job)
    // `tracing`: argument 1 of the system resource's type.
    var tracer: Tracer?
    if let resource = start.take(HandleType.info(HandleType.resource(.system), 1)) { tracer = Tracer(resource: resource) }
    let dispatcher: IPCDispatcher
    do throws(Status) { dispatcher = try IPCDispatcher() } catch { fail("can't make a dispatcher") }
    let tree = NodeTree(dispatcher: dispatcher)
    let files = ProcFiles(tree: tree, host: ProcHost(
      processes: { processes.entries() },
      status: { processes.status($0) },
      kill: { processes.kill($0) },
      post: { (koid: UInt64, text: String) throws(Status) in try processes.post(koid, text) },
      trace: tracer.map { t in
        TraceHost(start: { (hz: UInt64, pages: Int, categories: UInt32) throws(Status) in try t.start(hz, pages, categories) },
                  stop: { t.stop() }, describe: { processes.describe($0) })
      }))
    files.refresh()
    guard let export = start.export() else { fail("no export (its manifest's `export`)") }
    do throws(Status) {
      try tree.serve(export)
      try dispatcher.run()
    } catch {
      fail("can't serve: \(error.rawValue)")
    }
  }
}
