// SPDX-License-Identifier: BSD-3-Clause

// fdio's namespace natively: the process's Startup's (D65), read the
// first time a path is resolved, unless the program installed one
// (FDIO.install) before.

import Node
import Sys

func processNamespace() -> Namespace? { try? Namespace(Startup.current) }
