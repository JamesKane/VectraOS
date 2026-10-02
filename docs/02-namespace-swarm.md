# Phase 2 — The 9Px filesystem protocol and the distributed swarm namespace

_Blueprint v0, 2026-09-30._

## 1. The model

Plan 9's three ideas, unchanged:

1. **Every resource is a file tree served by some process** over one protocol.
2. **Every process has its own namespace**, assembled with `bind` and `mount`. Union directories let several trees appear as one.
3. **The network is transparent to that protocol**, so a mount of a remote tree looks the same as a local one.

What is new here is the set of *resources* (GPU and NPU accelerators, AI models and context, window internals, sensors, swarm pools) and the *protocol features* needed to make them fast: data by reference, a shared-memory transport, leases, and batching.

## 2. Namespace mechanics

**`libns` resolves names against the mount table of the process's namespace group, in user space** (D4, ADR-0009). Each entry maps a mount point to one or more *(connector, root, flags)* members; there are several for a union. A mount point is identified as in Plan 9: by the connector and the qid of the directory it was mounted on, not by its path. The path the user typed is kept beside it for `ns`.

```
bind  [-b|-a|-c] new old     # -b: new goes before old in the union, -a: after, -c: allow create
mount [-b|-a|-c] [-k key] srv|uri old [aname]
unmount [new] old
ns                           # print the namespace as namespace(6) lines, which newns replays
```

**Path resolution:** walk from the root's mount, checking the qid `Twalk` returns for each name against the table. At a mount point, continue from that mount's root with the names that remain. So a mount shows through every name that reaches its directory, and crossing one costs no extra round trip. Union directories try each member in order. `..` is resolved lexically before walking, as in Plan 9, so it cannot escape a bind.

**Inheritance:** every process belongs to a **namespace group**. As with Plan 9's `rfork`, a spawn chooses:

- **share** (the default): the child joins its parent's group, so a `bind` in a script reaches the shell that ran it;
- **copy** (`RFNAMEG`): a new group starting from a copy of the parent's table, sent as `mount` and `bind` records;
- **clean** (`RFCNAMEG`): an empty group, which the spawner fills from a template.

`nsd` holds the table of every group with more than one member. It publishes each table read-only to the members as a VMO with a sequence counter, so resolving a name takes no round trip, and `bind`, `mount` and `unmount` are one channel call each. Connections stay per process: a table entry names a connector, and each member opens its own connection through it on first use (a ring connection is never shared, §3.2).

**Security:** a process can only mount connections it holds handles for, so rewriting its own table gives it nothing it did not already have. Authority is the set of handles; the namespace is the *view*.

Because `libns` runs inside the process, `bind` confines nothing. A process can ignore its table and send its own `Twalk`, including `..`, from any fid on any connection it holds. Confinement therefore comes only from the connection:

- A restricted view is **its own connection, attached at a restricted root**: the `aname` of its `Tattach`, and the `root:` caveat of its token (§3.4).
- The server enforces the root. `..` at the attach root returns the root, and no walk ever leaves it.
- Whoever builds a sandbox (the parent, or `svcd`) evaluates the template itself and passes the child only the resulting connection handles. The child never holds a connection with a wider root.

Every server's conformance suite plays a hostile client that speaks raw 9Px and checks that it cannot leave its attach root.

**Namespace templates** (`/lib/ns/*`) are namespace(6) files: scripts of `bind`, `mount` and `unmount` lines that `newns` in `vx-ns` reads, as Plan 9's `newns` does. `ns` and `/proc/N/ns` print the same form. A template is a script, not data, so D14's ndb rule does not cover it (ADR-0009). Templates build sessions, POSIX environments, sandboxes and agent jails (§7):

```
# /lib/ns/posix — what a POSIX program expects
mount -a /srv/bootfs /
bind -c #home/$user /home/$user
bind /srv/ptyd /dev/pty
bind -a /srv/null /dev
mount -c /srv/tmpfs /tmp
```

**`/srv`** is Plan 9's service registry. A server *posts* a channel under `/srv/name`, and a client *mounts* it. `svcd` serves `/srv` for the local node.

## 3. 9Px: the protocol

### 3.1 Base and negotiation

9Px **is 9P2000** plus optional extensions, negotiated in `Tversion`:

```
Tversion msize=1048576 version="9P2000.x/1 +dref +map +lease +notify +xattr +posix"
Rversion msize=1048576 version="9P2000.x/1 +dref +map +notify"   # the server replies with what it supports
```

- A server that answers `9P2000` or `9P2000.L` still works, with extensions off.
- Our clients can therefore mount 9front, Linux `v9fs`-style servers, `diod`, QEMU's virtfs and WSL's 9P. Our servers can be mounted by Linux's `mount -t 9p`. **Milestone M3 depends on this** (04 §5, M3).
- Every extension is a capability bit from version 1 (rule 9).

### 3.2 Transports

| Scheme | Transport | Notes |
|---|---|---|
| `9px+shm://srvname` | A `Ring` from 01 §4.3 | Local default. Each message is a descriptor in the SQ; message bytes are in the arena; bulk data is by reference |
| `9px+tcp://host[:port]/path` | TCP with a Noise IK handshake, using the swarm keys (§6.2) | Remote default. One connection per mount. Large reads and writes are split at `msize` into chunks of at most 64 KiB, so a bulk transfer holds up a small message for about 64 µs at 1 GB/s. There is no pool of bulk connections, and so one handshake per mount |
| `9p://host[:port]` · `tcp!host!564` | The same TCP transport without Noise, speaking plain 9P2000 or 9P2000.L | For servers and clients from other systems: 9front, Linux `v9fs`, `diod`, QEMU virtfs. Plan 9 dial strings are accepted everywhere. Mounting plain 9P is always allowed. *Serving* it is off unless the user turns it on for a named address, because it has no authentication |

That is the whole list: one local transport and one network transport.

**Connecting over `9px+shm`.** A server reads a *listen channel*; `svcd` keeps its other end as `/srv/name`, and hands that end, duplicated, to whoever may mount the service. A client sends a connect request there with `channel_call`. The server creates a ring, keeps the server end, and replies with the client end and the ring's memory. So every connection is its own ring, as an SPSC ring requires (01 §4.3), and a connection is never shared: a child that inherits a mount connects again through its copy of the listen channel. Because `svcd` holds the listen channel and not the server, connections made while a server restarts wait for it instead of failing.

- **Roaming** (a laptop changing networks) is handled by reconnect and replay (§6.8), not by the transport.
- **NAT and firewalls** are handled by WireGuard or Tailscale overlays (§6.3).
- **Virtual machines** reach their host over ordinary TCP (QEMU user networking), so there is no vsock transport.
- **QUIC** is not used. Everything it offered is covered above, and it would be a second transport, putting TLS inside the swarm's own protocol, which Noise already secures (rule 13). TLS exists only in `tlsd`, for services outside the swarm (00 D16).
- **RDMA, later.** A `9px+rdma` transport (RC queue pairs over RoCEv2 or InfiniBand, with bulk data moved by RDMA read or write into registered `Buffer`s) is a planned extension for nodes with RDMA NICs. `dref` already has an RDMA region type, so adding it will not change the protocol.

### 3.3 Extensions

| Extension | Messages | Why |
|---|---|---|
| **dref** (data by reference) | `Tread`/`Rread` and `Twrite` carry `{region, offset, len}` instead of inline bytes. A region is an arena range or VMO handle (shm), the bytes that follow the message in the stream (TCP), or later an RDMA remote key | Zero copy (01 §6). A 64 MiB tensor read costs one small message |
| **map** | `Tmap fid offset len prot` returns a VMO handle from a trusted local pager. From a remote or untrusted server the client gets a private copy of the range instead (01 §5), so no remote server can stall a page fault | `mmap` of files and of devices. Model weights are mapped, not read |
| **lease** | `Tlease fid` and `Rlease`: a read lease, validated by the file's `qid.version`; server-initiated `Rbreak` recalls it. There are no write leases: writes go through to the server | Client-side caching with correctness, as Plan 9's `cfs` did with `qid.version`. NFSv4 write delegations show how hard write leases are to get right. Makes remote builds and remote `/ai/models` fast |
| **notify** | `Tnotify fid mask` then a stream of `Rnotify` messages (created, removed, modified, attribute changed) | File watching (IO.watch) without polling |
| **xattr** | 9P2000.L's `Tgetattr` and `Tsetattr`, wire format unchanged, plus two attributes: content type and schema reference | POSIX `stat` fidelity with no new spec, and agent discoverability |
| **posix** | 9P2000.L's `Trenameat`, `Tlink`, `Tsymlink`, `Treadlink`, `Tlock`, `Tgetlock` and `Tfsync`, unchanged; plus open-file state kept by the server, so every fd that shares an open shares its offset and `O_APPEND` (01 §9) | Git renames across directories, SQLite takes locks, and `fork` shares offsets. 9P2000's `wstat` can only rename within one directory |
| **Tflush** | Unchanged | Cancellation. It is Exec's `AbortIO`, and the heritage study validates it |

**Each extension waits for its first user.** An extension is frozen only when the milestone that needs it lands, and its spec in `docs/proto/` then opens with the client code that uses it. Until then, the table above is a sketch, not a promise.

| Extension | First needed by | First user |
|---|---|---|
| `dref` | M5 | `fsd` reads into a client `Buffer` without a copy |
| `map` | M5 | `mmap` of a file through the pager |
| `notify` | M6 | `winsrv` watching `/wsys/theme`; `gsh` completion caches |
| `lease` | M8 | the `cfs` cache in a `cpu` session (§6.6) |
| `xattr` | M4 | POSIX `stat` in the musl back end |
| `posix` | M4 | Git, and the shell's redirections, in the musl back end |

**Pipelining, not batching.** 9P clients choose their own fids, so walk, open and read can be sent back to back without waiting: `Twalk fid=0 newfid=5 …`, `Topen 5`, `Tread 5`. 9Px adds one rule: a server processes a request that names a fid created by an earlier request on the same connection after that request. If the walk fails, the later requests fail with `unknown fid`. That is one round trip over a WAN with no compound message; NFSv4's COMPOUND is the warning.

**Backpressure** needs no extension either. A server can only answer outstanding `Tread`s, so the number a client keeps outstanding is its credit. On a ring, the queue depth is the credit.

**Asynchrony:** 9P was always tagged and asynchronous. A client with several requests outstanding needs nothing more. A blocking read on an `events` file is *just an outstanding `Tread`*: when the reply arrives it becomes a ring completion, and therefore a packet on the client's one port (rule 4). No readiness protocol is needed.

### 3.4 Authentication

- The transport authenticates *nodes* (§6.2).
- `Tauth` or `Tattach` then presents a **capability token**: a macaroon: an HMAC chain whose root key is held, in `keyd`, by the server that minted it. That server is also the one that verifies it, so no shared secret ever leaves the node. Its caveats restrict it, for example:
  ```
  swarm:jk-home · root:/n/tower/accel · rights:rw · expires:2026-10-01T12:00Z · holder:agent/editor-7 · ops:!remove
  ```
- Anyone holding a token can **attenuate** it (add caveats) without contacting the issuer. That is how delegation to agents, to a `cpu` session or to a friend works (§7).
- **Bound to a node:** `holder:` names a node key, and the server accepts the token only on a Noise session authenticated by that key. A token copied off a machine is useless anywhere else.
- **Fail closed:** a verifier rejects a token with any caveat it does not understand.
- **Short-lived:** tokens expire within minutes or hours and are renewed; there is no other revocation. Expiry needs clocks that agree, so nodes keep real time with NTP through `netd` (§6.2).
- `keyd` holds private keys and performs the signing. Programs never see key material; they ask `keyd` over a channel, as with Plan 9's factotum.

## 4. Conventions for synthetic file servers

Every service follows the same shape, so that `ls`, `cat` and `echo` explore it and an agent can learn it without documentation:

| File | Convention |
|---|---|
| `ctl` | Commands written as text, one per write: `verb arg...`. The write returns an error string on failure. Reading it returns the current settings as re-playable commands |
| `info` / `status` | One ndb record (§4.1). Stable keys, documented in `.schema` |
| `events` | A stream: a blocking read returns the next records. Text by default, one ndb record per event; fixed-size binary records where rate matters, with the layout in `.schema` |
| `clone` | Opening it allocates a new instance directory `N/`, and reading it returns `N`. This is Plan 9's `/net/tcp/clone` pattern, used for connections, sessions, jobs and leases |
| `data` | Raw payload |
| `.help` | Human text: what this directory is and what `ctl` accepts |
| `.schema` | ndb records (§4.2) describing each file's keys and each `ctl` verb, with argument types and side-effect classes (`read-only`, `reversible`, `destructive`) |

The side-effect class in `.schema` is what the agent approval UI (03 §8.5) and `auditfs` act on.

### 4.1 One text format: ndb records

Every structured text file in the system uses one format, taken from Plan 9's network database (ndb). That covers `info`, `status`, text `events`, `.schema`, driver and service manifests, app manifests, the build's port and vendor files, and `/ai/policy` (D14). There is no TOML, JSON or YAML anywhere in the base system.

```
# a comment
key=value key=value flag key="a value with spaces"
    key=value                   # an indented line continues the record above
```

- A **record** is one line of tuples, plus any indented lines that follow it. Blank lines are ignored, and `#` starts a comment wherever a tuple could start.
- A **tuple** is `key=value`, or a bare `key`, which is a flag that is set. A record's first tuple usually says what kind of record it is (`match`, `route`, `file=info`).
- **Values** without spaces are written bare. Other values go in double quotes, where `""` stands for one quote. A value that is not printable UTF-8 (it holds a newline, another control character, or invalid UTF-8) is written as hex bytes inside `x"…"`: a file named `a`, newline, `b` is `name=x"610a62"`. Nothing else is escaped.
- **Writers never format by hand.** Window titles, file names, a11y text and model output come from other programs, and a newline or a stray quote in them would forge tuples or whole records. `vx-ndb`'s writer quotes and hex-encodes by itself, and no server builds a record with `printf`.
- **Parsers are strict.** A record with a duplicate key, bad quoting, or more than 64 KiB is rejected whole, never repaired, so two parsers can never read one record differently.
- **Lists** are comma-separated values (`formats=int8,int4,fp16`). Each key appears at most once in a record.
- **No nesting and no types** in the file. Dots group related keys (`reviewed.by`, `mem.free`). Types come from `.schema`.
- Files are UTF-8, and every record is one `grep` away.

The parser and writer are `vx-ndb`, a few hundred lines of C shared by every server, `svcd`, `devmgr` and `build`.

### 4.2 `.schema`

A `.schema` file is ndb too. It has one record per key and one per `ctl` verb:

```
file=info key=vendor type=string doc="Sensor vendor"
file=info key=rates  type=uint list doc="Supported sample rates, Hz"
file=ctl  verb=rate  args="hz:uint" effect=reversible
file=ctl  verb=range args="sensor:enum(accel|gyro) g:uint" effect=reversible
file=ctl  verb=calibrate effect=destructive
```

The types are `string`, `int`, `uint`, `float`, `bool`, `size`, `duration`, `time`, `path` and `enum(a|b|…)`. The flag `list` marks a comma-separated list.

## 5. The canonical tree

This is what a desktop terminal's default namespace looks like. The right-hand column names the server behind each tree.

```
/
├── boot/                      bootfs       read-only boot image (svc configs, drivers)
├── bin/ lib/ usr/             fsd          union: /boot/bin + /usr/bin + $home/bin
├── home/$user/                fsd          the user's files
├── tmp/                       tmpfs
├── env/                       envfs        per-namespace-group environment variables as files
├── srv/                       svcd         posted service channels
├── proc/                      procfs       every process by pid, native and POSIX alike
├── sys/                       sysfs        cpu/ mem/ clock/ power/ vulns
├── dev/                       drivers      cons, null, random, input/, sensors/, audio/, block/, gpu/, accel/, net/, display/
├── net/                       netd         Plan 9 style: tcp/ udp/ ether*/ cs dns ipifc/
├── wsys/                      winsrv       the app's own windows; the whole tree only by grant (§5.5)
├── ai/                        aid          models, sessions, ctx pools, providers, policy
├── swarm/                     swarmd       nodes, pools, jobs
├── n/                         (mounts)     remote nodes and volumes: /n/tower, /n/phone, /n/nas
└── mnt/                       (mounts)     session-specific; /mnt/term inside a cpu session
```

### 5.1 Processes and CPU topology

`procfs` holds the one process table (ADR-0011), with 9front's files. A pid is the process's kernel task id, which is never reused, and `exec` keeps the task (ADR-0012). Every spawn registers the child before it runs. M2's `procfs` serves `status` and `ctl` (`kill`); the rest arrives with the features it reports.

```
/proc/42/
    status     pid=42 name=hx state=running sid=7 intent=interactive threads=3 mem=18.2M budget=user/jk/desktop
    ctl        (write) kill · stop · start · startstop · waitstop · hang · nohang · setsid · intent background · trace on
    ppid       the parent's pid
    noteid     the note group (POSIX's process group): read it, or write a group's id to join it
    ns         the namespace group's table as namespace(6) lines
    fd/        one entry per open fd: its path, offset and server
    caps       held handles: type, rights, badge (inspect right required)
    threads/1/{status,ctl,sched}
    note       write to post a note (ADR-0010); a POSIX signal is a note too
    notepg     write to post a note to every process in the note group but the writer
    wait       read blocks until a child ends: pid=43 name=cc status="sys: trap: fault read addr=0x0 pc=0x4011a0" utime= stime= real=; its stat length is the records queued
    args       the command line
    events mem maps images threads/N/{regs,fpregs}    the debug files (05 §3)
/sys/cpu/
    topology   cpu=cpu0 cluster=0 llc=0 numa=0 type=perf capacity=1024 freq=4.8G smt=cpu1   (one record per CPU)
               cpu=cpu8 cluster=1 llc=1 numa=0 type=eff  capacity=512  freq=2.6G
               cpu=cpu2 cluster=0 llc=0 numa=0 type=perf capacity=1024 freq=4.8G reserved=42   (a core reservation, 01 §8)
    load       per-cpu utilisation, 1 s window
    vulns      mitigations selected
/sys/clock/
    info       tsc.hz=3187200000 tsc.invariant tsc.user cntfrq.hz=24000000 source=tsc
    now        monotonic and realtime, in ns
```

`/sys/clock/info` publishes the counter frequency the kernel calibrated at boot. A program that times itself with `rdtsc` or `cntvct_el0` reads this record once and never has to calibrate or guess. User space may always read the cycle counter; there is no mode that traps it.

In `topology`, `llc=` groups cores that share a last-level cache and `numa=` groups them by memory node; core reservations can target either (01 §8). On a Ryzen X3D part the V-Cache chiplet is its own `llc`, and its records carry the flag `vcache`.

`procfs` shows a task's files only to its own session. Writing `ctl` or `note`, and every debug file, need a token that names the task (05 §3).

### 5.2 Sensors and input

```
/dev/sensors/
    imu0/
        info       vendor=bosch model=bmi270 axes=accel,gyro rates=25,50,100,200,400
        ctl        rate 200 · range accel 8g · calibrate
        accel      read → "0.012 -0.003 9.806 m/s2 t=1759250000.123456789"
        gyro       read → "0.001 0.000 -0.002 rad/s t=..."
        stream     binary records {t_ns u64, x f32, y f32, z f32, kind u8}; ring-backed
        .schema
    temp/cpu0/{info,value}          value → "61.5 C"
    light0/{info,value,ctl}
    gnss0/{info,fix,nmea}
/dev/input/
    gamepads/0/{info,ctl,events}    normalised layout (F-214); ctl: rumble 0.4 0.8 120ms · led 2 · gyro on
    keyboards/ mice/ pens/           raw HID-usage streams; normally consumed only by winsrv
```

`cat /dev/sensors/imu0/accel` works from a shell. A robotics program mounts `/n/robot/dev/sensors` from the robot and reads the same files.

### 5.3 Accelerators

```
/dev/accel/
    gpu0/
        info       kind=gpu vendor=amd model="Radeon 890M" memory=uma coherent=yes
                       api=vulkan-1.4 profile=vx-vk-2026 queues=gfx:1,compute:4,copy:2 budget=12.0G
        ctl        (write) priority-classes · reset
        clone      open → allocates a context N/ (for non-Vulkan clients: CUDA-shaped host API, 00 D7)
        N/{ctl,status,mem,queue}
    npu0/
        info       kind=npu vendor=rockchip model=rk3588-npu tops.int8=6 formats=int8,int4,fp16
                       runtime=teflon ops=conv,matmul memory=uma coherent=no
        clone
        N/
            ctl        load /ai/models/yolo11n.tflite · bind-input 0 buf:17 · bind-output 0 buf:18 · run
            status     state=idle runs=1832 last_us=4210
            wait       read blocks until the submitted run completes; also a Counter (fence)
    .schema
```

Vulkan applications use the Vulkan loader, which talks to the GPU driver over rings. The GPU tree is still there for discovery, budgets and scripting, and for remote access (§6). NPUs, which have no cross-vendor API, are driven *through* this tree plus `Buffer` handles. `aid` wraps them for most users. Only NPUs with an open user-space stack are supported: the RK3588's, through Mesa's Rocket driver and its Teflon TensorFlow Lite delegate. Intel's NPU, AMD XDNA, Qualcomm Hexagon and Apple's ANE need closed Linux user-space libraries today, so they wait until open stacks exist.

### 5.4 Networking (Plan 9 style)

```
/net/tcp/clone                  open → "4"
/net/tcp/4/ctl                  connect 192.0.2.10!443 · announce *!8080 · keepalive 30
/net/tcp/4/{data,listen,local,remote,status}
/net/cs                         connection server: write "tcp!tower!9px" → read "/net/tcp/clone 10.0.0.5!564"
/net/dns                        query: write "tower.lan ip" → read answers
/net/ipifc/0/{ctl,status}       add 10.0.0.9/24 · mtu 9000
```

### 5.5 Windows (summary; 03 §5 has the full protocol)

```
/wsys/
    ctl                         new toplevel · focus 7 · workspace 3
    events                      desktop-level: window created/destroyed, output changes, keymap
    windows/7/
        ctl          move 100 200 · resize 1280 800 · tile left · float · fullscreen · close · raise
        info         kind=toplevel app=org.vx.hx pid=42 title="main.c — hx" workspace=2 scale=180/120
        geometry     x=100 y=200 w=1280 h=800 seq=41
        state        visible focused tiled
        events       key, pointer, IME, resize, frame events (binary records, ring-backed)
        surface      present fast path (Buffer + fence + damage), ring-backed
        ime          enable · rect 10 20 12 38 · surrounding "fn main" 7 7
        a11y/        accessibility tree as files (03 §5.6)
        props/       free-form key-value properties apps can set, for scripts and agents
    outputs/DP-1/{info,ctl,frame}
    workspaces/3/{ctl,layout,windows}
    keys                        key bindings (03 §5.3)
    theme/                      design tokens (03 §5.4)
```

An app's namespace holds only `/wsys/self`, its own windows, and a `new` verb. The whole tree, with every window's `events` and `a11y`, is a grant for `wm`, the shell, the palette and assistive technology (03 §5.7).

### 5.6 AI (summary; 03 §8 has the runtime)

```
/ai/
    models/
        qwen3-8b-q4/{info,ctl,clone}        info: params=8.2B quant=q4_K_M ctx=32768 placement=gpu0 loaded
        whisper-large-v3-turbo/…
        bge-m3/…                            embedding model
    providers/
        anthropic/{info,ctl,clone}          a frontier model as a mount; keys held by keyd
    sessions/
        clone                               open → "12"
        12/
            ctl        model qwen3-8b-q4 · temperature 0.2 · tools /ai/tools/fs,/ai/tools/wsys · max-tokens 2048
            prompt     write a user turn
            output     read streamed tokens (blocking read = streaming)
            context    the current context window: messages, attachments, token counts
            usage      tokens in/out, time, placement (local gpu0 | swarm tower:gpu0 | provider)
            actions    log of the tool calls this session made (read-only)
    ctx/
        personal/                           a context pool
            info       items=18234 embed=bge-m3 index=hnsw sensitivity=private replicas=laptop,tower
            docs/      the items (files, notes, window text) as files, with sensitivity labels
            query      write "how did I configure the RK3588 NPU?" → read ranked hits
            add        write a path or URI to index
    tools/                                  tool definitions exposed to models (.schema per tool)
    policy                                  routing and privacy rules (03 §8.6)
```

An agent sees only its own session and the context pools the user grants it (§7). `aid` never reads a pool on behalf of a session that was not granted it.

## 6. The distributed swarm

_Provisional: nothing in this section is needed before M8 (04 §6). It records the intended shape and will be rewritten against the code that M8 produces._

### 6.1 Roles

Plan 9 split resources into terminals, CPU servers, file servers and auth servers. A VectraOS node can take any combination of these roles:

| Role | Serves | Typical node |
|---|---|---|
| **Terminal** | A screen, input, local devices. Exports `/mnt/term` to sessions it starts | Laptop, tablet |
| **CPU server** | Cores and memory for `cpu` sessions | Workstation, rack server |
| **Accelerator server** | `/dev/accel/*` and `/ai/models` for remote use | GPU tower, NPU board (RK3588), Apple Silicon Mac mini |
| **File server** | Durable volumes and context pools | NAS |
| **Auth server** (optional) | Token issuance for multi-user swarms | Any always-on node |

### 6.2 Identity and trust

- Every node has an **ed25519 node key**, held in `keyd` and sealed by the TPM or Secure Enclave where there is one. The seal is bound to the PCRs of the measured boot chain (01 §10), so a modified kernel cannot unseal it.
- A **swarm** is defined by an *owner key*. The owner signs node certificates. Joining uses a pairing code or QR code shown on an existing member (SPAKE2), which yields a signed certificate.
- Transport authentication uses Noise IK over TCP with these certificates. Noise is the only secure-channel protocol in the system, written first-party over Monocypher primitives. Access to specific trees then uses capability tokens (§3.4).
- **Node certificates are short-lived** (days) and renew automatically while the node is in touch with the swarm. A lost or stolen node is put on a revocation list, signed by the owner key and gossiped by `swarmd`; every member refuses it from then on.
- **The owner key stays offline,** on a device that is not a daily-use node, with a paper recovery code. It is used only to sign node certificates and revocations, so losing a laptop never means losing the swarm.
- Nodes keep real time with NTP through `netd`, because certificate and token expiry depend on it.
- A node from another swarm can be granted access only with an explicit token. There is no implicit trust across swarms.

### 6.3 Discovery and mounting

- `swarmd` advertises and discovers nodes with DNS-SD (`_9px._tcp`) only on networks the user has marked as trusted. On café or LAN-party Wi-Fi an advertisement would publish node names and GPU inventory to strangers. Configured addresses and relays extend this beyond the LAN, and WireGuard or Tailscale overlays work unchanged.
- Nodes appear as:

```
/swarm/nodes/tower/
    info       roles=cpu,accel arch=x86_64 cores=32 mem=128G addr=9px+tcp://tower.lan
    load       cpu=0.12 gpu0=0.40 npu0=0.00 mem.free=71G
    caps       gpu0=vulkan-1.4,24G npu0=none models=qwen3-32b,whisper
    rtt        rtt=0.21ms bw=1.1G
```

Mounting uses the ordinary commands:

```sh
mount 9px+tcp://tower.lan/dev/accel /n/tower/accel       # one remote tree
import tower /ai/models /n/tower/models                  # import: dial via /net/cs, auth via keyd
bind -a /n/tower/accel /dev/accel                        # tower's GPUs now appear next to local ones
ls /dev/accel                                            # gpu0  npu0  tower-gpu0  tower-gpu1
```

### 6.4 Pools and leases

`swarmd` aggregates nodes into **pools** and hands out time-bounded **leases**, which are scheduling-context budgets on the serving node (01 §8):

```
/swarm/pool/
    cpu/{info,clone}            info: nodes=tower,nas cores.free=40
    gpu/{info,clone}
    npu/{info,clone}
    gpu/clone                   open → "3"
    gpu/3/
        ctl     want mem=16G vulkan=1.3 near=me duration=2h · release
        status  granted=tower:gpu0 mem=16G expires=2026-09-30T19:02Z
        ns      the namespace fragment to bind: "mount 9px+tcp://tower.lan/dev/accel/gpu0 /dev/accel/lease3"
```

A program that uses the pool writes `want`, reads `ns`, and applies it. Asking the pool for a GPU and mounting a specific machine's GPU are the same operation.

### 6.5 The `cpu` command

```sh
cpu -h tower                       # interactive shell on tower
cpu -h tower -c './build all'       # run one command
cpu -p gpu -c 'python train.py'    # let the pool choose the node
```

What happens:

```
 terminal (laptop)                                   cpu server (tower)
 1. dial 9px+tcp://tower, mutual auth
 2. mint a token for the export: holder=tower ttl=session
 3. exportfs serves a narrow export ────────────────► 4. new session task; mounts it at /mnt/term
                                                     5. builds the session namespace from /lib/ns/cpu:
                                                          bind /mnt/term/work /work        # the directory cpu was started in
                                                          bind /mnt/term/dev/cons /dev/cons
                                                          bind /mnt/term/wsys /wsys        # the laptop's per-app view: windows open there
                                                          (tower's own /dev/accel, /bin and /proc stay local)
                                                     6. runs the command in that namespace
```

- **The export is narrow by default.** `exportfs` serves the directory `cpu` was started in (as `work`), `/dev/cons` and the laptop's per-app `/wsys` view, and nothing else: not `/srv`, not `keyd`, not `/ai/ctx`, not the rest of `$home`. A compromised CPU server gets that much and no more. `cpu -x path` adds a tree for one session. Plan 9 exported the whole namespace because terminal and CPU server belonged to one administrator; a swarm may include a friend's machine.
- The command sees the **laptop's exported files and screen** and the **tower's cores and GPUs**.
- A GUI program launched this way opens its windows on the laptop, because `/wsys` is the laptop's.
- Surfaces rendered on the tower's GPU are sent as compressed frames over a `/wsys` surface stream. The window server offers the encoded codec surface type, H.265 or AV1 with the GPU encoder at both ends, when the connection is not local.

### 6.6 Transparent offloading: three worked examples

**1. A build on a CPU server.** `cpu -p cpu -c 'make -j64'`. Sources are read through `/mnt/term` with read leases, so after the first build the tower's `cfs` cache serves them without round trips. Outputs are written through to the laptop as they are produced. No distcc-style tool is needed.

**2. Local-first inference that grows beyond the laptop.** The editor writes a prompt to `/ai/sessions/12/prompt` with `model qwen3-32b`. The laptop's `aid` sees that the model is not resident locally, checks `/ai/policy`, finds that `tower` advertises `qwen3-32b` in `/swarm/nodes/tower/caps`, and forwards the session to `tower`'s `aid` over 9Px. Tokens stream back through `/ai/sessions/12/output`. The editor never knew. `usage` shows `placement tower:gpu0`.

**3. Sensor processing on a remote NPU.** A camera on an RK3588 robot is mounted over the network. Frames stay on the robot, and its NPU runs detection *where the data is*. The laptop reads only the detections:

```sh
mount 9px+tcp://robot/dev /n/robot/dev
echo 'load /ai/models/yolo11n.tflite · bind-input 0 camera:/dev/camera0 · run continuous' > /n/robot/dev/accel/npu0/clone
cat /n/robot/dev/accel/npu0/4/output     # detections as text records
```

This rule applies generally: **move the computation to the data** when the result is smaller than the input.

### 6.7 Latency and granularity

The namespace makes remote resources *nameable*. It does not make them *free*. Work is placed according to measured transport cost:

| Transport | Round trip | Bandwidth | Offload granularity it supports |
|---|---|---|---|
| `9px+shm` (local ring) | ~1 µs | memory bandwidth | Any, including per-kernel dispatch |
| `9px+tcp` over LAN (2.5–10 GbE) | 100–300 µs | 0.3–1.2 GB/s | Job and request level: an inference session, a compile unit |
| `9px+tcp` over WAN | 10–100 ms | varies | Whole jobs, sync, pools of context |
| `9px+rdma` (later; 100 GbE RoCE) | 3–5 µs | ~12 GB/s | Tensor-level; model sharding between two nodes |

- `swarmd` publishes the measured round-trip time and bandwidth per node, and `aid` and the pool scheduler use them.
- Each device class's `.schema` declares the granularity its remote use supports.
- A Vulkan queue submission is never routed over the network. Remote GPUs are used at the level of a lease plus a job, or through `aid` sessions, not by forwarding the Vulkan API.

### 6.8 Failure semantics

- **Reconnection:** a remote mount that drops returns `Rerror "hungup"` for requests in flight. The client library then re-dials and replays its fids (walk paths are recorded), as Plan 9's `aan` did. Outstanding leases are re-validated.
- **Jobs:** pool jobs are declared as either *idempotent*, in which case they are re-run elsewhere, or *checkpointed*, in which case state is written to a pool file and resumed. `aid` sessions resume from the transcript held in `context`.
- **Visibility:** failure is shown in the UI and in `/swarm/nodes/*/info`, not hidden. The status bar shows each remote resource the foreground app is using.

## 7. Namespaces as sandboxes: agents and delegation

Because the namespace is the authority (rule 3), sandboxing needs no new mechanism, only the rule from §2 that every confined view is its own connection:

```
# /lib/ns/agent.editor — what an editing agent may see. svcd evaluates it and hands
# the agent only the resulting connections, each attached at its own root.
mount -a /srv/bootfs!bin /bin                # tools, read-only
mount -c /srv/auditfs!$project /work         # the project only, through auditfs: every write logged and snapshotted
mount /srv/winsrv!window/$win /wsys/self     # its own window only; no other window or screen contents
mount /srv/aid!session/$session /ai/self     # its own session; no other session, no context pool
# absent: /home, /net, /dev, /n, /swarm, keys, and any connection to fsd
```

- **Grants at run time:** when the agent needs more, it writes a request to `/wsys/self/ctl`, for example `request mount /home/jk/notes read`. The desktop shows an approval prompt (03 §8.5). On approval, `svcd` mints an attenuated token and mounts the extra tree into the agent's namespace group.
- **Audit:** `auditfs` is a pass-through 9Px server. It logs every mutating operation with the session id, and uses the side-effect classes from `.schema` to decide what needs approval or a snapshot. `auditfs` is the agent's only connection to those files; the agent never holds a connection to `fsd`. Effect classes are trusted only from servers on the system's trusted list. A verb from any other server, such as one on a remote node, is treated as `destructive`, whatever its `.schema` says.
- **Delegation across machines** uses the same tokens. The `cpu` session in §6.5 is itself a delegated, attenuated namespace.

## 8. Open questions

1. **`cfs` and remote maps.** v1 gives a remote `Tmap` a private copy (§3.3). Is a coherent shared mapping across nodes ever worth its cost, or are a copy and a read lease the permanent answer?
2. **Encoded surfaces for remote windows.** Which codec baseline (AV1 or H.265) and which latency target (under 30 ms on a LAN) should `/wsys` promise?
3. ~~**Namespace groups.**~~ Settled by ADR-0009: groups are shared by default, as in Plan 9, and `nsd` arrives in M4.
