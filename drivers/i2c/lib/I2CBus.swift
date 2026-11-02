// SPDX-License-Identifier: BSD-3-Clause

// An I2C bus as its controller's driver serves it (D158): a device on it,
// which devmgr binds as a device of its own linked to the controller,
// reaches its chip through `transfer`, at `bus` in the controller's
// tree (/dev/provider/SERVICE/bus in the device's driver).

import IPC
import Node

@IPCLibrary(id: "vectraos.i2c", version: 1)
public enum I2CBusIPC {
  public enum I2CError: Int32, IPCErrorCode, Sendable {
    /// Nothing acknowledged the address.
    case noDevice = 1
    /// A byte written wasn't acknowledged.
    case nak
    /// The controller saw a bus error.
    case busError
    /// Another master won the bus.
    case arbitrationLost
    /// The transfer didn't end in its time.
    case timedOut
    /// More bytes than the controller moves in one transfer.
    case tooLong
  }

  public protocol Bus {
    /// `write` sent to the 7-bit `address`, then, after a repeated start,
    /// `read` bytes read from it (a write alone, a read alone, or an
    /// address alone, a probe, where the other is empty): what was read.
    func transfer(address: UInt16, write: [UInt8], read: UInt32) throws(I2CError) -> [UInt8]
  }
}
