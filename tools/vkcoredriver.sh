#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Writes graphics/vulkan/drivers/core/lib/Driver.swift: the Vulkan layer's table of entry points by name and its
# vkGetInstanceProcAddr and vkGetDeviceProcAddr. Every `func core_vkXxx` in the other files of lib/ is an entry
# point, so adding a command is writing its function and running this.
#
#     tools/vkcoredriver.sh
#
# Run it from anywhere; it needs only bash, grep, sed and sort.
set -e
lib="$(cd "$(dirname "$0")/.." && pwd)/graphics/vulkan/drivers/core/lib"
cd "$lib"
names=$(grep -h "^func core_vk" $(ls *.swift | grep -v '^Driver.swift$') | sed -E 's/func core_(vk[A-Za-z0-9]+).*/\1/' | sort)
{
cat <<'EOF'
// SPDX-License-Identifier: BSD-3-Clause

// The layer's entry points, by name, and the vkGetInstanceProcAddr and vkGetDeviceProcAddr the loader calls
// (D121): every command is given out for any handle, as Venus's driver does, and the loader filters by level.

import TDVulkan

/// Every command the layer implements, by name.
let coreEntries: [(name: StaticString, function: PFN_vkVoidFunction)] = [
EOF
for n in $names; do
  echo "  (\"$n\", unsafe unsafeBitCast(core_$n as PFN_$n, to: PFN_vkVoidFunction.self)),"
done
cat <<'EOF'
]

/// A command's entry point by name, or nil.
func coreProcAddress(_ name: UnsafePointer<CChar>?) -> PFN_vkVoidFunction? {
  guard let name = unsafe name else { return nil }
  for entry in coreEntries {
    var i = 0
    let s = unsafe entry.name.utf8Start
    while unsafe s[i] != 0, unsafe UInt8(bitPattern: name[i]) == s[i] { i += 1 }
    if unsafe s[i] == 0 && name[i] == 0 { return entry.function }
  }
  return nil
}

/// The layer's vkGetInstanceProcAddr, as the loader calls a driver's: standard pointer types only.
public let coreGetInstanceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer? = {
  instance, name in unsafe unsafeBitCast(coreProcAddress(name), to: UnsafeRawPointer?.self)
}

/// The layer's vkGetDeviceProcAddr.
public let coreGetDeviceProcAddr: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeRawPointer? = {
  device, name in unsafe unsafeBitCast(coreProcAddress(name), to: UnsafeRawPointer?.self)
}
EOF
} > Driver.swift
