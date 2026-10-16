// SPDX-License-Identifier: BSD-3-Clause

// bin/launch-service: TreeService.swift's tree, natively, for the launcher's
// boot test (system/launch/tests/native/manifests).

import Sys

@main struct LaunchService {
  static func main() { treeService(Startup.current) }
}
