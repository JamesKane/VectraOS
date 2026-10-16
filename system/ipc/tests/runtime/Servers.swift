// SPDX-License-Identifier: BSD-3-Clause

// Echo and Loud servers on tasks of their own, for the hosted tests
// (natively, bin/ipc-test starts them on threads: tier 0 has no tasks).

import Echo
import IPC

/// Starts a server on its own task; it sends one event, then serves.
func startServer(_ raw: UInt32) -> Task<IPCError<Never>?, Never> {
  Task.detached {
    var server = TestIPC.EchoServer(channel: Handle(raw: raw), impl: EchoImpl())
    do throws(IPCError<Never>) {
      try server.sendTicked(7, label: "first")
      try server.serve()
      return nil
    } catch {
      return error
    }
  }
}

/// Serves Loud, after sending one event of Echo's and one of its own.
func startLoudServer(_ raw: UInt32) -> Task<IPCError<Never>?, Never> {
  Task.detached {
    var server = TestIPC.LoudServer(channel: Handle(raw: raw), impl: LoudImpl())
    do throws(IPCError<Never>) {
      try TestIPC.EchoEventSender.sendTicked(1, label: "composed", on: server.connection)
      try server.sendShouted("hey")
      try server.serve()
      return nil
    } catch {
      return error
    }
  }
}
