# D136. Each info topic answers in its current layout only (2026-10-25, proposed; for the owner's review)

object_get_info's topics are Zircon's, versioned as Zircon's are: the
version in the topic's bits 31:28, an older version a prefix of the
newer layout. The kernel answers seven older versions, most by writing
that prefix (`putPrefix`): TASK_STATS_V1, KMEM_STATS_V1, TASK_RUNTIME_V1,
PROCESS_MAPS_V1, PROCESS_VMOS_V1 and _V2, VMO_V1 and _V2 (and _V3, the
current VMO layout's 128-byte prefix). Zircon keeps them for binaries
built against an older SDK. VectraOS has none: every program is built
from this tree with this tree's headers. The one caller of an older
version is Sys's `kmemStats` (KMEM_STATS_V1, whose fields the current
layout also has); the others are asked only by usertest.c's checks
that they answer.

- **A topic has one layout, its current one.** The older versions' enum
  cases go from `task.h` and `resource.h`, and `InfoTopics.swift` and
  `IpcSyscalls.swift` stop matching them; `putPrefix` goes. An older
  topic number is answered `NOT_SUPPORTED`, as any unknown topic is.
- **The numbering stays Zircon's** (topic | version << 28), with each
  topic's number its current version's, so Zircon's documentation and
  tools still read our numbers. A layout that changes takes the next
  version and drops the old one in the same change: nothing out of the
  tree needs it kept.
- Sys's `kmemStats` asks for KMEM_STATS, reading the fields it reads
  now. usertest.c's checks of the older versions are deleted with them;
  its checks of the current layouts stay where they are until a change
  touches them (D21).

Rejected: keeping them for Zircon parity (nothing here runs Zircon
binaries, and `docs/kernel/zircon-divergences.md` records the
difference); dropping the version bits from the numbers (a renumbering
of every current topic, for no line saved).

Covers: kernel/include/task.h, kernel/include/resource.h,
kernel/Kernel/User/InfoTopics.swift, IpcSyscalls.swift, Syscalls.swift
(`putPrefix`), system/sys/backend/native/Kernel.swift, user/test/usertest.c,
`docs/kernel/zircon-divergences.md`, and object(2). About
90 lines. Tests: boot-sys and the usertest boot on each arch.
