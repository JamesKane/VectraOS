// SPDX-License-Identifier: BSD-3-Clause

// fdio's namespace hosted: only what a test installs (FDIO.install).

import Node

func processNamespace() -> Namespace? { nil }

/// No descriptors are inherited hosted.
func inherited(_ fd: Int32) -> Bool { false }
