# Venus protocol

Data, not code (principle 29): the Venus protocol's definitions that
`vkgen` reads to generate the Venus client driver's encoders and decoders
(M5d). Each file keeps its own license, `Apache-2.0 OR MIT` (its SPDX
line), and is unmodified.

| File | Upstream path | sha256 (first 16) |
|---|---|---|
| `VK_EXT_command_serialization.xml` | `xmls/VK_EXT_command_serialization.xml` | 2451e5dcc5306f60 |
| `VK_MESA_venus_protocol.xml` | `xmls/VK_MESA_venus_protocol.xml` | d92839bc728fa9ad |
| `vk.xml` | `xmls/vk.xml` (Vulkan header version 357, the registry Venus is defined against) | 264d0d7350e37d70 |

From https://gitlab.freedesktop.org/virgl/venus-protocol at commit
`ca19b6358d7cc491bc3e4de76f04c6700876a8fa` (2026-09-06, "update version to
1.1.3"), fetched 2026-10-11. The repository has no LICENSE file at its root;
the files' SPDX lines are their licenses.

This `vk.xml` is newer than `data/vulkan/vk.xml` (341), which the host's
Vulkan bindings are generated from: Venus's encoding is generated from its
own, so the two stay apart. The wire format they serialize is written up
in our own words in `docs/research/venus-protocol.md`.

To update: copy the new files over from a newer commit, record it and the
hashes here, and regenerate.
