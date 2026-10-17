# D82. Driver classes are Plan 9's device directories for control, the one ring for bulk (2026-10-16, decided)

The driver classes (D74) are typed protocols over rings: the input class
(V2 item 7d), the net class (V3) and the block class (V4). "Nodes for
control, rings for bulk" holds, but the control halves were each a
protocol of their own. Plan 9 gives each kind of device one directory
shape, which rc, cpu and `import` reach without a client library.

- **Each class serves Plan 9's directory for its kind**, in the driver
  host's tree and bound into `/dev` or `/net` by devmgr:

  | Class | Directory | From |
  |---|---|---|
  | net | `/net/etherN/{clone,addr,stats,ifstats}`, and per conversation `N/{ctl,data,type,stats}` | Plan 9's ether(3) |
  | block | `/dev/sdXX/{ctl,raw,data}`, and a file per partition | sd(3) |
  | input | `/dev/kbd`, `/dev/mouse`, `/dev/mousectl` | 9front's kbd(3), mouse(3) |
  | audio | `/dev/audio`, `/dev/audioctl`, `/dev/volume` | 9front's audio(3) |

  `ctl` takes Plan 9's lines where Plan 9 has them (`promiscuous`,
  `mtu`, `geometry`, ...), and `stats` reads as Plan 9's text.
- **A data file's bulk is the one ring** (D43), attached through Node's
  `attach` (D67): a frame, block or event stream costs no syscall while
  it flows. Its records are Plan 9's where Plan 9 has a format (kbd's
  `k`/`K`/`c` lines, mouse's `m` records), so rc and tools read them
  with a plain Node read, and fast readers attach the ring. One format
  either way.
- **What stays typed:** devmgr's own protocol with driver hosts
  (resources, binding, `CROI_PA_DEVICE`), and Radharc's (D75 kept it).
  Display is not a device directory here: there is no `/dev/draw`.
- The network service (D79) is a client of `/net/etherN`, as Plan 9's IP
  stack is of `#l`; Taisce opens `/dev/sdXX/data` or a partition.
