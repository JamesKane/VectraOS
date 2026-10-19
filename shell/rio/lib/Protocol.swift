// SPDX-License-Identifier: BSD-3-Clause

// A rio window's surface (rio(4), D107), at `surface` in its files: lent
// to a program running in the window, which draws in a view of its own
// that rio shows over the window's whole content. Plan 9's winname, as a
// typed handoff: the program has no window of its own (vt(1)).

import IPC

@IPCLibrary(id: "vectraos.rio", version: 1)
public enum RioIPC {
  public enum SurfaceError: Int32, IPCErrorCode, Sendable {
    /// Not a view's token, or the window is gone.
    case invalid = 1
    /// Another program has the surface.
    case lent = 2
  }

  public protocol Surface {
    /// Shows the view whose token this is over the window's content,
    /// sized as the window is, until the view closes; rio shows its text
    /// again then. While it is shown, the window's raw keys include the
    /// arrows and the other keys that move the caret, as kbdfs's runes.
    func lend(view: consuming Handle) throws(SurfaceError)
  }
}
