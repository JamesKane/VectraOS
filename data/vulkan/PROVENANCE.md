# Vulkan API registry

Data, not code (principle 29): the registry `vkgen` reads to generate
`graphics/vulkan/c/include/td_vulkan.h` and `graphics/vulkan/swift/generated/Commands.swift`.
It keeps its own license, `Apache-2.0 OR MIT` (its SPDX line), and is
unmodified.

| File | From (Fedora 44 package) | Upstream | sha256 (first 16) |
|---|---|---|---|
| `vk.xml` | vulkan-headers 1.4.341.0-1.fc44, `/usr/share/vulkan/registry/vk.xml` | Khronos Vulkan-Docs, header version 341 | 006807a47518e9ab |

Copied 2026-10-09. To update: copy the new file over, record its version
and hash here, and regenerate (`CLAUDE.md`, "Generated outputs").
