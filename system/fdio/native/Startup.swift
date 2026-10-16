// SPDX-License-Identifier: BSD-3-Clause

// fdio's namespace natively: the process's Startup's (D65), read the
// first time a path is resolved, unless the program installed one
// (FDIO.install) before.

import Node
import Sys
import TDNative

func processNamespace() -> Namespace? { try? Namespace(Startup.current) }

/// Whether `fd` is a descriptor the process was started with, a ring of
/// its own above 2 (D46, td_stdio.h): fdio leaves its number alone.
func inherited(_ fd: Int32) -> Bool { unsafe td_stdio_has(fd, nil) }
